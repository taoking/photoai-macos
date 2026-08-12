import AppKit
import Foundation
import UniformTypeIdentifiers

struct LUTPreset: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var bookmarkData: Data
    var lastKnownPath: String
    var dimension: Int
    var importedAt: Date
}

struct LUTRenderRecipe: Hashable, Sendable {
    let cube: DecodedCubeLUT
    let intensity: Double
}

private struct LUTLibrarySnapshot: Codable {
    var presets: [LUTPreset]
}

private struct LUTLibraryPersistence {
    let fileURL: URL

    static let defaultFileURL: URL = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("PhotoAI-Mac", isDirectory: true)
            .appendingPathComponent("luts.json")
    }()

    func load() throws -> LUTLibrarySnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LUTLibrarySnapshot(presets: []) }
        return try JSONDecoder().decode(LUTLibrarySnapshot.self, from: Data(contentsOf: fileURL))
    }

    func save(_ snapshot: LUTLibrarySnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class LUTStore: ObservableObject {
    @Published private(set) var presets: [LUTPreset]
    @Published private(set) var lastErrorMessage: String?

    private let persistence: LUTLibraryPersistence
    private var decodedCache: [UUID: DecodedCubeLUT] = [:]

    init(storageURL: URL = LUTLibraryPersistence.defaultFileURL) {
        persistence = LUTLibraryPersistence(fileURL: storageURL)
        do {
            presets = try persistence.load().presets
        } catch {
            presets = []
            lastErrorMessage = "无法读取本地 LUT：\(error.localizedDescription)"
        }
    }

    func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "导入 .cube LUT"
        panel.message = "PhotoAI Mac 仅保存本地访问权限，不会复制或修改 LUT 文件。"
        panel.prompt = "导入 LUT"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLUT(at: url)
    }

    func importLUT(at url: URL) {
        let standardizedURL = url.standardizedFileURL
        do {
            let decoded = try decodeLUT(at: standardizedURL)
            let bookmarkData = try standardizedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            if let existing = presets.first(where: { $0.lastKnownPath == standardizedURL.path }) {
                decodedCache[existing.id] = decoded
                return
            }

            let preset = LUTPreset(
                id: UUID(),
                name: standardizedURL.deletingPathExtension().lastPathComponent,
                bookmarkData: bookmarkData,
                lastKnownPath: standardizedURL.path,
                dimension: decoded.dimension,
                importedAt: .now
            )
            presets.append(preset)
            presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            decodedCache[preset.id] = decoded
            persist()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "无法导入 LUT：\(error.localizedDescription)"
        }
    }

    func remove(_ presetID: UUID) {
        presets.removeAll { $0.id == presetID }
        decodedCache[presetID] = nil
        persist()
    }

    func renderRecipe(for recipe: EditRecipe) -> LUTRenderRecipe? {
        guard let lut = recipe.lut,
              let cube = decodedCube(for: lut.presetID) else {
            return nil
        }
        return LUTRenderRecipe(cube: cube, intensity: lut.intensity)
    }

    func title(for presetID: UUID) -> String? {
        presets.first(where: { $0.id == presetID })?.name
    }

    private func decodedCube(for presetID: UUID) -> DecodedCubeLUT? {
        if let cached = decodedCache[presetID] {
            return cached
        }
        guard let preset = presets.first(where: { $0.id == presetID }) else { return nil }

        do {
            let decoded = try decodeLUT(at: resolveURL(for: preset))
            decodedCache[presetID] = decoded
            return decoded
        } catch {
            lastErrorMessage = "无法读取 LUT：\(error.localizedDescription)"
            return nil
        }
    }

    private func decodeLUT(at url: URL) throws -> DecodedCubeLUT {
        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return try CubeLUTValidator.decode(contents).get()
    }

    private func resolveURL(for preset: LUTPreset) throws -> URL {
        if !preset.bookmarkData.isEmpty {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: preset.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        let fallback = URL(fileURLWithPath: preset.lastKnownPath)
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return fallback
    }

    private func persist() {
        do {
            try persistence.save(LUTLibrarySnapshot(presets: presets))
        } catch {
            lastErrorMessage = "无法保存本地 LUT：\(error.localizedDescription)"
        }
    }
}
