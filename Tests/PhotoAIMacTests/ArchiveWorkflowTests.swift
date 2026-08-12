import AppKit
import CryptoKit
import Foundation
import Testing
@testable import PhotoAIMac

struct ArchiveWorkflowTests {
    @Test
    func archiveHashAndPreviewPersistAcrossRestart() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let imageURL = sourceURL.appendingPathComponent("photo.jpg")
        try writeJPEG(to: imageURL, color: .systemBlue)
        let originalData = try Data(contentsOf: imageURL)

        let source = fixtureSource(id: UUID(), rootURL: sourceURL)
        let asset = try fixtureAsset(sourceID: source.id, url: imageURL, rootURL: sourceURL)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let persistence = try ArchiveIndexPersistence(databaseURL: ArchiveIndexPersistence.databaseURL(for: catalogURL))
        try persistence.bootstrap(sources: [source], assets: [asset])

        let result = try ArchiveProcessor.process(
            ArchiveProcessingRequest(asset: asset, bookmarkData: Data(), rootPath: sourceURL.path, existingMetadata: .empty),
            previewDirectory: root.appendingPathComponent("ArchivePreviews", isDirectory: true)
        )
        _ = try persistence.save(result: result)

        let restored = try ArchiveIndexPersistence(databaseURL: ArchiveIndexPersistence.databaseURL(for: catalogURL))
        let loaded = try restored.load(assetIDs: [asset.id])
        let metadata = try #require(loaded.metadata[asset.id])
        #expect(metadata.exactHash == SHA256.hash(data: try Data(contentsOf: imageURL)).map { String(format: "%02x", $0) }.joined())
        #expect(metadata.hashState == .complete)
        #expect(metadata.previewState == .complete)
        let previewURL = try #require(ArchiveProcessor.previewURL(for: metadata, previewDirectory: root.appendingPathComponent("ArchivePreviews", isDirectory: true)))
        #expect(FileManager.default.fileExists(atPath: previewURL.path))
        #expect(try Data(contentsOf: imageURL) == originalData)
    }

    @Test
    func unchangedFileDoesNotRehashAndModifiedFileInvalidatesMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let imageURL = sourceURL.appendingPathComponent("photo.jpg")
        try writeJPEG(to: imageURL, color: .systemRed)
        let source = fixtureSource(id: UUID(), rootURL: sourceURL)
        let asset = try fixtureAsset(sourceID: source.id, url: imageURL, rootURL: sourceURL)
        let previewDirectory = root.appendingPathComponent("previews", isDirectory: true)
        let generated = try ArchiveProcessor.process(
            ArchiveProcessingRequest(asset: asset, bookmarkData: Data(), rootPath: sourceURL.path, existingMetadata: .empty),
            previewDirectory: previewDirectory
        )
        let metadata = generated.metadata

        let unchanged = try ArchiveProcessor.process(
            ArchiveProcessingRequest(asset: asset, bookmarkData: Data(), rootPath: sourceURL.path, existingMetadata: metadata),
            previewDirectory: previewDirectory
        )
        #expect(!unchanged.didHash)
        #expect(!unchanged.didCreatePreview)

        var changed = asset
        changed.archive = metadata.invalidatedForChangedSource()
        changed = PhotoAsset(
            id: changed.id, sourceID: changed.sourceID, relativePath: changed.relativePath, filename: changed.filename,
            fileExtension: changed.fileExtension, fileSize: changed.fileSize + 1, modifiedAt: changed.modifiedAt?.addingTimeInterval(1),
            captureDate: changed.captureDate, width: changed.width, height: changed.height, cameraMake: changed.cameraMake,
            cameraModel: changed.cameraModel, lens: changed.lens, focalLength: changed.focalLength, aperture: changed.aperture,
            shutterSpeed: changed.shutterSpeed, iso: changed.iso, mediaType: changed.mediaType, rawType: changed.rawType,
            rating: changed.rating, flag: changed.flag, isFavorite: changed.isFavorite, editRecipe: changed.editRecipe, ocrText: changed.ocrText,
            archive: changed.archive
        )
        #expect(changed.archiveMetadata.needsHash(for: changed))
        #expect(changed.archiveMetadata.needsPreview(for: changed))
    }

    @Test
    func exactDuplicateAcrossDifferentSourcesUsesIndexedLookup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let firstURL = firstRoot.appendingPathComponent("same.jpg")
        let secondURL = secondRoot.appendingPathComponent("copy.jpg")
        try writeJPEG(to: firstURL, color: .systemGreen)
        try Data(contentsOf: firstURL).write(to: secondURL)

        let firstSource = fixtureSource(id: UUID(), rootURL: firstRoot)
        let secondSource = fixtureSource(id: UUID(), rootURL: secondRoot)
        let first = try fixtureAsset(sourceID: firstSource.id, url: firstURL, rootURL: firstRoot)
        let second = try fixtureAsset(sourceID: secondSource.id, url: secondURL, rootURL: secondRoot)
        let persistence = try ArchiveIndexPersistence(databaseURL: root.appendingPathComponent("archive.sqlite"))
        try persistence.bootstrap(sources: [firstSource, secondSource], assets: [first, second])
        let previewDirectory = root.appendingPathComponent("previews", isDirectory: true)
        let firstResult = try ArchiveProcessor.process(ArchiveProcessingRequest(asset: first, bookmarkData: Data(), rootPath: firstRoot.path, existingMetadata: .empty), previewDirectory: previewDirectory)
        _ = try persistence.save(result: firstResult)
        let secondResult = try ArchiveProcessor.process(ArchiveProcessingRequest(asset: second, bookmarkData: Data(), rootPath: secondRoot.path, existingMetadata: .empty), previewDirectory: previewDirectory)
        let relationships = try persistence.save(result: secondResult)

        #expect(relationships.contains { $0.kind == .exactDuplicate && Set([$0.firstAssetID, $0.secondAssetID]) == Set([first.id, second.id]) })
        #expect(!relationships.contains { $0.kind == .possibleVisualDuplicate })
        #expect(try persistence.exactMatches(for: try #require(secondResult.metadata.exactHash), excluding: second.id) == [first.id])

        let changedMetadata = ArchiveAssetMetadata(
            exactHash: "a-different-file",
            visualHash: 0,
            hashedFileSize: second.fileSize + 1,
            hashedModifiedAt: second.modifiedAt?.addingTimeInterval(1),
            hashUpdatedAt: .now,
            hashState: .complete,
            previewState: .pending
        )
        _ = try persistence.save(result: ArchiveProcessingResult(assetID: second.id, metadata: changedMetadata, didHash: true, didCreatePreview: false))
        let rebuilt = try persistence.load(assetIDs: [first.id, second.id]).relationships
        #expect(!rebuilt.contains { $0.kind == .exactDuplicate && Set([$0.firstAssetID, $0.secondAssetID]) == Set([first.id, second.id]) })
    }

    @Test
    func offlineOriginalWithOnlineExactCopyReportsMultipleCopies() {
        let offlineSource = fixtureSource(id: UUID(), rootURL: URL(fileURLWithPath: "/offline"))
        let onlineSource = fixtureSource(id: UUID(), rootURL: URL(fileURLWithPath: "/online"))
        let asset = PhotoAsset(id: UUID(), sourceID: offlineSource.id, relativePath: "original.jpg", filename: "original.jpg", fileExtension: "jpg", fileSize: 1, modifiedAt: nil, captureDate: nil, width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil, mediaType: .image, rawType: nil, rating: 0, flag: .none, isFavorite: false)
        let copy = PhotoAsset(id: UUID(), sourceID: onlineSource.id, relativePath: "copy.jpg", filename: "copy.jpg", fileExtension: "jpg", fileSize: 1, modifiedAt: nil, captureDate: nil, width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil, mediaType: .image, rawType: nil, rating: 0, flag: .none, isFavorite: false)
        var unavailableSource = offlineSource
        unavailableSource.status = .missing
        let locations = [
            AssetLocation(assetID: asset.id, sourceID: unavailableSource.id, relativePath: asset.relativePath, filename: asset.filename, fileSize: asset.fileSize, modifiedAt: nil, isAvailable: false),
            AssetLocation(assetID: copy.id, sourceID: onlineSource.id, relativePath: copy.relativePath, filename: copy.filename, fileSize: copy.fileSize, modifiedAt: nil, isAvailable: true)
        ]
        let duplicates = [ArchiveDuplicateRelationship(firstAssetID: asset.id, secondAssetID: copy.id, kind: .exactDuplicate)]

        #expect(asset.archiveAvailability(sources: [unavailableSource, onlineSource], locations: locations, duplicates: duplicates) == .multipleCopies)
    }

    @Test
    @MainActor
    func offlineAssetRetainsLocationAndPreviewAndRelinkRestoresSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("external-drive", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let imageURL = sourceURL.appendingPathComponent("offline.jpg")
        try writeJPEG(to: imageURL, color: .systemPurple)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(sourceURL)
        let coordinator = ArchiveCoordinator(catalogURL: catalogURL)
        coordinator.start(catalog: store)
        #expect(await waitForArchive(coordinator))
        let processedAsset = try #require(store.assets.first)
        let previewURL = try #require(store.offlinePreviewURL(for: processedAsset))
        #expect(FileManager.default.fileExists(atPath: previewURL.path))

        try FileManager.default.moveItem(at: sourceURL, to: root.appendingPathComponent("external-drive-offline", isDirectory: true))
        await store.rescan(try #require(store.sources.first?.id))
        let offlineAsset = try #require(store.assets.first)
        #expect(store.archiveAvailability(for: offlineAsset) == .offline)
        #expect(store.offlinePreviewURL(for: offlineAsset) != nil)
        #expect(store.archiveOriginalLocation(for: offlineAsset)?.relativePath == "offline.jpg")

        await store.relinkSource(try #require(store.sources.first?.id), to: root.appendingPathComponent("external-drive-offline", isDirectory: true))
        #expect(store.sources.first?.status == .ready)
        #expect(store.archiveAvailability(for: try #require(store.assets.first)) == .online)
    }

    @Test
    @MainActor
    func missingFileRemainsInHistoryWithOfflinePreview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let imageURL = sourceURL.appendingPathComponent("history.jpg")
        try writeJPEG(to: imageURL, color: .systemOrange)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(sourceURL)
        let coordinator = ArchiveCoordinator(catalogURL: catalogURL)
        coordinator.start(catalog: store)
        #expect(await waitForArchive(coordinator))
        let assetID = try #require(store.assets.first?.id)

        try FileManager.default.removeItem(at: imageURL)
        await store.rescan(try #require(store.sources.first?.id))

        let historicalAsset = try #require(store.assets.first(where: { $0.id == assetID }))
        #expect(store.assets.count == 1)
        #expect(store.archiveAvailability(for: historicalAsset) == .missing)
        #expect(store.offlinePreviewURL(for: historicalAsset) != nil)
        #expect(store.archiveOriginalLocation(for: historicalAsset)?.relativePath == "history.jpg")
    }

    @Test
    @MainActor
    func appRestartResumesPendingArchiveWorkSafely() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try writeJPEG(to: sourceURL.appendingPathComponent("resume.jpg"), color: .systemTeal)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let firstRun = CatalogStore(storageURL: catalogURL)
        await firstRun.addFolder(sourceURL)
        #expect(firstRun.assets.first?.archiveMetadata.hashState == .pending)

        let restartedCatalog = CatalogStore(storageURL: catalogURL)
        let resumed = ArchiveCoordinator(catalogURL: catalogURL)
        resumed.start(catalog: restartedCatalog)
        #expect(await waitForArchive(resumed))
        let archived = try #require(restartedCatalog.assets.first)
        #expect(archived.archiveMetadata.hashState == .complete)
        #expect(restartedCatalog.offlinePreviewURL(for: archived) != nil)
    }

    @Test
    @MainActor
    func backgroundArchiveCanPauseCancelAndResumeWithoutChangingOriginal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let imageURL = sourceURL.appendingPathComponent("cancel-resume.jpg")
        try writeJPEG(to: imageURL, color: .systemBrown)
        let originalData = try Data(contentsOf: imageURL)
        // JPEG decoder accepts trailing data; this makes SHA-256 long enough for a real cancellation point
        // without creating tens of thousands of picture files.
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.seekToEnd()
        handle.write(Data(repeating: 0xA5, count: 96 * 1_024 * 1_024))
        try handle.close()
        let sourceDataBeforeArchive = try Data(contentsOf: imageURL)

        let catalogURL = root.appendingPathComponent("catalog.json")
        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(sourceURL)
        let coordinator = ArchiveCoordinator(catalogURL: catalogURL)
        coordinator.start(catalog: store)
        await Task.yield()
        coordinator.pause()
        // 这模拟 `CatalogStore.assets` 的发布：暂停不能被自动补队列的 start 重新唤醒。
        coordinator.start(catalog: store)
        #expect(coordinator.progress.state == .paused)

        coordinator.resume(catalog: store)
        #expect(await waitForArchive(coordinator, attempts: 2_000))
        let archived = try #require(store.assets.first)
        #expect(archived.archiveMetadata.hashState == .complete)
        #expect(store.offlinePreviewURL(for: archived) != nil)
        #expect(try Data(contentsOf: imageURL) == sourceDataBeforeArchive)
        #expect(!originalData.isEmpty)
    }

    @Test
    @MainActor
    func sqliteMigrationBacksUpExistingCatalogAndRetainsUserMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let source = fixtureSource(id: UUID(), rootURL: sourceURL)
        var asset = PhotoAsset(
            id: UUID(), sourceID: source.id, relativePath: "kept.jpg", filename: "kept.jpg", fileExtension: "jpg",
            fileSize: 42, modifiedAt: .now, captureDate: .now, width: 12, height: 8, cameraMake: nil,
            cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil,
            mediaType: .image, rawType: nil, rating: 5, flag: .pick, isFavorite: true
        )
        asset.editRecipe = EditRecipe(exposure: 1.25, saturation: 0.2)
        asset.ocrText = "保留的 OCR"
        let catalogURL = root.appendingPathComponent("catalog.json")
        let persistence = CatalogPersistence(fileURL: catalogURL)
        try persistence.save(CatalogSnapshot(sources: [source], assets: [asset], schemaVersion: 2))
        let originalSnapshot = try Data(contentsOf: catalogURL)

        let migrated = CatalogStore(storageURL: catalogURL)
        let restored = try #require(migrated.assets.first)
        #expect(restored.id == asset.id)
        #expect(restored.rating == 5)
        #expect(restored.flag == .pick)
        #expect(restored.isFavorite)
        #expect(restored.editRecipe == asset.editRecipe)
        #expect(restored.ocrText == "保留的 OCR")
        let backupURL = catalogURL.appendingPathExtension("phase14-pre-sqlite.bak")
        #expect(try Data(contentsOf: backupURL) == originalSnapshot)
        #expect(FileManager.default.fileExists(atPath: ArchiveIndexPersistence.databaseURL(for: catalogURL).path))
    }

    @Test
    func largeArchiveExactLookupUsesSQLiteIndexAtTenThousandAndFiftyThousandRows() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try ArchiveIndexPersistence(databaseURL: root.appendingPathComponent("archive.sqlite"))
        let source = fixtureSource(id: UUID(), rootURL: root)
        let assets = (0..<50_000).map { index in
            PhotoAsset(id: UUID(), sourceID: source.id, relativePath: "\(index).jpg", filename: "\(index).jpg", fileExtension: "jpg", fileSize: Int64(index + 1), modifiedAt: .now, captureDate: nil, width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil, mediaType: .image, rawType: nil, rating: 0, flag: .none, isFavorite: false)
        }
        try persistence.bootstrap(sources: [source], assets: assets)
        let targetAtTenThousand = assets[7_777]
        let targetAtFiftyThousand = assets[47_777]
        let tenThousandMetadata = ArchiveAssetMetadata(exactHash: "indexed-10k", hashedFileSize: targetAtTenThousand.fileSize, hashedModifiedAt: targetAtTenThousand.modifiedAt, hashUpdatedAt: .now, hashState: .complete, previewState: .pending)
        _ = try persistence.save(result: ArchiveProcessingResult(assetID: targetAtTenThousand.id, metadata: tenThousandMetadata, didHash: true, didCreatePreview: false))
        #expect(try persistence.exactMatches(for: "indexed-10k", excluding: UUID()) == [targetAtTenThousand.id])

        let target = targetAtFiftyThousand
        let metadata = ArchiveAssetMetadata(exactHash: "indexed-target", hashedFileSize: target.fileSize, hashedModifiedAt: target.modifiedAt, hashUpdatedAt: .now, hashState: .complete, previewState: .pending)
        _ = try persistence.save(result: ArchiveProcessingResult(assetID: target.id, metadata: metadata, didHash: true, didCreatePreview: false))
        #expect(try persistence.exactMatches(for: "indexed-target", excluding: UUID()) == [target.id])
        let reloaded = try persistence.load(assetIDs: assets.map(\.id))
        #expect(reloaded.metadata[targetAtFiftyThousand.id]?.exactHash == "indexed-target")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAI-Mac-Archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtureSource(id: UUID, rootURL: URL) -> PhotoSource {
        PhotoSource(id: id, bookmarkData: Data(), displayName: rootURL.lastPathComponent, lastKnownPath: rootURL.path, createdAt: .now, lastScannedAt: .now, status: .ready, assetCount: 1)
    }

    private func fixtureAsset(sourceID: UUID, url: URL, rootURL: URL) throws -> PhotoAsset {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return PhotoAsset(id: UUID(), sourceID: sourceID, relativePath: url.lastPathComponent, filename: url.lastPathComponent, fileExtension: url.pathExtension, fileSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, captureDate: nil, width: nil, height: nil, cameraMake: nil, cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutterSpeed: nil, iso: nil, mediaType: .image, rawType: nil, rating: 0, flag: .none, isFavorite: false)
    }

    private func writeJPEG(to url: URL, color: NSColor) throws {
        let image = NSImage(size: NSSize(width: 1_600, height: 1_000))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1_600, height: 1_000)).fill()
        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ArchiveProcessingError.unreadableImage
        }
        try jpeg.write(to: url)
    }

    @MainActor
    private func waitForArchive(_ coordinator: ArchiveCoordinator, attempts: Int = 1_000) async -> Bool {
        for _ in 0..<attempts where coordinator.progress.state != .complete {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return coordinator.progress.state == .complete
    }
}
