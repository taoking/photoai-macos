import Testing
@testable import PhotoAIMac

struct SDKCapabilityProbeTests {
    @Test
    @MainActor
    func loadsBundledPhotoAILogo() throws {
        let logo = try #require(PhotoAIBrandAssets.logoImage)

        #expect(logo.size.width > 0)
        #expect(logo.size.height > 0)
    }

    @Test
    func compilesDeclaredFrameworkSymbols() {
        SDKCapabilityProbe.compileTimeSmokeTest()
    }

    @Test
    func reportsCoreCapabilities() {
        let names = Set(SDKCapabilityProbe.capabilities.map(\.name))

        #expect(names.isSuperset(of: ["Core Image RAW", "LUT (.cube)", "Vision OCR", "PhotoKit", "Foundation Models", "Media Intelligence"]))
    }

    @Test
    func reportsMacOS27MediaIntelligenceCapability() {
        let mediaIntelligence = SDKCapabilityProbe.capabilities.first { $0.name == "Media Intelligence" }

        #expect(mediaIntelligence?.isAvailable == true)
    }
}
