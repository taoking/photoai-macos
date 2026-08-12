import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoAIMac

struct EditRecipeTests {
    @Test
    func centerCropUsesRequestedAspectRatio() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let recipe = EditRecipe(crop: CropRecipe(aspectRatio: 1))

        let output = ImageProcessingPipeline.apply(source, recipe: recipe)

        #expect(output.extent.width == 100)
        #expect(output.extent.height == 100)
    }

    @Test
    func recipePersistsWithoutTouchingSourceAssetFields() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceID = UUID()
        let source = PhotoSource(
            id: sourceID,
            bookmarkData: Data(),
            displayName: "fixture",
            lastKnownPath: rootURL.path,
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: 1
        )
        var asset = fixtureAsset(sourceID: sourceID)
        asset.editRecipe = EditRecipe(exposure: 1.25, saturation: 0.2, rotation: 15)
        let storageURL = rootURL.appendingPathComponent("catalog.json")

        try CatalogPersistence(fileURL: storageURL).save(CatalogSnapshot(sources: [source], assets: [asset]))
        let restored = try CatalogPersistence(fileURL: storageURL).load()

        #expect(restored.assets[0].filename == "fixture.jpg")
        #expect(restored.assets[0].editRecipe?.exposure == 1.25)
        #expect(restored.assets[0].editRecipe?.rotation == 15)
    }

    @Test
    func previewAndJPEGExportUseTheSameCropSemantics() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let inputURL = rootURL.appendingPathComponent("fixture.jpg")
        let outputURL = rootURL.appendingPathComponent("edited.jpg")
        try writeFixtureJPEG(to: inputURL, width: 120, height: 80)

        let request = ImageRenderRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: rootURL.path,
            relativePath: "fixture.jpg",
            isRAW: false,
            recipe: EditRecipe(crop: CropRecipe(aspectRatio: 1)),
            lut: nil
        )

        let preview = try #require(ImageRenderer.preview(request, maximumPixelSize: 1_000))
        try ImageRenderer.exportJPEG(request, to: outputURL, quality: 0.9)
        let exported = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(exported, 0, nil) as? [CFString: Any]
        )

        #expect(preview.size.width == 80)
        #expect(preview.size.height == 80)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 80)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 80)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-EditRecipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixtureAsset(sourceID: UUID) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: "fixture.jpg",
            filename: "fixture.jpg",
            fileExtension: "jpg",
            fileSize: 1,
            modifiedAt: .now,
            captureDate: nil,
            width: 200,
            height: 100,
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

    private func writeFixtureJPEG(to url: URL, width: Int, height: Int) throws {
        let image = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let context = CIContext(options: [.cacheIntermediates: false])
        let cgImage = try #require(context.createCGImage(image, from: image.extent))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
