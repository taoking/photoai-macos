@preconcurrency import AppKit
import Foundation
import ImageIO

struct ThumbnailRequest: Sendable, Hashable {
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
    let modificationDate: Date?
    let mediaType: PhotoMediaType

    var cacheKey: String {
        let timestamp = modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(assetID.uuidString)-\(timestamp)"
    }
}

/// 单个缩略图订阅方自己的展示状态。它不发布到 `ThumbnailStore`，从而避免任意一张
/// 缩略图完成时唤醒整个网格。
enum ThumbnailViewState {
    case idle
    case loading
    case loaded(NSImage)
    case failed

    static func completed(with image: NSImage?) -> ThumbnailViewState {
        guard let image else { return .failed }
        return .loaded(image)
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 保留已经交给 Cell 的图像。界面恢复时，Cell 还会优先检查
    /// `ThumbnailStore` 的缓存：即使 SwiftUI 丢失了这份局部 `@State`，也不应
    /// 把一张已缓存的照片重新画成空白占位符。
    var loadedImage: NSImage? {
        guard case let .loaded(image) = self else { return nil }
        return image
    }
}

@MainActor
final class ThumbnailStore: ObservableObject {
    private let memoryCache = NSCache<NSString, NSImage>()
    /// 缩略图始终是可延后的界面增强项。使用 utility QoS，避免快速切换页面时
    /// 大量解码任务与主线程/交互事件争抢 CPU。
    ///
    /// 并发度按卷自适应，因为它的收益在不同卷上符号相反：本机实测同一批 24 张
    /// 照片，在 MTP/macFUSE 卷上串行 18.0 秒、6 路并发反而 22.4 秒；而本地卷
    /// 上并发能明显缩短首屏填充。慢速卷因此走串行队列，本地卷走有界并发队列
    /// （有上限是为了避免快速滚动时堆出大量并发解码）。
    ///
    /// 注意这条结论只适用于缩略图解码。扫描期的 EXIF 读取在同一块 MTP 卷上
    /// 并发反而有 5.09 倍加速，那里保持并行。两者差别在于单次读取的数据量。
    private let localVolumeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.taoking.PhotoAIMac.thumbnail.local"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount))
        return queue
    }()

    private let slowVolumeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.taoking.PhotoAIMac.thumbnail.slow"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// 按来源根路径缓存卷类型判定，避免每张缩略图都做一次系统调用。
    private var volumeIsLocalByRootPath: [String: Bool] = [:]

    /// 网络卷与 macFUSE（MTP、SMB 等）挂载的 `volumeIsLocal` 为 false；
    /// 本地盘以及 U 盘、SD 卡都是 true，后者速度足够，应当并发。
    func isLocalVolume(rootPath: String) -> Bool {
        if let cached = volumeIsLocalByRootPath[rootPath] { return cached }
        let values = try? URL(fileURLWithPath: rootPath).resourceValues(forKeys: [.volumeIsLocalKey])
        // 读不到卷信息时按本地处理：一次探测失败不该让整个来源退化成串行。
        let isLocal = values?.volumeIsLocal ?? true
        volumeIsLocalByRootPath[rootPath] = isLocal
        return isLocal
    }

    private func renderingQueue(for request: ThumbnailRequest) -> OperationQueue {
        isLocalVolume(rootPath: request.lastKnownRootPath) ? localVolumeQueue : slowVolumeQueue
    }
    private var inFlightKeys = Set<String>()
    private var callbacksByKey: [String: [UUID: (NSImage?) -> Void]] = [:]
    private(set) var completedKeys = Set<String>()
    /// 只在界面从编辑器等覆盖层返回时递增。可见 Cell 监听此值并从缓存重新取得
    /// 自己的缩略图，或重新订阅仍在进行的加载；它不是每张缩略图完成时的全局广播。
    @Published private(set) var visibleSubscriberGeneration = 0

    /// 缩略图的磁盘缓存目录。
    ///
    /// 此前 `ThumbnailStore` 只有内存缓存，进程一退出全部作废：重启后每一张
    /// 缩略图都要重新从原文件解码。在 MTP 这类慢速卷上实测 0.75 秒/张，
    /// 于是每次重启都要重新等上几分钟。大图预览一直有磁盘缓存，缩略图没有。
    private let cacheDirectoryURL: URL
    private let diskCacheByteBudget: Int

    init(
        cacheDirectoryURL: URL = ThumbnailStore.defaultCacheDirectoryURL,
        diskCacheByteBudget: Int = 512 * 1_024 * 1_024
    ) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.diskCacheByteBudget = diskCacheByteBudget
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 160 * 1_024 * 1_024
        ImageCacheMaintenance.scheduleCleanup(
            directoryURL: cacheDirectoryURL,
            byteBudget: diskCacheByteBudget
        )
    }

    static var defaultCacheDirectoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private func cacheURL(for request: ThumbnailRequest) -> URL {
        cacheDirectoryURL.appendingPathComponent(
            "\(request.cacheKey).\(ImageCacheMaintenance.fileExtension)",
            isDirectory: false
        )
    }

    func image(for request: ThumbnailRequest) -> NSImage? {
        memoryCache.object(forKey: request.cacheKey as NSString)
    }

    /// 编辑器覆盖层退出后，显式让仍在屏幕上的缩略图订阅方重新连接到缓存/加载队列。
    ///
    /// SwiftUI 在 macOS beta 上可能保留 LazyVGrid Cell 的实例，却跳过其一次
    /// `onAppear`。若该 Cell 恰好在编辑期间错过回调，就会一直保留旧的 loading /
    /// failed 状态。这里一次性的 generation 变更只影响当前可见 Cell，不会恢复过去
    /// "每解码一张图就刷新整个网格" 的性能问题。
    func refreshVisibleSubscribers() {
        visibleSubscriberGeneration &+= 1
    }

    /// 仅让仍可见的请求方在完成时更新自己的 `@State`。缓存本身不发布全局变更，
    /// 因而一张缩略图解码完成不会迫使整个网格重算。
    @discardableResult
    func load(
        _ request: ThumbnailRequest,
        completion: @escaping (NSImage?) -> Void
    ) -> ThumbnailLoadToken? {
        if let cachedImage = image(for: request) {
            completion(cachedImage)
            return nil
        }

        let key = request.cacheKey
        let token = ThumbnailLoadToken(key: key, id: UUID())
        callbacksByKey[key, default: [:]][token.id] = completion
        guard !inFlightKeys.contains(key) else { return token }
        inFlightKeys.insert(key)

        // 磁盘缓存的读写都放在后台队列上。`image(for:)` 只查内存，
        // 因为它会在 SwiftUI 的 body 求值期间被调用，绝不能碰文件系统。
        let diskURL = cacheURL(for: request)
        let budget = diskCacheByteBudget
        renderingQueue(for: request).addOperation { [weak self] in
            var image = ImageCacheMaintenance.loadImage(at: diskURL)
            if image == nil, let rendered = ThumbnailRenderer.render(request) {
                image = rendered
                ImageCacheMaintenance.write(rendered, to: diskURL, byteBudget: budget)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightKeys.remove(key)
                if let image {
                    let pixelCount = max(1, Int(image.size.width * image.size.height))
                    self.memoryCache.setObject(image, forKey: key as NSString, cost: pixelCount * 4)
                }
                self.completedKeys.insert(key)
                let callbacks: [(NSImage?) -> Void]
                if let registeredCallbacks = self.callbacksByKey.removeValue(forKey: key) {
                    callbacks = Array(registeredCallbacks.values)
                } else {
                    callbacks = []
                }
                callbacks.forEach { $0(image) }
            }
        }
        return token
    }

    func cancel(_ token: ThumbnailLoadToken?) {
        guard let token else { return }
        callbacksByKey[token.key]?[token.id] = nil
        if callbacksByKey[token.key]?.isEmpty == true {
            callbacksByKey[token.key] = nil
        }
    }
}

struct ThumbnailLoadToken: Hashable {
    fileprivate let key: String
    fileprivate let id: UUID
}

private enum ThumbnailRenderer {
    static func render(_ request: ThumbnailRequest) -> NSImage? {
        guard request.mediaType == .image else { return nil }

        var isStale = false
        let resolvedRootURL = try? URL(
            resolvingBookmarkData: request.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        // A debug build's unsigned identity can invalidate an earlier bookmark.
        // The fallback is only a local path already recorded for this source; it
        // never expands access beyond the folder that the user selected.
        let rootURL = resolvedRootURL ?? URL(fileURLWithPath: request.lastKnownRootPath)

        let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileURL = rootURL.appendingPathComponent(request.relativePath)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        guard let image = DownsampledImageDecoder.image(from: source, maximumPixelSize: 480) else {
            return nil
        }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
