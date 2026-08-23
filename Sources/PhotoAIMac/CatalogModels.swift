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
    /// 对同一 source + relativePath 保持稳定；重扫时由 CatalogStore 复用已有 ID。
    var id: UUID
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
    var colorLabel: String = ""
    var comment: String = ""
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

enum PhotoFlag: String, Hashable, Sendable {
    case none
    case pick = "picked"
    case reject = "rejected"
}

enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unrated
    case picks
    case rejected
    case fourStarsAndAbove
    case fiveStars
    case raw
    case videos
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .unrated: "未评分"
        case .picks: "Pick"
        case .rejected: "Reject"
        case .fourStarsAndAbove: "4 星及以上"
        case .fiveStars: "5 星"
        case .raw: "RAW"
        case .videos: "视频"
        case .duplicates: "重复照片"
        }
    }

    func matches(_ asset: PhotoAsset, duplicateAssetIDs: Set<UUID> = []) -> Bool {
        switch self {
        case .all: true
        case .unrated: asset.rating == 0
        case .picks: asset.flag == .pick
        case .rejected: asset.flag == .reject
        case .fourStarsAndAbove: asset.rating >= 4
        case .fiveStars: asset.rating == 5
        case .raw: asset.isRAW
        case .videos: asset.mediaType == .video
        case .duplicates: duplicateAssetIDs.contains(asset.id)
        }
    }
}

struct CatalogSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 3

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
        if schemaVersion < 3 {
            for index in assets.indices {
                assets[index].colorLabel = assets[index].colorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                assets[index].comment = assets[index].comment.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            schemaVersion = 3
        }
        if schemaVersion > CatalogSnapshot.currentSchemaVersion {
            // 前向版本保留字段能继续读取；当前 App 只维护自己已知的数据。
            schemaVersion = CatalogSnapshot.currentSchemaVersion
        }
    }
}

extension PhotoAsset {
    private enum CodingKeys: String, CodingKey {
        case id, sourceID, relativePath, filename, fileExtension, fileSize, modifiedAt, captureDate
        case width, height, cameraMake, cameraModel, lens, focalLength, aperture, shutterSpeed, iso
        case mediaType, rawType, rating, flag, colorLabel, comment, isFavorite, editRecipe, ocrText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        filename = try container.decode(String.self, forKey: .filename)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        captureDate = try container.decodeIfPresent(Date.self, forKey: .captureDate)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        cameraMake = try container.decodeIfPresent(String.self, forKey: .cameraMake)
        cameraModel = try container.decodeIfPresent(String.self, forKey: .cameraModel)
        lens = try container.decodeIfPresent(String.self, forKey: .lens)
        focalLength = try container.decodeIfPresent(String.self, forKey: .focalLength)
        aperture = try container.decodeIfPresent(String.self, forKey: .aperture)
        shutterSpeed = try container.decodeIfPresent(String.self, forKey: .shutterSpeed)
        iso = try container.decodeIfPresent(Int.self, forKey: .iso)
        mediaType = try container.decode(PhotoMediaType.self, forKey: .mediaType)
        rawType = try container.decodeIfPresent(String.self, forKey: .rawType)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        flag = try container.decodeIfPresent(PhotoFlag.self, forKey: .flag) ?? .none
        colorLabel = try container.decodeIfPresent(String.self, forKey: .colorLabel) ?? ""
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        editRecipe = try container.decodeIfPresent(EditRecipe.self, forKey: .editRecipe)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(filename, forKey: .filename)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(captureDate, forKey: .captureDate)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(cameraMake, forKey: .cameraMake)
        try container.encodeIfPresent(cameraModel, forKey: .cameraModel)
        try container.encodeIfPresent(lens, forKey: .lens)
        try container.encodeIfPresent(focalLength, forKey: .focalLength)
        try container.encodeIfPresent(aperture, forKey: .aperture)
        try container.encodeIfPresent(shutterSpeed, forKey: .shutterSpeed)
        try container.encodeIfPresent(iso, forKey: .iso)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encodeIfPresent(rawType, forKey: .rawType)
        try container.encode(min(max(rating, 0), 5), forKey: .rating)
        try container.encode(flag, forKey: .flag)
        try container.encode(colorLabel, forKey: .colorLabel)
        try container.encode(comment, forKey: .comment)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(editRecipe, forKey: .editRecipe)
        try container.encodeIfPresent(ocrText, forKey: .ocrText)
    }
}

extension PhotoFlag: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "none", "": self = .none
        case "pick", "picked": self = .pick
        case "reject", "rejected": self = .reject
        default: self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
