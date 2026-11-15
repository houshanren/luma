import SwiftUI
import AppKit

enum SettingsKeys {
    static let appearance = "settings.appearance"
    static let accent = "settings.accent"
    static let photoOpenMode = "settings.photoOpenMode"
    static let viewerLayout = "settings.viewerLayout"
    static let showInfoOnOpen = "settings.showInfoOnOpen"
    static let grouping = "settings.grouping"
    static let thumbSize = "settings.thumbSize"
    static let thumbnailAspect = "settings.thumbnailAspect"
    static let sortKey = "settings.sortKey"
    static let motion = "settings.motion"
    static let cardCornerRadius = "settings.cardCornerRadius"
    static let hoverLift = "settings.hoverLift"
    static let metadata = "settings.metadata"
    static let sortAscending = "settings.sortAscending"
    static let autoPlayVideo = "settings.autoPlayVideo"
    static let autoPlayNextVideo = "settings.autoPlayNextVideo"
    static let viewFullHDR = "settings.viewFullHDR"
    static let videoMuted = "settings.video.mutedByDefault"
    static let videoLoop = "settings.video.loopByDefault"
    static let trashRetentionDays = "settings.trash.retentionDays"
    static let importCreateAlbums = "settings.import.createAlbums"
    static let importPreserveStructure = "settings.import.preserveStructure"
    static let systemLibraryMaxAssets = "settings.system.maxAssets"
    /// 旧版全局设置已迁入当前图库的一次性标记（仅 UserDefaults）。
    static let libraryScopeMigrationDone = "settings.libraryScopeMigrationDone"
}

// MARK: - 缩略图元数据

/// 网格缩略图上要显示的元数据，可在「显示 › 元数据」或设置中逐项开关。
