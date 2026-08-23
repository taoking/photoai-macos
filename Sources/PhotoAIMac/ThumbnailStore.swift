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
}

@MainActor
final class ThumbnailStore: ObservableObject {
    private let memoryCache = NSCache<NSString, NSImage>()
    /// 缩略图始终是可延后的界面增强项。使用 utility QoS，避免快速切换页面时
    /// 大量解码任务与主线程/交互事件争抢 CPU。
    private let renderingQueue = DispatchQueue(label: "com.taoking.PhotoAIMac.thumbnail", qos: .utility)
    private var inFlightKeys = Set<String>()
    private var callbacksByKey: [String: [UUID: (NSImage?) -> Void]] = [:]
    private(set) var completedKeys = Set<String>()
    /// 只在界面从编辑器等覆盖层返回时递增。可见 Cell 监听此值并从缓存重新取得
    /// 自己的缩略图，或重新订阅仍在进行的加载；它不是每张缩略图完成时的全局广播。
    @Published private(set) var visibleSubscriberGeneration = 0

    init() {
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 160 * 1_024 * 1_024
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

        renderingQueue.async { [weak self] in
            let image = ThumbnailRenderer.render(request)

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

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: 480
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
