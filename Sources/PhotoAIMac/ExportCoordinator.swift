@preconcurrency import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ExportCoordinator: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var statusMessage: String?

    private let exportQueue = DispatchQueue(label: "com.taoking.PhotoAIMac.export", qos: .userInitiated)

    func chooseAndExport(_ request: ImageRenderRequest, suggestedFilename: String) {
        guard !isExporting else { return }

        let panel = NSSavePanel()
        panel.title = "导出 JPEG"
        panel.message = "导出会创建新文件，原始照片始终保持不变。"
        panel.prompt = "导出"
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        export(request, to: outputURL)
    }

    func export(_ request: ImageRenderRequest, to outputURL: URL) {
        guard !isExporting else { return }
        isExporting = true
        statusMessage = "正在导出 JPEG…"

        exportQueue.async { [weak self] in
            let result = Result {
                try ImageRenderer.exportJPEG(request, to: outputURL, quality: 0.92)
                return outputURL
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success:
                    self.statusMessage = "已导出 JPEG。"
                case let .failure(error):
                    self.statusMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
