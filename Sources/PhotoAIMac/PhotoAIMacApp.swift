import AppKit
import SwiftUI

@main
struct PhotoAIMacApp: App {
    @StateObject private var shell = AppShellModel()
    @StateObject private var catalog = CatalogStore()
    @StateObject private var thumbnails = ThumbnailStore()
    @StateObject private var editorPreview = EditorPreviewStore()
    @StateObject private var luts = LUTStore()
    @StateObject private var exporter = ExportCoordinator()
    @StateObject private var batch = BatchWorkflowStore()
    @StateObject private var cleanup = CleanupWorkflowStore()
    @StateObject private var culling = CullingWorkflowStore()
    @StateObject private var ocr = OCRIndexStore()
    @StateObject private var people = PeopleStore()
    @StateObject private var applePhotos = ApplePhotosStore()
    @StateObject private var applePhotosImporter = ApplePhotosImportCoordinator()

    init() {
        if let icon = PhotoAIBrandAssets.logoImage {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup("PhotoAI Mac") {
            AppShellView()
                .environmentObject(shell)
                .environmentObject(catalog)
                .environmentObject(thumbnails)
                .environmentObject(editorPreview)
                .environmentObject(luts)
                .environmentObject(exporter)
                .environmentObject(batch)
                .environmentObject(cleanup)
                .environmentObject(culling)
                .environmentObject(ocr)
                .environmentObject(people)
                .environmentObject(applePhotos)
                .environmentObject(applePhotosImporter)
        }
        .defaultSize(width: 1_360, height: 860)
        .commands {
            AppCommands(shell: shell, catalog: catalog, luts: luts, batch: batch)
        }

        Settings {
            SettingsView()
                .environmentObject(shell)
                .environmentObject(catalog)
                .environmentObject(thumbnails)
                .environmentObject(luts)
                .environmentObject(batch)
        }
    }
}
