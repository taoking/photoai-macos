@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO

/// PhotoViewer 的屏幕预览缓存。先读内存和本地离线缓存，只有缓存未命中时才在后台
/// 解码原文件；RAW 与视频绝不会在主线程直接读取。
@MainActor
final class PhotoPreviewStore: ObservableObject {
    private let memoryCache = NSCache<NSString, NSImage>()
    /// 离线预览的磁盘层。与缩略图共用同一套按来源分目录的存储。
    private let cache: DerivedImageCache
    /// 按 assetID 去重的进行中解码任务。
    private var decodeTasks: [String: Task<NSImage?, Never>] = [:]
    /// 实际启动过的解码次数。供测试断言同一张照片不会被重复解码。
    private(set) var decodeCount = 0

    init(cache: DerivedImageCache = DerivedImageCache()) {
        self.cache = cache
        memoryCache.countLimit = 20
        memoryCache.totalCostLimit = 320 * 1_024 * 1_024
    }

    /// 只查内存。磁盘读取一律走 `image(for:)` 的后台路径。
    func cachedImage(for request: DerivedImageRequest) -> NSImage? {
        memoryCache.object(forKey: request.memoryCacheKey(for: .preview) as NSString)
    }

    /// 解码一张屏幕预览。
    ///
    /// 两条规则决定了这里的写法：
    ///
    /// 1. **解码结果必须先入缓存，再交由调用方处理取消。** 早先的实现在写缓存之前
    ///    就用 `Task.isCancelled` 把图丢掉；而 `Task.detached` 并不继承取消，
    ///    那次解码其实一路跑完了。大图预览页每次 ← → 都会重建子树并取消 `.task`，
    ///    于是每张照片都完整解码、每张都被丢弃，永远收敛不到有图状态。
    /// 2. **同一张照片同时只解码一次。** 相同资产的并发请求共享同一个任务。
    ///
    /// - Parameter allowsRendering: 来源已离线时传 false，只读缓存。
    func image(for request: DerivedImageRequest, allowsRendering: Bool = true) async -> NSImage? {
        if let cached = cachedImage(for: request) { return cached }
        return await decodeTask(for: request, allowsRendering: allowsRendering).value
    }

    private func decodeTask(
        for request: DerivedImageRequest,
        allowsRendering: Bool
    ) -> Task<NSImage?, Never> {
        let key = request.memoryCacheKey(for: .preview)
        if let existing = decodeTasks[key] { return existing }

        decodeCount += 1
        let cache = self.cache
        let task = Task { @MainActor [weak self] () -> NSImage? in
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                if let cached = cache.image(for: request, tier: .preview) { return cached }
                guard allowsRendering,
                      let rendered = DerivedImageRenderer.render(request, tier: .preview) else {
                    return nil
                }
                cache.store(rendered, for: request, tier: .preview)
                return rendered
            }.value

            guard let self else { return image }
            self.decodeTasks[key] = nil
            guard let image else { return nil }
            self.storeInMemory(image, key: key)
            return image
        }
        decodeTasks[key] = task
        return task
    }

    private func storeInMemory(_ image: NSImage, key: String) {
        let pixelCount = max(1, Int(image.size.width * image.size.height))
        memoryCache.setObject(image, forKey: key as NSString, cost: pixelCount * 4)
    }
}
