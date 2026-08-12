import CoreGraphics
import Foundation
import ImageIO
import Vision

struct CullingSignal: Hashable, Sendable {
    let assetID: UUID
    /// 基于缩略图拉普拉斯能量的清晰度信号，不是对照片艺术价值的判断。
    let sharpness: Double
    /// Vision 的 faceCaptureQuality（0...1）；没有人脸或请求不可用时为 nil。
    let faceQuality: Double?
}

struct CullingRecommendation: Identifiable, Hashable, Sendable {
    let id: UUID
    let assetIDs: [UUID]
    let recommendedAssetID: UUID
    let signals: [CullingSignal]
    let reason: String
}

struct CullingAnalysisFailure: Identifiable, Hashable, Sendable {
    let id = UUID()
    let assetID: UUID
    let message: String
}

struct CullingAnalysisResult: Sendable {
    let recommendations: [CullingRecommendation]
    let failures: [CullingAnalysisFailure]
}

enum CullingState: Equatable {
    case idle
    case analyzing
    case complete
    case failed(String)

    var title: String {
        switch self {
        case .idle: "尚未开始智能选片"
        case .analyzing: "正在计算本地视觉信号"
        case .complete: "本地选片建议已就绪"
        case let .failed(message): "选片分析失败：\(message)"
        }
    }
}

enum CullingAnalyzer {
    static func analyze(_ requests: [CleanupAssetRequest]) async throws -> CullingAnalysisResult {
        var analyzed: [AnalyzedAsset] = []
        var failures: [CullingAnalysisFailure] = []

        for request in requests where !request.isRAW && Self.isImageExtension(request.fileExtension) {
            try Task.checkCancellation()
            do {
                let output = try CullingFileAccess.withURL(for: request) { url in
                    try analyzeImage(at: url)
                }
                analyzed.append(
                    AnalyzedAsset(
                        request: request,
                        visualHash: output.visualHash,
                        signal: CullingSignal(
                            assetID: request.assetID,
                            sharpness: output.signal.sharpness,
                            faceQuality: output.signal.faceQuality
                        )
                    )
                )
            } catch {
                failures.append(CullingAnalysisFailure(assetID: request.assetID, message: error.localizedDescription))
            }
        }

        var unassigned = Set(analyzed.indices)
        var recommendations: [CullingRecommendation] = []
        while let seed = unassigned.first {
            var group = Set([seed])
            var pending = [seed]
            unassigned.remove(seed)
            while let current = pending.popLast() {
                for candidate in unassigned where shouldGroup(analyzed[current], analyzed[candidate]) {
                    group.insert(candidate)
                    pending.append(candidate)
                }
                unassigned.subtract(group)
            }
            guard group.count > 1 else { continue }
            let members = group.map { analyzed[$0] }
            let sortedMembers = members.sorted { $0.request.filename.localizedStandardCompare($1.request.filename) == .orderedAscending }
            let preferred = sortedMembers.max { preferenceScore(for: $0.signal) < preferenceScore(for: $1.signal) }!
            let signals = sortedMembers.map(\.signal)
            recommendations.append(
                CullingRecommendation(
                    id: UUID(),
                    assetIDs: sortedMembers.map { $0.request.assetID },
                    recommendedAssetID: preferred.request.assetID,
                    signals: signals,
                    reason: reason(for: preferred.signal, among: signals)
                )
            )
        }

        recommendations.sort { $0.assetIDs.map(\.uuidString).joined() < $1.assetIDs.map(\.uuidString).joined() }
        return CullingAnalysisResult(recommendations: recommendations, failures: failures)
    }

    private struct AnalyzedAsset: Sendable {
        let request: CleanupAssetRequest
        let visualHash: UInt64
        let signal: CullingSignal
    }

    private static func shouldGroup(_ left: AnalyzedAsset, _ right: AnalyzedAsset) -> Bool {
        guard capturesAreNear(left.request.captureDate, right.request.captureDate, within: 86_400) else { return false }
        return (left.visualHash ^ right.visualHash).nonzeroBitCount <= 6
    }

    private static func preferenceScore(for signal: CullingSignal) -> Double {
        signal.sharpness * 0.7 + (signal.faceQuality ?? signal.sharpness) * 0.3
    }

    private static func reason(for preferred: CullingSignal, among signals: [CullingSignal]) -> String {
        let sharpness = Int((preferred.sharpness * 100).rounded())
        if let faceQuality = preferred.faceQuality {
            return "相似组中本地清晰度信号为 \(sharpness)/100，人脸采集质量为 \(Int((faceQuality * 100).rounded()))/100；建议保留此项。"
        }
        return "相似组中本地清晰度信号为 \(sharpness)/100，且未检测到可比较的人脸采集质量；建议保留此项。"
    }

    private static func analyzeImage(at url: URL) throws -> (visualHash: UInt64, signal: CullingSignal) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CullingError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CullingError.unreadableImage
        }
        let grayPixels = try grayscalePixels(for: image, width: 64, height: 64)
        let quality = faceCaptureQuality(for: image)
        let signal = CullingSignal(assetID: UUID(), sharpness: sharpness(for: grayPixels, width: 64, height: 64), faceQuality: quality)
        return (visualHash(for: grayPixels, width: 64), signal)
    }

    // Replaces the generated UUID with the Catalog asset ID at the call site.
    private static func visualHash(for pixels: [UInt8], width: Int) -> UInt64 {
        let sampleStep = width / 8
        let values = (0..<8).flatMap { y in
            (0..<8).map { x in pixels[(y * sampleStep) * width + x * sampleStep] }
        }
        let average = values.reduce(0) { $0 + Int($1) } / max(values.count, 1)
        return values.enumerated().reduce(into: UInt64(0)) { result, element in
            if element.element >= average { result |= UInt64(1) << UInt64(element.offset) }
        }
    }

    private static func sharpness(for pixels: [UInt8], width: Int, height: Int) -> Double {
        var total = 0.0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Int(pixels[y * width + x]) * 4
                let adjacent = Int(pixels[(y - 1) * width + x]) + Int(pixels[(y + 1) * width + x])
                    + Int(pixels[y * width + x - 1]) + Int(pixels[y * width + x + 1])
                total += Double(abs(center - adjacent))
                count += 1
            }
        }
        return min(total / Double(max(count, 1)) / 255, 1)
    }

    private static func grayscalePixels(for image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw CullingError.renderFailed
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func faceCaptureQuality(for image: CGImage) -> Double? {
        let request = VNDetectFaceCaptureQualityRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return nil }
        return request.results?.compactMap(\.faceCaptureQuality).map(Double.init).max()
    }

    private static func isImageExtension(_ fileExtension: String) -> Bool {
        ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp"].contains(fileExtension.lowercased())
    }

    private static func capturesAreNear(_ left: Date?, _ right: Date?, within interval: TimeInterval) -> Bool {
        guard let left, let right else { return true }
        return abs(left.timeIntervalSince(right)) <= interval
    }
}

@MainActor
final class CullingWorkflowStore: ObservableObject {
    @Published private(set) var state: CullingState = .idle
    @Published private(set) var recommendations: [CullingRecommendation] = []
    @Published private(set) var failures: [CullingAnalysisFailure] = []
    @Published var selectedRecommendationIDs = Set<UUID>()

    private var analysisTask: Task<Void, Never>?

    deinit { analysisTask?.cancel() }

    func startAnalysis(catalog: CatalogStore) {
        guard state != .analyzing else { return }
        let requests = catalog.cleanupRequests()
        state = .analyzing
        recommendations = []
        failures = []
        selectedRecommendationIDs = []

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try await CullingAnalyzer.analyze(requests)
                }.value
                guard !Task.isCancelled else { return }
                recommendations = result.recommendations
                failures = result.failures
                state = .complete
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
            analysisTask = nil
        }
    }

    func cancelAnalysis() { analysisTask?.cancel() }

    func toggleSelection(_ recommendationID: UUID) {
        if selectedRecommendationIDs.contains(recommendationID) {
            selectedRecommendationIDs.remove(recommendationID)
        } else {
            selectedRecommendationIDs.insert(recommendationID)
        }
    }

    func applyApprovedPicks(catalog: CatalogStore) {
        let assetIDs = recommendations
            .filter { selectedRecommendationIDs.contains($0.id) }
            .map(\.recommendedAssetID)
        catalog.applyCullingPick(to: Set(assetIDs))
        selectedRecommendationIDs = []
    }
}

private enum CullingFileAccess {
    static func withURL<Result>(for request: CleanupAssetRequest, operation: (URL) throws -> Result) throws -> Result {
        let rootURL: URL
        if !request.bookmarkData.isEmpty {
            var stale = false
            rootURL = (try? URL(
                resolvingBookmarkData: request.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )) ?? URL(fileURLWithPath: request.lastKnownRootPath)
        } else {
            rootURL = URL(fileURLWithPath: request.lastKnownRootPath)
        }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { throw CullingError.unreadableSource }
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { rootURL.stopAccessingSecurityScopedResource() }
        }
        let fileURL = rootURL.appendingPathComponent(request.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw CullingError.unreadableSource }
        return try operation(fileURL)
    }
}

private enum CullingError: LocalizedError {
    case unreadableSource
    case unreadableImage
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "无法访问用于智能选片的本地照片。"
        case .unreadableImage: "无法生成照片的本地视觉信号。"
        case .renderFailed: "无法处理照片缩略图。"
        }
    }
}
