import Foundation
import ImageIO

enum CatalogScanner {
    static let supportedImageExtensions: Set<String> = [
        "arw", "cr2", "cr3", "dng", "heic", "heif", "jpeg", "jpg", "nef", "orf", "png", "raf", "raw", "rw2", "tif", "tiff"
    ]

    static let supportedVideoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func scan(sourceID: UUID, rootURL: URL) throws -> [PhotoAsset] {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            throw CatalogScanError.unreadableFolder
        }

        var assets: [PhotoAsset] = []

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            guard let asset = makeAsset(
                sourceID: sourceID,
                rootURL: rootURL,
                fileURL: fileURL,
                resourceKeys: resourceKeys
            ) else {
                continue
            }

            assets.append(asset)
        }

        return assets.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    private static func makeAsset(
        sourceID: UUID,
        rootURL: URL,
        fileURL: URL,
        resourceKeys: Set<URLResourceKey>
    ) -> PhotoAsset? {
        let fileExtension = fileURL.pathExtension.lowercased()
        let mediaType: PhotoMediaType

        if supportedImageExtensions.contains(fileExtension) {
            mediaType = .image
        } else if supportedVideoExtensions.contains(fileExtension) {
            mediaType = .video
        } else {
            return nil
        }

        guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
              resourceValues.isRegularFile == true else {
            return nil
        }

        let metadata = mediaType == .image ? ImageMetadataReader.read(from: fileURL) : .empty
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let relativePath = filePath.hasPrefix(rootPath + "/")
            ? String(filePath.dropFirst(rootPath.count + 1))
            : fileURL.lastPathComponent

        return PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: relativePath,
            filename: fileURL.lastPathComponent,
            fileExtension: fileExtension,
            fileSize: Int64(resourceValues.fileSize ?? 0),
            modifiedAt: resourceValues.contentModificationDate,
            captureDate: metadata.captureDate,
            width: metadata.width,
            height: metadata.height,
            cameraMake: metadata.cameraMake,
            cameraModel: metadata.cameraModel,
            lens: metadata.lens,
            focalLength: metadata.focalLength,
            aperture: metadata.aperture,
            shutterSpeed: metadata.shutterSpeed,
            iso: metadata.iso,
            mediaType: mediaType,
            rawType: rawExtension(fileExtension),
            rating: 0,
            flag: .none,
            isFavorite: false
        )
    }

    private static func rawExtension(_ fileExtension: String) -> String? {
        switch fileExtension {
        case "arw", "cr2", "cr3", "dng", "nef", "orf", "raf", "raw", "rw2": fileExtension.uppercased()
        default: nil
        }
    }
}

enum CatalogScanError: LocalizedError {
    case unreadableFolder

    var errorDescription: String? {
        switch self {
        case .unreadableFolder: "无法读取所选文件夹。"
        }
    }
}

private struct ImageMetadata: Sendable {
    var captureDate: Date?
    var width: Int?
    var height: Int?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var focalLength: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: Int?

    static let empty = ImageMetadata()
}

private enum ImageMetadataReader {
    static func read(from fileURL: URL) -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .empty
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]

        return ImageMetadata(
            captureDate: captureDate(exif?[kCGImagePropertyExifDateTimeOriginal]),
            width: integer(properties[kCGImagePropertyPixelWidth]),
            height: integer(properties[kCGImagePropertyPixelHeight]),
            cameraMake: string(tiff?[kCGImagePropertyTIFFMake]),
            cameraModel: string(tiff?[kCGImagePropertyTIFFModel]),
            lens: string(exif?[kCGImagePropertyExifLensModel]),
            focalLength: formattedNumber(exif?[kCGImagePropertyExifFocalLength], suffix: " mm"),
            aperture: formattedNumber(exif?[kCGImagePropertyExifFNumber], prefix: "f/"),
            shutterSpeed: formattedNumber(exif?[kCGImagePropertyExifExposureTime], suffix: " s"),
            iso: integer(exif?[kCGImagePropertyExifISOSpeedRatings])
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        let result = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let values = value as? [NSNumber] { return values.first?.intValue }
        guard let text = string(value) else { return nil }
        return Int(text)
    }

    private static func formattedNumber(_ value: Any?, prefix: String = "", suffix: String = "") -> String? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            return "\(prefix)\(number.stringValue)\(suffix)"
        }
        guard let text = string(value) else { return nil }
        return "\(prefix)\(text)\(suffix)"
    }

    private static func captureDate(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
