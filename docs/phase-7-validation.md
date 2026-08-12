# Phase 7 验收记录 — Search + OCR

日期：2026-08-12  
开发环境：Xcode 27.0 Beta（macOS 27.0 SDK）

## 已完成

- 搜索工具页支持文件名、格式、RAW、相机、镜头、评分、收藏、Pick / Reject、拍摄日期和 OCR 文字的本地组合查询。
- 结构化条件以确定性本地规则执行并显示解释；示例：`rating>=4 format:raw`、`camera:Sony`、`text:invoice`、`after:2026-01-01`。
- 当用户选择“解释自然语言”时，系统可用才调用 `FoundationModels` 将请求转换为本地 DSL；模型不可用、拒答或解释无有效条件时，无条件回退到本地解析器。
- OCR 使用 `VNRecognizeTextRequest` 在后台读取受安全书签保护的本地图片缩略版本；识别文本仅保存在本地 Catalog。索引可暂停和继续，失败项不会影响其它项。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test --filter SearchAndOCRTests` | 通过，3 tests / 1 suite；包含 Vision OCR 暂停/恢复实测 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过，28 tests / 8 suites |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，28 tests / 8 suites |

OCR 的首次 Vision 模型冷启动在本机 beta 环境约需 25 秒；因此实现使用 `.utility` 后台任务并支持暂停，不阻塞图库或编辑器。

`xcodebuild` 的首次 OCR 测试曾输出 TextRecognition E5 模型资源路径警告，但 Vision 请求完成、OCR 暂停/恢复测试通过；该警告未导致错误或索引失败，后续系统 beta 更新时仍建议复测。

## 实机界面验证

- 已在调试 `.app` 打开“搜索”工具页，确认空搜索提示、条件解释、自然语言解释按钮和 OCR 暂停/继续入口可用。
- 输入 `format:raw` 后，界面仅显示本机 Catalog 中的 RAW 结果，并明确展示“本地规则解析：格式：raw”；此检查未启动 OCR 索引，也未改变任何原始文件或 Catalog 内容。
