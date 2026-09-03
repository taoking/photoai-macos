@preconcurrency import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

struct SearchQuery: Hashable, Sendable {
    var freeText: [String] = []
    var ocrText: [String] = []
    var cameraText: [String] = []
    var lensText: [String] = []
    var formatText: [String] = []
    var minimumRating: Int?
    var exactRating: Int?
    var isFavorite: Bool?
    var flag: PhotoFlag?
    var capturedAfter: Date?
    var capturedBefore: Date?

    static let empty = SearchQuery()

    var isEmpty: Bool {
        freeText.isEmpty && ocrText.isEmpty && cameraText.isEmpty && lensText.isEmpty && formatText.isEmpty
            && minimumRating == nil && exactRating == nil && isFavorite == nil && flag == nil
            && capturedAfter == nil && capturedBefore == nil
    }

    func matches(_ asset: PhotoAsset) -> Bool {
        guard !isEmpty else { return false }
        if let minimumRating, asset.rating < minimumRating { return false }
        if let exactRating, asset.rating != exactRating { return false }
        if let isFavorite, asset.isFavorite != isFavorite { return false }
        if let flag, asset.flag != flag { return false }
        if let capturedAfter, (asset.captureDate ?? .distantPast) < capturedAfter { return false }
        if let capturedBefore, (asset.captureDate ?? .distantFuture) > capturedBefore { return false }

        let metadata = [
            asset.filename,
            asset.fileExtension,
            asset.rawType ?? "",
            asset.cameraMake ?? "",
            asset.cameraModel ?? "",
            asset.lens ?? "",
            asset.focalLength ?? "",
            asset.aperture ?? ""
        ].joined(separator: " ")

        return freeText.allSatisfy { metadata.localizedCaseInsensitiveContains($0) || (asset.ocrText ?? "").localizedCaseInsensitiveContains($0) }
            && ocrText.allSatisfy { (asset.ocrText ?? "").localizedCaseInsensitiveContains($0) }
            && cameraText.allSatisfy { "\(asset.cameraMake ?? "") \(asset.cameraModel ?? "")".localizedCaseInsensitiveContains($0) }
            && lensText.allSatisfy { (asset.lens ?? "").localizedCaseInsensitiveContains($0) }
            && formatText.allSatisfy {
                ($0.localizedCaseInsensitiveCompare("raw") == .orderedSame && asset.isRAW)
                    || asset.fileExtension.localizedCaseInsensitiveContains($0)
                    || (asset.rawType ?? "").localizedCaseInsensitiveContains($0)
            }
    }

    var explanation: String {
        guard !isEmpty else { return "输入关键词，或使用 rating>=4、format:raw、camera:…、text:…、after:YYYY-MM-DD 等条件。" }
        var clauses: [String] = []
        if !freeText.isEmpty { clauses.append("关键词：\(freeText.joined(separator: "、"))") }
        if !ocrText.isEmpty { clauses.append("OCR：\(ocrText.joined(separator: "、"))") }
        if !cameraText.isEmpty { clauses.append("相机：\(cameraText.joined(separator: "、"))") }
        if !lensText.isEmpty { clauses.append("镜头：\(lensText.joined(separator: "、"))") }
        if !formatText.isEmpty { clauses.append("格式：\(formatText.joined(separator: "、"))") }
        if let minimumRating { clauses.append("评分 ≥ \(minimumRating)") }
        if let exactRating { clauses.append("评分 = \(exactRating)") }
        if isFavorite == true { clauses.append("已收藏") }
        if flag == .pick { clauses.append("Pick") }
        if flag == .reject { clauses.append("Reject") }
        if let capturedAfter { clauses.append("拍摄日期不早于 \(Self.dateFormatter.string(from: capturedAfter))") }
        if let capturedBefore { clauses.append("拍摄日期不晚于 \(Self.dateFormatter.string(from: capturedBefore))") }
        return clauses.joined(separator: "；")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum SearchInterpretationSource: String, Sendable {
    case fallback
    case foundationModels

    var title: String {
        switch self {
        case .fallback: "本地规则解析"
        case .foundationModels: "Foundation Models 解释后，本地规则执行"
        }
    }
}

struct SearchInterpretation: Hashable, Sendable {
    let query: SearchQuery
    let source: SearchInterpretationSource
    let rawQuery: String

    static let empty = SearchInterpretation(query: .empty, source: .fallback, rawQuery: "")

    var explanation: String {
        "\(source.title)：\(query.explanation)"
    }
}

enum SearchQueryInterpreter {
    static func fallbackInterpretation(for input: String) -> SearchInterpretation {
        SearchInterpretation(query: FallbackSearchParser.parse(input), source: .fallback, rawQuery: input)
    }

    static func interpret(_ input: String) async -> SearchInterpretation {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return fallbackInterpretation(for: input) }

            do {
                let session = LanguageModelSession(
                    model: model,
                    instructions: """
                    You convert a photo search request into a single line of the following local DSL only:
                    rating>=N, rating:N, format:VALUE, camera:VALUE, lens:VALUE, text:VALUE,
                    favorite, pick, reject, after:YYYY-MM-DD, before:YYYY-MM-DD, and plain keywords.
                    Do not include explanations or any information not present in the request.
                    """
                )
                let response = try await session.respond(to: input)
                let parsed = FallbackSearchParser.parse(response.content)
                guard !parsed.isEmpty else { return fallbackInterpretation(for: input) }
                return SearchInterpretation(query: parsed, source: .foundationModels, rawQuery: input)
            } catch {
                return fallbackInterpretation(for: input)
            }
        }
        #endif
        return fallbackInterpretation(for: input)
    }
}

enum FallbackSearchParser {
    static func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        let tokens = tokens(in: input)

        for token in tokens {
            let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = normalized.lowercased()
            guard !lowercased.isEmpty else { continue }

            if let rating = rating(from: lowercased) {
                if rating.comparison == .minimum { query.minimumRating = rating.value }
                else { query.exactRating = rating.value }
            } else if lowercased == "raw" || lowercased == "format:raw" || lowercased == "格式:raw" {
                query.formatText.append("raw")
            } else if lowercased == "favorite" || lowercased == "收藏" || lowercased == "fav" {
                query.isFavorite = true
            } else if lowercased == "pick" {
                query.flag = .pick
            } else if lowercased == "reject" {
                query.flag = .reject
            } else if let value = value(afterAnyPrefix: ["camera:", "相机:"], in: normalized) {
                query.cameraText.append(value)
            } else if let value = value(afterAnyPrefix: ["lens:", "镜头:"], in: normalized) {
                query.lensText.append(value)
            } else if let value = value(afterAnyPrefix: ["format:", "格式:"], in: normalized) {
                query.formatText.append(value)
            } else if let value = value(afterAnyPrefix: ["text:", "ocr:", "文字:"], in: normalized) {
                query.ocrText.append(value)
            } else if let value = value(afterAnyPrefix: ["after:"], in: normalized), let date = date(from: value) {
                query.capturedAfter = date
            } else if let value = value(afterAnyPrefix: ["before:"], in: normalized), let date = date(from: value) {
                query.capturedBefore = date
            } else {
                query.freeText.append(normalized)
            }
        }

        return query
    }

    private enum RatingComparison { case minimum, exact }

    private static func rating(from token: String) -> (comparison: RatingComparison, value: Int)? {
        let expressions: [(String, RatingComparison)] = [
            ("rating>=", .minimum), ("评分>=", .minimum), ("rating:", .exact), ("评分:", .exact)
        ]
        for (prefix, comparison) in expressions where token.hasPrefix(prefix) {
            guard let value = Int(token.dropFirst(prefix.count)), (0...5).contains(value) else { return nil }
            return (comparison, value)
        }
        return nil
    }

    private static func value(afterAnyPrefix prefixes: [String], in token: String) -> String? {
        let lowercased = token.lowercased()
        for prefix in prefixes where lowercased.hasPrefix(prefix.lowercased()) {
            let value = String(token.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func tokens(in input: String) -> [String] {
        input.split(whereSeparator: \.isWhitespace).map { token in
            token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'，,;；"))
        }
    }

    private static func date(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

struct OCRIndexRequest: Hashable, Sendable {
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
}

enum OCRTextRecognizer {
    static func recognize(_ request: OCRIndexRequest) throws -> String {
        try withReadableURL(for: request) { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw OCRRecognizerError.unreadableSource
            }
            guard let image = DownsampledImageDecoder.image(from: source, maximumPixelSize: 2_000) else {
                throw OCRRecognizerError.unreadableSource
            }

            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([recognition])
            let candidates = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return candidates.joined(separator: "\n")
        }
    }

    private static func withReadableURL<Result>(
        for request: OCRIndexRequest,
        _ operation: (URL) throws -> Result
    ) throws -> Result {
        var isStale = false
        let bookmarkedRoot: URL?
        if request.bookmarkData.isEmpty {
            bookmarkedRoot = nil
        } else {
            bookmarkedRoot = try? URL(
                resolvingBookmarkData: request.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
        let rootURL = bookmarkedRoot ?? URL(fileURLWithPath: request.lastKnownRootPath)
        let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { rootURL.stopAccessingSecurityScopedResource() }
        }

        let fileURL = rootURL.appendingPathComponent(request.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OCRRecognizerError.unreadableSource
        }
        return try operation(fileURL)
    }
}

enum OCRRecognizerError: LocalizedError {
    case unreadableSource

    var errorDescription: String? { "无法读取用于 OCR 的图片。" }
}

enum OCRIndexState: Equatable {
    case idle
    case running
    case paused
    case completed

    var title: String {
        switch self {
        case .idle: "尚未开始 OCR 索引"
        case .running: "正在建立 OCR 索引"
        case .paused: "OCR 索引已暂停"
        case .completed: "OCR 索引已完成"
        }
    }
}

@MainActor
final class OCRIndexStore: ObservableObject {
    @Published private(set) var state: OCRIndexState = .idle
    @Published private(set) var totalCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var failureCount = 0

    private var pendingRequests: [OCRIndexRequest] = []
    private var indexingTask: Task<Void, Never>?
    private weak var catalog: CatalogStore?
    private var resumeRequested = false

    deinit { indexingTask?.cancel() }

    var progressDescription: String {
        guard totalCount > 0 else { return state.title }
        let failures = failureCount == 0 ? "" : "，失败 \(failureCount) 项"
        return "\(state.title)：\(completedCount) / \(totalCount)\(failures)"
    }

    func start(catalog: CatalogStore) {
        self.catalog = catalog
        guard state != .running else { return }
        if state != .paused {
            pendingRequests = catalog.ocrRequestsForUnindexedAssets()
            totalCount = pendingRequests.count
            completedCount = 0
            failureCount = 0
        }
        resume(catalog: catalog)
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        resumeRequested = false
        indexingTask?.cancel()
    }

    func resume(catalog: CatalogStore) {
        self.catalog = catalog
        guard state != .running else { return }
        guard !pendingRequests.isEmpty else {
            state = .completed
            return
        }
        // `pause()` 取消的 worker 可能尚未执行完 `finishIfNeeded`。保留一个恢复请求，
        // 由旧 worker 完成清理后启动新的 worker，避免两个 OCR 队列并发消费同一请求。
        guard indexingTask == nil else {
            resumeRequested = true
            return
        }
        state = .running

        indexingTask = Task.detached(priority: .utility) { [weak self, weak catalog] in
            while !Task.isCancelled {
                guard let request = await self?.takeNextRequest() else { break }
                do {
                    let text = try OCRTextRecognizer.recognize(request)
                    if Task.isCancelled {
                        await self?.requeue(request)
                        break
                    }
                    await catalog?.updateOCRText(text, for: request.assetID)
                    await self?.recordCompletion(failed: false)
                } catch {
                    if Task.isCancelled {
                        await self?.requeue(request)
                        break
                    }
                    await self?.recordCompletion(failed: true)
                }
            }
            await self?.finishIfNeeded()
        }
    }

    private func takeNextRequest() -> OCRIndexRequest? {
        guard state == .running, !pendingRequests.isEmpty else { return nil }
        return pendingRequests.removeFirst()
    }

    private func requeue(_ request: OCRIndexRequest) {
        pendingRequests.insert(request, at: 0)
    }

    private func recordCompletion(failed: Bool) {
        completedCount += 1
        if failed { failureCount += 1 }
    }

    private func finishIfNeeded() {
        indexingTask = nil
        if state == .paused, resumeRequested, let catalog {
            resumeRequested = false
            resume(catalog: catalog)
            return
        }
        if state == .running, pendingRequests.isEmpty {
            state = .completed
        }
    }
}
