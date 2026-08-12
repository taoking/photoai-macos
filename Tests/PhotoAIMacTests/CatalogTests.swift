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
    func catalogMergeHandlesFiftyThousandAssets() {
        let sourceID = UUID()
        let otherSourceID = UUID()
        var existing = (0..<50_000).map { index in
            makeSyntheticAsset(sourceID: sourceID, index: index)
        }
        let preserved = existing[12_345]
        existing[12_345].rating = 5
        existing[12_345].flag = .pick
        existing[12_345].isFavorite = true
        existing[12_345].editRecipe = EditRecipe(exposure: 0.75)
        existing[12_345].ocrText = "保留的 OCR"
        existing.append(makeSyntheticAsset(sourceID: otherSourceID, index: 1))

        // 49,000 项复扫：1,000 个历史缺失项，另加入 500 个新项。
        var scanned = (0..<49_000).map { index in
            makeSyntheticAsset(sourceID: sourceID, index: index, id: UUID())
        }
        scanned.append(contentsOf: (50_000..<50_500).map { index in
            makeSyntheticAsset(sourceID: sourceID, index: index)
        })

        let merged = CatalogMerge.merging(existingAssets: existing, scannedAssets: scanned, sourceID: sourceID)
        let bySourceAndPath = Dictionary(uniqueKeysWithValues: merged.map { ("\($0.sourceID.uuidString)|\($0.relativePath)", $0) })
        let restored = try! #require(bySourceAndPath["\(sourceID.uuidString)|synthetic/12345.jpg"])

        #expect(merged.count == 50_501)
        #expect(Set(merged.map(\.id)).count == merged.count)
        #expect(restored.id == preserved.id)
        #expect(restored.rating == 5)
        #expect(restored.flag == .pick)
        #expect(restored.isFavorite)
        #expect(restored.editRecipe == EditRecipe(exposure: 0.75))
        #expect(restored.ocrText == "保留的 OCR")
        #expect(bySourceAndPath["\(sourceID.uuidString)|synthetic/49500.jpg"]?.id == existing[49_500].id)
        #expect(bySourceAndPath["\(sourceID.uuidString)|synthetic/50010.jpg"] != nil)
        #expect(merged.contains(where: { $0.sourceID == otherSourceID }))
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

    private func makeSyntheticAsset(sourceID: UUID, index: Int, id: UUID = UUID()) -> PhotoAsset {
        PhotoAsset(
            id: id,
            sourceID: sourceID,
            relativePath: "synthetic/\(index).jpg",
            filename: "\(index).jpg",
            fileExtension: "jpg",
            fileSize: Int64(index + 1),
            modifiedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
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
            rawType: nil,
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }
}
