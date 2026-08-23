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

    init(cacheDirectoryURL: URL = PhotoPreviewStore.defaultCacheDirectoryURL) {
        self.cacheDirectoryURL = cacheDirectoryURL
        memoryCache.countLimit = 20
        memoryCache.totalCostLimit = 320 * 1_024 * 1_024
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

    func image(for request: PhotoPreviewRequest) async -> NSImage? {
        if let cached = cachedImage(for: request) { return cached }

        let image = await Task.detached(priority: .userInitiated) {
            await PhotoPreviewRenderer.render(request)
        }.value
        guard !Task.isCancelled, let image else { return nil }

        storeInMemory(image, key: request.cacheKey)
        let diskURL = cacheURL(for: request)
        Task.detached(priority: .utility) {
            guard let data = image.tiffRepresentation else { return }
            try? FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: diskURL, options: .atomic)
        }
        return image
    }

    private func cacheURL(for request: PhotoPreviewRequest) -> URL {
        cacheDirectoryURL.appendingPathComponent("\(request.cacheKey).tiff", isDirectory: false)
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
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: 2_400
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
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
