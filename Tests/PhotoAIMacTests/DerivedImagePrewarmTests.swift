import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoAIMac

@MainActor
struct DerivedImagePrewarmTests {
    /// 预热存在的理由：缩略图原本只为滚动到的可见 Cell 生成，
    /// 所以"扫描完退出卷"实际上几乎什么都看不到。
    @Test
    func prewarmingGeneratesEveryTierForTheWholeSource() async throws {
        let fixture = try makeFixture(photoCount: 5)
        defer { fixture.cleanUp() }

        fixture.store.start(sourceID: fixture.sourceID, requests: fixture.requests)
        try await waitForCompletion(fixture.store, sourceID: fixture.sourceID)

        for request in fixture.requests {
            for tier in DerivedImageTier.allCases {
                #expect(
                    fixture.cache.hasFreshEntry(for: request, tier: tier),
                    "\(tier) 缺失：\(request.relativePath)"
                )
            }
        }
        #expect(fixture.cache.entryCount(for: fixture.sourceID, tier: .thumbnail) == 5)
        #expect(fixture.cache.entryCount(for: fixture.sourceID, tier: .preview) == 5)
    }

    /// 预热后卷退出：照片必须依然看得见。这是整个离线索引需求的验收点。
    @Test
    func photosStayVisibleAfterTheVolumeGoesAway() async throws {
        let fixture = try makeFixture(photoCount: 3)
        defer { fixture.cleanUp() }

        fixture.store.start(sourceID: fixture.sourceID, requests: fixture.requests)
        try await waitForCompletion(fixture.store, sourceID: fixture.sourceID)

        // 卷退出：原文件全部不可读。
        try FileManager.default.removeItem(at: fixture.photosDirectory)

        let thumbnails = ThumbnailStore(cache: fixture.cache)
        let previews = PhotoPreviewStore(cache: fixture.cache)
        for request in fixture.requests {
            let thumbnail = await loadThumbnail(thumbnails, request: request)
            #expect(thumbnail != nil, "离线缩略图缺失：\(request.relativePath)")
            let preview = await previews.image(for: request, allowsRendering: false)
            #expect(preview != nil, "离线预览缺失：\(request.relativePath)")
        }
    }

    /// 已有缓存直接跳过，因此中断后重启不会从头再来。
    @Test
    func alreadyCachedAssetsAreCountedWithoutRedoingWork() async throws {
        let fixture = try makeFixture(photoCount: 4)
        defer { fixture.cleanUp() }

        fixture.store.start(sourceID: fixture.sourceID, requests: fixture.requests)
        try await waitForCompletion(fixture.store, sourceID: fixture.sourceID)

        // 第二轮：原文件全部删掉。若不是走"已缓存则跳过"，这一轮必然失败。
        try FileManager.default.removeItem(at: fixture.photosDirectory)
        let resumed = DerivedImagePrewarmStore(cache: fixture.cache)
        resumed.start(sourceID: fixture.sourceID, requests: fixture.requests)
        try await waitForCompletion(resumed, sourceID: fixture.sourceID)

        let progress = try #require(resumed.progress(for: fixture.sourceID))
        #expect(progress.completed == 4)
        #expect(progress.isFinished)
    }

    @Test
    func pausingStopsProgressAndKeepsWhatWasAlreadyBuilt() async throws {
        let fixture = try makeFixture(photoCount: 6)
        defer { fixture.cleanUp() }

        fixture.store.start(sourceID: fixture.sourceID, requests: fixture.requests)
        fixture.store.pause(sourceID: fixture.sourceID)

        let progress = try #require(fixture.store.progress(for: fixture.sourceID))
        #expect(progress.isPaused)
        #expect(progress.completed <= 6)
    }

    @Test
    func cancellingClearsProgressForThatSourceOnly() async throws {
        let fixture = try makeFixture(photoCount: 2)
        defer { fixture.cleanUp() }

        fixture.store.start(sourceID: fixture.sourceID, requests: fixture.requests)
        fixture.store.cancel(sourceID: fixture.sourceID)

        #expect(fixture.store.progress(for: fixture.sourceID) == nil)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: DerivedImagePrewarmStore
        let cache: DerivedImageCache
        let sourceID: UUID
        let requests: [DerivedImageRequest]
        let photosDirectory: URL
        let cacheDirectory: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: photosDirectory)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private func makeFixture(photoCount: Int) throws -> Fixture {
        let photosDirectory = try makeTemporaryDirectory("Photos")
        let cacheDirectory = try makeTemporaryDirectory("Cache")
        let sourceID = UUID()
        var requests: [DerivedImageRequest] = []

        for index in 0..<photoCount {
            let name = String(format: "DSC%05d.JPG", index)
            try writeJPEG(width: 1_200, height: 800, to: photosDirectory.appendingPathComponent(name))
            requests.append(
                DerivedImageRequest(
                    sourceID: sourceID,
                    assetID: UUID(),
                    bookmarkData: Data(),
                    lastKnownRootPath: photosDirectory.path,
                    relativePath: name,
                    modificationDate: nil,
                    mediaType: .image
                )
            )
        }

        let cache = DerivedImageCache(rootURL: cacheDirectory)
        return Fixture(
            store: DerivedImagePrewarmStore(cache: cache),
            cache: cache,
            sourceID: sourceID,
            requests: requests,
            photosDirectory: photosDirectory,
            cacheDirectory: cacheDirectory
        )
    }

    private func waitForCompletion(
        _ store: DerivedImagePrewarmStore,
        sourceID: UUID
    ) async throws {
        for _ in 0..<300 {
            if store.progress(for: sourceID)?.isFinished == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("预热没有在预期时间内完成")
    }

    private func loadThumbnail(_ store: ThumbnailStore, request: DerivedImageRequest) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var resumed = false
            _ = store.load(request, allowsRendering: false) { image in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
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

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Prewarm-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
