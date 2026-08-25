# 优化待办清单

本文件记录 2026-08-26 对 `agent/phase-17-photo-culling` 分支所做的一次只读审查（UI/交互、代码质量、可用性与完成度）产出的可优化项，用于跟踪后续修复轮次。产品范围与阶段验收标准仍以 `PhotoAI-Mac-PLAN.md` / `plan.md` 为准；本文件不新增功能范围，只跟踪修复状态。

状态标记：`[ ]` 待处理 `[~]` 进行中 `[x]` 已完成

## 第一优先级（P0：功能性缺陷）

- [x] **快捷键与文本输入框冲突**：`AppCommands.swift` 将空格/方向键/`1-5`/`0`/`p`/`x`/`u`/`e`/`f` 注册为无修饰键菜单快捷键；`AppShellView.swift`（人物搜索、Apple Photos 筛选、颜色标签、备注等 `TextField`）聚焦时会被同名按键拦截，导致无法正常输入这些字符或用方向键移动光标。
  - 修复：在 `AppShellModel` 增加 `isTextInputActive`（第一响应者是否为文本输入框）；为人物搜索/重命名、全局搜索框、Apple Photos 筛选框、检查器的颜色标签/备注共 6 个 `TextField` 接入 `@FocusState` 并同步该状态；`AppCommands.swift` 中对应的无修饰键菜单项在文本输入激活时 `.disabled`，使按键事件正常回退到文本框。尚未在真实 `.app` 中做手动 UI 回归（本机 Swift 工具链为 6.3.3，仓库要求 6.4，无法在此环境编译），需要下一次有匹配 Xcode 的环境验证。
- [~] **快捷键双重实现**：←→ 1-5 P X U Esc 同时在 `AppCommands.swift`（菜单命令）与 `PhotoCullingView.swift`（`onExitCommand` + `onKeyPress`）各实现一套，Esc 可能被重复触发 `exitCurrentMode()`；应收敛为单一来源。
  - 已修复（Esc）：移除 `PhotoCullingView.swift` 中冗余的 `.onExitCommand { exitCurrentMode() }`，保留已 `return .handled` 的 `.onKeyPress(.escape)` 作为唯一 Esc 处理入口，避免比较模式下一次 Esc 同时退出比较视图又退出整个筛选会话。
  - 仍未收敛（←→ / 1-5 / P / X / U）：这些键在 `AppCommands.swift` 与 `PhotoCullingView.swift` 的 `onKeyPress` 中仍是两套实现。AppKit 先做菜单 key equivalent 匹配，因此实际生效的始终是菜单一路（`navigate(offset:)` / `applyCullingShortcut` 均转发到 `photoCulling.perform`，行为与视图版本一致，不会重复触发），视图内的处理器在有主菜单时是不可达分支。属代码质量问题而非功能缺陷，降级跟踪，待拆分/重构时一并收敛。

- [x] **文本输入状态易卡死（第一轮修复的加固）**：第一轮把 `isTextInputActive` 实现为单个 `Bool`，由 6 处 `TextField` 的 `@FocusState` 直接赋值，存在两个失效场景——(1) 聚焦状态下视图被销毁（切换侧边栏离开人物库、`⌘⌥I` 隐藏检查器、取消选中导致检查器 Section 消失、人物卡片滚出 `LazyVGrid`）时不会再收到 `false` 回调，状态永久停留在"输入中"，空格/方向键/1-5/P/X/U/F 等菜单项被持续禁用；(2) 焦点在两个输入框之间直接转移时，SwiftUI 不保证"旧框失焦"与"新框获焦"回调的先后顺序，若 `false` 后到会在输入过程中重新放行单键快捷键，退回原始 bug。
  - 修复：`AppShellModel` 改为 `@Published private(set) var activeTextInputs: Set<String>`，`isTextInputActive` 变为 `!activeTextInputs.isEmpty` 的计算属性；新增 `setTextInput(_:active:)` 与集中定义的 `TextInputField` 标识（人物卡片按 `person.id` 生成唯一标识）。6 处输入框改为按标识注册/注销，并各自补 `.onDisappear` 同步注销。集合语义使两种回调顺序都能收敛到正确终态。
  - 新增单测：`AppShellModelTests` 三个用例覆盖基本聚焦/失焦、跨输入框乱序回调、聚焦中视图销毁三条路径。

## 第二优先级（P1）

- [ ] **编辑器无逐步撤销**：`EditorView.swift` 仅有一次性"还原"，全局 Cmd+Z 只处理评分/Pick/Reject，不覆盖 `EditRecipe` 的曝光/裁剪/旋转调整，与应用其余模块的 Cmd+Z 心智模型不一致。
- [x] **核心快捷键可发现性弱**：←→ 1-5 P X U Esc 只在进入筛选模式时一次性 `announce`，无常驻速查图例。
  - 修复：新增 `KeyboardShortcutReference.swift` 作为键位说明的唯一数据源（`all` / `cullingEssentials` / `cullingAnnouncement`）；`PhotoCullingView` 底部增加常驻图例行；`SettingsView` 增加"快捷键"速查表；`AppCommands` 与 `AppShellView` 中两处重复的进入筛选模式播报文案改为引用同一来源。新增 `KeyboardShortcutReferenceTests` 4 个用例。
- [x] **图标按钮缺无障碍标签**：`PhotoCullingView.swift` 的星标/P/X/U 等核心按钮、`EditorView.swift`、`SettingsView.swift` 缺少 `accessibilityLabel`，VoiceOver 用户无法使用。
  - 修复：星标按钮补"设为 N 星"标签与 `.isSelected` 特征并归组为"星级评分"；P/X/U 补语义标签（"标记为 Pick / Reject"、"清除 Pick / Reject 标记"）并归组为"照片标记"；A/B 比较的放大/缩小图标按钮补标签；`EditorView` 胶片条缩略图按钮以文件名作标签并带选中特征；`SettingsView` 的 SDK 状态图标补"可用/不可用"。
- [ ] **`AppShellView.swift` 上帝文件**：2268 行内定义 27 个互不相关的 private view struct（侧边栏、人物库、Apple Photos 库、大图查看器、清理库等），应按功能拆分为独立文件。
- [ ] **AppKit 弹窗耦合进业务 Store**：`NSOpenPanel`/`NSSavePanel` 直接写在 `CatalogStore`、`BatchWorkflowStore`、`LUTStore`、`OriginalPhotoExportStore`、`ApplePhotosImportCoordinator`、`ExportCoordinator` 内部，导致"选文件夹/选导出目录"核心流程无法单元测试。
- [ ] **`ExportCoordinator` 无直接单测**：负责真实写盘的核心路径在 `Tests/PhotoAIMacTests/` 中无任何直接引用。
- [ ] **未签名未公证**：release 产物仅 ad-hoc 签名，无 Developer ID / Apple 公证，公网分发前 Gatekeeper 会拦截首次运行。

## 第三优先级（P2）

- [ ] **目录扫描无进度/取消**：`AppShellView.swift` 的"重新扫描"仅显示文字+旋转图标，无进度条/取消按钮（对比导出功能有完整 `ProgressView` + 取消）。
- [ ] **`CullingWorkflowStore`/`CleanupWorkflowStore` 状态机重复**：两者"可取消后台分析任务"模式（`start → detached task → catch CancellationError → catch Error`）几乎逐行重复，未抽象为公共基础设施。
- [ ] **`CullingWorkflowStore` 状态机测试空白**：`.analyzing/.complete/.failed` 转换与取消路径无测试；结构相同的 `BatchWorkflowStore` 已有专门取消测试，覆盖不对称。
- [x] **空 catch 块**：`ApplePhotosImportCoordinator.swift` 中 `try handle.close()` 的空 `catch {}` 静默吞异常。
  - 修复：`close()` 失败改为在没有更具体错误时向上抛出（缓冲未落盘意味着文件不完整，不能报告成功）。顺带修掉同一处更严重的问题：`dataReceivedHandler` 里的写盘失败此前只调用 `cancel()`，导致磁盘写满/权限不足被上层当成"用户取消"；现用 `recordWriteFailure` / `consumeWriteFailure` 记录真实原因并优先抛出。
- [ ] **命名不一致**：`PhotoFlag.reject` vs `LibraryFilter.rejected` 动词时态不一致；"Culling" 一词被后台批量分析（`CullingWorkflowStore`）与交互式筛选（`PhotoCullingSessionStore`）两套系统复用，易混淆。
- [ ] **`Settings` 功能单薄**：`SettingsView.swift` 仅约100行，无语言切换、缓存/存储管理、关于/版本信息、快捷键速查表；菜单无 Help 入口。
- [ ] **中英文术语混用**：菜单中 "Pick"/"Reject"/"RAW" 直接嵌入中文界面，无 i18n 基础设施。
- [ ] **View body 过大与魔法数字**：`AppShellView` 顶层 `body` 约300行、多层嵌套；`EditorView.swift`/`SettingsView.swift` 散落未常量化的尺寸数值。
- [ ] **开源许可证未确定**：`plan.md` Phase 13 遗留未勾选项，影响对外发布合规性。

## 验证缺口清单（非虚报，已在各 Phase 验收文档中如实标注 NOT RUN / BLOCKED）

- Apple Photos 各类真实权限态（拒绝/受限/仅 iCloud）、真实素材导入/取消/重命名、导入后重扫（Phase 11 / 15）。
- Phase 15 网格滚动/多选：`BLOCKED`（macOS 27 beta Accessibility 自动化管道故障）。
- Phase 16 / 17 真实 UI 导出文件夹选择：自动化用隔离临时目录代替，未做真实用户目录验证。
- Phase 17 的 3,000 张真实照片浏览：本机仅 922 项真实样本，未达标测试量。

## 修复轮次记录

- 第三轮（已完成代码修改，待编译/UI 回归）：
  - P1 核心快捷键可发现性：新增 `KeyboardShortcutReference` 单一数据源 + 筛选模式常驻图例 + 设置页速查表，并收敛两处重复播报文案。
  - P1 无障碍标签：`PhotoCullingView` / `EditorView` / `SettingsView` 的图标与单字母按钮补齐 `accessibilityLabel` 与选中特征。
  - P2 空 catch：`ApplePhotosImportCoordinator` 的 `close()` 失败与写盘失败均改为真实上报。
  - 涉及文件：`KeyboardShortcutReference.swift`（新增）、`PhotoCullingView.swift`、`SettingsView.swift`、`EditorView.swift`、`AppCommands.swift`、`AppShellView.swift`、`ApplePhotosImportCoordinator.swift`、`Tests/PhotoAIMacTests/KeyboardShortcutReferenceTests.swift`（新增）。
  - 已知限制：同样未编译（原因见第二轮）。图例行在窄窗口下的换行/截断表现、VoiceOver 实际播报顺序需在真实 `.app` 中确认。

- 第二轮（已完成代码修改，待编译/UI 回归）：
  - 加固第一轮的文本输入状态跟踪：`Bool` 改为标识集合（`activeTextInputs` + `setTextInput(_:active:)` + `TextInputField`），6 处输入框补 `.onDisappear` 注销，消除"状态卡在输入中导致单键快捷键全部失效"与"跨输入框回调乱序"两个隐患。
  - `AppShellModelTests` 增加 3 个用例覆盖上述路径。
  - 复核第一轮修复：6 处 `TextField` 已是全仓库全部文本输入控件（无 `TextEditor` / `SecureField` / `.searchable`）；全部无修饰键菜单项（空格、←→、1-5、0、P、X、U、E、F）均已接入禁用条件；唯一未接入的无修饰键项是 `Esc`（"关闭大图预览"），它本身已由 `!shell.isPhotoViewerPresented` 禁用，且大图预览态下无可聚焦输入框，无需处理。
  - 涉及文件：`AppShellModel.swift`、`AppShellView.swift`、`Tests/PhotoAIMacTests/AppShellModelTests.swift`。
  - 已知限制：本轮同样未能编译。开发机 Swift 工具链 6.3.3 低于 `Package.swift` 要求；本次会话可达的两个环境（设备侧 Linux VM、云端容器）均无 Swift 工具链，且 `download.swift.org` 被出口策略拦截，无法临时安装。`swift build` / `swift test` / 真实 UI 回归仍需在具备匹配 Xcode 的 macOS 环境补跑。

- 第一轮（已完成代码修改，待编译/UI 回归）：
  - 修复快捷键与文本输入框冲突（新增 `AppShellModel.isTextInputActive`，6 处 `TextField` 接入 `@FocusState`，`AppCommands.swift` 对应菜单项按状态禁用）。
  - 收敛 `PhotoCullingView.swift` 的 Esc 双重实现为单一 `onKeyPress(.escape)`。
  - 涉及文件：`AppShellModel.swift`、`AppShellView.swift`、`AppCommands.swift`、`PhotoCullingView.swift`。
  - 已知限制：本机 Swift 工具链为 6.3.3，仓库 `Package.swift` 要求 6.4，`swift build`/`swift test` 未能在本环境执行；需要在具备匹配 Xcode（如 README 提到的 Xcode 27 beta）的环境中补跑 `swift build`、`swift test` 与真实 UI 回归后再合并。
