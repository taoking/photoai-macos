import Foundation

/// 旧的 JSON 快照读写。
///
/// 日常持久化已经交给 `CatalogDatabase`；这里只保留两个用途：把迁移前的
/// `catalog.json` 读进来，以及给测试构造夹具（顺带让测试走一遍真实的迁移路径）。
struct CatalogPersistence: Sendable {
    let fileURL: URL

    init(fileURL: URL = CatalogPersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> CatalogSnapshot {
        let recoveryURL = self.recoveryFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) || FileManager.default.fileExists(atPath: recoveryURL.path) else {
            return .empty
        }

        var primaryError: Error?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                return try decodeSnapshot(at: fileURL)
            } catch {
                primaryError = error
            }
        }
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            return try decodeSnapshot(at: recoveryURL)
        }
        throw primaryError ?? CatalogPersistenceError.unreadableSnapshot
    }

    func save(_ snapshot: CatalogSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 只备份可解码的旧主快照，避免把一次崩溃留下的损坏主文件覆盖最后的有效恢复点。
        if FileManager.default.fileExists(atPath: fileURL.path),
           let oldData = try? Data(contentsOf: fileURL),
           (try? JSONDecoder.photoAICatalog.decode(CatalogSnapshot.self, from: oldData)) != nil {
            try oldData.write(to: recoveryFileURL, options: .atomic)
        }
        var normalized = snapshot
        normalized.migrateInPlace()
        let data = try JSONEncoder.photoAICatalog.encode(normalized)
        try data.write(to: fileURL, options: .atomic)
    }

    var recoveryFileURL: URL {
        fileURL.appendingPathExtension("bak")
    }

    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }

    private func decodeSnapshot(at url: URL) throws -> CatalogSnapshot {
        try JSONDecoder.photoAICatalog.decode(CatalogSnapshot.self, from: Data(contentsOf: url))
    }
}

private enum CatalogPersistenceError: LocalizedError {
    case unreadableSnapshot

    var errorDescription: String? { "无法读取 Catalog 快照。" }
}

private extension JSONEncoder {
    static let photoAICatalog: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let photoAICatalog: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
