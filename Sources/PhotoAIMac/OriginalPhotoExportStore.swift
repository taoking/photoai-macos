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
    let destinationRootURL: URL
    let destinationURL: URL
}

enum OriginalPhotoExportLayout: Sendable {
    case flat
    case preserveDirectoryStructure
}

enum OriginalPhotoExportPlanner {
    static func plans(
        requests: [OriginalPhotoExportRequest],
        destinationURL: URL,
        existingFilenames: [String],
        layout: OriginalPhotoExportLayout = .flat
    ) -> [OriginalPhotoExportPlan] {
        var occupiedNamesByDirectory: [String: Set<String>] = [:]
        for existingPath in existingFilenames {
            let directory = normalizedDirectory((existingPath as NSString).deletingLastPathComponent)
            occupiedNamesByDirectory[directory, default: []].insert(
                normalizedFilename((existingPath as NSString).lastPathComponent)
            )
        }

        return requests.map { request in
            let relativeDirectory = layout == .preserveDirectoryStructure
                ? safeRelativeDirectory(for: request.relativePath)
                : ""
            let directoryKey = normalizedDirectory(relativeDirectory)
            var occupiedNames = occupiedNamesByDirectory[directoryKey, default: []]
            let filename = conflictSafeFilename(
                preferredFilename: request.filename,
                occupiedFilenames: &occupiedNames
            )
            occupiedNamesByDirectory[directoryKey] = occupiedNames
            let targetDirectory = relativeDirectory.isEmpty
                ? destinationURL
                : destinationURL.appendingPathComponent(relativeDirectory, isDirectory: true)
            return OriginalPhotoExportPlan(
                request: request,
                destinationRootURL: destinationURL,
                destinationURL: targetDirectory.appendingPathComponent(filename, isDirectory: false)
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

    private static func normalizedDirectory(_ directory: String) -> String {
        let normalized = directory == "." ? "" : directory
        return normalized.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func safeRelativeDirectory(for relativePath: String) -> String {
        guard !relativePath.hasPrefix("/") else { return "" }
        let directory = (relativePath as NSString).deletingLastPathComponent
        guard directory != ".", !directory.isEmpty else { return "" }
        let components = directory.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return "" }
        return components.joined(separator: "/")
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
    /// 本次导出中已成功复制的资产。导出结束后交给 Catalog 记为已导出。
    private(set) var exportedAssetIDs: Set<UUID> = []
    /// 由 App 接线：成功导出的资产要在 Catalog 里留下标记，
    /// 否则"选一批 → 导出 → 下次再选"这个循环里分不清哪些处理过了。
    var onAssetsExported: ((Set<UUID>) -> Void)?

    private var exportTask: Task<Void, Never>?

    deinit {
        exportTask?.cancel()
    }

    var progressDescription: String? {
        guard totalCount > 0 else { return nil }
        var components = ["\(state.title) \(completedCount) / \(totalCount)"]
        if let currentFilename, state.isActive { components.append(currentFilename) }
        if let failureSummary { components.append(failureSummary) }
        return components.joined(separator: " · ")
    }

    /// 失败原因要写进提示本身。只报一个"失败 1"等于没说：用户看不出是原盘拔了、
    /// 目标已存在同名文件，还是别的原因。
    var failureSummary: String? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            return "失败：\(first.filename) — \(first.message)"
        }
        return "失败 \(failures.count) 项，首个：\(first.filename) — \(first.message)"
    }

    func chooseDestinationAndStart(
        assets: [PhotoAsset],
        catalog: CatalogStore,
        preserveDirectoryStructure: Bool = false
    ) {
        guard !assets.isEmpty, !state.isActive else { return }
        let panel = NSOpenPanel()
        panel.title = "导出原始照片"
        panel.message = preserveDirectoryStructure
            ? "选择目标文件夹。PhotoAI Mac 会复制原文件、保留来源目录结构和扩展名，不会覆盖已有文件。"
            : "选择目标文件夹。PhotoAI Mac 会复制原文件并保留扩展名，不会覆盖已有文件。"
        panel.prompt = "导出到此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        let requests = assets.compactMap(catalog.originalExportRequest)
        start(
            requests: requests,
            destinationURL: destinationURL,
            layout: preserveDirectoryStructure ? .preserveDirectoryStructure : .flat
        )
    }

    func startForTesting(
        requests: [OriginalPhotoExportRequest],
        destinationURL: URL,
        layout: OriginalPhotoExportLayout = .flat
    ) {
        start(requests: requests, destinationURL: destinationURL, layout: layout)
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelling
        exportTask?.cancel()
    }

    private func start(
        requests: [OriginalPhotoExportRequest],
        destinationURL: URL,
        layout: OriginalPhotoExportLayout
    ) {
        guard !requests.isEmpty, !state.isActive else { return }
        let existingNames = existingRelativePaths(at: destinationURL, recursively: layout == .preserveDirectoryStructure)
        let plans = OriginalPhotoExportPlanner.plans(
            requests: requests,
            destinationURL: destinationURL,
            existingFilenames: existingNames,
            layout: layout
        )

        self.destinationURL = destinationURL
        state = .running
        totalCount = plans.count
        completedCount = 0
        succeededCount = 0
        currentFilename = nil
        failures = []
        exportedAssetIDs = []

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
                    await self?.recordExported(plan.request.assetID)
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
        let destinationRootURL = plan.destinationRootURL
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
        let standardizedRootPath = destinationRootURL.standardizedFileURL.path + "/"
        guard plan.destinationURL.standardizedFileURL.path.hasPrefix(standardizedRootPath) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: plan.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: plan.destinationURL)
    }

    private func existingRelativePaths(at rootURL: URL, recursively: Bool) -> [String] {
        guard recursively else {
            return (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { value -> String? in
            guard let url = value as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    private func recordCurrentFilename(_ filename: String) {
        currentFilename = filename
    }

    private func recordExported(_ assetID: UUID) {
        exportedAssetIDs.insert(assetID)
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
        // 取消也要记：已经复制完成的那些确实导出了。
        if !exportedAssetIDs.isEmpty {
            onAssetsExported?(exportedAssetIDs)
        }
    }
}
