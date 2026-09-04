import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case allPhotos
    case recentImports
    case favorites
    case raw
    case videos
    case missingFiles
    case folders
    case applePhotos
    case people
    case search
    case cleanup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allPhotos: "所有照片"
        case .recentImports: "最近导入"
        case .favorites: "收藏"
        case .raw: "RAW"
        case .videos: "视频"
        case .missingFiles: "缺失文件"
        case .folders: "文件夹"
        case .applePhotos: "Apple Photos"
        case .people: "人物"
        case .search: "搜索"
        case .cleanup: "清理"
        }
    }

    var systemImage: String {
        switch self {
        case .allPhotos: "photo.on.rectangle.angled"
        case .recentImports: "clock.arrow.circlepath"
        case .favorites: "heart"
        case .raw: "camera.aperture"
        case .videos: "video"
        case .missingFiles: "exclamationmark.triangle"
        case .folders: "folder"
        case .applePhotos: "photo.stack"
        case .people: "person.2"
        case .search: "magnifyingglass"
        case .cleanup: "sparkles"
        }
    }

    var group: SidebarGroup {
        switch self {
        case .allPhotos, .recentImports, .favorites, .raw, .videos, .missingFiles:
            .library
        case .folders, .applePhotos:
            .collections
        case .people, .search, .cleanup:
            .tools
        }
    }
}

enum SidebarGroup: String, CaseIterable, Identifiable {
    case library
    case collections
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "图库"
        case .collections: "收藏集"
        case .tools: "工具"
        }
    }
}
