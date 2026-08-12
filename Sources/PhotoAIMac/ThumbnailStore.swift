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

@MainActor
final class ThumbnailStore: ObservableObject {
    private let memoryCache = NSCache<NSString, NSImage>()
    private let renderingQueue = DispatchQueue(label: "com.taoking.PhotoAIMac.thumbnail", qos: .userInitiated)
    private var inFlightKeys = Set<String>()
    @Published private(set) var completedKeys = Set<String>()

    init() {
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 160 * 1_024 * 1_024
    }

    func image(for request: ThumbnailRequest) -> NSImage? {
        memoryCache.object(forKey: request.cacheKey as NSString)
    }

    func load(_ request: ThumbnailRequest) {
        let key = request.cacheKey
        guard image(for: request) == nil, !inFlightKeys.contains(key) else { return }
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
            }
        }
    }
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
