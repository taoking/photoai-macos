import Foundation
import Testing
@testable import PhotoAIMac

/// 用真实 `catalog.json` 的副本演练迁移。
///
/// 默认跳过：它依赖本机数据，不是可移植的测试。迁移是一次性的、不可回退的操作，
/// 所以在真正对用户数据执行之前，值得先拿真实数据跑一遍逐字段比对。
@MainActor
struct MigrationDrillTests {
    @Test(
        "RUN: migrate a real catalog.json copy",
        .enabled(
            if: ProcessInfo.processInfo.environment["PHOTOAI_MIGRATION_DRILL"] != nil,
            "SKIPPED: 设置 PHOTOAI_MIGRATION_DRILL=/path/to/catalog.json 以运行本机迁移演练。"
        )
    )
    func migratingARealCatalogPreservesEverything() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PHOTOAI_MIGRATION_DRILL"])
        let jsonURL = URL(fileURLWithPath: path)

        let before = try CatalogPersistence(fileURL: jsonURL).load()
        let migrationStart = Date()
        let database = try CatalogMigration.openDatabase(legacyJSONURL: jsonURL)
        let migrationSeconds = -migrationStart.timeIntervalSinceNow

        let loadStart = Date()
        let after = try database.loadSnapshot()
        let loadSeconds = -loadStart.timeIntervalSinceNow

        let attributes = try? FileManager.default.attributesOfItem(
            atPath: CatalogMigration.databaseURL(forLegacyJSON: jsonURL).path
        )
        let databaseBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        print(String(
            format: "迁移 %d 来源 / %d 资产：写入 %.3fs，读回 %.3fs，数据库 %.2f MB",
            before.sources.count,
            before.assets.count,
            migrationSeconds,
            loadSeconds,
            Double(databaseBytes) / 1e6
        ))

        #expect(after.sources.count == before.sources.count)
        #expect(after.assets.count == before.assets.count)

        // 逐字段比对，而不是只比数量。丢一个评分和丢一整张照片同样是数据损失。
        let originals = Dictionary(uniqueKeysWithValues: before.assets.map { ($0.id, $0) })
        var mismatches: [String] = []
        for asset in after.assets {
            guard let original = originals[asset.id] else {
                mismatches.append("多出资产 \(asset.filename)")
                continue
            }
            if asset != original { mismatches.append("字段不一致：\(asset.filename)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")

        let originalSources = Dictionary(uniqueKeysWithValues: before.sources.map { ($0.id, $0) })
        for source in after.sources {
            let original = try #require(originalSources[source.id])
            #expect(source == original, "来源不一致：\(source.displayName)")
        }
    }
}
