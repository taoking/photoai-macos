# 优化待办清单

本文件记录 2026-08-26 对 `agent/phase-17-photo-culling` 分支所做的一次只读审查（UI/交互、代码质量、可用性与完成度）产出的可优化项，用于跟踪后续修复轮次。产品范围与阶段验收标准仍以 `PhotoAI-Mac-PLAN.md` / `plan.md` 为准；本文件不新增功能范围，只跟踪修复状态。

状态标记：`[ ]` 待处理 `[~]` 进行中 `[x]` 已完成

## 第一优先级（P0：功能性缺陷）

- [x] **快捷键与文本输入框冲突**：`AppCommands.swift` 将空格/方向键/`1-5`/`0`/`p`/`x`/`u`/`e`/`f` 注册为无修饰键菜单快捷键；`AppShellView.swift`（人物搜索、Apple Photos 筛选、颜色标签、备注等 `TextField`）聚焦时会被同名按键拦截，导致无法正常输入这些字符或用方向键移动光标。
  - 修复：在 `AppShellModel` 增加 `isTextInputActive`（第一响应者是否为文本输入框）；为人物搜索/重命名、全局搜索框、Apple Photos 筛选框、检查器的颜色标签/备注共 6 个 `TextField` 接入 `@FocusState` 并同步该状态；`AppCommands.swift` 中对应的无修饰键菜单项在文本输入激活时 `.disabled`，使按键事件正常回退到文本框。尚未在真实 `.app` 中做手动 UI 回归（本机 Swift 工具链为 6.3.3，仓库要求 6.4，无法在此环境编译），需要下一次有匹配 Xcode 的环境验证。
- [x] **快捷键双重实现**：←→ 1-5 P X U Esc 同时在 `AppCommands.swift`（菜单命令）与 `PhotoCullingView.swift`（`onExitCommand` + `onKeyPress`）各实现一套，Esc 可能被重复触发 `exitCurrentMode()`；应收敛为单一来源。
  - 修复：移除 `PhotoCullingView.swift` 中冗余的 `.onExitCommand { exitCurrentMode() }`，保留已 `return .handled` 的 `.onKeyPress(.escape)` 作为唯一 Esc 处理入口，避免比较模式下一次 Esc 同时退出比较视图又退出整个筛选会话。

## 第二优先级（P1）

- [ ] **编辑器无逐步撤销**：`EditorView.swift` 仅有一次性"还原"，全局 Cmd+Z 只处理评分/Pick/Reject，不覆盖 `EditRecipe` 的曝光/裁剪/旋转调整，与应用其余模块的 Cmd+Z 心智模型不一致。
- [ ] **核心快捷键可发现性弱**：←→ 1-5 P X U Esc 只在进入筛选模式时一次性 `announce`，无常驻速查图例。
- [ ] **图标按钮缺无障碍标签**：`PhotoCullingView.swift` 的星标/P/X/U 等核心按钮、`EditorView.swift`、`SettingsView.swift` 缺少 `accessibilityLabel`，VoiceOver 用户无法使用。
- [ ] **`AppShellView.swift` 上帝文件**：2268 行内定义 27 个互不相关的 private view struct（侧边栏、人物库、Apple Photos 库、大图查看器、清理库等），应按功能拆分为独立文件。
- [ ] **AppKit 弹窗耦合进业务 Store**：`NSOpenPanel`/`NSSavePanel` 直接写在 `CatalogStore`、`BatchWorkflowStore`、`LUTStore`、`OriginalPhotoExportStore`、`ApplePhotosImportCoordinator`、`ExportCoordinator` 内部，导致"选文件夹/选导出目录"核心流程无法单元测试。
- [ ] **`ExportCoordinator` 无直接单测**：负责真实写盘的核心路径在 `Tests/PhotoAIMacTests/` 中无任何直接引用。
- [ ] **未签名未公证**：release 产物仅 ad-hoc 签名，无 Developer ID / Apple 公证，公网分发前 Gatekeeper 会拦截首次运行。

## 第三优先级（P2）

- [ ] **目录扫描无进度/取消**：`AppShellView.swift` 的"重新扫描"仅显示文字+旋转图标，无进度条/取消按钮（对比导出功能有完整 `ProgressView` + 取消）。
- [ ] **`CullingWorkflowStore`/`CleanupWorkflowStore` 状态机重复**：两者"可取消后台分析任务"模式（`start → detached task → catch CancellationError → catch Error`）几乎逐行重复，未抽象为公共基础设施。
- [ ] **`CullingWorkflowStore` 状态机测试空白**：`.analyzing/.complete/.failed` 转换与取消路径无测试；结构相同的 `BatchWorkflowStore` 已有专门取消测试，覆盖不对称。
- [ ] **空 catch 块**：`ApplePhotosImportCoordinator.swift` 中 `try handle.close()` 的空 `catch {}` 静默吞异常。
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

- 第一轮（已完成代码修改，待编译/UI 回归）：
  - 修复快捷键与文本输入框冲突（新增 `AppShellModel.isTextInputActive`，6 处 `TextField` 接入 `@FocusState`，`AppCommands.swift` 对应菜单项按状态禁用）。
  - 收敛 `PhotoCullingView.swift` 的 Esc 双重实现为单一 `onKeyPress(.escape)`。
  - 涉及文件：`AppShellModel.swift`、`AppShellView.swift`、`AppCommands.swift`、`PhotoCullingView.swift`。
  - 已知限制：本机 Swift 工具链为 6.3.3，仓库 `Package.swift` 要求 6.4，`swift build`/`swift test` 未能在本环境执行；需要在具备匹配 Xcode（如 README 提到的 Xcode 27 beta）的环境中补跑 `swift build`、`swift test` 与真实 UI 回归后再合并。
