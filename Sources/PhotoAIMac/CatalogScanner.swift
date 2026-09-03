import Foundation
import ImageIO

enum CatalogScanner {
    static let supportedImageExtensions: Set<String> = [
        "arw", "cr2", "cr3", "dng", "heic", "heif", "jpeg", "jpg", "nef", "orf", "png", "raf", "raw", "rw2", "tif", "tiff"
    ]

    static let supportedVideoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// 一批扫描结果。`scanned` / `total` 用于界面进度，`assets` 用于边扫边显示。
    struct ScanBatch: Sendable {
        let assets: [PhotoAsset]
        let scanned: Int
        let total: Int
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .fileSizeKey,
        .isRegularFileKey
    ]

    /// 元数据读取的并发度。
    ///
    /// 单线程扫描时每个文件都要 `CGImageSourceCreateWithURL` + 读 EXIF，
    /// 在 MTP 挂载盘上实测 0.22–0.33 秒/文件，5,338 个文件需要 20–30 分钟且只用一个核。
    /// 上限压在 8，是为了不在慢速外置卷上同时打开过多文件。
    static var defaultConcurrency: Int {
        min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// 同步全量扫描。保留给测试与不需要进度的调用方。
    static func scan(
        sourceID: UUID,
        rootURL: URL,
        reusableAssets: [String: PhotoAsset] = [:]
    ) throws -> [PhotoAsset] {
        let fileURLs = try candidateFileURLs(at: rootURL)
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(fileURLs.count)

        for fileURL in fileURLs {
            try Task.checkCancellation()
            if let asset = makeAsset(
                sourceID: sourceID,
                rootURL: rootURL,
                fileURL: fileURL,
                reusableAssets: reusableAssets
            ) {
                assets.append(asset)
            }
        }
        return sorted(assets)
    }

    /// 并行扫描：先枚举路径（便宜），再按 CPU 核数并行读取元数据，并按批回报进度。
    ///
    /// `reusableAssets` 按 `relativePath` 提供上一次的索引结果；文件大小与修改时间都没变时
    /// 直接复用，跳过整个 EXIF 读取——重扫因此接近零成本。
    ///
    /// 名字与同步版本刻意不同：两者只差若干带默认值的参数，同名重载在 async 上下文里
    /// 会被静默解析成这一个，调用方很难看出自己用的是哪个。
    static func scanConcurrently(
        sourceID: UUID,
        rootURL: URL,
        reusableAssets: [String: PhotoAsset] = [:],
        concurrency: Int = defaultConcurrency,
        batchSize: Int = 128,
        onBatch: (@Sendable (ScanBatch) async -> Void)? = nil
    ) async throws -> [PhotoAsset] {
        let fileURLs = try candidateFileURLs(at: rootURL)
        let total = fileURLs.count
        guard total > 0 else {
            await onBatch?(ScanBatch(assets: [], scanned: 0, total: 0))
            return []
        }

        let chunks = stride(from: 0, to: total, by: max(1, batchSize)).map { start in
            Array(fileURLs[start..<min(start + max(1, batchSize), total)])
        }

        var orderedResults = [[PhotoAsset]](repeating: [], count: chunks.count)
        var scanned = 0

        try await withThrowingTaskGroup(of: (Int, [PhotoAsset]).self) { group in
            var nextChunkIndex = 0

            func addTask(_ index: Int) {
                let chunk = chunks[index]
                group.addTask {
                    var assets: [PhotoAsset] = []
                    assets.reserveCapacity(chunk.count)
                    for fileURL in chunk {
                        try Task.checkCancellation()
                        if let asset = makeAsset(
                            sourceID: sourceID,
                            rootURL: rootURL,
                            fileURL: fileURL,
                            reusableAssets: reusableAssets
                        ) {
                            assets.append(asset)
                        }
                    }
                    return (index, assets)
                }
            }

            while nextChunkIndex < min(concurrency, chunks.count) {
                addTask(nextChunkIndex)
                nextChunkIndex += 1
            }

            while let (index, assets) = try await group.next() {
                orderedResults[index] = assets
                scanned += chunks[index].count
                await onBatch?(ScanBatch(assets: assets, scanned: scanned, total: total))

                if nextChunkIndex < chunks.count {
                    addTask(nextChunkIndex)
                    nextChunkIndex += 1
                }
            }
        }

        return sorted(orderedResults.flatMap { $0 })
    }

    /// 只枚举路径并按扩展名过滤，不读取任何图像内容。
    private static func candidateFileURLs(at rootURL: URL) throws -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            throw CatalogScanError.unreadableFolder
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let fileExtension = fileURL.pathExtension.lowercased()
            guard supportedImageExtensions.contains(fileExtension)
                    || supportedVideoExtensions.contains(fileExtension) else {
                continue
            }
            fileURLs.append(fileURL)
        }
        return fileURLs
    }

    private static func sorted(_ assets: [PhotoAsset]) -> [PhotoAsset] {
        assets.sorted {
            let filenameOrder = $0.filename.localizedStandardCompare($1.filename)
            if filenameOrder != .orderedSame { return filenameOrder == .orderedAscending }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func makeAsset(
        sourceID: UUID,
        rootURL: URL,
        fileURL: URL,
        reusableAssets: [String: PhotoAsset]
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

        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let relativePath = filePath.hasPrefix(rootPath + "/")
            ? String(filePath.dropFirst(rootPath.count + 1))
            : fileURL.lastPathComponent

        let fileSize = Int64(resourceValues.fileSize ?? 0)
        let modifiedAt = resourceValues.contentModificationDate

        // 重扫快路径：大小与修改时间都没变，说明文件内容没动过，
        // 直接复用上一次的记录，跳过这个文件的整次 EXIF 读取。
        if let existing = reusableAssets[relativePath],
           existing.fileSize == fileSize,
           existing.modifiedAt == modifiedAt {
            return existing
        }

        let metadata = mediaType == .image ? ImageMetadataReader.read(from: fileURL) : .empty

        return PhotoAsset(
            id: UUID(),
            sourceID: sourceID,
            relativePath: relativePath,
            filename: fileURL.lastPathComponent,
            fileExtension: fileExtension,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
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
        return EXIFDateParser.date(from: text)
    }
}

/// EXIF `DateTimeOriginal` 的解析器。
///
/// 该字段是固定的 `yyyy:MM:dd HH:mm:ss` ASCII 格式，因此这里手写解析，
/// 而不是每张照片新建一个 `DateFormatter`：本机实测 5,338 次 `DateFormatter`
/// 分配约 0.48 秒，且 `DateFormatter` 不是 `Sendable`，无法在并行扫描中共享一份。
enum EXIFDateParser {
    /// 时区在首次使用时取一次。与旧实现（每次新建 formatter 并设 `.current`）在
    /// 同一次运行内等价；跨时区变更需重启 App 才生效。
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    static func date(from text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 19,
              bytes[4] == UInt8(ascii: ":"),
              bytes[7] == UInt8(ascii: ":"),
              bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":") else {
            return nil
        }

        func number(in range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let digit = Int(bytes[index]) &- 48
                guard digit >= 0, digit <= 9 else { return nil }
                result = result * 10 + digit
            }
            return result
        }

        guard let year = number(in: 0..<4),
              let month = number(in: 5..<7),
              let day = number(in: 8..<10),
              let hour = number(in: 11..<13),
              let minute = number(in: 14..<16),
              let second = number(in: 17..<19) else {
            return nil
        }

        // 相机未设置时间时写出的全 0 值必须判为无效，与旧的 `DateFormatter` 行为一致。
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
}
