import Foundation
import AppKit
import Testing
@testable import PhotoAIMac

struct CatalogTests {
    @Test
    func scannerIndexesSupportedFilesAndPreservesOriginalBytes() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedURL = rootURL.appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let imageURL = nestedURL.appendingPathComponent("SUNSET.DNG")
        let originalBytes = Data([0x00, 0xA1, 0xB2, 0xC3])
        try originalBytes.write(to: imageURL)
        try Data("not a photo".utf8).write(to: rootURL.appendingPathComponent("notes.txt"))

        let sourceID = UUID()
        let assets = try CatalogScanner.scan(sourceID: sourceID, rootURL: rootURL)

        #expect(assets.count == 1)
        #expect(assets[0].filename == "SUNSET.DNG")
        #expect(assets[0].relativePath == "2026/SUNSET.DNG")
        #expect(assets[0].rawType == "DNG")
        #expect(try Data(contentsOf: imageURL) == originalBytes)
    }

    @Test
    @MainActor
    func catalogPersistsIndexedFolderAcrossStoreInitialization() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let imageURL = rootURL.appendingPathComponent("library-photo.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: imageURL)
        let catalogURL = rootURL.appendingPathComponent("catalog.json")

        let firstStore = CatalogStore(storageURL: catalogURL)
        await firstStore.addFolder(rootURL)

        #expect(firstStore.sources.count == 1)
        #expect(firstStore.assets.count == 1)
        #expect(firstStore.sources[0].status == .ready)
        await firstStore.flushPendingPersist()

        let restoredStore = CatalogStore(storageURL: catalogURL)
        #expect(restoredStore.sources.count == 1)
        #expect(restoredStore.assets.map(\.filename) == ["library-photo.jpg"])
    }

    @Test
    @MainActor
    func rescanPreservesAssetIdentityAndLocalState() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let imageURL = rootURL.appendingPathComponent("stable-id.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: imageURL)
        let catalogURL = rootURL.appendingPathComponent("catalog.json")
        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(rootURL)
        let original = try #require(store.assets.first)

        store.select(assetID: original.id, in: [original.id], modifiers: [])
        store.setRating(5)
        store.setFlag(.pick)
        store.toggleFavorite()
        await store.rescan(try #require(store.sources.first?.id))
        let rescanned = try #require(store.assets.first)

        #expect(rescanned.id == original.id)
        #expect(rescanned.rating == 5)
        #expect(rescanned.flag == .pick)
        #expect(rescanned.isFavorite)
        #expect(store.selectedAssetIDs == [original.id])
    }

    @Test
    @MainActor
    func marksUnresolvableSourceAsMissing() async throws {
        let rootURL = try makeTemporaryDirectory()
        let catalogURL = rootURL.appendingPathComponent("catalog.json")
        let missingFolder = rootURL.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        let bookmark = try missingFolder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.removeItem(at: missingFolder)
        let source = PhotoSource(
            id: UUID(),
            bookmarkData: bookmark,
            displayName: "missing",
            lastKnownPath: missingFolder.path,
            createdAt: .now,
            lastScannedAt: nil,
            status: .ready,
            assetCount: 0
        )
        try CatalogPersistence(fileURL: catalogURL).save(CatalogSnapshot(sources: [source], assets: []))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = CatalogStore(storageURL: catalogURL)
        await store.rescan(source.id)

        #expect(store.sources.first?.status == .missing)
    }

    @Test
    @MainActor
    func supportsRangeSelectionAndBatchRatingFlaggingAndFiltering() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceID = UUID()
        let source = PhotoSource(
            id: sourceID,
            bookmarkData: Data(),
            displayName: "fixture",
            lastKnownPath: rootURL.path,
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: 3
        )
        let assets = ["one.jpg", "two.jpg", "three.dng"].map { makeAsset(sourceID: sourceID, filename: $0) }
        let storageURL = rootURL.appendingPathComponent("catalog.json")
        try CatalogPersistence(fileURL: storageURL).save(CatalogSnapshot(sources: [source], assets: assets))

        let store = CatalogStore(storageURL: storageURL)
        let ids = store.assets.map(\.id)
        store.select(assetID: ids[0], in: ids, modifiers: [])
        store.select(assetID: ids[2], in: ids, modifiers: .shift)
        store.setRating(5)
        store.setFlag(.pick)

        #expect(store.selectedAssetIDs == Set(ids))
        #expect(store.assets.allSatisfy { $0.rating == 5 && $0.flag == .pick })

        store.filter = .picks
        #expect(store.assets(for: .allPhotos).count == 3)

        store.filter = .fiveStars
        #expect(store.assets(for: .allPhotos).count == 3)
    }

    @Test
    func thumbnailCacheKeyChangesWhenSourceChanges() {
        let assetID = UUID()
        let initialDate = Date(timeIntervalSinceReferenceDate: 100)
        let initial = ThumbnailRequest(
            assetID: assetID,
            bookmarkData: Data(),
            lastKnownRootPath: "/fixture",
            relativePath: "photo.jpg",
            modificationDate: initialDate,
            mediaType: .image
        )
        let changed = ThumbnailRequest(
            assetID: assetID,
            bookmarkData: Data(),
            lastKnownRootPath: "/fixture",
            relativePath: "photo.jpg",
            modificationDate: initialDate.addingTimeInterval(1),
            mediaType: .image
        )

        #expect(initial.cacheKey != changed.cacheKey)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAsset(sourceID: UUID, filename: String) -> PhotoAsset {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        return PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: filename,
            filename: filename,
            fileExtension: fileExtension,
            fileSize: 1,
            modifiedAt: .now,
            captureDate: nil,
            width: 1,
            height: 1,
            cameraMake: nil,
            cameraModel: nil,
            lens: nil,
            focalLength: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            mediaType: .image,
            rawType: fileExtension.lowercased() == "dng" ? "DNG" : nil,
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }
}
