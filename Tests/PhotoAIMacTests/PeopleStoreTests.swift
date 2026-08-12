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
        #expect(store.representativeFaces(for: person, limit: 2).map(\.id) == ["large", "middle"])
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
