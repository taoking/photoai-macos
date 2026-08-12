import Foundation

/// 相似度比较所需的最小索引。`visualHash` 是低分辨率视觉指纹，而非原图内容哈希。
struct SimilarityCandidate: Hashable, Sendable {
    let assetID: UUID
    let captureDate: Date?
    let visualHash: UInt64
}

struct SimilarityCandidatePair: Hashable, Sendable {
    let firstID: UUID
    let secondID: UUID

    init(_ firstID: UUID, _ secondID: UUID) {
        if firstID.uuidString.localizedStandardCompare(secondID.uuidString) == .orderedAscending {
            self.firstID = firstID
            self.secondID = secondID
        } else {
            self.firstID = secondID
            self.secondID = firstID
        }
    }
}

struct SimilarityCandidatePlan: Sendable {
    struct Statistics: Equatable, Sendable {
        let assetCount: Int
        let allLibraryPairCount: Int64
        let directLinkCount: Int
        let candidatePairCount: Int
        let oversizedBucketCount: Int
        let undatedAssetCount: Int
    }

    /// 完全相同的视觉 hash 可在线性时间内连成链，不需要成对比较。
    let directLinks: [SimilarityCandidatePair]
    /// 调用方仍须检查时间距离和汉明距离；这里只负责有界地缩小候选集。
    let candidatePairs: [SimilarityCandidatePair]
    let statistics: Statistics
}

/// 为 Cleanup 与 Culling 共用的候选规划器。
///
/// - 有拍摄时间：按日窗口与 7 个哈希分段桶产生候选；距离不超过 6 的 64-bit hash
///   至少有一个分段完全相同，因此常规桶不会漏掉这种候选。
/// - 无拍摄时间：只把完全相同的视觉 hash 连成线性链，绝不退化为全库两两比较。
/// - 极大单桶：改为哈希排序后的固定邻域扫描，优先保证交互式工具不会被异常 burst 拖成 O(n²)。
enum SimilarityCandidatePlanner {
    static let captureWindow: TimeInterval = 86_400

    private static let secondsPerDay: TimeInterval = 86_400
    private static let fullComparisonBucketLimit = 96
    private static let oversizedBucketNeighborCount = 12
    // 64 位被拆为 7 段。最多 6 个 bit 改变时，至少有 1 段保持不变。
    private static let segmentBitCounts = [10, 9, 9, 9, 9, 9, 9]

    static func plan(for candidates: [SimilarityCandidate]) -> SimilarityCandidatePlan {
        let ordered = candidates.sorted(by: stableOrder)
        let allLibraryPairCount = Int64(ordered.count) * Int64(max(0, ordered.count - 1)) / 2
        guard ordered.count > 1 else {
            return SimilarityCandidatePlan(
                directLinks: [],
                candidatePairs: [],
                statistics: .init(
                    assetCount: ordered.count,
                    allLibraryPairCount: allLibraryPairCount,
                    directLinkCount: 0,
                    candidatePairCount: 0,
                    oversizedBucketCount: 0,
                    undatedAssetCount: ordered.filter { $0.captureDate == nil }.count
                )
            )
        }

        var directLinks = Set<SimilarityCandidatePair>()
        let byExactHash = Dictionary(grouping: ordered, by: \.visualHash)
        for group in byExactHash.values {
            appendExactHashLinks(group, to: &directLinks)
        }

        var buckets: [BucketKey: [SimilarityCandidate]] = [:]
        for candidate in ordered where candidate.captureDate != nil {
            let day = dayBucket(for: candidate.captureDate!)
            for segment in segmentBitCounts.indices {
                let key = BucketKey(day: day, segment: segment, value: segmentValue(candidate.visualHash, at: segment))
                buckets[key, default: []].append(candidate)
            }
        }

        var candidatePairs = Set<SimilarityCandidatePair>()
        var oversizedBucketCount = 0
        for key in buckets.keys.sorted(by: bucketOrder) {
            let current = buckets[key, default: []]
            appendBoundedPairs(
                current,
                to: &candidatePairs,
                oversizedBucketCount: &oversizedBucketCount
            )

            let nextDayKey = BucketKey(day: key.day + 1, segment: key.segment, value: key.value)
            if let nextDay = buckets[nextDayKey] {
                appendBoundedPairs(
                    current + nextDay,
                    to: &candidatePairs,
                    oversizedBucketCount: &oversizedBucketCount
                )
            }
        }

        // 同 hash 已由 directLinks 处理；让调用方只对真正需要汉明距离计算的 pair 工作。
        let hashByAssetID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.assetID, $0.visualHash) })
        candidatePairs = candidatePairs.filter { pair in
            guard let firstHash = hashByAssetID[pair.firstID],
                  let secondHash = hashByAssetID[pair.secondID] else {
                return false
            }
            return firstHash != secondHash
        }

        return SimilarityCandidatePlan(
            directLinks: directLinks.sorted(by: pairOrder),
            candidatePairs: candidatePairs.sorted(by: pairOrder),
            statistics: .init(
                assetCount: ordered.count,
                allLibraryPairCount: allLibraryPairCount,
                directLinkCount: directLinks.count,
                candidatePairCount: candidatePairs.count,
                oversizedBucketCount: oversizedBucketCount,
                undatedAssetCount: ordered.filter { $0.captureDate == nil }.count
            )
        )
    }

    private static func appendExactHashLinks(
        _ group: [SimilarityCandidate],
        to links: inout Set<SimilarityCandidatePair>
    ) {
        let dated = group.compactMap { candidate -> SimilarityCandidate? in
            candidate.captureDate == nil ? nil : candidate
        }.sorted {
            guard let left = $0.captureDate, let right = $1.captureDate else { return stableOrder($0, $1) }
            if left != right { return left < right }
            return stableOrder($0, $1)
        }
        for (left, right) in zip(dated, dated.dropFirst()) {
            if capturesAreNear(left.captureDate, right.captureDate) {
                links.insert(SimilarityCandidatePair(left.assetID, right.assetID))
            }
        }

        // 没有拍摄时间时，没有可靠的时间窗口；仅对完全相同 hash 建立线性关系。
        let undated = group.filter { $0.captureDate == nil }.sorted(by: stableOrder)
        for (left, right) in zip(undated, undated.dropFirst()) {
            links.insert(SimilarityCandidatePair(left.assetID, right.assetID))
        }
    }

    private static func appendBoundedPairs(
        _ input: [SimilarityCandidate],
        to result: inout Set<SimilarityCandidatePair>,
        oversizedBucketCount: inout Int
    ) {
        let candidates = input.sorted {
            if $0.visualHash != $1.visualHash { return $0.visualHash < $1.visualHash }
            return stableOrder($0, $1)
        }
        guard candidates.count > 1 else { return }

        if candidates.count <= fullComparisonBucketLimit {
            for index in candidates.indices {
                for later in candidates.indices.dropFirst(index + 1) {
                    let left = candidates[index]
                    let right = candidates[later]
                    guard left.visualHash != right.visualHash else { continue }
                    result.insert(SimilarityCandidatePair(left.assetID, right.assetID))
                }
            }
            return
        }

        oversizedBucketCount += 1
        for index in candidates.indices {
            let upperBound = min(candidates.index(index, offsetBy: oversizedBucketNeighborCount, limitedBy: candidates.endIndex) ?? candidates.endIndex, candidates.endIndex)
            for later in candidates.indices.dropFirst(index + 1).prefix(upperBound - candidates.index(after: index)) {
                let left = candidates[index]
                let right = candidates[later]
                guard left.visualHash != right.visualHash else { continue }
                result.insert(SimilarityCandidatePair(left.assetID, right.assetID))
            }
        }
    }

    private static func dayBucket(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / secondsPerDay).rounded(.down))
    }

    private static func segmentValue(_ hash: UInt64, at segment: Int) -> UInt16 {
        let shift = segmentBitCounts.prefix(segment).reduce(0, +)
        let width = segmentBitCounts[segment]
        let mask = (UInt64(1) << UInt64(width)) - 1
        return UInt16((hash >> UInt64(shift)) & mask)
    }

    private static func capturesAreNear(_ left: Date?, _ right: Date?) -> Bool {
        guard let left, let right else { return false }
        return abs(left.timeIntervalSince(right)) <= captureWindow
    }

    private static func stableOrder(_ left: SimilarityCandidate, _ right: SimilarityCandidate) -> Bool {
        left.assetID.uuidString.localizedStandardCompare(right.assetID.uuidString) == .orderedAscending
    }

    private static func pairOrder(_ left: SimilarityCandidatePair, _ right: SimilarityCandidatePair) -> Bool {
        let firstOrder = left.firstID.uuidString.localizedStandardCompare(right.firstID.uuidString)
        if firstOrder != .orderedSame { return firstOrder == .orderedAscending }
        return left.secondID.uuidString.localizedStandardCompare(right.secondID.uuidString) == .orderedAscending
    }

    private static func bucketOrder(_ left: BucketKey, _ right: BucketKey) -> Bool {
        if left.day != right.day { return left.day < right.day }
        if left.segment != right.segment { return left.segment < right.segment }
        return left.value < right.value
    }

    private struct BucketKey: Hashable {
        let day: Int64
        let segment: Int
        let value: UInt16
    }
}

/// 以线性空间收集“相似”连边对应的连通分量，避免为每个相似 pair 生成一条重复推荐。
struct SimilarityComponentBuilder {
    private var parent: [UUID: UUID]
    private var rank: [UUID: Int] = [:]

    init<S: Sequence>(assetIDs: S) where S.Element == UUID {
        parent = Dictionary(uniqueKeysWithValues: assetIDs.map { ($0, $0) })
    }

    mutating func connect(_ first: UUID, _ second: UUID) {
        guard parent[first] != nil, parent[second] != nil else { return }
        let firstRoot = root(of: first)
        let secondRoot = root(of: second)
        guard firstRoot != secondRoot else { return }

        let firstRank = rank[firstRoot, default: 0]
        let secondRank = rank[secondRoot, default: 0]
        if firstRank < secondRank {
            parent[firstRoot] = secondRoot
        } else if firstRank > secondRank {
            parent[secondRoot] = firstRoot
        } else {
            parent[secondRoot] = firstRoot
            rank[firstRoot] = firstRank + 1
        }
    }

    mutating func groups() -> [[UUID]] {
        var result: [UUID: [UUID]] = [:]
        for assetID in parent.keys {
            result[root(of: assetID), default: []].append(assetID)
        }
        return result.values.map { $0.sorted { $0.uuidString.localizedStandardCompare($1.uuidString) == .orderedAscending } }
    }

    private mutating func root(of assetID: UUID) -> UUID {
        guard let parentID = parent[assetID], parentID != assetID else { return assetID }
        let resolved = root(of: parentID)
        parent[assetID] = resolved
        return resolved
    }
}
