# Phase 6 验收记录 — Batch Workflow

日期：2026-08-12  
开发环境：Xcode 27.0 Beta（macOS 27.0 SDK）

## 已完成

- 在现有单选、Shift / Command 多选基础上增加“批处理”入口：复制调整、粘贴调整、以选中主照片同步调整。
- 调整仍然只写入 Catalog 的 `EditRecipe`；批量复制和同步不接触原始图像文件。
- 提供“高质量 JPEG”和“紧凑 JPEG”两个持久化导出预设；设置页可选择默认预设。
- 批量导出在后台独立任务中运行，显示进度、成功数、失败数并支持取消；单个文件失败会记录原因而不会中断剩余队列。
- 输出文件名自动去重；导出仍使用统一的 JPEG 渲染器，保留 RAW / LUT / EditRecipe 语义。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过；Phase 6 收尾时为 25 tests / 7 suites，后续整合测试为 28 tests / 8 suites |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，28 tests / 8 suites |

新增批处理测试使用隔离临时目录，覆盖：

- 复制、粘贴和同步配方后原始 JPEG 字节保持不变；
- 50 项 JPEG 队列全部完成；
- 三项队列中的单个缺失文件被报告，同时其余两项成功；
- 100 项队列在取消后停止未处理的剩余任务；
- 自定义导出预设重启后保留。

## 实机界面验证

- 已在本机调试 `.app` 选择照片并打开“批处理”菜单，确认复制调整、禁用态粘贴/同步、批量导出以及两种 JPEG 预设可见且可访问。
- 本次界面检查未执行粘贴、同步或导出，因此没有修改 Catalog 配方，也没有创建用户可见导出文件。
