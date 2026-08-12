import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoAIMac

@MainActor
struct BatchWorkflowTests {
    @Test
    func copiesPastesAndSyncsRecipesWithoutWritingSourceFiles() throws {
        let fixture = try makeFixture(assetCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let catalog = CatalogStore(storageURL: fixture.catalogURL)
        let batch = BatchWorkflowStore(storageURL: fixture.presetURL)
        let originalData = try Data(contentsOf: fixture.rootURL.appendingPathComponent(fixture.assets[0].relativePath))
        let sourceAsset = fixture.assets[0]
        let destinationIDs = Set(fixture.assets.dropFirst().map(\.id))

        catalog.replaceRecipe(EditRecipe(exposure: 1.2, saturation: 0.3), for: [sourceAsset.id])
        batch.copyAdjustments(from: sourceAsset, catalog: catalog)
        #expect(batch.pasteAdjustments(to: destinationIDs, catalog: catalog))

        for asset in fixture.assets.dropFirst() {
            #expect(catalog.recipe(for: asset).exposure == 1.2)
            #expect(catalog.recipe(for: asset).saturation == 0.3)
        }

        catalog.replaceRecipe(EditRecipe(rotation: 12), for: [sourceAsset.id])
        #expect(batch.syncAdjustments(from: sourceAsset, to: Set(fixture.assets.map(\.id)), catalog: catalog))
        for asset in fixture.assets.dropFirst() {
            #expect(catalog.recipe(for: asset).rotation == 12)
        }
        #expect(try Data(contentsOf: fixture.rootURL.appendingPathComponent(sourceAsset.relativePath)) == originalData)
    }

    @Test
    func exportsFiftyItemsAndReportsIndividualFailures() async throws {
        let fixture = try makeFixture(assetCount: 50)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let exportDirectory = fixture.rootURL.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let catalog = CatalogStore(storageURL: fixture.catalogURL)
        let batch = BatchWorkflowStore(storageURL: fixture.presetURL)
        batch.startForTesting(
            assets: fixture.assets,
            directoryURL: exportDirectory,
            preset: .compactJPEG
        ) { asset in
            catalog.renderRequest(for: asset)
        }
        await waitForBatch(batch)

        #expect(batch.state == .completed)
        #expect(batch.completedCount == 50)
        #expect(batch.succeededCount == 50)
        #expect(batch.failures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil).count == 50)

        let missingAsset = makeAsset(sourceID: fixture.source.id, index: 99, relativePath: "missing.jpg")
        let failureDirectory = fixture.rootURL.appendingPathComponent("failure-export", isDirectory: true)
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        let selection = [fixture.assets[0], missingAsset, fixture.assets[1]]
        batch.startForTesting(
            assets: selection,
            directoryURL: failureDirectory,
            preset: .highQualityJPEG
        ) { asset in
            catalog.renderRequest(for: asset)
        }
        await waitForBatch(batch)

        #expect(batch.state == .completed)
        #expect(batch.completedCount == 3)
        #expect(batch.succeededCount == 2)
        #expect(batch.failures.count == 1)
        #expect(batch.failures.first?.assetID == missingAsset.id)
        #expect(try FileManager.default.contentsOfDirectory(at: failureDirectory, includingPropertiesForKeys: nil).count == 2)
    }

    @Test
    func cancellationStopsTheRemainingBatchItems() async throws {
        let fixture = try makeFixture(assetCount: 100)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let exportDirectory = fixture.rootURL.appendingPathComponent("cancelled-export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let catalog = CatalogStore(storageURL: fixture.catalogURL)
        let batch = BatchWorkflowStore(storageURL: fixture.presetURL)
        batch.startForTesting(
            assets: fixture.assets,
            directoryURL: exportDirectory,
            preset: .highQualityJPEG
        ) { asset in
            catalog.renderRequest(for: asset)
        }
        batch.cancel()
        await waitForBatch(batch)

        #expect(batch.state == .cancelled)
        #expect(batch.completedCount < 100)
    }

    @Test
    func exportPresetPersistsLocally() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-Preset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("presets.json")
        let customPreset = ExportPreset(id: UUID(), name: "测试预设", quality: 0.7, filenameSuffix: "-Test")

        let store = BatchWorkflowStore(storageURL: storageURL)
        store.savePreset(customPreset)
        let restoredStore = BatchWorkflowStore(storageURL: storageURL)

        #expect(restoredStore.presets.contains(customPreset))
    }

    private func waitForBatch(_ batch: BatchWorkflowStore) async {
        while batch.state == .running || batch.state == .cancelling {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeFixture(assetCount: Int) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-Batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let firstImageURL = rootURL.appendingPathComponent("fixture-0.jpg")
        try writeFixtureJPEG(to: firstImageURL)
        if assetCount > 1 {
            for index in 1..<assetCount {
                try FileManager.default.copyItem(at: firstImageURL, to: rootURL.appendingPathComponent("fixture-\(index).jpg"))
            }
        }

        let source = PhotoSource(
            id: UUID(),
            bookmarkData: Data(),
            displayName: "fixture",
            lastKnownPath: rootURL.path,
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: assetCount
        )
        let assets = (0..<assetCount).map { makeAsset(sourceID: source.id, index: $0, relativePath: "fixture-\($0).jpg") }
        let catalogURL = rootURL.appendingPathComponent("catalog.json")
        try CatalogPersistence(fileURL: catalogURL).save(CatalogSnapshot(sources: [source], assets: assets))

        return Fixture(
            rootURL: rootURL,
            catalogURL: catalogURL,
            presetURL: rootURL.appendingPathComponent("presets.json"),
            source: source,
            assets: assets
        )
    }

    private func makeAsset(sourceID: UUID, index: Int, relativePath: String) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: relativePath,
            filename: relativePath,
            fileExtension: "jpg",
            fileSize: 1,
            modifiedAt: .now,
            captureDate: nil,
            width: 32,
            height: 24,
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

    private func writeFixtureJPEG(to url: URL) throws {
        let image = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let context = CIContext(options: [.cacheIntermediates: false])
        let cgImage = try #require(context.createCGImage(image, from: image.extent))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private struct Fixture {
    let rootURL: URL
    let catalogURL: URL
    let presetURL: URL
    let source: PhotoSource
    let assets: [PhotoAsset]
}
