import CoreImage
import Foundation
import Testing
@testable import PhotoAIMac

struct CubeLUTValidatorTests {
    @Test
    func acceptsValid3DCubeHeader() throws {
        let contents = """
        TITLE \"Warm\"
        LUT_3D_SIZE 33
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        """

        let result = CubeLUTValidator.validate(contents)
        #expect(try result.get() == 33)
    }

    @Test
    func rejectsMissingSizeHeader() {
        #expect(CubeLUTValidator.validate("TITLE \"Warm\"") == .failure(.missing3DSize))
    }

    @Test
    func rejectsInvalidSizeHeader() {
        #expect(CubeLUTValidator.validate("LUT_3D_SIZE 1") == .failure(.invalid3DSize))
    }

    @Test
    func decodesAndAppliesIdentityCube() throws {
        let cube = try CubeLUTValidator.decode(identityCube).get()
        #expect(cube.dimension == 2)
        #expect(cube.cubeData.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)

        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
        let output = ImageProcessingPipeline.apply(
            source,
            recipe: .identity,
            lut: LUTRenderRecipe(cube: cube, intensity: 1)
        )

        #expect(output.extent.width == 32)
        #expect(output.extent.height == 16)
    }

    @Test
    func rejectsCubeWithWrongNumberOfRows() {
        let contents = """
        LUT_3D_SIZE 2
        0 0 0
        """

        let result = CubeLUTValidator.decode(contents)
        switch result {
        case .success:
            Issue.record("不完整的 LUT 不应被解码。")
        case let .failure(error as CubeLUTDecodingError):
            #expect(error == .incorrectColorRowCount(expected: 8, actual: 1))
        case .failure:
            Issue.record("应返回颜色行数错误。")
        }
    }

    @Test
    @MainActor
    func importedLUTPersistsAndResolvesForRendering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoAI-Mac-LUT-\(UUID().uuidString)", isDirectory: true)
        let lutURL = directory.appendingPathComponent("Identity.cube")
        let storageURL = directory.appendingPathComponent("luts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try identityCube.write(to: lutURL, atomically: true, encoding: .utf8)

        let store = LUTStore(storageURL: storageURL)
        store.importLUT(at: lutURL)
        let preset = try #require(store.presets.first)

        let restoredStore = LUTStore(storageURL: storageURL)
        let restoredPreset = try #require(restoredStore.presets.first)
        let recipe = EditRecipe(lut: LUTRecipe(presetID: restoredPreset.id, intensity: 0.6))
        let renderRecipe = try #require(restoredStore.renderRecipe(for: recipe))

        #expect(preset.name == "Identity")
        #expect(restoredPreset.id == preset.id)
        #expect(renderRecipe.cube.dimension == 2)
        #expect(renderRecipe.intensity == 0.6)
    }

    private var identityCube: String {
        """
        TITLE "Identity"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
    }
}
