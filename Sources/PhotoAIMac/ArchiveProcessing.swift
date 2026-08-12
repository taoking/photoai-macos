@preconcurrency import AppKit
import CryptoKit
import Foundation
import ImageIO

struct ArchiveProcessingRequest: Sendable, Hashable {
    let asset: PhotoAsset
    let bookmarkData: Data
    let rootPath: String
    let existingMetadata: ArchiveAssetMetadata
}

struct ArchiveProcessingResult: Sendable {
    let assetID: UUID
    let metadata: ArchiveAssetMetadata
    let didHash: Bool
    let didCreatePreview: Bool
}

enum ArchiveProcessingError: LocalizedError, Equatable {
    case sourceUnavailable
    case unreadableImage
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "原始文件当前不可访问。"
        case .unreadableImage: "无法生成离线预览。"
        case let .processingFailed(message): message
        }
    }
}

/// 受 ArchiveCoordinator 串行调度；单项不持有 UI 状态，也不修改原始文件。
enum ArchiveProcessor {
    /// 1280 px 在 Retina 网格和人物预览中仍足够辨认，同时比旧 1440 px 明显降低缓存占用。
    static let previewLongEdge = 1_280

    /// 小图保留更多细节；接近最大边长的预览优先控制缓存体积。
    static func previewQuality(width: Int, height: Int) -> CGFloat {
        let pixelCount = width * height
        if pixelCount >= 1_200_000 { return 0.68 }
        if pixelCount <= 450_000 { return 0.74 }
        return 0.71
    }

    static func process(_ request: ArchiveProcessingRequest, previewDirectory: URL) throws -> ArchiveProcessingResult {
        let asset = request.asset
        let needsHash = request.existingMetadata.needsHash(for: asset)
        let needsPreview = request.existingMetadata.needsPreview(for: asset)
        guard needsHash || needsPreview else {
            return ArchiveProcessingResult(assetID: asset.id, metadata: request.existingMetadata, didHash: false, didCreatePreview: false)
        }

        return try withSourceURL(request) { sourceURL in
            try Task.checkCancellation()
            var metadata = request.existingMetadata
            let now = Date.now
            if metadata.firstSeenAt == nil { metadata.firstSeenAt = now }
            metadata.lastSeenAt = now
            metadata.lastError = nil

            var didHash = false
            if needsHash {
                // 先生成快速视觉指纹；完整 SHA-256 仍是“完全重复”的唯一证据。
                metadata.visualHash = asset.mediaType == .image ? visualHash(for: sourceURL) : nil
            }

            var didCreatePreview = false
            if needsPreview {
                do {
                    metadata.preview = try createPreview(assetID: asset.id, sourceURL: sourceURL, sourceModifiedAt: asset.modifiedAt, previewDirectory: previewDirectory)
                    metadata.previewState = .complete
                    didCreatePreview = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ArchiveProcessingError where error == .unreadableImage {
                    metadata.preview = nil
                    metadata.previewState = .unsupported
                    metadata.lastError = error.localizedDescription
                } catch {
                    metadata.preview = nil
                    metadata.previewState = .retryableFailure
                    metadata.lastError = error.localizedDescription
                }
            }
            if needsHash {
                metadata.exactHash = try exactHash(for: sourceURL)
                metadata.hashedFileSize = asset.fileSize
                metadata.hashedModifiedAt = asset.modifiedAt
                metadata.hashUpdatedAt = now
                metadata.hashState = .complete
                didHash = true
            }
            return ArchiveProcessingResult(assetID: asset.id, metadata: metadata, didHash: didHash, didCreatePreview: didCreatePreview)
        }
    }

    static func previewURL(for metadata: ArchiveAssetMetadata, previewDirectory: URL) -> URL? {
        metadata.preview.map { previewDirectory.appendingPathComponent($0.relativePath) }
    }

    static func clearPreviews(at previewDirectory: URL) throws {
        guard FileManager.default.fileExists(atPath: previewDirectory.path) else { return }
        try FileManager.default.removeItem(at: previewDirectory)
    }

    private static func withSourceURL<Result>(_ request: ArchiveProcessingRequest, _ operation: (URL) throws -> Result) throws -> Result {
        var isStale = false
        let bookmarkedRoot = request.bookmarkData.isEmpty ? nil : try? URL(
            resolvingBookmarkData: request.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let rootURL = bookmarkedRoot ?? URL(fileURLWithPath: request.rootPath)
        let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { rootURL.stopAccessingSecurityScopedResource() }
        }
        let sourceURL = rootURL.appendingPathComponent(request.asset.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw ArchiveProcessingError.sourceUnavailable }
        return try operation(sourceURL)
    }

    private static func exactHash(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func visualHash(for url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = 8
        let height = 8
        var values = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &values,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let average = values.reduce(0) { $0 + Int($1) } / values.count
        return values.enumerated().reduce(UInt64(0)) { partial, item in
            item.element >= average ? partial | (UInt64(1) << UInt64(item.offset)) : partial
        }
    }

    private static func createPreview(assetID: UUID, sourceURL: URL, sourceModifiedAt: Date?, previewDirectory: URL) throws -> OfflinePreviewMetadata {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { throw ArchiveProcessingError.unreadableImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: previewLongEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ArchiveProcessingError.unreadableImage }
        try Task.checkCancellation()
        let identifier = assetID.uuidString.lowercased()
        let relativePath = "\(identifier.prefix(2))/\(identifier)-v\(OfflinePreviewMetadata.currentVersion).jpg"
        let destinationURL = previewDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(identifier)-\(UUID().uuidString)-preview-writing.jpg")
        try? FileManager.default.removeItem(at: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, "public.jpeg" as CFString, 1, nil) else { throw ArchiveProcessingError.unreadableImage }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: previewQuality(width: image.width, height: image.height)] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw ArchiveProcessingError.unreadableImage }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        let byteSize = Int64((try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return OfflinePreviewMetadata(relativePath: relativePath, width: image.width, height: image.height, byteSize: byteSize, generatedAt: .now, sourceModifiedAt: sourceModifiedAt)
    }
}

@MainActor
final class ArchiveCoordinator: ObservableObject {
    @Published private(set) var progress = ArchiveWorkProgress()
    @Published private(set) var lastErrorMessage: String?

    static let maximumConcurrentWork = 2

    private let persistence: ArchiveIndexPersistence?
    private let initializationError: Error?
    private let previewDirectory: URL
    private var requestQueue = ArchiveRequestQueue()
    private var processingTask: Task<Void, Never>?
    private weak var catalog: CatalogStore?
    private var inFlightAssetIDs = Set<UUID>()
    private var userPaused = false
    private var resumeRequested = false

    init(
        catalogURL: URL = CatalogPersistence.defaultFileURL,
        previewDirectory: URL? = nil
    ) {
        let resolvedPreviewDirectory = previewDirectory ?? catalogURL
            .deletingLastPathComponent()
            .appendingPathComponent("ArchivePreviews", isDirectory: true)
        do {
            persistence = try ArchiveIndexPersistence(databaseURL: ArchiveIndexPersistence.databaseURL(for: catalogURL))
            initializationError = nil
        } catch {
            persistence = nil
            initializationError = error
        }
        self.previewDirectory = resolvedPreviewDirectory
    }

    init(persistence: ArchiveIndexPersistence, previewDirectory: URL) {
        self.persistence = persistence
        initializationError = nil
        self.previewDirectory = previewDirectory
    }

    deinit { processingTask?.cancel() }

    func start(catalog: CatalogStore) {
        self.catalog = catalog
        guard persistence != nil else {
            lastErrorMessage = "无法打开本地归档索引。\(initializationError.map { " \($0.localizedDescription)" } ?? "")"
            return
        }
        guard progress.state != .running, progress.state != .paused else { return }
        requestQueue = ArchiveRequestQueue(catalog.initialArchiveProcessingRequests())
        progress = ArchiveWorkProgress(state: requestQueue.isEmpty ? .complete : .paused, totalCount: requestQueue.count)
        userPaused = false
        resume(catalog: catalog)
    }

    /// 只接收 Catalog 已经计算好的增量请求。完成一项不会重新扫描整个图库。
    func enqueue(_ requests: [ArchiveProcessingRequest], catalog: CatalogStore) {
        self.catalog = catalog
        let additions = requestQueue.enqueue(requests, excluding: inFlightAssetIDs)
        guard !additions.isEmpty else { return }
        if progress.state == .complete || progress.state == .idle {
            progress = ArchiveWorkProgress(state: .paused, totalCount: additions.count)
            userPaused = false
            resume(catalog: catalog)
        } else {
            progress.totalCount += additions.count
        }
    }

    func pause() {
        guard progress.state == .running else { return }
        progress.state = .paused
        userPaused = true
        resumeRequested = false
        processingTask?.cancel()
    }

    func resume(catalog: CatalogStore) {
        self.catalog = catalog
        guard let persistence else {
            lastErrorMessage = "无法打开本地归档索引。\(initializationError.map { " \($0.localizedDescription)" } ?? "")"
            return
        }
        guard progress.state != .running else { return }
        guard processingTask == nil else {
            // 已出队的 worker 可能尚未把取消请求安全地放回队列；此时不能把
            // 空队列误判为完成，待 worker 收敛后由 finishIfNeeded 继续。
            resumeRequested = true
            userPaused = false
            return
        }
        guard !requestQueue.isEmpty else {
            progress.state = .complete
            return
        }
        resumeRequested = false
        userPaused = false
        progress.state = .running
        let previewDirectory = previewDirectory
        let maximumConcurrentWork = Self.maximumConcurrentWork
        processingTask = Task.detached(priority: .utility) { [weak self, weak catalog, persistence] in
            await withTaskGroup(of: ArchiveWorkOutcome.self) { group in
                for _ in 0..<maximumConcurrentWork {
                    if let request = await self?.takeNextRequest() {
                        group.addTask { Self.process(request, persistence: persistence, previewDirectory: previewDirectory) }
                    }
                }

                while let outcome = await group.next() {
                    switch outcome {
                    case let .success(request, result, relationships):
                        await catalog?.applyArchiveProcessingResult(result, relationships: relationships)
                        await self?.recordCompletion(result: result, failed: false)
                        _ = request
                    case let .failure(request, error):
                        if error == .sourceUnavailable {
                            await catalog?.markArchiveLocationUnavailable(for: request.asset)
                        }
                        await self?.recordFailure(assetID: request.asset.id, message: error.localizedDescription)
                    case let .cancelled(request):
                        await self?.requeue(request)
                    }
                    guard !Task.isCancelled, let next = await self?.takeNextRequest() else { continue }
                    group.addTask { Self.process(next, persistence: persistence, previewDirectory: previewDirectory) }
                }
            }
            await self?.finishIfNeeded()
        }
    }

    nonisolated private static func process(
        _ request: ArchiveProcessingRequest,
        persistence: ArchiveIndexPersistence,
        previewDirectory: URL
    ) -> ArchiveWorkOutcome {
        do {
            let result = try ArchiveProcessor.process(request, previewDirectory: previewDirectory)
            if Task.isCancelled { return .cancelled(request) }
            let relationships = try persistence.save(result: result)
            return .success(request, result, relationships)
        } catch is CancellationError {
            return .cancelled(request)
        } catch let error as ArchiveProcessingError {
            return .failure(request, error)
        } catch {
            return .failure(request, .processingFailed(error.localizedDescription))
        }
    }

    private func takeNextRequest() -> ArchiveProcessingRequest? {
        guard progress.state == .running, let request = requestQueue.dequeue() else { return nil }
        inFlightAssetIDs.insert(request.asset.id)
        return request
    }

    private func requeue(_ request: ArchiveProcessingRequest) {
        inFlightAssetIDs.remove(request.asset.id)
        _ = requestQueue.enqueue([request], excluding: inFlightAssetIDs)
    }

    private func recordCompletion(result: ArchiveProcessingResult?, failed: Bool, message: String? = nil) {
        if let result { inFlightAssetIDs.remove(result.assetID) }
        progress.completedCount += 1
        if result?.didHash == true { progress.hashCompletedCount += 1 }
        if result?.didCreatePreview == true { progress.previewCompletedCount += 1 }
        if failed {
            progress.failureCount += 1
            lastErrorMessage = message
        }
    }

    private func recordFailure(assetID: UUID, message: String) {
        inFlightAssetIDs.remove(assetID)
        progress.completedCount += 1
        progress.failureCount += 1
        lastErrorMessage = message
    }

    private func finishIfNeeded() {
        processingTask = nil
        if progress.state == .paused, resumeRequested, let catalog {
            resumeRequested = false
            resume(catalog: catalog)
            return
        }
        if progress.state == .running, requestQueue.isEmpty { progress.state = .complete }
    }

    /// 清理与预览写入共享同一协调器：先取消并等待当前 worker，随后再更新 SQLite 和目录。
    func clearOfflinePreviews(catalog: CatalogStore) async {
        let shouldResume = progress.state == .running && !userPaused
        let trackedIDs = requestQueue.assetIDs.union(inFlightAssetIDs)
        let task = processingTask
        pause()
        await task?.value
        do {
            try catalog.evictOfflinePreviews()
            let refreshed = catalog.archiveProcessingRequests(for: trackedIDs)
            requestQueue = ArchiveRequestQueue(refreshed)
            progress = ArchiveWorkProgress(state: requestQueue.isEmpty ? .complete : .paused, totalCount: requestQueue.count)
            resumeRequested = false
            if shouldResume { resume(catalog: catalog) }
        } catch {
            lastErrorMessage = "无法清理离线预览：\(error.localizedDescription)"
        }
    }

    func rebuildOfflinePreviews(catalog: CatalogStore) {
        let requests = catalog.restoreEvictedOfflinePreviews()
        guard !requests.isEmpty else { return }
        enqueue(requests, catalog: catalog)
        if progress.state == .paused { resume(catalog: catalog) }
    }
}

/// Array + 游标避免每个请求 `removeFirst()` 造成的线性搬移；仅在已消费前缀较大时整体压缩。
struct ArchiveRequestQueue: Sendable {
    private var storage: [ArchiveProcessingRequest] = []
    private var readIndex = 0
    private var queuedAssetIDs = Set<UUID>()

    init(_ requests: [ArchiveProcessingRequest] = []) {
        _ = enqueue(requests, excluding: [])
    }

    var isEmpty: Bool { readIndex >= storage.count }
    var count: Int { storage.count - readIndex }
    var assetIDs: Set<UUID> { queuedAssetIDs }

    @discardableResult
    mutating func enqueue(_ requests: [ArchiveProcessingRequest], excluding excludedAssetIDs: Set<UUID>) -> [ArchiveProcessingRequest] {
        var additions: [ArchiveProcessingRequest] = []
        for request in requests where !excludedAssetIDs.contains(request.asset.id) {
            if queuedAssetIDs.insert(request.asset.id).inserted {
                storage.append(request)
                additions.append(request)
            }
        }
        return additions
    }

    mutating func dequeue() -> ArchiveProcessingRequest? {
        guard readIndex < storage.count else { return nil }
        let request = storage[readIndex]
        readIndex += 1
        queuedAssetIDs.remove(request.asset.id)
        if readIndex == storage.count {
            // 已完全消费时才释放数组；正常出队始终只是 O(1) 游标前移。
            storage.removeAll(keepingCapacity: true)
            readIndex = 0
        }
        return request
    }
}

private enum ArchiveWorkOutcome: Sendable {
    case success(ArchiveProcessingRequest, ArchiveProcessingResult, [ArchiveDuplicateRelationship])
    case failure(ArchiveProcessingRequest, ArchiveProcessingError)
    case cancelled(ArchiveProcessingRequest)
}
