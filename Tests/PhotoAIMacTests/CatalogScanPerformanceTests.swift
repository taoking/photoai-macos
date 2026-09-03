import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct CatalogScanPerformanceTests {
    // MARK: - 并行扫描

    @Test
    func concurrentScanMatchesSerialScanAndReportsProgressToCompletion() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let nestedURL = rootURL.appendingPathComponent("2026/新疆", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        for index in 0..<50 {
            let directory = index.isMultiple(of: 2) ? rootURL : nestedURL
            try Data([0xFF, 0xD8, 0xFF]).write(
                to: directory.appendingPathComponent(String(format: "DSC%05d.JPG", index))
            )
        }
        try Data("not a photo".utf8).write(to: rootURL.appendingPathComponent("notes.txt"))

        let sourceID = UUID()
        let serial = try CatalogScanner.scan(sourceID: sourceID, rootURL: rootURL)

        let batches = BatchRecorder()
        let concurrent = try await CatalogScanner.scanConcurrently(
            sourceID: sourceID,
            rootURL: rootURL,
            concurrency: 4,
            batchSize: 8
        ) { batch in
            await batches.record(batch)
        }

        // 并行只改变读取方式，不能改变结果集与最终顺序。
        #expect(concurrent.map(\.relativePath) == serial.map(\.relativePath))
        #expect(concurrent.count == 50)

        let recorded = await batches.batches
        #expect(recorded.allSatisfy { $0.total == 50 })
        #expect(recorded.last?.scanned == 50)
        #expect(recorded.map(\.assets.count).reduce(0, +) == 50)
        // 进度必须单调递增，否则界面上的数字会来回跳。
        #expect(recorded.map(\.scanned) == recorded.map(\.scanned).sorted())
    }

    // MARK: - 重扫跳过未变文件

    @Test
    func unchangedFilesReuseThePreviousIndexInsteadOfRereadingMetadata() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("DSC00001.JPG")
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)

        let sourceID = UUID()
        let firstPass = try CatalogScanner.scan(sourceID: sourceID, rootURL: rootURL)
        let indexed = try #require(firstPass.first)

        // cameraModel 只可能来自读取 EXIF。把它换成哨兵值后重扫：
        // 哨兵仍在，就说明这个文件的整次 EXIF 读取被跳过了。
        let sentinel = makeSentinel(from: indexed)
        let reused = try CatalogScanner.scan(
            sourceID: sourceID,
            rootURL: rootURL,
            reusableAssets: [indexed.relativePath: sentinel]
        )
        #expect(reused.first?.cameraModel == "REUSED-WITHOUT-EXIF-READ")
        #expect(reused.first?.id == sentinel.id)
    }

    @Test
    func changedFilesAreReadAgainInsteadOfReused() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("DSC00002.JPG")
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)

        let sourceID = UUID()
        let indexed = try #require(try CatalogScanner.scan(sourceID: sourceID, rootURL: rootURL).first)

        // 文件变大了：必须重新读取，不能复用旧记录。
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]).write(to: fileURL)
        let rescanned = try CatalogScanner.scan(
            sourceID: sourceID,
            rootURL: rootURL,
            reusableAssets: [indexed.relativePath: makeSentinel(from: indexed)]
        )
        #expect(rescanned.first?.cameraModel != "REUSED-WITHOUT-EXIF-READ")
    }

    @Test
    func catalogStoreFeedsThePreviousIndexBackIntoRescan() async throws {
        // 验证接线：CatalogStore 确实把上一次的索引交给了扫描器。
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("DSC00003.JPG")
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)
        let catalogURL = rootURL.appendingPathComponent("catalog.json")

        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(rootURL)
        let indexed = try #require(store.assets.first)

        let seeded = CatalogStore(
            snapshot: CatalogSnapshot(sources: store.sources, assets: [makeSentinel(from: indexed)]),
            storageURL: catalogURL
        )
        await seeded.rescan(try #require(seeded.sources.first?.id))

        #expect(seeded.assets.first?.cameraModel == "REUSED-WITHOUT-EXIF-READ")
    }

    // MARK: - 写入合并

    @Test
    func rapidMetadataChangesCoalesceIntoASingleWrite() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("DSC00004.JPG")
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)
        let catalogURL = rootURL.appendingPathComponent("catalog.json")

        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(rootURL)
        await store.flushPendingPersist()
        let baseline = await store.persistWriteCount
        let assetID = try #require(store.assets.first?.id)

        // 模拟筛片时连续按星级：20 次改动不应该写 20 遍整份 Catalog。
        for rating in 0..<20 {
            store.setRating(rating % 6, for: [assetID])
        }
        await store.flushPendingPersist()

        let writes = await store.persistWriteCount - baseline
        #expect(writes <= 2, "20 次连续改动产生了 \(writes) 次整表写入")

        let restored = CatalogStore(storageURL: catalogURL)
        #expect(restored.asset(withID: assetID)?.rating == 19 % 6)
    }

    // MARK: - Fixtures

    private func makeSentinel(from asset: PhotoAsset) -> PhotoAsset {
        PhotoAsset(
            id: asset.id,
            sourceID: asset.sourceID,
            relativePath: asset.relativePath,
            filename: asset.filename,
            fileExtension: asset.fileExtension,
            fileSize: asset.fileSize,
            modifiedAt: asset.modifiedAt,
            captureDate: asset.captureDate,
            width: asset.width,
            height: asset.height,
            cameraMake: asset.cameraMake,
            cameraModel: "REUSED-WITHOUT-EXIF-READ",
            lens: asset.lens,
            focalLength: asset.focalLength,
            aperture: asset.aperture,
            shutterSpeed: asset.shutterSpeed,
            iso: asset.iso,
            mediaType: asset.mediaType,
            rawType: asset.rawType,
            rating: asset.rating,
            flag: asset.flag,
            isFavorite: asset.isFavorite
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor BatchRecorder {
    private(set) var batches: [CatalogScanner.ScanBatch] = []

    func record(_ batch: CatalogScanner.ScanBatch) {
        batches.append(batch)
    }
}

@MainActor
struct TransientScanStateTests {
    /// 扫描进行中退出 App 会把 `.scanning` 写进快照。若不归位，
    /// 下次启动会看到一个永远停在"正在扫描"的来源。
    @Test
    func scanningStatusNeverSurvivesReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Transient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogURL = directory.appendingPathComponent("catalog.json")

        let source = PhotoSource(
            id: UUID(),
            bookmarkData: Data(),
            displayName: "中途退出的来源",
            lastKnownPath: directory.path,
            createdAt: .now,
            lastScannedAt: nil,
            status: .scanning,
            assetCount: 0
        )
        try CatalogPersistence(fileURL: catalogURL).save(CatalogSnapshot(sources: [source], assets: []))

        let restored = CatalogStore(storageURL: catalogURL)
        #expect(restored.sources.first?.status == .ready)
    }
}
