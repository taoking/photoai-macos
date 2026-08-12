# Phase 3 — Library 验证

执行日期：2026-08-12  
环境：Xcode 27.0 Beta（27A5228h）、macOS 27.0 SDK、Apple Silicon。

## 实现范围

- 以 `CGImageSourceCreateThumbnailAtIndex` 在后台生成最大 480 px 的 JPEG、HEIF 与 RAW 预览；网格的惰性单元出现时才请求缩略图，不读取全分辨率渲染结果。
- 内存缩略图缓存上限为 600 项 / 160 MiB，缓存键包含 asset ID 和文件修改时间；源文件变化会自然失效旧缓存。
- Security-Scoped Bookmark 仍为首选访问方式。若未签名调试 bundle 的身份变化使既有书签失效，才回退到该来源已持久化的本地根路径；该回退不枚举或访问用户未选择的目录。
- 支持单选、Command 多选、Shift 范围选择、左右方向键移动选择。
- 支持 0–5 星、Pick、Reject、取消标记、收藏及「全部 / Pick / Reject / 4 星及以上 / 5 星」筛选；这些操作只更新本地 Catalog recipe 数据，不写入照片文件。
- Inspector 会展示当前选择的文件格式、尺寸、EXIF/TIFF 基础元数据、评分、标记和收藏状态。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 14 tests / 4 suites 通过 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，14 tests 通过 |

新增覆盖包括：

- Shift 范围选择、批量评分/标记，以及筛选结果。
- 缩略图缓存键随源文件修改时间变化。

## 人工 UI 验收

- 已确认此前的蓝紫渐变占位块被真实 RAW/JPEG 低分辨率预览替代。
- 已确认选择一个照片单元后出现选中边框，Inspector 同步展示该照片元数据。
- 为避免修改用户实际 Catalog，本次人工验收没有触发评分、Pick/Reject 或收藏；这些写入行为由自动化测试验证。

本记录不保存截图、目录、文件名、照片数量或 EXIF 值，以保护本地图库隐私。

## Phase 边界

视频缩略图目前使用类型图标；视频处理不在 MVP。编辑、裁剪与导出将从 Phase 4 开始实现。

