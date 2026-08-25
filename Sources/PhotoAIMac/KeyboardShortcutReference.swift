import Foundation

/// 快捷键速查的唯一数据源：快速筛选模式的常驻图例与设置页的速查表都从这里取值，
/// 避免键位说明散落在 `announce` 文案、`help` 提示与文档中各写一份而互相漂移。
/// 新增或调整 `AppCommands` / `PhotoCullingView` 中的键位时，请同步更新本表。
struct KeyboardShortcutReference: Identifiable, Hashable, Sendable {
    /// 显示用的键位文本，例如 `← →`、`⌘⇧K`。
    let keys: String
    /// 该键位执行的动作描述。
    let action: String
    /// 是否属于快速筛选模式的核心键位（决定是否出现在筛选模式底部的紧凑图例中）。
    let isCullingEssential: Bool

    var id: String { keys }

    init(keys: String, action: String, isCullingEssential: Bool = false) {
        self.keys = keys
        self.action = action
        self.isCullingEssential = isCullingEssential
    }
}

extension KeyboardShortcutReference {
    static let all: [KeyboardShortcutReference] = [
        KeyboardShortcutReference(keys: "← →", action: "上一张 / 下一张", isCullingEssential: true),
        KeyboardShortcutReference(keys: "1–5", action: "设置星级", isCullingEssential: true),
        KeyboardShortcutReference(keys: "0", action: "清除评分", isCullingEssential: true),
        KeyboardShortcutReference(keys: "P", action: "标记 Pick", isCullingEssential: true),
        KeyboardShortcutReference(keys: "X", action: "标记 Reject", isCullingEssential: true),
        KeyboardShortcutReference(keys: "U", action: "清除标记", isCullingEssential: true),
        KeyboardShortcutReference(keys: "Esc", action: "退出比较 / 退出快速筛选", isCullingEssential: true),
        KeyboardShortcutReference(keys: "空格", action: "大图预览 / 返回图库"),
        KeyboardShortcutReference(keys: "F", action: "切换收藏"),
        KeyboardShortcutReference(keys: "E", action: "打开编辑器"),
        KeyboardShortcutReference(keys: "⌘Z", action: "撤销上一次评分或标记"),
        KeyboardShortcutReference(keys: "⌘⇧K", action: "进入 / 退出快速筛选"),
        KeyboardShortcutReference(keys: "⌘A", action: "全选当前结果"),
        KeyboardShortcutReference(keys: "⌘1–⌘4", action: "所有照片 / 最近导入 / 收藏 / RAW"),
        KeyboardShortcutReference(keys: "⌘⌥I", action: "显示 / 隐藏检查器"),
        KeyboardShortcutReference(keys: "⌘⇧O", action: "添加照片文件夹…"),
        KeyboardShortcutReference(keys: "⌘⇧R", action: "重新扫描当前来源"),
        KeyboardShortcutReference(keys: "⌘⌥C", action: "复制调整"),
        KeyboardShortcutReference(keys: "⌘⌥V", action: "粘贴调整"),
        KeyboardShortcutReference(keys: "⌘⌥S", action: "同步调整")
    ]

    /// 快速筛选模式的核心键位，用于常驻图例与进入模式时的一次性播报。
    static var cullingEssentials: [KeyboardShortcutReference] {
        all.filter(\.isCullingEssential)
    }

    /// 供 VoiceOver 播报与 `announce` 复用的单条文本。
    var spokenDescription: String { "\(keys)：\(action)" }

    /// 进入快速筛选模式时的一次性播报文案。
    static var cullingAnnouncement: String {
        "快速筛选模式：" + cullingEssentials.map(\.spokenDescription).joined(separator: "，") + "。"
    }
}
