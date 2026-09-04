import Foundation
import Testing
@testable import PhotoAIMac

struct DateBucketTests {
    @Test
    func yearAndMonthBucketsMatchCaptureDate() {
        let asset = makeAsset(captureDate: date(2026, 7, 19))

        #expect(DateBucket.year(2026).matches(asset))
        #expect(DateBucket.month(year: 2026, month: 7).matches(asset))
        #expect(!DateBucket.year(2025).matches(asset))
        #expect(!DateBucket.month(year: 2026, month: 6).matches(asset))
        #expect(!DateBucket.undated.matches(asset))
    }

    /// 没有拍摄时间的照片单独成桶，而不是从所有日期里静默消失——
    /// 否则用户按日期筛选时会觉得照片凭空少了几张。本机 1,874 项里有 12 项如此。
    @Test
    func assetsWithoutCaptureDateLandInTheUndatedBucket() {
        let asset = makeAsset(captureDate: nil)

        #expect(DateBucket.undated.matches(asset))
        #expect(!DateBucket.year(2026).matches(asset))
        #expect(!DateBucket.month(year: 2026, month: 7).matches(asset))
    }

    @Test
    func sectionsAreGroupedAndCountedNewestFirst() {
        let assets = [
            makeAsset(captureDate: date(2026, 7, 19)),
            makeAsset(captureDate: date(2026, 7, 20)),
            makeAsset(captureDate: date(2026, 6, 1)),
            makeAsset(captureDate: date(2025, 12, 31)),
            makeAsset(captureDate: nil)
        ]

        let grouped = DateSectionBuilder.sections(for: assets)

        // 年份倒序，与图库默认的"新的在前"一致。
        #expect(grouped.sections.map(\.year) == [2026, 2025])
        #expect(grouped.sections[0].count == 3)
        #expect(grouped.sections[0].months.map(\.month) == [7, 6])
        #expect(grouped.sections[0].months[0].count == 2)
        #expect(grouped.sections[1].count == 1)
        #expect(grouped.undatedCount == 1)
    }

    @Test
    func emptyLibraryProducesNoSections() {
        let grouped = DateSectionBuilder.sections(for: [])
        #expect(grouped.sections.isEmpty)
        #expect(grouped.undatedCount == 0)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateBucket.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeAsset(captureDate: Date?) -> PhotoAsset {
        PhotoAsset(
            id: UUID(), sourceID: UUID(), relativePath: "a.jpg", filename: "a.jpg",
            fileExtension: "jpg", fileSize: 1, modifiedAt: nil, captureDate: captureDate,
            width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil,
            focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil,
            mediaType: .image, rawType: nil, rating: 0, flag: .none, isFavorite: false
        )
    }
}

@MainActor
struct DateFilteringTests {
    /// 日期与既有筛选正交：日期决定"看哪一段时间"，筛选决定"看其中的哪些"。
    @Test
    func dateBucketComposesWithTheExistingFilter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Date-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = PhotoSource(
            id: UUID(), bookmarkData: Data(), displayName: "卷",
            lastKnownPath: directory.path, createdAt: .now, lastScannedAt: nil,
            status: .ready, assetCount: 3
        )
        let july = makeAsset(sourceID: source.id, name: "JULY.JPG", month: 7, rating: 5)
        let julyUnrated = makeAsset(sourceID: source.id, name: "JULY2.JPG", month: 7, rating: 0)
        let june = makeAsset(sourceID: source.id, name: "JUNE.JPG", month: 6, rating: 5)

        let store = CatalogStore(
            snapshot: CatalogSnapshot(sources: [source], assets: [july, julyUnrated, june]),
            storageURL: directory.appendingPathComponent("catalog.json"),
            derivedImageCache: DerivedImageCache(rootURL: directory.appendingPathComponent("Derived"))
        )

        #expect(store.assets(for: .allPhotos).count == 3)

        store.setDateBucket(.month(year: 2026, month: 7))
        #expect(Set(store.assets(for: .allPhotos).map(\.filename)) == ["JULY.JPG", "JULY2.JPG"])

        // 叠加五星筛选：两者同时生效。
        #expect(store.assets(for: .allPhotos, filter: .fiveStars).map(\.filename) == ["JULY.JPG"])

        store.setDateBucket(nil)
        #expect(store.assets(for: .allPhotos).count == 3)
    }

    /// 查询缓存必须把日期算进键里，否则切换月份会读到上一次的结果。
    @Test
    func switchingBucketsDoesNotReturnStaleCachedResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-DateCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = PhotoSource(
            id: UUID(), bookmarkData: Data(), displayName: "卷",
            lastKnownPath: directory.path, createdAt: .now, lastScannedAt: nil,
            status: .ready, assetCount: 2
        )
        let store = CatalogStore(
            snapshot: CatalogSnapshot(
                sources: [source],
                assets: [
                    makeAsset(sourceID: source.id, name: "A.JPG", month: 7, rating: 0),
                    makeAsset(sourceID: source.id, name: "B.JPG", month: 6, rating: 0)
                ]
            ),
            storageURL: directory.appendingPathComponent("catalog.json"),
            derivedImageCache: DerivedImageCache(rootURL: directory.appendingPathComponent("Derived"))
        )

        store.setDateBucket(.month(year: 2026, month: 7))
        #expect(store.assets(for: .allPhotos).map(\.filename) == ["A.JPG"])
        store.setDateBucket(.month(year: 2026, month: 6))
        #expect(store.assets(for: .allPhotos).map(\.filename) == ["B.JPG"])
    }

    private func makeAsset(sourceID: UUID, name: String, month: Int, rating: Int) -> PhotoAsset {
        var asset = PhotoAsset(
            id: UUID(), sourceID: sourceID, relativePath: name, filename: name,
            fileExtension: "jpg", fileSize: 1, modifiedAt: nil,
            captureDate: DateBucket.calendar.date(from: DateComponents(year: 2026, month: month, day: 1)),
            width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil,
            focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil,
            mediaType: .image, rawType: nil, rating: rating, flag: .none, isFavorite: false
        )
        asset.rating = rating
        return asset
    }
}

@MainActor
struct ExportTrackingTests {
    /// 选片的实际形态是"选一批 → 导出 → 下次再选"。没有导出标记，
    /// 第二轮就分不清哪些已经处理过了。
    @Test
    func successfulExportsAreRecordedAndSurviveReload() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Export-\(UUID().uuidString)", isDirectory: true)
        let photos = container.appendingPathComponent("卷", isDirectory: true)
        let destination = container.appendingPathComponent("目标", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try Data([0xFF, 0xD8, 0xFF]).write(to: photos.appendingPathComponent("A.JPG"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: photos.appendingPathComponent("B.JPG"))

        let catalogURL = container.appendingPathComponent("catalog.json")
        let store = CatalogStore(
            storageURL: catalogURL,
            derivedImageCache: DerivedImageCache(rootURL: container.appendingPathComponent("Derived"))
        )
        await store.addFolder(photos)
        let exportedAsset = try #require(store.assets.first { $0.filename == "A.JPG" })
        let untouched = try #require(store.assets.first { $0.filename == "B.JPG" })

        #expect(store.assets(for: .allPhotos, filter: .notExported).count == 2)

        let exporter = OriginalPhotoExportStore()
        exporter.onAssetsExported = { store.markExported($0) }
        let request = try #require(store.originalExportRequest(for: exportedAsset))
        exporter.startForTesting(requests: [request], destinationURL: destination)
        for _ in 0..<200 where exporter.state != .completed {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await store.flushPendingPersist()

        #expect(store.asset(withID: exportedAsset.id)?.exportedAt != nil)
        #expect(store.asset(withID: untouched.id)?.exportedAt == nil)
        #expect(store.assets(for: .allPhotos, filter: .exported).map(\.filename) == ["A.JPG"])
        #expect(store.assets(for: .allPhotos, filter: .notExported).map(\.filename) == ["B.JPG"])

        // 必须跨重启存活，否则下次进来又分不清了。
        let restored = CatalogStore(
            storageURL: catalogURL,
            derivedImageCache: DerivedImageCache(rootURL: container.appendingPathComponent("Derived"))
        )
        #expect(restored.asset(withID: exportedAsset.id)?.exportedAt != nil)
        #expect(restored.asset(withID: untouched.id)?.exportedAt == nil)
    }
}

@MainActor
struct LibrarySortOrderTests {
    /// 单相机单卡时文件名≈拍摄顺序，但多来源混合时按文件名排会把不同相机、
    /// 不同时期的照片交错，所以默认按拍摄时间。
    @Test
    func captureDateOrderIgnoresFilenameInterleaving() {
        let older = makeAsset(name: "ZZZ_9999.JPG", captureDate: date(2026, 6, 1))
        let newer = makeAsset(name: "AAA_0001.JPG", captureDate: date(2026, 7, 1))

        let sorted = [older, newer].sorted(by: LibrarySortOrder.captureDateDescending.isOrderedBefore)
        #expect(sorted.map(\.filename) == ["AAA_0001.JPG", "ZZZ_9999.JPG"])

        // 文件名排序仍然可选，此时结果相反。
        let byName = [older, newer].sorted(by: LibrarySortOrder.filenameDescending.isOrderedBefore)
        #expect(byName.map(\.filename) == ["ZZZ_9999.JPG", "AAA_0001.JPG"])
    }

    /// 没有拍摄时间的照片排在最后，而不是混进时间序列里。
    @Test
    func undatedAssetsSortLast() {
        let dated = makeAsset(name: "A.JPG", captureDate: date(2026, 1, 1))
        let undated = makeAsset(name: "Z.JPG", captureDate: nil)

        let sorted = [undated, dated].sorted(by: LibrarySortOrder.captureDateDescending.isOrderedBefore)
        #expect(sorted.map(\.filename) == ["A.JPG", "Z.JPG"])
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateBucket.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeAsset(name: String, captureDate: Date?) -> PhotoAsset {
        PhotoAsset(
            id: UUID(), sourceID: UUID(), relativePath: name, filename: name,
            fileExtension: "jpg", fileSize: 1, modifiedAt: nil, captureDate: captureDate,
            width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil,
            focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil,
            mediaType: .image, rawType: nil, rating: 0, flag: .none, isFavorite: false
        )
    }
}
