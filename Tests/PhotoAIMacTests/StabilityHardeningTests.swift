import Foundation
import Testing
@testable import PhotoAIMac

struct StabilityHardeningTests {
    @Test
    func catalogFallsBackToLastValidSnapshotAfterInterruptedWrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CatalogPersistence(fileURL: root.appendingPathComponent("catalog.json"))
        let first = CatalogSnapshot(sources: [source(named: "first")], assets: [])
        let second = CatalogSnapshot(sources: [source(named: "second")], assets: [])
        try persistence.save(first)
        try persistence.save(second)

        try Data("{ damaged snapshot".utf8).write(to: persistence.fileURL, options: .atomic)
        let restored = try persistence.load()

        #expect(restored.sources.map(\.displayName) == ["first"])
        #expect(FileManager.default.fileExists(atPath: persistence.recoveryFileURL.path))
    }

    @Test
    func migratesLegacyCatalogWithoutSchemaVersion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CatalogPersistence(fileURL: root.appendingPathComponent("catalog.json"))
        try Data("{\"sources\":[],\"assets\":[]}".utf8).write(to: persistence.fileURL)

        let migrated = try persistence.load()

        #expect(migrated.schemaVersion == CatalogSnapshot.currentSchemaVersion)
        #expect(migrated.assets.isEmpty)
    }

    @Test
    func persistsAndRestoresLargeCatalogSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = source(named: "large")
        let assets = (0..<5_000).map { index in asset(sourceID: source.id, index: index) }
        let persistence = CatalogPersistence(fileURL: root.appendingPathComponent("catalog.json"))

        try persistence.save(CatalogSnapshot(sources: [source], assets: assets))
        let restored = try persistence.load()

        #expect(restored.assets.count == 5_000)
        #expect(restored.sources.first?.assetCount == 5_000)
    }

    @Test
    @MainActor
    func corruptThumbnailCompletesWithoutCachingOrCrashing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let filename = "corrupt.jpg"
        try Data([0x00, 0x12, 0x34]).write(to: root.appendingPathComponent(filename))
        let request = ThumbnailRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: root.path,
            relativePath: filename,
            modificationDate: .now,
            mediaType: .image
        )
        let store = ThumbnailStore()
        store.load(request) { _ in }

        for _ in 0..<100 where !store.completedKeys.contains(request.cacheKey) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.completedKeys.contains(request.cacheKey))
        #expect(store.image(for: request) == nil)
    }

    @Test
    @MainActor
    func missingLUTProducesRecoverableLocalError() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lutURL = root.appendingPathComponent("temporary.cube")
        let storageURL = root.appendingPathComponent("luts.json")
        try identityCube.write(to: lutURL, atomically: true, encoding: .utf8)
        let store = LUTStore(storageURL: storageURL)
        store.importLUT(at: lutURL)
        let preset = try #require(store.presets.first)
        try FileManager.default.removeItem(at: lutURL)

        let restored = LUTStore(storageURL: storageURL)
        #expect(restored.renderRecipe(for: EditRecipe(lut: LUTRecipe(presetID: preset.id))) == nil)
        #expect(restored.lastErrorMessage?.contains("无法读取 LUT") == true)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-Stability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func source(named name: String) -> PhotoSource {
        PhotoSource(
            id: UUID(),
            bookmarkData: Data(),
            displayName: name,
            lastKnownPath: "/fixture/\(name)",
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: name == "large" ? 5_000 : 0
        )
    }

    private func asset(sourceID: UUID, index: Int) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: "folder/image-\(index).jpg",
            filename: "image-\(index).jpg",
            fileExtension: "jpg",
            fileSize: 100,
            modifiedAt: .now,
            captureDate: .now,
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

    private var identityCube: String {
        """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
    }
}
