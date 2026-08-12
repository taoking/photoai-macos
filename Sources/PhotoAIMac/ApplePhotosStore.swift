import Foundation
import Photos

/// Apple Photos 数据源独立于文件夹 Catalog；它不创建书签、不写入 PhotoAsset，也不改变文件系统来源。
struct ApplePhotosAsset: Identifiable, Hashable, Sendable {
    enum Availability: String, Hashable, Sendable {
        case local
        case iCloudOnly
        case unknown

        var title: String {
            switch self {
            case .local: "本机可用"
            case .iCloudOnly: "需要从 iCloud 下载"
            case .unknown: "可用性未知"
            }
        }
    }

    let id: String
    let filename: String
    let createdAt: Date?
    let isFavorite: Bool
    let mediaKind: String
    let availability: Availability
}

struct ApplePhotosAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let estimatedAssetCount: Int
}

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

@MainActor
final class ApplePhotosStore: ObservableObject {
    @Published private(set) var authorization: ApplePhotosAuthorization
    @Published private(set) var state: ApplePhotosLoadState = .idle
    @Published private(set) var albums: [ApplePhotosAlbum] = []
    @Published private(set) var assets: [ApplePhotosAsset] = []
    @Published var selectedAlbumID: String?
    @Published var favoritesOnly = false

    init() {
        authorization = ApplePhotosAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    var visibleAssets: [ApplePhotosAsset] {
        assets.filter { !favoritesOnly || $0.isFavorite }
    }

    func refreshAuthorizationStatus() {
        authorization = ApplePhotosAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// 这是唯一会请求 Photos 权限的入口，且由页面中的用户操作触发。
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
                state = .failed(authorization.title)
                return
            }
            loadSelectedSource()
        }
    }

    /// 枚举仅在授权后、用户主动点击后执行；iCloud 资产检测使用 `isNetworkAccessAllowed = false`。
    func loadSelectedSource() {
        guard authorization.canRead else {
            state = .failed(authorization.title)
            return
        }
        state = .loading
        let selectedAlbumID = selectedAlbumID
        let favoritesOnly = favoritesOnly

        Task.detached(priority: .utility) { [weak self] in
            let result = Self.loadAssets(albumID: selectedAlbumID, favoritesOnly: favoritesOnly)
            await self?.apply(result)
        }
    }

    private func apply(_ result: Result<LoadedLibrary, Error>) {
        switch result {
        case let .success(library):
            albums = library.albums
            assets = library.assets
            state = .loaded
        case let .failure(error):
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated private static func loadAssets(albumID: String?, favoritesOnly: Bool) -> Result<LoadedLibrary, Error> {
        Result {
            let albums = loadAlbums()
            let fetchResult: PHFetchResult<PHAsset>
            if let albumID,
               let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
                fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions(favoritesOnly: favoritesOnly))
            } else {
                fetchResult = PHAsset.fetchAssets(with: fetchOptions(favoritesOnly: favoritesOnly))
            }

            var loadedAssets: [ApplePhotosAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in
                let resource = PHAssetResource.assetResources(for: asset).first
                loadedAssets.append(
                    ApplePhotosAsset(
                        id: asset.localIdentifier,
                        filename: resource?.originalFilename ?? "Apple Photos 资产",
                        createdAt: asset.creationDate,
                        isFavorite: asset.isFavorite,
                        mediaKind: asset.mediaType == .video ? "视频" : "照片",
                        availability: availability(for: asset)
                    )
                )
            }
            return LoadedLibrary(albums: albums, assets: loadedAssets)
        }
    }

    nonisolated private static func loadAlbums() -> [ApplePhotosAlbum] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albums: [ApplePhotosAlbum] = []
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

    nonisolated private static func fetchOptions(favoritesOnly: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if favoritesOnly { options.predicate = NSPredicate(format: "favorite == YES") }
        return options
    }

    nonisolated private static func availability(for asset: PHAsset) -> ApplePhotosAsset.Availability {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        var isInCloud = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1, height: 1),
            contentMode: .aspectFit,
            options: options
        ) { _, info in
            isInCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
        }
        return isInCloud ? .iCloudOnly : .local
    }

    private struct LoadedLibrary: Sendable {
        let albums: [ApplePhotosAlbum]
        let assets: [ApplePhotosAsset]
    }
}
