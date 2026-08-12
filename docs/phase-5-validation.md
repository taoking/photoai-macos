# Phase 5 验收记录 — RAW + LUT

日期：2026-08-12  
开发环境：Xcode 27.0 Beta（macOS 27.0 SDK）

## 已完成

- RAW 预览使用 `CIRAWFilter`，依据目标最大像素尺寸设置缩放和 draft mode；全分辨率 JPEG 导出关闭 draft mode 并以原生尺寸渲染。
- RAW、JPEG / HEIF 的预览与导出共同经过 `ImageProcessingPipeline`，保证 `EditRecipe` 的几何和颜色调整语义一致。
- `.cube` LUT 支持：结构校验、颜色表解码、`DOMAIN_MIN` / `DOMAIN_MAX`、`CIColorCube` 应用、强度混合、本地安全书签持久化、编辑器选择及设置页导入/移除管理。
- 编辑器提供“导出 JPEG…”入口；导出仅创建新文件。导出失败时只清理由本次新建的目标文件，绝不删除原始照片或既有文件。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过，21 tests / 6 suites |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，21 tests / 6 suites |

新增测试覆盖：

- 合成 JPEG 的预览/导出一致性；
- `.cube` 的有效表、错误数据行、解析、Core Image 应用和本地预设持久化；
- 本机 Catalog 中实际可访问的 Sony ARW：RAW 预览、全分辨率 JPEG 导出，以及临时输出目录的清理。

## 实机界面验证

- 已通过本机调试 `.app` 打开真实 RAW 照片，确认 `CIRAWFilter` 预览成功显示，并可见 RAW 编辑面板、LUT 区域和 JPEG 导出入口。
- 本次界面检查未改变调整值，也未通过界面保存任何导出文件；自动化 RAW 导出只写入系统临时目录，并在测试结束时删除。

## 已知边界

- 当前导出目标为 JPEG；其他交付格式和批量队列由后续阶段扩展。
- `.cube` 支持通用 3D 色表；包含 1D + 3D 混合声明或非文本编码的 LUT 会被拒绝，而不会做不确定的颜色处理。
