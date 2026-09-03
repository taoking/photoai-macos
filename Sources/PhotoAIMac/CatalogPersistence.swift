import Foundation

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

    /// - Parameter validatesExistingSnapshot: 是否在备份前解码校验旧的主快照。
    ///   解码整份 Catalog 是这次保存里最贵的一步，而只有来自上一次运行的主快照
    ///   才可能是崩溃留下的半截文件。本进程自己编码写出的主快照按构造即有效，
    ///   因此 `CatalogWriter` 只在进程内第一次保存时要求校验。
    func save(_ snapshot: CatalogSnapshot, validatesExistingSnapshot: Bool = true) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 只备份可解码的旧主快照，避免把一次崩溃留下的损坏主文件覆盖最后的有效恢复点。
        if FileManager.default.fileExists(atPath: fileURL.path),
           let oldData = try? Data(contentsOf: fileURL),
           !validatesExistingSnapshot
            || (try? JSONDecoder.photoAICatalog.decode(CatalogSnapshot.self, from: oldData)) != nil {
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

/// Catalog 的写入串行化点。编码与写盘都发生在这个 actor 上，不再占用主线程：
/// 5.96 MB 的 Catalog 每次保存需要读旧文件 + 解码校验 + 编码 + 两次原子写，
/// 此前全部同步跑在 main actor 上，筛片时每改一次评分都会卡顿。
actor CatalogWriter {
    private let persistence: CatalogPersistence
    private var hasValidatedExistingSnapshot = false
    /// 实际落盘次数。供测试断言连续改动被合并成一次写入。
    private(set) var writeCount = 0

    init(persistence: CatalogPersistence) {
        self.persistence = persistence
    }

    func write(_ snapshot: CatalogSnapshot) throws {
        try persistence.save(snapshot, validatesExistingSnapshot: !hasValidatedExistingSnapshot)
        hasValidatedExistingSnapshot = true
        writeCount += 1
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
