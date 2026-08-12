import Foundation
import SQLite3

/// Archive 相关的高频写入使用 SQLite；Catalog 的既有 JSON 快照仍保存用户编辑与兼容迁移数据。
/// 这样哈希/预览完成不会每项都重写整个 Catalog，也能用索引进行精确重复查询。
final class ArchiveIndexPersistence: @unchecked Sendable {
    let databaseURL: URL
    private var database: OpaquePointer?
    private let lock = NSLock()

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              database != nil else {
            throw ArchiveIndexError.openFailed
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try createSchema()
    }

    deinit { sqlite3_close(database) }

    static func databaseURL(for catalogURL: URL) -> URL {
        catalogURL
            .deletingPathExtension()
            .appendingPathExtension("archive.sqlite")
    }

    func load(assetIDs: [UUID]) throws -> (metadata: [UUID: ArchiveAssetMetadata], locations: [AssetLocation], relationships: [ArchiveDuplicateRelationship]) {
        lock.lock()
        defer { lock.unlock() }
        // `IN` 绑定值受 SQLite 编译时上限约束；历史图库可达 50k+ 项，必须分批读取。
        let batchSize = 400 // relationship 查询会使用两份绑定值，仍远低于保守的 999 上限。
        var metadata: [UUID: ArchiveAssetMetadata] = [:]
        var locations: [AssetLocation] = []
        var relationshipByKey: [String: ArchiveDuplicateRelationship] = [:]
        for start in stride(from: 0, to: assetIDs.count, by: batchSize) {
            let end = min(start + batchSize, assetIDs.count)
            let batch = Array(assetIDs[start..<end])
            metadata.merge(try loadMetadata(assetIDs: batch), uniquingKeysWith: { _, latest in latest })
            locations.append(contentsOf: try loadLocations(assetIDs: batch))
            for relationship in try loadRelationships(assetIDs: batch) {
                relationshipByKey[relationship.key] = relationship
            }
        }
        return (metadata, locations, Array(relationshipByKey.values))
    }

    func recordScan(
        source: PhotoSource,
        assets: [PhotoAsset],
        previouslyIndexedKeys: Set<String>
    ) throws -> ArchiveImportSummary {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            var summary = ArchiveImportSummary(scannedCount: assets.count)
            let seenPaths = Set(assets.map(\.relativePath))
            try markUnavailableLocations(sourceID: source.id, excluding: seenPaths)
            for asset in assets {
                let isExisting = previouslyIndexedKeys.contains(asset.identityKey)
                if isExisting { summary.sameIndexedFileCount += 1 } else { summary.newAssetCount += 1 }
                try upsertLocation(location(for: asset, source: source))
                try ensureArchiveRow(for: asset)
                try invalidateArchiveMetadataIfNeeded(for: asset)
            }
            try execute("COMMIT;")
            return summary
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// 首次创建 SQLite 归档索引时只复制既有 JSON Catalog 的派生检索信息；不修改或删除快照。
    func bootstrap(sources: [PhotoSource], assets: [PhotoAsset]) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            for source in sources {
                let sourceAssets = assets.filter { $0.sourceID == source.id }
                for asset in sourceAssets {
                    var location = location(for: asset, source: source)
                    location.isAvailable = source.status == .ready
                    // 启动时只补齐缺失位置，不覆盖上次扫描已判定为缺失的单个文件。
                    try insertLocationIfNeeded(location)
                    try ensureArchiveRow(for: asset)
                }
                if source.status != .ready {
                    try execute("UPDATE asset_locations SET is_available = 0 WHERE source_id = ?;", bindings: [.text(source.id.uuidString)])
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func recordUnavailableSource(_ sourceID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("UPDATE asset_locations SET is_available = 0 WHERE source_id = ?;", bindings: [.text(sourceID.uuidString)])
    }

    func save(result: ArchiveProcessingResult) throws -> [ArchiveDuplicateRelationship] {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let metadata = result.metadata
            try execute(
                """
                INSERT INTO archive_assets (
                    asset_id, exact_hash, visual_hash, hashed_file_size, hashed_modified_at, hash_updated_at,
                    hash_state, preview_relative_path, preview_version, preview_width, preview_height,
                    preview_byte_size, preview_generated_at, preview_source_modified_at, preview_state,
                    first_seen_at, last_seen_at, last_error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    exact_hash=excluded.exact_hash, visual_hash=excluded.visual_hash,
                    hashed_file_size=excluded.hashed_file_size, hashed_modified_at=excluded.hashed_modified_at,
                    hash_updated_at=excluded.hash_updated_at, hash_state=excluded.hash_state,
                    preview_relative_path=excluded.preview_relative_path, preview_version=excluded.preview_version,
                    preview_width=excluded.preview_width, preview_height=excluded.preview_height,
                    preview_byte_size=excluded.preview_byte_size, preview_generated_at=excluded.preview_generated_at,
                    preview_source_modified_at=excluded.preview_source_modified_at, preview_state=excluded.preview_state,
                    last_seen_at=excluded.last_seen_at, last_error=excluded.last_error;
                """,
                bindings: archiveBindings(assetID: result.assetID, metadata: metadata)
            )
            // 文件内容变化后，旧 SHA / 视觉指纹得出的关系不再有效；在同一事务内重建。
            try deleteRelationships(for: result.assetID)
            try replaceVisualSegments(assetID: result.assetID, visualHash: metadata.visualHash)
            let relationships = try exactDuplicateRelationships(assetID: result.assetID, exactHash: metadata.exactHash)
                + visualDuplicateRelationships(assetID: result.assetID, exactHash: metadata.exactHash, visualHash: metadata.visualHash)
            for relationship in relationships {
                try execute(
                    "INSERT OR IGNORE INTO duplicate_relationships (relationship_key, first_asset_id, second_asset_id, kind, discovered_at) VALUES (?, ?, ?, ?, ?);",
                    bindings: [.text(relationship.key), .text(relationship.firstAssetID.uuidString), .text(relationship.secondAssetID.uuidString), .text(relationship.kind.rawValue), .double(relationship.discoveredAt.timeIntervalSince1970)]
                )
            }
            try execute("COMMIT;")
            return relationships
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func exactMatches(for hash: String, excluding assetID: UUID) throws -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return try queryUUIDs(
            "SELECT asset_id FROM archive_assets WHERE exact_hash = ? AND asset_id != ?;",
            bindings: [.text(hash), .text(assetID.uuidString)]
        )
    }

    func previewCacheStatistics() throws -> (assetCount: Int, byteSize: Int64) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT COUNT(*), COALESCE(SUM(preview_byte_size), 0) FROM archive_assets WHERE preview_state = 'complete';", statement: &statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ArchiveIndexError.queryFailed(databaseMessage()) }
        return (Int(sqlite3_column_int(statement, 0)), sqlite3_column_int64(statement, 1))
    }

    func removeAllPreviewMetadata() throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("UPDATE archive_assets SET preview_relative_path = NULL, preview_version = NULL, preview_width = NULL, preview_height = NULL, preview_byte_size = NULL, preview_generated_at = NULL, preview_source_modified_at = NULL, preview_state = 'pending';")
    }

    private func createSchema() throws {
        let schema =
            """
            CREATE TABLE IF NOT EXISTS archive_assets (
                asset_id TEXT PRIMARY KEY,
                exact_hash TEXT,
                visual_hash TEXT,
                hashed_file_size INTEGER,
                hashed_modified_at REAL,
                hash_updated_at REAL,
                hash_state TEXT NOT NULL,
                preview_relative_path TEXT,
                preview_version INTEGER,
                preview_width INTEGER,
                preview_height INTEGER,
                preview_byte_size INTEGER,
                preview_generated_at REAL,
                preview_source_modified_at REAL,
                preview_state TEXT NOT NULL,
                first_seen_at REAL,
                last_seen_at REAL,
                last_error TEXT
            );
            CREATE INDEX IF NOT EXISTS archive_assets_exact_hash_idx ON archive_assets(exact_hash);
            CREATE INDEX IF NOT EXISTS archive_assets_visual_hash_idx ON archive_assets(visual_hash);
            CREATE TABLE IF NOT EXISTS asset_locations (
                id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                volume_identifier TEXT,
                volume_name TEXT,
                file_resource_identifier TEXT,
                relative_path TEXT NOT NULL,
                filename TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                modified_at REAL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                is_available INTEGER NOT NULL,
                UNIQUE(source_id, relative_path)
            );
            CREATE INDEX IF NOT EXISTS asset_locations_asset_idx ON asset_locations(asset_id);
            CREATE INDEX IF NOT EXISTS asset_locations_source_idx ON asset_locations(source_id, relative_path);
            CREATE TABLE IF NOT EXISTS duplicate_relationships (
                relationship_key TEXT PRIMARY KEY,
                first_asset_id TEXT NOT NULL,
                second_asset_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                discovered_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS duplicate_relationships_first_idx ON duplicate_relationships(first_asset_id);
            CREATE INDEX IF NOT EXISTS duplicate_relationships_second_idx ON duplicate_relationships(second_asset_id);
            CREATE TABLE IF NOT EXISTS visual_hash_segments (
                asset_id TEXT NOT NULL,
                segment INTEGER NOT NULL,
                signature INTEGER NOT NULL,
                PRIMARY KEY (asset_id, segment)
            );
            CREATE INDEX IF NOT EXISTS visual_hash_segments_lookup_idx ON visual_hash_segments(segment, signature);
            """
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else { throw ArchiveIndexError.queryFailed(databaseMessage()) }
    }

    private func ensureArchiveRow(for asset: PhotoAsset) throws {
        try execute(
            "INSERT OR IGNORE INTO archive_assets (asset_id, hash_state, preview_state, first_seen_at, last_seen_at) VALUES (?, 'pending', 'pending', ?, ?);",
            bindings: [.text(asset.id.uuidString), .double(Date.now.timeIntervalSince1970), .double(Date.now.timeIntervalSince1970)]
        )
    }

    private func location(for asset: PhotoAsset, source: PhotoSource) -> AssetLocation {
        let rootURL = URL(fileURLWithPath: source.lastKnownPath)
        let fileURL = rootURL.appendingPathComponent(asset.relativePath)
        let rootValues = try? rootURL.resourceValues(forKeys: [.volumeNameKey, .volumeIdentifierKey])
        let fileValues = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return AssetLocation(
            assetID: asset.id,
            sourceID: source.id,
            volumeIdentifier: rootValues?.volumeIdentifier.map { String(describing: $0) },
            volumeName: rootValues?.volumeName ?? rootURL.lastPathComponent,
            fileResourceIdentifier: fileValues?.fileResourceIdentifier.map { String(describing: $0) },
            relativePath: asset.relativePath,
            filename: asset.filename,
            fileSize: asset.fileSize,
            modifiedAt: asset.modifiedAt
        )
    }

    /// 对照上次参与计算的文件元数据。发生变化时，不能让旧哈希继续参与重复判断。
    private func invalidateArchiveMetadataIfNeeded(for asset: PhotoAsset) throws {
        guard let existing = try loadMetadata(assetIDs: [asset.id])[asset.id] else { return }
        let hashChanged = existing.hashedFileSize != nil &&
            (existing.hashedFileSize != asset.fileSize || existing.hashedModifiedAt != asset.modifiedAt)
        let previewChanged = existing.preview != nil && existing.preview?.sourceModifiedAt != asset.modifiedAt
        guard hashChanged || previewChanged else { return }

        try execute(
            """
            UPDATE archive_assets SET
                exact_hash = NULL, visual_hash = NULL, hashed_file_size = NULL, hashed_modified_at = NULL,
                hash_updated_at = NULL, hash_state = 'stale', preview_relative_path = NULL,
                preview_version = NULL, preview_width = NULL, preview_height = NULL, preview_byte_size = NULL,
                preview_generated_at = NULL, preview_source_modified_at = NULL, preview_state = 'stale',
                last_error = NULL
            WHERE asset_id = ?;
            """,
            bindings: [.text(asset.id.uuidString)]
        )
        try deleteRelationships(for: asset.id)
        try replaceVisualSegments(assetID: asset.id, visualHash: nil)
    }

    private func upsertLocation(_ location: AssetLocation) throws {
        try execute(
            """
            INSERT INTO asset_locations (id, asset_id, source_id, volume_identifier, volume_name, file_resource_identifier, relative_path, filename, file_size, modified_at, first_seen_at, last_seen_at, is_available)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, relative_path) DO UPDATE SET
                asset_id=excluded.asset_id, volume_identifier=excluded.volume_identifier, volume_name=excluded.volume_name,
                file_resource_identifier=excluded.file_resource_identifier, filename=excluded.filename, file_size=excluded.file_size,
                modified_at=excluded.modified_at, last_seen_at=excluded.last_seen_at, is_available=1;
            """,
            bindings: locationBindings(location)
        )
    }

    private func insertLocationIfNeeded(_ location: AssetLocation) throws {
        try execute(
            """
            INSERT OR IGNORE INTO asset_locations (id, asset_id, source_id, volume_identifier, volume_name, file_resource_identifier, relative_path, filename, file_size, modified_at, first_seen_at, last_seen_at, is_available)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: locationBindings(location)
        )
    }

    private func markUnavailableLocations(sourceID: UUID, excluding paths: Set<String>) throws {
        if paths.isEmpty {
            try execute("UPDATE asset_locations SET is_available = 0 WHERE source_id = ?;", bindings: [.text(sourceID.uuidString)])
            return
        }
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        let bindings: [SQLiteValue] = [.text(sourceID.uuidString)] + paths.sorted().map(SQLiteValue.text)
        try execute("UPDATE asset_locations SET is_available = 0 WHERE source_id = ? AND relative_path NOT IN (\(placeholders));", bindings: bindings)
    }

    private func exactDuplicateRelationships(assetID: UUID, exactHash: String?) throws -> [ArchiveDuplicateRelationship] {
        guard let exactHash else { return [] }
        return try queryUUIDs(
            "SELECT asset_id FROM archive_assets WHERE exact_hash = ? AND asset_id != ?;",
            bindings: [.text(exactHash), .text(assetID.uuidString)]
        ).map { ArchiveDuplicateRelationship(firstAssetID: assetID, secondAssetID: $0, kind: .exactDuplicate) }
    }

    private func visualDuplicateRelationships(assetID: UUID, exactHash: String?, visualHash: UInt64?) throws -> [ArchiveDuplicateRelationship] {
        guard let visualHash else { return [] }
        let candidates = try visualCandidates(for: visualHash, excluding: assetID)
        return candidates.compactMap { candidate in
            // 字节完全一致时只保留“完全重复”这一结论，避免让两种语义混在一起。
            candidate.exactHash != exactHash && (visualHash ^ candidate.hash).nonzeroBitCount <= 6
                ? ArchiveDuplicateRelationship(firstAssetID: assetID, secondAssetID: candidate.id, kind: .possibleVisualDuplicate)
                : nil
        }
    }

    private func deleteRelationships(for assetID: UUID) throws {
        try execute(
            "DELETE FROM duplicate_relationships WHERE first_asset_id = ? OR second_asset_id = ?;",
            bindings: [.text(assetID.uuidString), .text(assetID.uuidString)]
        )
    }

    private func replaceVisualSegments(assetID: UUID, visualHash: UInt64?) throws {
        try execute("DELETE FROM visual_hash_segments WHERE asset_id = ?;", bindings: [.text(assetID.uuidString)])
        guard let visualHash else { return }
        for segment in 0..<7 {
            try execute(
                "INSERT INTO visual_hash_segments (asset_id, segment, signature) VALUES (?, ?, ?);",
                bindings: [.text(assetID.uuidString), .int(Int32(segment)), .int64(Int64(bitPattern: segmentValue(visualHash, at: segment)))]
            )
        }
    }

    private func visualCandidates(for visualHash: UInt64, excluding assetID: UUID) throws -> [(id: UUID, hash: UInt64, exactHash: String?)] {
        let segmentClauses = (0..<7).map { _ in "(segment = ? AND signature = ?)" }.joined(separator: " OR ")
        let sql = "SELECT DISTINCT archive_assets.asset_id, archive_assets.visual_hash, archive_assets.exact_hash FROM visual_hash_segments JOIN archive_assets ON archive_assets.asset_id = visual_hash_segments.asset_id WHERE (\(segmentClauses)) AND archive_assets.asset_id != ?;"
        var bindings: [SQLiteValue] = []
        for segment in 0..<7 {
            bindings.append(.int(Int32(segment)))
            bindings.append(.int64(Int64(bitPattern: segmentValue(visualHash, at: segment))))
        }
        bindings.append(.text(assetID.uuidString))
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        try bind(bindings, to: statement)
        var result: [(id: UUID, hash: UInt64, exactHash: String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuid(column: 0, statement: statement), let hash = string(column: 1, statement: statement).flatMap(UInt64.init) else { continue }
            result.append((id, hash, string(column: 2, statement: statement)))
        }
        return result
    }

    private func loadMetadata(assetIDs: [UUID]) throws -> [UUID: ArchiveAssetMetadata] {
        guard !assetIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT asset_id, exact_hash, visual_hash, hashed_file_size, hashed_modified_at, hash_updated_at, hash_state, preview_relative_path, preview_version, preview_width, preview_height, preview_byte_size, preview_generated_at, preview_source_modified_at, preview_state, first_seen_at, last_seen_at, last_error FROM archive_assets WHERE asset_id IN (\(placeholders));", statement: &statement)
        try bind(assetIDs.map { .text($0.uuidString) }, to: statement)
        var result: [UUID: ArchiveAssetMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let assetID = uuid(column: 0, statement: statement) else { continue }
            result[assetID] = ArchiveAssetMetadata(
                exactHash: string(column: 1, statement: statement),
                visualHash: string(column: 2, statement: statement).flatMap(UInt64.init),
                hashedFileSize: int64(column: 3, statement: statement),
                hashedModifiedAt: date(column: 4, statement: statement),
                hashUpdatedAt: date(column: 5, statement: statement),
                hashState: ArchiveHashState(rawValue: string(column: 6, statement: statement) ?? "pending") ?? .pending,
                preview: preview(statement: statement),
                previewState: ArchivePreviewState(rawValue: string(column: 14, statement: statement) ?? "pending") ?? .pending,
                firstSeenAt: date(column: 15, statement: statement),
                lastSeenAt: date(column: 16, statement: statement),
                lastError: string(column: 17, statement: statement)
            )
        }
        return result
    }

    private func loadLocations(assetIDs: [UUID]) throws -> [AssetLocation] {
        guard !assetIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT id, asset_id, source_id, volume_identifier, volume_name, file_resource_identifier, relative_path, filename, file_size, modified_at, first_seen_at, last_seen_at, is_available FROM asset_locations WHERE asset_id IN (\(placeholders));", statement: &statement)
        try bind(assetIDs.map { .text($0.uuidString) }, to: statement)
        var result: [AssetLocation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuid(column: 0, statement: statement), let assetID = uuid(column: 1, statement: statement), let sourceID = uuid(column: 2, statement: statement), let relativePath = string(column: 6, statement: statement), let filename = string(column: 7, statement: statement) else { continue }
            result.append(AssetLocation(id: id, assetID: assetID, sourceID: sourceID, volumeIdentifier: string(column: 3, statement: statement), volumeName: string(column: 4, statement: statement), fileResourceIdentifier: string(column: 5, statement: statement), relativePath: relativePath, filename: filename, fileSize: int64(column: 8, statement: statement) ?? 0, modifiedAt: date(column: 9, statement: statement), firstSeenAt: date(column: 10, statement: statement) ?? .now, lastSeenAt: date(column: 11, statement: statement) ?? .now, isAvailable: sqlite3_column_int(statement, 12) != 0))
        }
        return result
    }

    private func loadRelationships(assetIDs: [UUID]) throws -> [ArchiveDuplicateRelationship] {
        guard !assetIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT first_asset_id, second_asset_id, kind, discovered_at FROM duplicate_relationships WHERE first_asset_id IN (\(placeholders)) OR second_asset_id IN (\(placeholders));", statement: &statement)
        let bindings = assetIDs.map { SQLiteValue.text($0.uuidString) }
        try bind(bindings + bindings, to: statement)
        var result: [ArchiveDuplicateRelationship] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let first = uuid(column: 0, statement: statement), let second = uuid(column: 1, statement: statement), let kindText = string(column: 2, statement: statement), let kind = ArchiveDuplicateKind(rawValue: kindText) else { continue }
            result.append(ArchiveDuplicateRelationship(firstAssetID: first, secondAssetID: second, kind: kind, discoveredAt: date(column: 3, statement: statement) ?? .now))
        }
        return result
    }

    private func archiveBindings(assetID: UUID, metadata: ArchiveAssetMetadata) -> [SQLiteValue] {
        let preview = metadata.preview
        return [.text(assetID.uuidString), .optionalText(metadata.exactHash), .optionalText(metadata.visualHash.map(String.init)), .optionalInt64(metadata.hashedFileSize), .optionalDate(metadata.hashedModifiedAt), .optionalDate(metadata.hashUpdatedAt), .text(metadata.hashState.rawValue), .optionalText(preview?.relativePath), .optionalInt(preview?.version), .optionalInt(preview?.width), .optionalInt(preview?.height), .optionalInt64(preview?.byteSize), .optionalDate(preview?.generatedAt), .optionalDate(preview?.sourceModifiedAt), .text(metadata.previewState.rawValue), .optionalDate(metadata.firstSeenAt), .optionalDate(metadata.lastSeenAt), .optionalText(metadata.lastError)]
    }

    private func locationBindings(_ location: AssetLocation) -> [SQLiteValue] {
        [.text(location.id.uuidString), .text(location.assetID.uuidString), .text(location.sourceID.uuidString), .optionalText(location.volumeIdentifier), .optionalText(location.volumeName), .optionalText(location.fileResourceIdentifier), .text(location.relativePath), .text(location.filename), .int64(location.fileSize), .optionalDate(location.modifiedAt), .double(location.firstSeenAt.timeIntervalSince1970), .double(location.lastSeenAt.timeIntervalSince1970), .int(location.isAvailable ? 1 : 0)]
    }

    private func queryUUIDs(_ sql: String, bindings: [SQLiteValue]) throws -> [UUID] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        try bind(bindings, to: statement)
        var result: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = uuid(column: 0, statement: statement) { result.append(value) }
        }
        return result
    }

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw ArchiveIndexError.queryFailed(databaseMessage()) }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ArchiveIndexError.queryFailed(databaseMessage())
        }
    }

    private func databaseMessage() -> String {
        guard let database, let message = sqlite3_errmsg(database) else { return "unknown SQLite error" }
        return String(cString: message)
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(value): result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let .int(value): result = sqlite3_bind_int(statement, index, value)
            case let .int64(value): result = sqlite3_bind_int64(statement, index, value)
            case let .double(value): result = sqlite3_bind_double(statement, index, value)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw ArchiveIndexError.queryFailed(databaseMessage()) }
        }
    }

    private func string(column: Int32, statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func int64(column: Int32, statement: OpaquePointer?) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    private func date(column: Int32, statement: OpaquePointer?) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func uuid(column: Int32, statement: OpaquePointer?) -> UUID? {
        string(column: column, statement: statement).flatMap(UUID.init(uuidString:))
    }

    private func preview(statement: OpaquePointer?) -> OfflinePreviewMetadata? {
        guard let relativePath = string(column: 7, statement: statement), let version = int64(column: 8, statement: statement), let width = int64(column: 9, statement: statement), let height = int64(column: 10, statement: statement), let byteSize = int64(column: 11, statement: statement), let generatedAt = date(column: 12, statement: statement) else { return nil }
        return OfflinePreviewMetadata(version: Int(version), relativePath: relativePath, width: Int(width), height: Int(height), byteSize: byteSize, generatedAt: generatedAt, sourceModifiedAt: date(column: 13, statement: statement))
    }

    private func segmentValue(_ hash: UInt64, at segment: Int) -> UInt64 {
        let widths = [10, 9, 9, 9, 9, 9, 9]
        let shift = widths.prefix(segment).reduce(0, +)
        let mask = (UInt64(1) << UInt64(widths[segment])) - 1
        return (hash >> UInt64(shift)) & mask
    }
}

private enum SQLiteValue {
    case text(String)
    case int(Int32)
    case int64(Int64)
    case double(Double)
    case null

    static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    static func optionalInt(_ value: Int?) -> SQLiteValue { value.map { .int(Int32($0)) } ?? .null }
    static func optionalInt64(_ value: Int64?) -> SQLiteValue { value.map(SQLiteValue.int64) ?? .null }
    static func optionalDate(_ value: Date?) -> SQLiteValue { value.map { .double($0.timeIntervalSince1970) } ?? .null }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ArchiveIndexError: LocalizedError {
    case openFailed
    case queryFailed(String = "")

    var errorDescription: String? {
        switch self {
        case .openFailed: "无法打开本地归档索引。"
        case let .queryFailed(message): "无法更新本地归档索引。\(message.isEmpty ? "" : " SQLite：\(message)")"
        }
    }
}
