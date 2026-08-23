import Foundation

struct CullingStatistics: Equatable, Sendable {
    private(set) var totalCount: Int
    private(set) var pickCount: Int
    private(set) var fiveStarCount: Int
    private(set) var rejectCount: Int
    private(set) var unprocessedCount: Int

    static let empty = CullingStatistics(
        totalCount: 0,
        pickCount: 0,
        fiveStarCount: 0,
        rejectCount: 0,
        unprocessedCount: 0
    )

    init(assets: [PhotoAsset]) {
        totalCount = assets.count
        pickCount = assets.count { $0.flag == .pick }
        fiveStarCount = assets.count { $0.rating == 5 }
        rejectCount = assets.count { $0.flag == .reject }
        unprocessedCount = assets.count { $0.rating == 0 && $0.flag == .none }
    }

    private init(
        totalCount: Int,
        pickCount: Int,
        fiveStarCount: Int,
        rejectCount: Int,
        unprocessedCount: Int
    ) {
        self.totalCount = totalCount
        self.pickCount = pickCount
        self.fiveStarCount = fiveStarCount
        self.rejectCount = rejectCount
        self.unprocessedCount = unprocessedCount
    }

    mutating func replace(_ oldValue: CullingMetadataState, with newValue: CullingMetadataState) {
        apply(oldValue, delta: -1)
        apply(newValue, delta: 1)
    }

    private mutating func apply(_ value: CullingMetadataState, delta: Int) {
        if value.flag == .pick { pickCount += delta }
        if value.rating == 5 { fiveStarCount += delta }
        if value.flag == .reject { rejectCount += delta }
        if value.rating == 0 && value.flag == .none { unprocessedCount += delta }
    }
}

struct CullingMetadataState: Equatable, Sendable {
    let rating: Int
    let flag: PhotoFlag

    init(asset: PhotoAsset) {
        rating = asset.rating
        flag = asset.flag
    }
}

struct PhotoGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let assetIDs: [UUID]

    init(assetIDs: [UUID]) {
        precondition(!assetIDs.isEmpty)
        id = assetIDs[0]
        self.assetIDs = assetIDs
    }
}

enum PhotoGroupBuilder {
    static let defaultCaptureWindow: TimeInterval = 30

    /// 基础分组只依赖 Catalog 中已有的拍摄时间、来源目录和连续文件名，不读取文件，
    /// 也不调用视觉分析或 AI。只有至少两张连续照片才形成一个组。
    static func groups(
        in assets: [PhotoAsset],
        captureWindow: TimeInterval = defaultCaptureWindow
    ) -> [PhotoGroup] {
        let buckets = Dictionary(grouping: assets) { asset in
            PhotoGroupBucket(
                sourceID: asset.sourceID,
                directory: (asset.relativePath as NSString).deletingLastPathComponent.lowercased()
            )
        }

        var result: [PhotoGroup] = []
        for bucket in buckets.values {
            let ordered = bucket.sorted(by: groupOrder)
            var run: [PhotoAsset] = []

            for asset in ordered {
                if let previous = run.last,
                   isContinuous(previous, asset, captureWindow: captureWindow) {
                    run.append(asset)
                } else {
                    appendRun(run, to: &result)
                    run = [asset]
                }
            }
            appendRun(run, to: &result)
        }

        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return result.sorted { left, right in
            guard let leftID = left.assetIDs.first,
                  let rightID = right.assetIDs.first,
                  let leftAsset = assetByID[leftID],
                  let rightAsset = assetByID[rightID] else {
                return left.id.uuidString < right.id.uuidString
            }
            return groupOrder(leftAsset, rightAsset)
        }
    }

    private static func appendRun(_ run: [PhotoAsset], to groups: inout [PhotoGroup]) {
        guard run.count >= 2 else { return }
        groups.append(PhotoGroup(assetIDs: run.map(\.id)))
    }

    private static func isContinuous(
        _ left: PhotoAsset,
        _ right: PhotoAsset,
        captureWindow: TimeInterval
    ) -> Bool {
        guard let leftDate = left.captureDate,
              let rightDate = right.captureDate,
              abs(rightDate.timeIntervalSince(leftDate)) <= captureWindow,
              let leftSequence = filenameSequence(left.filename),
              let rightSequence = filenameSequence(right.filename),
              leftSequence.prefix == rightSequence.prefix else {
            return false
        }
        let sequenceDelta = rightSequence.number - leftSequence.number
        // RAW+JPEG 配对通常共享同一编号；它们与下一连续编号都属于同一拍摄序列。
        return sequenceDelta == 0 || sequenceDelta == 1
    }

    private static func filenameSequence(_ filename: String) -> (prefix: String, number: Int)? {
        let baseName = (filename as NSString).deletingPathExtension
        let digits = baseName.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty, let number = Int(String(digits)) else { return nil }
        let prefix = String(baseName.dropLast(digits.count)).lowercased()
        return (prefix, number)
    }

    private static func groupOrder(_ left: PhotoAsset, _ right: PhotoAsset) -> Bool {
        switch (left.captureDate, right.captureDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return left.filename.localizedStandardCompare(right.filename) == .orderedAscending
        }
    }
}

private struct PhotoGroupBucket: Hashable {
    let sourceID: UUID
    let directory: String
}

enum PhotoCompareSide: String, Sendable {
    case a
    case b
}

struct PhotoCompareState: Equatable, Sendable {
    let assetAID: UUID
    let assetBID: UUID
    private(set) var zoomScale: Double = 1
    private(set) var offsetX: Double = 0
    private(set) var offsetY: Double = 0
    private(set) var preferredSide: PhotoCompareSide?

    mutating func setZoomScale(_ scale: Double) {
        zoomScale = min(max(scale, 1), 8)
        if zoomScale == 1 {
            offsetX = 0
            offsetY = 0
        }
    }

    mutating func setOffset(x: Double, y: Double) {
        offsetX = x
        offsetY = y
    }

    mutating func resetTransform() {
        zoomScale = 1
        offsetX = 0
        offsetY = 0
    }

    mutating func select(_ side: PhotoCompareSide) {
        preferredSide = side
    }
}

enum PhotoCullingShortcut: Equatable, Sendable {
    case previous
    case next
    case rating(Int)
    case pick
    case reject
    case clearFlag
    case escape

    static func metadataShortcut(for characters: String) -> PhotoCullingShortcut? {
        switch characters.lowercased() {
        case "1", "2", "3", "4", "5":
            return Int(characters).map(PhotoCullingShortcut.rating)
        case "p": return .pick
        case "x": return .reject
        case "u": return .clearFlag
        default: return nil
        }
    }
}

enum PhotoCullingExportSelection: Sendable {
    case picks
    case fiveStars
    case currentResult
}

enum PhotoCullingExportSelector {
    static func assets(
        from assets: [PhotoAsset],
        selection: PhotoCullingExportSelection
    ) -> [PhotoAsset] {
        switch selection {
        case .picks:
            return assets.filter { $0.flag == .pick }
        case .fiveStars:
            return assets.filter { $0.rating == 5 }
        case .currentResult:
            return assets
        }
    }
}

/// Phase 17 快速筛选会话。上下文、当前位置和 Metadata 快照都只来自 Catalog；
/// 单张切换通过数组索引完成，不触发磁盘扫描或预览解码。
@MainActor
final class PhotoCullingSessionStore: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var currentAssetID: UUID?
    @Published private(set) var contextAssetIDs: [UUID] = []
    @Published private(set) var groups: [PhotoGroup] = []
    @Published private(set) var statistics = CullingStatistics.empty
    @Published private(set) var compareState: PhotoCompareState?

    private var currentIndex = 0
    private var indexByAssetID: [UUID: Int] = [:]
    private var groupIndexByAssetID: [UUID: Int] = [:]
    private var metadataByAssetID: [UUID: CullingMetadataState] = [:]

    var positionDescription: String {
        guard isPresented, !contextAssetIDs.isEmpty else { return "0 / 0" }
        return "\(currentIndex + 1) / \(contextAssetIDs.count)"
    }

    var currentGroup: PhotoGroup? {
        guard let currentAssetID,
              let groupIndex = groupIndexByAssetID[currentAssetID],
              groups.indices.contains(groupIndex) else {
            return nil
        }
        return groups[groupIndex]
    }

    var currentGroupDescription: String {
        guard let currentGroup,
              let currentAssetID,
              let itemIndex = currentGroup.assetIDs.firstIndex(of: currentAssetID) else {
            return "未成组"
        }
        return "连续组 \(itemIndex + 1) / \(currentGroup.assetIDs.count)"
    }

    func start(assets: [PhotoAsset], focusedAssetID: UUID?) {
        guard !assets.isEmpty else { return }
        contextAssetIDs = assets.map(\.id)
        indexByAssetID = Dictionary(uniqueKeysWithValues: contextAssetIDs.enumerated().map { ($0.element, $0.offset) })
        let requestedIndex = focusedAssetID.flatMap { indexByAssetID[$0] } ?? 0
        currentIndex = requestedIndex
        currentAssetID = contextAssetIDs[requestedIndex]
        metadataByAssetID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, CullingMetadataState(asset: $0)) })
        statistics = CullingStatistics(assets: assets)
        groups = PhotoGroupBuilder.groups(in: assets)
        groupIndexByAssetID = [:]
        for (groupIndex, group) in groups.enumerated() {
            for assetID in group.assetIDs {
                groupIndexByAssetID[assetID] = groupIndex
            }
        }
        compareState = nil
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        currentAssetID = nil
        contextAssetIDs = []
        groups = []
        statistics = .empty
        compareState = nil
        currentIndex = 0
        indexByAssetID = [:]
        groupIndexByAssetID = [:]
        metadataByAssetID = [:]
    }

    @discardableResult
    func move(offset: Int) -> UUID? {
        guard isPresented, compareState == nil, !contextAssetIDs.isEmpty else { return nil }
        let nextIndex = min(max(currentIndex + offset, 0), contextAssetIDs.count - 1)
        currentIndex = nextIndex
        currentAssetID = contextAssetIDs[nextIndex]
        return currentAssetID
    }

    func canMove(offset: Int) -> Bool {
        guard isPresented, compareState == nil else { return false }
        return contextAssetIDs.indices.contains(currentIndex + offset)
    }

    @discardableResult
    func perform(_ shortcut: PhotoCullingShortcut, catalog: CatalogStore) -> Bool {
        switch shortcut {
        case .previous:
            guard let assetID = move(offset: -1) else { return false }
            catalog.selectSingle(assetID: assetID)
        case .next:
            guard let assetID = move(offset: 1) else { return false }
            catalog.selectSingle(assetID: assetID)
        case let .rating(rating):
            guard let currentAssetID else { return false }
            let changed = catalog.setRating(rating, for: [currentAssetID])
            synchronizeMetadata(for: changed, catalog: catalog)
        case .pick:
            guard let currentAssetID else { return false }
            let changed = catalog.setFlag(.pick, for: [currentAssetID])
            synchronizeMetadata(for: changed, catalog: catalog)
        case .reject:
            guard let currentAssetID else { return false }
            let changed = catalog.setFlag(.reject, for: [currentAssetID])
            synchronizeMetadata(for: changed, catalog: catalog)
        case .clearFlag:
            guard let currentAssetID else { return false }
            let changed = catalog.setFlag(.none, for: [currentAssetID])
            synchronizeMetadata(for: changed, catalog: catalog)
        case .escape:
            dismiss()
        }
        return true
    }

    @discardableResult
    func beginCompare() -> Bool {
        guard compareState == nil,
              let currentAssetID,
              let candidateID = compareCandidate(for: currentAssetID),
              candidateID != currentAssetID else {
            return false
        }
        compareState = PhotoCompareState(assetAID: currentAssetID, assetBID: candidateID)
        return true
    }

    func finishCompare(focusPreferred: Bool = true) {
        guard let compareState else { return }
        let focusedID: UUID
        if focusPreferred {
            focusedID = compareState.preferredSide == .b ? compareState.assetBID : compareState.assetAID
        } else {
            focusedID = compareState.assetAID
        }
        if let index = indexByAssetID[focusedID] {
            currentIndex = index
            currentAssetID = focusedID
        }
        self.compareState = nil
    }

    func setCompareZoom(_ scale: Double) {
        compareState?.setZoomScale(scale)
    }

    func setCompareOffset(x: Double, y: Double) {
        compareState?.setOffset(x: x, y: y)
    }

    func resetCompareTransform() {
        compareState?.resetTransform()
    }

    @discardableResult
    func chooseCompareSide(_ side: PhotoCompareSide, catalog: CatalogStore) -> Bool {
        guard var compareState else { return false }
        let winnerID = side == .a ? compareState.assetAID : compareState.assetBID
        let loserID = side == .a ? compareState.assetBID : compareState.assetAID
        let changed = catalog.applyCompareDecision(winnerID: winnerID, loserID: loserID)
        synchronizeMetadata(for: changed, catalog: catalog)
        compareState.select(side)
        self.compareState = compareState
        return true
    }

    @discardableResult
    func undoLastOperation(catalog: CatalogStore) -> Bool {
        let changed = catalog.undoLastMetadataOperation()
        guard !changed.isEmpty else { return false }
        synchronizeMetadata(for: changed, catalog: catalog)
        if let compareState {
            // 撤销 A/B 选择时同时清除“首选”高亮，但保持当前比较配对。
            self.compareState = PhotoCompareState(
                assetAID: compareState.assetAID,
                assetBID: compareState.assetBID
            )
        }
        return true
    }

    func synchronizedAssets(catalog: CatalogStore) -> [PhotoAsset] {
        catalog.assets(withIDs: contextAssetIDs)
    }

    func synchronizeMetadata(for assetIDs: Set<UUID>, catalog: CatalogStore) {
        for assetID in assetIDs {
            guard let asset = catalog.asset(withID: assetID) else { continue }
            let newValue = CullingMetadataState(asset: asset)
            if let oldValue = metadataByAssetID[assetID] {
                statistics.replace(oldValue, with: newValue)
            }
            metadataByAssetID[assetID] = newValue
        }
    }

    private func compareCandidate(for assetID: UUID) -> UUID? {
        if let groupIndex = groupIndexByAssetID[assetID], groups.indices.contains(groupIndex) {
            let groupIDs = groups[groupIndex].assetIDs
            if let index = groupIDs.firstIndex(of: assetID) {
                if groupIDs.indices.contains(index + 1) { return groupIDs[index + 1] }
                if groupIDs.indices.contains(index - 1) { return groupIDs[index - 1] }
            }
        }
        if contextAssetIDs.indices.contains(currentIndex + 1) { return contextAssetIDs[currentIndex + 1] }
        if contextAssetIDs.indices.contains(currentIndex - 1) { return contextAssetIDs[currentIndex - 1] }
        return nil
    }
}
