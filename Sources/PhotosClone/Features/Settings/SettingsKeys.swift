import SwiftUI
import AppKit

enum SettingsKeys {
    /// 设置窗口当前停留的分页：其它入口可以先写入目标页再打开设置。
    static let selectedTab = "settings.selectedTab"
    static let appearance = "settings.appearance"
    static let accent = "settings.accent"
    static let photoOpenMode = "settings.photoOpenMode"
    static let viewerLayout = "settings.viewerLayout"
    static let showInfoOnOpen = "settings.showInfoOnOpen"
    static let viewerFilmstrip = "settings.viewerFilmstrip"
    /// 查看器是否用当前照片的模糊影像铺满舞台背景。
    static let viewerBackdrop = "settings.viewerBackdrop"
    static let grouping = "settings.grouping"
    static let thumbSize = "settings.thumbSize"
    /// 新打开的侧边栏页面（媒体类型 / 相簿 / 文件夹…）图片列表默认每行张数。
    static let defaultGridColumns = "settings.defaultGridColumns"
    /// 相簿 / 媒体类型 / 场景 / 更多项目等卡片墙默认每行张数。
    static let defaultCardColumns = "settings.defaultCardColumns"
    /// 每个侧边栏页面各自的卡片墙每行张数，JSON 字典。
    static let cardColumns = "settings.cardColumns"
    /// 旧版按 pt 记录页面尺寸；改为按「每行张数」后每个图库执行一次清理。
    static let gridColumnsMigration = "settings.gridColumnsMigration"
    /// 每个侧边栏页面各自的缩略图尺寸（滑杆位置），JSON 字典。
    static let thumbSizes = "settings.thumbSizes"
    static let thumbnailAspect = "settings.thumbnailAspect"
    static let albumDisplayStyle = "settings.albumDisplayStyle"
    static let sortKey = "settings.sortKey"
    /// 「位置」页的地点聚合层级（省 / 市 / 区县 / 街道）。
    static let placeGranularity = "settings.placeGranularity"
    /// 「人物」页的聚合筛选（全部 / 已命名 / 待命名 / 宠物）。
    static let peopleFilter = "settings.peopleFilter"
    /// 「人物」总览的头像形状（圆形 / 圆角方形）。
    static let peopleDisplayStyle = "settings.peopleDisplayStyle"
    /// 「整理工作室」的浏览维度（评分 / 旗标 / 色标 / 关键词）。
    static let organizeDimension = "settings.organizeDimension"
    /// 「个人收藏」的浏览方式（全部 / 年 / 类型 / 地点 / 相机 / 人物）。
    static let favoritesViewMode = "settings.favoritesViewMode"
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
    /// 视频查看器里 ↑ / ↓ 快进快退的步长（秒）。
    static let videoSeekStep = "settings.video.seekStep"
    /// 视频控制条的位置：底部悬浮 / 顶栏融合。
    static let videoControlPlacement = "settings.video.controlPlacement"
    /// 视频转码 / 边下边播缓存的总容量上限（GB）。
    static let videoCacheLimitGB = "settings.video.cacheLimitGB"
    /// 外挂字幕字号。
    static let subtitleFontSize = "settings.video.subtitleFontSize"
    /// 外挂字幕是否显示半透明底色。
    static let subtitleBackground = "settings.video.subtitleBackground"
    static let trashRetentionDays = "settings.trash.retentionDays"
    static let importCreateAlbums = "settings.import.createAlbums"
    static let importPreserveStructure = "settings.import.preserveStructure"
    static let importSkipDuplicates = "settings.import.skipDuplicates"
    static let importVerifyCopies = "settings.import.verifyCopies"
    /// 旧版全局设置已迁入当前图库的一次性标记（仅 UserDefaults）。
    static let libraryScopeMigrationDone = "settings.libraryScopeMigrationDone"
    /// 本地模型清单地址（可替换为私有镜像或测试源）。
    static let modelManifestURL = "settings.model.manifestURL"

    // MARK: 影院刮削
    static let cinemaProvider = "settings.cinema.provider"
    static let cinemaAPIKey = "settings.cinema.apiKey"
    static let cinemaLanguage = "settings.cinema.language"
    static let cinemaAPIBase = "settings.cinema.apiBase"
    static let cinemaImageBase = "settings.cinema.imageBase"
    static let cinemaAutoScrape = "settings.cinema.autoScrape"
    static let cinemaDoubanBase = "settings.cinema.doubanBase"
    static let cinemaDoubanCookie = "settings.cinema.doubanCookie"

    /// 单个本地能力是否启用。模型文件存放在本机 Application Support，开关只表示用不用。
    static func modelEnabled(_ id: String) -> String {
        "settings.model.\(id).enabled"
    }
}

// MARK: - 缩略图元数据

/// 网格缩略图上要显示的元数据，可在「显示 › 元数据」或设置中逐项开关。
