import AppKit
import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct PhotoManagementTests {
    @Test
    func ratingPersistence() async throws {
        let fixture = try makeCatalogFixture(assetCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let store = CatalogStore(storageURL: fixture.catalogURL)
        let assetID = try #require(store.assets.first?.id)
        store.selectSingle(assetID: assetID)
        store.setRating(5)
        store.setColorLabel("red", for: [assetID])
        store.setComment("旅行精选", for: [assetID])
        // Catalog 写入已移出主线程，读回磁盘前必须先等待落盘。
        await store.flushPendingPersist()

        let restored = CatalogStore(storageURL: fixture.catalogURL)
        let asset = try #require(restored.asset(withID: assetID))
        #expect(asset.rating == 5)
        #expect(asset.colorLabel == "red")
        #expect(asset.comment == "旅行精选")

        let json = try String(contentsOf: fixture.catalogURL, encoding: .utf8)
        #expect(json.contains("\"rating\" : 5"))
        #expect(json.contains("\"colorLabel\" : \"red\""))
        #expect(json.contains("\"comment\" : \"旅行精选\""))
    }

    @Test
    func flagPersistence() async throws {
        let fixture = try makeCatalogFixture(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let store = CatalogStore(storageURL: fixture.catalogURL)
        let assetID = try #require(store.assets.first?.id)
        store.setFlag(.pick, for: [assetID])
        await store.flushPendingPersist()

        let restored = CatalogStore(storageURL: fixture.catalogURL)
        #expect(restored.asset(withID: assetID)?.flag == .pick)
        let json = try String(contentsOf: fixture.catalogURL, encoding: .utf8)
        #expect(json.contains("\"flag\" : \"picked\""))
    }

    @Test
    func filterByRating() throws {
        let fixture = try makeCatalogFixture(assetCount: 3) { index, asset in
            asset.rating = [0, 5, 4][index]
        }
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let store = CatalogStore(storageURL: fixture.catalogURL)
        store.filter = .unrated
        #expect(store.assets(for: .allPhotos).map(\.rating) == [0])
        store.filter = .fiveStars
        #expect(store.assets(for: .allPhotos).map(\.rating) == [5])
        store.filter = .fourStarsAndAbove
        #expect(Set(store.assets(for: .allPhotos).map(\.rating)) == [4, 5])
    }

    @Test
    func filterByFlag() throws {
        let fixture = try makeCatalogFixture(assetCount: 3) { index, asset in
            asset.flag = [.none, .pick, .reject][index]
        }
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let store = CatalogStore(storageURL: fixture.catalogURL)
        store.filter = .picks
        #expect(store.assets(for: .allPhotos).map(\.flag) == [.pick])
        store.filter = .rejected
        #expect(store.assets(for: .allPhotos).map(\.flag) == [.reject])
    }

    @Test
    func multiSelectionOperation() throws {
        let fixture = try makeCatalogFixture(assetCount: 4)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let store = CatalogStore(storageURL: fixture.catalogURL)
        let ids = store.assets.map(\.id)
        store.select(assetID: ids[0], in: ids, modifiers: [])
        store.select(assetID: ids[2], in: ids, modifiers: .command)
        store.setRating(3)
        store.setFlag(.reject)

        #expect(store.selectedAssetIDs == [ids[0], ids[2]])
        #expect(store.assets.filter { store.selectedAssetIDs.contains($0.id) }.allSatisfy {
            $0.rating == 3 && $0.flag == .reject
        })
        #expect(store.assets.filter { !store.selectedAssetIDs.contains($0.id) }.allSatisfy {
            $0.rating == 0 && $0.flag == .none
        })
    }

    @Test
    func exportFilenameConflict() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "PhotoAI-Export-Conflict")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceDirectory = rootURL.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = rootURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let originalBytes = Data([0x52, 0x41, 0x57, 0x01])
        try originalBytes.write(to: sourceDirectory.appendingPathComponent("IMG_001.ARW"))
        let occupiedBytes = Data("existing".utf8)
        try occupiedBytes.write(to: destinationDirectory.appendingPathComponent("IMG_001.ARW"))

        let exporter = OriginalPhotoExportStore()
        exporter.startForTesting(
            requests: [makeExportRequest(rootURL: sourceDirectory, relativePath: "IMG_001.ARW", filename: "IMG_001.ARW")],
            destinationURL: destinationDirectory
        )
        await waitForExport(exporter)

        #expect(exporter.state == .completed)
        #expect(exporter.succeededCount == 1)
        #expect(try Data(contentsOf: destinationDirectory.appendingPathComponent("IMG_001.ARW")) == occupiedBytes)
        #expect(try Data(contentsOf: destinationDirectory.appendingPathComponent("IMG_001-2.ARW")) == originalBytes)
    }

    @Test
    func exportCancellation() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "PhotoAI-Export-Cancel")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationDirectory = rootURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: rootURL.appendingPathComponent("source.jpg"))
        let requests = (0..<2_000).map { index in
            makeExportRequest(rootURL: rootURL, relativePath: "source.jpg", filename: "copy-\(index).jpg")
        }

        let exporter = OriginalPhotoExportStore()
        exporter.startForTesting(requests: requests, destinationURL: destinationDirectory)
        exporter.cancel()
        await waitForExport(exporter)

        #expect(exporter.state == .cancelled)
        #expect(exporter.completedCount < requests.count)
    }

    @Test
    func exportLargeBatch() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "PhotoAI-Export-Large")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationDirectory = rootURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let originalBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try originalBytes.write(to: rootURL.appendingPathComponent("source.jpg"))
        let requests = (0..<500).map { index in
            makeExportRequest(rootURL: rootURL, relativePath: "source.jpg", filename: "export-\(index).jpg")
        }

        let exporter = OriginalPhotoExportStore()
        exporter.startForTesting(requests: requests, destinationURL: destinationDirectory)
        await waitForExport(exporter, attempts: 2_000)

        #expect(exporter.state == .completed)
        #expect(exporter.completedCount == 500)
        #expect(exporter.succeededCount == 500)
        #expect(exporter.failures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).count == 500)
    }

    @Test
    func cachedCatalogFilteringScalesToFiftyThousandAssets() throws {
        let rootURL = try makeTemporaryDirectory(prefix: "PhotoAI-Query-Scale")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let source = makeSource(rootURL: rootURL, assetCount: 50_000)
        let assets = (0..<50_000).map { index -> PhotoAsset in
            var asset = makeAsset(sourceID: source.id, index: index)
            if index.isMultiple(of: 10) { asset.flag = .pick }
            return asset
        }
        let store = CatalogStore(
            snapshot: CatalogSnapshot(sources: [source], assets: assets),
            storageURL: rootURL.appendingPathComponent("catalog.json")
        )
        store.filter = .picks

        let firstResult = store.assets(for: .allPhotos)
        let computationCount = store.queryComputationCount
        store.selectSingle(assetID: try #require(firstResult.first?.id))
        let secondResult = store.assets(for: .allPhotos)

        #expect(firstResult.count == 5_000)
        #expect(secondResult.count == 5_000)
        #expect(store.queryComputationCount == computationCount)
    }

    private func makeCatalogFixture(
        assetCount: Int,
        mutate: ((Int, inout PhotoAsset) -> Void)? = nil
    ) throws -> CatalogFixture {
        let rootURL = try makeTemporaryDirectory(prefix: "PhotoAI-Management")
        let source = makeSource(rootURL: rootURL, assetCount: assetCount)
        let assets = (0..<assetCount).map { index -> PhotoAsset in
            var asset = makeAsset(sourceID: source.id, index: index)
            mutate?(index, &asset)
            return asset
        }
        let catalogURL = rootURL.appendingPathComponent("catalog.json")
        try CatalogPersistence(fileURL: catalogURL).save(CatalogSnapshot(sources: [source], assets: assets))
        return CatalogFixture(rootURL: rootURL, catalogURL: catalogURL)
    }

    private func makeSource(rootURL: URL, assetCount: Int) -> PhotoSource {
        PhotoSource(
            id: UUID(),
            bookmarkData: Data(),
            displayName: "fixture",
            lastKnownPath: rootURL.path,
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: assetCount
        )
    }

    private func makeAsset(sourceID: UUID, index: Int) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: "photo-\(index).jpg",
            filename: "photo-\(index).jpg",
            fileExtension: "jpg",
            fileSize: Int64(1_000 + index),
            modifiedAt: .now,
            captureDate: .now,
            width: 6_000,
            height: 4_000,
            cameraMake: "Example",
            cameraModel: "Camera",
            lens: "35mm",
            focalLength: "35 mm",
            aperture: "f/2.8",
            shutterSpeed: "1/250",
            iso: 100,
            mediaType: .image,
            rawType: nil,
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }

    private func makeExportRequest(rootURL: URL, relativePath: String, filename: String) -> OriginalPhotoExportRequest {
        OriginalPhotoExportRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: rootURL.path,
            relativePath: relativePath,
            filename: filename
        )
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForExport(_ exporter: OriginalPhotoExportStore, attempts: Int = 500) async {
        for _ in 0..<attempts where exporter.state.isActive {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct CatalogFixture {
    let rootURL: URL
    let catalogURL: URL
}
