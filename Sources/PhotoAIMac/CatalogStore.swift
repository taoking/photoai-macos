import AppKit
import Foundation

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var sources: [PhotoSource]
    @Published private(set) var assets: [PhotoAsset]
    @Published private(set) var scanProgress: [UUID: Int] = [:]
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var selectedAssetIDs = Set<UUID>()
    @Published var filter: LibraryFilter = .all {
        didSet { invalidateQueryCache() }
    }
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchInterpretation = SearchInterpretation.empty
    @Published private(set) var isInterpretingSearch = false
    @Published private(set) var metadataUndoActionTitle: String?

    private var selectionAnchorID: UUID?
    private var queryCache: [CatalogQueryKey: [PhotoAsset]] = [:]
    private var duplicateAssetIDsCache: Set<UUID>?
    private var assetIndexByID: [UUID: Int] = [:]
    private var metadataUndoStack: [CatalogMetadataUndoOperation] = []
    private(set) var queryComputationCount = 0

    private let persistence: CatalogPersistence
    private var scanTasks: [UUID: Task<Void, Never>] = [:]

    init(storageURL: URL = CatalogPersistence.defaultFileURL) {
        persistence = CatalogPersistence(fileURL: storageURL)

        do {
            let snapshot = try persistence.load()
            sources = snapshot.sources
            assets = snapshot.assets
            rebuildAssetIndex()
        } catch {
            sources = []
            assets = []
            lastErrorMessage = "无法读取本地 Catalog：\(error.localizedDescription)"
        }
    }

    init(snapshot: CatalogSnapshot, storageURL: URL) {
        persistence = CatalogPersistence(fileURL: storageURL)
        sources = snapshot.sources
        assets = snapshot.assets
        rebuildAssetIndex()
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

    func assets(for destination: SidebarDestination, filter requestedFilter: LibraryFilter? = nil) -> [PhotoAsset] {
        let selectedFilter = requestedFilter ?? filter
        let cacheKey = CatalogQueryKey(destination: destination, filter: selectedFilter)
        if let cachedAssets = queryCache[cacheKey] {
            return cachedAssets
        }

        let destinationAssets: [PhotoAsset]
        switch destination {
        case .allPhotos, .recentImports, .folders, .albums, .people, .cleanup:
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

        let duplicateAssetIDs = selectedFilter == .duplicates ? duplicateAssetIDs() : []
        let filtered = destinationAssets.filter { selectedFilter.matches($0, duplicateAssetIDs: duplicateAssetIDs) }
        let result: [PhotoAsset]
        if destination == .recentImports {
            result = filtered.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        } else {
            result = filtered
        }
        queryComputationCount += 1
        queryCache[cacheKey] = result
        return result
    }

    var selectedAsset: PhotoAsset? {
        guard selectedAssetIDs.count == 1, let id = selectedAssetIDs.first else { return nil }
        return asset(withID: id)
    }

    var selectedAssets: [PhotoAsset] {
        selectedAssetIDs.compactMap(asset(withID:)).sorted { left, right in
            (assetIndexByID[left.id] ?? .max) < (assetIndexByID[right.id] ?? .max)
        }
    }

    func selectedAssets(orderedBy orderedAssetIDs: [UUID]) -> [PhotoAsset] {
        return orderedAssetIDs.compactMap { id in
            guard selectedAssetIDs.contains(id) else { return nil }
            return asset(withID: id)
        }
    }

    func asset(withID assetID: UUID) -> PhotoAsset? {
        guard let index = assetIndexByID[assetID], assets.indices.contains(index) else { return nil }
        return assets[index]
    }

    func assets(withIDs orderedAssetIDs: [UUID]) -> [PhotoAsset] {
        orderedAssetIDs.compactMap(asset(withID:))
    }

    var selectionAnchorAsset: PhotoAsset? {
        guard let selectionAnchorID else { return nil }
        return asset(withID: selectionAnchorID)
    }

    func thumbnailRequest(for asset: PhotoAsset) -> ThumbnailRequest? {
        guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
        return ThumbnailRequest(
            assetID: asset.id,
            bookmarkData: source.bookmarkData,
            lastKnownRootPath: source.lastKnownPath,
            relativePath: asset.relativePath,
            modificationDate: asset.modifiedAt,
            mediaType: asset.mediaType
        )
    }

    func renderRequest(for asset: PhotoAsset, lut: LUTRenderRecipe? = nil) -> ImageRenderRequest? {
        guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
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

    func previewRequest(for asset: PhotoAsset) -> PhotoPreviewRequest? {
        guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
        return PhotoPreviewRequest(
            assetID: asset.id,
            bookmarkData: source.bookmarkData,
            lastKnownRootPath: source.lastKnownPath,
            relativePath: asset.relativePath,
            modificationDate: asset.modifiedAt,
            mediaType: asset.mediaType
        )
    }

    func originalExportRequest(for asset: PhotoAsset) -> OriginalPhotoExportRequest? {
        guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
        return OriginalPhotoExportRequest(
            assetID: asset.id,
            bookmarkData: source.bookmarkData,
            lastKnownRootPath: source.lastKnownPath,
            relativePath: asset.relativePath,
            filename: asset.filename
        )
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

    func selectSingle(assetID: UUID) {
        guard assetIndexByID[assetID] != nil else { return }
        selectedAssetIDs = [assetID]
        selectionAnchorID = assetID
    }

    func clearSelection() {
        selectedAssetIDs = []
        selectionAnchorID = nil
    }

    func selectAll(in orderedAssetIDs: [UUID]) {
        selectedAssetIDs = Set(orderedAssetIDs)
        selectionAnchorID = orderedAssetIDs.first
    }

    @discardableResult
    func setRating(_ rating: Int) -> Set<UUID> {
        setRating(rating, for: selectedAssetIDs)
    }

    @discardableResult
    func setRating(_ rating: Int, for assetIDs: Set<UUID>) -> Set<UUID> {
        performMetadataOperation(title: "评分", assetIDs: assetIDs) { asset in
            asset.rating = min(max(rating, 0), 5)
        }
    }

    @discardableResult
    func setFlag(_ flag: PhotoFlag) -> Set<UUID> {
        setFlag(flag, for: selectedAssetIDs)
    }

    @discardableResult
    func setFlag(_ flag: PhotoFlag, for assetIDs: Set<UUID>) -> Set<UUID> {
        performMetadataOperation(title: "标记", assetIDs: assetIDs) { asset in
            asset.flag = flag
        }
    }

    @discardableResult
    func applyCompareDecision(winnerID: UUID, loserID: UUID) -> Set<UUID> {
        guard winnerID != loserID else { return [] }
        return performMetadataOperation(title: "A/B 比较选择", assetIDs: [winnerID, loserID]) { asset in
            asset.flag = asset.id == winnerID ? .pick : .reject
        }
    }

    var canUndoMetadataOperation: Bool { !metadataUndoStack.isEmpty }

    @discardableResult
    func undoLastMetadataOperation() -> Set<UUID> {
        guard let operation = metadataUndoStack.popLast() else { return [] }
        var restoredIDs = Set<UUID>()
        for snapshot in operation.snapshots {
            guard let index = assetIndexByID[snapshot.assetID], assets.indices.contains(index) else { continue }
            assets[index].rating = snapshot.rating
            assets[index].flag = snapshot.flag
            restoredIDs.insert(snapshot.assetID)
        }
        metadataUndoActionTitle = metadataUndoStack.last?.title
        if !restoredIDs.isEmpty { persist() }
        return restoredIDs
    }

    func setColorLabel(_ colorLabel: String, for assetIDs: Set<UUID>) {
        updateAssets(assetIDs) { asset in
            asset.colorLabel = colorLabel
        }
    }

    func setComment(_ comment: String, for assetIDs: Set<UUID>) {
        updateAssets(assetIDs) { asset in
            asset.comment = comment
        }
    }

    func toggleFavorite() {
        updateAssets(selectedAssetIDs) { asset in
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
        invalidateQueryCache()
    }

    func interpretSearchWithFoundationModel() async {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchInterpretation = .empty
            return
        }
        isInterpretingSearch = true
        searchInterpretation = await SearchQueryInterpreter.interpret(searchQuery)
        isInterpretingSearch = false
        invalidateQueryCache()
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
        rebuildAssetIndex()
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
        setFlag(.pick, for: assetIDs)
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
            merge(scannedAssets, for: sourceID)

            guard let refreshedIndex = sources.firstIndex(where: { $0.id == sourceID }) else { return }
            sources[refreshedIndex].status = .ready
            sources[refreshedIndex].lastScannedAt = .now
            sources[refreshedIndex].assetCount = scannedAssets.count
            scanProgress[sourceID] = nil
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
            return try URL(
                resolvingBookmarkData: source.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
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
            preserved.colorLabel = existing.colorLabel
            preserved.comment = existing.comment
            preserved.isFavorite = existing.isFavorite
            preserved.editRecipe = existing.editRecipe
            preserved.ocrText = existing.ocrText
            return preserved
        }

        assets.removeAll { $0.sourceID == sourceID }
        assets.append(contentsOf: merged)
        assets.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        rebuildAssetIndex()
        selectedAssetIDs.formIntersection(Set(assets.map(\.id)))
    }

    private func setStatus(_ status: PhotoSourceStatus, for sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].status = status
        scanProgress[sourceID] = nil
        persist()
    }

    private func persist() {
        invalidateQueryCache()
        do {
            try persistence.save(CatalogSnapshot(sources: sources, assets: assets))
        } catch {
            lastErrorMessage = "无法保存本地 Catalog：\(error.localizedDescription)"
        }
    }

    private func updateAssets(_ assetIDs: Set<UUID>, _ update: (inout PhotoAsset) -> Void) {
        guard !assetIDs.isEmpty else { return }
        for assetID in assetIDs {
            guard let index = assetIndexByID[assetID], assets.indices.contains(index) else { continue }
            update(&assets[index])
        }
        persist()
    }

    private func performMetadataOperation(
        title: String,
        assetIDs: Set<UUID>,
        update: (inout PhotoAsset) -> Void
    ) -> Set<UUID> {
        guard !assetIDs.isEmpty else { return [] }
        var snapshots: [CatalogMetadataSnapshot] = []
        var changedIDs = Set<UUID>()

        for assetID in assetIDs {
            guard let index = assetIndexByID[assetID], assets.indices.contains(index) else { continue }
            let original = assets[index]
            var updated = original
            update(&updated)
            guard original.rating != updated.rating || original.flag != updated.flag else { continue }
            snapshots.append(
                CatalogMetadataSnapshot(assetID: assetID, rating: original.rating, flag: original.flag)
            )
            assets[index].rating = updated.rating
            assets[index].flag = updated.flag
            changedIDs.insert(assetID)
        }

        guard !snapshots.isEmpty else { return [] }
        metadataUndoStack.append(CatalogMetadataUndoOperation(title: title, snapshots: snapshots))
        if metadataUndoStack.count > 100 {
            metadataUndoStack.removeFirst(metadataUndoStack.count - 100)
        }
        metadataUndoActionTitle = title
        persist()
        return changedIDs
    }

    private func rebuildAssetIndex() {
        assetIndexByID = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func invalidateQueryCache() {
        queryCache.removeAll(keepingCapacity: true)
        duplicateAssetIDsCache = nil
    }

    private func duplicateAssetIDs() -> Set<UUID> {
        if let duplicateAssetIDsCache { return duplicateAssetIDsCache }
        let candidates = assets.filter { $0.mediaType == .image && $0.fileSize > 0 }
        let groups = Dictionary(grouping: candidates) { asset in
            DuplicateIndexKey(
                fileSize: asset.fileSize,
                width: asset.width,
                height: asset.height,
                fileExtension: asset.fileExtension.lowercased()
            )
        }
        let duplicateIDs = Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        duplicateAssetIDsCache = duplicateIDs
        return duplicateIDs
    }
}

private struct CatalogQueryKey: Hashable {
    let destination: SidebarDestination
    let filter: LibraryFilter
}

private struct DuplicateIndexKey: Hashable {
    let fileSize: Int64
    let width: Int?
    let height: Int?
    let fileExtension: String
}

private struct CatalogMetadataSnapshot: Sendable {
    let assetID: UUID
    let rating: Int
    let flag: PhotoFlag
}

private struct CatalogMetadataUndoOperation: Sendable {
    let title: String
    let snapshots: [CatalogMetadataSnapshot]
}

private enum CatalogStoreError: Error {
    case sourceMissing
}
