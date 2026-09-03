@preconcurrency import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageRenderRequest: Sendable, Hashable {
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
    let isRAW: Bool
    let recipe: EditRecipe
    let lut: LUTRenderRecipe?
}

enum ImageProcessingPipeline {
    static func apply(_ inputImage: CIImage, recipe: EditRecipe, lut: LUTRenderRecipe? = nil) -> CIImage {
        var image = inputImage

        if recipe.exposure != 0,
           let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(recipe.exposure, forKey: kCIInputEVKey)
            image = filter.outputImage ?? image
        }

        if recipe.contrast != 0 || recipe.saturation != 0 {
            let filter = CIFilter(name: "CIColorControls")
            filter?.setValue(image, forKey: kCIInputImageKey)
            filter?.setValue(recipe.contrast + 1, forKey: kCIInputContrastKey)
            filter?.setValue(recipe.saturation + 1, forKey: kCIInputSaturationKey)
            image = filter?.outputImage ?? image
        }

        if recipe.highlights != 0 || recipe.shadows != 0,
           let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(recipe.highlights, forKey: "inputHighlightAmount")
            filter.setValue(recipe.shadows, forKey: "inputShadowAmount")
            image = filter.outputImage ?? image
        }

        if recipe.temperature != 0 || recipe.tint != 0,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 6_500, y: 0), forKey: "inputNeutral")
            filter.setValue(
                CIVector(x: 6_500 + recipe.temperature * 20, y: recipe.tint * 2),
                forKey: "inputTargetNeutral"
            )
            image = filter.outputImage ?? image
        }

        if let lut, lut.intensity > 0 {
            image = apply(lut: lut, to: image)
        }

        if let ratio = recipe.crop?.aspectRatio, ratio > 0 {
            let extent = image.extent
            let currentRatio = extent.width / extent.height
            let cropRect: CGRect
            if currentRatio > ratio {
                let width = extent.height * ratio
                cropRect = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
            } else {
                let height = extent.width / ratio
                cropRect = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
            }
            image = image.cropped(to: cropRect.integral)
        }

        if recipe.rotation != 0 {
            let radians = recipe.rotation * .pi / 180
            let extent = image.extent
            let centeredTransform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .rotated(by: radians)
                .translatedBy(x: extent.midX, y: extent.midY)
            image = image.transformed(by: centeredTransform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }

        return image
    }

    private static func apply(lut: LUTRenderRecipe, to inputImage: CIImage) -> CIImage {
        let normalizedImage = normalize(inputImage, domainMinimum: lut.cube.domainMinimum, domainMaximum: lut.cube.domainMaximum)
        guard let cube = CIFilter(name: "CIColorCube") else { return inputImage }
        cube.setValue(normalizedImage, forKey: kCIInputImageKey)
        cube.setValue(lut.cube.dimension, forKey: "inputCubeDimension")
        cube.setValue(lut.cube.cubeData, forKey: "inputCubeData")
        guard let lutImage = cube.outputImage else { return inputImage }
        guard lut.intensity < 1,
              let mixer = CIFilter(name: "CIDissolveTransition") else {
            return lutImage
        }

        mixer.setValue(inputImage, forKey: kCIInputImageKey)
        mixer.setValue(lutImage, forKey: "inputTargetImage")
        mixer.setValue(lut.intensity, forKey: "inputTime")
        return mixer.outputImage ?? lutImage
    }

    private static func normalize(
        _ image: CIImage,
        domainMinimum: LUTDomain,
        domainMaximum: LUTDomain
    ) -> CIImage {
        guard domainMinimum != .zero || domainMaximum != .one,
              let filter = CIFilter(name: "CIColorMatrix") else {
            return image
        }

        func scale(_ minimum: Float, _ maximum: Float) -> CGFloat { CGFloat(1 / (maximum - minimum)) }
        func bias(_ minimum: Float, _ maximum: Float) -> CGFloat { CGFloat(-minimum / (maximum - minimum)) }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: scale(domainMinimum.red, domainMaximum.red), y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: scale(domainMinimum.green, domainMaximum.green), z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: scale(domainMinimum.blue, domainMaximum.blue), w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(
            CIVector(
                x: bias(domainMinimum.red, domainMaximum.red),
                y: bias(domainMinimum.green, domainMaximum.green),
                z: bias(domainMinimum.blue, domainMaximum.blue),
                w: 0
            ),
            forKey: "inputBiasVector"
        )
        return filter.outputImage ?? image
    }
}

@MainActor
final class EditorPreviewStore: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isRendering = false

    private let renderingQueue = DispatchQueue(label: "com.taoking.PhotoAIMac.editor-preview", qos: .userInitiated)
    private var renderToken = UUID()

    func render(_ request: ImageRenderRequest) {
        let token = UUID()
        renderToken = token
        isRendering = true

        renderingQueue.async { [weak self] in
            let image = ImageRenderer.preview(request)

            DispatchQueue.main.async {
                guard let self, self.renderToken == token else { return }
                self.image = image
                self.isRendering = false
            }
        }
    }
}

enum ImageRenderer {
    static func preview(_ request: ImageRenderRequest, maximumPixelSize: Int = 1_600) -> NSImage? {
        try? withImageURL(for: request) { url in
            let input = try previewImage(for: request, at: url, maximumPixelSize: maximumPixelSize)
            let output = ImageProcessingPipeline.apply(input, recipe: request.recipe, lut: request.lut)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let renderedImage = context.createCGImage(output, from: output.extent.integral) else {
                throw ImageRenderError.renderFailed
            }
            return NSImage(cgImage: renderedImage, size: NSSize(width: renderedImage.width, height: renderedImage.height))
        }
    }

    static func exportJPEG(_ request: ImageRenderRequest, to outputURL: URL, quality: Double) throws {
        var didFinalize = false
        let outputExistedBeforeExport = FileManager.default.fileExists(atPath: outputURL.path)
        defer {
            if !didFinalize, !outputExistedBeforeExport {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        try withImageURL(for: request) { url in
            let input = try fullResolutionImage(for: request, at: url)
            let output = ImageProcessingPipeline.apply(input, recipe: request.recipe, lut: request.lut)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let renderedImage = context.createCGImage(output, from: output.extent.integral),
                  let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ImageRenderError.renderFailed
            }

            CGImageDestinationAddImage(destination, renderedImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ImageRenderError.exportFailed
            }
            didFinalize = true
        }
    }

    private static func previewImage(
        for request: ImageRenderRequest,
        at url: URL,
        maximumPixelSize: Int
    ) throws -> CIImage {
        if request.isRAW {
            guard let rawFilter = CIRAWFilter(imageURL: url) else {
                throw ImageRenderError.unreadableSource
            }
            let longestSide = max(rawFilter.nativeSize.width, rawFilter.nativeSize.height)
            rawFilter.scaleFactor = Float(min(1, Double(maximumPixelSize) / max(longestSide, 1)))
            rawFilter.isDraftModeEnabled = rawFilter.scaleFactor < 1
            guard let image = rawFilter.outputImage else {
                throw ImageRenderError.renderFailed
            }
            return image
        }

        return try withImageSource(at: url) { source in
            guard let previewImage = DownsampledImageDecoder.image(
                from: source,
                maximumPixelSize: maximumPixelSize
            ) else {
                throw ImageRenderError.unreadableSource
            }
            return CIImage(cgImage: previewImage)
        }
    }

    private static func fullResolutionImage(for request: ImageRenderRequest, at url: URL) throws -> CIImage {
        if request.isRAW {
            guard let rawFilter = CIRAWFilter(imageURL: url) else {
                throw ImageRenderError.unreadableSource
            }
            rawFilter.scaleFactor = 1
            rawFilter.isDraftModeEnabled = false
            guard let image = rawFilter.outputImage else {
                throw ImageRenderError.renderFailed
            }
            return image
        }

        return try withImageSource(at: url) { source in
            guard let originalImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ImageRenderError.unreadableSource
            }
            return CIImage(cgImage: originalImage)
        }
    }

    private static func withImageURL<Result>(
        for request: ImageRenderRequest,
        _ operation: (URL) throws -> Result
    ) throws -> Result {
        var isStale = false
        let bookmarkedRoot: URL?
        if request.bookmarkData.isEmpty {
            bookmarkedRoot = nil
        } else {
            bookmarkedRoot = try? URL(
                resolvingBookmarkData: request.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
        let rootURL = bookmarkedRoot ?? URL(fileURLWithPath: request.lastKnownRootPath)
        let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileURL = rootURL.appendingPathComponent(request.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImageRenderError.unreadableSource
        }
        return try operation(fileURL)
    }

    private static func withImageSource<Result>(at url: URL, _ operation: (CGImageSource) throws -> Result) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageRenderError.unreadableSource
        }
        return try operation(source)
    }
}

enum ImageRenderError: LocalizedError {
    case unreadableSource
    case renderFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "无法读取原始图片。"
        case .renderFailed: "无法渲染编辑结果。"
        case .exportFailed: "无法写入导出文件。"
        }
    }
}
