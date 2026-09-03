import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoAIMac

@MainActor
struct PreviewDecodingTests {
    // MARK: - DownsampledImageDecoder

    @Test
    func embeddedPreviewIsRejectedWhenTooSmallForRequest() {
        // JPEG 只内嵌 160×120 的 EXIF 缩略图：本机实测无论请求 480 还是 2400 都只返回它。
        // 若判定为"够用"，整个图库会退化成 160×120。
        let tinyEmbedded = makeImage(width: 160, height: 120)
        #expect(!DownsampledImageDecoder.isAcceptable(tinyEmbedded, maximumPixelSize: 480))
        #expect(!DownsampledImageDecoder.isAcceptable(tinyEmbedded, maximumPixelSize: 2_400))

        // Sony ARW 内嵌约 1616 px 预览：够 2400 px 的大图预览用，
        // 接受它可以把冷文件的 36.09 秒降到 0.35 秒。
        let rawEmbedded = makeImage(width: 1_616, height: 1_080)
        #expect(DownsampledImageDecoder.isAcceptable(rawEmbedded, maximumPixelSize: 2_400))
        #expect(DownsampledImageDecoder.isAcceptable(rawEmbedded, maximumPixelSize: 480))
    }

    @Test
    func decoderReturnsRequestedResolutionWhenNoUsableEmbeddedPreviewExists() throws {
        // 没有内嵌预览的文件必须回退到全解码并给出请求尺寸，
        // 否则这次修复会把网格和 OCR 的输入画质一起拉低。
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("wide.jpg")
        try writeJPEG(width: 1_200, height: 800, to: fileURL)

        let source = try #require(CGImageSourceCreateWithURL(fileURL as CFURL, nil))
        let decoded = try #require(DownsampledImageDecoder.image(from: source, maximumPixelSize: 480))

        #expect(max(decoded.width, decoded.height) == 480)
    }

    @Test
    func decoderDoesNotUpscaleImagesSmallerThanRequest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("small.jpg")
        try writeJPEG(width: 240, height: 160, to: fileURL)

        let source = try #require(CGImageSourceCreateWithURL(fileURL as CFURL, nil))
        let decoded = try #require(DownsampledImageDecoder.image(from: source, maximumPixelSize: 2_400))

        #expect(max(decoded.width, decoded.height) == 240)
    }

    // MARK: - PhotoPreviewStore

    @Test
    func decodedPreviewIsCachedEvenWhenTheCallerWasCancelled() async throws {
        // 大图预览页每次翻页都会取消上一张的 `.task`。解码既然已经跑完，
        // 成品就必须进缓存；否则来回翻页永远收敛不到有图状态，页面一直空白。
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        let task = Task { await fixture.store.image(for: fixture.request) }
        task.cancel()
        _ = await task.value

        #expect(fixture.store.cachedImage(for: fixture.request) != nil)
    }

    @Test
    func concurrentRequestsForTheSamePhotoDecodeOnlyOnce() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        async let first = fixture.store.image(for: fixture.request)
        async let second = fixture.store.image(for: fixture.request)
        async let third = fixture.store.image(for: fixture.request)
        let results = await [first, second, third]

        #expect(results.allSatisfy { $0 != nil })
        #expect(fixture.store.decodeCount == 1)
    }

    @Test
    func cachedPreviewIsServedWithoutDecodingAgain() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        _ = await fixture.store.image(for: fixture.request)
        _ = await fixture.store.image(for: fixture.request)

        #expect(fixture.store.decodeCount == 1)
    }

    // MARK: - 磁盘缓存

    @Test
    func diskCacheUsesLossyEncodingInsteadOfUncompressedTIFF() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        _ = await fixture.store.image(for: fixture.request)
        try await waitForDiskCacheFile(in: fixture.cacheDirectory)

        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let cached = try #require(files.first)
        #expect(cached.pathExtension == "jpg")

        // 900×600 的未压缩 TIFF 约 2 MB；JPEG 必须远小于它。
        let size = try #require(try cached.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size < 400_000, "缓存文件 \(size) 字节，看起来仍是未压缩数据")
    }

    @Test
    func diskCacheEvictsLeastRecentlyUsedFilesBeyondTheBudget() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 三个 100 KB 文件，预算只放得下两个。
        let payload = Data(repeating: 0xAB, count: 100_000)
        let names = ["oldest.jpg", "middle.jpg", "newest.jpg"]
        for (index, name) in names.enumerated() {
            let url = directory.appendingPathComponent(name)
            try payload.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: Double(index) * 1_000)],
                ofItemAtPath: url.path
            )
        }
        // 旧格式残留必须无条件清掉。
        try payload.write(to: directory.appendingPathComponent("legacy.tiff"))

        PhotoPreviewCacheMaintenance.enforceBudget(directoryURL: directory, byteBudget: 250_000)

        let remaining = Set(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        )
        #expect(!remaining.contains("legacy.tiff"))
        #expect(remaining.contains("newest.jpg"))
        #expect(!remaining.contains("oldest.jpg"))
    }

    @Test
    func budgetEnforcementKeepsEverythingWhenUnderBudget() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0xAB, count: 1_000).write(to: directory.appendingPathComponent("a.jpg"))
        try Data(repeating: 0xAB, count: 1_000).write(to: directory.appendingPathComponent("b.jpg"))

        PhotoPreviewCacheMaintenance.enforceBudget(directoryURL: directory, byteBudget: 10_000)

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    // MARK: - Fixtures

    /// 磁盘写入是后台 detached 任务，测试需要等它落地。
    private func waitForDiskCacheFile(in directory: URL) async throws {
        for _ in 0..<100 {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if !files.isEmpty { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("预览磁盘缓存没有在预期时间内写出文件")
    }

    private struct StoreFixture {
        let store: PhotoPreviewStore
        let request: PhotoPreviewRequest
        let directory: URL
        let cacheDirectory: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private func makeStoreFixture() throws -> StoreFixture {
        let directory = try makeTemporaryDirectory()
        let cacheDirectory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("preview.jpg")
        try writeJPEG(width: 900, height: 600, to: fileURL)

        // bookmarkData 为空时 PhotoPreviewRenderer 会回退到 lastKnownRootPath，
        // 因此测试无需真实的安全作用域书签。
        let request = PhotoPreviewRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: directory.path,
            relativePath: "preview.jpg",
            modificationDate: Date(timeIntervalSinceReferenceDate: 1_000),
            mediaType: .image
        )
        return StoreFixture(
            store: PhotoPreviewStore(cacheDirectoryURL: cacheDirectory),
            request: request,
            directory: directory,
            cacheDirectory: cacheDirectory
        )
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func writeJPEG(width: Int, height: Int, to url: URL) throws {
        let image = makeImage(width: width, height: height)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PreviewFixtureError.destinationUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewFixtureError.writeFailed
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum PreviewFixtureError: Error {
    case destinationUnavailable
    case writeFailed
}
