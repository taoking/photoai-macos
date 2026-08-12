import CoreImage
import Foundation
import Photos
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(MediaIntelligence)
import MediaIntelligence
#endif

struct SDKCapability: Identifiable, Equatable {
    let name: String
    let isAvailable: Bool
    let detail: String

    var id: String { name }
}

enum SDKCapabilityProbe {
    static let capabilities: [SDKCapability] = [
        .init(
            name: "Core Image RAW",
            isAvailable: true,
            detail: "CIRAWFilter 可在当前 SDK 编译；真实 RAW 工作流仍需素材验证。"
        ),
        .init(
            name: "LUT (.cube)",
            isAvailable: true,
            detail: "基础 .cube 结构验证已实现；渲染管线留待 Phase 5。"
        ),
        .init(
            name: "Vision OCR",
            isAvailable: true,
            detail: "VNRecognizeTextRequest 可在当前 SDK 编译；尚未对图片运行 OCR。"
        ),
        .init(
            name: "PhotoKit",
            isAvailable: true,
            detail: "PHPhotoLibrary / PHAsset 可在当前 SDK 编译；读取权限与 iCloud 状态须在用户授权的运行时确认。"
        ),
        .init(
            name: "Foundation Models",
            isAvailable: hasFoundationModelsModule,
            detail: hasFoundationModelsModule
                ? "LanguageModelSession 可在当前 SDK 编译；模型可用性须在真机运行时确认。"
                : "当前 SDK 不提供 FoundationModels 模块。"
        ),
        .init(
            name: "Media Intelligence",
            isAvailable: hasMediaIntelligenceModule,
            detail: hasMediaIntelligenceModule
                ? "FaceGroupAnalyzer 可在 macOS 27 SDK 编译；真实人脸分组工作流留待 Phase 8。"
                : "当前 SDK 不提供 MediaIntelligence 模块。"
        )
    ]

    static func compileTimeSmokeTest() {
        _ = CIRAWFilter.self
        _ = CIFilter.self
        _ = VNRecognizeTextRequest.self
        _ = PHPhotoLibrary.self
        _ = PHAsset.self

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            _ = LanguageModelSession.self
        }
        #endif

        #if canImport(MediaIntelligence)
        if #available(macOS 27.0, *) {
            _ = MediaIntelligenceImageAsset.self
            _ = FaceGroupAnalyzer.self
        }
        #endif
    }

    private static var hasFoundationModelsModule: Bool {
        #if canImport(FoundationModels)
        true
        #else
        false
        #endif
    }

    private static var hasMediaIntelligenceModule: Bool {
        #if canImport(MediaIntelligence)
        true
        #else
        false
        #endif
    }
}
