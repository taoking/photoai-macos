import Foundation

/// Apple Photos 项目只存在于内存中；`id` 始终是 PhotoKit 的 `localIdentifier`，从不伪造文件路径。
struct ApplePhotosAsset: Identifiable, Hashable, Sendable {
    enum Availability: String, Hashable, Sendable {
        case local
        case iCloudOnly
        case unknown

        var title: String {
            switch self {
            case .local: "本地可用"
            case .iCloudOnly: "来自 iCloud"
            case .unknown: "状态未知"
            }
        }
    }

    let id: String
    let filename: String
    let createdAt: Date?
    let modifiedAt: Date?
    let mediaType: ApplePhotosMediaType
    let mediaSubtypes: UInt
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let isFavorite: Bool
    let isRAW: Bool
    let isLivePhoto: Bool

    /// 初始加载不会逐项探测 iCloud；懒加载结果由 `ApplePhotosStore` 单独缓存。
    let availability: Availability

    init(
        id: String,
        filename: String,
        createdAt: Date?,
        modifiedAt: Date? = nil,
        mediaType: ApplePhotosMediaType = .image,
        mediaSubtypes: UInt = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        duration: TimeInterval = 0,
        isFavorite: Bool,
        isRAW: Bool = false,
        isLivePhoto: Bool = false,
        availability: Availability = .unknown
    ) {
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.isRAW = isRAW
        self.isLivePhoto = isLivePhoto
        self.availability = availability
    }

    /// Phase 11 的兼容展示属性；新界面应使用 `mediaType`。
    var mediaKind: String { mediaType.title }

    var displayDimensions: String {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight)" : "尺寸未知"
    }

    var durationText: String? {
        guard mediaType == .video, duration > 0 else { return nil }
        let totalSeconds = Int(duration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

enum ApplePhotosMediaType: String, CaseIterable, Hashable, Sendable {
    case image
    case video
    case unknown

    var title: String {
        switch self {
        case .image: "照片"
        case .video: "视频"
        case .unknown: "其他媒体"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .video: "video"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

enum ApplePhotosBrowseFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case recent
    case favorites
    case videos
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部照片"
        case .recent: "最近项目"
        case .favorites: "收藏"
        case .videos: "视频"
        case .raw: "RAW"
        }
    }

    func matches(_ asset: ApplePhotosAsset, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: return true
        case .recent:
            guard let createdAt = asset.createdAt else { return false }
            return createdAt >= calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .favorites: return asset.isFavorite
        case .videos: return asset.mediaType == .video
        case .raw: return asset.isRAW
        }
    }
}

enum ApplePhotosDateFilter: String, CaseIterable, Identifiable, Sendable {
    case allTime
    case today
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime: "所有日期"
        case .today: "今天"
        case .last30Days: "最近 30 天"
        }
    }

    func matches(_ asset: ApplePhotosAsset, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let date = asset.createdAt else { return self == .allTime }
        switch self {
        case .allTime:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .last30Days:
            return date >= calendar.date(byAdding: .day, value: -30, to: now) ?? now
        }
    }
}

struct ApplePhotosAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let estimatedAssetCount: Int
}

/// 选择状态只使用 `PHAsset.localIdentifier`，支持单选、Command 切换和 Shift 范围选择。
struct ApplePhotosSelection: Equatable, Sendable {
    private(set) var selectedAssetIDs = Set<String>()
    private(set) var anchorID: String?

    mutating func select(assetID: String, in orderedAssetIDs: [String], command: Bool, shift: Bool) {
        guard orderedAssetIDs.contains(assetID) else { return }

        if command {
            if selectedAssetIDs.contains(assetID) {
                selectedAssetIDs.remove(assetID)
            } else {
                selectedAssetIDs.insert(assetID)
                anchorID = assetID
            }
            return
        }

        if shift,
           let anchorID,
           let anchorIndex = orderedAssetIDs.firstIndex(of: anchorID),
           let currentIndex = orderedAssetIDs.firstIndex(of: assetID) {
            selectedAssetIDs.formUnion(orderedAssetIDs[min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)])
            return
        }

        selectedAssetIDs = [assetID]
        anchorID = assetID
    }

    mutating func retain(_ availableIDs: Set<String>) {
        selectedAssetIDs.formIntersection(availableIDs)
        if let anchorID, !availableIDs.contains(anchorID) {
            self.anchorID = nil
        }
    }

    mutating func clear() {
        selectedAssetIDs = []
        anchorID = nil
    }
}

enum ApplePhotosResourceRole: String, Hashable, Sendable {
    case originalPhoto
    case originalVideo
    case livePhotoPairedVideo
    case fallbackPhoto
    case fallbackVideo
    case fallbackPairedVideo
    case unsupported

    var isImportable: Bool { self != .unsupported }

    var isOriginal: Bool {
        switch self {
        case .originalPhoto, .originalVideo, .livePhotoPairedVideo: true
        case .fallbackPhoto, .fallbackVideo, .fallbackPairedVideo, .unsupported: false
        }
    }

    var title: String {
        switch self {
        case .originalPhoto: "原始照片资源"
        case .originalVideo: "原始视频资源"
        case .livePhotoPairedVideo: "Live Photo 配对视频"
        case .fallbackPhoto: "可用全尺寸照片（非原始）"
        case .fallbackVideo: "可用全尺寸视频（非原始）"
        case .fallbackPairedVideo: "可用配对视频（非原始）"
        case .unsupported: "不支持的资源"
        }
    }
}

/// 与 PhotoKit 解耦的资源描述，方便使用 Mock 覆盖 RAW、Live Photo、视频和未知资源。
struct ApplePhotosResourceDescriptor: Hashable, Sendable {
    let sourceIndex: Int
    let filename: String
    let role: ApplePhotosResourceRole

    init(sourceIndex: Int, filename: String, role: ApplePhotosResourceRole) {
        self.sourceIndex = sourceIndex
        self.filename = filename
        self.role = role
    }
}

struct ApplePhotosImportResourcePlan: Identifiable, Hashable, Sendable {
    let assetID: String
    let sourceIndex: Int
    let filename: String
    let role: ApplePhotosResourceRole

    var id: String { "\(assetID)#\(sourceIndex)" }
}

enum ApplePhotosImportPlanner {
    /// 保留每个原始资源：RAW+JPEG 会保留两者，Live Photo 会保留静态照片及配对视频。
    /// 仅当库没有相应的原始资源时才采用全尺寸回退资源，且结果明确标注为非原始。
    static func plan(assetID: String, resources: [ApplePhotosResourceDescriptor]) -> [ApplePhotosImportResourcePlan] {
        let originalPhotos = resources.filter { $0.role == .originalPhoto }
        let originalVideos = resources.filter { $0.role == .originalVideo }
        let pairedVideos = resources.filter { $0.role == .livePhotoPairedVideo }
        let fallbackPhotos = resources.filter { $0.role == .fallbackPhoto }
        let fallbackVideos = resources.filter { $0.role == .fallbackVideo }
        let fallbackPairedVideos = resources.filter { $0.role == .fallbackPairedVideo }

        let selected = (originalPhotos.isEmpty ? fallbackPhotos : originalPhotos)
            + (originalVideos.isEmpty ? fallbackVideos : originalVideos)
            + (pairedVideos.isEmpty ? fallbackPairedVideos : pairedVideos)

        return selected
            .filter(\.role.isImportable)
            .map { descriptor in
                ApplePhotosImportResourcePlan(
                    assetID: assetID,
                    sourceIndex: descriptor.sourceIndex,
                    filename: descriptor.filename,
                    role: descriptor.role
                )
            }
    }

    static func conflictSafeFilename(preferredFilename: String, occupiedFilenames: inout Set<String>) -> String {
        let normalizedPreferred = preferredFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = normalizedPreferred.isEmpty ? "Apple Photos 资源" : normalizedPreferred
        let filename = (fallback as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let suffix = (filename as NSString).pathExtension
        let safeStem = stem.isEmpty ? "Apple Photos 资源" : stem

        var candidate = filename
        var suffixIndex = 2
        while occupiedFilenames.contains(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            candidate = suffix.isEmpty ? "\(safeStem)-\(suffixIndex)" : "\(safeStem)-\(suffixIndex).\(suffix)"
            suffixIndex += 1
        }
        occupiedFilenames.insert(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        return candidate
    }
}

enum ApplePhotosImportState: Equatable, Sendable {
    case idle
    case importing
    case cancelling
    case cancelled
    case completed
    case failed(String)

    var title: String {
        switch self {
        case .idle: "尚未导入"
        case .importing: "正在导入原始资源"
        case .cancelling: "正在取消导入"
        case .cancelled: "已取消导入"
        case .completed: "导入完成"
        case let .failed(message): "导入失败：\(message)"
        }
    }

    var isActive: Bool { self == .importing || self == .cancelling }
}

struct ApplePhotosImportProgress: Equatable, Sendable {
    var totalResources: Int = 0
    var completedResources: Int = 0
    var failedResources: Int = 0
    var currentFilename: String?
    var currentFraction: Double = 0

    var fractionCompleted: Double {
        guard totalResources > 0 else { return 0 }
        return min(1, (Double(completedResources) + currentFraction) / Double(totalResources))
    }
}

struct ApplePhotosImportFailure: Identifiable, Equatable, Sendable {
    let assetID: String
    let filename: String
    let message: String

    var id: String { "\(assetID)-\(filename)-\(message)" }
}

struct ApplePhotosImportResult: Equatable, Sendable {
    let writtenFileURLs: [URL]
    let importedAssetIDs: Set<String>
    let failures: [ApplePhotosImportFailure]
    let usedFallbackResources: Int
    let wasCancelled: Bool

    static let empty = ApplePhotosImportResult(
        writtenFileURLs: [],
        importedAssetIDs: [],
        failures: [],
        usedFallbackResources: 0,
        wasCancelled: false
    )
}
