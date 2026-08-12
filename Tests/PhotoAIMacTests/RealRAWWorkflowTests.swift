import Foundation
import ImageIO
import Testing
@testable import PhotoAIMac

@MainActor
struct RealRAWWorkflowTests {
    @Test(
        "RUN: real Sony ARW preview and export integration",
        .enabled(
            if: ProcessInfo.processInfo.environment["PHOTOAI_RUN_REAL_RAW"] == "1",
            "SKIPPED: set PHOTOAI_RUN_REAL_RAW=1 and PHOTOAI_REAL_RAW_PATH=/path/to/Sony.ARW to run this integration test."
        )
    )
    func realSonyARWPreviewAndExportIntegration() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOAI_REAL_RAW_PATH"], !path.isEmpty else {
            throw RealRAWIntegrationError.fixtureNotConfigured
        }
        let rawURL = URL(fileURLWithPath: path)
        guard rawURL.pathExtension.lowercased() == "arw", FileManager.default.fileExists(atPath: rawURL.path) else {
            throw RealRAWIntegrationError.invalidFixture
        }

        let request = ImageRenderRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: rawURL.deletingLastPathComponent().path,
            relativePath: rawURL.lastPathComponent,
            isRAW: true,
            recipe: .identity,
            lut: nil
        )

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
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) >= Int(preview.size.width))
        #expect((properties[kCGImagePropertyPixelHeight] as? Int ?? 0) >= Int(preview.size.height))
    }
}

private enum RealRAWIntegrationError: LocalizedError {
    case fixtureNotConfigured
    case invalidFixture

    var errorDescription: String? {
        switch self {
        case .fixtureNotConfigured: "PHOTOAI_REAL_RAW_PATH is required when PHOTOAI_RUN_REAL_RAW=1."
        case .invalidFixture: "PHOTOAI_REAL_RAW_PATH must point to an accessible Sony .ARW file."
        }
    }
}
