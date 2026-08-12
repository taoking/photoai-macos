# Phase 8 验收记录 — People

日期：2026-08-12  
开发环境：Xcode 27.0 Beta（macOS 27.0 SDK）

## 已完成

- 通过 `MediaIntelligenceImageAsset` 与 `FaceGroupAnalyzer` 接入本地人物分组；运行前先探测服务可用性，失败时保留明确、可恢复的错误状态。
- 人物库使用独立、可恢复的本地 `people.json` 保存人物记录、名称、隐藏状态、合并关系和分析器实体关联；用户人物 ID 不依赖或等同于任何单一 analyzer entity ID。
- 人物页提供名称搜索、重命名、合并、隐藏，以及仅在用户主动点击后才会执行的本地照片分析入口。
- 每张人物卡片从已有本地缩略图中裁剪并显示最多三张人脸样本，面积较大的人脸优先；可点击“查看照片”回到图库并定位来源照片。未命名人物会显示直接命名输入框及说明，便于辨认后再保存名称。
- 分析器访问原图时复用已有安全书签；不上传照片、人脸结果或人物名称。

## 自动化验证

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test --filter 'FacePreviewRendererTests\|PeopleStoreTests'` | 通过，5 tests / 2 suites；覆盖人脸预览裁剪、边缘裁剪、样本排序及人物记录恢复。 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过，46 tests / 14 suites。 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，46 tests / 14 suites。 |

## 本机界面与 API 验证

- 已在调试 `.app` 打开“人物”工具页，人物服务显示为可用，证明 macOS 27 beta 上 `FaceGroupAnalyzer` 可成功初始化。
- 本次只完成初始化探测，未点击“分析本地照片”；因此未对用户图片执行人脸检测，也未写入人物数据库。完整分组效果应在用户主动开始分析后，针对其许可的素材另行复测。
- 2026-08-12 已在现有人物分组数据上验证：每张人物卡片都暴露关联照片预览、来源照片定位和命名输入入口；验证期间未写入人物名称，未重新分析照片。
