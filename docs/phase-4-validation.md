# Phase 4 验收记录 — JPEG / HEIF Editor

日期：2026-08-12  
开发环境：Xcode 27.0 Beta（macOS 27.0 SDK）

## 已完成

- `EditRecipe` 采用带版本号的 Codable 数据模型，随 Catalog 本地持久化；原始照片没有写入路径。
- JPEG / HEIF 编辑器提供曝光、对比度、高光、阴影、色温、色调、饱和度、居中比例裁剪、旋转和还原。
- 预览与 JPEG 导出共用 `ImageProcessingPipeline.apply`，避免两套处理语义偏离。
- 预览在后台队列渲染，导出从原尺寸图像创建处理结果；两者都使用安全书签失败时的受控本地路径回退。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过，17 tests / 5 suites |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，17 tests / 5 suites |

新增测试覆盖：

- 居中裁剪的目标比例；
- `EditRecipe` 重启后持久化，同时保留原始文件字段；
- 合成 JPEG 的预览与导出均输出相同的裁剪尺寸。

## 实机界面验证

- 已通过本机调试 `.app` 打开索引中的 JPEG，确认真实缩略预览、调整面板、裁剪比例菜单、旋转控制、胶片带与“完成”返回均可用。
- 本次界面检查未改变任何调整值；应用提示与实现均保持“只写入本地 EditRecipe、原文件不修改”的约束。

## 已知边界

- Phase 4 的界面编辑入口仅对 JPEG / HEIF 开放；RAW 编辑、LUT 与完整 RAW 导出由 Phase 5 实现并验证。
