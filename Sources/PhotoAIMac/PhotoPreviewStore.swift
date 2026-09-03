@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO

struct PhotoPreviewRequest: Sendable, Hashable {
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
    let modificationDate: Date?
    let mediaType: PhotoMediaType

    var cacheKey: String {
        let timestamp = modificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0
        return "\(assetID.uuidString)-\(timestamp)-2400"
    }
}

/// PhotoViewer 的屏幕预览缓存。先读内存和本地离线缓存，只有缓存未命中时才在后台
/// 解码原文件；RAW 与视频绝不会在主线程直接读取。
@MainActor
final class PhotoPreviewStore: ObservableObject {
    private let memoryCache = NSCache<NSString, NSImage>()
    private let cacheDirectoryURL: URL
    /// 按 `cacheKey` 去重的进行中解码任务。
    private var decodeTasks: [String: Task<NSImage?, Never>] = [:]
    /// 实际启动过的解码次数。供测试断言同一张照片不会被重复解码。
    private(set) var decodeCount = 0

    /// 磁盘缓存的总字节预算。
    ///
    /// 早先这里以未压缩 TIFF 落盘（2400px 约 15 MB/张）且没有任何淘汰策略，
    /// 浏览完一个 8,055 项的图库会写出 100 GB 以上。现在改为 JPEG 编码并设总量上限。
    private let diskCacheByteBudget: Int

    init(
        cacheDirectoryURL: URL = PhotoPreviewStore.defaultCacheDirectoryURL,
        diskCacheByteBudget: Int = 2 * 1_024 * 1_024 * 1_024
    ) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.diskCacheByteBudget = diskCacheByteBudget
        memoryCache.countLimit = 20
        memoryCache.totalCostLimit = 320 * 1_024 * 1_024
        PhotoPreviewCacheMaintenance.scheduleCleanup(
            directoryURL: cacheDirectoryURL,
            byteBudget: diskCacheByteBudget
        )
    }

    func cachedImage(for request: PhotoPreviewRequest) -> NSImage? {
        if let image = memoryCache.object(forKey: request.cacheKey as NSString) {
            return image
        }
        let diskURL = cacheURL(for: request)
        guard let image = NSImage(contentsOf: diskURL) else { return nil }
        storeInMemory(image, key: request.cacheKey)
        return image
    }

    /// 解码一张屏幕预览。
    ///
    /// 两条规则决定了这里的写法：
    ///
    /// 1. **解码结果必须先入缓存，再交由调用方处理取消。** 早先的实现在
    ///    `storeInMemory` 之前就用 `Task.isCancelled` 把图丢掉；而 `Task.detached`
    ///    并不继承取消，那次解码其实一路跑完了。大图预览页每次 ← → 都会重建子树并
    ///    取消 `.task`，于是每张照片都完整解码、每张都被丢弃，永远收敛不到有图状态，
    ///    页面就一直空白。现在无论调用方是否已取消，成品都会进缓存，下一次进入直接命中。
    /// 2. **同一张照片同时只解码一次。** 相同 `cacheKey` 的并发请求共享同一个任务，
    ///    避免预览页与筛选页各跑一遍。
    func image(for request: PhotoPreviewRequest) async -> NSImage? {
        if let cached = cachedImage(for: request) { return cached }
        return await decodeTask(for: request).value
    }

    /// 取回或新建该 `cacheKey` 的解码任务。任务本身不随调用方取消，
    /// 因为它的产出要留给缓存。
    private func decodeTask(for request: PhotoPreviewRequest) -> Task<NSImage?, Never> {
        let key = request.cacheKey
        if let existing = decodeTasks[key] { return existing }

        decodeCount += 1
        let task = Task { @MainActor [weak self] () -> NSImage? in
            let image = await Task.detached(priority: .userInitiated) {
                await PhotoPreviewRenderer.render(request)
            }.value

            guard let self else { return image }
            self.decodeTasks[key] = nil
            guard let image else { return nil }
            self.storeInMemory(image, key: key)
            self.writeToDiskCache(image, for: request)
            return image
        }
        decodeTasks[key] = task
        return task
    }

    private func writeToDiskCache(_ image: NSImage, for request: PhotoPreviewRequest) {
        let diskURL = cacheURL(for: request)
        let budget = diskCacheByteBudget
        Task.detached(priority: .utility) {
            guard let data = PhotoPreviewCacheMaintenance.encode(image) else { return }
            try? FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: diskURL, options: .atomic)
            PhotoPreviewCacheMaintenance.enforceBudget(
                directoryURL: diskURL.deletingLastPathComponent(),
                byteBudget: budget
            )
        }
    }

    private func cacheURL(for request: PhotoPreviewRequest) -> URL {
        cacheDirectoryURL.appendingPathComponent(
            "\(request.cacheKey).\(PhotoPreviewCacheMaintenance.fileExtension)",
            isDirectory: false
        )
    }

    private func storeInMemory(_ image: NSImage, key: String) {
        let pixelCount = max(1, Int(image.size.width * image.size.height))
        memoryCache.setObject(image, forKey: key as NSString, cost: pixelCount * 4)
    }

    private static let defaultCacheDirectoryURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("PhotoViewer", isDirectory: true)
    }()
}

private enum PhotoPreviewRenderer {
    static func render(_ request: PhotoPreviewRequest) async -> NSImage? {
        let rootURL = resolveRootURL(for: request)
        let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { rootURL.stopAccessingSecurityScopedResource() }
        }

        let fileURL = rootURL.appendingPathComponent(request.relativePath)
        if request.mediaType == .video {
            return await renderVideoFrame(fileURL)
        }
        return renderImagePreview(fileURL)
    }

    private static func resolveRootURL(for request: PhotoPreviewRequest) -> URL {
        var isStale = false
        return (try? URL(
            resolvingBookmarkData: request.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? URL(fileURLWithPath: request.lastKnownRootPath)
    }

    private static func renderImagePreview(_ fileURL: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        guard let image = DownsampledImageDecoder.image(from: source, maximumPixelSize: 2_400) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func renderVideoFrame(_ fileURL: URL) async -> NSImage? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2_400, height: 2_400)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        let image = result.image
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// 预览磁盘缓存的编码与容量维护。
enum PhotoPreviewCacheMaintenance {
    /// 屏幕预览是可随时重建的派生数据，没有理由为它保留无损像素。
    /// JPEG 相比原先的未压缩 TIFF 通常小一个数量级以上。
    static let fileExtension = "jpg"
    static let compressionQuality = 0.85

    static func encode(_ image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }

    /// 把缓存目录裁剪到预算以内，优先删除最久未被读取的文件。
    /// 同时清掉旧版本留下的 `.tiff`：它们的键名规则相同，但体积是现在的十几倍。
    static func enforceBudget(directoryURL: URL, byteBudget: Int) {
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var files: [(url: URL, lastUsed: Date, size: Int)] = []
        var totalBytes = 0
        for url in entries {
            if url.pathExtension.lowercased() == "tiff" {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { continue }
            let lastUsed = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            files.append((url, lastUsed, size))
            totalBytes += size
        }

        guard totalBytes > byteBudget else { return }
        for file in files.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard totalBytes > byteBudget else { break }
            try? FileManager.default.removeItem(at: file.url)
            totalBytes -= file.size
        }
    }

    /// 启动时做一次后台维护，让上一次运行遗留的超额缓存和旧格式文件被回收。
    static func scheduleCleanup(directoryURL: URL, byteBudget: Int) {
        Task.detached(priority: .background) {
            enforceBudget(directoryURL: directoryURL, byteBudget: byteBudget)
        }
    }
}
