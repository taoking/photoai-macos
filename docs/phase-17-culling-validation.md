# Phase 17 摄影照片筛选工作流验证

## 范围

Phase 17 只扩展照片快速筛选、A/B 比较、基础分组、统计、原文件精选导出和元数据撤销。它不新增 RAW 调色、LUT、曲线、HSL、蒙版或 AI 修图；基础 Photo Group 只使用 Catalog 中已有的拍摄时间、来源目录和连续文件名，不读取源文件，也不调用 AI。

## 验证状态

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 3,000 张真实照片快速浏览 | NOT RUN | 本机当前可控 Catalog 为 922 项，没有伪造 3,000 张真实样本；另有 100,000 项纯 Catalog 性能门禁。 |
| 922 项 Culling Mode | PASS | 当前调试包中从“所有照片”进入快速筛选，Preview Cache 显示真实 ARW/JPEG；方向键在 1/922、2/922 间即时切换，Esc 返回后网格、选择和缩略图保留。 |
| 星级评分 | PASS | 真实界面按 `5` 后五星与统计同步更新；一次 Command+Z 恢复。`ratingShortcutTest` 同时验证快捷键映射与 Catalog 写入。 |
| Pick / Reject / U | PASS | 真实界面按 `P` 后 Pick 统计同步更新并以 Command+Z 恢复；`pickRejectTest` 覆盖 Pick、Reject 和清除标记。 |
| A/B Compare View | PASS | 真实 JPG/ARW 双图并排显示独立文件名和 Metadata；工具栏与手势共享缩放/位移状态，两幅图同步放大及移动。 |
| A/B 快速选择 | PASS | 真实界面选择 B 后，B 成为 Pick、A 成为 Reject；一次 Command+Z 同时恢复两张。`compareViewStateTest` 覆盖配对、变换和选择状态。 |
| 基础 Photo Group | PASS | `photoGroupTest` 验证同目录、30 秒窗口、同编号 RAW+JPEG 配对及下一连续编号形成一组，断号和不同目录不会误合并；界面显示当前连续组位置。 |
| 筛选统计 | PASS | 真实 922 项会话显示总数、Pick、五星、Reject、未处理；评分、标记、A/B 选择与撤销均增量同步统计，不重新遍历或扫描源目录。 |
| Pick / 五星 / 当前结果导出选择 | PASS | `exportSelectionTest` 验证三种选择范围；原文件复制仍保留扩展名、不覆盖目标并隔离失败。 |
| 保持目录结构 | PASS | 隔离临时目录实际把 `2026/新疆/IMG_001.ARW` 复制为 `Export/2026/新疆/IMG_001.ARW` 并逐字节比对；冲突规划生成安全后缀。 |
| 真实 UI 导出文件夹选择 | NOT RUN | 为避免在用户目录产生验证副本，本轮没有确认真实选择面板；自动化使用隔离临时目录完成实际写入。 |
| Command+Z 与批量撤销 | PASS | `undoOperationTest` 对三张照片的批量评分和批量 Reject 各以一次操作恢复；真实 A/B 双项目操作也以一次 Command+Z 恢复。 |
| 100,000 项性能 | PASS | `largeCatalogPerformanceTest` 建立 100,000 项内存会话并执行 2,000 次 O(1) 前后切换，断言最慢单步 `<100ms`；切换只更新会话索引，不读取文件或重新计算全库筛选。 |
| RAW UI 线程约束 | PASS | Culling 与 Compare 共用 Phase 16 `PhotoPreviewStore`；内存/磁盘缓存未命中时才在 detached 后台任务通过 ImageIO 生成 2,400 像素预览。 |

## 自动化命令

- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift build`：PASS。
- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift test`：PASS，90 项测试 / 17 个套件；真实 Sony RAW 编辑/导出集成项按显式环境变量门禁跳过。
- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' -quiet test`：PASS；仅输出 Xcode 27 Beta 的 destination/diagnostics 已知警告。
- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer ./Scripts/build-debug-app.sh`：PASS，当前源码已组装并 ad-hoc 签名。

## 性能与非破坏性约束

- 会话启动时只从现有 Catalog 查询结果建立 UUID → 数组位置索引、Metadata 统计快照和基础连续组；单张切换为 O(1)。
- Catalog 单项查找和元数据修改使用 UUID 索引，不再为当前照片线性查找 100,000 项。
- 所有评分/标记撤销仅恢复 JSON Catalog Metadata，不修改原文件或 EXIF；撤销栈最多保存 100 个会话内操作。
- 保持目录结构导出会校验相对目录、创建目标子目录、再次检查目标不存在，再复制原始字节。
- Preview Cache 未命中时的 RAW/视频帧生成留在后台；Culling UI 不直接读取全分辨率文件。

## Phase 17 Code Gate

当前状态：`PASS`。功能、自动化、100,000 项性能门禁、真实 922 项 UI 验证、提交与推送均已完成；交付位于堆叠 Draft [PR #5](https://github.com/taoking/photoai-macos/pull/5)，基线为 Phase 16 Draft PR #4。表中明确标注的 3,000 张真实样本和真实 UI 导出选择项仍保持 `NOT RUN`，未虚报为通过。
