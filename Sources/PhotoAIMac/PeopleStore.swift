import Foundation

#if canImport(MediaIntelligence)
import MediaIntelligence
#endif

struct PersonRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    /// Analyzer IDs are only evidence for a person; the stable user-facing person ID is independent.
    var analyzerEntityIDs: Set<String>
    var isHidden: Bool
    var mergedIntoID: UUID?
    var createdAt: Date
    var updatedAt: Date

    var title: String { displayName.isEmpty ? "未命名人物" : displayName }
}

struct DetectedFace: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let assetID: UUID
    let analyzerEntityID: String?
    let bounds: FaceBounds
}

struct FaceBounds: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct FaceAnalysisRequest: Hashable, Sendable {
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
}

enum PeopleAnalysisStatus: Equatable {
    case unprobed
    case ready
    case unavailable(String)
    case analyzing
    case complete(Date)

    var title: String {
        switch self {
        case .unprobed: "尚未检查人物分析服务"
        case .ready: "人物分析服务可用"
        case let .unavailable(message): "人物分析不可用：\(message)"
        case .analyzing: "正在本地分析人物"
        case .complete: "人物分析已完成"
        }
    }
}

private struct PeopleSnapshot: Codable {
    var people: [PersonRecord]
    var faces: [DetectedFace]
}

private struct PeoplePersistence {
    let fileURL: URL

    static let defaultFileURL: URL = {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDirectory
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("people.json")
    }()

    func load() throws -> PeopleSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PeopleSnapshot(people: [], faces: [])
        }
        return try JSONDecoder().decode(PeopleSnapshot.self, from: Data(contentsOf: fileURL))
    }

    func save(_ snapshot: PeopleSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class PeopleStore: ObservableObject {
    @Published private(set) var people: [PersonRecord]
    @Published private(set) var faces: [DetectedFace]
    @Published private(set) var status: PeopleAnalysisStatus = .unprobed
    @Published private(set) var lastErrorMessage: String?
    @Published var searchText = ""

    private let persistence: PeoplePersistence
    private let workingDirectory: URL
    private var analysisTask: Task<Void, Never>?

    init(
        storageURL: URL = PeoplePersistence.defaultFileURL,
        workingDirectory: URL? = nil
    ) {
        persistence = PeoplePersistence(fileURL: storageURL)
        self.workingDirectory = workingDirectory ?? storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("FaceAnalysis", isDirectory: true)
        do {
            let snapshot = try persistence.load()
            people = snapshot.people
            faces = snapshot.faces
        } catch {
            people = []
            faces = []
            lastErrorMessage = "无法读取本地人物记录：\(error.localizedDescription)"
        }
    }

    deinit { analysisTask?.cancel() }

    var visiblePeople: [PersonRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return people
            .filter { !$0.isHidden && $0.mergedIntoID == nil }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func faceCount(for person: PersonRecord) -> Int {
        faces(for: person).count
    }

    /// 人物可能在同一张照片中被记录到多个脸框；界面中的“关联照片”必须去重。
    func photoCount(for person: PersonRecord) -> Int {
        Set(faces(for: person).map(\.assetID)).count
    }

    func faces(for person: PersonRecord) -> [DetectedFace] {
        faces.filter { face in
            guard let entityID = face.analyzerEntityID else { return false }
            return person.analyzerEntityIDs.contains(entityID)
        }
    }

    /// 选择面积较大的人脸作为识别线索；不会把这项启发式写入用户的人物记录。
    func representativeFaces(for person: PersonRecord, limit: Int = 3) -> [DetectedFace] {
        faces(for: person)
            .sorted { left, right in
                let leftArea = faceArea(left)
                let rightArea = faceArea(right)
                if leftArea != rightArea { return leftArea > rightArea }
                let assetOrder = left.assetID.uuidString.localizedStandardCompare(right.assetID.uuidString)
                if assetOrder != .orderedSame { return assetOrder == .orderedAscending }
                return left.id.localizedStandardCompare(right.id) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func probeAvailability() {
        guard status == .unprobed else { return }
        do {
            try FaceAnalysisEngine.probe(workingDirectory: workingDirectory)
            status = .ready
        } catch {
            status = .unavailable(error.localizedDescription)
        }
    }

    func startAnalysis(catalog: CatalogStore) {
        guard status != .analyzing else { return }
        let requests = catalog.faceAnalysisRequests()
        guard !requests.isEmpty else {
            status = .complete(.now)
            return
        }
        status = .analyzing
        lastErrorMessage = nil

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analyzedFaces = try await FaceAnalysisEngine.analyze(requests, workingDirectory: workingDirectory)
                guard !Task.isCancelled else { return }
                apply(analyzedFaces)
                status = .complete(.now)
            } catch {
                guard !Task.isCancelled else { return }
                status = .unavailable(error.localizedDescription)
                lastErrorMessage = "人物分析未完成：\(error.localizedDescription)"
            }
            analysisTask = nil
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        if case .analyzing = status { status = .ready }
    }

    func rename(personID: UUID, to name: String) {
        guard let index = people.firstIndex(where: { $0.id == personID }) else { return }
        people[index].displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        people[index].updatedAt = .now
        persist()
    }

    func hide(personID: UUID) {
        guard let index = people.firstIndex(where: { $0.id == personID }) else { return }
        people[index].isHidden = true
        people[index].updatedAt = .now
        persist()
    }

    func merge(personID: UUID, into destinationID: UUID) {
        guard personID != destinationID,
              let sourceIndex = people.firstIndex(where: { $0.id == personID }),
              let destinationIndex = people.firstIndex(where: { $0.id == destinationID }) else { return }
        people[destinationIndex].analyzerEntityIDs.formUnion(people[sourceIndex].analyzerEntityIDs)
        people[destinationIndex].updatedAt = .now
        people[sourceIndex].mergedIntoID = destinationID
        people[sourceIndex].updatedAt = .now
        persist()
    }

    func ingestDetectedFaces(_ analyzedFaces: [DetectedFace]) {
        apply(analyzedFaces)
    }

    private func apply(_ analyzedFaces: [DetectedFace]) {
        faces = analyzedFaces
        let entityIDs = Set(analyzedFaces.compactMap(\.analyzerEntityID))
        for entityID in entityIDs where !people.contains(where: { $0.analyzerEntityIDs.contains(entityID) }) {
            people.append(
                PersonRecord(
                    id: UUID(),
                    displayName: "",
                    analyzerEntityIDs: [entityID],
                    isHidden: false,
                    mergedIntoID: nil,
                    createdAt: .now,
                    updatedAt: .now
                )
            )
        }
        persist()
    }

    private func persist() {
        do {
            try persistence.save(PeopleSnapshot(people: people, faces: faces))
        } catch {
            lastErrorMessage = "无法保存本地人物记录：\(error.localizedDescription)"
        }
    }

    private func faceArea(_ face: DetectedFace) -> Double {
        max(0, face.bounds.width) * max(0, face.bounds.height)
    }
}

enum FaceAnalysisEngine {
    static func probe(workingDirectory: URL) throws {
        #if canImport(MediaIntelligence)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        _ = try FaceGroupAnalyzer(workingDirectory: workingDirectory)
        #else
        throw FaceAnalysisError.frameworkUnavailable
        #endif
    }

    static func analyze(_ requests: [FaceAnalysisRequest], workingDirectory: URL) async throws -> [DetectedFace] {
        #if canImport(MediaIntelligence)
        try probe(workingDirectory: workingDirectory)
        let analyzer = try FaceGroupAnalyzer(workingDirectory: workingDirectory)
        var activeRoots: [(url: URL, needsStop: Bool)] = []
        defer {
            for root in activeRoots where root.needsStop {
                root.url.stopAccessingSecurityScopedResource()
            }
        }

        let assets = try requests.compactMap { request -> MediaIntelligenceImageAsset? in
            let rootURL = try resolveRootURL(bookmarkData: request.bookmarkData, fallbackPath: request.lastKnownRootPath)
            if !activeRoots.contains(where: { $0.url == rootURL }) {
                activeRoots.append((rootURL, rootURL.startAccessingSecurityScopedResource()))
            }
            let fileURL = rootURL.appendingPathComponent(request.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return MediaIntelligenceImageAsset(
                id: .init(request.assetID.uuidString),
                kind: .url(fileURL)
            )
        }
        guard !assets.isEmpty else { return [] }

        let updates = try await analyzer.insertOrUpdateAssets(assets)
        for try await _ in updates {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        try await analyzer.update()

        var result: [DetectedFace] = []
        for try await face in analyzer.allFaces {
            guard let assetID = UUID(uuidString: face.assetID.rawValue) else { continue }
            result.append(
                DetectedFace(
                    id: face.id.rawValue,
                    assetID: assetID,
                    analyzerEntityID: face.entityID?.rawValue,
                    bounds: FaceBounds(
                        x: face.bounds.origin.x,
                        y: face.bounds.origin.y,
                        width: face.bounds.width,
                        height: face.bounds.height
                    )
                )
            )
        }
        return result
        #else
        throw FaceAnalysisError.frameworkUnavailable
        #endif
    }

    private static func resolveRootURL(bookmarkData: Data, fallbackPath: String) throws -> URL {
        if !bookmarkData.isEmpty {
            var isStale = false
            if let URL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return URL
            }
        }
        let fallback = URL(fileURLWithPath: fallbackPath)
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw FaceAnalysisError.unreadableSource
        }
        return fallback
    }
}

enum FaceAnalysisError: LocalizedError {
    case frameworkUnavailable
    case unreadableSource

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable: "当前系统不提供 Media Intelligence 人物分析。"
        case .unreadableSource: "无法访问用于人物分析的本地照片。"
        }
    }
}
