import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoAIMac

struct CullingWorkflowTests {
    @Test
    func localCullingGroupsSimilarImagesWithAnExplainableReasonWithoutWritingFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("burst-a.png")
        let jpeg = root.appendingPathComponent("burst-b.jpg")
        try writePatternImage(to: png, type: .png)
        try writePatternImage(to: jpeg, type: .jpeg)

        let before = try Data(contentsOf: png)
        let requests = try [request(for: png, root: root), request(for: jpeg, root: root)]
        let result = try await CullingAnalyzer.analyze(requests)
        let recommendation = try #require(result.recommendations.first)

        #expect(recommendation.assetIDs.count == 2)
        #expect(recommendation.signals.map(\.assetID).allSatisfy { recommendation.assetIDs.contains($0) })
        #expect(recommendation.reason.contains("清晰度信号"))
        #expect(try Data(contentsOf: png) == before)
    }

    @Test
    @MainActor
    func picksChangeOnlyWhenTheExplicitApprovalMethodIsCalled() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID()
        let source = PhotoSource(
            id: sourceID,
            bookmarkData: Data(),
            displayName: "fixture",
            lastKnownPath: root.path,
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: 2
        )
        let recommended = makeAsset(sourceID: sourceID, filename: "recommended.jpg")
        let untouched = makeAsset(sourceID: sourceID, filename: "untouched.jpg")
        let storageURL = root.appendingPathComponent("catalog.json")
        try CatalogPersistence(fileURL: storageURL).save(CatalogSnapshot(sources: [source], assets: [recommended, untouched]))
        let catalog = CatalogStore(storageURL: storageURL)

        #expect(catalog.assets.allSatisfy { $0.flag == .none })
        catalog.applyCullingPick(to: [recommended.id])
        #expect(catalog.assets.first(where: { $0.id == recommended.id })?.flag == .pick)
        #expect(catalog.assets.first(where: { $0.id == untouched.id })?.flag == PhotoFlag.none)
    }

    private func request(for url: URL, root: URL) throws -> CleanupAssetRequest {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return CleanupAssetRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: root.path,
            relativePath: url.lastPathComponent,
            filename: url.lastPathComponent,
            fileExtension: url.pathExtension,
            fileSize: Int64(values.fileSize ?? 0),
            captureDate: Date(timeIntervalSinceReferenceDate: 100),
            isRAW: false,
            hasEdits: false
        )
    }

    private func makeAsset(sourceID: UUID, filename: String) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: filename,
            filename: filename,
            fileExtension: "jpg",
            fileSize: 1,
            modifiedAt: .now,
            captureDate: .now,
            width: 10,
            height: 10,
            cameraMake: nil,
            cameraModel: nil,
            lens: nil,
            focalLength: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            mediaType: .image,
            rawType: nil,
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-Culling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePatternImage(to url: URL, type: UTType) throws {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 17 + y * 3) % 256)
                pixels[offset + 1] = UInt8((x * 7 + y * 19) % 256)
                pixels[offset + 2] = UInt8((x * 13 + y * 11) % 256)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
