import Foundation

/// 手工维护的选片集。
///
/// 它解决的是一个很具体的问题：照片多到一次框选不完时，需要分多次把选中的照片
/// 累积到同一处。因此它只有一级、不嵌套，成员关系是纯粹的引用——
/// 加入、移除、删除选片集都不会碰原始文件，也不会改动照片自身的评分与标记。
///
/// 与「收藏」的区别：收藏是照片的一个属性（每张照片只有一个开关），
/// 选片集是任意多个可命名的集合，一张照片可以同时属于多个。
struct PhotoCollection: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    /// 侧边栏按名称排序：这是手工维护的列表，按名字找比按创建时间找容易。
    static func isOrderedBefore(_ lhs: PhotoCollection, _ rhs: PhotoCollection) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.createdAt < rhs.createdAt
    }

    /// 去掉首尾空白后是否还是一个可用的名字。
    static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
