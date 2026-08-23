# Phase 16 照片管理与导出验证

## 范围

Phase 16 只扩展照片管理与原文件复制导出，不新增 RAW 调色、LUT、曲线、HSL、蒙版或 AI 修图。评分、标记、颜色标签和备注继续保存在 JSON Catalog；筛选使用 Catalog 派生内存索引缓存，不重新扫描磁盘，也不重构现有持久化方案。

## 验证状态

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| JPEG 大图浏览 | PASS | 在真实 922 项本地 Catalog 中点击 `DSC01872.JPG`，PhotoViewer 显示屏幕适配大图、真实路径和 EXIF 摘要。 |
| RAW Preview | PASS | 点击 `DSC01872.ARW` 后从离线缓存优先路径加载 RAW Preview；解码在后台执行，界面操作区保持响应。 |
| 前后切换 | PASS | 方向键在 `DSC01872.ARW` 与 `DSC01872.JPG` 间切换，文件名、大小、图片和元数据同步更新。 |
| Esc / Space 返回 | PASS | 在最终调试包中分别用 Esc 与 Space 返回同一图库上下文，922 项网格与缩略图保持可见。 |
| 星级评分 | PASS | 真实界面用 `5` 显示五星后以 `0` 恢复；`ratingPersistence` 验证重启读取。 |
| Pick / Reject | PASS | 真实界面用 `P` 设置后以 `U` 恢复；`flagPersistence` 验证新 JSON 写为 `picked`，并兼容旧 `pick/reject` 值。 |
| Catalog 筛选 | PASS | `filterByRating`、`filterByFlag` 通过；筛选包含全部、未评分、五星、Pick、Reject、RAW、视频和重复照片。 |
| Command / Shift 多选与批量操作 | PASS | `multiSelectionOperation` 与既有范围选择测试通过；工具栏支持批量评分、Pick、Reject 和取消标记。 |
| 原文件单张/多张/筛选结果导出 | PASS | 独立原文件导出器按后台任务复制，保留扩展名；`exportLargeBatch` 成功复制 500/500 个文件。 |
| RAW 字节保持与冲突命名 | PASS | `exportFilenameConflict` 保留既有 `IMG_001.ARW`，新文件写为 `IMG_001-2.ARW`，内容与源字节一致。 |
| 导出进度与取消 | PASS | 状态包含总数、完成数、当前文件、失败数和取消；`exportCancellation` 在 2,000 项计划完成前取消。 |
| 50,000 项 Catalog | PASS | `cachedCatalogFilteringScalesToFiftyThousandAssets` 验证 50,000 项中 5,000 个 Pick 首次建立缓存；选择变化后的界面重绘不重新计算全库筛选。 |
| Apple Photos 大图 | NOT RUN | 本轮调试包处于未授权状态，没有触发新的系统照片权限请求；代码明确显示 Apple Photos 无公开真实路径，浏览仍禁止网络下载原件。 |
| HEIC / PNG 真实文件预览 | NOT RUN | ImageIO 路径与 JPEG 共用且扩展名已被 Catalog 支持，但本轮真实图库首屏未提供可控 HEIC / PNG 样本。 |
| 视频真实缩略图 | NOT RUN | AVFoundation 异步帧提取已编译接入，但本轮没有使用可控视频样本做人工画面验收。 |
| UI 文件夹选择与真实批量写入 | NOT RUN | 为避免在用户真实照片目录产生验证副本，本轮用隔离临时目录完成自动化复制、冲突、失败和取消验证。 |

## 自动化命令

- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift build`：PASS。
- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift test`：PASS，82 项测试 / 16 个套件；真实 Sony RAW 编辑/导出集成项按显式环境变量门禁跳过。
- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' -quiet test`：PASS；仅输出 Xcode 27 Beta 的 destination/diagnostics 已知警告。
- `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer ./Scripts/build-debug-app.sh`：PASS，最新源码已组装并 ad-hoc 签名。

## 性能与安全约束

- PhotoViewer 先读内存/磁盘离线 Preview Cache；缓存未命中时才在后台生成最大 2,400 像素预览。
- Catalog 查询结果按目标页和筛选缓存；选择、检查器和普通界面重绘不再重复遍历 50,000 项。
- 原文件导出在后台串行复制，目标名在启动前统一分配；写入前再次检查目标不存在，绝不覆盖。
- 取消在当前文件边界生效；已成功复制的文件保留，未开始项目不会写入。
- Apple Photos 不伪造路径；未授权时不读取图库，浏览预览不允许网络下载。

## Phase 16 Code Gate

当前状态：`PASS`。功能、自动化、50,000 项索引路径、本机 UI 验证、提交与推送均已完成；交付位于 Draft [PR #4](https://github.com/taoking/photoai-macos/pull/4)。表中明确标注的真实样本/权限项仍保持 `NOT RUN`，未虚报为通过。
