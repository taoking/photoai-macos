# Phase 15 验收记录 — Apple Photos 系统相册接入

日期：2026-08-24
开发环境：macOS 27 Golden Gate beta / Xcode 27 beta（macOS 27 SDK）

## 设计与安全边界

- Apple Photos 保持独立的内存模型：主身份为 `PHAsset.localIdentifier`，不创建假的文件系统路径，也不会写入 `catalog.json`。
- 应用启动只读取当前授权状态；不会请求权限、枚举图库、请求缩略图或下载 iCloud 原件。系统授权只由“授权并读取 Apple Photos”按钮触发。
- Xcode 27 SDK 中可读取图库的公开访问级别为 `PHAccessLevel.readWrite`；`addOnly` 不能浏览。实现只调用查询和读取 API，没有 `performChanges`、`PHAssetChangeRequest` 或相簿变更 API。
- 浏览的缩略图和预览通过 `PHCachingImageManager` / `PHImageManager` 按可见 Cell 或单个选中项惰性请求，缩略图预热窗口最多保留 96 项；请求均显式 `isNetworkAccessAllowed = false`。初始元数据枚举不做逐资产 iCloud 探测。
- 大图库网格使用 240 项首屏与“显示更多”的渐进加载；筛选仍对完整内存元数据集执行，选择范围只覆盖当前已展示的项目，避免把完整 ID 列表复制到每个 Cell。
- 只有用户点击“导入到 PhotoAI…”并选择目标文件夹后，才对所选资源使用 `PHAssetResourceManager.requestData` 且设为 `isNetworkAccessAllowed = true`。导入并发限制为 2，可取消，文件名冲突使用 `-2`、`-3` 后缀，绝不覆盖现有文件。
- 导入保留原始资源：RAW+JPEG 同时导入，Live Photo 导入静态照片及配对视频，普通视频导入原始视频。仅在没有可用原始资源时才会导入明确标记的全尺寸回退资源。
- 文件真正写入后才调用本地 `CatalogStore.addFolder` 进行扫描；导入前不会创建 `PhotoAsset`，也不会自动触发 OCR、人物、清理、选片或编辑。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift build` | 通过。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift test` | 通过，70 tests / 15 suites；真实 Sony RAW 集成测试按既有条件显式 `SKIPPED`。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，70 tests / 15 suites；测试日志含既有 Xcode beta E5/运行时警告，但没有失败。 |
| `rg -n "availability\\(for: asset\\)|isSynchronous|requestImage\\(|isNetworkAccessAllowed|requestData\\(|writeData\\(" Sources/PhotoAIMac/ApplePhotos*.swift` | 代码审查通过：没有初始全图库同步 iCloud 探测；浏览查询均禁止网络，只有显式导入资源的路径允许网络。 |
| `rg -n "PHPhotoLibrary|PHAssetChangeRequest|PHAssetCollectionChangeRequest|performChanges" Sources/PhotoAIMac/ApplePhotos*.swift` | 代码审查通过：仅有授权状态/授权请求；无 PhotoKit 写入或修改 API。 |
| `git diff --check` | 通过。 |

自动测试覆盖：授权状态、初始 Store 不请求权限、资源模型、收藏/视频/RAW/日期筛选、单选/Command 多选/Shift 范围选择、冲突安全命名、RAW+JPEG、Live Photo、视频与回退资源规划、取消状态、导入结果汇总及双并发限制；以及本轮新增的本地缩略图失败状态、人物预览失败状态和快速相簿切换 Latest Selection Wins。

## Final Fix 性能与竞态回归

- 本地缩略图的完成状态只由可见订阅 Cell 的 `@State` 更新；`ThumbnailStore.completedKeys` 保持为非 `@Published`，不会因单张缩略图完成广播重绘整个网格。加载返回 `nil` 时，本地图库与人物预览均显示 `photo.badge.exclamationmark`，不再永久显示 `ProgressView`。
- Apple Photos 相簿加载在每次请求时取消前一任务并递增 generation；只有 generation、当前 Picker 相簿和授权状态均匹配时才会应用结果。自动测试覆盖“B 慢、C 快、B 后返回”的过期结果丢弃。
- Apple Photos 的预热判重现在发生在 `PHAsset` 查询之前；同一资产与尺寸已经预热时，不会再次执行不必要的 `PHAsset.fetchAssets(withLocalIdentifiers:)`。

| 人工性能回归场景 | 真实结果 |
| --- | --- |
| 本地 Catalog | 922 张照片。 |
| 连续侧栏切换 | 10 轮：搜索 → 人物 → 所有照片 → 清理 → Apple Photos → 搜索 → 人物 → 所有照片 → 清理 → 所有照片；所有目标页均保持响应。 |
| 缩略图失败呈现 | PASS：人物页实际出现损坏/不可用缩略图时，显示稳定的 `photo.badge.exclamationmark` 占位，而非持续 Spinner。 |
| 切换完成后 CPU | 0.0%。 |
| 主线程采样 | 正常 AppKit/SwiftUI 事件循环，阻塞在等待下一事件；无持续 busy loop 或持续高 CPU。 |

以上是当前测试机器、macOS 27 Golden Gate beta 与 922 张本地 Catalog 下的人工回归结果，不构成绝对性能承诺。

## 编辑器返回图库回归

- 复核本机 `catalog.json`：仍有 922 项，两个本地来源均为 `ready` 且目录存在；问题不是 Catalog 数据丢失。
- 以系统 ImageIO（`sips`）直接解码代表性 JPEG 与 Sony ARW，二者均返回 `4608 × 3072`，确认源文件继续可读。
- 编辑器改为覆盖仍存活的图库视图树，而不是替换整个详情区域；完成调色后，现有的可见 Cell、缩略图订阅和内存缓存不会被销毁重建。
- 新增 `editingRoundTripPreservesTheCurrentLibraryDestination`，确保进入与退出编辑器不会改变“所有照片”目标页。
- 编辑器退出时，`ThumbnailStore` 只递增一次 `visibleSubscriberGeneration`；仍可见的 `CatalogAssetCell` 会从内存缓存恢复，或重新订阅已经在跑的解码请求。这针对 macOS beta 上覆盖层退出后可能遗漏 `onAppear` 的情况，且没有把每张缩略图完成事件恢复为 `@Published` 全局刷新。
- `CatalogAssetCell` 绘制时也直接检查内存缓存；若 macOS beta 在覆盖层切换中丢失 Cell 的局部 `@State`，已解码缩略图仍会立即显示，而不会退化为空白占位。测试覆盖已加载状态保留其图像供该展示回退路径使用。
- 侧边栏改为明确的返回导航：编辑器打开时选择任一目标页会退出编辑器。新增模型测试覆盖该语义，并测试一次编辑器返回只发出一次可见缩略图刷新信号。
- 使用本地辅助功能控制完成真实 `DSC01872.JPG` 的“选择 → 编辑器 → 完成”往返；回到 922 项“所有照片”网格后，可见 JPEG、RAW 缩略图均正常显示，选中状态与来源元数据仍在。该验证未请求或修改 Apple Photos 权限。

## 人工 UI 验证

| 场景 | 状态 | 结果 |
| --- | --- | --- |
| 未授权启动 | PASS | 打开调试 App 的 Apple Photos 页面，显示“授权并读取 Apple Photos”；未点击该按钮，未出现权限提示，导入按钮禁用。 |
| 未授权界面 | PASS | 显示浏览/相簿/日期/文件名筛选控件、零项目计数、明确的下一步及无网络 Preview 说明。 |
| 授权成功 | PASS | 用户明确允许后，调试 App 显示“已获 Apple Photos 完整访问权限”。 |
| 拒绝 / Restricted / Limited | NOT RUN | 需要受控系统权限状态后复测。 |
| 加载全部照片 | PASS | 在真实系统相册中读取 35,214 项元数据；初始读取不下载 iCloud 原件。 |
| 大图库渐进网格 | PASS | 显示 240 / 35,214 项首屏和“显示更多”操作，避免整库一次性物化为 Cell。 |
| 文件名筛选 | PASS | `IMG_5903` 从 35,214 项收敛为 3 项，结果均标为本地可用；筛选后网格正常更新。 |
| 相簿 / 收藏 / 视频 / RAW | NOT RUN | 需要有代表性的受控 Apple Photos 测试素材后复测。 |
| Live Photo 标识 | PASS | 真实相册首屏项目显示 Live Photo 标识；静态/配对资源保留逻辑另有自动化测试。 |
| Grid 滚动 / Command、Shift 多选 / 屏幕预览 | BLOCKED | 单选动作后，macOS 27 beta 上的 Computer Use Accessibility 管道关闭；PhotoAI Mac 进程继续运行、无新崩溃报告，采样显示主线程空闲。已通过纯模型测试覆盖选择语义，但未把真实预览标为通过。 |
| iCloud-only 浏览不下载 | NOT RUN | 代码已明确关闭浏览网络；仍需真实仅云端项目复测。 |
| 显式导入 iCloud 原件、取消、重名 | NOT RUN | 需要用户选择测试目录及受控相册素材后复测。 |
| 导入后 Catalog Rescan / Phase 14 Archive | NOT RUN | Phase 14 PR #2 在本阶段基线的 `main` 上尚未合并；本实现完成 Catalog 接入，待合并后的 Archive 工作流复测。 |
| 快速连续切换真实 Apple Photos 相簿 | NOT RUN | 本轮调试 App 当前为未授权状态；没有为自动化验收触发新的系统照片权限申请。最新选择优先逻辑由纯模型测试覆盖；待用户授权后按“全部照片 → 相簿 A → 相簿 B → 全部照片”复测 Picker、计数与 Grid 一致性。 |

## Gate

### Phase 15 Code Gate：**PASS**

Final Fix 代码条件已满足：损坏缩略图不再永久 Spinner、人物预览有稳定失败占位、`completedKeys` 未恢复全局发布、相簿请求使用取消与 generation 双重 Latest Selection Wins 保护、预热先判重、原有侧栏性能修复仍保留，且本地 build、Swift Testing、xcodebuild 测试和 `git diff --check` 均通过。

### Phase 15 Product Gate：**NOT READY**

已完成真实完整授权、35,214 项全库元数据读取、渐进网格和文件名筛选验证。Gate 仍未就绪：受限访问、iCloud-only 资源、真实预览/多选（被 macOS 27 beta 的自动化 Accessibility 管道阻断）、写入用户选择目录及随后 Archive 的运行时验证尚未完成。本阶段继续保持 Draft PR；没有合并 PR、没有创建 Release。

### Phase 14 集成状态

等待 PR #2 合并到 `main` 后再将 PR #3 rebase / merge 到最新 `main`，重新 build/test，并执行真实 Apple Photos 导入、Catalog Rescan、Phase 14 SHA-256、离线预览与重复检测复测。本轮未 cherry-pick 或合并 PR #2 的提交。
