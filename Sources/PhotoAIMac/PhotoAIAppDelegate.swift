import AppKit

/// 退出前把尚未落盘的 Catalog 快照写完。
///
/// Catalog 的编码与写盘已经移出主线程，因此点下退出时可能还有一份待写入的快照。
/// `applicationShouldTerminate` 返回 `.terminateLater` 可以让系统等待，
/// 落盘完成后再放行——否则最后一次评分或标记会在退出瞬间丢掉。
@MainActor
final class PhotoAIAppDelegate: NSObject, NSApplicationDelegate {
    /// 由 `AppShellView` 在出现时注入。未注入时按无待办处理，直接退出。
    var flushPendingWork: (@MainActor () async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flushPendingWork else { return .terminateNow }
        Task { @MainActor in
            await flushPendingWork()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
