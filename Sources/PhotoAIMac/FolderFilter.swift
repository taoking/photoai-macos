import Foundation

/// 图库的文件夹维度筛选。
///
/// 与 `DateBucket` 一样是正交筛选：文件夹决定"看哪一批导入的照片"，
/// 日期决定"看哪一段时间"，`LibraryFilter` 决定"看其中的哪些"，三者可以同时生效。
/// 这正是"打完分之后既能按文件夹也能按星级找回来"所依赖的。
struct FolderFilter: Hashable, Sendable {
    let sourceID: UUID
    /// 相对来源根目录的子目录，不含结尾斜杠；根目录为空串。
    let directory: String

    func matches(_ asset: PhotoAsset) -> Bool {
        asset.sourceID == sourceID && Self.directory(of: asset.relativePath) == directory
    }

    /// 取相对路径的目录部分。`2026/新疆/DSC1.ARW` → `2026/新疆`，`DSC1.ARW` → `""`。
    static func directory(of relativePath: String) -> String {
        guard let index = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[relativePath.startIndex..<index])
    }
}

/// 侧边栏「按文件夹」一节里的一个来源，及其下的目录。
struct FolderSection: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let count: Int
    let folders: [FolderEntry]

    var id: UUID { sourceID }
}

struct FolderEntry: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let directory: String
    let count: Int

    var id: String { "\(sourceID.uuidString)/\(directory)" }
    var filter: FolderFilter { FolderFilter(sourceID: sourceID, directory: directory) }

    /// 根目录没有名字，显示成来源自身。
    var title: String { directory.isEmpty ? "（根目录）" : directory }
}

enum FolderSectionBuilder {
    /// 按来源与目录归类并统计数量。
    ///
    /// 与日期一样一次扫描算完：侧边栏每行现算一次会把整个资产表扫很多遍。
    static func sections(for assets: [PhotoAsset], sources: [PhotoSource]) -> [FolderSection] {
        var countsByDirectory: [UUID: [String: Int]] = [:]
        for asset in assets {
            let directory = FolderFilter.directory(of: asset.relativePath)
            countsByDirectory[asset.sourceID, default: [:]][directory, default: 0] += 1
        }

        return sources.compactMap { source in
            guard let directories = countsByDirectory[source.id], !directories.isEmpty else {
                return nil
            }
            let entries = directories
                .map { FolderEntry(sourceID: source.id, directory: $0.key, count: $0.value) }
                .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
            return FolderSection(
                sourceID: source.id,
                sourceName: source.displayName,
                count: entries.reduce(0) { $0 + $1.count },
                folders: entries
            )
        }
    }
}
