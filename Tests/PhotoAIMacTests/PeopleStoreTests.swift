import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct PeopleStoreTests {
    @Test
    func namesMergesHidesAndRestoresIndependentPersonRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-People-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PeopleStore(
            storageURL: directory.appendingPathComponent("people.json"),
            workingDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        let assetID = UUID()
        store.ingestDetectedFaces([
            face(assetID: assetID, id: "face-a", entityID: "entity-a"),
            face(assetID: assetID, id: "face-b", entityID: "entity-a"),
            face(assetID: assetID, id: "face-c", entityID: "entity-b")
        ])
        let people = store.visiblePeople
        let first = try #require(people.first(where: { $0.analyzerEntityIDs.contains("entity-a") }))
        let second = try #require(people.first(where: { $0.analyzerEntityIDs.contains("entity-b") }))

        store.rename(personID: first.id, to: "测试人物")
        store.merge(personID: second.id, into: first.id)
        let merged = try #require(store.visiblePeople.first(where: { $0.id == first.id }))
        #expect(merged.title == "测试人物")
        #expect(store.faceCount(for: merged) == 3)

        store.hide(personID: merged.id)
        #expect(store.visiblePeople.isEmpty)

        let restored = PeopleStore(
            storageURL: directory.appendingPathComponent("people.json"),
            workingDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        #expect(restored.people.first(where: { $0.id == merged.id })?.displayName == "测试人物")
        #expect(restored.people.first(where: { $0.id == second.id })?.mergedIntoID == merged.id)
    }

    @Test
    func representativeFacesPrioritizeLargerFaceSamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-People-Preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PeopleStore(
            storageURL: directory.appendingPathComponent("people.json"),
            workingDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        let assetID = UUID()
        store.ingestDetectedFaces([
            face(assetID: assetID, id: "small", entityID: "entity-a", width: 0.1, height: 0.1),
            face(assetID: assetID, id: "large", entityID: "entity-a", width: 0.4, height: 0.4),
            face(assetID: assetID, id: "middle", entityID: "entity-a", width: 0.2, height: 0.2)
        ])
        let person = try #require(store.visiblePeople.first)

        #expect(store.faceCount(for: person) == 3)
        #expect(store.photoCount(for: person) == 1)
        #expect(store.representativeFaces(for: person, limit: 2).map(\.id) == ["large", "middle"])
    }

    @Test
    func representativeFacesUseDeterministicTieBreakers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-People-Preview-Ties-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PeopleStore(
            storageURL: directory.appendingPathComponent("people.json"),
            workingDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        let assetA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let assetB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        store.ingestDetectedFaces([
            face(assetID: assetB, id: "b", entityID: "entity-a", width: 0.2, height: 0.2),
            face(assetID: assetA, id: "z", entityID: "entity-a", width: 0.2, height: 0.2),
            face(assetID: assetA, id: "a", entityID: "entity-a", width: 0.2, height: 0.2)
        ])
        let person = try #require(store.visiblePeople.first)

        #expect(store.representativeFaces(for: person).map(\.id) == ["a", "z", "b"])
    }

    @Test
    func peopleFacesRemainReachableAfterCatalogRescanAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-Catalog-People-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("person.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: imageURL)
        let catalogURL = directory.appendingPathComponent("catalog.json")
        let peopleURL = directory.appendingPathComponent("people.json")
        let catalog = CatalogStore(storageURL: catalogURL)
        await catalog.addFolder(directory)
        let originalAsset = try #require(catalog.assets.first(where: { $0.filename == "person.jpg" }))

        let people = PeopleStore(
            storageURL: peopleURL,
            workingDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        people.ingestDetectedFaces([face(assetID: originalAsset.id, id: "face-person", entityID: "entity-person")])

        await catalog.rescan(try #require(catalog.sources.first?.id))
        let rescannedAsset = try #require(catalog.assets.first(where: { $0.relativePath == "person.jpg" }))
        #expect(rescannedAsset.id == originalAsset.id)
        #expect(people.faces.first?.assetID == rescannedAsset.id)

        await catalog.flushPendingPersist()
        let restoredCatalog = CatalogStore(storageURL: catalogURL)
        let restoredPeople = PeopleStore(
            storageURL: peopleURL,
            workingDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        let restoredAsset = try #require(restoredCatalog.assets.first(where: { $0.relativePath == "person.jpg" }))
        let restoredPerson = try #require(restoredPeople.visiblePeople.first)

        #expect(restoredAsset.id == originalAsset.id)
        #expect(restoredPeople.faces(for: restoredPerson).map(\.assetID) == [restoredAsset.id])
        #expect(restoredPeople.photoCount(for: restoredPerson) == 1)
    }

    @Test
    func mediaIntelligenceRuntimeProbeReturnsRecordedResult() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-FaceProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = Result { try FaceAnalysisEngine.probe(workingDirectory: directory) }
        switch result {
        case .success:
            #expect(FileManager.default.fileExists(atPath: directory.path))
        case let .failure(error):
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    private func face(
        assetID: UUID,
        id: String,
        entityID: String,
        width: Double = 0.2,
        height: Double = 0.2
    ) -> DetectedFace {
        DetectedFace(
            id: id,
            assetID: assetID,
            analyzerEntityID: entityID,
            bounds: FaceBounds(x: 0.1, y: 0.1, width: width, height: height)
        )
    }
}
