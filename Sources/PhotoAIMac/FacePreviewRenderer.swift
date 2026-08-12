import AppKit
import Foundation

/// 从已有图库缩略图中裁剪人脸上下文。该渲染器不读取原图，也不运行新的人脸分析。
@MainActor
enum FacePreviewRenderer {
    private static let cache = NSCache<NSString, NSImage>()

    static func preview(
        thumbnail: NSImage,
        face: DetectedFace,
        thumbnailCacheKey: String
    ) -> NSImage? {
        let key = "\(thumbnailCacheKey)-\(face.id)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cropped = crop(thumbnail: thumbnail, bounds: face.bounds) else { return nil }
        cache.setObject(cropped, forKey: key)
        return cropped
    }

    static func crop(thumbnail: NSImage, bounds: FaceBounds) -> NSImage? {
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let faceRect = scaledFaceRect(bounds: bounds, imageSize: imageSize)
        let paddedRect = paddedSquare(around: faceRect, constrainedTo: imageSize)
        guard let output = image.cropping(to: paddedRect.integral) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }

    private static func scaledFaceRect(bounds: FaceBounds, imageSize: CGSize) -> CGRect {
        let looksNormalized = bounds.x >= 0 && bounds.y >= 0 && bounds.width > 0 && bounds.height > 0
            && bounds.x + bounds.width <= 1.001 && bounds.y + bounds.height <= 1.001
        if looksNormalized {
            // Media Intelligence / Vision 的归一化坐标原点在左下；CGImage 像素坐标原点在左上。
            return CGRect(
                x: bounds.x * imageSize.width,
                y: (1 - bounds.y - bounds.height) * imageSize.height,
                width: bounds.width * imageSize.width,
                height: bounds.height * imageSize.height
            )
        }
        return CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }

    private static func paddedSquare(around faceRect: CGRect, constrainedTo imageSize: CGSize) -> CGRect {
        let side = min(max(faceRect.width, faceRect.height) * 2.25, max(imageSize.width, imageSize.height))
        let raw = CGRect(
            x: faceRect.midX - side / 2,
            y: faceRect.midY - side / 2,
            width: side,
            height: side
        )
        let imageRect = CGRect(origin: .zero, size: imageSize)
        let intersection = raw.intersection(imageRect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return imageRect }
        return intersection
    }
}
