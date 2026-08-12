# Phase 11 验收记录 — Apple Photos Source

日期：2026-08-12  
开发环境：Xcode 27.0 Beta（macOS 27.0 SDK）

## 已完成

- 新增独立的 Apple Photos 数据源，不与文件夹 `Catalog`、安全书签或 `PhotoAsset` 混合。
- 接入 PhotoKit 授权状态、相簿、收藏筛选和资产索引模型；资产可用性用 `PHImageRequestOptions.isNetworkAccessAllowed = false` 检查，因此不会因读取索引自动下载 iCloud 原件。
- 未授权、受限、拒绝、有限授权和读取失败均有明确状态；只有用户主动点击“授权并读取 Apple Photos”才请求系统权限和读取资产。
- 添加 `NSPhotoLibraryUsageDescription`，说明访问范围仅限用户主动授权后的本地索引，且不会修改 Apple Photos 内容。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test --filter ApplePhotosStoreTests` | 通过，3 tests / 1 suite；覆盖授权状态映射、初始状态不请求权限/不加载资产，以及 iCloud 可用性模型。 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过，43 tests / 13 suites。 |

## 本机界面验证与限制

- 已打开调试 `.app` 的“Apple Photos”页面；本机状态为“尚未授权访问 Apple Photos”，界面只显示“授权并读取 Apple Photos”，并明确说明未授权时文件夹 Catalog 不受影响。
- 本次未点击授权按钮，未触发系统权限提示，未读取 Apple Photos 资产，也未下载 iCloud 项目。因此，已授权、有限授权和实际 iCloud 仅云端资产的 PhotoKit 运行时回调仍需在用户主动授权后复测。
