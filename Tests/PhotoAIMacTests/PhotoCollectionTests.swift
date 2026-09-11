import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct PhotoCollectionTests {
    /// 选片集要解决的具体问题：照片多到一次框选不完，需要分多次累积到同一处。
    /// 因此重复加入必须是无操作，否则反复选会把同一张算很多遍。
    @Test
    func assetsAccumulateAcrossMultipleSelectionsWithoutDuplicates() async throws {
        let fixture = try await makeFixture(photoCount: 4)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let ids = store.assets.map(\.id)

        let collection = try #require(store.createCollection(named: "  喀拉峻精选  "))
        // 名称去掉首尾空白。
        #expect(collection.name == "喀拉峻精选")

        store.addAssets([ids[0], ids[1]], to: collection.id)
        #expect(store.assetCount(in: collection.id) == 2)

        // 第二次框选与第一次有重叠：只应新增没加过的那张。
        store.addAssets([ids[1], ids[2]], to: collection.id)
        #expect(store.assetCount(in: collection.id) == 3)

        store.selectCollection(collection.id)
        let shown = store.assets(for: .collection).map(\.id)
        #expect(Set(shown) == Set([ids[0], ids[1], ids[2]]))
    }

    /// 一张照片可以同时属于多个选片集。
    @Test
    func oneAssetCanBelongToSeveralCollections() async throws {
        let fixture = try await makeFixture(photoCount: 2)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let assetID = try #require(store.assets.first?.id)

        let first = try #require(store.createCollection(named: "A"))
        let second = try #require(store.createCollection(named: "B"))
        store.addAssets([assetID], to: first.id)
        store.addAssets([assetID], to: second.id)

        #expect(store.assetCount(in: first.id) == 1)
        #expect(store.assetCount(in: second.id) == 1)
    }

    /// 从选片集移除、以及删除选片集，都只断开关系：
    /// 照片、评分标记与原始文件都不受影响。
    @Test
    func removingMembersAndDeletingCollectionsLeavePhotosUntouched() async throws {
        let fixture = try await makeFixture(photoCount: 3)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let ids = store.assets.map(\.id)
        store.setRating(5, for: [ids[0]])

        let collection = try #require(store.createCollection(named: "待导出"))
        store.addAssets(Set(ids), to: collection.id)
        #expect(store.assetCount(in: collection.id) == 3)

        store.removeAssets([ids[0]], from: collection.id)
        #expect(store.assetCount(in: collection.id) == 2)
        #expect(store.asset(withID: ids[0])?.rating == 5)

        store.deleteCollection(collection.id)
        #expect(store.collections.isEmpty)
        #expect(store.assets.count == 3)
        #expect(store.asset(withID: ids[0])?.rating == 5)
        #expect(FileManager.default.fileExists(atPath: fixture.photoURL(index: 0).path))
    }

    /// 选片集与成员关系必须跨重启存活，否则分多次累积的工作全白做。
    @Test
    func collectionsAndMembersSurviveReload() async throws {
        let fixture = try await makeFixture(photoCount: 3)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let ids = store.assets.map(\.id)

        let collection = try #require(store.createCollection(named: "第一轮"))
        store.addAssets([ids[0], ids[2]], to: collection.id)
        store.renameCollection(collection.id, to: "第一轮精选")
        await store.flushPendingPersist()

        let restored = fixture.reopen()
        let restoredCollection = try #require(restored.collections.first)
        #expect(restoredCollection.id == collection.id)
        #expect(restoredCollection.name == "第一轮精选")
        #expect(restored.assetCount(in: collection.id) == 2)

        restored.selectCollection(collection.id)
        #expect(Set(restored.assets(for: .collection).map(\.id)) == Set([ids[0], ids[2]]))
    }

    /// 移除来源时，它名下照片的收录记录必须一并消失，不能留下无主条目。
    @Test
    func removingASourceClearsItsMembershipRecords() async throws {
        let fixture = try await makeFixture(photoCount: 2)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let collection = try #require(store.createCollection(named: "全部"))
        store.addAssets(Set(store.assets.map(\.id)), to: collection.id)
        #expect(store.assetCount(in: collection.id) == 2)

        let sourceID = try #require(store.sources.first?.id)
        store.removeSource(sourceID)
        await store.flushPendingPersist()

        #expect(store.assetCount(in: collection.id) == 0)
        let restored = fixture.reopen()
        #expect(restored.assetCount(in: collection.id) == 0)
        #expect(restored.collections.count == 1)
    }

    @Test
    func blankNamesAreRejected() async throws {
        let fixture = try await makeFixture(photoCount: 1)
        defer { fixture.cleanUp() }
        #expect(fixture.store.createCollection(named: "   ") == nil)
        #expect(fixture.store.collections.isEmpty)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let store: CatalogStore
        let container: URL
        let photos: URL

        func photoURL(index: Int) -> URL {
            photos.appendingPathComponent(String(format: "DSC%05d.JPG", index))
        }

        func reopen() -> CatalogStore {
            CatalogStore(
                storageURL: container.appendingPathComponent("catalog.json"),
                derivedImageCache: DerivedImageCache(rootURL: container.appendingPathComponent("Derived"))
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: container) }
    }

    private func makeFixture(photoCount: Int) async throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Collection-\(UUID().uuidString)", isDirectory: true)
        let photos = container.appendingPathComponent("卷", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for index in 0..<photoCount {
            try Data([0xFF, 0xD8, 0xFF]).write(
                to: photos.appendingPathComponent(String(format: "DSC%05d.JPG", index))
            )
        }
        let store = CatalogStore(
            storageURL: container.appendingPathComponent("catalog.json"),
            derivedImageCache: DerivedImageCache(rootURL: container.appendingPathComponent("Derived"))
        )
        await store.addFolder(photos)
        return Fixture(store: store, container: container, photos: photos)
    }
}

struct LibraryFilterAndSortTests {
    /// 单个星级是"恰好 N 星"，与"4 星及以上"用途不同，两者都保留。
    @Test
    func singleStarFiltersMatchExactlyThatRating() {
        for rating in 1...5 {
            let asset = makeAsset(rating: rating)
            let exact: LibraryFilter = [.oneStar, .twoStars, .threeStars, .fourStars, .fiveStars][rating - 1]
            #expect(exact.matches(asset))
            for other in 1...5 where other != rating {
                let wrong: LibraryFilter = [.oneStar, .twoStars, .threeStars, .fourStars, .fiveStars][other - 1]
                #expect(!wrong.matches(asset), "\(rating) 星不应匹配 \(wrong.title)")
            }
        }

        #expect(LibraryFilter.fourStarsAndAbove.matches(makeAsset(rating: 4)))
        #expect(LibraryFilter.fourStarsAndAbove.matches(makeAsset(rating: 5)))
        #expect(!LibraryFilter.fourStarsAndAbove.matches(makeAsset(rating: 3)))
    }

    /// 拍摄时间要能两个方向排，文件名同理。
    @Test
    func bothDirectionsAreAvailableForEachSortDimension() {
        let older = makeAsset(name: "B.JPG", captureDate: date(2026, 6, 1))
        let newer = makeAsset(name: "A.JPG", captureDate: date(2026, 7, 1))

        #expect([older, newer].sorted(by: LibrarySortOrder.captureDateDescending.isOrderedBefore)
            .map(\.filename) == ["A.JPG", "B.JPG"])
        #expect([newer, older].sorted(by: LibrarySortOrder.captureDateAscending.isOrderedBefore)
            .map(\.filename) == ["B.JPG", "A.JPG"])
        #expect([older, newer].sorted(by: LibrarySortOrder.filenameAscending.isOrderedBefore)
            .map(\.filename) == ["A.JPG", "B.JPG"])
        #expect([newer, older].sorted(by: LibrarySortOrder.filenameDescending.isOrderedBefore)
            .map(\.filename) == ["B.JPG", "A.JPG"])
    }

    /// 正序时也不能让没有拍摄时间的照片冒充"最早的一张"。
    @Test
    func undatedAssetsStayLastInBothDirections() {
        let dated = makeAsset(name: "A.JPG", captureDate: date(2026, 1, 1))
        let undated = makeAsset(name: "Z.JPG", captureDate: nil)

        for order in [LibrarySortOrder.captureDateAscending, .captureDateDescending] {
            #expect([undated, dated].sorted(by: order.isOrderedBefore).map(\.filename) == ["A.JPG", "Z.JPG"])
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateBucket.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeAsset(name: String = "A.JPG", rating: Int = 0, captureDate: Date? = nil) -> PhotoAsset {
        var asset = PhotoAsset(
            id: UUID(), sourceID: UUID(), relativePath: name, filename: name,
            fileExtension: "jpg", fileSize: 1, modifiedAt: nil, captureDate: captureDate,
            width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil,
            focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil,
            mediaType: .image, rawType: nil, rating: rating, flag: .none, isFavorite: false
        )
        asset.rating = rating
        return asset
    }
}
