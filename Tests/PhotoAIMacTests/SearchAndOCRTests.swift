import AppKit
import Foundation
import Testing
@testable import PhotoAIMac

@MainActor
struct SearchAndOCRTests {
    @Test
    func fallbackParserExplainsAndMatchesStructuredMetadataConditions() {
        let sourceID = UUID()
        var rawAsset = fixtureAsset(sourceID: sourceID, filename: "night.ARW", fileExtension: "arw", rawType: "ARW")
        rawAsset.rating = 5
        rawAsset.ocrText = "Receipt number"

        let interpretation = SearchQueryInterpreter.fallbackInterpretation(for: "rating>=4 format:raw camera:Example text:Receipt")

        #expect(interpretation.source == .fallback)
        #expect(interpretation.query.matches(rawAsset))
        #expect(interpretation.explanation.contains("评分 ≥ 4"))
        #expect(interpretation.explanation.contains("OCR：Receipt"))
    }

    @Test
    func emptyOrUnmatchedQueryDoesNotReturnEveryAsset() {
        let asset = fixtureAsset(sourceID: UUID(), filename: "sample.jpg", fileExtension: "jpg", rawType: nil)

        #expect(!SearchQueryInterpreter.fallbackInterpretation(for: "").query.matches(asset))
        #expect(!SearchQueryInterpreter.fallbackInterpretation(for: "not-present").query.matches(asset))
    }

    @Test
    func OCRPauseThenImmediateResumeCompletesWithoutChangingSourceImage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-OCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstImageURL = rootURL.appendingPathComponent("ocr-0.jpg")
        try writeTextFixtureJPEG(to: firstImageURL)
        let originalData = try Data(contentsOf: firstImageURL)

        let source = PhotoSource(
            id: UUID(),
            bookmarkData: Data(),
            displayName: "ocr fixture",
            lastKnownPath: rootURL.path,
            createdAt: .now,
            lastScannedAt: .now,
            status: .ready,
            assetCount: 1
        )
        let assets = (0..<1).map { index in
            fixtureAsset(sourceID: source.id, filename: "ocr-\(index).jpg", fileExtension: "jpg", rawType: nil)
        }
        let catalogURL = rootURL.appendingPathComponent("catalog.json")
        try CatalogPersistence(fileURL: catalogURL).save(CatalogSnapshot(sources: [source], assets: assets))

        let catalog = CatalogStore(storageURL: catalogURL)
        let indexer = OCRIndexStore()
        indexer.start(catalog: catalog)
        indexer.pause()
        #expect(indexer.state == .paused)

        indexer.start(catalog: catalog)
        #expect(await waitForOCR(indexer))

        #expect(indexer.state == .completed)
        #expect(indexer.completedCount == 1)
        #expect(indexer.failureCount == 0)
        #expect(catalog.assets.allSatisfy { $0.ocrText != nil })
        #expect(try Data(contentsOf: firstImageURL) == originalData)
    }

    @Test
    func OCRPauseAfterWorkerCancellationThenResumeCompletes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-OCR-DelayedResume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let imageURL = rootURL.appendingPathComponent("ocr-delayed.jpg")
        try writeTextFixtureJPEG(to: imageURL)
        let source = PhotoSource(
            id: UUID(), bookmarkData: Data(), displayName: "ocr fixture", lastKnownPath: rootURL.path,
            createdAt: .now, lastScannedAt: .now, status: .ready, assetCount: 1
        )
        let asset = fixtureAsset(sourceID: source.id, filename: "ocr-delayed.jpg", fileExtension: "jpg", rawType: nil)
        let catalogURL = rootURL.appendingPathComponent("catalog.json")
        try CatalogPersistence(fileURL: catalogURL).save(CatalogSnapshot(sources: [source], assets: [asset]))

        let catalog = CatalogStore(storageURL: catalogURL)
        let indexer = OCRIndexStore()
        indexer.start(catalog: catalog)
        indexer.pause()
        #expect(indexer.state == .paused)

        // 让取消中的 worker 走到 finishIfNeeded；此时 resume 不应启动第二个并发 worker。
        try? await Task.sleep(for: .milliseconds(100))
        #expect(indexer.state == .paused)
        indexer.resume(catalog: catalog)

        #expect(await waitForOCR(indexer))
        #expect(indexer.state == .completed)
        #expect(indexer.completedCount == 1)
        #expect(indexer.failureCount == 0)
        #expect(catalog.assets.first?.ocrText != nil)
    }

    private func waitForOCR(_ indexer: OCRIndexStore) async -> Bool {
        // `start` may be invoked immediately after `pause`. The cancellation task
        // finishes asynchronously, so a transient `.paused` is expected before
        // it observes the queued resume request and switches back to `.running`.
        for _ in 0..<3_000 where indexer.state != .completed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return indexer.state == .completed
    }

    private func fixtureAsset(sourceID: UUID, filename: String, fileExtension: String, rawType: String?) -> PhotoAsset {
        PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: filename,
            filename: filename,
            fileExtension: fileExtension,
            fileSize: 1,
            modifiedAt: .now,
            captureDate: .now,
            width: 800,
            height: 400,
            cameraMake: "Example",
            cameraModel: "Example Camera",
            lens: "Example Lens",
            focalLength: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            mediaType: .image,
            rawType: rawType,
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }

    private func writeTextFixtureJPEG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 800, height: 400))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 400)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        NSString(string: "PHOTOAI OCR").draw(at: NSPoint(x: 60, y: 160), withAttributes: attributes)
        image.unlockFocus()

        let bitmap = try #require(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        let data = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        try data.write(to: url, options: .atomic)
    }
}
