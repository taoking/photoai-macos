import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct CatalogDatabaseTests {
    /// 迁移必须无损。这份 JSON 是用户机器上唯一一份迁移前的完整记录，
    /// 评分、标记、颜色标签、备注、调整配方、OCR 文本都在里面。
    @Test
    func migratingFromJSONPreservesEveryField() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("catalog.json")

        let source = makeSource(path: directory.path)
        var asset = makeAsset(sourceID: source.id, filename: "DSC00001.ARW")
        asset.rating = 4
        asset.flag = .pick
        asset.colorLabel = "red"
        asset.comment = "旅行精选"
        asset.isFavorite = true
        asset.ocrText = "识别出的文字"
        var recipe = EditRecipe.identity
        recipe.exposure = 0.75
        recipe.lut = LUTRecipe(presetID: UUID(), intensity: 0.5)
        asset.editRecipe = recipe

        try CatalogPersistence(fileURL: jsonURL).save(
            CatalogSnapshot(sources: [source], assets: [asset])
        )

        let database = try CatalogMigration.openDatabase(legacyJSONURL: jsonURL)
        let snapshot = try database.loadSnapshot()

        let restoredSource = try #require(snapshot.sources.first)
        #expect(restoredSource.id == source.id)
        #expect(restoredSource.bookmarkData == source.bookmarkData)
        #expect(restoredSource.lastKnownPath == source.lastKnownPath)
        #expect(restoredSource.status == source.status)

        let restored = try #require(snapshot.assets.first)
        #expect(restored.id == asset.id)
        #expect(restored.sourceID == asset.sourceID)
        #expect(restored.relativePath == asset.relativePath)
        #expect(restored.fileSize == asset.fileSize)
        #expect(restored.modifiedAt == asset.modifiedAt)
        #expect(restored.captureDate == asset.captureDate)
        #expect(restored.width == asset.width)
        #expect(restored.cameraModel == asset.cameraModel)
        #expect(restored.iso == asset.iso)
        #expect(restored.rawType == asset.rawType)
        #expect(restored.rating == 4)
        #expect(restored.flag == .pick)
        #expect(restored.colorLabel == "red")
        #expect(restored.comment == "旅行精选")
        #expect(restored.isFavorite)
        #expect(restored.ocrText == "识别出的文字")
        #expect(restored.editRecipe == recipe)
    }

    /// 迁移后原 JSON 必须改名保留而不是删除：它是唯一的退路。
    @Test
    func migrationKeepsTheOriginalJSONAsABackup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("catalog.json")
        let source = makeSource(path: directory.path)
        try CatalogPersistence(fileURL: jsonURL).save(
            CatalogSnapshot(sources: [source], assets: [makeAsset(sourceID: source.id, filename: "a.jpg")])
        )

        _ = try CatalogMigration.openDatabase(legacyJSONURL: jsonURL)

        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(FileManager.default.fileExists(
            atPath: CatalogMigration.legacyBackupURL(forLegacyJSON: jsonURL).path
        ))
    }

    /// 迁移只能发生一次。否则用户在新版本里的改动会被旧 JSON 反复覆盖。
    @Test
    func migrationDoesNotRunTwiceAndNeverOverwritesNewerData() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("catalog.json")
        let source = makeSource(path: directory.path)
        var asset = makeAsset(sourceID: source.id, filename: "a.jpg")
        asset.rating = 1
        try CatalogPersistence(fileURL: jsonURL).save(
            CatalogSnapshot(sources: [source], assets: [asset])
        )

        let database = try CatalogMigration.openDatabase(legacyJSONURL: jsonURL)
        var updated = asset
        updated.rating = 5
        try database.updateAssetMetadata([updated])

        // 把旧 JSON 放回原处，模拟用户从备份复制回来或旧版本残留。
        try CatalogPersistence(fileURL: jsonURL).save(
            CatalogSnapshot(sources: [source], assets: [asset])
        )
        let reopened = try CatalogMigration.openDatabase(legacyJSONURL: jsonURL)
        #expect(try reopened.loadSnapshot().assets.first?.rating == 5)
    }

    /// 删除来源必须连带删掉它的资产，否则库里会留下无主记录。
    @Test
    func deletingASourceCascadesToItsAssets() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try CatalogDatabase(fileURL: directory.appendingPathComponent("catalog.sqlite"))

        let kept = makeSource(path: "/kept")
        let removed = makeSource(path: "/removed")
        try database.replaceAll(with: CatalogSnapshot(
            sources: [kept, removed],
            assets: [
                makeAsset(sourceID: kept.id, filename: "keep.jpg"),
                makeAsset(sourceID: removed.id, filename: "drop.jpg")
            ]
        ))

        try database.deleteSource(id: removed.id)
        let snapshot = try database.loadSnapshot()
        #expect(snapshot.sources.map(\.id) == [kept.id])
        #expect(snapshot.assets.allSatisfy { $0.sourceID == kept.id })
    }

    /// 重扫会整体替换某个来源的资产，但不能碰到别的来源。
    @Test
    func replacingAssetsOnlyTouchesTheGivenSource() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try CatalogDatabase(fileURL: directory.appendingPathComponent("catalog.sqlite"))

        let first = makeSource(path: "/first")
        let second = makeSource(path: "/second")
        try database.replaceAll(with: CatalogSnapshot(
            sources: [first, second],
            assets: [
                makeAsset(sourceID: first.id, filename: "old.jpg"),
                makeAsset(sourceID: second.id, filename: "other.jpg")
            ]
        ))

        try database.replaceAssets([makeAsset(sourceID: first.id, filename: "new.jpg")], forSource: first.id)
        let snapshot = try database.loadSnapshot()
        #expect(snapshot.assets.count == 2)
        #expect(snapshot.assets.contains { $0.filename == "new.jpg" })
        #expect(snapshot.assets.contains { $0.filename == "other.jpg" })
        #expect(!snapshot.assets.contains { $0.filename == "old.jpg" })
    }

    /// 空书签必须能原样存取：来源在测试与部分回退路径下会带空 Data，
    /// 而书签列是 NOT NULL，绑定成 NULL 会直接写失败。
    @Test
    func emptyBookmarkDataRoundTrips() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try CatalogDatabase(fileURL: directory.appendingPathComponent("catalog.sqlite"))

        var source = makeSource(path: "/empty")
        source.bookmarkData = Data()
        try database.upsertSource(source)

        #expect(try database.loadSnapshot().sources.first?.bookmarkData.isEmpty == true)
    }

    // MARK: - Fixtures

    private func makeSource(path: String) -> PhotoSource {
        PhotoSource(
            id: UUID(),
            bookmarkData: Data([0x01, 0x02, 0x03]),
            displayName: (path as NSString).lastPathComponent,
            lastKnownPath: path,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            lastScannedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            status: .ready,
            assetCount: 1
        )
    }

    private func makeAsset(sourceID: UUID, filename: String) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: "2026/\(filename)",
            filename: filename,
            fileExtension: (filename as NSString).pathExtension.lowercased(),
            fileSize: 68_600_000,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 3_000),
            captureDate: Date(timeIntervalSinceReferenceDate: 4_000),
            width: 7_008,
            height: 4_672,
            cameraMake: "SONY",
            cameraModel: "ILCE-7RM5",
            lens: "FE 24-70mm",
            focalLength: "35 mm",
            aperture: "f/2.8",
            shutterSpeed: "1/250 s",
            iso: 400,
            mediaType: .image,
            rawType: filename.hasSuffix(".ARW") ? "ARW" : nil,
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-DB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
