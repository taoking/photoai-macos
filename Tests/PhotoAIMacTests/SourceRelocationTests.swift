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
