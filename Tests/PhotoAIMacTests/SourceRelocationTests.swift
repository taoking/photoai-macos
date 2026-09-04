import AppKit
import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct SourceRelocationTests {
    @Test
    func relocatingAMissingSourceKeepsAssetIdentityAndLocalState() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let originalRoot = container.appendingPathComponent("原始位置", isDirectory: true)
        let nested = originalRoot.appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: nested.appendingPathComponent("photo.jpg"))
        let catalogURL = container.appendingPathComponent("catalog.json")

        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(originalRoot)
        let sourceID = try #require(store.sources.first?.id)
        let originalAsset = try #require(store.assets.first)
        store.setRating(5, for: [originalAsset.id])
        store.setFlag(.pick, for: [originalAsset.id])

        // 素材整盘搬走：书签与最后已知路径都失效。
        try FileManager.default.removeItem(at: originalRoot)
        await store.rescan(sourceID)
        #expect(store.sources.first?.status == .missing)

        // 用户在新位置重新找到同一批文件。
        let newRoot = container.appendingPathComponent("新位置", isDirectory: true)
        let newNested = newRoot.appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: newNested, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: newNested.appendingPathComponent("photo.jpg"))

        await store.relocate(sourceID, to: newRoot)

        let source = try #require(store.sources.first)
        #expect(source.id == sourceID)
        #expect(source.status == .ready)
        #expect(source.lastKnownPath == newRoot.standardizedFileURL.path)

        // 重新定位保留 sourceID 与 relativePath，因此资产 ID 稳定，
        // 评分、标记这些只存在于 Catalog 的本地状态都不会丢。
        let relocated = try #require(store.assets.first)
        #expect(relocated.id == originalAsset.id)
        #expect(relocated.relativePath == "2026/photo.jpg")
        #expect(relocated.rating == 5)
        #expect(relocated.flag == .pick)
    }

    @Test
    func relocatingToAFolderAlreadyIndexedIsRejected() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let first = container.appendingPathComponent("first", isDirectory: true)
        let second = container.appendingPathComponent("second", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF]).write(to: directory.appendingPathComponent("photo.jpg"))
        }

        let store = CatalogStore(storageURL: container.appendingPathComponent("catalog.json"))
        await store.addFolder(first)
        await store.addFolder(second)
        #expect(store.sources.count == 2)

        let firstID = try #require(store.sources.first(where: { $0.lastKnownPath == first.standardizedFileURL.path })?.id)
        await store.relocate(firstID, to: second)

        // 两个来源指向同一个文件夹会让同一批文件被索引两次。
        #expect(store.lastErrorMessage != nil)
        #expect(store.sources.first(where: { $0.id == firstID })?.lastKnownPath == first.standardizedFileURL.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Relocate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
struct AppTerminationTests {
    @Test
    func terminationWaitsForPendingCatalogWrites() async throws {
        let delegate = PhotoAIAppDelegate()
        let recorder = FlushRecorder()
        delegate.flushPendingWork = { await recorder.markFlushed() }

        // 注入了待办工作时必须请求延后退出，而不是让系统立刻终止进程。
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)

        for _ in 0..<100 where await !recorder.didFlush {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await recorder.didFlush)
    }

    @Test
    func terminationIsImmediateWhenNothingIsPending() {
        let delegate = PhotoAIAppDelegate()
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }
}

private actor FlushRecorder {
    private(set) var didFlush = false
    func markFlushed() { didFlush = true }
}

@MainActor
struct UnreachableSourceReportingTests {
    /// 图库按文件名全局排序，失效来源的资产会成片聚在一起。本机真实数据里
    /// 排序后前 1,699 项全部来自三个已失效的文件夹，第一张可读照片在第 1,700 位，
    /// 于是整个首屏都是无法解释的破图标。界面必须能把这种情况认出来。
    @Test
    func assetsFromMissingSourcesAreReportedAsUnreachable() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let goneRoot = container.appendingPathComponent("已失效", isDirectory: true)
        let liveRoot = container.appendingPathComponent("仍可用", isDirectory: true)
        for directory in [goneRoot, liveRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF]).write(to: directory.appendingPathComponent("photo.jpg"))
        }

        let store = CatalogStore(storageURL: container.appendingPathComponent("catalog.json"))
        await store.addFolder(goneRoot)
        await store.addFolder(liveRoot)
        let goneID = try #require(store.sources.first(where: { $0.lastKnownPath == goneRoot.standardizedFileURL.path })?.id)

        try FileManager.default.removeItem(at: goneRoot)
        await store.rescan(goneID)

        #expect(store.unreachableSources.map(\.id) == [goneID])

        // 失效来源的资产仍留在图库里，但必须被标记为不可读。
        let stranded = try #require(store.assets.first(where: { $0.sourceID == goneID }))
        let live = try #require(store.assets.first(where: { $0.sourceID != goneID }))
        #expect(store.isSourceReachable(for: stranded) == false)
        #expect(store.isSourceReachable(for: live))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Unreachable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
struct SourceRemovalTests {
    @Test
    func removingASourceDropsOnlyItsRecordsAndNeverTouchesFiles() async throws {
        let container = try makeRemovalDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let doomed = container.appendingPathComponent("待移除", isDirectory: true)
        let kept = container.appendingPathComponent("保留", isDirectory: true)
        for directory in [doomed, kept] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF]).write(to: directory.appendingPathComponent("photo.jpg"))
        }

        let catalogURL = container.appendingPathComponent("catalog.json")
        let store = CatalogStore(storageURL: catalogURL)
        await store.addFolder(doomed)
        await store.addFolder(kept)
        let doomedID = try #require(store.sources.first(where: { $0.lastKnownPath == doomed.standardizedFileURL.path })?.id)
        let doomedAssetID = try #require(store.assets.first(where: { $0.sourceID == doomedID })?.id)
        store.selectSingle(assetID: doomedAssetID)

        store.removeSource(doomedID)
        await store.flushPendingPersist()

        #expect(store.sources.count == 1)
        #expect(store.assets.allSatisfy { $0.sourceID != doomedID })
        #expect(store.assets.count == 1)
        // 悬空的选中项必须一并清掉，否则工具栏会对一个已不存在的资产启用操作。
        #expect(store.selectedAssetIDs.isEmpty)
        // 只动索引：原始文件必须原封不动。
        #expect(FileManager.default.fileExists(atPath: doomed.appendingPathComponent("photo.jpg").path))

        let restored = CatalogStore(storageURL: catalogURL)
        #expect(restored.sources.count == 1)
        #expect(restored.assets.count == 1)
    }

    private func makeRemovalDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
struct ThumbnailVolumePolicyTests {
    /// 缩略图并发在不同卷上收益符号相反：MTP/macFUSE 卷实测串行 18.0s、
    /// 6 路并发 22.4s，本地卷则相反。因此必须按卷分流。
    @Test
    func localVolumesAreTreatedAsParallelCapable() {
        let store = ThumbnailStore()
        #expect(store.isLocalVolume(rootPath: FileManager.default.temporaryDirectory.path))
    }

    @Test
    func unknownPathsFallBackToTheParallelPath() {
        // 读不到卷信息时不该让整个来源退化成串行。
        let store = ThumbnailStore()
        #expect(store.isLocalVolume(rootPath: "/该路径不存在/\(UUID().uuidString)"))
    }
}
