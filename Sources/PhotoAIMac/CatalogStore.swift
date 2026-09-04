import AppKit
import Foundation

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var sources: [PhotoSource]
    @Published private(set) var assets: [PhotoAsset]
    @Published private(set) var scanProgress: [UUID: CatalogScanProgress] = [:]
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
    private let writer: CatalogWriter
    /// 派生图磁盘层。移除来源时要连同它的缓存目录一起清掉。
    let derivedImageCache: DerivedImageCache
    /// 一个来源扫描完成后触发，用于把整卷排进派生图预热。
    /// 由 App 在启动时接线，Store 本身不认识预热的实现。
    var onSourceScanCompleted: ((UUID, [DerivedImageRequest]) -> Void)?
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    /// 待写入的最新快照。写入进行中时只替换它，不排队重复写整份 Catalog。
    private var pendingSnapshot: CatalogSnapshot?
    private var persistTask: Task<Void, Never>?

    init(
        storageURL: URL = CatalogPersistence.defaultFileURL,
        derivedImageCache: DerivedImageCache = DerivedImageCache()
    ) {
        persistence = CatalogPersistence(fileURL: storageURL)
        writer = CatalogWriter(persistence: persistence)
        self.derivedImageCache = derivedImageCache

        do {
            let snapshot = try persistence.load()
            sources = snapshot.sources
            // 必须在这里重新排序，不能沿用快照里的数组顺序。
            // 顺序规则会随版本变化，而磁盘上的快照是用写它时的旧规则排好的；
            // 若直接采用，新规则要等到下一次重扫才生效——这正是"改成倒序后
            // 重启仍看到升序"的原因。
            assets = snapshot.assets.sorted(by: PhotoAsset.isOrderedBefore)
            rebuildAssetIndex()
        } catch {
            sources = []
            assets = []
            lastErrorMessage = "无法读取本地 Catalog：\(error.localizedDescription)"
        }
    }

    init(
        snapshot: CatalogSnapshot,
        storageURL: URL,
        derivedImageCache: DerivedImageCache = DerivedImageCache()
    ) {
        persistence = CatalogPersistence(fileURL: storageURL)
        writer = CatalogWriter(persistence: persistence)
        self.derivedImageCache = derivedImageCache
        sources = snapshot.sources
        assets = snapshot.assets.sorted(by: PhotoAsset.isOrderedBefore)
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

    /// 为一个来源重新选择文件夹。
    ///
    /// 外置盘换盘符、素材整体搬家之后，来源会停在 `missing`，其下的资产既没有缩略图
    /// 也打不开预览，而界面此前没有任何恢复入口。这里保留 `sourceID` 与 `relativePath`，
    /// 因此重扫后资产 ID 稳定，评分、标记、调整配方与人脸关联都不会丢。
    func chooseAndRelocateFolder(for sourceID: UUID) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位「\(source.displayName)」"
        panel.message = "选择该来源现在所在的文件夹。原始文件不会被修改，评分与标记会保留。"
        panel.prompt = "重新定位"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startRelocating(sourceID, to: url)
    }

    func startRelocating(_ sourceID: UUID, to newRootURL: URL) {
        Task { [weak self] in
            await self?.relocate(sourceID, to: newRootURL)
        }
    }

    func relocate(_ sourceID: UUID, to newRootURL: URL) async {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        let standardizedURL = newRootURL.standardizedFileURL

        if let conflicting = sources.first(where: { $0.id != sourceID && $0.lastKnownPath == standardizedURL.path }) {
            lastErrorMessage = "该文件夹已作为来源「\(conflicting.displayName)」存在。"
            return
        }

        do {
            let bookmarkData = try standardizedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            sources[index].bookmarkData = bookmarkData
            sources[index].lastKnownPath = standardizedURL.path
            sources[index].displayName = standardizedURL.lastPathComponent
            sources[index].status = .ready
            lastErrorMessage = nil
            persist()
            await rescan(sourceID)
        } catch {
            lastErrorMessage = "无法保存文件夹访问权限：\(error.localizedDescription)"
        }
    }

    /// 移除一个来源及其全部 Catalog 记录。
    ///
    /// 只删除本地索引，绝不触碰原始文件。评分、标记与调整配方会随记录一起消失，
    /// 且无法通过重新添加同一文件夹找回（资产会拿到新的 ID），因此调用方必须
    /// 先向用户明确确认。
    func removeSource(_ sourceID: UUID) {
        guard sources.contains(where: { $0.id == sourceID }) else { return }
        scanTasks[sourceID]?.cancel()
        scanTasks[sourceID] = nil
        scanProgress[sourceID] = nil

        let removedAssetIDs = Set(assets.lazy.filter { $0.sourceID == sourceID }.map(\.id))
        sources.removeAll { $0.id == sourceID }
        assets.removeAll { $0.sourceID == sourceID }
        selectedAssetIDs.subtract(removedAssetIDs)
        if let anchorID = selectionAnchorID, removedAssetIDs.contains(anchorID) {
            selectionAnchorID = nil
        }
        rebuildAssetIndex()
        persist()

        // 派生图随索引一起消失：用户已在确认框里同意，留着也再没有东西引用它们。
        let cache = derivedImageCache
        Task.detached(priority: .utility) {
            cache.removeAll(for: sourceID)
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

    /// 该资产所属来源当前是否可读。
    ///
    /// 来源失效时它名下的资产仍然留在图库里（评分、标记都还在），但既没有缩略图
    /// 也打不开预览。界面需要把这种"文件夹不在了"与"这张图解码失败"区分开，
    /// 否则用户只会看到一片无法解释的破图标。
    func isSourceReachable(for asset: PhotoAsset) -> Bool {
        guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return false }
        return source.status != .missing && source.status != .inaccessible
    }

    var unreachableSources: [PhotoSource] {
        sources.filter { $0.status == .missing || $0.status == .inaccessible }
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

    /// 外置盘重新接上时把受影响的来源恢复回来。
    ///
    /// 此前来源会一直停在 `missing`，要用户自己想起来点"重新扫描"。资产身份由
    /// `sourceID + relativePath` 决定，路径没变时重扫即可原样对上，评分与标记都在。
    /// 只处理路径确实又出现了的来源；换了盘符的仍然走"重新定位"。
    func recoverSourcesAvailableAgain() {
        let candidates = sources.filter { source in
            (source.status == .missing || source.status == .inaccessible)
                && FileManager.default.fileExists(atPath: source.lastKnownPath)
        }
        for source in candidates {
            startRescan(source.id)
        }
    }

    /// 外置盘拔出时把受影响的来源标记为离线。
    ///
    /// 与 `recoverSourcesAvailableAgain` 成对。只监听挂载而不监听卸载会让来源一直
    /// 停在 `ready`：文件夹页谎报"可用"、"离线"角标不出现，未缓存的照片还会继续
    /// 发起注定失败的实时解码。这里只改状态，不动任何资产记录——离线浏览正是靠
    /// 那些记录和已生成的派生图撑着。
    func markUnavailableSourcesMissing() {
        for source in sources where source.status == .ready {
            guard !FileManager.default.fileExists(atPath: source.lastKnownPath) else { continue }
            guard let index = sources.firstIndex(where: { $0.id == source.id }) else { continue }
            scanTasks[source.id]?.cancel()
            scanTasks[source.id] = nil
            scanProgress[source.id] = nil
            sources[index].status = .missing
            persist()
        }
    }

    /// 一个来源下全部资产的派生图请求，供整卷预热使用。
    func derivedImageRequests(for sourceID: UUID) -> [DerivedImageRequest] {
        assets.lazy.filter { $0.sourceID == sourceID }.compactMap(derivedImageRequest(for:))
    }

    /// 缩略图与离线预览共用同一个请求：它们读的是同一个文件、走同一次解码。
    func derivedImageRequest(for asset: PhotoAsset) -> DerivedImageRequest? {
        guard let source = sources.first(where: { $0.id == asset.sourceID }) else { return nil }
        return DerivedImageRequest(
            sourceID: source.id,
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
        scanProgress[sourceID] = CatalogScanProgress(scanned: 0, total: 0)
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

            // 上一次的索引结果按 relativePath 交给扫描器：大小与修改时间都没变的文件
            // 直接复用，跳过整次 EXIF 读取。重扫因此接近零成本。
            let previouslyIndexed = Dictionary(
                assets.lazy.filter { $0.sourceID == sourceID }.map { ($0.relativePath, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // 首次导入时本来就没有可显示的内容，边扫边追加能让照片立刻出现；
            // 重扫已有来源则等最终 merge，避免与既有条目重复。
            let isInitialImport = previouslyIndexed.isEmpty

            let scannedAssets = try await CatalogScanner.scanConcurrently(
                sourceID: sourceID,
                rootURL: rootURL,
                reusableAssets: previouslyIndexed
            ) { [weak self] batch in
                await self?.applyScanBatch(batch, for: sourceID, isInitialImport: isInitialImport)
            }
            try Task.checkCancellation()
            merge(scannedAssets, for: sourceID)

            guard let refreshedIndex = sources.firstIndex(where: { $0.id == sourceID }) else { return }
            sources[refreshedIndex].status = .ready
            sources[refreshedIndex].lastScannedAt = .now
            sources[refreshedIndex].assetCount = scannedAssets.count
            scanProgress[sourceID] = nil
            persist()
            onSourceScanCompleted?(sourceID, derivedImageRequests(for: sourceID))
        } catch is CancellationError {
            setStatus(.ready, for: sourceID)
        } catch CatalogStoreError.sourceMissing {
            setStatus(.missing, for: sourceID)
        } catch {
            setStatus(.inaccessible, for: sourceID)
            lastErrorMessage = "无法扫描 \(source.displayName)：\(error.localizedDescription)"
        }
    }

    /// 扫描进行中的一批结果：更新进度，并在首次导入时立即让照片出现在图库里。
    ///
    /// 批次按任务完成顺序到达，因此导入过程中的排列顺序不是最终顺序；
    /// 扫描结束时的 `merge` 会做统一排序。
    private func applyScanBatch(
        _ batch: CatalogScanner.ScanBatch,
        for sourceID: UUID,
        isInitialImport: Bool
    ) {
        scanProgress[sourceID] = CatalogScanProgress(scanned: batch.scanned, total: batch.total)
        guard isInitialImport, !batch.assets.isEmpty else { return }
        assets.append(contentsOf: batch.assets)
        rebuildAssetIndex()
        invalidateQueryCache()
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
        assets.sort(by: PhotoAsset.isOrderedBefore)
        rebuildAssetIndex()
        selectedAssetIDs.formIntersection(Set(assets.map(\.id)))
    }

    private func setStatus(_ status: PhotoSourceStatus, for sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].status = status
        scanProgress[sourceID] = nil
        persist()
    }

    /// 记录一次待写入的快照。
    ///
    /// 编码与写盘都交给 `CatalogWriter`，主线程只做一次 O(1) 的数组引用拷贝。
    /// 写入进行中时后续的改动只替换 `pendingSnapshot`：连续按星级不会排出一串
    /// 各写一遍整份 Catalog 的任务，最终落盘的始终是最新状态。
    private func persist() {
        invalidateQueryCache()
        pendingSnapshot = CatalogSnapshot(sources: sources, assets: assets)
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            await self?.drainPendingSnapshots()
        }
    }

    private func drainPendingSnapshots() async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            do {
                try await writer.write(snapshot)
            } catch {
                lastErrorMessage = "无法保存本地 Catalog：\(error.localizedDescription)"
            }
        }
        persistTask = nil
    }

    /// 实际落盘次数。供测试断言连续改动被合并成一次写入。
    var persistWriteCount: Int {
        get async { await writer.writeCount }
    }

    /// 等待所有待写入的快照真正落盘。写入既然是异步的，
    /// 任何"改完立刻从磁盘读回"的调用方（测试、退出流程）都必须先经过这里。
    func flushPendingPersist() async {
        while let task = persistTask {
            await task.value
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

/// 扫描进度。此前 `scanProgress` 只在开始时被设为 0、结束时清空，且界面从未读取它，
/// 用户在长达 20–30 分钟的扫描里看不到任何数字变化。
struct CatalogScanProgress: Equatable, Sendable {
    let scanned: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(scanned) / Double(total))
    }

    var description: String {
        guard total > 0 else { return "正在枚举文件…" }
        return "\(scanned) / \(total)"
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
