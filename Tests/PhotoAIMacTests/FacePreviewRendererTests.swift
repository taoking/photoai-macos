import AppKit
import CoreGraphics
import Testing
@testable import PhotoAIMac

@MainActor
struct FacePreviewRendererTests {
    @Test
    func cropsNormalizedFaceBoundsIntoImagePreview() throws {
        let image = try #require(testImage(width: 160, height: 100))
        let preview = try #require(
            FacePreviewRenderer.crop(
                thumbnail: image,
                bounds: FaceBounds(x: 0.35, y: 0.2, width: 0.2, height: 0.25)
            )
        )

        #expect(preview.size.width > 0)
        #expect(preview.size.height > 0)
        #expect(preview.size.width <= 160)
        #expect(preview.size.height <= 100)
    }

    @Test
    func gracefullyCropsFacesAtTheImageEdge() throws {
        let image = try #require(testImage(width: 80, height: 80))
        let preview = try #require(
            FacePreviewRenderer.crop(
                thumbnail: image,
                bounds: FaceBounds(x: 0, y: 0, width: 0.08, height: 0.08)
            )
        )

        #expect(preview.size.width > 0)
        #expect(preview.size.height > 0)
    }

    private func testImage(width: Int, height: Int) -> NSImage? {
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
        context.setFillColor(NSColor.systemPurple.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
