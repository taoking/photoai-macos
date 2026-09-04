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
    func rapidMetadataChangesWriteOnlyTheAffectedRows() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("DSC00004.JPG")
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)
        let catalogURL = rootURL.appendingPathComponent("catalog.json")

        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(rootURL)
        await store.flushPendingPersist()
        let baseline = store.persistWriteCount
        let assetID = try #require(store.assets.first?.id)

        // 筛片时连续按星级。改成按行写入之后，每次改动就是一次单行 UPDATE
        // （实测约 0.9 毫秒），不再是把整份 Catalog 重新编码一遍——
        // 后者在 5 万张规模下是 37 MB。这里断言写入次数与改动次数一一对应，
        // 即没有任何一次改动触发了整表重写。
        // 1…5 循环，每一次都与前一次不同，因此是 20 次真实改动。
        for step in 0..<20 {
            store.setRating(step % 5 + 1, for: [assetID])
        }
        await store.flushPendingPersist()

        let writes = store.persistWriteCount - baseline
        #expect(writes == 20, "20 次改动产生了 \(writes) 次写操作")

        // 值没变时根本不该写盘。
        store.setRating(19 % 5 + 1, for: [assetID])
        await store.flushPendingPersist()
        #expect(store.persistWriteCount - baseline == 20, "无变化的改动不应产生写操作")

        let restored = CatalogStore(storageURL: catalogURL)
        #expect(restored.asset(withID: assetID)?.rating == 19 % 5 + 1)
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

@MainActor
struct LibraryOrderingTests {
    /// 图库按文件名倒序：导入的照片文件名与拍摄时间顺序一致，
    /// 倒序等价于最新的排在最前。这是产品决策，必须被钉住——
    /// 此前全库按文件名升序，导致 `before_after_*` 这类旧素材霸占整个首屏，
    /// 真实相机照片要滚过一千多项才出现。
    @Test
    func libraryIsOrderedByFilenameDescending() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for name in ["DSC00001.JPG", "DSC00002.JPG", "DSC00010.JPG", "before_after_01.jpg"] {
            try Data([0xFF, 0xD8, 0xFF]).write(to: rootURL.appendingPathComponent(name))
        }

        let store = CatalogStore(storageURL: rootURL.appendingPathComponent("catalog.json"))
        await store.addFolder(rootURL)

        // 数字按自然序倒排（10 在 2 之前），且旧素材沉到末尾而不是霸占首屏。
        #expect(store.assets.map(\.filename) == [
            "DSC00010.JPG",
            "DSC00002.JPG",
            "DSC00001.JPG",
            "before_after_01.jpg"
        ])
    }

    /// 扫描器与图库必须用同一个顺序，否则"导出当前结果"之类
    /// 依赖顺序的功能会与用户所见不一致。
    @Test
    func scannerAndLibraryAgreeOnOrder() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        for index in 0..<12 {
            try Data([0xFF, 0xD8, 0xFF]).write(
                to: rootURL.appendingPathComponent(String(format: "DSC%05d.JPG", index))
            )
        }

        let scanned = try CatalogScanner.scan(sourceID: UUID(), rootURL: rootURL)
        let store = CatalogStore(storageURL: rootURL.appendingPathComponent("catalog.json"))
        await store.addFolder(rootURL)

        #expect(scanned.map(\.filename) == store.assets.map(\.filename))
    }

    /// 顺序不能依赖磁盘快照里的数组顺序。
    ///
    /// 快照是用写它时的排序规则排好的；规则改变后若直接沿用，新顺序要等到
    /// 下一次重扫才生效。实测症状就是改成倒序后重启，DSC06691 仍排在
    /// DSC06693 前面。
    @Test
    func loadingAnAscendinglyStoredSnapshotStillYieldsDescendingOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogURL = directory.appendingPathComponent("catalog.json")

        let source = PhotoSource(
            id: UUID(),
            bookmarkData: Data(),
            displayName: "旧顺序",
            lastKnownPath: directory.path,
            createdAt: .now,
            lastScannedAt: nil,
            status: .ready,
            assetCount: 3
        )
        // 按旧规则（升序）写入磁盘。
        let ascending = ["DSC06691.ARW", "DSC06692.ARW", "DSC06693.ARW"].map {
            makeAsset(named: $0, sourceID: source.id)
        }
        try CatalogPersistence(fileURL: catalogURL).save(
            CatalogSnapshot(sources: [source], assets: ascending)
        )

        let store = CatalogStore(storageURL: catalogURL)
        #expect(store.assets.map(\.filename) == ["DSC06693.ARW", "DSC06692.ARW", "DSC06691.ARW"])
    }

    private func makeAsset(named filename: String, sourceID: UUID) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: filename,
            filename: filename,
            fileExtension: (filename as NSString).pathExtension.lowercased(),
            fileSize: 1_024,
            modifiedAt: nil,
            captureDate: nil,
            width: nil,
            height: nil,
            cameraMake: nil,
            cameraModel: nil,
            lens: nil,
            focalLength: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            mediaType: .image,
            rawType: "ARW",
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
