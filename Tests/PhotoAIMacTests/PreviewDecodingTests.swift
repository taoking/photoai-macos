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

    // MARK: - 派生图磁盘层

    @Test
    func derivedImagesAreStoredPerSourceAndSurviveTheOriginal() async throws {
        // 离线索引的核心：卷退出后，派生图就是这些照片在本机的唯一表示。
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        _ = await fixture.store.image(for: fixture.request)

        let cached = fixture.cache.image(for: fixture.request, tier: .preview)
        #expect(cached != nil)

        // 落在该来源自己的目录下，移除来源时才能整目录清掉。
        let expected = fixture.cache.fileURL(
            sourceID: fixture.request.sourceID,
            assetID: fixture.request.assetID,
            tier: .preview
        )
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(expected.pathExtension == "jpg")
    }

    @Test
    func offlineSourcesReadFromCacheWithoutTouchingTheOriginal() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        _ = await fixture.store.image(for: fixture.request)
        // 卷退出：原文件不可读。
        try FileManager.default.removeItem(at: fixture.originalURL)

        let offlineStore = PhotoPreviewStore(cache: fixture.cache)
        let image = await offlineStore.image(for: fixture.request, allowsRendering: false)
        #expect(image != nil)
    }

    @Test
    func removingASourceDropsItsDerivedImages() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        _ = await fixture.store.image(for: fixture.request)
        #expect(fixture.cache.byteSize(for: fixture.request.sourceID) > 0)

        fixture.cache.removeAll(for: fixture.request.sourceID)
        #expect(fixture.cache.byteSize(for: fixture.request.sourceID) == 0)
        #expect(fixture.cache.image(for: fixture.request, tier: .preview) == nil)
    }

    @Test
    func staleEntriesAreIgnoredWhenTheOriginalIsNewer() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanUp() }

        _ = await fixture.store.image(for: fixture.request)
        #expect(fixture.cache.hasFreshEntry(for: fixture.request, tier: .preview))

        // 原文件在缓存写入之后又被改过：缓存必须判为过期。
        var newer = fixture.request
        newer = DerivedImageRequest(
            sourceID: fixture.request.sourceID,
            assetID: fixture.request.assetID,
            bookmarkData: fixture.request.bookmarkData,
            lastKnownRootPath: fixture.request.lastKnownRootPath,
            relativePath: fixture.request.relativePath,
            modificationDate: Date(timeIntervalSinceNow: 3_600),
            mediaType: .image
        )
        #expect(!fixture.cache.hasFreshEntry(for: newer, tier: .preview))
    }

    // MARK: - Fixtures

    private struct StoreFixture {
        let store: PhotoPreviewStore
        let cache: DerivedImageCache
        let request: DerivedImageRequest
        let directory: URL
        let cacheDirectory: URL
        let originalURL: URL

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

        // bookmarkData 为空时渲染器会回退到 lastKnownRootPath，
        // 因此测试无需真实的安全作用域书签。
        let request = DerivedImageRequest(
            sourceID: UUID(),
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: directory.path,
            relativePath: "preview.jpg",
            modificationDate: Date(timeIntervalSinceReferenceDate: 1_000),
            mediaType: .image
        )
        let cache = DerivedImageCache(rootURL: cacheDirectory)
        return StoreFixture(
            store: PhotoPreviewStore(cache: cache),
            cache: cache,
            request: request,
            directory: directory,
            cacheDirectory: cacheDirectory,
            originalURL: fileURL
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

@MainActor
struct ThumbnailDiskCacheTests {
    /// 缩略图此前只有内存缓存，进程一退，全部作废：重启后每张都要重新解码，
    /// 在 MTP 这类慢速卷上是 0.75 秒/张。磁盘缓存必须跨实例存活。
    @Test
    func thumbnailsSurviveANewStoreInstance() async throws {
        let directory = try makeDirectory("Source")
        let cacheDirectory = try makeDirectory("Cache")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        let fileURL = directory.appendingPathComponent("photo.jpg")
        try writeJPEG(width: 800, height: 600, to: fileURL)
        let request = DerivedImageRequest(
            sourceID: UUID(),
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: directory.path,
            relativePath: "photo.jpg",
            modificationDate: Date(timeIntervalSinceReferenceDate: 42),
            mediaType: .image
        )

        let cache = DerivedImageCache(rootURL: cacheDirectory)
        let first = ThumbnailStore(cache: cache)
        _ = await loadThumbnail(from: first, request: request)

        // 原文件消失后，新实例仍必须拿得到缩略图——只能来自磁盘缓存。
        // 这正是"扫描完退出卷、照片依然看得见"所依赖的路径。
        try FileManager.default.removeItem(at: fileURL)
        let second = ThumbnailStore(cache: cache)
        let restored = await loadThumbnail(from: second, request: request, allowsRendering: false)

        #expect(restored != nil)
    }

    @Test
    func aMissingDiskEntryStillRendersFromTheOriginal() async throws {
        let directory = try makeDirectory("Source")
        let cacheDirectory = try makeDirectory("Cache")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        try writeJPEG(width: 400, height: 300, to: directory.appendingPathComponent("photo.jpg"))

        let store = ThumbnailStore(cache: DerivedImageCache(rootURL: cacheDirectory))
        let image = await loadThumbnail(
            from: store,
            request: DerivedImageRequest(
                sourceID: UUID(),
                assetID: UUID(),
                bookmarkData: Data(),
                lastKnownRootPath: directory.path,
                relativePath: "photo.jpg",
                modificationDate: nil,
                mediaType: .image
            )
        )
        #expect(image != nil)
    }

    private func loadThumbnail(
        from store: ThumbnailStore,
        request: DerivedImageRequest,
        allowsRendering: Bool = true
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var resumed = false
            _ = store.load(request, allowsRendering: allowsRendering) { image in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }


    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Thumb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJPEG(width: Int, height: Int, to url: URL) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
    }
}
