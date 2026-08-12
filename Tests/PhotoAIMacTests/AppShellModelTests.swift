import Testing
@testable import PhotoAIMac

struct AppShellModelTests {
    @Test
    @MainActor
    func changesSelectedSidebarDestination() {
        let shell = AppShellModel()

        shell.select(.raw)

        #expect(shell.selection == .raw)
        #expect(shell.statusMessage.contains("RAW"))
    }

    @Test
    @MainActor
    func togglesInspectorVisibility() {
        let shell = AppShellModel()

        shell.toggleInspector()

        #expect(shell.isInspectorVisible == false)
        #expect(shell.statusMessage == "已隐藏检查器。")
    }

    @Test
    func coversAllPlannedSidebarDestinations() {
        let titles = Set(SidebarDestination.allCases.map(\.title))

        #expect(titles.isSuperset(of: ["所有照片", "最近导入", "收藏", "RAW", "视频", "缺失文件", "文件夹", "相簿", "人物", "搜索", "清理"]))
    }
}
