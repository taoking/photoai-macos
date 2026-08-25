import SwiftUI

@MainActor
final class AppShellModel: ObservableObject {
    @Published var selection: SidebarDestination = .allPhotos
    @Published var isInspectorVisible = true
    @Published var isEditorPresented = false
    @Published private(set) var photoViewerItem: PhotoViewerItem? = nil
    @Published var gridDensity: GridDensity = .comfortable
    @Published private(set) var statusMessage = "准备就绪 — 原始照片始终保持不变。"
    /// 当前处于聚焦编辑状态的文本输入框标识集合（搜索、重命名、颜色标签、备注等）。
    /// 使用集合而不是单个 Bool：焦点在两个输入框之间直接转移时，SwiftUI 不保证
    /// “旧框失焦”与“新框获焦”两个回调的先后顺序，集合能保证最终状态始终正确。
    @Published private(set) var activeTextInputs: Set<String> = []
    private var photoViewerContext: [PhotoViewerItem] = []

    var isPhotoViewerPresented: Bool { photoViewerItem != nil }

    /// 任意文本输入框当前是否处于聚焦编辑状态。
    /// 无修饰键菜单快捷键（空格、方向键、数字、P/X/U/E/F 等）在此期间会被禁用，
    /// 避免 AppKit 的菜单键等效匹配抢在文本框之前吞掉按键。
    var isTextInputActive: Bool { !activeTextInputs.isEmpty }

    /// 文本输入框标识。集中定义避免各视图散落字符串字面量。
    enum TextInputField {
        static let peopleSearch = "people.search"
        static let globalSearch = "library.search"
        static let applePhotosFilter = "applePhotos.filter"
        static let inspectorMetadata = "inspector.metadata"

        static func personName(_ personID: UUID) -> String {
            "people.name.\(personID.uuidString)"
        }
    }

    /// 由各文本框的 `@FocusState` 变化与 `onDisappear` 调用。
    /// `onDisappear` 必须同步注销：视图（人物卡片、检查器等）在聚焦状态下被销毁时
    /// 不会再收到 `false` 的焦点回调，否则状态会永久停留在“输入中”，
    /// 导致全部单键快捷键被持续禁用。
    func setTextInput(_ identifier: String, active: Bool) {
        if active {
            guard !activeTextInputs.contains(identifier) else { return }
            activeTextInputs.insert(identifier)
        } else {
            guard activeTextInputs.contains(identifier) else { return }
            activeTextInputs.remove(identifier)
        }
    }

    func select(_ destination: SidebarDestination) {
        if isEditorPresented {
            isEditorPresented = false
        }
        dismissPhotoViewer(announce: false)
        selection = destination
        statusMessage = "正在显示\(destination.title)。"
    }

    func toggleInspector() {
        isInspectorVisible.toggle()
        statusMessage = isInspectorVisible ? "已显示检查器。" : "已隐藏检查器。"
    }

    func announce(_ message: String) {
        statusMessage = message
    }

    func presentEditor() {
        dismissPhotoViewer(announce: false)
        isEditorPresented = true
        statusMessage = "编辑器使用非破坏性调整。"
    }

    func dismissEditor() {
        isEditorPresented = false
        statusMessage = "已返回图库。"
    }

    func presentPhotoViewer(item: PhotoViewerItem, in context: [PhotoViewerItem]) {
        guard context.contains(item) else { return }
        isEditorPresented = false
        photoViewerContext = context
        photoViewerItem = item
        statusMessage = "正在大图浏览；原文件不会被修改。"
    }

    func dismissPhotoViewer(announce: Bool = true) {
        guard photoViewerItem != nil else { return }
        photoViewerItem = nil
        photoViewerContext = []
        if announce { statusMessage = "已返回图库。" }
    }

    @discardableResult
    func movePhotoViewer(offset: Int) -> PhotoViewerItem? {
        guard let photoViewerItem,
              let currentIndex = photoViewerContext.firstIndex(of: photoViewerItem),
              !photoViewerContext.isEmpty else {
            return nil
        }
        let nextIndex = min(max(currentIndex + offset, 0), photoViewerContext.count - 1)
        let nextItem = photoViewerContext[nextIndex]
        self.photoViewerItem = nextItem
        statusMessage = "大图浏览 \(nextIndex + 1) / \(photoViewerContext.count)"
        return nextItem
    }

    func canMovePhotoViewer(offset: Int) -> Bool {
        guard let photoViewerItem,
              let currentIndex = photoViewerContext.firstIndex(of: photoViewerItem) else {
            return false
        }
        return photoViewerContext.indices.contains(currentIndex + offset)
    }
}

enum PhotoViewerItem: Hashable, Sendable {
    case catalog(UUID)
    case applePhotos(String)
}

enum GridDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .comfortable: "舒适"
        case .spacious: "宽松"
        }
    }

    var minimumThumbnailWidth: CGFloat {
        switch self {
        case .compact: 120
        case .comfortable: 172
        case .spacious: 260
        }
    }
}
