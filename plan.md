# 执行计划

本文件跟踪 `PhotoAI-Mac-PLAN.md` 的实际执行状态；产品范围与阶段验收标准以原计划为准。

## 当前阶段：Phase 15 — Brand Identity

### Phase 15 — Brand Identity（已完成）

- [x] 设计 PhotoAI Mac 的原创摄影 / AI 标志。
- [x] 生成 macOS `.icns` 应用图标，并配置到调试 App bundle。
- [x] 在应用侧边栏使用同一品牌标志。
- [x] 执行构建和自动化回归验证。
- [x] 修复开发启动路径未使用 App bundle 导致 Dock 图标缺失的问题。

## 已完成阶段：Phase 14 — Hardening / Draft PR under review

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

### Phase 14 — Library Archive & Duplicate Import Guard（Hardening / Draft PR 待审）

- [x] 评估 JSON Catalog 的高频归档写入成本；保留 JSON 为用户状态恢复基线，并以 SQLite 保存哈希、位置、预览元数据和重复关系。
- [x] 增加长期历史资产、物理位置、卷/文件资源标识、SHA-256、视觉指纹和状态模型；同一来源重扫复用稳定资产身份。
- [x] 增加持久离线预览（1280 px 长边、自适应 JPEG Quality）、两项受限并发后台队列、暂停/续跑与重启后对未完成项目的安全恢复。
- [x] 增加 Archive / History 入口、离线/缺失/多个副本/完全重复筛选、扫描摘要、来源检查器与重新关联入口。
- [x] 将原图不可用时的 Grid/人物缩略图回退到离线预览，禁用编辑与原图导出，并清楚标明预览不是备份。
- [x] 覆盖哈希持久化与失效、跨来源精确重复、离线/重新关联、历史保留、迁移备份、取消/续跑和 10k/50k SQLite 索引查找。
- [x] 修复 50k 来源扫描、归档队列、预览状态、记录清理、离线模块行为与 SQLite/JSON 职责边界。
- [x] 消除 50k Catalog merge 嵌套扫描，补充稳定 ID / 用户状态 / 历史资产的 50k 纯模型回归。
- [x] 防止迟到 worker 在显式删除后复活 SQLite 归档记录，并清理被丢弃结果的预览文件。
- [x] Archive DB 不可用时显式删除 Fail Closed；完全重复筛选使用 O(1) runtime 索引。
- [x] 完成 Hardening 全量验证、文档、现有 Draft PR 更新后停止。

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
- Apple Photos 调试 App 当前未获系统授权；授权、有限授权和 iCloud 仅云端资产的实际读取回调仍待用户主动授权后的复测。
- 尚未选择开源许可证，也尚未生成带版本号的 release 产物；本次仅按授权创建公开源码仓库并推送 `main`。
