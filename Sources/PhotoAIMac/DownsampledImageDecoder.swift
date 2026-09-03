import CoreGraphics
import Foundation
import ImageIO

/// 全 App 统一的降采样解码入口。所有"把原图缩到某个尺寸"的读取路径都必须走这里。
///
/// `kCGImageSourceCreateThumbnailFromImageAlways` 的语义是"忽略内嵌预览，永远从完整
/// 图像重新渲染"。对 MTP 挂载盘上 68.6 MB 的 Sony ARW，本机实测缩略图 480 需要
/// 30.04 秒、预览 2400 需要 36.09 秒；只读内嵌预览则分别是 0.441 秒与 0.350 秒。
/// 大图预览页"空白"正是在等这几十秒。
///
/// 但内嵌预览不能无条件采用：JPEG 通常只内嵌 160×120 的 EXIF 缩略图，无论请求 480 还是
/// 2400 都只返回这一张。若直接删掉上述 flag，本机 4,068 张 JPG 会全部退化为 160×120，
/// 网格变糊、OCR 失效。
///
/// 因此这里按尺寸判定：内嵌预览的长边达到请求值的 ``minimumAcceptableRatio`` 才采用，
/// 否则回退到完整解码。RAW（内嵌约 1616 px 预览）因此走快路径，JPEG 保持既有画质与行为。
enum DownsampledImageDecoder {
    /// 内嵌预览长边至少要达到请求尺寸的这个比例才算够用。
    ///
    /// 取 0.5 而不是 1.0，是为了让 ARW 的 1616 px 内嵌预览能服务 2400 px 的大图预览请求：
    /// 满屏预览接受 1616 px 的代价，远小于为多出的像素多等 36 秒。
    static let minimumAcceptableRatio = 0.5

    /// 优先返回内嵌预览；不存在或过小时回退到完整解码。
    static func image(from source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        if let embedded = embeddedPreview(from: source, maximumPixelSize: maximumPixelSize),
           isAcceptable(embedded, maximumPixelSize: maximumPixelSize) {
            return embedded
        }
        return fullyDecodedImage(from: source, maximumPixelSize: maximumPixelSize)
    }

    /// 判定一张内嵌预览是否够用。原图本身就比请求小时判定为不够用，
    /// 此时回退路径会直接解码原图，成本同样很低。
    static func isAcceptable(_ image: CGImage, maximumPixelSize: Int) -> Bool {
        let longestSide = max(image.width, image.height)
        return Double(longestSide) >= Double(maximumPixelSize) * minimumAcceptableRatio
    }

    /// 内嵌预览优先：不带 `Always`，ImageIO 因此不会为了缩图去解完整图像。
    /// 保留 `IfAbsent` 是为了让完全没有内嵌预览的文件在这一次调用里直接解码完成，
    /// 不必先返回 nil 再走一次回退。
    static func embeddedPreview(from source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 完整解码后降采样。这是慢路径，只在内嵌预览缺失或过小时使用。
    static func fullyDecodedImage(from source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
