@preconcurrency import AppKit
import Foundation
import UniformTypeIdentifiers

struct ExportPreset: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var quality: Double
    var filenameSuffix: String

    static let highQualityJPEG = ExportPreset(
        id: UUID(uuidString: "660A7EA1-A76A-4B44-9FDE-9152CE3AD41F")!,
        name: "高质量 JPEG",
        quality: 0.92,
        filenameSuffix: "-Edited"
    )
    static let compactJPEG = ExportPreset(
        id: UUID(uuidString: "C2876C28-A450-4055-B7D9-4BBDF6EB42CC")!,
        name: "紧凑 JPEG",
        quality: 0.8,
        filenameSuffix: "-Web"
    )
}

struct BatchExportFailure: Identifiable, Hashable, Sendable {
    let id: UUID
    let assetID: UUID
    let displayName: String
    let message: String
}

enum BatchExportState: Equatable {
    case idle
    case running
    case cancelling
    case completed
    case cancelled

    var title: String {
        switch self {
        case .idle: ""
        case .running: "正在批量导出"
        case .cancelling: "正在取消批量导出"
        case .completed: "批量导出完成"
        case .cancelled: "批量导出已取消"
        }
    }
}

private struct BatchPresetSnapshot: Codable {
    var presets: [ExportPreset]
}

private struct BatchPresetPersistence {
    let fileURL: URL

    static let defaultFileURL: URL = {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDirectory
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("export-presets.json")
    }()

    func load() throws -> [ExportPreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [.highQualityJPEG, .compactJPEG]
        }
        return try JSONDecoder().decode(BatchPresetSnapshot.self, from: Data(contentsOf: fileURL)).presets
    }

    func save(_ presets: [ExportPreset]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BatchPresetSnapshot(presets: presets)).write(to: fileURL, options: .atomic)
    }
}

private struct BatchExportItem: Sendable {
    let assetID: UUID
    let displayName: String
    let request: ImageRenderRequest?
    let outputURL: URL
}

@MainActor
final class BatchWorkflowStore: ObservableObject {
    @Published private(set) var copiedRecipe: EditRecipe?
    @Published private(set) var presets: [ExportPreset]
    @Published var selectedPresetID: UUID
    @Published private(set) var state: BatchExportState = .idle
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var succeededCount = 0
    @Published private(set) var failures: [BatchExportFailure] = []
    @Published private(set) var lastErrorMessage: String?

    private let persistence: BatchPresetPersistence
    private var batchTask: Task<Void, Never>?

    init(storageURL: URL = BatchPresetPersistence.defaultFileURL) {
        persistence = BatchPresetPersistence(fileURL: storageURL)
        let loadedPresets: [ExportPreset]
        let loadErrorMessage: String?
        do {
            loadedPresets = try persistence.load()
            loadErrorMessage = nil
        } catch {
            loadedPresets = [.highQualityJPEG, .compactJPEG]
            loadErrorMessage = "无法读取导出预设：\(error.localizedDescription)"
        }
        presets = loadedPresets
        selectedPresetID = loadedPresets.first?.id ?? ExportPreset.highQualityJPEG.id
        lastErrorMessage = loadErrorMessage
    }

    deinit {
        batchTask?.cancel()
    }

    var selectedPreset: ExportPreset {
        presets.first(where: { $0.id == selectedPresetID }) ?? .highQualityJPEG
    }

    var progressDescription: String? {
        guard totalCount > 0 else { return nil }
        let base = "\(state.title) \(completedCount) / \(totalCount)"
        if failures.isEmpty { return base }
        return "\(base)，失败 \(failures.count) 项"
    }

    func savePreset(_ preset: ExportPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistPresets()
    }

    func copyAdjustments(from asset: PhotoAsset, catalog: CatalogStore) {
        copiedRecipe = catalog.recipe(for: asset)
    }

    @discardableResult
    func pasteAdjustments(to assetIDs: Set<UUID>, catalog: CatalogStore) -> Bool {
        guard let copiedRecipe, !assetIDs.isEmpty else { return false }
        catalog.replaceRecipe(copiedRecipe, for: assetIDs)
        return true
    }

    @discardableResult
    func syncAdjustments(from anchor: PhotoAsset, to assetIDs: Set<UUID>, catalog: CatalogStore) -> Bool {
        let destinationIDs = assetIDs.subtracting([anchor.id])
        guard !destinationIDs.isEmpty else { return false }
        catalog.replaceRecipe(catalog.recipe(for: anchor), for: destinationIDs)
        return true
    }

    func chooseDestinationAndStart(
        assets: [PhotoAsset],
        preset: ExportPreset,
        requestProvider: (PhotoAsset) -> ImageRenderRequest?
    ) {
        guard !assets.isEmpty, state != .running, state != .cancelling else { return }

        let panel = NSOpenPanel()
        panel.title = "选择批量导出位置"
        panel.message = "会为每张照片创建新的 JPEG 文件，原始文件不会被修改。"
        panel.prompt = "开始导出"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        let items = makeItems(assets: assets, directoryURL: directoryURL, preset: preset, requestProvider: requestProvider)
        start(items: items, preset: preset)
    }

    func startForTesting(
        assets: [PhotoAsset],
        directoryURL: URL,
        preset: ExportPreset,
        requestProvider: (PhotoAsset) -> ImageRenderRequest?
    ) {
        let items = makeItems(assets: assets, directoryURL: directoryURL, preset: preset, requestProvider: requestProvider)
        start(items: items, preset: preset)
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelling
        batchTask?.cancel()
    }

    private func makeItems(
        assets: [PhotoAsset],
        directoryURL: URL,
        preset: ExportPreset,
        requestProvider: (PhotoAsset) -> ImageRenderRequest?
    ) -> [BatchExportItem] {
        var allocatedFilenames = Set<String>()
        return assets.map { asset in
            let outputURL = uniqueOutputURL(
                for: asset,
                directoryURL: directoryURL,
                preset: preset,
                allocatedFilenames: &allocatedFilenames
            )
            return BatchExportItem(
                assetID: asset.id,
                displayName: asset.filename,
                request: requestProvider(asset),
                outputURL: outputURL
            )
        }
    }

    private func start(items: [BatchExportItem], preset: ExportPreset) {
        guard !items.isEmpty, state != .running, state != .cancelling else { return }
        state = .running
        completedCount = 0
        totalCount = items.count
        succeededCount = 0
        failures = []
        lastErrorMessage = nil

        batchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var completedCount = 0
            var succeededCount = 0
            var failures: [BatchExportFailure] = []

            for item in items {
                guard !Task.isCancelled else {
                    await self?.finish(cancelled: true, completedCount: completedCount, succeededCount: succeededCount, failures: failures)
                    return
                }

                if let request = item.request {
                    do {
                        try ImageRenderer.exportJPEG(request, to: item.outputURL, quality: preset.quality)
                        succeededCount += 1
                    } catch {
                        failures.append(
                            BatchExportFailure(
                                id: UUID(),
                                assetID: item.assetID,
                                displayName: item.displayName,
                                message: error.localizedDescription
                            )
                        )
                    }
                } else {
                    failures.append(
                        BatchExportFailure(
                            id: UUID(),
                            assetID: item.assetID,
                            displayName: item.displayName,
                            message: "无法访问原始文件。"
                        )
                    )
                }

                completedCount += 1
                await self?.recordProgress(completedCount: completedCount, succeededCount: succeededCount, failures: failures)
            }

            await self?.finish(cancelled: false, completedCount: completedCount, succeededCount: succeededCount, failures: failures)
        }
    }

    private func recordProgress(completedCount: Int, succeededCount: Int, failures: [BatchExportFailure]) {
        self.completedCount = completedCount
        self.succeededCount = succeededCount
        self.failures = failures
    }

    private func finish(cancelled: Bool, completedCount: Int, succeededCount: Int, failures: [BatchExportFailure]) {
        self.completedCount = completedCount
        self.succeededCount = succeededCount
        self.failures = failures
        state = cancelled ? .cancelled : .completed
        batchTask = nil
    }

    private func uniqueOutputURL(
        for asset: PhotoAsset,
        directoryURL: URL,
        preset: ExportPreset,
        allocatedFilenames: inout Set<String>
    ) -> URL {
        let baseName = (asset.filename as NSString).deletingPathExtension
        var index = 1
        while true {
            let suffix = index == 1 ? preset.filenameSuffix : "\(preset.filenameSuffix)-\(index)"
            let filename = "\(baseName)\(suffix).jpg"
            let normalizedFilename = filename.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let candidate = directoryURL.appendingPathComponent(filename)
            if !allocatedFilenames.contains(normalizedFilename),
               !FileManager.default.fileExists(atPath: candidate.path) {
                allocatedFilenames.insert(normalizedFilename)
                return candidate
            }
            index += 1
        }
    }

    private func persistPresets() {
        do {
            try persistence.save(presets)
        } catch {
            lastErrorMessage = "无法保存导出预设：\(error.localizedDescription)"
        }
    }
}
