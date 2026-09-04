import Foundation

/// 一次 Catalog 写操作。
///
/// 改成 SQLite 之后写入按操作而不是按快照描述：每个操作只碰它涉及的那几行。
/// 这也是"连续改评分不再重写整份 Catalog"的直接来源。
enum CatalogWrite: Sendable {
    case upsertSource(PhotoSource)
    case deleteSource(UUID)
    case replaceAssets([PhotoAsset], UUID)
    case updateAssets([PhotoAsset])
    case deleteAssets(Set<UUID>)

    func apply(to database: CatalogDatabase) throws {
        switch self {
        case let .upsertSource(source):
            try database.upsertSource(source)
        case let .deleteSource(id):
            try database.deleteSource(id: id)
        case let .replaceAssets(assets, sourceID):
            try database.replaceAssets(assets, forSource: sourceID)
        case let .updateAssets(assets):
            try database.updateAssetMetadata(assets)
        case let .deleteAssets(ids):
            try database.deleteAssets(ids: ids)
        }
    }
}

/// 打开 Catalog 数据库，必要时把既有的 JSON 快照迁进来。
enum CatalogMigration {
    /// 迁移完成后原 JSON 会被改名保留，而不是删除。
    ///
    /// 它是这台机器上唯一一份迁移前的完整记录：评分、标记、调整配方都在里面。
    /// 迁移逻辑再怎么测过，也不该在用户第一次启动新版本时就把退路砍掉。
    static let legacyBackupSuffix = "pre-sqlite.bak"

    /// - Parameter legacyJSONURL: 旧的 `catalog.json` 路径。数据库取同目录的
    ///   同名 `.sqlite`，这样测试与默认路径都不必各自再拼一次。
    static func openDatabase(legacyJSONURL: URL) throws -> CatalogDatabase {
        let databaseURL = databaseURL(forLegacyJSON: legacyJSONURL)
        let database = try CatalogDatabase(fileURL: databaseURL)

        // 只在数据库还是空的时候迁移。之后 JSON 备份就只是备份，不再参与读取，
        // 否则用户在新版本里的改动会被旧文件反复覆盖。
        guard database.isEmpty,
              FileManager.default.fileExists(atPath: legacyJSONURL.path) else {
            return database
        }

        let snapshot = try CatalogPersistence(fileURL: legacyJSONURL).load()
        guard !snapshot.sources.isEmpty || !snapshot.assets.isEmpty else { return database }
        try database.replaceAll(with: snapshot)
        archiveLegacyFile(at: legacyJSONURL)
        return database
    }

    static func databaseURL(forLegacyJSON legacyJSONURL: URL) -> URL {
        legacyJSONURL.deletingPathExtension().appendingPathExtension("sqlite")
    }

    static func legacyBackupURL(forLegacyJSON legacyJSONURL: URL) -> URL {
        legacyJSONURL.appendingPathExtension(legacyBackupSuffix)
    }

    private static func archiveLegacyFile(at url: URL) {
        let backupURL = legacyBackupURL(forLegacyJSON: url)
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: url, to: backupURL)
        // `.bak` 恢复文件迁移后同样失去意义，一并归档掉，免得下次启动被当成待迁移数据。
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
    }
}
