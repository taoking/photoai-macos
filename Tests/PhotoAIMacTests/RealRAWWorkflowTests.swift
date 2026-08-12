import Foundation
import ImageIO
import Testing
@testable import PhotoAIMac

@MainActor
struct RealRAWWorkflowTests {
    @Test
    func previewAndExportReachableLocalRAWWithoutTemporaryFiles() throws {
        let catalog = CatalogStore()
        guard let asset = catalog.assets.first(where: \.isRAW),
              let request = catalog.renderRequest(for: asset) else {
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-RAW-\(UUID().uuidString)", isDirectory: true)
        let outputURL = temporaryDirectory.appendingPathComponent("export.jpg")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let preview = try #require(ImageRenderer.preview(request, maximumPixelSize: 1_280))
        try ImageRenderer.exportJPEG(request, to: outputURL, quality: 0.9)
        let source = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        #expect(preview.size.width > 0)
        #expect(preview.size.height > 0)
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > Int(preview.size.width))
        #expect((properties[kCGImagePropertyPixelHeight] as? Int ?? 0) > Int(preview.size.height))
    }
}
