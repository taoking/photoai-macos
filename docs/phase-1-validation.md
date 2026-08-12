# Phase 1 — App Shell 验证

执行日期：2026-08-12  
环境：Xcode 27.0 Beta（27A5228h）、macOS 27.0 SDK、Apple Silicon。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift build` | 通过 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 9/9 tests 通过 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，9/9 tests |

## 人工 UI 验收

使用本地调试 bundle（未提交）启动后，已确认：

- Sidebar 包含所有计划中的顶层入口，且选择 RAW 会更新内容区。
- 中间区显示桌面尺寸的可滚动缩略图占位网格和状态栏。
- 右侧 Inspector 显示元数据与筛选占位项。
- Toolbar 中的「添加来源」、缩略图大小及 Inspector 切换控件可访问。
- 隐藏 Inspector 后，Sidebar 仍保持显示；重新显示后 Inspector 恢复。
- 应用窗口标题保持为「PhotoAI Mac」。

验收中发现并修复两处问题：

1. `NavigationSplitViewVisibility.doubleColumn` 会隐藏 Sidebar 而非 Inspector。现改用双栏 `NavigationSplitView` 加内容区内 `HSplitView`，只移除右侧 Inspector。
2. Inspector 的 `navigationTitle` 覆盖了窗口标题；已移除该修饰符。

## Phase 边界

本阶段只实现 App Shell，不读取、复制或修改任何用户照片。实际文件夹访问、索引和元数据会在 Phase 2 实现。

