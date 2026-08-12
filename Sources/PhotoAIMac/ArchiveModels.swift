import Foundation

enum ArchiveHashState: String, Codable, Hashable, Sendable {
    case pending
    case complete
    case stale
    case failed

    var title: String {
        switch self {
        case .pending: "等待计算"
        case .complete: "已完成"
        case .stale: "原文件已变化"
        case .failed: "暂未完成"
        }
    }
}

enum ArchivePreviewState: String, Codable, Hashable, Sendable {
    case pending
    case complete
    case stale
    /// 临时 I/O 中断等可由用户明确重试的失败，不会在每次启动时无限重试。
    case retryableFailure
    /// 当前 ImageIO 无法解码的格式；除非实现增加支持，否则不自动重复尝试。
    case unsupported
    /// 用户主动释放了派生预览。哈希仍然保留，只有明确“重新建立”才会恢复预览。
    case evicted
}

enum AssetArchiveAvailability: String, Codable, Hashable, Sendable {
    case online
    case offline
    case missing
    case multipleCopies

    var title: String {
        switch self {
        case .online: "原始文件可用"
        case .offline: "原始文件离线"
        case .missing: "原始文件缺失"
        case .multipleCopies: "存在多个已索引副本"
        }
    }
}

struct OfflinePreviewMetadata: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var relativePath: String
    var width: Int
    var height: Int
    var byteSize: Int64
    var generatedAt: Date
    var sourceModifiedAt: Date?

    init(
        version: Int = OfflinePreviewMetadata.currentVersion,
        relativePath: String,
        width: Int,
        height: Int,
        byteSize: Int64,
        generatedAt: Date,
        sourceModifiedAt: Date?
    ) {
        self.version = version
        self.relativePath = relativePath
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.generatedAt = generatedAt
        self.sourceModifiedAt = sourceModifiedAt
    }
}

/// 只保存本地派生索引；不保存或上传原始图像内容。
struct ArchiveAssetMetadata: Codable, Hashable, Sendable {
    var exactHash: String?
    var visualHash: UInt64?
    var hashedFileSize: Int64?
    var hashedModifiedAt: Date?
    var hashUpdatedAt: Date?
    var hashState: ArchiveHashState
    var preview: OfflinePreviewMetadata?
    var previewState: ArchivePreviewState
    var firstSeenAt: Date?
    var lastSeenAt: Date?
    var lastError: String?

    init(
        exactHash: String? = nil,
        visualHash: UInt64? = nil,
        hashedFileSize: Int64? = nil,
        hashedModifiedAt: Date? = nil,
        hashUpdatedAt: Date? = nil,
        hashState: ArchiveHashState = .pending,
        preview: OfflinePreviewMetadata? = nil,
        previewState: ArchivePreviewState = .pending,
        firstSeenAt: Date? = nil,
        lastSeenAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.exactHash = exactHash
        self.visualHash = visualHash
        self.hashedFileSize = hashedFileSize
        self.hashedModifiedAt = hashedModifiedAt
        self.hashUpdatedAt = hashUpdatedAt
        self.hashState = hashState
        self.preview = preview
        self.previewState = previewState
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastError = lastError
    }

    static let empty = ArchiveAssetMetadata()

    func needsHash(for asset: PhotoAsset) -> Bool {
        hashState != .complete || hashedFileSize != asset.fileSize || hashedModifiedAt != asset.modifiedAt || exactHash == nil
    }

    func needsPreview(for asset: PhotoAsset) -> Bool {
        guard asset.mediaType == .image else { return false }
        switch previewState {
        case .pending, .stale:
            return true
        case .complete:
            return preview?.version != OfflinePreviewMetadata.currentVersion || preview?.sourceModifiedAt != asset.modifiedAt
        case .retryableFailure, .unsupported, .evicted:
            return false
        }
    }

    func canRebuildPreview(for asset: PhotoAsset) -> Bool {
        guard asset.mediaType == .image else { return false }
        return previewState == .evicted || previewState == .retryableFailure
    }

    func invalidatedForChangedSource() -> ArchiveAssetMetadata {
        var copy = self
        copy.exactHash = nil
        copy.visualHash = nil
        copy.hashedFileSize = nil
        copy.hashedModifiedAt = nil
        copy.hashUpdatedAt = nil
        copy.hashState = .stale
        copy.preview = nil
        copy.previewState = .stale
        copy.lastError = nil
        return copy
    }
}

/// 物理文件位置。当前 Phase 14 保留一条主资产与多条位置/重复关系的扩展空间，
/// 不会把不同来源的字节级副本自动删除或静默合并。
struct AssetLocation: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var assetID: UUID
    var sourceID: UUID
    var volumeIdentifier: String?
    var volumeName: String?
    var fileResourceIdentifier: String?
    var relativePath: String
    var filename: String
    var fileSize: Int64
    var modifiedAt: Date?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var isAvailable: Bool

    init(
        id: UUID = UUID(),
        assetID: UUID,
        sourceID: UUID,
        volumeIdentifier: String? = nil,
        volumeName: String? = nil,
        fileResourceIdentifier: String? = nil,
        relativePath: String,
        filename: String,
        fileSize: Int64,
        modifiedAt: Date?,
        firstSeenAt: Date = .now,
        lastSeenAt: Date = .now,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceID = sourceID
        self.volumeIdentifier = volumeIdentifier
        self.volumeName = volumeName
        self.fileResourceIdentifier = fileResourceIdentifier
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.isAvailable = isAvailable
    }
}

enum ArchiveDuplicateKind: String, Codable, Hashable, Sendable {
    case sameIndexedFile
    case exactDuplicate
    case possibleVisualDuplicate

    var title: String {
        switch self {
        case .sameIndexedFile: "已索引文件"
        case .exactDuplicate: "完全重复"
        case .possibleVisualDuplicate: "疑似视觉重复"
        }
    }
}

struct ArchiveDuplicateRelationship: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var firstAssetID: UUID
    var secondAssetID: UUID
    var kind: ArchiveDuplicateKind
    var discoveredAt: Date

    init(
        id: UUID = UUID(),
        firstAssetID: UUID,
        secondAssetID: UUID,
        kind: ArchiveDuplicateKind,
        discoveredAt: Date = .now
    ) {
        if firstAssetID.uuidString.localizedStandardCompare(secondAssetID.uuidString) == .orderedAscending {
            self.firstAssetID = firstAssetID
            self.secondAssetID = secondAssetID
        } else {
            self.firstAssetID = secondAssetID
            self.secondAssetID = firstAssetID
        }
        self.id = id
        self.kind = kind
        self.discoveredAt = discoveredAt
    }

    var key: String { "\(firstAssetID.uuidString)/\(secondAssetID.uuidString)/\(kind.rawValue)" }
}

enum ArchiveWorkState: Equatable, Sendable {
    case idle
    case running
    case paused
    case complete

    var title: String {
        switch self {
        case .idle: "等待归档索引"
        case .running: "正在建立离线索引"
        case .paused: "归档索引已暂停"
        case .complete: "归档索引已完成"
        }
    }
}

struct ArchiveWorkProgress: Equatable, Sendable {
    var state: ArchiveWorkState = .idle
    var totalCount = 0
    var completedCount = 0
    var hashCompletedCount = 0
    var previewCompletedCount = 0
    var failureCount = 0

    var description: String {
        guard totalCount > 0 else { return state.title }
        let failures = failureCount == 0 ? "" : "，失败 \(failureCount) 项"
        return "\(state.title)：\(completedCount) / \(totalCount)（Hash \(hashCompletedCount)，离线预览 \(previewCompletedCount)）\(failures)"
    }
}

struct ArchiveImportSummary: Equatable, Sendable {
    var scannedCount = 0
    var newAssetCount = 0
    var sameIndexedFileCount = 0
    var exactDuplicateCount = 0
    var possibleVisualDuplicateCount = 0
    var failureCount = 0
}
