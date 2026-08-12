import AppKit
import Foundation

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var sources: [PhotoSource]
    @Published private(set) var assets: [PhotoAsset]
    @Published private(set) var scanProgress: [UUID: Int] = [:]
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var selectedAssetIDs = Set<UUID>()
    @Published private(set) var archiveLocations: [AssetLocation] = []
    @Published private(set) var archiveRelationships: [ArchiveDuplicateRelationship] = []
    @Published private(set) var lastArchiveImportSummary = ArchiveImportSummary()
    /// 扫描结束时递增；AppShell 只据此转交新增/变化的归档请求，绝不监听整个 assets 数组。
    @Published private(set) var archiveEnqueueRevision = 0
    /// 让仅依赖 SQLite 派生元数据的视图在归档完成后刷新，而无需重写 JSON Catalog 资产。
    @Published private(set) var archiveRevision = 0
    @Published var filter: LibraryFilter = .all
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchInterpretation = SearchInterpretation.empty
    @Published private(set) var isInterpretingSearch = false

    private var selectionAnchorID: UUID?

    private let persistence: CatalogPersistence
    private let archiveIndex: ArchiveIndexPersistence?
    private let archivePreviewDirectory: URL
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var latestArchiveScanAssetIDs = Set<UUID>()
    private var latestArchiveExactDuplicateIDs = Set<UUID>()
    private var latestArchiveVisualDuplicateIDs = Set<UUID>()
    private var archiveMetadataByAssetID: [UUID: ArchiveAssetMetadata] = [:]
    private var archiveLocationsByAssetID: [UUID: [AssetLocation]] = [:]
    private var archiveExactDuplicateAssetIDsByAssetID: [UUID: Set<UUID>] = [:]
    private var archiveAvailabilityByAssetID: [UUID: AssetArchiveAvailability] = [:]
    private var archiveOriginalLocationByAssetID: [UUID: AssetLocation] = [:]
    private var archiveAvailableCopyLocationByAssetID: [UUID: AssetLocation] = [:]
    private var sourceByID: [UUID: PhotoSource] = [:]
    private var assetByID: [UUID: PhotoAsset] = [:]
    private var scheduledArchiveAssetIDs = Set<UUID>()

    init(storageURL: URL = CatalogPersistence.defaultFileURL) {
        persistence = CatalogPersistence(fileURL: storageURL)
        archivePreviewDirectory = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("ArchivePreviews", isDirectory: true)

        let databaseURL = ArchiveIndexPersistence.databaseURL(for: storageURL)
        let shouldCreateMigrationBackup = !FileManager.default.fileExists(atPath: databaseURL.path)
        // JSON 是用户编辑、OCR 与既有资产身份的恢复基线；SQLite 迁移前先保留独立副本。
        if shouldCreateMigrationBackup,
           FileManager.default.fileExists(atPath: storageURL.path) {
            let backupURL = storageURL.appendingPathExtension("phase14-pre-sqlite.bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.copyItem(at: storageURL, to: backupURL)
            }
        }
        do {
            archiveIndex = try ArchiveIndexPersistence(databaseURL: databaseURL)
        } catch {
            archiveIndex = nil
            lastErrorMessage = "无法打开本地归档索引：\(error.localizedDescription)"
        }

        do {
            let snapshot = try persistence.load()
            sources = snapshot.sources
            assets = snapshot.assets
        } catch {
            sources = []
            assets = []
            lastErrorMessage = "无法读取本地 Catalog：\(error.localizedDescription)"
        }
        rebuildCatalogLookups()
        let offlineSourceIDs = sources.indices.compactMap { index -> UUID? in
            guard sources[index].status == .ready,
                  !FileManager.default.fileExists(atPath: sources[index].lastKnownPath) else {
                return nil
            }
            sources[index].status = .missing
            return sources[index].id
        }
        rebuildSourceLookup()
        do {
            try archiveIndex?.bootstrap(sources: sources, assets: assets)
            reloadArchiveIndex()
        } catch {
            // SQLite 是可重新建立的派生索引；失败绝不能让既有 JSON Catalog 丢失或重置。
            lastErrorMessage = "无法初始化本地归档索引：\(error.localizedDescription)"
        }
        if !offlineSourceIDs.isEmpty { persist() }
    }

    deinit {
        scanTasks.values.forEach { $0.cancel() }
    }

    func chooseAndAddFolder() {
        let panel = NSOpenPanel()
        panel.title = "添加照片文件夹"
        panel.message = "PhotoAI Mac 只建立本地索引，不会复制或修改原始文件。"
        panel.prompt = "添加文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startAddingFolder(url)
    }

    func startAddingFolder(_ rootURL: URL) {
        Task { [weak self] in
            await self?.addFolder(rootURL)
        }
    }

    func addFolder(_ rootURL: URL) async {
        let standardizedURL = rootURL.standardizedFileURL

        if let existingSource = sources.first(where: { $0.lastKnownPath == standardizedURL.path }) {
            await rescan(existingSource.id)
            return
        }

        do {
            let bookmarkData = try standardizedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let source = PhotoSource(
                id: UUID(),
                bookmarkData: bookmarkData,
                displayName: standardizedURL.lastPathComponent,
                lastKnownPath: standardizedURL.path,
                createdAt: .now,
                lastScannedAt: nil,
                status: .ready,
                assetCount: 0
            )
            sources.append(source)
            rebuildSourceLookup()
            persist()
            await rescan(source.id)
        } catch {
            lastErrorMessage = "无法保存文件夹访问权限：\(error.localizedDescription)"
        }
    }

    func startRescanAll() {
        for source in sources where scanTasks[source.id] == nil {
            scanTasks[source.id] = Task { [weak self] in
                await self?.rescan(source.id)
            }
        }
    }

    func startRescan(_ sourceID: UUID) {
        guard scanTasks[sourceID] == nil else { return }
        scanTasks[sourceID] = Task { [weak self] in
            await self?.rescan(sourceID)
        }
    }

    func cancelScan(for sourceID: UUID) {
        scanTasks[sourceID]?.cancel()
    }

    func assets(for destination: SidebarDestination) -> [PhotoAsset] {
        let destinationAssets: [PhotoAsset]
        switch destination {
        case .allPhotos, .recentImports, .folders, .albums, .archive, .people, .cleanup:
            destinationAssets = assets
        case .applePhotos:
            destinationAssets = []
        case .search:
            destinationAssets = assets.filter { searchInterpretation.query.matches($0) }
        case .favorites:
            destinationAssets = assets.filter(\.isFavorite)
        case .raw:
            destinationAssets = assets.filter(\.isRAW)
        case .videos:
            destinationAssets = assets.filter { $0.mediaType == .video }
        case .missingFiles:
            let missingSourceIDs = Set(sources.filter { $0.status == .missing }.map(\.id))
            destinationAssets = assets.filter { missingSourceIDs.contains($0.sourceID) }
        }

        let filtered = destinationAssets.filter { filter.matches($0) }
        if destination == .recentImports {
            return filtered.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        }
        return filtered
    }

    var selectedAsset: PhotoAsset? {
        guard selectedAssetIDs.count == 1, let id = selectedAssetIDs.first else { return nil }
        return assets.first(where: { $0.id == id })
    }

    var selectedAssets: [PhotoAsset] {
        assets.filter { selectedAssetIDs.contains($0.id) }
    }

    var selectionAnchorAsset: PhotoAsset? {
        guard let selectionAnchorID else { return nil }
        return assets.first(where: { $0.id == selectionAnchorID })
    }

    func thumbnailRequest(for asset: PhotoAsset) -> ThumbnailRequest? {
        guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
        return ThumbnailRequest(
            assetID: asset.id,
            bookmarkData: source.bookmarkData,
            lastKnownRootPath: source.lastKnownPath,
            relativePath: asset.relativePath,
            modificationDate: asset.modifiedAt,
            mediaType: asset.mediaType,
            offlinePreviewURL: offlinePreviewURL(for: asset)
        )
    }

    func offlinePreviewURL(for asset: PhotoAsset) -> URL? {
        _ = archiveRevision
        guard let url = ArchiveProcessor.previewURL(for: archiveMetadata(for: asset), previewDirectory: archivePreviewDirectory),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func archiveMetadata(for asset: PhotoAsset) -> ArchiveAssetMetadata {
        _ = archiveRevision
        return archiveMetadataByAssetID[asset.id] ?? .empty
    }

    func archiveAvailability(for asset: PhotoAsset) -> AssetArchiveAvailability {
        _ = archiveRevision
        return archiveAvailabilityByAssetID[asset.id] ?? .missing
    }

    func archiveOriginalLocation(for asset: PhotoAsset) -> AssetLocation? {
        _ = archiveRevision
        return archiveOriginalLocationByAssetID[asset.id]
    }

    func archiveAvailableCopyLocation(for asset: PhotoAsset) -> AssetLocation? {
        _ = archiveRevision
        return archiveAvailableCopyLocationByAssetID[asset.id]
    }

    func revealArchiveCopy(_ location: AssetLocation) {
        guard let source = sources.first(where: { $0.id == location.sourceID }) else { return }
        let url = URL(fileURLWithPath: source.lastKnownPath).appendingPathComponent(location.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastErrorMessage = "可用副本已不在记录的位置。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 仅在应用启动时调用一次，恢复 SQLite 中 pending/stale 的归档工作。
    func initialArchiveProcessingRequests() -> [ArchiveProcessingRequest] {
        archiveProcessingRequests(for: Set(assets.map(\.id)))
    }

    /// 由扫描或显式“重新建立预览”产生的增量候选集合；不会遍历整个 Catalog。
    func takeScheduledArchiveProcessingRequests() -> [ArchiveProcessingRequest] {
        let identifiers = scheduledArchiveAssetIDs
        scheduledArchiveAssetIDs = []
        return archiveProcessingRequests(for: identifiers)
    }

    func archiveProcessingRequests(for assetIDs: Set<UUID>) -> [ArchiveProcessingRequest] {
        guard !assetIDs.isEmpty else { return [] }
        return assetIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { assetID in
            guard let asset = assetByID[assetID] else { return nil }
            let metadata = archiveMetadataByAssetID[asset.id] ?? .empty
            guard let source = sourceByID[asset.sourceID], source.status == .ready,
                  metadata.needsHash(for: asset) || metadata.needsPreview(for: asset),
                  FileManager.default.fileExists(atPath: URL(fileURLWithPath: source.lastKnownPath).appendingPathComponent(asset.relativePath).path) else {
                return nil
            }
            return ArchiveProcessingRequest(asset: asset, bookmarkData: source.bookmarkData, rootPath: source.lastKnownPath, existingMetadata: metadata)
        }
    }

    func applyArchiveProcessingResult(_ result: ArchiveProcessingResult, relationships: [ArchiveDuplicateRelationship]) {
        guard assetByID[result.assetID] != nil else { return }
        archiveMetadataByAssetID[result.assetID] = result.metadata
        var byKey = Dictionary(uniqueKeysWithValues: archiveRelationships.map { ($0.key, $0) })
        byKey = byKey.filter { _, relationship in
            relationship.firstAssetID != result.assetID && relationship.secondAssetID != result.assetID
        }
        for relationship in relationships { byKey[relationship.key] = relationship }
        archiveRelationships = byKey.values.sorted { $0.discoveredAt > $1.discoveredAt }
        rebuildRelationshipLookups()
        updateArchiveAvailability(for: Set([result.assetID]).union(relationships.flatMap { [$0.firstAssetID, $0.secondAssetID] }))
        archiveRevision &+= 1
        guard latestArchiveScanAssetIDs.contains(result.assetID) else { return }
        for relationship in relationships {
            guard relationship.firstAssetID == result.assetID || relationship.secondAssetID == result.assetID else { continue }
            switch relationship.kind {
            case .exactDuplicate: latestArchiveExactDuplicateIDs.insert(result.assetID)
            case .possibleVisualDuplicate: latestArchiveVisualDuplicateIDs.insert(result.assetID)
            case .sameIndexedFile: break
            }
        }
        lastArchiveImportSummary.exactDuplicateCount = latestArchiveExactDuplicateIDs.count
        lastArchiveImportSummary.possibleVisualDuplicateCount = latestArchiveVisualDuplicateIDs.count
    }

    func markArchiveSourceUnavailable(_ sourceID: UUID) {
        guard let sourceIndex = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[sourceIndex].status = .missing
        rebuildSourceLookup()
        do {
            try archiveIndex?.recordUnavailableSource(sourceID)
        } catch {
            lastErrorMessage = "无法更新离线来源的归档状态：\(error.localizedDescription)"
            return
        }
        reloadArchiveIndex()
        persist()
    }

    func markArchiveLocationUnavailable(for asset: PhotoAsset) {
        guard let source = sourceByID[asset.sourceID] else { return }
        if !FileManager.default.fileExists(atPath: source.lastKnownPath) {
            markArchiveSourceUnavailable(source.id)
            return
        }
        do {
            try archiveIndex?.recordUnavailableLocation(sourceID: source.id, relativePath: asset.relativePath)
            reloadArchiveIndex()
        } catch {
            lastErrorMessage = "无法更新缺失原文件的归档状态：\(error.localizedDescription)"
        }
    }

    /// 仅供 ArchiveCoordinator 在取消并等待 worker 停止后调用，避免清理目录与写入预览竞态。
    func evictOfflinePreviews() throws {
        do {
            try archiveIndex?.evictAllPreviews()
            try ArchiveProcessor.clearPreviews(at: archivePreviewDirectory)
            reloadArchiveIndex()
        } catch {
            lastErrorMessage = "无法清理离线预览：\(error.localizedDescription)"
            throw error
        }
    }

    func restoreEvictedOfflinePreviews() -> [ArchiveProcessingRequest] {
        do {
            let restoredIDs = try archiveIndex?.restoreEvictedPreviews() ?? []
            reloadArchiveIndex()
            return archiveProcessingRequests(for: Set(restoredIDs))
        } catch {
            lastErrorMessage = "无法恢复离线预览：\(error.localizedDescription)"
            return []
        }
    }

    func archivePreviewCacheStatistics() -> (assetCount: Int, byteSize: Int64) {
        (try? archiveIndex?.previewCacheStatistics()) ?? (0, 0)
    }

    func renderRequest(for asset: PhotoAsset, lut: LUTRenderRecipe? = nil) -> ImageRenderRequest? {
        guard isOriginalAvailable(for: asset), let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
        return ImageRenderRequest(
            assetID: asset.id,
            bookmarkData: source.bookmarkData,
            lastKnownRootPath: source.lastKnownPath,
            relativePath: asset.relativePath,
            isRAW: asset.isRAW,
            recipe: recipe(for: asset),
            lut: lut
        )
    }

    func isOriginalAvailable(for asset: PhotoAsset) -> Bool {
        guard let source = sources.first(where: { $0.id == asset.sourceID }), source.status == .ready else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: source.lastKnownPath).appendingPathComponent(asset.relativePath).path)
    }

    func canEdit(_ asset: PhotoAsset) -> Bool {
        asset.supportsEditing && isOriginalAvailable(for: asset)
    }

    func chooseAndRelinkSource(for sourceID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "重新关联原始来源"
        panel.message = "选择此前添加的来源根文件夹。PhotoAI Mac 会重新扫描并复用已有本地记录。"
        panel.prompt = "重新关联"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in await self?.relinkSource(sourceID, to: url) }
    }

    func relinkSource(_ sourceID: UUID, to rootURL: URL) async {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        let standardizedURL = rootURL.standardizedFileURL
        do {
            sources[index].bookmarkData = try standardizedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            sources[index].lastKnownPath = standardizedURL.path
            sources[index].displayName = standardizedURL.lastPathComponent
            sources[index].status = .ready
            rebuildSourceLookup()
            persist()
            await rescan(sourceID)
        } catch {
            lastErrorMessage = "无法重新关联来源：\(error.localizedDescription)"
        }
    }

    func select(
        assetID: UUID,
        in orderedAssetIDs: [UUID],
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        guard orderedAssetIDs.contains(assetID) else { return }

        if modifiers.contains(.command) {
            if selectedAssetIDs.contains(assetID) {
                selectedAssetIDs.remove(assetID)
            } else {
                selectedAssetIDs.insert(assetID)
                selectionAnchorID = assetID
            }
            return
        }

        if modifiers.contains(.shift),
           let anchorID = selectionAnchorID,
           let anchorIndex = orderedAssetIDs.firstIndex(of: anchorID),
           let currentIndex = orderedAssetIDs.firstIndex(of: assetID) {
            let range = min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)
            selectedAssetIDs.formUnion(orderedAssetIDs[range])
            return
        }

        selectedAssetIDs = [assetID]
        selectionAnchorID = assetID
    }

    func selectAdjacent(offset: Int, in orderedAssetIDs: [UUID]) {
        guard !orderedAssetIDs.isEmpty else { return }
        let currentIndex = selectionAnchorID.flatMap { orderedAssetIDs.firstIndex(of: $0) } ?? (offset > 0 ? -1 : orderedAssetIDs.count)
        let nextIndex = min(max(currentIndex + offset, 0), orderedAssetIDs.count - 1)
        select(assetID: orderedAssetIDs[nextIndex], in: orderedAssetIDs, modifiers: [])
    }

    func clearSelection() {
        selectedAssetIDs = []
        selectionAnchorID = nil
    }

    func setRating(_ rating: Int) {
        updateSelectedAssets { asset in
            asset.rating = min(max(rating, 0), 5)
        }
    }

    func setFlag(_ flag: PhotoFlag) {
        updateSelectedAssets { asset in
            asset.flag = flag
        }
    }

    func toggleFavorite() {
        updateSelectedAssets { asset in
            asset.isFavorite.toggle()
        }
    }

    func recipe(for asset: PhotoAsset) -> EditRecipe {
        assets.first(where: { $0.id == asset.id })?.editRecipe ?? asset.editRecipe ?? .identity
    }

    func updateRecipe(for assetID: UUID, _ update: (inout EditRecipe) -> Void) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        var recipe = assets[index].editRecipe ?? .identity
        update(&recipe)
        if recipe.version < EditRecipe.currentVersion {
            recipe.version = EditRecipe.currentVersion
        }
        assets[index].editRecipe = recipe.isIdentity ? nil : recipe
        persist()
    }

    func resetRecipe(for assetID: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        assets[index].editRecipe = nil
        persist()
    }

    func setSearchQuery(_ query: String) {
        searchQuery = query
        searchInterpretation = SearchQueryInterpreter.fallbackInterpretation(for: query)
    }

    func interpretSearchWithFoundationModel() async {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchInterpretation = .empty
            return
        }
        isInterpretingSearch = true
        searchInterpretation = await SearchQueryInterpreter.interpret(searchQuery)
        isInterpretingSearch = false
    }

    func ocrRequestsForUnindexedAssets() -> [OCRIndexRequest] {
        assets.compactMap { asset in
            guard asset.mediaType == .image,
                  asset.ocrText == nil,
                  isOriginalAvailable(for: asset),
                  let source = sourceByID[asset.sourceID] else {
                return nil
            }
            return OCRIndexRequest(
                assetID: asset.id,
                bookmarkData: source.bookmarkData,
                lastKnownRootPath: source.lastKnownPath,
                relativePath: asset.relativePath
            )
        }
    }

    func faceAnalysisRequests() -> [FaceAnalysisRequest] {
        assets.compactMap { asset in
            guard asset.mediaType == .image,
                  isOriginalAvailable(for: asset),
                  let source = sourceByID[asset.sourceID] else {
                return nil
            }
            return FaceAnalysisRequest(
                assetID: asset.id,
                bookmarkData: source.bookmarkData,
                lastKnownRootPath: source.lastKnownPath,
                relativePath: asset.relativePath
            )
        }
    }

    func cleanupRequests() -> [CleanupAssetRequest] {
        assets.compactMap { asset in
            guard isOriginalAvailable(for: asset), let source = sourceByID[asset.sourceID] else { return nil }
            return CleanupAssetRequest(
                assetID: asset.id,
                bookmarkData: source.bookmarkData,
                lastKnownRootPath: source.lastKnownPath,
                relativePath: asset.relativePath,
                filename: asset.filename,
                fileExtension: asset.fileExtension,
                fileSize: asset.fileSize,
                captureDate: asset.captureDate,
                isRAW: asset.isRAW,
                hasEdits: !(asset.editRecipe ?? .identity).isIdentity
            )
        }
    }

    /// 只有文件已成功移入系统废纸篓后才移除本地 Catalog 记录；绝不直接删除原文件。
    func removeLocalRecords(assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else { return }
        do {
            let previewPaths = try archiveIndex?.removeArchiveRecords(assetIDs: assetIDs) ?? []
            for relativePath in previewPaths {
                let previewURL = archivePreviewDirectory.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: previewURL.path) {
                    do {
                        try FileManager.default.removeItem(at: previewURL)
                    } catch {
                        // SQLite 已在事务内移除引用；文件系统残留只会是无引用派生文件，
                        // 不能阻止已经成功移入废纸篓的 Catalog 记录完成清理。
                        lastErrorMessage = "归档记录已移除，但未能删除一项离线预览：\(error.localizedDescription)"
                    }
                }
            }
        } catch {
            // SQLite 事务未提交时 JSON Catalog 绝不移除资产，避免留下无法解释的双份状态。
            lastErrorMessage = "无法移除归档记录，已保留 Catalog 项目：\(error.localizedDescription)"
            return
        }
        assets.removeAll { assetIDs.contains($0.id) }
        selectedAssetIDs.subtract(assetIDs)
        if let selectionAnchorID, assetIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        for index in sources.indices {
            sources[index].assetCount = assets.filter { $0.sourceID == sources[index].id }.count
        }
        archiveMetadataByAssetID = archiveMetadataByAssetID.filter { !assetIDs.contains($0.key) }
        archiveLocations = archiveLocations.filter { !assetIDs.contains($0.assetID) }
        archiveRelationships = archiveRelationships.filter { !assetIDs.contains($0.firstAssetID) && !assetIDs.contains($0.secondAssetID) }
        rebuildCatalogLookups()
        rebuildArchiveLookups()
        archiveRevision &+= 1
        persist()
    }

    /// 智能选片只会在用户确认后调用此方法；它不会改动星级或 Reject 状态。
    func applyCullingPick(to assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else { return }
        for index in assets.indices where assetIDs.contains(assets[index].id) {
            assets[index].flag = .pick
        }
        persist()
    }

    func updateOCRText(_ text: String, for assetID: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        assets[index].ocrText = text
        persist()
    }

    func replaceRecipe(_ recipe: EditRecipe?, for assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else { return }
        let normalizedRecipe = recipe.map { recipe -> EditRecipe in
            var current = recipe
            if current.version < EditRecipe.currentVersion {
                current.version = EditRecipe.currentVersion
            }
            return current.isIdentity ? .identity : current
        }

        for index in assets.indices where assetIDs.contains(assets[index].id) {
            assets[index].editRecipe = normalizedRecipe?.isIdentity == true ? nil : normalizedRecipe
        }
        persist()
    }

    func fileURL(for asset: PhotoAsset) -> URL? {
        guard let source = sources.first(where: { $0.id == asset.sourceID }),
              source.status != .missing else {
            return nil
        }

        return URL(fileURLWithPath: source.lastKnownPath)
            .appendingPathComponent(asset.relativePath)
    }

    func rescan(_ sourceID: UUID) async {
        defer { scanTasks[sourceID] = nil }

        guard let sourceIndex = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        var source = sources[sourceIndex]
        source.status = .scanning
        sources[sourceIndex] = source
        rebuildSourceLookup()
        scanProgress[sourceID] = 0
        lastErrorMessage = nil

        do {
            let rootURL = try resolveURL(for: source)
            guard FileManager.default.fileExists(atPath: rootURL.path) else {
                setStatus(.missing, for: sourceID)
                return
            }

            let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess {
                    rootURL.stopAccessingSecurityScopedResource()
                }
            }

            let scannedAssets = try await withThrowingTaskGroup(of: [PhotoAsset].self) { group in
                group.addTask {
                    try CatalogScanner.scan(sourceID: sourceID, rootURL: rootURL)
                }
                guard let scannedAssets = try await group.next() else {
                    throw CatalogScanError.unreadableFolder
                }
                group.cancelAll()
                return scannedAssets
            }
            try Task.checkCancellation()
            let existingKeys = Set(assets.filter { $0.sourceID == sourceID }.map(\.identityKey))
            merge(scannedAssets, for: sourceID)

            guard let refreshedIndex = sources.firstIndex(where: { $0.id == sourceID }) else { return }
            sources[refreshedIndex].status = .ready
            sources[refreshedIndex].lastScannedAt = .now
            sources[refreshedIndex].assetCount = scannedAssets.count
            rebuildSourceLookup()
            scanProgress[sourceID] = nil
            // `assets` 是历史图库；本次扫描只更新仍实际存在的项目，缺失项目保留为离线历史。
            let scannedRelativePaths = Set(scannedAssets.map(\.relativePath))
            let mergedAssets = assets.filter { $0.sourceID == sourceID && scannedRelativePaths.contains($0.relativePath) }
            guard let archiveIndex else {
                throw CatalogStoreError.archiveUnavailable
            }
            do {
                lastArchiveImportSummary = try archiveIndex.recordScan(
                    source: sources[refreshedIndex],
                    assets: mergedAssets,
                    previouslyIndexedKeys: existingKeys
                )
            } catch {
                // 扫描得到的 JSON Catalog 仍然可用；但不能把归档扫描伪装成成功。
                lastArchiveImportSummary = ArchiveImportSummary(scannedCount: scannedAssets.count, failureCount: 1)
                lastErrorMessage = "文件夹已扫描，但无法更新本地归档索引：\(error.localizedDescription)"
                persist()
                return
            }
            latestArchiveScanAssetIDs = Set(mergedAssets.map(\.id))
            latestArchiveExactDuplicateIDs = []
            latestArchiveVisualDuplicateIDs = []
            reloadArchiveIndex()
            scheduleArchiveProcessing(for: Set(mergedAssets.map(\.id)))
            persist()
        } catch is CancellationError {
            setStatus(.ready, for: sourceID)
        } catch CatalogStoreError.sourceMissing {
            setStatus(.missing, for: sourceID)
        } catch {
            setStatus(.inaccessible, for: sourceID)
            lastErrorMessage = "无法扫描 \(source.displayName)：\(error.localizedDescription)"
        }
    }

    private func resolveURL(for source: PhotoSource) throws -> URL {
        var isStale = false
        do {
            let bookmarkedURL = try URL(
                resolvingBookmarkData: source.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // 安全书签在本机文件夹被移动/改名时可能仍解析到旧的可访问 URL。
            // 归档的当前可用性以记录的来源路径为准，重新关联会明确更新该路径。
            let recordedURL = URL(fileURLWithPath: source.lastKnownPath)
            if FileManager.default.fileExists(atPath: recordedURL.path) { return recordedURL }
            guard FileManager.default.fileExists(atPath: bookmarkedURL.path), bookmarkedURL.standardizedFileURL.path == recordedURL.standardizedFileURL.path else {
                throw CatalogStoreError.sourceMissing
            }
            return bookmarkedURL
        } catch {
            let fallbackURL = URL(fileURLWithPath: source.lastKnownPath)
            guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
                throw CatalogStoreError.sourceMissing
            }
            return fallbackURL
        }
    }

    private func merge(_ scannedAssets: [PhotoAsset], for sourceID: UUID) {
        let existingByKey = Dictionary(
            uniqueKeysWithValues: assets
                .filter { $0.sourceID == sourceID }
                .map { ($0.identityKey, $0) }
        )
        let merged = scannedAssets.map { asset -> PhotoAsset in
            guard let existing = existingByKey[asset.identityKey] else { return asset }
            var preserved = asset
            // Scanner 为新增项目分配 UUID；同一 source + relativePath 的既有项目必须保留稳定 ID，
            // 否则 People、OCR、选择状态等跨模块引用会在重扫后失效。
            preserved.id = existing.id
            preserved.rating = existing.rating
            preserved.flag = existing.flag
            preserved.isFavorite = existing.isFavorite
            preserved.editRecipe = existing.editRecipe
            preserved.ocrText = existing.ocrText
            return preserved
        }

        // 不能因一次扫描时文件缺席就抹掉历史记录。SQLite 中对应的 AssetLocation 会标为不可用，
        // 已完成的离线预览、哈希、评分、配方和人物关联仍可浏览。
        let historicalAssets = assets.filter { asset in
            asset.sourceID == sourceID && !scannedAssets.contains { $0.identityKey == asset.identityKey }
        }
        assets.removeAll { $0.sourceID == sourceID }
        assets.append(contentsOf: historicalAssets)
        assets.append(contentsOf: merged)
        assets.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        selectedAssetIDs.formIntersection(Set(assets.map(\.id)))
        rebuildCatalogLookups()
    }

    private func setStatus(_ status: PhotoSourceStatus, for sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].status = status
        rebuildSourceLookup()
        if status == .missing || status == .inaccessible {
            do {
                try archiveIndex?.recordUnavailableSource(sourceID)
            } catch {
                lastErrorMessage = "无法更新离线来源的归档状态：\(error.localizedDescription)"
            }
            reloadArchiveIndex()
        }
        scanProgress[sourceID] = nil
        persist()
    }

    private func persist() {
        do {
            try persistence.save(CatalogSnapshot(sources: sources, assets: assets))
        } catch {
            lastErrorMessage = "无法保存本地 Catalog：\(error.localizedDescription)"
        }
    }

    private func reloadArchiveIndex() {
        guard let archiveIndex else { return }
        do {
            let loaded = try archiveIndex.load(assetIDs: assets.map(\.id))
            archiveMetadataByAssetID = loaded.metadata
            archiveLocations = loaded.locations
            archiveRelationships = loaded.relationships.sorted { $0.discoveredAt > $1.discoveredAt }
            rebuildArchiveLookups()
            archiveRevision &+= 1
        } catch {
            lastErrorMessage = "无法读取本地归档索引：\(error.localizedDescription)"
        }
    }

    private func scheduleArchiveProcessing(for assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else { return }
        let candidates = Set(archiveProcessingRequests(for: assetIDs).map { $0.asset.id })
        guard !candidates.isEmpty else { return }
        scheduledArchiveAssetIDs.formUnion(candidates)
        archiveEnqueueRevision &+= 1
    }

    private func rebuildArchiveLookups() {
        archiveLocationsByAssetID = Dictionary(grouping: archiveLocations, by: \.assetID)
        archiveOriginalLocationByAssetID = archiveLocationsByAssetID.reduce(into: [:]) { partial, item in
            partial[item.key] = item.value.max { $0.lastSeenAt < $1.lastSeenAt }
        }
        rebuildRelationshipLookups()
        archiveAvailabilityByAssetID = [:]
        archiveAvailableCopyLocationByAssetID = [:]
        updateArchiveAvailability(for: Set(assets.map(\.id)))
    }

    private func rebuildCatalogLookups() {
        rebuildSourceLookup()
        assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    }

    private func rebuildSourceLookup() {
        sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }

    private func rebuildRelationshipLookups() {
        var exactDuplicates: [UUID: Set<UUID>] = [:]
        for relationship in archiveRelationships where relationship.kind == .exactDuplicate {
            exactDuplicates[relationship.firstAssetID, default: []].insert(relationship.secondAssetID)
            exactDuplicates[relationship.secondAssetID, default: []].insert(relationship.firstAssetID)
        }
        archiveExactDuplicateAssetIDsByAssetID = exactDuplicates
    }

    private func updateArchiveAvailability(for assetIDs: Set<UUID>) {
        for assetID in assetIDs {
            let ownLocations = archiveLocationsByAssetID[assetID] ?? []
            let duplicateIDs = archiveExactDuplicateAssetIDsByAssetID[assetID] ?? []
            let isOnline: (AssetLocation) -> Bool = { location in
                location.isAvailable && self.sourceByID[location.sourceID]?.status == .ready
            }
            let onlineOwn = ownLocations.contains(where: isOnline)
            let availableCopy = duplicateIDs
                .flatMap { archiveLocationsByAssetID[$0] ?? [] }
                .filter(isOnline)
                .max { $0.lastSeenAt < $1.lastSeenAt }
            archiveAvailableCopyLocationByAssetID[assetID] = availableCopy
            if (onlineOwn || availableCopy != nil), !duplicateIDs.isEmpty {
                archiveAvailabilityByAssetID[assetID] = .multipleCopies
            } else if onlineOwn {
                archiveAvailabilityByAssetID[assetID] = .online
            } else if ownLocations.isEmpty {
                archiveAvailabilityByAssetID[assetID] = .missing
            } else if ownLocations.contains(where: { sourceByID[$0.sourceID]?.status == .ready }) {
                archiveAvailabilityByAssetID[assetID] = .missing
            } else {
                archiveAvailabilityByAssetID[assetID] = .offline
            }
        }
    }

    private func updateSelectedAssets(_ update: (inout PhotoAsset) -> Void) {
        guard !selectedAssetIDs.isEmpty else { return }
        for index in assets.indices where selectedAssetIDs.contains(assets[index].id) {
            update(&assets[index])
        }
        persist()
    }
}

private enum CatalogStoreError: Error {
    case sourceMissing
    case archiveUnavailable
}
