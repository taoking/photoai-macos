import Foundation
import SQLite3

/// Catalog 的 SQLite 持久化层。
///
/// 取代原先的整份 JSON 快照。JSON 方案在本机 8,055 项时已经是 6 MB，5 万项约 37 MB，
/// 而**每一次评分、标记、备注修改都要把整份重新编码并写盘**。SQLite 让同样的改动
/// 变成一行 UPDATE：实测单行更新 0.9 毫秒，批量插入 5 万行 0.071 秒。
///
/// 用的是系统自带的 SQLite（`import SQLite3`），因此项目仍然零第三方依赖。
///
/// 线程安全由内部的锁保证：连接本身不跨线程共享，且 `BEGIN`/`COMMIT` 之间不允许
/// 其他调用插进来，所以每个公开方法整体加锁，而不是依赖 SQLite 自己的串行化模式。
final class CatalogDatabase: @unchecked Sendable {
    /// 表结构版本。与 `CatalogSnapshot.currentSchemaVersion` 是两回事：
    /// 后者描述资产字段的语义版本，这里描述表结构本身。
    static let currentUserVersion: Int32 = 1

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    let fileURL: URL

    init(fileURL: URL = CatalogDatabase.defaultFileURL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            throw CatalogDatabaseError.openFailed(message)
        }
        self.handle = handle

        // WAL 让读不阻塞写，崩溃后也能靠日志恢复到最后一次提交。
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
        try createSchemaIfNeeded()
    }

    deinit {
        sqlite3_close(handle)
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("catalog.sqlite")
    }

    // MARK: - 读取

    func loadSnapshot() throws -> CatalogSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var sources: [PhotoSource] = []
        try query("SELECT id, bookmark, display_name, last_known_path, created_at, last_scanned_at, status, asset_count FROM sources;") { statement in
            guard let id = UUID(uuidString: Self.text(statement, 0) ?? "") else { return }
            sources.append(
                PhotoSource(
                    id: id,
                    bookmarkData: Self.blob(statement, 1),
                    displayName: Self.text(statement, 2) ?? "",
                    lastKnownPath: Self.text(statement, 3) ?? "",
                    createdAt: Self.date(statement, 4) ?? .now,
                    lastScannedAt: Self.date(statement, 5),
                    status: PhotoSourceStatus(rawValue: Self.text(statement, 6) ?? "") ?? .ready,
                    assetCount: Int(sqlite3_column_int64(statement, 7))
                )
            )
        }

        var assets: [PhotoAsset] = []
        try query(Self.assetSelect) { statement in
            if let asset = Self.decodeAsset(statement) { assets.append(asset) }
        }

        var snapshot = CatalogSnapshot(sources: sources, assets: assets)
        snapshot.migrateInPlace()
        return snapshot
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        try? query("SELECT COUNT(*) FROM sources;") { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count == 0
    }

    // MARK: - 写入

    /// 整库替换。只用于从 JSON 迁移和测试夹具，日常写入一律走下面的增量方法。
    func replaceAll(with snapshot: CatalogSnapshot) throws {
        try inTransaction {
            try execute("DELETE FROM assets;")
            try execute("DELETE FROM sources;")
            for source in snapshot.sources { try upsertSourceLocked(source) }
            for asset in snapshot.assets { try upsertAssetLocked(asset) }
        }
    }

    func upsertSource(_ source: PhotoSource) throws {
        try inTransaction { try upsertSourceLocked(source) }
    }

    /// 删除来源及其全部资产。资产由外键级联删除。
    func deleteSource(id: UUID) throws {
        try inTransaction {
            let statement = try prepare("DELETE FROM sources WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, id.uuidString)
            try step(statement)
        }
    }

    /// 重扫后整体替换某个来源的资产集合。
    func replaceAssets(_ assets: [PhotoAsset], forSource sourceID: UUID) throws {
        try inTransaction {
            let delete = try prepare("DELETE FROM assets WHERE source_id = ?;")
            Self.bind(delete, 1, sourceID.uuidString)
            try step(delete)
            sqlite3_finalize(delete)
            for asset in assets { try upsertAssetLocked(asset) }
        }
    }

    /// 只更新用户可改的那些字段。评分、标记这类高频改动走这里，
    /// 一次改动就是一行 UPDATE，不再重写整份 Catalog。
    func updateAssetMetadata(_ assets: [PhotoAsset]) throws {
        guard !assets.isEmpty else { return }
        try inTransaction {
            let statement = try prepare("""
                UPDATE assets SET rating = ?, flag = ?, color_label = ?, comment = ?,
                    is_favorite = ?, edit_recipe = ?, ocr_text = ?, exported_at = ?
                WHERE id = ?;
                """)
            defer { sqlite3_finalize(statement) }
            for asset in assets {
                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, Int64(asset.rating))
                Self.bind(statement, 2, asset.flag.rawValue)
                Self.bind(statement, 3, asset.colorLabel)
                Self.bind(statement, 4, asset.comment)
                sqlite3_bind_int64(statement, 5, asset.isFavorite ? 1 : 0)
                Self.bind(statement, 6, Self.encodeRecipe(asset.editRecipe))
                Self.bind(statement, 7, asset.ocrText)
                Self.bind(statement, 8, asset.exportedAt)
                Self.bind(statement, 9, asset.id.uuidString)
                try step(statement)
            }
        }
    }

    func deleteAssets(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try inTransaction {
            let statement = try prepare("DELETE FROM assets WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                Self.bind(statement, 1, id.uuidString)
                try step(statement)
            }
        }
    }

    // MARK: - 内部

    private func createSchemaIfNeeded() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,
                bookmark BLOB NOT NULL,
                display_name TEXT NOT NULL,
                last_known_path TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_scanned_at REAL,
                status TEXT NOT NULL,
                asset_count INTEGER NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                filename TEXT NOT NULL,
                file_extension TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                modified_at REAL,
                capture_date REAL,
                width INTEGER,
                height INTEGER,
                camera_make TEXT,
                camera_model TEXT,
                lens TEXT,
                focal_length TEXT,
                aperture TEXT,
                shutter_speed TEXT,
                iso INTEGER,
                media_type TEXT NOT NULL,
                raw_type TEXT,
                rating INTEGER NOT NULL DEFAULT 0,
                flag TEXT NOT NULL DEFAULT 'none',
                color_label TEXT NOT NULL DEFAULT '',
                comment TEXT NOT NULL DEFAULT '',
                is_favorite INTEGER NOT NULL DEFAULT 0,
                edit_recipe TEXT,
                ocr_text TEXT,
                exported_at REAL,
                UNIQUE(source_id, relative_path)
            );
            """)
        // 资产身份是 source_id + relative_path，重扫时按它复用既有 ID。
        try execute("CREATE INDEX IF NOT EXISTS assets_by_source ON assets(source_id);")
        // 老库补列。SQLite 没有 IF NOT EXISTS，重复执行会报错，忽略即可。
        try? execute("ALTER TABLE assets ADD COLUMN exported_at REAL;")
        try execute("PRAGMA user_version = \(Self.currentUserVersion);")
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func upsertSourceLocked(_ source: PhotoSource) throws {
        let statement = try prepare("""
            INSERT INTO sources (id, bookmark, display_name, last_known_path, created_at, last_scanned_at, status, asset_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                bookmark = excluded.bookmark,
                display_name = excluded.display_name,
                last_known_path = excluded.last_known_path,
                created_at = excluded.created_at,
                last_scanned_at = excluded.last_scanned_at,
                status = excluded.status,
                asset_count = excluded.asset_count;
            """)
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, source.id.uuidString)
        Self.bind(statement, 2, source.bookmarkData)
        Self.bind(statement, 3, source.displayName)
        Self.bind(statement, 4, source.lastKnownPath)
        Self.bind(statement, 5, source.createdAt)
        Self.bind(statement, 6, source.lastScannedAt)
        Self.bind(statement, 7, source.status.rawValue)
        sqlite3_bind_int64(statement, 8, Int64(source.assetCount))
        try step(statement)
    }

    private func upsertAssetLocked(_ asset: PhotoAsset) throws {
        let statement = try prepare("""
            INSERT INTO assets (
                id, source_id, relative_path, filename, file_extension, file_size,
                modified_at, capture_date, width, height, camera_make, camera_model,
                lens, focal_length, aperture, shutter_speed, iso, media_type, raw_type,
                rating, flag, color_label, comment, is_favorite, edit_recipe, ocr_text,
                exported_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_id = excluded.source_id, relative_path = excluded.relative_path,
                filename = excluded.filename, file_extension = excluded.file_extension,
                file_size = excluded.file_size, modified_at = excluded.modified_at,
                capture_date = excluded.capture_date, width = excluded.width, height = excluded.height,
                camera_make = excluded.camera_make, camera_model = excluded.camera_model,
                lens = excluded.lens, focal_length = excluded.focal_length,
                aperture = excluded.aperture, shutter_speed = excluded.shutter_speed,
                iso = excluded.iso, media_type = excluded.media_type, raw_type = excluded.raw_type,
                rating = excluded.rating, flag = excluded.flag, color_label = excluded.color_label,
                comment = excluded.comment, is_favorite = excluded.is_favorite,
                edit_recipe = excluded.edit_recipe, ocr_text = excluded.ocr_text,
                exported_at = excluded.exported_at;
            """)
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, asset.id.uuidString)
        Self.bind(statement, 2, asset.sourceID.uuidString)
        Self.bind(statement, 3, asset.relativePath)
        Self.bind(statement, 4, asset.filename)
        Self.bind(statement, 5, asset.fileExtension)
        sqlite3_bind_int64(statement, 6, asset.fileSize)
        Self.bind(statement, 7, asset.modifiedAt)
        Self.bind(statement, 8, asset.captureDate)
        Self.bind(statement, 9, asset.width)
        Self.bind(statement, 10, asset.height)
        Self.bind(statement, 11, asset.cameraMake)
        Self.bind(statement, 12, asset.cameraModel)
        Self.bind(statement, 13, asset.lens)
        Self.bind(statement, 14, asset.focalLength)
        Self.bind(statement, 15, asset.aperture)
        Self.bind(statement, 16, asset.shutterSpeed)
        Self.bind(statement, 17, asset.iso)
        Self.bind(statement, 18, asset.mediaType.rawValue)
        Self.bind(statement, 19, asset.rawType)
        sqlite3_bind_int64(statement, 20, Int64(asset.rating))
        Self.bind(statement, 21, asset.flag.rawValue)
        Self.bind(statement, 22, asset.colorLabel)
        Self.bind(statement, 23, asset.comment)
        sqlite3_bind_int64(statement, 24, asset.isFavorite ? 1 : 0)
        Self.bind(statement, 25, Self.encodeRecipe(asset.editRecipe))
        Self.bind(statement, 26, asset.ocrText)
        Self.bind(statement, 27, asset.exportedAt)
        try step(statement)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CatalogDatabaseError.executionFailed(lastErrorMessage, sql)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CatalogDatabaseError.executionFailed(lastErrorMessage, sql)
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw CatalogDatabaseError.executionFailed(lastErrorMessage, "step")
        }
    }

    private func query(_ sql: String, row: (OpaquePointer) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
    }
}

enum CatalogDatabaseError: LocalizedError {
    case openFailed(String)
    case executionFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "无法打开 Catalog 数据库：\(message)"
        case let .executionFailed(message, sql): "Catalog 数据库操作失败：\(message)（\(sql)）"
        }
    }
}

// MARK: - 绑定与解码

private extension CatalogDatabase {
    /// SQLite 需要知道字符串在 step 之前会不会失效。这里一律按"会失效"处理，
    /// 让它自己复制一份，避免 Swift 字符串的临时缓冲区被提前释放。
    static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    static let assetSelect = """
        SELECT id, source_id, relative_path, filename, file_extension, file_size,
               modified_at, capture_date, width, height, camera_make, camera_model,
               lens, focal_length, aperture, shutter_speed, iso, media_type, raw_type,
               rating, flag, color_label, comment, is_favorite, edit_recipe, ocr_text,
               exported_at
        FROM assets;
        """

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Date?) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSinceReferenceDate)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
        if value.isEmpty {
            // 空 Data 传空指针会被当成 NULL，而书签列是 NOT NULL。
            sqlite3_bind_zeroblob(statement, index, 0)
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
        }
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    static func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }

    static func integer(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    /// `EditRecipe` 仍以 JSON 存一列：它是嵌套结构且已有版本迁移逻辑，
    /// 拆成表列只会把那套迁移复制一遍。
    static func encodeRecipe(_ recipe: EditRecipe?) -> String? {
        guard let recipe, let data = try? JSONEncoder().encode(recipe) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeRecipe(_ text: String?) -> EditRecipe? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditRecipe.self, from: data)
    }

    static func decodeAsset(_ statement: OpaquePointer) -> PhotoAsset? {
        guard let id = UUID(uuidString: text(statement, 0) ?? ""),
              let sourceID = UUID(uuidString: text(statement, 1) ?? "") else {
            return nil
        }
        var asset = PhotoAsset(
            id: id,
            sourceID: sourceID,
            relativePath: text(statement, 2) ?? "",
            filename: text(statement, 3) ?? "",
            fileExtension: text(statement, 4) ?? "",
            fileSize: sqlite3_column_int64(statement, 5),
            modifiedAt: date(statement, 6),
            captureDate: date(statement, 7),
            width: integer(statement, 8),
            height: integer(statement, 9),
            cameraMake: text(statement, 10),
            cameraModel: text(statement, 11),
            lens: text(statement, 12),
            focalLength: text(statement, 13),
            aperture: text(statement, 14),
            shutterSpeed: text(statement, 15),
            iso: integer(statement, 16),
            mediaType: PhotoMediaType(rawValue: text(statement, 17) ?? "") ?? .image,
            rawType: text(statement, 18),
            rating: Int(sqlite3_column_int64(statement, 19)),
            flag: PhotoFlag(rawValue: text(statement, 20) ?? "") ?? .none,
            isFavorite: sqlite3_column_int64(statement, 23) != 0
        )
        asset.colorLabel = text(statement, 21) ?? ""
        asset.comment = text(statement, 22) ?? ""
        asset.editRecipe = decodeRecipe(text(statement, 24))
        asset.ocrText = text(statement, 25)
        asset.exportedAt = date(statement, 26)
        return asset
    }
}
