# Phase 14 验证记录 — Library Archive & Duplicate Import Guard

日期：2026-08-12
开发环境：macOS 27 Golden Gate beta、Xcode 27 beta（macOS 27 SDK）

## 架构与持久化决策

既有 `catalog.json` 适合保存用户编辑、OCR、稳定资产 ID 与原子恢复快照，但不适合每张图片的哈希完成、预览状态和重复关系都重写整份 Catalog。Phase 14 采用混合持久化：

- `catalog.json` 只保存用户状态和稳定资产身份；哈希、位置、预览元数据和重复关系不再编码到 `PhotoAsset` JSON。
- 首次建立归档索引前复制 `catalog.json.phase14-pre-sqlite.bak`；SQLite 初始化失败不会清空或重置 JSON Catalog。
- 与 Catalog 同目录的 `catalog.archive.sqlite` 保存 `archive_assets`、`asset_locations`、`duplicate_relationships` 及视觉哈希候选段索引。该库不保存 preview 二进制。
- `Application Support/PhotoAI-Mac/ArchivePreviews/<UUID 前缀>/<UUID>-v1.jpg` 保存持久派生预览；普通 Grid 缩略图仍是内存缓存。

这不是完整 Catalog 到 SQLite 的破坏性重写：现有评分、Flag、收藏、`EditRecipe`、OCR 和 People 所引用的稳定资产 ID 都保留在 JSON Catalog。Phase 14 Hardening 以全新归档数据库为目标，不维护旧 Phase 14 SQLite schema 的兼容或回滚逻辑。

## 已实现的归档行为

- 每个文件位置记录来源、相对路径、文件名、大小、修改时间、首次/最后发现时间、可用性，以及系统可读取时的卷名、卷标识和文件资源标识。
- 后台归档队列限制为 2 项并发。启动时只读取一次 pending/stale 任务；新增来源与重扫只提交新增/变化的资产 ID，单项完成不会重新遍历 Catalog。队列以 Array 游标出队，不使用逐项 `removeFirst()`。
- 对图片先构造视觉指纹和 1280 px JPEG 预览，再计算全文件 SHA-256；队列可暂停并在重新打开应用后对未完成项目继续处理。
- 哈希状态保存文件大小和修改时间；任一项改变都会让哈希/预览标记为 stale，在 SQLite 事务中移除旧的重复关系与视觉候选后重新计算。
- SHA-256 相等是“完全重复”；感知哈希仅是“疑似视觉重复”。同一 `sourceID + relativePath` 重扫归为“已索引文件”，不会创建第二个资产；不同来源的精确副本建立关系而不删除、不阻止扫描。
- Archive 页面可筛选全部、在线、离线、缺失、多个副本与完全重复；扫描摘要显示新照片、已索引、完全重复和疑似相似数量。
- 原始文件离线/缺失时，Grid 和人物缩略图可回退到离线预览；检查器展示原始卷/路径/最后发现时间并提供“重新关联来源”。若另一份精确副本在线，检查器会展示其位置并可在 Finder 中打开。编辑与原图导出会禁用。
- “删除离线预览”会在协调器取消并等待在途 worker 后，删除派生 JPEG 并将 SQLite 预览状态标为 `evicted`；它不会自动重新生成。用户可选择“重新建立离线预览”，该操作仅恢复预览任务，不会重新计算已完成的哈希。
- 明确从 Catalog 移除/移入废纸篓成功的资产，会在同一 SQLite 事务中清理归档元数据、位置、视觉哈希段和重复关系，并移除对应预览文件；外置盘缺失或单个路径消失只标记不可用，历史不会被删除。

## Preview 策略

| 项目 | 值 |
| --- | --- |
| 长边 | 1280 px（在 Retina 网格、人物预览可辨认；像素面积为旧 1440 px 目标的约 79%，降低缓存面积） |
| 格式 | JPEG |
| 压缩质量 | 自适应 JPEG：≤450k 像素 0.74、常规 0.71、≥1.2M 像素 0.68；以小预览可辨认和接近 1280 px 缓存体积平衡 |
| 命名 | `UUID 前缀/UUID-v1.jpg`，避免按原文件名冲突或单目录过大 |
| 容量 | 记录实际字节数和总数；不把 100 KB 当作硬上限 |

离线预览用于识别和浏览，**不是原图备份**，不用于编辑、正式导出或打印。

## 自动化验证

本阶段新增 `ArchiveWorkflowTests`，覆盖：

- 哈希与 preview 跨 SQLite 重开后仍存在，且 preview 生成不会修改原文件。
- 文件未变化时不会重新 hash；文件变化会失效旧 hash/preview，且旧精确重复关系被移除。
- 两个不同来源的同字节文件经 SHA-256 识别为“完全重复”，不会同时误报成视觉重复。
- 测试目录移动后资产仍保留原始路径和离线 preview；重新关联目录后恢复在线。
- 单个文件在仍在线来源内被删除后仍留在历史图库，状态为“缺失”。
- 应用重启后，SQLite 中待处理资产被重新排队并完成。
- 后台归档暂停/取消后可恢复，并验证不会修改原始文件。
- 离线原位置但另一份精确副本在线时，状态为“多个副本”。
- 旧 JSON Catalog 在 SQLite 迁移前得到备份，评分、Flag、收藏、配方与 OCR 原样保留。
- 纯元数据 10,000 和 50,000 行场景通过 `archive_assets.exact_hash` SQLite 索引查询精确重复，不需要遍历完整 Catalog。
- 50,000 条 `recordScan()` 先以单个来源 UPDATE 标记旧位置不可用，再逐条 UPSERT 已扫描路径；验证没有巨型 `NOT IN` 绑定、扫描路径恢复可用、137 条缺失路径仍不可用，并验证扫描摘要。
- 50,000 条合成请求在归档队列中只入队/出队一次；暂停后的重新入队不会重复项目，且没有触发全 Catalog 请求生成。
- `evicted`、`unsupported` 与 `retryableFailure` 预览状态不会在启动时无限自动重试；“重新建立离线预览”只恢复 `evicted` 与 `retryableFailure`，不重算已完成哈希；清理进行中的归档任务后，最终状态确定为 `evicted`。
- OCR、人物分析、清理和智能选片仅接收原始文件实际可用的资产；离线人物卡仍可显示既有本地预览。

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift build` | 2026-08-13 通过。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift test --filter ArchiveWorkflowTests` | 2026-08-13 通过，16 tests / 1 suite（含真实 50k `recordScan()`、50k 队列和清理并发测试）。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift test` | 2026-08-13 通过，69 tests / 16 suites；真实 Sony ARW 由既有显式开关报告 `SKIPPED`。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | 2026-08-13 `TEST SUCCEEDED`，69 tests / 16 suites；同一真实 RAW 测试明确 `SKIPPED`。 |

Xcode 日志仍有既有、已被测试隔离的系统/测试环境提示：损坏缩略图测试的 ImageIO 解码错误、Vision OCR E5 模型路径提示，以及大内存 JPEG 取消测试触发的 IOSurface 日志；均未导致测试失败。本记录不把本机测试目录的移动/重新关联表述为真实可移动磁盘硬件验收。

## 已知限制

- 当前在不重写原有 `PhotoAsset` 主模型的前提下，把不同来源的精确副本保留为独立 Catalog 项并用 SQLite 关系连接；`AssetLocation` 已为未来合并为单逻辑资产保留空间。
- 自动重新挂载优先依赖现有安全书签和记录路径；当系统不能可靠恢复路径时，用户需在检查器中选择“重新关联来源”。
- 视频记录位置与哈希状态，但本阶段不生成视频离线预览。
- 真实外置盘/NAS 断开：**NOT RUN**。自动化覆盖本地目录移动、缺失与重新关联，不把它表述为真实可移动存储硬件验收。
