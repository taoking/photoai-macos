import AppKit
import Foundation

struct OriginalPhotoExportRequest: Sendable, Hashable {
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
    let filename: String
}

struct OriginalPhotoExportFailure: Identifiable, Hashable, Sendable {
    let id: UUID
    let assetID: UUID
    let filename: String
    let message: String
}

enum OriginalPhotoExportState: Equatable, Sendable {
    case idle
    case running
    case cancelling
    case completed
    case cancelled

    var title: String {
        switch self {
        case .idle: ""
        case .running: "正在复制原始照片"
        case .cancelling: "正在取消导出"
        case .completed: "原始照片导出完成"
        case .cancelled: "原始照片导出已取消"
        }
    }

    var isActive: Bool { self == .running || self == .cancelling }
}

struct OriginalPhotoExportPlan: Hashable, Sendable {
    let request: OriginalPhotoExportRequest
    let destinationURL: URL
}

enum OriginalPhotoExportPlanner {
    static func plans(
        requests: [OriginalPhotoExportRequest],
        destinationURL: URL,
        existingFilenames: [String]
    ) -> [OriginalPhotoExportPlan] {
        var occupiedNames = Set(existingFilenames.map(normalizedFilename))
        return requests.map { request in
            let filename = conflictSafeFilename(
                preferredFilename: request.filename,
                occupiedFilenames: &occupiedNames
            )
            return OriginalPhotoExportPlan(
                request: request,
                destinationURL: destinationURL.appendingPathComponent(filename, isDirectory: false)
            )
        }
    }

    static func conflictSafeFilename(
        preferredFilename: String,
        occupiedFilenames: inout Set<String>
    ) -> String {
        let pathExtension = (preferredFilename as NSString).pathExtension
        let baseName = (preferredFilename as NSString).deletingPathExtension
        var candidate = preferredFilename
        var suffix = 2
        while occupiedFilenames.contains(normalizedFilename(candidate)) {
            candidate = pathExtension.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(pathExtension)"
            suffix += 1
        }
        occupiedFilenames.insert(normalizedFilename(candidate))
        return candidate
    }

    private static func normalizedFilename(_ filename: String) -> String {
        filename.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// 复制 Catalog 已索引的原始文件，不重新渲染、不改扩展名、不覆盖目标文件。
/// 文件 I/O 全部运行在后台任务，进度更新才回到 MainActor。
@MainActor
final class OriginalPhotoExportStore: ObservableObject {
    @Published private(set) var state: OriginalPhotoExportState = .idle
    @Published private(set) var totalCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var succeededCount = 0
    @Published private(set) var currentFilename: String?
    @Published private(set) var failures: [OriginalPhotoExportFailure] = []
    @Published private(set) var destinationURL: URL?

    private var exportTask: Task<Void, Never>?

    deinit {
        exportTask?.cancel()
    }

    var progressDescription: String? {
        guard totalCount > 0 else { return nil }
        var components = ["\(state.title) \(completedCount) / \(totalCount)"]
        if let currentFilename, state.isActive { components.append(currentFilename) }
        if !failures.isEmpty { components.append("失败 \(failures.count)") }
        return components.joined(separator: " · ")
    }

    func chooseDestinationAndStart(assets: [PhotoAsset], catalog: CatalogStore) {
        guard !assets.isEmpty, !state.isActive else { return }
        let panel = NSOpenPanel()
        panel.title = "导出原始照片"
        panel.message = "选择目标文件夹。PhotoAI Mac 会复制原文件并保留扩展名，不会覆盖已有文件。"
        panel.prompt = "导出到此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        let requests = assets.compactMap(catalog.originalExportRequest)
        start(requests: requests, destinationURL: destinationURL)
    }

    func startForTesting(requests: [OriginalPhotoExportRequest], destinationURL: URL) {
        start(requests: requests, destinationURL: destinationURL)
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelling
        exportTask?.cancel()
    }

    private func start(requests: [OriginalPhotoExportRequest], destinationURL: URL) {
        guard !requests.isEmpty, !state.isActive else { return }
        let existingNames = (try? FileManager.default.contentsOfDirectory(atPath: destinationURL.path)) ?? []
        let plans = OriginalPhotoExportPlanner.plans(
            requests: requests,
            destinationURL: destinationURL,
            existingFilenames: existingNames
        )

        self.destinationURL = destinationURL
        state = .running
        totalCount = plans.count
        completedCount = 0
        succeededCount = 0
        currentFilename = nil
        failures = []

        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            var completedCount = 0
            var succeededCount = 0
            var failures: [OriginalPhotoExportFailure] = []

            for plan in plans {
                await Task.yield()
                guard !Task.isCancelled else {
                    await self?.finish(
                        cancelled: true,
                        completedCount: completedCount,
                        succeededCount: succeededCount,
                        failures: failures
                    )
                    return
                }

                await self?.recordCurrentFilename(plan.destinationURL.lastPathComponent)
                do {
                    try Self.copy(plan)
                    succeededCount += 1
                } catch {
                    failures.append(
                        OriginalPhotoExportFailure(
                            id: UUID(),
                            assetID: plan.request.assetID,
                            filename: plan.request.filename,
                            message: error.localizedDescription
                        )
                    )
                }
                completedCount += 1
                await self?.recordProgress(
                    completedCount: completedCount,
                    succeededCount: succeededCount,
                    failures: failures
                )
            }

            await self?.finish(
                cancelled: false,
                completedCount: completedCount,
                succeededCount: succeededCount,
                failures: failures
            )
        }
    }

    nonisolated private static func copy(_ plan: OriginalPhotoExportPlan) throws {
        let request = plan.request
        var isStale = false
        let rootURL = (try? URL(
            resolvingBookmarkData: request.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? URL(fileURLWithPath: request.lastKnownRootPath)
        let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
        let destinationRootURL = plan.destinationURL.deletingLastPathComponent()
        let hasDestinationAccess = destinationRootURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { rootURL.stopAccessingSecurityScopedResource() }
            if hasDestinationAccess { destinationRootURL.stopAccessingSecurityScopedResource() }
        }

        let sourceURL = rootURL.appendingPathComponent(request.relativePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard !FileManager.default.fileExists(atPath: plan.destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.copyItem(at: sourceURL, to: plan.destinationURL)
    }

    private func recordCurrentFilename(_ filename: String) {
        currentFilename = filename
    }

    private func recordProgress(
        completedCount: Int,
        succeededCount: Int,
        failures: [OriginalPhotoExportFailure]
    ) {
        self.completedCount = completedCount
        self.succeededCount = succeededCount
        self.failures = failures
    }

    private func finish(
        cancelled: Bool,
        completedCount: Int,
        succeededCount: Int,
        failures: [OriginalPhotoExportFailure]
    ) {
        self.completedCount = completedCount
        self.succeededCount = succeededCount
        self.failures = failures
        currentFilename = nil
        state = cancelled ? .cancelled : .completed
        exportTask = nil
    }
}
