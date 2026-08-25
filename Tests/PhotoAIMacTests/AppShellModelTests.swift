import Foundation
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
    @MainActor
    func editingRoundTripPreservesTheCurrentLibraryDestination() {
        let shell = AppShellModel()
        shell.select(.allPhotos)

        shell.presentEditor()
        #expect(shell.isEditorPresented)
        #expect(shell.selection == .allPhotos)

        shell.dismissEditor()
        #expect(!shell.isEditorPresented)
        #expect(shell.selection == .allPhotos)
    }

    @Test
    @MainActor
    func selectingDestinationExitsTheEditor() {
        let shell = AppShellModel()
        shell.presentEditor()

        shell.select(.allPhotos)

        #expect(!shell.isEditorPresented)
        #expect(shell.selection == .allPhotos)
    }

    @Test
    @MainActor
    func photoViewerPreservesContextAndNavigatesWithoutEditing() {
        let shell = AppShellModel()
        let ids = [UUID(), UUID(), UUID()]
        let items = ids.map { PhotoViewerItem.catalog($0) }

        shell.presentPhotoViewer(item: items[1], in: items)
        #expect(shell.isPhotoViewerPresented)
        #expect(!shell.isEditorPresented)
        #expect(shell.movePhotoViewer(offset: 1) == items[2])
        #expect(!shell.canMovePhotoViewer(offset: 1))

        shell.dismissPhotoViewer()
        #expect(!shell.isPhotoViewerPresented)
        #expect(shell.selection == .allPhotos)
    }

    @Test
    @MainActor
    func selectingDestinationExitsPhotoViewer() {
        let shell = AppShellModel()
        let item = PhotoViewerItem.catalog(UUID())
        shell.presentPhotoViewer(item: item, in: [item])

        shell.select(.favorites)

        #expect(!shell.isPhotoViewerPresented)
        #expect(shell.selection == .favorites)
    }

    @Test
    @MainActor
    func tracksTextInputFocusSoSingleKeyShortcutsStayDisabledWhileTyping() {
        let shell = AppShellModel()
        #expect(!shell.isTextInputActive)

        shell.setTextInput(AppShellModel.TextInputField.globalSearch, active: true)
        #expect(shell.isTextInputActive)

        shell.setTextInput(AppShellModel.TextInputField.globalSearch, active: false)
        #expect(!shell.isTextInputActive)
    }

    @Test
    @MainActor
    func keepsTextInputActiveWhenFocusMovesBetweenFieldsInEitherCallbackOrder() {
        let shell = AppShellModel()
        let personA = AppShellModel.TextInputField.personName(UUID())
        let personB = AppShellModel.TextInputField.personName(UUID())

        // 先“新框获焦”后“旧框失焦”：不能因为旧框的注销而误判为未在输入。
        shell.setTextInput(personA, active: true)
        shell.setTextInput(personB, active: true)
        shell.setTextInput(personA, active: false)
        #expect(shell.isTextInputActive)

        shell.setTextInput(personB, active: false)
        #expect(!shell.isTextInputActive)
    }

    @Test
    @MainActor
    func releasesTextInputStateWhenAFocusedFieldDisappears() {
        let shell = AppShellModel()
        shell.setTextInput(AppShellModel.TextInputField.inspectorMetadata, active: true)

        // 检查器在聚焦状态下被隐藏时只会收到 onDisappear，没有第二次焦点回调。
        shell.setTextInput(AppShellModel.TextInputField.inspectorMetadata, active: false)

        #expect(!shell.isTextInputActive)
        #expect(shell.activeTextInputs.isEmpty)
    }

    @Test
    func coversAllPlannedSidebarDestinations() {
        let titles = Set(SidebarDestination.allCases.map(\.title))

        #expect(titles.isSuperset(of: ["所有照片", "最近导入", "收藏", "RAW", "视频", "缺失文件", "文件夹", "相簿", "人物", "搜索", "清理"]))
    }
}
