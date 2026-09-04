@preconcurrency import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// 从原始照片产出各级派生图。
///
/// 关键性质：**一次解码可以产出所有级别**。昂贵的是读文件加解码，不是编码——
/// 实测同一批真实照片，解出最大一级后在内存里缩放出其余级别，增量成本只有
/// 一次 JPEG 编码。因此预热时不必为缩略图和离线预览各读一遍原文件。
enum DerivedImageRenderer {
    /// 按最大的那一级解码一次，其余级别由它在内存中缩放得到。
    static func render(_ request: DerivedImageRequest, tiers: Set<DerivedImageTier>) -> [DerivedImageTier: NSImage] {
        guard !tiers.isEmpty else { return [:] }

        let rootURL = resolveRootURL(for: request)
        let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { rootURL.stopAccessingSecurityScopedResource() }
        }

        let fileURL = rootURL.appendingPathComponent(request.relativePath)
        guard let base = decodeBase(at: fileURL, mediaType: request.mediaType, tiers: tiers) else {
            return [:]
        }

        var results: [DerivedImageTier: NSImage] = [:]
        for tier in tiers {
            guard let scaled = downscale(base, toMaximumPixelSize: tier.maximumPixelSize) else { continue }
            results[tier] = NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
        }
        return results
    }

    /// 只渲染一个级别时的便捷入口。
    static func render(_ request: DerivedImageRequest, tier: DerivedImageTier) -> NSImage? {
        render(request, tiers: [tier])[tier]
    }

    private static func decodeBase(
        at fileURL: URL,
        mediaType: PhotoMediaType,
        tiers: Set<DerivedImageTier>
    ) -> CGImage? {
        let largest = tiers.map(\.maximumPixelSize).max() ?? DerivedImageTier.thumbnail.maximumPixelSize
        if mediaType == .video {
            return videoFrame(at: fileURL, maximumPixelSize: largest)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return DownsampledImageDecoder.image(from: source, maximumPixelSize: largest)
    }

    /// 已经不大于目标尺寸时原样返回，绝不放大。
    private static func downscale(_ image: CGImage, toMaximumPixelSize maximumPixelSize: Int) -> CGImage? {
        let longestSide = max(image.width, image.height)
        guard longestSide > maximumPixelSize else { return image }

        let scale = Double(maximumPixelSize) / Double(longestSide)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func videoFrame(at fileURL: URL, maximumPixelSize: Int) -> CGImage? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    private static func resolveRootURL(for request: DerivedImageRequest) -> URL {
        var isStale = false
        // 调试构建每次重新签名都会让旧书签失效，回退到已记录的本地路径即可；
        // 它绝不会扩大到用户选择的文件夹之外。
        let resolved = try? URL(
            resolvingBookmarkData: request.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return resolved ?? URL(fileURLWithPath: request.lastKnownRootPath)
    }
}
