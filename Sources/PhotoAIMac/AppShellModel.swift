import SwiftUI

@MainActor
final class AppShellModel: ObservableObject {
    @Published var selection: SidebarDestination = .allPhotos
    @Published var isInspectorVisible = true
    @Published var isEditorPresented = false
    @Published var gridDensity: GridDensity = .comfortable
    @Published private(set) var statusMessage = "准备就绪 — 原始照片始终保持不变。"

    func select(_ destination: SidebarDestination) {
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
        isEditorPresented = true
        statusMessage = "编辑器使用非破坏性调整。"
    }

    func dismissEditor() {
        isEditorPresented = false
        statusMessage = "已返回图库。"
    }
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
