import SwiftUI

@MainActor
final class AppShellModel: ObservableObject {
    @Published var selection: SidebarDestination = .allPhotos
    @Published var isInspectorVisible = true
    @Published var isEditorPresented = false
    @Published private(set) var photoViewerItem: PhotoViewerItem? = nil
    @Published var gridDensity: GridDensity = .comfortable
    @Published private(set) var statusMessage = "准备就绪 — 原始照片始终保持不变。"
    private var photoViewerContext: [PhotoViewerItem] = []

    var isPhotoViewerPresented: Bool { photoViewerItem != nil }

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
