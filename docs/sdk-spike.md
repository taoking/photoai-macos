# Phase 0 SDK / Reuse Spike

执行日期：2026-08-12  
环境：Apple Silicon、Xcode 27.0 Beta（27A5228h）、macOS 27.0 SDK、Swift 6.4。

> 本机通过 `/path/to/Xcode-beta.app` 使用 Xcode 27.0 Beta。该 SDK 仍处于 Beta 阶段，所有 API 结论应在正式 SDK 发布后复查。

## 编译验证

| 能力 | 编译结果 | 运行时/真实素材结果 | 结论 |
| --- | --- | --- | --- |
| SwiftUI macOS target | `swift build` 与 `xcodebuild … build` 均通过，二进制 `LC_BUILD_VERSION` 为 minOS 27.0 / SDK 27.0 | 未作人工窗口交互验收 | 可构建 |
| Core Image RAW (`CIRAWFilter`) | 已通过 Xcode 27 Beta 独立 `swiftc -typecheck` | 无 RAW 素材；未打开、预览、全分辨率渲染或导出 | 仅接口可编译 |
| LUT | `.cube` 最小头部校验由单元测试覆盖 | 未进行色彩渲染或导出 | Phase 5 前不可称为 LUT 编辑已支持 |
| Vision (`VNRecognizeTextRequest`) | 已通过 Xcode 27 Beta 独立 `swiftc -typecheck` | 未对真实图片执行 OCR | 仅接口可编译 |
| Foundation Models (`LanguageModelSession`) | 已通过 Xcode 27 Beta 独立 `swiftc -typecheck` | 未确认设备模型下载、可用性或推理 | 仅接口可编译 |
| Media Intelligence (`FaceGroupAnalyzer`) | 已通过 Xcode 27 Beta 独立 `swiftc -typecheck` | 未对真实图片运行分组或持久化其 entity | 仅接口可编译 |

## 已执行的独立接口检查

```sh
xcrun swiftc -typecheck -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target arm64-apple-macosx27.0 -
```

输入同时引用 `CIRAWFilter`、`VNRecognizeTextRequest`、`LanguageModelSession` 与 `FaceGroupAnalyzer`，结果为成功。`MediaIntelligence.framework` 的 Swift interface 声明为 macOS 27.0 可用，且提供 `FaceGroupAnalyzer`、`MediaIntelligenceImageAsset` 与 `VideoAnalyzer`。

## 复用评估

当前目录仅包含产品计划，未提供 `photoai-ios` 源码、Swift Package 或已构建模块，故不能在本机识别或验证 Domain、RAW、LUT、Search、Persistence 等复用边界。待 iOS 工程被置入可读取范围后，再单独编译并记录结果；在此之前不做跨项目重构。

## 下一步与验收边界

Phase 0 的编译验收已完成，结果如下：

```text
DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift build
# Build complete! (6.58秒)

DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test
# 5 tests in 2 suites passed

DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer \
  xcodebuild -scheme PhotoAIMac -destination 'platform=macOS' build
# ** BUILD SUCCEEDED **

DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer \
  xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test
# ** TEST SUCCEEDED ** (5 tests)
```

在进入相关功能阶段前仍需：

1. 使用公开或合成的 DNG/ARW fixture 分别验证 RAW 的打开、预览、全分辨率渲染与导出。
2. 在正式 Xcode 27 SDK 发布后重跑所有编译检查，并确认 Beta API 是否变化。
3. Phase 0 已完成；根据总计划，等待确认后才进入 Phase 1。
