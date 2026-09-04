# 执行计划

本文件跟踪 `PhotoAI-Mac-PLAN.md` 的实际执行状态；产品范围与阶段验收标准以原计划为准。

## 当前阶段：预览空白与索引性能修复

### 预览空白与索引性能修复（进行中）

诊断报告与全部实测数据见 [docs/preview-and-indexing-performance.md](docs/preview-and-indexing-performance.md)。
现场：Catalog 8,055 项（ARW 3,987 / JPG 4,068，平均 35.5 MB），唯一可用来源在安卓 MTP
挂载盘（`aft-mtp-mount@macfuse0`，读文件前 1 MB 约 0.6 秒），另有 3 个来源已 `missing`。

诊断结论（均为本机实测）：

- 预览空白的决定性根因是 6 处 `kCGImageSourceCreateThumbnailFromImageAlways` 强制全图解码：
  冷 ARW 缩略图 480 需 **30.04 s**、预览 2400 需 **36.09 s**；仅用内嵌预览分别是 0.441 s 与 0.350 s。
- 但不能直接删除该 flag：JPEG 只内嵌 160×120 的 EXIF 缩略图，无论请求 480 还是 2400 都只返回它，
  直接删除会让 4,068 张 JPG 全部变糊并使 OCR 失效。ARW 内嵌约 1616 px 预览，够用。
- `PhotoPreviewStore` 把已解码完成的图像在写入缓存前因调用方取消而丢弃，且无 in-flight 去重，
  导致左右翻页时每张都完整解码、每张都丢弃，永远收敛不到有图状态。
- 索引缓慢的根因是扫描完全单线程、每个文件都读一次 EXIF（0.22–0.33 s/文件），
  5,338 文件约需 20–30 分钟，且全程无进度、无增量提交、重扫无跳过。

本轮修复（优先级 1+2，已完成代码与自动化验证）：

- [x] 新增 `DownsampledImageDecoder`：内嵌长边达到请求值一半才采用，否则回退全解码；
      已替换 `ThumbnailStore`、`PhotoPreviewStore`、`ImageProcessingPipeline`、`SearchAndOCR`、
      `CullingWorkflowStore`、`CleanupWorkflowStore` 共 6 处调用，源码中已无散落的该 flag。
- [x] `PhotoPreviewStore` 改为先写入内存/磁盘缓存再交由调用方处理取消，并按 `cacheKey` 去重；
      新增 `decodeCount` 供测试断言实际解码次数。
- [x] 新增 `Tests/PhotoAIMacTests/PreviewDecodingTests.swift`（6 项），覆盖尺寸判定回退、
      取消后仍入缓存、并发去重；后两项已用"临时回滚为修复前语义"确认确实会失败。
- [x] `swift build`、`swift test`（103 tests / 19 suites）、`Scripts/build-debug-app.sh`、
      `git diff --check` 均 PASS；整套测试耗时从 28.10 s 降到 1.84 s。
- [ ] 真机 UI 点击验证：调试包已就绪（`.build/PhotoAI-Mac.app`），待本机实际操作确认。

实测效果（真实 MTP 冷文件，使用发布代码）：缩略图 480 冷 ARW 由 30.04 s 降到 **0.681 s**，
预览 2400 冷 ARW 由 36.09 s 降到 **0.550 s**；JPEG 路径经同规格受控 A/B 确认无回归
（1.658 s → 1.500 s，输出同为 320×480）。RAW 全屏预览尺寸由 2400 px 变为内嵌的 1616 px，
观感是否可接受待真机判断。

第二轮修复（优先级 3–5，已完成代码与自动化验证，详见报告第 5 节）：

- [x] `CatalogScanner` 拆为"枚举路径 + 并行读元数据"，新增 `scanConcurrently` 按批回报进度。
- [x] 新增 `EXIFDateParser` 替换每张照片新建的 `DateFormatter`，并有与旧实现逐输入等价的测试。
- [x] `scanProgress` 改为已扫描 / 总数，并在 `FolderSourceList` 真正显示计数与进度条
      （此前该属性从未被任何界面读取）；首次导入按批追加，照片边扫边出现。
- [x] 重扫按 `fileSize` + `modifiedAt` 跳过未变文件，命中即复用旧记录。
- [x] 新增 `CatalogWriter` actor：编码与写盘移出主线程，连续改动合并为一次写入，
      `.bak` 解码校验改为每进程一次；新增 `flushPendingPersist()`，4 个既有测试已按新契约更新。
- [x] `swift build`、`swift test`（109 tests / 21 suites）、`Scripts/build-debug-app.sh`、
      `git diff --check` 均 PASS。
- [ ] 真机完整导入验证（5,338 项，约 13 分钟）与导入过程中的网格观感确认。

实测（48 个冷 ARW 一组）：串行读 EXIF 34.59 s → 并行 6.79 s，**加速 5.09×**；
重扫快路径仅 stat，48 个文件 0.003 s。按 5,338 项外推：首次导入约 64 分钟降到约 13 分钟，
重扫由约 64 分钟降到**约 1.2 秒**。连续 20 次评分改动实际只落盘 1 次。

第三轮修复（剩余待办，已完成代码与自动化验证，详见报告第 6 节）：

- [x] 网格单击只选中、双击才进预览，并补上右键菜单与 `accessibilityAction` 入口。
- [x] 新增 `CatalogStore.relocate(_:to:)` 与两处"重新定位…"入口；
      保留 `sourceID` 与 `relativePath`，重新定位后资产 ID、评分、标记均不丢。
- [x] 预览磁盘缓存改 JPEG 编码 + 2 GB 预算淘汰，并清除旧 `.tiff` 残留。
- [x] 缩略图队列由串行改为 `maxConcurrentOperationCount = min(6, 核数)`。
- [x] 新增 `PhotoAIAppDelegate`，退出前经 `.terminateLater` 等待 `flushPendingPersist()`。
- [x] 核实 Phase 14 归档数据在源码中零引用后移入废纸篓，实际回收约 **1.6 GB**
      （sqlite 576 MB + ArchivePreviews 1.0 GB，可从废纸篓还原）。
- [x] 顺带修复：`.scanning` 这一运行时瞬时状态会被扫描期持久化写进快照并跨重启存活，
      导致来源永远停在"正在扫描"；读取时已统一归位为 `.ready`。
- [x] `swift build`、`swift test`（117 tests / 24 suites）、`Scripts/build-debug-app.sh`、
      `git diff --check` 均 PASS。
- [ ] 真机验证：双击手感、重新定位真实 missing 来源、退出时的 `.terminateLater` 行为。

第四轮：离线索引能力（已完成代码与自动化验证，详见报告第 7 节）

需求扩展：扫描过的照片，即使外置盘或临时卷退出，预览也要继续显示；卷接回时又能对应
回原文件。这让派生图不再是可丢弃的缓存，而是**卷离线期间照片在本机的唯一表示**，
因此推翻了上一轮的三条决策——存 Caches、总量预算与 LRU 淘汰、文件名含修改时间。
目标平台明确为内置磁盘与外置 SSD，MTP 降级为"能用但不为它优化"。

关键实测（n=6 真实照片）：**一次解码可产出所有级别**，昂贵的是读文件加解码而不是编码，
所以增加一级的代价是磁盘空间而非时间。ARW 请求 2400 实际只得到内嵌的 1616×1080，
因此离线预览定在 1600——对 RAW 零损失，2400 要多花 9.3 GB 却只对 JPEG 有意义。

- [x] A：派生图迁到 `Application Support/PhotoAI-Mac/Derived/<sourceID>/`，取消总量预算与
      LRU 淘汰，文件名去掉修改时间，两个请求类型合并为 `DerivedImageRequest`，
      加载支持 `allowsRendering`，离线角标，启动回收 Caches 下的旧布局。
- [x] B：扫描完成自动全卷预热，两级同一次解码产出；已有缓存跳过因而可续跑；
      交互解码优先于预热；大图预览三级回退，空白页在结构上不再可能出现。
- [x] C：监听 `NSWorkspace.didMountNotification` 自动恢复接回的卷；设置页可选离线预览
      级别（关 / 1280 / 1600 / 2400），每档标注实测占用；预热级别改为可注入，
      避免测试污染 `UserDefaults.standard`。
- [x] `swift build`、`swift test`（137 tests / 33 suites）、`Scripts/build-debug-app.sh`、
      `git diff --check` 均 PASS。
- [x] 固态盘照片导入：用户实机反馈效果良好。
- [ ] 真机验证：拔盘后离线浏览、卷接回自动恢复、5 万张规模的预热耗时与占用。

空间预算（每万张，含 480 缩略图）：关闭 0.5 GB / 1280 3.1 GB / **1600 默认 4.2 GB** /
2400 6.1 GB。按 5 万张规模，默认档约 21 GB。

后续待办：

- [ ] JSON → SQLite。5 万张时 `catalog.json` 约 37 MB 且每次保存全量重编码，
      是做真正"照片数据库"的前置条件。独立阶段。

## 历史阶段：Phase 17 — 摄影照片筛选工作流

### Phase 17 — 摄影照片筛选工作流（已完成）

- [x] 梳理 Phase 16 Viewer、Catalog Index、选择模型和原文件导出能力，确认 Phase 17 不进入照片编辑范围。
- [x] 实现保持图库上下文的 Culling Mode、缓存预览、快捷键导航与单张评分/标记。
- [x] 实现 A/B Compare View 的状态、同步缩放/移动、元数据展示与快速选择。
- [x] 基于拍摄时间窗口和文件连续性建立非 AI Photo Group，并增加总数、Pick、五星、Reject、未处理统计。
- [x] 扩展原文件导出：Pick、五星、当前筛选结果，并可选保持来源目录结构且绝不覆盖目标。
- [x] 为评分、Pick/Reject 和批量操作增加 Command+Z 撤销，并避免触发磁盘重扫或 UI 线程 RAW 读取。
- [x] 补齐提示词指定测试与 100,000 项 Catalog 性能门禁，完成真实 UI 验证并记录 PASS / NOT RUN / BLOCKED。
- [x] 更新 README 和 `docs/phase-17-culling-validation.md`，完成提交、推送和堆叠 Draft PR 后停止。

### Phase 16 — 照片管理与导出工作流（已完成）

- [x] 梳理 Catalog 索引、图库选择、缩略图缓存和既有批量导出能力，确认不进入照片编辑范围。
- [x] 实现保留图库上下文的 PhotoViewer、大图离线预览缓存、上一张/下一张及 Esc/方向键/Space 导航。
- [x] 完成 0–5 星、Pick/Reject/None 的单张与批量操作、JSON 持久化和基于 Catalog 内存索引的筛选。
- [x] 实现原扩展名复制导出、安全冲突命名、批量进度、失败隔离与取消，不覆盖或修改原文件。
- [x] 覆盖评分/标记持久化、筛选、批量操作、冲突命名、取消及大批量导出测试，并验证 50,000 项索引路径不读取磁盘。
- [x] 新增 `docs/phase-16-photo-management-validation.md`，按 PASS / NOT RUN / BLOCKED 记录真实自动化与本机 UI 验证。
- [x] 完成提交、推送并创建 Draft PR 后停止，不进入 RAW 调色、LUT、曲线、HSL、蒙版或 AI 修图开发。

### 切换性能修复（已完成）

- [x] 在含 922 项本地 Catalog 的实际 app 中复现并采样反复侧栏切换；定位到重复 ID 构建、全局缩略图完成通知和 Apple Photos 全库即时筛选造成的主线程压力。
- [x] 消除重复 ID 构建与全局缩略图完成通知，改为有界缓存和按 Cell 更新；离屏 Cell 会撤销其回调，避免待更新视图累积。
- [x] 缓存 Apple Photos 筛选结果和进行中的缩略图/可用性请求；完成 7 轮实际侧栏切换、空闲进程采样、`swift test` 与 `xcodebuild test` 回归。

### Phase 15 Final Fix（进行中）

- [x] 确认 Final Fix 仅涵盖本地缩略图失败状态、快速相簿切换与预热顺序。
- [x] 以 Cell 本地状态表现缩略图加载失败，且保持 `ThumbnailStore.completedKeys` 非 `@Published`。
- [x] 为 Apple Photos 加入取消加 generation 双重保护，保证 Latest Selection Wins。
- [x] 将缩略图预热判重移动到 `PHAsset` 查询之前，并新增纯模型回归测试。
- [x] 完成 Xcode 27 build/test、本地 922 张 Catalog 的 10 轮侧栏性能回归，更新验证文档与 Draft PR #3；真实相簿切换因本轮调试包未授权而如实保留为待复测。

### 编辑器返回图库空白修复（已完成）

- [x] 确认 Catalog 快照仍含 922 项，两个本地来源路径均可访问；问题不是 Catalog 数据丢失。
- [x] 保留编辑器下方的图库视图树，避免完成调色后销毁并重建所有可见缩略图 Cell。
- [x] 完成 Xcode 27 自动化回归、Catalog/源文件可读性复核与新构建启动；真实点击式 JPEG 编辑器往返已验证。
- [x] 在编辑器退出时一次性重新连接可见缩略图订阅；Cell 优先从缓存恢复、否则加入既有加载，不恢复逐张图全局刷新。
- [x] 在 Cell 的局部缩略图状态异常丢失时，展示层直接回退到已有内存缓存，避免已解码照片误显示为空白占位。
- [x] 将侧边栏选择定义为退出编辑器的导航操作，并为模型语义和缩略图刷新信号增加自动化回归。

### 编辑器返回图库全空白复发排查（已完成）

- [x] 收到真实使用反馈：编辑页内操作后切回主页面，整个主内容为空白，重启应用才恢复；此前仅针对缩略图 Cell 的缓存兜底不足。
- [x] 发现实际启动的两个 `.app` 二进制仍停留在 8 月 12/13 日；最新 8 月 24 日源码修复从未进入运行包。用当前源码重新组装独立调试包后，真实“调整曝光 → 返回所有照片”路径不再空白。
- [x] 修复侧边栏绕过 `AppShellModel.select(_:)` 的入口；编辑时再次点击已选中的“所有照片”也会明确退出编辑器。
- [x] 新增统一调试包构建脚本并更新 README，确保 `.build/PhotoAI-Mac.app` 始终装入刚编译的可执行文件并完成临时签名。
- [x] 完成 70 项 Swift/Xcode 自动测试、脚本语法与签名验证；最终调试包已启动，真实 JPEG 调整后通过同一“所有照片”侧栏入口返回，922 项网格与可见缩略图保持正常。

### 历史 Logo 恢复（已完成）

- [x] 定位历史提交 `bd7e6a1`，确认原始 PNG、macOS `.icns`、SwiftPM 资源声明、侧边栏品牌区和运行时图标配置完整。
- [x] 恢复 PNG 母版、SwiftPM 运行时 PNG 与 macOS `.icns`；适配当前侧边栏，并让调试包脚本同时复制 `.icns` 和 SwiftPM 资源 bundle。
- [x] 通过显式 `Bundle.module` / `NSImage` 加载统一设置运行时图标与侧边栏 Logo；真实应用中品牌图标和文字均正常显示。
- [x] 完成 71 项 Swift/Xcode 自动测试、资源可用性回归、应用包 `Info.plist`/资源清单、ad-hoc 签名和真实 UI 验证。

### Phase 15 合并与 Release 打包（已完成）

- [x] 确认版本沿用 `0.1.0 (1)`，不擅自创建 Git tag 或 GitHub Release。
- [x] 补充可重复的 Release 打包脚本，确保 `.icns` 与 SwiftPM 品牌资源进入应用包，并拒绝覆盖既有产物。
- [x] 在合并后的 `main` 上完成 Swift/Xcode 测试、Release 构建、签名、压缩包与 SHA-256 验证。
- [x] 将 PR #3 从 Draft 转为可审查并合并到 `main`；合并提交为 `1aa188e`，最终产物保存在本机 `dist/main-<commit>/`。

### Phase 15 — Apple Photos 系统相册接入（已实现；真实全库读取与渐进网格已验，剩余受控运行时复测待审）

- [x] 从 `main` 建立独立 `agent/phase-15-apple-photos` 分支；不混入尚未合并的 Phase 14 PR #2。
- [x] 按本机 Xcode 27 / macOS 27 SDK 核对 PhotoKit 公共授权、缓存缩略图和原始资源导出接口。
- [x] 重构独立 Apple Photos 内存模型、授权状态、筛选、相簿与惰性 iCloud 状态。
- [x] 实现可扩展的真实缩略图网格、多选、受限预览与检查器；大图库改为 240 项首屏与“显示更多”，防止一次性物化数万个 Cell。
- [x] 实现用户选择目录后的原始资源导入、冲突安全命名、进度、取消与 Catalog 接入。
- [x] 补充纯模型测试、真实完整授权后的 35,214 项读取/首屏/文件名筛选复测，并如实记录自动化 Accessibility 管道对预览验证的阻断；完成构建测试、提交、推送及 Draft PR #3；未合并、不创建 Release。

### Phase 0 — SDK / Reuse Spike（已完成）

- [x] 检查目录、现有说明与本机开发环境。
- [x] 使用 Xcode 27.0 Beta / macOS 27.0 SDK 验证 SwiftUI、Core Image、Vision、Foundation Models 与 Media Intelligence 的编译接口。
- [x] 建立最小 macOS 27 target 与自动化测试。
- [x] 执行 build / test，并将实际结果写入 SDK 验证记录。
- [x] 完成 Phase 0 验收。

### Phase 1 — App Shell（已完成）

- [x] 实现三栏桌面布局：Sidebar、内容区与 Inspector。
- [x] 实现工具栏、菜单命令、快捷键框架与 Settings。
- [x] 构建、自动测试与人工 UI 验收（见 `docs/phase-1-validation.md`）。

### Phase 2 — Catalog + Folder Source（已验收）

- [x] 添加本地文件夹并保存 Security-Scoped Bookmark。
- [x] 分层扫描并持久化 PhotoSource / PhotoAsset 的基础元数据。
- [x] 处理重启、重扫与缺失来源状态，保证不修改原文件。
- [x] `swift test` 通过：12 tests / 4 suites；用户主动选择本地测试来源后，已完成只读界面验收。
- [x] 用户已验收，进入 Phase 3。

### Phase 3 — Library（已验收）

- [x] 生成并缓存真实的低分辨率缩略图，网格不读取全分辨率原图。
- [x] 实现单选、Shift/Command 多选、快捷键、评分、Pick/Reject、收藏与筛选。
- [x] 让 Inspector 显示选中照片元数据。
- [x] `swift test` 与 `xcodebuild test` 通过：14 tests / 4 suites；真实 RAW/JPEG 预览和 Inspector 联动已人工验收。
- [x] 用户授权后续阶段由 Codex 自行验收。

### Phase 4 — JPEG / HEIF Editor（已验收）

- [x] 实现可版本化、可持久化的非破坏 `EditRecipe`。
- [x] 实现 JPEG / HEIF 的预览调整、裁剪、旋转和 Reset。
- [x] 保证预览与导出复用同一渲染语义，并测试原图不变。
- [x] `swift test` 与 `xcodebuild test` 通过：17 tests / 5 suites；真实 JPEG 预览、编辑面板与返回图库已本机验收（见 `docs/phase-4-validation.md`）。

### Phase 5 — RAW + LUT（已验收）

- [x] 将 `CIRAWFilter` 纳入 RAW 预览与全分辨率 JPEG 导出管线。
- [x] 实现 `.cube` LUT 校验、管理、选择与强度调节。
- [x] 使用真实 Sony ARW 做预览与导出验证；确保取消/关闭不遗留临时文件。
- [x] `swift test` 与 `xcodebuild test` 通过：21 tests / 6 suites；真实 RAW 预览、RAW 全分辨率临时导出和编辑器入口已本机验收（见 `docs/phase-5-validation.md`）。

### Phase 6 — Batch Workflow（已验收）

- [x] 实现批量 Recipe 应用、可取消队列与进度状态。
- [x] 提供批量 JPEG 导出、失败隔离与结果汇总。
- [x] 对批量任务执行自动化与本机界面验收，保证原始照片不被修改。
- [x] `swift test` 与 `xcodebuild test` 通过：整合后 28 tests / 8 suites；批处理入口与导出预设已本机验收（见 `docs/phase-6-validation.md`）。

### Phase 7 — Search + OCR（已验收）

- [x] 实现元数据与结构化查询，并展示条件解释。
- [x] 在后台建立可暂停/恢复的 Vision OCR 索引。
- [x] 为 Foundation Models 解释器提供不可用时的确定性回退。
- [x] `swift test` 与 `xcodebuild test` 通过：28 tests / 8 suites；真实本机 RAW 条件搜索、OCR 控制入口和条件解释已本机验收（见 `docs/phase-7-validation.md`）。

### Phase 8 — People（已验收）

- [x] 验证并接入 Media Intelligence 人脸分析；失败时保留可恢复状态。
- [x] 实现人物网格、持久化人物记录、命名、合并、隐藏与人物搜索。
- [x] 记录真实运行时 API 可用性，同时不把用户命名绑定到分析器实体。
- [x] 人物卡片显示稳定的本地人脸主预览与其余样本数量，并可定位到来源照片；未命名卡片提供直接命名提示，不会重新分析或上传照片。
- [x] `swift test` 与 `xcodebuild test` 通过：46 tests / 14 suites；本机已验证人物预览、命名入口与来源照片定位（见 `docs/phase-8-validation.md`）。

### Phase 9 — Cleanup（已验收）

- [x] 实现重复项、相似项、RAW/JPEG 配对、截图和导出关联的仅推荐式清理视图。
- [x] 提供带明确确认的“移到废纸篓”操作，并处理外置磁盘失败状态。
- [x] 为推荐、确认和失败隔离补充自动化与本机界面验收（见 `docs/phase-9-validation.md`）。

### Phase 10 — AI Culling（已验收）

- [x] 基于本地视觉指纹组成相似组，并计算清晰度与 Vision 人脸采集质量信号。
- [x] 提供带理由的推荐；不自动删除、标记 Pick/Reject 或修改星级。
- [x] 仅在明确确认后把选择的推荐项标记为 Pick；自动化与本机界面验收完成（见 `docs/phase-10-validation.md`）。

### Phase 11 — Apple Photos Source（已实现；授权态运行时待用户主动授权后复测）

- [x] 评估并接入独立的 PhotoKit 数据源、相簿、收藏和 iCloud 可用性状态。
- [x] 明确处理未授权、受限、iCloud 未下载和不可访问资产，且不与文件系统来源耦合。
- [x] 补充隔离自动化与未授权本机界面验收；不在未获授权时读取 Photos 图库（见 `docs/phase-11-validation.md`）。

### Phase 12 — Stability Hardening（已验收）

- [x] 增加 Catalog schema 迁移、原子写入和最后有效快照恢复。
- [x] 覆盖大 Catalog、外置来源缺失、重启恢复、RAW 导出、导出/OCR 取消、缺失 LUT 与损坏缩略图。
- [x] `swift test` 与 `xcodebuild test` 通过：43 tests / 13 suites（见 `docs/stability-validation.md`）。

### Phase 12.5 — Catalog Identity & Scale Hardening（已完成；Draft PR 待审）

- [x] 重扫复用同一 `sourceID + relativePath` 的 `PhotoAsset.id`，并保留既有 Catalog 状态。
- [x] 覆盖 Catalog → People → Rescan → Restart 回归，确保人脸记录仍指向原照片。
- [x] 修正人物 Hero 的剩余关联照片计数，并使主预览排序可复现。
- [x] 将 Cleanup 与 Culling 的相似性比较改为时间窗口和视觉候选桶，避免全库 O(n²)；无拍摄时间项目采用有界保守策略。
- [x] 将真实 Sony ARW 改为显式 `RUN / SKIPPED` 集成测试，并强化 OCR 暂停/恢复竞争测试。
- [x] 增加最小 GitHub Actions、阶段验证文档；在独立分支提交、推送并创建 Draft PR 后停止。

### Phase 13 — Release Preparation（已暂停，等待 Phase 12.5 Release Gate）

- [x] 更新 README、阶段验收记录和隐私说明。
- [ ] 确定开源许可证（法律/授权选择）。
- [x] 已初始化 Git、创建公开 `taoking/photoai-macos` 并推送 `main`；release tag 与 PR 不在本次范围。
- [ ] 在已确定版本号与许可证后生成 unsigned `.app.zip`、SHA-256 与 BUILD-INFO。

## Phase 0 验证结果

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift build` | 通过 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过，5/5 tests |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS' build` | `BUILD SUCCEEDED` |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，5/5 tests |

## 已知风险

- 目录未提供 iOS 工程或可复用模块，因此暂不能做跨项目复用验证。
- Xcode 27.0 Beta 的 SDK API 仍可能变化；系统更新后应重跑 Vision、Media Intelligence、PhotoKit 与 RAW 相关验证。
- Apple Photos 已在真实完整授权下读取 35,214 项并验证首屏渐进加载与文件名筛选；有限授权、仅云端 iCloud 项、显式导入，以及预览/多选的自动化运行时复测仍待完成（后者受 macOS 27 beta 的 Accessibility 自动化管道影响）。
- 尚未选择开源许可证，也尚未生成带版本号的 release 产物；本次仅按授权创建公开源码仓库并推送 `main`。
