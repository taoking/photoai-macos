import AppKit
import Foundation
@preconcurrency import Photos

/// 仅在用户明确选择目录并点击导入后运行。它从 PhotoKit 读取所选原始资源，写到用户选择的目录，
/// 成功写入后才通知本地 Catalog 扫描；绝不会改变 Apple Photos 中的任何对象。
@MainActor
final class ApplePhotosImportCoordinator: ObservableObject {
    static let maximumConcurrentResourceImports = 2

    @Published private(set) var state: ApplePhotosImportState = .idle
    @Published private(set) var progress = ApplePhotosImportProgress()
    @Published private(set) var result: ApplePhotosImportResult = .empty
    @Published private(set) var destinationURL: URL?

    private var importTask: Task<Void, Never>?

    deinit {
        importTask?.cancel()
    }

    /// 用户显式挑选目录；不会默认复制到 Application Support 或其他隐藏目录。
    func chooseDestinationAndImport(assetIDs: Set<String>, store: ApplePhotosStore, catalog: CatalogStore) {
        guard !assetIDs.isEmpty, !state.isActive else { return }

        let panel = NSOpenPanel()
        panel.title = "导入 Apple Photos 原始资源"
        panel.message = "选择导入目录。PhotoAI Mac 只会复制你已选择的原始资源，不会修改 Apple Photos。"
        panel.prompt = "导入到此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        startImport(assetIDs: assetIDs, destinationURL: destinationURL, store: store, catalog: catalog)
    }

    /// 供单元测试和未来自定义 UI 使用；调用者必须已经获得用户明确选择的目录。
    func startImport(assetIDs: Set<String>, destinationURL: URL, store: ApplePhotosStore, catalog: CatalogStore) {
        guard !assetIDs.isEmpty, !state.isActive else { return }
        let workItems = makeWorkItems(assetIDs: assetIDs, store: store, destinationURL: destinationURL)
        guard !workItems.isEmpty else {
            state = .failed("没有可导入的原始资源。")
            return
        }

        self.destinationURL = destinationURL
        state = .importing
        result = .empty
        progress = ApplePhotosImportProgress(totalResources: workItems.count)
        let progressReporter = ImportProgressReporter(coordinator: self)

        importTask = Task { [weak self, weak catalog] in
            let outcomes = await Self.transfer(
                workItems: workItems,
                maximumConcurrency: Self.maximumConcurrentResourceImports,
                progressReporter: progressReporter
            )

            guard let self else { return }
            let completedResult = Self.makeResult(outcomes: outcomes, wasCancelled: Task.isCancelled)
            result = completedResult
            progress.completedResources = completedResult.writtenFileURLs.count
            progress.failedResources = completedResult.failures.count
            progress.currentFilename = nil
            progress.currentFraction = 0

            if !completedResult.writtenFileURLs.isEmpty, let catalog {
                // 真实文件已落盘后才创建/重扫 Catalog source；PHAsset 从不提前变成 PhotoAsset。
                await catalog.addFolder(destinationURL)
            }

            if Task.isCancelled || completedResult.wasCancelled {
                state = .cancelled
            } else if completedResult.writtenFileURLs.isEmpty, let failure = completedResult.failures.first {
                state = .failed(failure.message)
            } else {
                state = .completed
            }
            importTask = nil
        }
    }

    func cancel() {
        guard state == .importing else { return }
        state = .cancelling
        importTask?.cancel()
    }

    private func makeWorkItems(assetIDs: Set<String>, store: ApplePhotosStore, destinationURL: URL) -> [ImportWorkItem] {
        let fileManager = FileManager.default
        let existing = (try? fileManager.contentsOfDirectory(atPath: destinationURL.path)) ?? []
        var occupiedNames = Set(existing.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        var workItems: [ImportWorkItem] = []

        // 根据当前浏览顺序生成稳定计划；每个资源取得唯一目标名后才启动并发写入。
        for asset in store.assets where assetIDs.contains(asset.id) {
            let descriptors = store.resourceDescriptors(for: asset.id)
            let plans = ApplePhotosImportPlanner.plan(assetID: asset.id, resources: descriptors)
            for plan in plans {
                guard let resource = store.photoKitResource(assetID: asset.id, sourceIndex: plan.sourceIndex) else { continue }
                let filename = ApplePhotosImportPlanner.conflictSafeFilename(
                    preferredFilename: plan.filename,
                    occupiedFilenames: &occupiedNames
                )
                workItems.append(
                    ImportWorkItem(
                        plan: plan,
                        resource: resource,
                        destinationURL: destinationURL.appendingPathComponent(filename, isDirectory: false)
                    )
                )
            }
        }
        return workItems
    }

    fileprivate func updateCurrentProgress(filename: String, fraction: Double) {
        guard state == .importing || state == .cancelling else { return }
        progress.currentFilename = filename
        progress.currentFraction = min(max(fraction, 0), 1)
    }

    fileprivate func finishCurrentResource(succeeded: Bool) {
        guard state == .importing || state == .cancelling else { return }
        if succeeded {
            progress.completedResources += 1
        } else {
            progress.failedResources += 1
        }
        progress.currentFraction = 0
    }

    private static func transfer(
        workItems: [ImportWorkItem],
        maximumConcurrency: Int,
        progressReporter: ImportProgressReporter
    ) async -> [ImportOutcome] {
        await withTaskGroup(of: ImportOutcome.self) { group in
            var outcomes: [ImportOutcome] = []
            var nextIndex = 0
            let workerCount = min(maximumConcurrency, workItems.count)

            func scheduleNext() {
                guard nextIndex < workItems.count else { return }
                let item = workItems[nextIndex]
                nextIndex += 1
                group.addTask {
                    await transfer(item: item, progressReporter: progressReporter)
                }
            }

            for _ in 0..<workerCount { scheduleNext() }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                let succeeded: Bool
                if case .success = outcome.result {
                    succeeded = true
                } else {
                    succeeded = false
                }
                await progressReporter.resourceFinished(succeeded: succeeded)
                if !Task.isCancelled {
                    scheduleNext()
                }
            }
            group.cancelAll()
            return outcomes
        }
    }

    private static func transfer(
        item: ImportWorkItem,
        progressReporter: ImportProgressReporter
    ) async -> ImportOutcome {
        do {
            try Task.checkCancellation()
            await progressReporter.report(filename: item.destinationURL.lastPathComponent, fraction: 0)
            try FileManager.default.createDirectory(at: item.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await PhotoKitResourceTransfer.write(
                resource: item.resource,
                to: item.destinationURL,
                progressHandler: { filename, fraction in
                    Task { await progressReporter.report(filename: filename, fraction: fraction) }
                }
            )
            try Task.checkCancellation()
            return ImportOutcome(item: item, result: .success(()))
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: item.destinationURL)
            return ImportOutcome(item: item, result: .failure(ImportFailure.cancelled))
        } catch {
            try? FileManager.default.removeItem(at: item.destinationURL)
            return ImportOutcome(item: item, result: .failure(ImportFailure.message(error.localizedDescription)))
        }
    }

    private static func makeResult(outcomes: [ImportOutcome], wasCancelled: Bool) -> ApplePhotosImportResult {
        var writtenFileURLs: [URL] = []
        var successfulResourceCountByAssetID: [String: Int] = [:]
        var plannedResourceCountByAssetID: [String: Int] = [:]
        var failures: [ApplePhotosImportFailure] = []
        var fallbackCount = 0
        var cancelled = wasCancelled

        for outcome in outcomes {
            plannedResourceCountByAssetID[outcome.item.plan.assetID, default: 0] += 1
            if !outcome.item.plan.role.isOriginal { fallbackCount += 1 }
            switch outcome.result {
            case .success:
                writtenFileURLs.append(outcome.item.destinationURL)
                successfulResourceCountByAssetID[outcome.item.plan.assetID, default: 0] += 1
            case let .failure(failure):
                if failure == .cancelled { cancelled = true }
                failures.append(
                    ApplePhotosImportFailure(
                        assetID: outcome.item.plan.assetID,
                        filename: outcome.item.destinationURL.lastPathComponent,
                        message: failure.message
                    )
                )
            }
        }

        let importedAssetIDs = Set(plannedResourceCountByAssetID.compactMap { assetID, plannedCount in
            successfulResourceCountByAssetID[assetID] == plannedCount ? assetID : nil
        })
        return ApplePhotosImportResult(
            writtenFileURLs: writtenFileURLs,
            importedAssetIDs: importedAssetIDs,
            failures: failures,
            usedFallbackResources: fallbackCount,
            wasCancelled: cancelled
        )
    }

    private struct ImportWorkItem: @unchecked Sendable {
        let plan: ApplePhotosImportResourcePlan
        let resource: PHAssetResource
        let destinationURL: URL
    }

    private struct ImportOutcome: Sendable {
        let item: ImportWorkItem
        let result: Result<Void, ImportFailure>
    }

    private enum ImportFailure: Error, Equatable, Sendable {
        case cancelled
        case message(String)

        var message: String {
            switch self {
            case .cancelled: "导入已取消"
            case let .message(message): message
            }
        }
    }
}

private actor ImportProgressReporter {
    let coordinator: ApplePhotosImportCoordinator

    init(coordinator: ApplePhotosImportCoordinator) {
        self.coordinator = coordinator
    }

    func report(filename: String, fraction: Double) async {
        await coordinator.updateCurrentProgress(filename: filename, fraction: fraction)
    }

    func resourceFinished(succeeded: Bool) async {
        await coordinator.finishCurrentResource(succeeded: succeeded)
    }
}

/// `requestData` 提供取消请求 ID；与 `writeData` 相比可以在流式写入中报告 iCloud 下载进度并立即取消。
private final class PhotoKitResourceTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID
    private var cancellationRequested = false

    static func write(
        resource: PHAssetResource,
        to destinationURL: URL,
        progressHandler: @escaping @Sendable (String, Double) -> Void
    ) async throws {
        let transfer = PhotoKitResourceTransfer()
        try await transfer.write(resource: resource, to: destinationURL, progressHandler: progressHandler)
    }

    private func write(
        resource: PHAssetResource,
        to destinationURL: URL,
        progressHandler: @escaping @Sendable (String, Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destinationURL)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let options = PHAssetResourceRequestOptions()
                // 唯一允许网络的路径：用户已选择具体资产、具体资源及明确目的文件夹的显式导入。
                options.isNetworkAccessAllowed = true
                options.progressHandler = { fraction in
                    progressHandler(destinationURL.lastPathComponent, fraction)
                }

                let id = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        do {
                            try handle.write(contentsOf: data)
                        } catch {
                            self.cancel()
                        }
                    },
                    completionHandler: { error in
                        do { try handle.close() } catch { }
                        self.clearRequestID()
                        if let error {
                            continuation.resume(throwing: error)
                        } else if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume()
                        }
                    }
                )
                self.setRequestID(id)
            }
        }, onCancel: { [self] in
            cancel()
        })
    }

    private func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel, id != PHInvalidAssetResourceDataRequestID {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    private func clearRequestID() {
        lock.lock()
        requestID = PHInvalidAssetResourceDataRequestID
        lock.unlock()
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let id = requestID
        requestID = PHInvalidAssetResourceDataRequestID
        lock.unlock()
        if id != PHInvalidAssetResourceDataRequestID {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }
}
