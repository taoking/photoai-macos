import AppKit
import CryptoKit
import Foundation
import ImageIO

/// 只读分析时传递的最小定位信息。清理建议不会修改 Catalog 或原始文件。
struct CleanupAssetRequest: Sendable, Hashable {
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let captureDate: Date?
    let isRAW: Bool
    let hasEdits: Bool
}

enum CleanupRecommendationKind: String, CaseIterable, Codable, Sendable {
    case exactDuplicate
    case similar
    case rawJPEGPair
    case screenshot
    case editedExport

    var title: String {
        switch self {
        case .exactDuplicate: "完全重复"
        case .similar: "相似照片"
        case .rawJPEGPair: "RAW / JPEG 配对"
        case .screenshot: "截图"
        case .editedExport: "编辑导出关联"
        }
    }

    var systemImage: String {
        switch self {
        case .exactDuplicate: "rectangle.on.rectangle"
        case .similar: "rectangle.3.group"
        case .rawJPEGPair: "camera.aperture"
        case .screenshot: "macwindow"
        case .editedExport: "square.and.arrow.up"
        }
    }
}

struct CleanupRecommendation: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: CleanupRecommendationKind
    /// 包含所有关联文件；这不是待删除列表。
    var assetIDs: [UUID]
    /// 只有用户明确选中后，才可能进入“移到废纸篓”确认步骤。
    var candidateAssetIDs: [UUID]
    let suggestedKeepAssetID: UUID?
    let explanation: String

    func removing(assetIDs removedIDs: Set<UUID>) -> CleanupRecommendation? {
        let remainingAssets = assetIDs.filter { !removedIDs.contains($0) }
        guard !remainingAssets.isEmpty else { return nil }
        var copy = self
        copy.assetIDs = remainingAssets
        copy.candidateAssetIDs.removeAll { removedIDs.contains($0) }
        return copy
    }
}

struct CleanupAnalysisFailure: Identifiable, Hashable, Sendable {
    let id = UUID()
    let assetID: UUID
    let message: String
}

struct CleanupAnalysisResult: Sendable {
    var recommendations: [CleanupRecommendation]
    var failures: [CleanupAnalysisFailure]
    var similarityStatistics: SimilarityCandidatePlan.Statistics
}

enum CleanupAnalysisState: Equatable {
    case idle
    case analyzing
    case complete
    case failed(String)

    var title: String {
        switch self {
        case .idle: "尚未分析"
        case .analyzing: "正在本地分析"
        case .complete: "本地清理建议已就绪"
        case let .failed(message): "分析失败：\(message)"
        }
    }
}

struct CleanupTrashFailure: Identifiable, Hashable, Sendable {
    let id = UUID()
    let assetID: UUID
    let message: String
}

struct CleanupTrashResult: Sendable {
    var movedAssetIDs: Set<UUID>
    var failures: [CleanupTrashFailure]
}

/// 这个协议使“移到废纸篓”的真实文件操作可在单元测试中替换，避免测试触碰用户废纸篓。
protocol CleanupTrashMoving {
    func trash(_ url: URL) throws -> URL
}

struct SystemTrashMover: CleanupTrashMoving {
    func trash(_ url: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL? ?? url
    }
}

enum CleanupTrashService {
    static func moveToTrash(
        _ requests: [CleanupAssetRequest],
        mover: any CleanupTrashMoving = SystemTrashMover()
    ) -> CleanupTrashResult {
        var movedAssetIDs = Set<UUID>()
        var failures: [CleanupTrashFailure] = []

        for request in requests {
            do {
                try CleanupFileAccess.withURL(for: request) { url in
                    _ = try mover.trash(url)
                }
                movedAssetIDs.insert(request.assetID)
            } catch {
                failures.append(CleanupTrashFailure(assetID: request.assetID, message: error.localizedDescription))
            }
        }
        return CleanupTrashResult(movedAssetIDs: movedAssetIDs, failures: failures)
    }
}

enum CleanupAnalyzer {
    static func analyze(_ requests: [CleanupAssetRequest]) async throws -> CleanupAnalysisResult {
        var recommendations = metadataRecommendations(for: requests)
        var failures: [CleanupAnalysisFailure] = []
        var hashesByAssetID: [UUID: String] = [:]
        var perceptualHashes: [(request: CleanupAssetRequest, hash: UInt64)] = []

        // 文件大小不同不可能是字节级重复；先分桶可避免无谓地读取大型 RAW。
        let requestsBySize = Dictionary(grouping: requests, by: \.fileSize)
        let duplicateCandidateIDs = Set(requestsBySize.values.filter { $0.count > 1 }.flatMap { $0.map(\.assetID) })

        for request in requests {
            try Task.checkCancellation()
            guard request.fileSize > 0 else { continue }

            do {
                try CleanupFileAccess.withURL(for: request) { url in
                    if duplicateCandidateIDs.contains(request.assetID) {
                        hashesByAssetID[request.assetID] = try SHA256.hash(data: Data(contentsOf: url, options: .mappedIfSafe))
                            .compactMap { String(format: "%02x", $0) }
                            .joined()
                    }

                    guard !request.isRAW, isImageExtension(request.fileExtension), let hash = perceptualHash(for: url) else {
                        return
                    }
                    perceptualHashes.append((request, hash))
                }
            } catch {
                failures.append(CleanupAnalysisFailure(assetID: request.assetID, message: error.localizedDescription))
            }
        }

        let exactGroups = Dictionary(grouping: hashesByAssetID.keys, by: { hashesByAssetID[$0] ?? "" })
        let exactPairs = exactGroups.values.filter { $0.count > 1 }
        for group in exactPairs {
            let ordered = order(group, using: requests)
            recommendations.append(
                CleanupRecommendation(
                    id: UUID(),
                    kind: .exactDuplicate,
                    assetIDs: ordered,
                    candidateAssetIDs: Array(ordered.dropFirst()),
                    suggestedKeepAssetID: ordered.first,
                    explanation: "文件内容哈希一致；建议保留一份，其余项目仍需由你确认。"
                )
            )
        }

        let similarityPlan = SimilarityCandidatePlanner.plan(for: perceptualHashes.map {
            SimilarityCandidate(assetID: $0.request.assetID, captureDate: $0.request.captureDate, visualHash: $0.hash)
        })
        let visualByAssetID = Dictionary(uniqueKeysWithValues: perceptualHashes.map { ($0.request.assetID, $0) })
        var similarComponents = SimilarityComponentBuilder(assetIDs: visualByAssetID.keys)

        for pair in similarityPlan.directLinks {
            guard !haveIdenticalContent(pair.firstID, pair.secondID, contentHashes: hashesByAssetID) else { continue }
            similarComponents.connect(pair.firstID, pair.secondID)
        }
        for pair in similarityPlan.candidatePairs {
            try Task.checkCancellation()
            guard let left = visualByAssetID[pair.firstID],
                  let right = visualByAssetID[pair.secondID],
                  !haveIdenticalContent(pair.firstID, pair.secondID, contentHashes: hashesByAssetID),
                  left.request.captureDate.isNear(right.request.captureDate, within: SimilarityCandidatePlanner.captureWindow),
                  left.hash.nonzeroBitCountDifference(to: right.hash) <= 6 else {
                continue
            }
            similarComponents.connect(pair.firstID, pair.secondID)
        }
        for group in similarComponents.groups() where group.count > 1 {
            let ordered = order(group, using: requests)
            recommendations.append(
                CleanupRecommendation(
                    id: UUID(),
                    kind: .similar,
                    assetIDs: ordered,
                    candidateAssetIDs: Array(ordered.dropFirst()),
                    suggestedKeepAssetID: ordered.first,
                    explanation: "低分辨率视觉指纹相近；这是建议，不代表文件内容相同。"
                )
            )
        }

        recommendations.sort {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.assetIDs.map(\.uuidString).joined() < $1.assetIDs.map(\.uuidString).joined()
        }
        return CleanupAnalysisResult(
            recommendations: recommendations,
            failures: failures,
            similarityStatistics: similarityPlan.statistics
        )
    }

    private static func metadataRecommendations(for requests: [CleanupAssetRequest]) -> [CleanupRecommendation] {
        var recommendations: [CleanupRecommendation] = []
        let byBaseName = Dictionary(grouping: requests, by: { normalizedBaseName($0.filename) })

        for group in byBaseName.values {
            let raw = group.filter(\.isRAW)
            let rendered = group.filter { !$0.isRAW && isImageExtension($0.fileExtension) }
            guard !raw.isEmpty, !rendered.isEmpty else { continue }
            let assetIDs = order(group.map(\.assetID), using: requests)
            recommendations.append(
                CleanupRecommendation(
                    id: UUID(),
                    kind: .rawJPEGPair,
                    assetIDs: assetIDs,
                    candidateAssetIDs: [],
                    suggestedKeepAssetID: nil,
                    explanation: "同名 RAW 与 JPEG 已关联；它们不是自动判定的重复文件。"
                )
            )
        }

        for request in requests where isScreenshot(request.filename) {
            recommendations.append(
                CleanupRecommendation(
                    id: UUID(),
                    kind: .screenshot,
                    assetIDs: [request.assetID],
                    candidateAssetIDs: [request.assetID],
                    suggestedKeepAssetID: nil,
                    explanation: "文件名符合截图命名规则；请在确认内容后自行决定是否移入废纸篓。"
                )
            )
        }

        for request in requests {
            guard let originalBase = exportOriginalBase(for: request.filename),
                  let originals = byBaseName[originalBase], !originals.isEmpty else {
                continue
            }
            let assetIDs = order(originals.map(\.assetID) + [request.assetID], using: requests)
            recommendations.append(
                CleanupRecommendation(
                    id: UUID(),
                    kind: .editedExport,
                    assetIDs: assetIDs,
                    candidateAssetIDs: [request.assetID],
                    suggestedKeepAssetID: originals.first?.assetID,
                    explanation: "文件名与已导出的编辑版本模式匹配；请确认导出版本是否仍需要保留。"
                )
            )
        }
        return recommendations
    }

    private static func order(_ ids: [UUID], using requests: [CleanupAssetRequest]) -> [UUID] {
        let requestsByID = Dictionary(uniqueKeysWithValues: requests.map { ($0.assetID, $0) })
        return ids.sorted {
            let left = requestsByID[$0]
            let right = requestsByID[$1]
            return (left?.captureDate ?? .distantFuture, left?.filename ?? "") < (right?.captureDate ?? .distantFuture, right?.filename ?? "")
        }
    }

    private static func normalizedBaseName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func exportOriginalBase(for filename: String) -> String? {
        let base = normalizedBaseName(filename)
        for suffix in ["-edited", "-web", "-export", "-photoai"] where base.hasSuffix(suffix) {
            return String(base.dropLast(suffix.count))
        }
        return nil
    }

    private static func isScreenshot(_ filename: String) -> Bool {
        let normalized = filename.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.contains("screenshot") || normalized.contains("screen shot") || normalized.contains("屏幕快照")
    }

    private static func isImageExtension(_ fileExtension: String) -> Bool {
        ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp"].contains(fileExtension.lowercased())
    }

    private static func haveIdenticalContent(
        _ first: UUID,
        _ second: UUID,
        contentHashes: [UUID: String]
    ) -> Bool {
        guard let firstHash = contentHashes[first], let secondHash = contentHashes[second] else { return false }
        return firstHash == secondHash
    }

    private static func perceptualHash(for url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let image = DownsampledImageDecoder.image(from: source, maximumPixelSize: 32) else { return nil }

        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let luma = stride(from: 0, to: pixels.count, by: 4).map { index in
            (Int(pixels[index]) * 299 + Int(pixels[index + 1]) * 587 + Int(pixels[index + 2]) * 114) / 1_000
        }
        let average = luma.reduce(0, +) / max(luma.count, 1)
        return luma.enumerated().reduce(into: UInt64(0)) { hash, value in
            if value.element >= average { hash |= UInt64(1) << UInt64(value.offset) }
        }
    }
}

@MainActor
final class CleanupWorkflowStore: ObservableObject {
    @Published private(set) var state: CleanupAnalysisState = .idle
    @Published private(set) var recommendations: [CleanupRecommendation] = []
    @Published private(set) var analysisFailures: [CleanupAnalysisFailure] = []
    @Published private(set) var trashFailures: [CleanupTrashFailure] = []
    @Published private(set) var isMovingToTrash = false
    @Published var selectedCandidateAssetIDs = Set<UUID>()

    private var analysisTask: Task<Void, Never>?

    deinit { analysisTask?.cancel() }

    func startAnalysis(catalog: CatalogStore) {
        guard state != .analyzing else { return }
        let requests = catalog.cleanupRequests()
        state = .analyzing
        recommendations = []
        analysisFailures = []
        trashFailures = []
        selectedCandidateAssetIDs = []

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try await CleanupAnalyzer.analyze(requests)
                }.value
                guard !Task.isCancelled else { return }
                recommendations = result.recommendations
                analysisFailures = result.failures
                state = .complete
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
            analysisTask = nil
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    func toggleCandidates(for recommendation: CleanupRecommendation) {
        let candidateIDs = Set(recommendation.candidateAssetIDs)
        if candidateIDs.isSubset(of: selectedCandidateAssetIDs) {
            selectedCandidateAssetIDs.subtract(candidateIDs)
        } else {
            selectedCandidateAssetIDs.formUnion(candidateIDs)
        }
    }

    func moveSelectedToTrash(catalog: CatalogStore) {
        guard !isMovingToTrash, !selectedCandidateAssetIDs.isEmpty else { return }
        let requestsByID = Dictionary(uniqueKeysWithValues: catalog.cleanupRequests().map { ($0.assetID, $0) })
        let requests = selectedCandidateAssetIDs.compactMap { requestsByID[$0] }
        guard !requests.isEmpty else { return }
        isMovingToTrash = true
        trashFailures = []

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CleanupTrashService.moveToTrash(requests)
            }.value
            guard let self else { return }
            catalog.removeLocalRecords(assetIDs: result.movedAssetIDs)
            selectedCandidateAssetIDs.subtract(result.movedAssetIDs)
            recommendations = recommendations.compactMap { $0.removing(assetIDs: result.movedAssetIDs) }
            trashFailures = result.failures
            isMovingToTrash = false
        }
    }
}

private enum CleanupFileAccess {
    static func withURL<Result>(for request: CleanupAssetRequest, operation: (URL) throws -> Result) throws -> Result {
        let rootURL: URL
        if !request.bookmarkData.isEmpty {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: request.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                rootURL = resolved
            } else {
                rootURL = URL(fileURLWithPath: request.lastKnownRootPath)
            }
        } else {
            rootURL = URL(fileURLWithPath: request.lastKnownRootPath)
        }
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            throw CleanupFileAccessError.unreadableSource
        }
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { rootURL.stopAccessingSecurityScopedResource() }
        }
        let fileURL = rootURL.appendingPathComponent(request.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CleanupFileAccessError.fileMissing
        }
        return try operation(fileURL)
    }
}

private enum CleanupFileAccessError: LocalizedError {
    case unreadableSource
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "无法访问照片来源（外置磁盘可能已断开）。"
        case .fileMissing: "找不到待处理文件。"
        }
    }
}

private extension Date? {
    func isNear(_ other: Date?, within interval: TimeInterval) -> Bool {
        guard let self, let other else { return true }
        return abs(self.timeIntervalSince(other)) <= interval
    }
}

private extension UInt64 {
    func nonzeroBitCountDifference(to other: UInt64) -> Int {
        (self ^ other).nonzeroBitCount
    }
}
