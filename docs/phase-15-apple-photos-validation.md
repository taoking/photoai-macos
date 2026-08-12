# Phase 15 验收记录 — Apple Photos 系统相册接入

日期：2026-08-13
开发环境：macOS 27 Golden Gate beta / Xcode 27 beta（macOS 27 SDK）

## 设计与安全边界

- Apple Photos 保持独立的内存模型：主身份为 `PHAsset.localIdentifier`，不创建假的文件系统路径，也不会写入 `catalog.json`。
- 应用启动只读取当前授权状态；不会请求权限、枚举图库、请求缩略图或下载 iCloud 原件。系统授权只由“授权并读取 Apple Photos”按钮触发。
- Xcode 27 SDK 中可读取图库的公开访问级别为 `PHAccessLevel.readWrite`；`addOnly` 不能浏览。实现只调用查询和读取 API，没有 `performChanges`、`PHAssetChangeRequest` 或相簿变更 API。
- 浏览的缩略图和预览通过 `PHCachingImageManager` / `PHImageManager` 按可见 Cell 或单个选中项惰性请求，缩略图预热窗口最多保留 96 项；请求均显式 `isNetworkAccessAllowed = false`。初始元数据枚举不做逐资产 iCloud 探测。
- 只有用户点击“导入到 PhotoAI…”并选择目标文件夹后，才对所选资源使用 `PHAssetResourceManager.requestData` 且设为 `isNetworkAccessAllowed = true`。导入并发限制为 2，可取消，文件名冲突使用 `-2`、`-3` 后缀，绝不覆盖现有文件。
- 导入保留原始资源：RAW+JPEG 同时导入，Live Photo 导入静态照片及配对视频，普通视频导入原始视频。仅在没有可用原始资源时才会导入明确标记的全尺寸回退资源。
- 文件真正写入后才调用本地 `CatalogStore.addFolder` 进行扫描；导入前不会创建 `PhotoAsset`，也不会自动触发 OCR、人物、清理、选片或编辑。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift build` | 通过。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer swift test` | 通过，61 tests / 15 suites；真实 Sony RAW 集成测试按既有条件显式 `SKIPPED`。 |
| `DEVELOPER_DIR=/Users/tao/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，61 tests / 15 suites；测试日志含既有 Xcode beta 环境警告，但没有失败。 |
| `rg -n "availability\\(for: asset\\)|isSynchronous|requestImage\\(|isNetworkAccessAllowed|requestData\\(|writeData\\(" Sources/PhotoAIMac/ApplePhotos*.swift` | 代码审查通过：没有初始全图库同步 iCloud 探测；浏览查询均禁止网络，只有显式导入资源的路径允许网络。 |
| `rg -n "PHPhotoLibrary|PHAssetChangeRequest|PHAssetCollectionChangeRequest|performChanges" Sources/PhotoAIMac/ApplePhotos*.swift` | 代码审查通过：仅有授权状态/授权请求；无 PhotoKit 写入或修改 API。 |
| `git diff --check` | 通过。 |

自动测试覆盖：授权状态、初始 Store 不请求权限、资源模型、收藏/视频/RAW/日期筛选、单选/Command 多选/Shift 范围选择、冲突安全命名、RAW+JPEG、Live Photo、视频与回退资源规划、取消状态、导入结果汇总及双并发限制。

## 人工 UI 验证

| 场景 | 状态 | 结果 |
| --- | --- | --- |
| 未授权启动 | PASS | 打开调试 App 的 Apple Photos 页面，显示“授权并读取 Apple Photos”；未点击该按钮，未出现权限提示，导入按钮禁用。 |
| 未授权界面 | PASS | 显示浏览/相簿/日期/文件名筛选控件、零项目计数、明确的下一步及无网络 Preview 说明。 |
| 授权成功 | NOT RUN | 本轮不接受或修改系统照片权限。 |
| 拒绝 / Restricted / Limited | NOT RUN | 需要受控系统权限状态后复测。 |
| 加载全部照片 / 最近项目 | NOT RUN | 需要用户主动授权后复测。 |
| 相簿 / 收藏 / 视频 / RAW | NOT RUN | 需要受控 Apple Photos 测试素材后复测。 |
| Live Photo、Grid 滚动、多选、屏幕预览 | NOT RUN | 需要受控 Apple Photos 测试素材后复测。 |
| iCloud-only 浏览不下载 | NOT RUN | 代码已明确关闭浏览网络；仍需真实仅云端项目复测。 |
| 显式导入 iCloud 原件、取消、重名 | NOT RUN | 需要用户选择测试目录及受控相册素材后复测。 |
| 导入后 Catalog Rescan / Phase 14 Archive | NOT RUN | Phase 14 PR #2 在本阶段基线的 `main` 上尚未合并；本实现完成 Catalog 接入，待合并后的 Archive 工作流复测。 |

## Gate

Phase 15 Gate：**NOT READY**。

原因不是自动化或构建失败，而是真实授权后的 Apple Photos、受限访问、iCloud-only 资源、写入用户选择目录及随后 Archive 的人工运行时验证尚未执行。本阶段已提交独立实现，等待 Draft PR 审核及受控人工复测；没有合并 PR、没有创建 Release。
