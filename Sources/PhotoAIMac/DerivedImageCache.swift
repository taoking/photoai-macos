@preconcurrency import AppKit
import Foundation

/// 派生图的级别。两级都由同一次解码产出，因此增加一级的成本只有编码与磁盘空间。
enum DerivedImageTier: String, CaseIterable, Sendable {
    /// 网格缩略图。实测真实照片平均 52.4 KB，5 万张约 2.5 GB。
    case thumbnail
    /// 离线大图预览。取 1600 是因为 Sony ARW 的内嵌预览本身就是 1616×1080，
    /// 这一级对 RAW 是零损失；再往上（2400）只对 JPEG 原图有意义，却要多花 9 GB。
    /// 实测平均 389.9 KB，5 万张约 18.6 GB。
    case preview

    var maximumPixelSize: Int {
        switch self {
        case .thumbnail: 480
        case .preview: OfflinePreviewSetting.current.pixelSize
        }
    }

    var directoryName: String {
        switch self {
        case .thumbnail: "thumbnails"
        case .preview: "previews"
        }
    }
}

/// 离线预览这一级的尺寸。它直接决定磁盘占用，所以交给用户选。
///
/// 每万张照片的实测占用（真实照片均值）：缩略图约 0.5 GB 固定，
/// 离线预览 1280 约 2.6 GB、1600 约 3.7 GB、2400 约 5.6 GB。
enum OfflinePreviewSetting: Int, CaseIterable, Identifiable, Sendable {
    /// 只留缩略图。卷退出后仍能浏览网格，但点开单张只有放大的缩略图。
    case disabled = 0
    case compact = 1_280
    /// 默认。Sony ARW 的内嵌预览本身就是 1616×1080，这一级对 RAW 是零损失。
    case standard = 1_600
    case large = 2_400

    static let storageKey = "photoai.offlinePreviewPixelSize"

    var id: Int { rawValue }

    var pixelSize: Int { self == .disabled ? DerivedImageTier.thumbnail.maximumPixelSize : rawValue }

    var title: String {
        switch self {
        case .disabled: "关闭（仅缩略图）"
        case .compact: "1280 px"
        case .standard: "1600 px（推荐）"
        case .large: "2400 px"
        }
    }

    var storageEstimate: String {
        switch self {
        case .disabled: "每万张约 0.5 GB"
        case .compact: "每万张约 3.1 GB"
        case .standard: "每万张约 4.2 GB"
        case .large: "每万张约 6.1 GB"
        }
    }

    /// 未设置时取默认值。读 `UserDefaults` 是线程安全的，因此不需要额外的全局可变状态。
    static var current: OfflinePreviewSetting {
        guard let stored = UserDefaults.standard.object(forKey: storageKey) as? Int,
              let setting = OfflinePreviewSetting(rawValue: stored) else {
            return .standard
        }
        return setting
    }

    static var isOfflinePreviewEnabled: Bool { current != .disabled }
}

/// 定位一张原始照片所需的最小信息。缩略图与离线预览共用同一个请求，
/// 因为它们读的是同一个文件、走的是同一次解码。
struct DerivedImageRequest: Sendable, Hashable {
    let sourceID: UUID
    let assetID: UUID
    let bookmarkData: Data
    let lastKnownRootPath: String
    let relativePath: String
    let modificationDate: Date?
    let mediaType: PhotoMediaType

    /// 与级别无关的稳定标识，供 SwiftUI 的 `.task(id:)` / `.onChange(of:)` 判定视图身份。
    /// 带上修改时间，原文件一改视图就会重新加载。
    var cacheKey: String {
        let timestamp = modificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0
        return "\(assetID.uuidString)-\(timestamp)"
    }

    /// 内存缓存键。每一级各存一份。
    func memoryCacheKey(for tier: DerivedImageTier) -> String {
        "\(cacheKey)-\(tier.rawValue)"
    }
}

/// 派生图的磁盘层。
///
/// 这里存的**不是可丢弃的缓存**：卷退出之后，它就是那些照片在本机的唯一表示。
/// 因此它住在 Application Support 而不是 Caches——后者会被系统在磁盘压力下清除，
/// 而且默认不进 Time Machine 备份。也因此没有总量预算和 LRU 淘汰：
/// 容量由"每个来源占多少"和"移除来源时一并清理"来管理，而不是背着用户删文件。
struct DerivedImageCache: Sendable {
    let rootURL: URL

    init(rootURL: URL = DerivedImageCache.defaultRootURL) {
        self.rootURL = rootURL
    }

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("Derived", isDirectory: true)
    }

    /// 文件名只用 `assetID`，不含修改时间。
    ///
    /// 资产身份已由 `sourceID + relativePath` 保证稳定，而外置盘或 exFAT 重新接回时
    /// 修改时间可能因时区或取整发生漂移；若把它编进文件名，重新接回会让整卷缓存
    /// 全部落空，旧文件还会变成没人认领的孤儿。是否需要重新生成改由文件时间比较决定。
    func fileURL(sourceID: UUID, assetID: UUID, tier: DerivedImageTier) -> URL {
        directoryURL(sourceID: sourceID, tier: tier)
            .appendingPathComponent("\(assetID.uuidString).jpg", isDirectory: false)
    }

    func directoryURL(sourceID: UUID, tier: DerivedImageTier) -> URL {
        rootURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(tier.directoryName, isDirectory: true)
    }

    func sourceDirectoryURL(sourceID: UUID) -> URL {
        rootURL.appendingPathComponent(sourceID.uuidString, isDirectory: true)
    }

    /// 缓存是否存在且不比原文件旧。原文件在缓存写入之后被改过就算过期。
    func hasFreshEntry(for request: DerivedImageRequest, tier: DerivedImageTier) -> Bool {
        let url = fileURL(sourceID: request.sourceID, assetID: request.assetID, tier: tier)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let cachedAt = values.contentModificationDate else {
            return false
        }
        guard let modifiedAt = request.modificationDate else { return true }
        return cachedAt >= modifiedAt
    }

    func image(for request: DerivedImageRequest, tier: DerivedImageTier) -> NSImage? {
        guard hasFreshEntry(for: request, tier: tier) else { return nil }
        return NSImage(contentsOf: fileURL(sourceID: request.sourceID, assetID: request.assetID, tier: tier))
    }

    @discardableResult
    func store(_ image: NSImage, for request: DerivedImageRequest, tier: DerivedImageTier) -> Bool {
        guard let data = Self.encode(image) else { return false }
        let url = fileURL(sourceID: request.sourceID, assetID: request.assetID, tier: tier)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 移除来源时调用。派生图不再有价值，且用户已在确认框里同意。
    func removeAll(for sourceID: UUID) {
        try? FileManager.default.removeItem(at: sourceDirectoryURL(sourceID: sourceID))
    }

    /// 某个来源当前占用的磁盘字节数。文件夹页用它把占用情况摊开给用户。
    func byteSize(for sourceID: UUID) -> Int64 {
        let directory = sourceDirectoryURL(sourceID: sourceID)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// 已经缓存了多少张。用于预热进度，以及判断一个离线来源还剩多少看不到。
    func entryCount(for sourceID: UUID, tier: DerivedImageTier) -> Int {
        let directory = directoryURL(sourceID: sourceID, tier: tier)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { !$0.hasPrefix(".") }.count
    }

    /// 清理旧版本留在 `~/Library/Caches/` 里的派生图。
    ///
    /// 旧布局是扁平的、以"资产 + 修改时间"为文件名，无法映射到现在按来源分的目录；
    /// 它们本来就是可重建的缓存，直接删除即可。放在 Caches 下也正是这次要改掉的问题：
    /// 系统会在磁盘压力下清除那里，而派生图现在承担着离线浏览的职责。
    static func removeLegacyCaches() {
        let legacyRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
        for name in ["Thumbnails", "PhotoViewer"] {
            try? FileManager.default.removeItem(at: legacyRoot.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// 派生图是可随时重建的展示数据，没有理由为它保留无损像素。
    static func encode(_ image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
