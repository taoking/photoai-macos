import Foundation

enum CubeLUTValidationError: Error, Equatable {
    case empty
    case missing3DSize
    case invalid3DSize
}

enum CubeLUTDecodingError: Error, Equatable, LocalizedError {
    case invalidDomain
    case invalidColorRow
    case incorrectColorRowCount(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidDomain:
            "LUT 的 DOMAIN_MIN / DOMAIN_MAX 无效。"
        case .invalidColorRow:
            "LUT 包含无法解析的颜色数据。"
        case let .incorrectColorRowCount(expected, actual):
            "LUT 需要 \(expected) 行颜色数据，实际为 \(actual) 行。"
        }
    }
}

struct LUTDomain: Hashable, Sendable {
    let red: Float
    let green: Float
    let blue: Float

    static let zero = LUTDomain(red: 0, green: 0, blue: 0)
    static let one = LUTDomain(red: 1, green: 1, blue: 1)
}

struct DecodedCubeLUT: Hashable, Sendable {
    let dimension: Int
    let cubeData: Data
    let domainMinimum: LUTDomain
    let domainMaximum: LUTDomain
}

enum CubeLUTValidator {
    /// Verifies the minimum structure needed before a `.cube` file enters the catalog.
    /// Color-cube decoding and application are intentionally deferred to Phase 5.
    static func validate(_ contents: String) -> Result<Int, CubeLUTValidationError> {
        let lines = contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else {
            return .failure(.empty)
        }

        guard let sizeLine = lines.first(where: { $0.hasPrefix("LUT_3D_SIZE") }) else {
            return .failure(.missing3DSize)
        }

        let components = sizeLine.split(whereSeparator: \.isWhitespace)
        guard components.count == 2,
              let size = Int(components[1]),
              size > 1 else {
            return .failure(.invalid3DSize)
        }

        return .success(size)
    }

    /// Decodes the common Iridas `.cube` layout into the float RGBA table expected by `CIColorCube`.
    static func decode(_ contents: String) -> Result<DecodedCubeLUT, Error> {
        guard case let .success(dimension) = validate(contents) else {
            return .failure(validationError(for: contents))
        }

        var domainMinimum = LUTDomain.zero
        var domainMaximum = LUTDomain.one
        var values: [Float] = []
        let expectedRows = dimension * dimension * dimension

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let components = line.split(whereSeparator: \.isWhitespace)
            guard let directive = components.first?.uppercased() else { continue }

            switch directive {
            case "TITLE", "LUT_1D_SIZE", "LUT_3D_SIZE":
                continue
            case "DOMAIN_MIN":
                guard let domain = parseDomain(components) else { return .failure(CubeLUTDecodingError.invalidDomain) }
                domainMinimum = domain
            case "DOMAIN_MAX":
                guard let domain = parseDomain(components) else { return .failure(CubeLUTDecodingError.invalidDomain) }
                domainMaximum = domain
            default:
                guard components.count == 3,
                      let red = Float(components[0]),
                      let green = Float(components[1]),
                      let blue = Float(components[2]) else {
                    return .failure(CubeLUTDecodingError.invalidColorRow)
                }
                values.append(contentsOf: [red, green, blue, 1])
            }
        }

        guard domainMinimum.red < domainMaximum.red,
              domainMinimum.green < domainMaximum.green,
              domainMinimum.blue < domainMaximum.blue else {
            return .failure(CubeLUTDecodingError.invalidDomain)
        }
        guard values.count / 4 == expectedRows else {
            return .failure(CubeLUTDecodingError.incorrectColorRowCount(expected: expectedRows, actual: values.count / 4))
        }

        let cubeData = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return .success(
            DecodedCubeLUT(
                dimension: dimension,
                cubeData: cubeData,
                domainMinimum: domainMinimum,
                domainMaximum: domainMaximum
            )
        )
    }

    private static func validationError(for contents: String) -> CubeLUTValidationError {
        switch validate(contents) {
        case .failure(let error): error
        case .success: .empty
        }
    }

    private static func parseDomain(_ components: [Substring]) -> LUTDomain? {
        guard components.count == 4,
              let red = Float(components[1]),
              let green = Float(components[2]),
              let blue = Float(components[3]) else {
            return nil
        }
        return LUTDomain(red: red, green: green, blue: blue)
    }
}
