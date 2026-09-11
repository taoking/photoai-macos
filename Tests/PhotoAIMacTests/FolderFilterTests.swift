import Foundation
import Testing
@testable import PhotoAIMac

struct FolderFilterPathTests {
    @Test
    func directoryIsTakenFromTheRelativePath() {
        #expect(FolderFilter.directory(of: "2026/新疆/DSC1.ARW") == "2026/新疆")
        #expect(FolderFilter.directory(of: "照片_002/DSC1.JPG") == "照片_002")
        // 根目录下的照片归入空串这一档，而不是被漏掉。
        #expect(FolderFilter.directory(of: "DSC1.ARW") == "")
    }

    @Test
    func sectionsGroupBySourceAndDirectoryWithCounts() {
        let first = makeSource(name: "喀拉峻photo")
        let second = makeSource(name: "101MSDCF")
        let assets = [
            makeAsset(sourceID: first.id, path: "photo/A.JPG"),
            makeAsset(sourceID: first.id, path: "photo/B.JPG"),
            makeAsset(sourceID: first.id, path: "goodphoto/C.JPG"),
            makeAsset(sourceID: second.id, path: "D.JPG")
        ]

        let sections = FolderSectionBuilder.sections(for: assets, sources: [first, second])

        #expect(sections.map(\.sourceName) == ["喀拉峻photo", "101MSDCF"])
        #expect(sections[0].count == 3)
        #expect(sections[0].folders.map(\.directory) == ["goodphoto", "photo"])
        #expect(sections[0].folders.first { $0.directory == "photo" }?.count == 2)
        // 根目录显示成可读的名字，而不是空白一行。
        #expect(sections[1].folders.map(\.title) == ["（根目录）"])
        // 各级计数自洽。
        #expect(sections[0].count == sections[0].folders.reduce(0) { $0 + $1.count })
        // 一级文件夹的筛选条件指向整个来源。
        #expect(sections[0].filter == FolderFilter(sourceID: first.id, directory: nil))
    }

    /// 一级文件夹（来源本身）可筛选：选中它就是这个来源下的全部照片，含所有子目录。
    @Test
    func selectingTheSourceLevelMatchesEveryFolderBeneathIt() {
        let source = makeSource(name: "101MSDCF")
        let other = makeSource(name: "别的卷")
        let wholeSource = FolderFilter(sourceID: source.id, directory: nil)

        #expect(wholeSource.matches(makeAsset(sourceID: source.id, path: "照片_016/A.ARW")))
        #expect(wholeSource.matches(makeAsset(sourceID: source.id, path: "照片_002/B.ARW")))
        // 根目录下的也算在内。
        #expect(wholeSource.matches(makeAsset(sourceID: source.id, path: "C.ARW")))
        // 但不跨来源。
        #expect(!wholeSource.matches(makeAsset(sourceID: other.id, path: "照片_016/D.ARW")))

        // 子目录仍然只匹配自己那一层。
        let subfolder = FolderFilter(sourceID: source.id, directory: "照片_016")
        #expect(subfolder.matches(makeAsset(sourceID: source.id, path: "照片_016/A.ARW")))
        #expect(!subfolder.matches(makeAsset(sourceID: source.id, path: "照片_002/B.ARW")))
    }

    /// 没有资产的来源不该在侧边栏占一行。
    @Test
    func sourcesWithoutAssetsAreOmitted() {
        let used = makeSource(name: "有照片")
        let empty = makeSource(name: "空的")
        let sections = FolderSectionBuilder.sections(
            for: [makeAsset(sourceID: used.id, path: "A.JPG")],
            sources: [used, empty]
        )
        #expect(sections.map(\.sourceName) == ["有照片"])
    }

    private func makeSource(name: String) -> PhotoSource {
        PhotoSource(
            id: UUID(), bookmarkData: Data(), displayName: name, lastKnownPath: "/\(name)",
            createdAt: .now, lastScannedAt: nil, status: .ready, assetCount: 0
        )
    }

    private func makeAsset(sourceID: UUID, path: String) -> PhotoAsset {
        PhotoAsset(
            id: UUID(), sourceID: sourceID, relativePath: path,
            filename: (path as NSString).lastPathComponent,
            fileExtension: (path as NSString).pathExtension.lowercased(),
            fileSize: 1, modifiedAt: nil, captureDate: nil,
            width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil,
            focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil,
            mediaType: .image, rawType: nil, rating: 0, flag: .none, isFavorite: false
        )
    }
}

@MainActor
struct FolderFilterCompositionTests {
    /// 这正是"打完分之后既能按文件夹也能按星级找回来"所依赖的：
    /// 文件夹、日期、星级三者正交，可以同时生效。
    @Test
    func folderComposesWithDateAndRatingFilters() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = PhotoSource(
            id: UUID(), bookmarkData: Data(), displayName: "卷",
            lastKnownPath: directory.path, createdAt: .now, lastScannedAt: nil,
            status: .ready, assetCount: 4
        )
        let store = CatalogStore(
            snapshot: CatalogSnapshot(sources: [source], assets: [
                makeAsset(sourceID: source.id, path: "好片/A.JPG", month: 7, rating: 4),
                makeAsset(sourceID: source.id, path: "好片/B.JPG", month: 7, rating: 2),
                makeAsset(sourceID: source.id, path: "好片/C.JPG", month: 6, rating: 4),
                makeAsset(sourceID: source.id, path: "备份/D.JPG", month: 7, rating: 4)
            ]),
            storageURL: directory.appendingPathComponent("catalog.json"),
            derivedImageCache: DerivedImageCache(rootURL: directory.appendingPathComponent("Derived"))
        )

        #expect(store.assets(for: .allPhotos).count == 4)

        store.setFolderFilter(FolderFilter(sourceID: source.id, directory: "好片"))
        #expect(Set(store.assets(for: .allPhotos).map(\.filename)) == ["A.JPG", "B.JPG", "C.JPG"])

        // 叠加四星：只剩好片里的四星。
        #expect(store.assets(for: .allPhotos, filter: .fourStars).map(\.filename).sorted() == ["A.JPG", "C.JPG"])

        // 再叠加日期：三者同时生效。
        store.setDateBucket(.month(year: 2026, month: 7))
        #expect(store.assets(for: .allPhotos, filter: .fourStars).map(\.filename) == ["A.JPG"])

        // 切到一级文件夹：该来源下全部子目录都算进来。
        store.setDateBucket(nil)
        store.setFolderFilter(FolderFilter(sourceID: source.id, directory: nil))
        #expect(store.assets(for: .allPhotos).count == 4)

        // 全部筛选清空后，四星是跨文件夹、跨月份的三张。
        store.setFolderFilter(nil)
        #expect(
            store.assets(for: .allPhotos, filter: .fourStars).map(\.filename).sorted()
                == ["A.JPG", "C.JPG", "D.JPG"]
        )
    }

    /// 查询缓存必须把文件夹算进键里，否则切换文件夹会读到上一次的结果。
    @Test
    func switchingFoldersDoesNotReturnStaleCachedResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-FolderCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = PhotoSource(
            id: UUID(), bookmarkData: Data(), displayName: "卷",
            lastKnownPath: directory.path, createdAt: .now, lastScannedAt: nil,
            status: .ready, assetCount: 2
        )
        let store = CatalogStore(
            snapshot: CatalogSnapshot(sources: [source], assets: [
                makeAsset(sourceID: source.id, path: "一/A.JPG", month: 7, rating: 0),
                makeAsset(sourceID: source.id, path: "二/B.JPG", month: 7, rating: 0)
            ]),
            storageURL: directory.appendingPathComponent("catalog.json"),
            derivedImageCache: DerivedImageCache(rootURL: directory.appendingPathComponent("Derived"))
        )

        store.setFolderFilter(FolderFilter(sourceID: source.id, directory: "一"))
        #expect(store.assets(for: .allPhotos).map(\.filename) == ["A.JPG"])
        store.setFolderFilter(FolderFilter(sourceID: source.id, directory: "二"))
        #expect(store.assets(for: .allPhotos).map(\.filename) == ["B.JPG"])
    }

    private func makeAsset(sourceID: UUID, path: String, month: Int, rating: Int) -> PhotoAsset {
        var asset = PhotoAsset(
            id: UUID(), sourceID: sourceID, relativePath: path,
            filename: (path as NSString).lastPathComponent, fileExtension: "jpg",
            fileSize: 1, modifiedAt: nil,
            captureDate: DateBucket.calendar.date(from: DateComponents(year: 2026, month: month, day: 1)),
            width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil,
            focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil,
            mediaType: .image, rawType: nil, rating: rating, flag: .none, isFavorite: false
        )
        asset.rating = rating
        return asset
    }
}
