import AppKit
import SwiftUI

@main
struct PhotoAIMacApp: App {
    @NSApplicationDelegateAdaptor(PhotoAIAppDelegate.self) private var appDelegate
    @StateObject private var shell = AppShellModel()
    @StateObject private var catalog = CatalogStore()
    @StateObject private var thumbnails = ThumbnailStore()
    @StateObject private var photoPreviews = PhotoPreviewStore()
    @StateObject private var prewarm = DerivedImagePrewarmStore()
    @StateObject private var editorPreview = EditorPreviewStore()
    @StateObject private var luts = LUTStore()
    @StateObject private var exporter = ExportCoordinator()
    @StateObject private var batch = BatchWorkflowStore()
    @StateObject private var cleanup = CleanupWorkflowStore()
    @StateObject private var culling = CullingWorkflowStore()
    @StateObject private var photoCulling = PhotoCullingSessionStore()
    @StateObject private var ocr = OCRIndexStore()
    @StateObject private var people = PeopleStore()
    @StateObject private var applePhotos = ApplePhotosStore()
    @StateObject private var applePhotosImporter = ApplePhotosImportCoordinator()
    @StateObject private var originalPhotoExporter = OriginalPhotoExportStore()

    init() {
        if let icon = PhotoAIBrandAssets.logoImage {
            NSApplication.shared.applicationIconImage = icon
        }
        // 派生图已迁到 Application Support；Caches 下的旧布局无人引用，回收掉。
        Task.detached(priority: .background) {
            DerivedImageCache.removeLegacyCaches()
        }
    }

    var body: some Scene {
        WindowGroup("PhotoAI Mac") {
            AppShellView()
                .onAppear {
                    // Catalog 写入是异步的：退出前必须让待写入的快照落盘。
                    appDelegate.flushPendingWork = { [catalog] in
                        await catalog.flushPendingPersist()
                    }
                    // 扫描完成后自动把整卷过一遍，这样退出卷后照片依然看得见。
                    catalog.onSourceScanCompleted = { [prewarm] sourceID, requests in
                        prewarm.start(sourceID: sourceID, requests: requests)
                    }
                }
                .environmentObject(shell)
                .environmentObject(catalog)
                .environmentObject(thumbnails)
                .environmentObject(photoPreviews)
                .environmentObject(prewarm)
                .environmentObject(editorPreview)
                .environmentObject(luts)
                .environmentObject(exporter)
                .environmentObject(batch)
                .environmentObject(cleanup)
                .environmentObject(culling)
                .environmentObject(photoCulling)
                .environmentObject(ocr)
                .environmentObject(people)
                .environmentObject(applePhotos)
                .environmentObject(applePhotosImporter)
                .environmentObject(originalPhotoExporter)
        }
        .defaultSize(width: 1_360, height: 860)
        .commands {
            AppCommands(
                shell: shell,
                catalog: catalog,
                luts: luts,
                batch: batch,
                originalExporter: originalPhotoExporter,
                applePhotos: applePhotos,
                photoCulling: photoCulling
            )
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
