import Foundation

struct PhotoSource: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var bookmarkData: Data
    var displayName: String
    var lastKnownPath: String
    var createdAt: Date
    var lastScannedAt: Date?
    var status: PhotoSourceStatus
    var assetCount: Int
}

enum PhotoSourceStatus: String, Codable, Hashable, Sendable {
    case ready
    case scanning
    case missing
    case inaccessible

    var title: String {
        switch self {
        case .ready: "可用"
        case .scanning: "正在扫描"
        case .missing: "文件夹缺失"
        case .inaccessible: "无法访问"
        }
    }
}

struct PhotoAsset: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let sourceID: UUID
    let relativePath: String
    let filename: String
    let fileExtension: String
    let fileSize: Int64
    let modifiedAt: Date?
    let captureDate: Date?
    let width: Int?
    let height: Int?
    let cameraMake: String?
    let cameraModel: String?
    let lens: String?
    let focalLength: String?
    let aperture: String?
    let shutterSpeed: String?
    let iso: Int?
    let mediaType: PhotoMediaType
    let rawType: String?

    var rating: Int
    var flag: PhotoFlag
    var isFavorite: Bool
    var editRecipe: EditRecipe? = nil
    /// `nil` means the asset has not been indexed for OCR yet; an empty string is an indexed image with no recognized text.
    var ocrText: String? = nil

    var displayDimensions: String {
        guard let width, let height else { return "—" }
        return "\(width) × \(height)"
    }

    var isRAW: Bool { rawType != nil }

    var identityKey: String { "\(sourceID.uuidString)/\(relativePath)" }
}

struct EditRecipe: Codable, Hashable, Sendable {
    static let currentVersion = 2

    var version: Int
    var exposure: Double
    var contrast: Double
    var highlights: Double
    var shadows: Double
    var temperature: Double
    var tint: Double
    var saturation: Double
    var crop: CropRecipe?
    var rotation: Double
    var lut: LUTRecipe?

    init(
        version: Int = EditRecipe.currentVersion,
        exposure: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        saturation: Double = 0,
        crop: CropRecipe? = nil,
        rotation: Double = 0,
        lut: LUTRecipe? = nil
    ) {
        self.version = version
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.temperature = temperature
        self.tint = tint
        self.saturation = saturation
        self.crop = crop
        self.rotation = rotation
        self.lut = lut
    }

    static let identity = EditRecipe()

    var isIdentity: Bool { self == .identity }

    private enum CodingKeys: String, CodingKey {
        case version, exposure, contrast, highlights, shadows
        case temperature, tint, saturation, crop, rotation, lut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        crop = try container.decodeIfPresent(CropRecipe.self, forKey: .crop)
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        lut = try container.decodeIfPresent(LUTRecipe.self, forKey: .lut)
    }
}

struct CropRecipe: Codable, Hashable, Sendable {
    /// `nil` preserves the original aspect ratio; other values center-crop.
    var aspectRatio: Double?

    init(aspectRatio: Double?) {
        self.aspectRatio = aspectRatio
    }
}

struct LUTRecipe: Codable, Hashable, Sendable {
    var presetID: UUID
    var intensity: Double

    init(presetID: UUID, intensity: Double = 1) {
        self.presetID = presetID
        self.intensity = min(max(intensity, 0), 1)
    }
}

enum PhotoMediaType: String, Codable, Hashable, Sendable {
    case image
    case video
}

enum PhotoFlag: String, Codable, Hashable, Sendable {
    case none
    case pick
    case reject
}

enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case picks
    case rejected
    case fourStarsAndAbove
    case fiveStars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .picks: "Pick"
        case .rejected: "Reject"
        case .fourStarsAndAbove: "4 星及以上"
        case .fiveStars: "5 星"
        }
    }

    func matches(_ asset: PhotoAsset) -> Bool {
        switch self {
        case .all: true
        case .picks: asset.flag == .pick
        case .rejected: asset.flag == .reject
        case .fourStarsAndAbove: asset.rating >= 4
        case .fiveStars: asset.rating == 5
        }
    }
}

struct CatalogSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var sources: [PhotoSource]
    var assets: [PhotoAsset]

    init(
        sources: [PhotoSource],
        assets: [PhotoAsset],
        schemaVersion: Int = CatalogSnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.assets = assets
    }

    static let empty = CatalogSnapshot(sources: [], assets: [])

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Phase 0–11 的快照没有版本字段，视为 v1 并在读取时迁移。
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sources = try container.decodeIfPresent([PhotoSource].self, forKey: .sources) ?? []
        assets = try container.decodeIfPresent([PhotoAsset].self, forKey: .assets) ?? []
        migrateInPlace()
    }

    mutating func migrateInPlace() {
        if schemaVersion < 2 {
            for index in assets.indices {
                if var recipe = assets[index].editRecipe, recipe.version < EditRecipe.currentVersion {
                    recipe.version = EditRecipe.currentVersion
                    assets[index].editRecipe = recipe
                }
            }
            schemaVersion = 2
        }
        if schemaVersion > CatalogSnapshot.currentSchemaVersion {
            // 前向版本保留字段能继续读取；当前 App 只维护自己已知的数据。
            schemaVersion = CatalogSnapshot.currentSchemaVersion
        }
    }
}
