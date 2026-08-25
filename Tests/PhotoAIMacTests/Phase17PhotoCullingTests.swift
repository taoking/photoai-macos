import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct Phase17PhotoCullingTests {
    @Test
    func cullingNavigationTest() throws {
        let assets = makeAssets(count: 4)
        let session = PhotoCullingSessionStore()

        session.start(assets: assets, focusedAssetID: assets[1].id)

        #expect(session.isPresented)
        #expect(session.currentAssetID == assets[1].id)
        #expect(session.positionDescription == "2 / 4")
        #expect(session.move(offset: 1) == assets[2].id)
        #expect(session.move(offset: -1) == assets[1].id)
        #expect(session.statistics.totalCount == 4)
    }

    @Test
    func ratingShortcutTest() throws {
        let fixture = try makeCatalogFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = PhotoCullingSessionStore()
        session.start(assets: fixture.store.assets, focusedAssetID: fixture.store.assets[0].id)

        let shortcut = try #require(PhotoCullingShortcut.metadataShortcut(for: "5"))
        #expect(shortcut == .rating(5))
        #expect(session.perform(shortcut, catalog: fixture.store))
        #expect(fixture.store.asset(withID: fixture.store.assets[0].id)?.rating == 5)
        #expect(session.statistics.fiveStarCount == 1)
        #expect(session.statistics.unprocessedCount == 1)
    }

    @Test
    func pickRejectTest() throws {
        let fixture = try makeCatalogFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = PhotoCullingSessionStore()
        let firstID = fixture.store.assets[0].id
        session.start(assets: fixture.store.assets, focusedAssetID: firstID)

        #expect(session.perform(.pick, catalog: fixture.store))
        #expect(fixture.store.asset(withID: firstID)?.flag == .pick)
        #expect(session.statistics.pickCount == 1)
        #expect(session.perform(.reject, catalog: fixture.store))
        #expect(fixture.store.asset(withID: firstID)?.flag == .reject)
        #expect(session.statistics.pickCount == 0)
        #expect(session.statistics.rejectCount == 1)
        #expect(session.perform(.clearFlag, catalog: fixture.store))
        #expect(fixture.store.asset(withID: firstID)?.flag == PhotoFlag.none)
    }

    @Test
    func compareViewStateTest() throws {
        let fixture = try makeCatalogFixture(count: 3)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = PhotoCullingSessionStore()
        let assets = fixture.store.assets
        session.start(assets: assets, focusedAssetID: assets[0].id)

        #expect(session.beginCompare())
        session.setCompareZoom(2.5)
        session.setCompareOffset(x: 120, y: -45)

        let state = try #require(session.compareState)
        #expect(state.assetAID == assets[0].id)
        #expect(state.assetBID == assets[1].id)
        #expect(state.zoomScale == 2.5)
        #expect(state.offsetX == 120)
        #expect(state.offsetY == -45)

        #expect(session.chooseCompareSide(.b, catalog: fixture.store))
        #expect(session.compareState?.preferredSide == .b)
        #expect(fixture.store.asset(withID: assets[0].id)?.flag == .reject)
        #expect(fixture.store.asset(withID: assets[1].id)?.flag == .pick)
    }

    @Test
    func photoGroupTest() {
        let sourceID = UUID()
        let baseDate = Date(timeIntervalSinceReferenceDate: 10_000)
        let assets = [
            makeAsset(sourceID: sourceID, index: 1, relativePath: "新疆/IMG_001.ARW", date: baseDate),
            makeAsset(sourceID: sourceID, index: 1, relativePath: "新疆/IMG_001.JPG", date: baseDate),
            makeAsset(sourceID: sourceID, index: 2, relativePath: "新疆/IMG_002.ARW", date: baseDate.addingTimeInterval(8)),
            makeAsset(sourceID: sourceID, index: 4, relativePath: "新疆/IMG_004.ARW", date: baseDate.addingTimeInterval(12)),
            makeAsset(sourceID: sourceID, index: 5, relativePath: "北京/IMG_005.ARW", date: baseDate.addingTimeInterval(13))
        ]

        let groups = PhotoGroupBuilder.groups(in: assets)

        #expect(groups.count == 1)
        #expect(groups[0].assetIDs == [assets[0].id, assets[1].id, assets[2].id])
    }

    @Test
    func exportSelectionTest() async throws {
        let sourceID = UUID()
        var assets = makeAssets(count: 4, sourceID: sourceID, directory: "2026/新疆")
        assets[0].flag = .pick
        assets[1].rating = 5
        assets[2].flag = .pick

        #expect(PhotoCullingExportSelector.assets(from: assets, selection: .picks).map(\.id) == [assets[0].id, assets[2].id])
        #expect(PhotoCullingExportSelector.assets(from: assets, selection: .fiveStars).map(\.id) == [assets[1].id])
        #expect(PhotoCullingExportSelector.assets(from: assets, selection: .currentResult).count == 4)

        let destinationURL = URL(fileURLWithPath: "/tmp/export-selection")
        let requests = assets.prefix(2).map { asset in
            OriginalPhotoExportRequest(
                assetID: asset.id,
                bookmarkData: Data(),
                lastKnownRootPath: "/tmp/source",
                relativePath: asset.relativePath,
                filename: asset.filename
            )
        }
        let plans = OriginalPhotoExportPlanner.plans(
            requests: requests,
            destinationURL: destinationURL,
            existingFilenames: ["2026/新疆/IMG_000.ARW"],
            layout: .preserveDirectoryStructure
        )

        #expect(plans[0].destinationURL.path == "/tmp/export-selection/2026/新疆/IMG_000-2.ARW")
        #expect(plans[1].destinationURL.path == "/tmp/export-selection/2026/新疆/IMG_001.ARW")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Phase17-Export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceRootURL = rootURL.appendingPathComponent("source", isDirectory: true)
        let nestedSourceURL = sourceRootURL.appendingPathComponent("2026/新疆", isDirectory: true)
        let actualDestinationURL = rootURL.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actualDestinationURL, withIntermediateDirectories: true)
        let sourceBytes = Data([0x52, 0x41, 0x57, 0x17])
        try sourceBytes.write(to: nestedSourceURL.appendingPathComponent("IMG_001.ARW"))
        let exporter = OriginalPhotoExportStore()
        exporter.startForTesting(
            requests: [
                OriginalPhotoExportRequest(
                    assetID: UUID(),
                    bookmarkData: Data(),
                    lastKnownRootPath: sourceRootURL.path,
                    relativePath: "2026/新疆/IMG_001.ARW",
                    filename: "IMG_001.ARW"
                )
            ],
            destinationURL: actualDestinationURL,
            layout: .preserveDirectoryStructure
        )
        for _ in 0..<500 where exporter.state.isActive {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let copiedURL = actualDestinationURL.appendingPathComponent("2026/新疆/IMG_001.ARW")
        #expect(exporter.state == .completed)
        #expect(try Data(contentsOf: copiedURL) == sourceBytes)
    }

    @Test
    func undoOperationTest() throws {
        let fixture = try makeCatalogFixture(count: 3)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let ids = Set(fixture.store.assets.map(\.id))

        #expect(fixture.store.setRating(4, for: ids) == ids)
        #expect(fixture.store.assets.allSatisfy { $0.rating == 4 })
        #expect(fixture.store.canUndoMetadataOperation)
        #expect(fixture.store.undoLastMetadataOperation() == ids)
        #expect(fixture.store.assets.allSatisfy { $0.rating == 0 })

        #expect(fixture.store.setFlag(.reject, for: ids) == ids)
        #expect(fixture.store.undoLastMetadataOperation() == ids)
        #expect(fixture.store.assets.allSatisfy { $0.flag == .none })
    }

    @Test
    func largeCatalogPerformanceTest() {
        let assets = makeAssets(count: 100_000)
        let session = PhotoCullingSessionStore()
        session.start(assets: assets, focusedAssetID: assets[50_000].id)
        let clock = ContinuousClock()
        var slowestStep = Duration.zero

        for index in 0..<2_000 {
            let start = clock.now
            _ = session.move(offset: index.isMultiple(of: 2) ? 1 : -1)
            slowestStep = max(slowestStep, start.duration(to: clock.now))
        }

        #expect(session.contextAssetIDs.count == 100_000)
        #expect(slowestStep < .milliseconds(100))
        #expect(session.currentAssetID == assets[50_000].id)
    }

    private func makeCatalogFixture(count: Int) throws -> Phase17CatalogFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Phase17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let sourceID = UUID()
        let source = PhotoSource(
            id: sourceID,
            bookmarkData: Data(),
            displayName: "fixture",
            lastKnownPath: rootURL.path,
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: count
        )
        let store = CatalogStore(
            snapshot: CatalogSnapshot(sources: [source], assets: makeAssets(count: count, sourceID: sourceID)),
            storageURL: rootURL.appendingPathComponent("catalog.json")
        )
        return Phase17CatalogFixture(rootURL: rootURL, store: store)
    }

    private func makeAssets(
        count: Int,
        sourceID: UUID = UUID(),
        directory: String = "shoot"
    ) -> [PhotoAsset] {
        let baseDate = Date(timeIntervalSinceReferenceDate: 20_000)
        return (0..<count).map { index in
            makeAsset(
                sourceID: sourceID,
                index: index,
                relativePath: String(format: "%@/IMG_%03d.ARW", directory, index),
                date: baseDate.addingTimeInterval(Double(index))
            )
        }
    }

    private func makeAsset(
        sourceID: UUID,
        index: Int,
        relativePath: String,
        date: Date
    ) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: relativePath,
            filename: (relativePath as NSString).lastPathComponent,
            fileExtension: "ARW",
            fileSize: Int64(20_000_000 + index),
            modifiedAt: date,
            captureDate: date,
            width: 6_000,
            height: 4_000,
            cameraMake: "Sony",
            cameraModel: "Test Camera",
            lens: "35mm",
            focalLength: "35 mm",
            aperture: "f/2.8",
            shutterSpeed: "1/500",
            iso: 100,
            mediaType: .image,
            rawType: "ARW",
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }
}

private struct Phase17CatalogFixture {
    let rootURL: URL
    let store: CatalogStore
}
