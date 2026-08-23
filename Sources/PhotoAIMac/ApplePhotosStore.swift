import AppKit
import Foundation
@preconcurrency import Photos
import UniformTypeIdentifiers

enum ApplePhotosAuthorization: Equatable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
    case unavailable

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unavailable
        }
    }

    var title: String {
        switch self {
        case .notDetermined: "尚未授权访问 Apple Photos"
        case .authorized: "已获 Apple Photos 完整访问权限"
        case .limited: "已获 Apple Photos 有限访问权限"
        case .denied: "Apple Photos 访问被拒绝"
        case .restricted: "Apple Photos 访问受系统限制"
        case .unavailable: "无法确定 Apple Photos 访问状态"
        }
    }

    var canRead: Bool { self == .authorized || self == .limited }

    var nextStep: String {
        switch self {
        case .notDetermined: "点击“授权并读取 Apple Photos”后才会显示系统授权请求。"
        case .authorized, .limited: "可选择筛选、相簿、预览或导入已选原始资源。"
        case .denied: "请在系统设置中允许 PhotoAI Mac 访问照片后，再点击读取。"
        case .restricted: "此 Mac 的照片访问受到系统限制。"
        case .unavailable: "请稍后刷新系统照片权限状态。"
        }
    }
}

enum ApplePhotosLoadState: Equatable {
    case idle
    case requestingAuthorization
    case loading
    case loaded
    case failed(String)

    var title: String {
        switch self {
        case .idle: "尚未读取 Apple Photos"
        case .requestingAuthorization: "正在请求 Apple Photos 授权"
        case .loading: "正在读取 Apple Photos 索引"
        case .loaded: "Apple Photos 索引已读取"
        case let .failed(message): "读取失败：\(message)"
        }
    }
}

/// Apple Photos 的只读浏览状态。没有真实文件路径、没有 Catalog 持久化，也不会在启动时读取图库。
@MainActor
final class ApplePhotosStore: ObservableObject {
    @Published private(set) var authorization: ApplePhotosAuthorization
    @Published private(set) var state: ApplePhotosLoadState = .idle
    @Published private(set) var albums: [ApplePhotosAlbum] = []
    @Published private(set) var assets: [ApplePhotosAsset] = []
    /// 筛选仅在数据源或筛选条件变更时计算一次。界面重绘（例如选择项目、切换
    /// 检查器或从其他页面返回）只读取这里的结果，不会重新遍历整个 Photos 图库。
    @Published private(set) var visibleAssets: [ApplePhotosAsset] = []
    @Published private(set) var selectedAssetIDs = Set<String>()
    @Published private(set) var previewImage: NSImage?
    @Published var selectedAlbumID: String?
    @Published var browseFilter: ApplePhotosBrowseFilter = .all {
        didSet { rebuildVisibleAssets(resetDisplayWindow: true) }
    }
    @Published var dateFilter: ApplePhotosDateFilter = .allTime {
        didSet { rebuildVisibleAssets(resetDisplayWindow: true) }
    }
    @Published var searchText = "" {
        didSet { rebuildVisibleAssets(resetDisplayWindow: true) }
    }

    private let imageManager = PHCachingImageManager()
    private var availabilityByAssetID: [String: ApplePhotosAsset.Availability] = [:]
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailTasks: [ThumbnailRequestKey: Task<NSImage?, Never>] = [:]
    private var availabilityTasks: [String: Task<ApplePhotosAsset.Availability, Never>] = [:]
    private var selection = ApplePhotosSelection()
    private var preheatedThumbnails: [ThumbnailPreheat] = []
    private var loadCoordinator = ApplePhotosLoadCoordinator()
    private var loadTask: Task<Void, Never>?
    private let maximumPreheatedThumbnailCount = 96
    @Published private(set) var displayLimit = ApplePhotosDisplayWindow.pageSize

    init() {
        // Xcode 27 SDK 中可读取图库的最低可用 access level 是 `readWrite`；本组件不会调用任何写 API。
        authorization = ApplePhotosAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        thumbnailCache.countLimit = 240
        thumbnailCache.totalCostLimit = 120 * 1_024 * 1_024
    }

    /// 网格只物化一个有界首屏，避免大图库在一次 SwiftUI / Accessibility 更新中
    /// 生成数万个子视图。筛选仍针对完整内存元数据集执行。
    var displayedAssets: [ApplePhotosAsset] {
        Array(visibleAssets.prefix(displayLimit))
    }

    var hasMoreVisibleAssets: Bool {
        visibleAssets.count > displayLimit
    }

    /// Shift 范围限定为当前已展示项目；其余项目可按需继续加载后再选择。
    /// 顺序在 Store 中集中计算，避免每个网格 Cell 捕获完整 ID 列表。
    private var displayedAssetIDs: [String] {
        displayedAssets.map(\.id)
    }

    var selectedAsset: ApplePhotosAsset? {
        guard selectedAssetIDs.count == 1, let id = selectedAssetIDs.first else { return nil }
        return assets.first(where: { $0.id == id })
    }

    func availability(for asset: ApplePhotosAsset) -> ApplePhotosAsset.Availability {
        availabilityByAssetID[asset.id] ?? asset.availability
    }

    /// 仅读取系统当前授权状态；不会申请权限，也不会触发 PhotoKit 枚举。
    func refreshAuthorizationStatus() {
        authorization = ApplePhotosAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard !authorization.canRead else { return }
        invalidateActiveLoad()
        clearTransientLibraryState()
        if state == .loaded { state = .idle }
    }

    /// 唯一会请求 PhotoKit 授权的入口，必须由“授权并读取 Apple Photos”按钮调用。
    func requestAuthorizationAndLoad() {
        guard state != .requestingAuthorization, state != .loading else { return }
        if authorization.canRead {
            loadSelectedSource()
            return
        }
        guard authorization == .notDetermined else {
            state = .failed(authorization.title)
            return
        }

        state = .requestingAuthorization
        Task { [weak self] in
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard let self else { return }
            authorization = ApplePhotosAuthorization(status)
            guard authorization.canRead else {
                clearTransientLibraryState()
                state = .failed(authorization.title)
                return
            }
            loadSelectedSource()
        }
    }

    /// 仅在授权成功且用户明确读取或切换相簿后枚举元数据。这里不请求缩略图，也不检查 iCloud。
    func loadSelectedSource() {
        guard authorization.canRead else {
            state = .failed(authorization.title)
            return
        }
        let request = loadCoordinator.begin(selectedAlbumID: selectedAlbumID)
        loadTask?.cancel()
        state = .loading
        loadTask = Task.detached(priority: .utility) { [weak self] in
            let result = Self.loadAssets(albumID: request.albumID)
            guard !Task.isCancelled else { return }
            await self?.apply(result, for: request)
        }
    }

    func select(assetID: String, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let previousSelection = selectedAssetIDs
        selection.select(
            assetID: assetID,
            in: displayedAssetIDs,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift)
        )
        selectedAssetIDs = selection.selectedAssetIDs
        if selectedAssetIDs != previousSelection { previewImage = nil }
    }

    func clearSelection() {
        selection.clear()
        selectedAssetIDs = []
        previewImage = nil
    }

    func showMoreAssets() {
        guard hasMoreVisibleAssets else { return }
        displayLimit = ApplePhotosDisplayWindow.nextLimit(
            currentLimit: displayLimit,
            totalCount: visibleAssets.count
        )
    }

    func resetDisplayedAssets() {
        displayLimit = ApplePhotosDisplayWindow.pageSize
    }

    /// 可见 Cell 进入屏幕时才预热，绝不对整个图库预热或请求全部缩略图。
    func preheatThumbnail(for assetID: String, targetSize: CGSize) {
        let preheat = ThumbnailPreheat(assetID: assetID, targetSize: targetSize)
        guard !preheatedThumbnails.contains(preheat) else { return }
        guard let asset = photoKitAsset(id: assetID) else { return }
        imageManager.startCachingImages(
            for: [asset],
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: thumbnailOptions()
        )
        preheatedThumbnails.append(preheat)
        while preheatedThumbnails.count > maximumPreheatedThumbnailCount {
            let stale = preheatedThumbnails.removeFirst()
            guard let staleAsset = photoKitAsset(id: stale.assetID) else { continue }
            imageManager.stopCachingImages(
                for: [staleAsset],
                targetSize: stale.targetSize,
                contentMode: .aspectFill,
                options: thumbnailOptions()
            )
        }
    }

    /// 网格缩略图：目标尺寸来自 Grid Density × Retina scale，且明确禁止网络下载。
    func thumbnail(for assetID: String, targetSize: CGSize) async -> NSImage? {
        let key = ThumbnailRequestKey(assetID: assetID, targetSize: targetSize)
        if let cachedImage = thumbnailCache.object(forKey: key.cacheKey as NSString) {
            return cachedImage
        }
        if let activeTask = thumbnailTasks[key] {
            return await activeTask.value
        }

        let task = Task { [weak self] () -> NSImage? in
            guard let self, let asset = self.photoKitAsset(id: assetID) else { return nil }
            let response = await self.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: self.thumbnailOptions()
            )
            self.updateAvailability(assetID: assetID, response: response)
            return response.image
        }
        thumbnailTasks[key] = task
        let image = await task.value
        thumbnailTasks.removeValue(forKey: key)
        if let image {
            let pixelCount = max(1, Int(image.size.width * image.size.height))
            thumbnailCache.setObject(image, forKey: key.cacheKey as NSString, cost: pixelCount * 4)
        }
        return image
    }

    /// 只在可见 Cell 或明确选中的项目上执行 1px 无网络可用性查询；结果缓存在内存。
    func resolveAvailability(for assetID: String) async -> ApplePhotosAsset.Availability {
        if let known = availabilityByAssetID[assetID] { return known }
        if let activeTask = availabilityTasks[assetID] {
            return await activeTask.value
        }

        let task = Task { [weak self] () -> ApplePhotosAsset.Availability in
            guard let self, let asset = self.photoKitAsset(id: assetID) else { return .unknown }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            let response = await self.requestImage(
                for: asset,
                targetSize: CGSize(width: 1, height: 1),
                contentMode: .aspectFit,
                options: options
            )
            let availability = self.availability(from: response)
            self.availabilityByAssetID[assetID] = availability
            return availability
        }
        availabilityTasks[assetID] = task
        let availability = await task.value
        availabilityTasks.removeValue(forKey: assetID)
        return availability
    }

    private struct ThumbnailRequestKey: Hashable {
        let assetID: String
        let width: Int
        let height: Int

        init(assetID: String, targetSize: CGSize) {
            self.assetID = assetID
            width = Int(targetSize.width.rounded())
            height = Int(targetSize.height.rounded())
        }

        var cacheKey: String { "\(assetID)-\(width)x\(height)" }
    }

    /// 预览只请求适合当前检查器显示的像素尺寸；浏览时永远不下载 iCloud 原件，也不请求 Full Original。
    func loadPreview(for assetID: String, targetSize: CGSize) async {
        guard let asset = photoKitAsset(id: assetID) else {
            previewImage = nil
            return
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let response = await requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options)
        guard selectedAssetIDs == [assetID] else { return }
        updateAvailability(assetID: assetID, response: response)
        previewImage = response.image
    }

    func resourceDescriptors(for assetID: String) -> [ApplePhotosResourceDescriptor] {
        guard let asset = photoKitAsset(id: assetID) else { return [] }
        return PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            ApplePhotosResourceDescriptor(
                sourceIndex: index,
                filename: resource.originalFilename,
                role: Self.resourceRole(for: resource.type)
            )
        }
    }

    func photoKitResource(assetID: String, sourceIndex: Int) -> PHAssetResource? {
        guard let asset = photoKitAsset(id: assetID) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.indices.contains(sourceIndex) else { return nil }
        return resources[sourceIndex]
    }

    private func apply(_ result: Result<LoadedLibrary, Error>, for request: ApplePhotosLoadCoordinator.Request) {
        guard loadCoordinator.shouldApply(
            request,
            selectedAlbumID: selectedAlbumID,
            canRead: authorization.canRead
        ) else {
            return
        }
        loadTask = nil
        switch result {
        case let .success(library):
            imageManager.stopCachingImagesForAllAssets()
            preheatedThumbnails = []
            thumbnailCache.removeAllObjects()
            thumbnailTasks.values.forEach { $0.cancel() }
            thumbnailTasks = [:]
            availabilityTasks.values.forEach { $0.cancel() }
            availabilityTasks = [:]
            albums = library.albums
            assets = library.assets
            rebuildVisibleAssets()
            availabilityByAssetID = [:]
            displayLimit = ApplePhotosDisplayWindow.pageSize
            selection.retain(Set(assets.map(\.id)))
            selectedAssetIDs = selection.selectedAssetIDs
            if selectedAssetIDs.count != 1 { previewImage = nil }
            state = .loaded
        case let .failure(error):
            state = .failed(error.localizedDescription)
        }
    }

    private func clearTransientLibraryState() {
        imageManager.stopCachingImagesForAllAssets()
        preheatedThumbnails = []
        thumbnailCache.removeAllObjects()
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks = [:]
        availabilityTasks.values.forEach { $0.cancel() }
        availabilityTasks = [:]
        albums = []
        assets = []
        visibleAssets = []
        availabilityByAssetID = [:]
        displayLimit = ApplePhotosDisplayWindow.pageSize
        selection.clear()
        selectedAssetIDs = []
        previewImage = nil
    }

    private func invalidateActiveLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadCoordinator.invalidate()
    }

    private func rebuildVisibleAssets(resetDisplayWindow: Bool = false) {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleAssets = assets.filter { asset in
            browseFilter.matches(asset)
                && dateFilter.matches(asset)
                && (normalizedSearch.isEmpty || asset.filename.localizedCaseInsensitiveContains(normalizedSearch))
        }
        if resetDisplayWindow {
            displayLimit = ApplePhotosDisplayWindow.pageSize
        }
    }

    private func photoKitAsset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func thumbnailOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        return options
    }

    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        options: PHImageRequestOptions
    ) async -> ImageResponse {
        await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                continuation.resume(returning: ImageResponse(image: image, info: info))
            }
        }
    }

    private func updateAvailability(assetID: String, response: ImageResponse) {
        let resolved = availability(from: response)
        guard resolved != .unknown || availabilityByAssetID[assetID] == nil else { return }
        availabilityByAssetID[assetID] = resolved
    }

    private func availability(from response: ImageResponse) -> ApplePhotosAsset.Availability {
        if (response.info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true {
            return .iCloudOnly
        }
        return response.image == nil ? .unknown : .local
    }

    nonisolated private static func loadAssets(albumID: String?) -> Result<LoadedLibrary, Error> {
        Result {
            let albums = loadAlbums()
            let fetchResult: PHFetchResult<PHAsset>
            if let albumID,
               let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
                fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions())
            } else {
                fetchResult = PHAsset.fetchAssets(with: fetchOptions())
            }

            var loadedAssets: [ApplePhotosAsset] = []
            loadedAssets.reserveCapacity(fetchResult.count)
            fetchResult.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                let preferredName = resources.first(where: { resourceRole(for: $0.type).isOriginal })?.originalFilename
                    ?? resources.first?.originalFilename
                    ?? "Apple Photos 资产"
                let mediaType: ApplePhotosMediaType
                switch asset.mediaType {
                case .image: mediaType = .image
                case .video: mediaType = .video
                default: mediaType = .unknown
                }
                let subtypes = asset.mediaSubtypes
                loadedAssets.append(
                    ApplePhotosAsset(
                        id: asset.localIdentifier,
                        filename: preferredName,
                        createdAt: asset.creationDate,
                        modifiedAt: asset.modificationDate,
                        mediaType: mediaType,
                        mediaSubtypes: UInt(subtypes.rawValue),
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        duration: asset.duration,
                        isFavorite: asset.isFavorite,
                        isRAW: resources.contains(where: isRAWResource),
                        isLivePhoto: subtypes.contains(.photoLive),
                        availability: .unknown
                    )
                )
            }
            return LoadedLibrary(albums: albums, assets: loadedAssets)
        }
    }

    nonisolated private static func loadAlbums() -> [ApplePhotosAlbum] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [ApplePhotosAlbum] = []
        albums.reserveCapacity(collections.count)
        collections.enumerateObjects { collection, _, _ in
            albums.append(
                ApplePhotosAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "未命名相簿",
                    estimatedAssetCount: PHAsset.fetchAssets(in: collection, options: nil).count
                )
            )
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    nonisolated static func resourceRole(for type: PHAssetResourceType) -> ApplePhotosResourceRole {
        switch type {
        case .photo: .originalPhoto
        case .video: .originalVideo
        case .pairedVideo: .livePhotoPairedVideo
        case .fullSizePhoto: .fallbackPhoto
        case .fullSizeVideo: .fallbackVideo
        case .fullSizePairedVideo: .fallbackPairedVideo
        // RAW+JPEG 组合中的 RAW 通常以 alternatePhoto 出现；必须与 JPEG 一起保留。
        case .alternatePhoto: .originalPhoto
        case .audio, .adjustmentData, .adjustmentBasePhoto,
             .adjustmentBasePairedVideo, .adjustmentBaseVideo, .photoProxy:
            .unsupported
        @unknown default:
            .unsupported
        }
    }

    /// macOS 27 的 `PHAssetMediaSubtype` 没有 RAW 位标记；以公开 `PHAssetResource.contentType`
    /// 判定资源是否为 RAW，必要时以常见原始扩展名作保守回退。
    nonisolated private static func isRAWResource(_ resource: PHAssetResource) -> Bool {
        if resource.contentType.conforms(to: .rawImage) { return true }
        let extensionName = (resource.originalFilename as NSString).pathExtension.lowercased()
        return ["arw", "cr2", "cr3", "dng", "nef", "nrw", "orf", "pef", "raf", "rw2", "srw", "x3f"].contains(extensionName)
    }

    private struct ImageResponse: @unchecked Sendable {
        let image: NSImage?
        let info: [AnyHashable: Any]?
    }

    private struct ThumbnailPreheat: Equatable {
        let assetID: String
        let targetSize: CGSize
    }

    private struct LoadedLibrary: Sendable {
        let albums: [ApplePhotosAlbum]
        let assets: [ApplePhotosAsset]
    }
}
