import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoAIMac

struct CleanupWorkflowTests {
    @Test
    func generatesLocalRecommendationsWithoutChangingSourceFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let duplicateA = root.appendingPathComponent("duplicate-a.png")
        let duplicateB = root.appendingPathComponent("duplicate-b.png")
        try writePatternImage(to: duplicateA, type: .png)
        try Data(contentsOf: duplicateA).write(to: duplicateB)

        let similarPNG = root.appendingPathComponent("similar-one.png")
        let similarJPEG = root.appendingPathComponent("similar-two.jpg")
        try writePatternImage(to: similarPNG, type: .png)
        try writePatternImage(to: similarJPEG, type: .jpeg)

        let rawURL = root.appendingPathComponent("PAIR.DNG")
        try Data([0x01, 0x02, 0x03, 0x04, 0x05]).write(to: rawURL)
        let pairedJPEG = root.appendingPathComponent("PAIR.JPG")
        try writePatternImage(to: pairedJPEG, type: .jpeg)

        let screenshot = root.appendingPathComponent("Screenshot 2026-08-12.png")
        try writePatternImage(to: screenshot, type: .png)
        let original = root.appendingPathComponent("Vacation.jpg")
        let exported = root.appendingPathComponent("Vacation-Edited.jpg")
        try writePatternImage(to: original, type: .jpeg)
        try writePatternImage(to: exported, type: .jpeg)

        let urls: [(URL, Bool)] = [
            (duplicateA, false), (duplicateB, false), (similarPNG, false), (similarJPEG, false),
            (rawURL, true), (pairedJPEG, false), (screenshot, false), (original, false), (exported, false)
        ]
        let before = try Data(contentsOf: duplicateA)
        let requests = try urls.map { try request(for: $0.0, root: root, isRAW: $0.1) }

        let result = try await CleanupAnalyzer.analyze(requests)
        let kinds = Set(result.recommendations.map(\.kind))

        #expect(kinds.contains(.exactDuplicate))
        #expect(kinds.contains(.similar))
        #expect(kinds.contains(.rawJPEGPair))
        #expect(kinds.contains(.screenshot))
        #expect(kinds.contains(.editedExport))
        #expect(try Data(contentsOf: duplicateA) == before)
    }

    @Test
    func trashRequiresExplicitServiceAndReportsInaccessibleSources() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("candidate.jpg")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)
        let request = try request(for: fileURL, root: root, isRAW: false)
        let mover = RecordingTrashMover()

        let success = CleanupTrashService.moveToTrash([request], mover: mover)
        #expect(success.movedAssetIDs == [request.assetID])
        #expect(mover.urls == [fileURL])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let inaccessible = CleanupAssetRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: root.appendingPathComponent("disconnected").path,
            relativePath: "missing.jpg",
            filename: "missing.jpg",
            fileExtension: "jpg",
            fileSize: 1,
            captureDate: nil,
            isRAW: false,
            hasEdits: false
        )
        let failure = CleanupTrashService.moveToTrash([inaccessible], mover: mover)
        #expect(failure.movedAssetIDs.isEmpty)
        #expect(failure.failures.count == 1)
        #expect(failure.failures[0].message.contains("外置磁盘"))
    }

    @Test
    func systemTrashMoverMovesOnlyExplicitTemporaryFileAndCanRestoreIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("restore-after-test.jpg")
        try Data([0xAA, 0xBB, 0xCC]).write(to: fileURL)

        let trashedURL = try SystemTrashMover().trash(fileURL)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: trashedURL.path))

        try FileManager.default.moveItem(at: trashedURL, to: fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func request(for url: URL, root: URL, isRAW: Bool) throws -> CleanupAssetRequest {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return CleanupAssetRequest(
            assetID: UUID(),
            bookmarkData: Data(),
            lastKnownRootPath: root.path,
            relativePath: url.lastPathComponent,
            filename: url.lastPathComponent,
            fileExtension: url.pathExtension,
            fileSize: Int64(values.fileSize ?? 0),
            captureDate: Date(timeIntervalSinceReferenceDate: 100),
            isRAW: isRAW,
            hasEdits: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-Cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePatternImage(to url: URL, type: UTType) throws {
        let width = 24
        let height = 24
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 9 + y * 3) % 256)
                pixels[offset + 1] = UInt8((x * 5 + y * 11) % 256)
                pixels[offset + 2] = UInt8((x * 13 + y * 7) % 256)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private final class RecordingTrashMover: CleanupTrashMoving {
    var urls: [URL] = []

    func trash(_ url: URL) throws -> URL {
        urls.append(url)
        return url
    }
}
