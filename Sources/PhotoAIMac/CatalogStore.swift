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
        archiveIndex = try? ArchiveIndexPersistence(databaseURL: databaseURL)

        do {
            let snapshot = try persistence.load()
            sources = snapshot.sources
            assets = snapshot.assets
        } catch {
            sources = []
            assets = []
            lastErrorMessage = "无法读取本地 Catalog：\(error.localizedDescription)"
        }
        let offlineSourceIDs = sources.indices.compactMap { index -> UUID? in
            guard sources[index].status == .ready,
                  !FileManager.default.fileExists(atPath: sources[index].lastKnownPath) else {
                return nil
            }
            sources[index].status = .missing
            return sources[index].id
        }
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
        guard let url = ArchiveProcessor.previewURL(for: asset.archiveMetadata, previewDirectory: archivePreviewDirectory),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func archiveAvailability(for asset: PhotoAsset) -> AssetArchiveAvailability {
        asset.archiveAvailability(sources: sources, locations: archiveLocations, duplicates: archiveRelationships)
    }

    func archiveOriginalLocation(for asset: PhotoAsset) -> AssetLocation? {
        archiveLocations
            .filter { $0.assetID == asset.id }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first
    }

    func archiveAvailableCopyLocation(for asset: PhotoAsset) -> AssetLocation? {
        let duplicateAssetIDs = Set(archiveRelationships.compactMap { relationship -> UUID? in
            guard relationship.kind == .exactDuplicate else { return nil }
            if relationship.firstAssetID == asset.id { return relationship.secondAssetID }
            if relationship.secondAssetID == asset.id { return relationship.firstAssetID }
            return nil
        })
        return archiveLocations
            .filter { location in
                duplicateAssetIDs.contains(location.assetID) && location.isAvailable &&
                    sources.first(where: { $0.id == location.sourceID })?.status == .ready
            }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first
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

    func archiveProcessingRequests() -> [ArchiveProcessingRequest] {
        assets.compactMap { asset in
            guard let source = sources.first(where: { $0.id == asset.sourceID }), source.status == .ready,
                  asset.archiveMetadata.needsHash(for: asset) || asset.archiveMetadata.needsPreview(for: asset),
                  FileManager.default.fileExists(atPath: URL(fileURLWithPath: source.lastKnownPath).appendingPathComponent(asset.relativePath).path) else {
                return nil
            }
            return ArchiveProcessingRequest(asset: asset, bookmarkData: source.bookmarkData, rootPath: source.lastKnownPath, existingMetadata: asset.archiveMetadata)
        }
    }

    func applyArchiveProcessingResult(_ result: ArchiveProcessingResult, relationships: [ArchiveDuplicateRelationship]) {
        guard let index = assets.firstIndex(where: { $0.id == result.assetID }) else { return }
        assets[index].archive = result.metadata
        var byKey = Dictionary(uniqueKeysWithValues: archiveRelationships.map { ($0.key, $0) })
        for relationship in relationships { byKey[relationship.key] = relationship }
        archiveRelationships = byKey.values.sorted { $0.discoveredAt > $1.discoveredAt }
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
        try? archiveIndex?.recordUnavailableSource(sourceID)
        reloadArchiveIndex()
        persist()
    }

    func clearOfflinePreviews() {
        do {
            try ArchiveProcessor.clearPreviews(at: archivePreviewDirectory)
            try archiveIndex?.removeAllPreviewMetadata()
            for index in assets.indices {
                assets[index].archive?.preview = nil
                assets[index].archive?.previewState = .pending
            }
        } catch {
            lastErrorMessage = "无法清理离线预览：\(error.localizedDescription)"
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
                  let source = sources.first(where: { $0.id == asset.sourceID }) else {
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
                  let source = sources.first(where: { $0.id == asset.sourceID }) else {
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
            guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
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
        assets.removeAll { assetIDs.contains($0.id) }
        selectedAssetIDs.subtract(assetIDs)
        if let selectionAnchorID, assetIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        for index in sources.indices {
            sources[index].assetCount = assets.filter { $0.sourceID == sources[index].id }.count
        }
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
            scanProgress[sourceID] = nil
            // `assets` 是历史图库；本次扫描只更新仍实际存在的项目，缺失项目保留为离线历史。
            let scannedRelativePaths = Set(scannedAssets.map(\.relativePath))
            let mergedAssets = assets.filter { $0.sourceID == sourceID && scannedRelativePaths.contains($0.relativePath) }
            lastArchiveImportSummary = (try? archiveIndex?.recordScan(
                source: sources[refreshedIndex],
                assets: mergedAssets,
                previouslyIndexedKeys: existingKeys
            )) ?? ArchiveImportSummary(scannedCount: scannedAssets.count)
            latestArchiveScanAssetIDs = Set(mergedAssets.map(\.id))
            latestArchiveExactDuplicateIDs = []
            latestArchiveVisualDuplicateIDs = []
            reloadArchiveIndex()
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
            let metadataChanged = existing.fileSize != asset.fileSize || existing.modifiedAt != asset.modifiedAt
            preserved.archive = metadataChanged ? existing.archiveMetadata.invalidatedForChangedSource() : existing.archive
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
    }

    private func setStatus(_ status: PhotoSourceStatus, for sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].status = status
        if status == .missing || status == .inaccessible {
            try? archiveIndex?.recordUnavailableSource(sourceID)
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
        guard let loaded = try? archiveIndex.load(assetIDs: assets.map(\.id)) else { return }
        for index in assets.indices {
            assets[index].archive = loaded.metadata[assets[index].id] ?? assets[index].archive
        }
        archiveLocations = loaded.locations
        archiveRelationships = loaded.relationships
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
}
