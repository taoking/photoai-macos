# Phase 14 验证记录 — Library Archive & Duplicate Import Guard

日期：2026-08-12
开发环境：macOS 27 Golden Gate beta、Xcode 27 beta（macOS 27 SDK）

## 架构与持久化决策

既有 `catalog.json` 适合保存用户编辑、OCR、稳定资产 ID 与原子恢复快照，但不适合每张图片的哈希完成、预览状态和重复关系都重写整份 Catalog。Phase 14 采用混合持久化：

- `catalog.json` 仍是用户状态与旧版本兼容恢复基线；schema 升至 v3。
- 首次建立归档索引前复制 `catalog.json.phase14-pre-sqlite.bak`；SQLite 初始化失败不会清空或重置 JSON Catalog。
- 与 Catalog 同目录的 `catalog.archive.sqlite` 保存 `archive_assets`、`asset_locations`、`duplicate_relationships` 及视觉哈希候选段索引。该库不保存 preview 二进制。
- `Application Support/PhotoAI-Mac/ArchivePreviews/<UUID 前缀>/<UUID>-v1.jpg` 保存持久派生预览；普通 Grid 缩略图仍是内存缓存。

这不是完整 Catalog 到 SQLite 的破坏性重写：现有评分、Flag、收藏、`EditRecipe`、OCR 和 People 所引用的稳定资产 ID 都保留在 JSON Catalog，因此也保留了回滚与恢复空间。

## 已实现的归档行为

- 每个文件位置记录来源、相对路径、文件名、大小、修改时间、首次/最后发现时间、可用性，以及系统可读取时的卷名、卷标识和文件资源标识。
- 后台归档队列限制为 2 项并发。对图片先构造视觉指纹和 1440 px JPEG 预览，再计算全文件 SHA-256；队列可暂停并在重新打开应用后对未完成项目继续处理。
- 哈希状态保存文件大小和修改时间；任一项改变都会让哈希/预览标记为 stale，在 SQLite 事务中移除旧的重复关系与视觉候选后重新计算。
- SHA-256 相等是“完全重复”；感知哈希仅是“疑似视觉重复”。同一 `sourceID + relativePath` 重扫归为“已索引文件”，不会创建第二个资产；不同来源的精确副本建立关系而不删除、不阻止扫描。
- Archive 页面可筛选全部、在线、离线、缺失、多个副本与完全重复；扫描摘要显示新照片、已索引、完全重复和疑似相似数量。
- 原始文件离线/缺失时，Grid 和人物缩略图可回退到离线预览；检查器展示原始卷/路径/最后发现时间并提供“重新关联来源”。若另一份精确副本在线，检查器会展示其位置并可在 Finder 中打开。编辑与原图导出会禁用。
- “删除离线预览”只删除派生 JPEG 与其 SQLite 元数据；不会删除原始照片、Catalog、哈希、评分、OCR、人物记录或编辑配方。

## Preview 策略

| 项目 | 值 |
| --- | --- |
| 长边 | 1440 px（落在 1280–1600 建议区间） |
| 格式 | JPEG |
| 压缩质量 | 0.72 |
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

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift build` | 通过。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift test` | 通过，63 tests / 16 suites；真实 Sony ARW 集成测试按既有开关明确 `SKIPPED`。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，63 tests / 16 suites；同一真实 RAW 测试明确 `SKIPPED`。 |

Xcode 日志仍有既有、已被测试隔离的系统/测试环境提示：损坏缩略图测试的 ImageIO 解码错误、Vision OCR E5 模型路径提示，以及大内存 JPEG 取消测试触发的 IOSurface 日志；均未导致测试失败。本记录不把本机测试目录的移动/重新关联表述为真实可移动磁盘硬件验收。

## 已知限制

- 当前在不重写原有 `PhotoAsset` 主模型的前提下，把不同来源的精确副本保留为独立 Catalog 项并用 SQLite 关系连接；`AssetLocation` 已为未来合并为单逻辑资产保留空间。
- 自动重新挂载优先依赖现有安全书签和记录路径；当系统不能可靠恢复路径时，用户需在检查器中选择“重新关联来源”。
- 视频记录位置与哈希状态，但本阶段不生成视频离线预览。
- 真实外置盘/NAS 断开属于硬件与权限组合场景；本轮通过本地测试目录的移动、缺失与重新关联流程验证状态恢复，仍建议在目标存储设备上做一次手动回归。
