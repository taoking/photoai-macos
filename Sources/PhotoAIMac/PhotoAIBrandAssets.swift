import AppKit

@MainActor
enum PhotoAIBrandAssets {
    static let logoImage: NSImage? = {
        guard let url = Bundle.module.url(
            forResource: "PhotoAI-Logo",
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
