import Foundation

/// 网络存储的浏览范围：侧边栏条目与网格筛选共用同一份枚举，互斥切换。
public enum CloudScope: Hashable {
    case all
    case videos
    case photos
    case screenshots
    case animated
    case raws
    /// 全景：按文件名或超宽比例推断（网盘没有 PhotoKit 元数据）。
    case panoramas
    /// 录屏：视频文件名里带 Screen Recording / 录屏 等字样。
    case screenRecordings
    case favorites
    case text
    /// 最近查看：按本机查看记录排序（与拾光 / 系统图库的同一入口一致）。
    case recentlyViewed
    /// 图库整理：评分 / 旗标 / 色标只记在本机（`cloud_marks`），不写回网盘。
    case ratings
    /// 最近编辑：网盘只读，没有编辑记录，入口与系统图库同位但页面为只读说明。
    case recentlyEdited
    /// 最近保存：按网盘文件的修改时间落在最近 30 天内。
    case recentlySaved
    /// 最近删除：网盘不提供回收站，入口与系统图库同位但页面为只读说明。
    case trash
    /// 导入项目：网盘不产生导入批次，入口与系统图库同位但页面为只读说明。
    case imports
    case scene(String)
    /// 值得重看：按 EXIF 拍摄时间与本机查看记录派生。
    case revisit
    /// 带 GPS 的照片：地图 / 位置 / 人物与重复项目都是只读派生范围。
    case map
    case places
    case people
    case duplicates
    /// 图库体检：对当前目录做清晰度 / 相似连拍 / 过大视频检查，只读。
    case health
    /// 关键词总览：关键词是拾光为网盘文件记录的本地标签，不写回网盘。
    case keywords
    /// 单个关键词下的网盘照片。
    case keyword(String)

    public var title: String {
        switch self {
        case .all: return "全部项目"
        case .videos: return "视频"
        case .photos: return "照片"
        case .screenshots: return "截屏"
        case .animated: return "动图"
        case .raws: return "RAW"
        case .panoramas: return "全景照片"
        case .screenRecordings: return "录屏"
        case .favorites: return "个人收藏"
        case .text: return "包含文字"
        case .recentlyViewed: return "最近查看"
        case .ratings: return "图库整理"
        case .recentlyEdited: return "最近编辑"
        case .recentlySaved: return "最近保存"
        case .trash: return "最近删除"
        case .imports: return "导入项目"
        case .scene(let id): return SceneCatalog.category(id: id)?.title ?? "场景"
        case .revisit: return "值得重看"
        case .map: return "地图"
        case .places: return "位置"
        case .people: return "人物"
        case .duplicates: return "重复项目"
        case .health: return "图库体检"
        case .keywords: return "关键词"
        case .keyword(let name): return "关键词：\(name)"
        }
    }

    public var icon: String {
        switch self {
        case .all: return "photo.stack"
        case .videos: return "video"
        case .photos: return "photo"
        case .screenshots: return "camera.viewfinder"
        case .animated: return "photo.on.rectangle.angled"
        case .raws: return "camera.aperture"
        case .panoramas: return "pano"
        case .screenRecordings: return "record.circle"
        case .favorites: return "heart.fill"
        case .text: return "text.viewfinder"
        case .recentlyViewed: return "eye"
        case .ratings: return "square.grid.2x2"
        case .recentlyEdited: return "slider.horizontal.3"
        case .recentlySaved: return "square.and.arrow.down"
        case .trash: return "trash"
        case .imports: return "square.and.arrow.down.on.square"
        case .scene(let id): return SceneCatalog.category(id: id)?.icon ?? "sparkles"
        case .revisit: return "clock.arrow.circlepath"
        case .map: return "map"
        case .places: return "mappin.and.ellipse"
        case .people: return "person.crop.square"
        case .duplicates: return "square.on.square"
        case .health: return "stethoscope"
        case .keywords, .keyword: return "tag"
        }
    }

    /// 侧边栏行标识（用于悬停状态与测试定位）。
    public var key: String {
        switch self {
        case .all: return "all"
        case .videos: return "videos"
        case .photos: return "photos"
        case .screenshots: return "screenshots"
        case .animated: return "animated"
        case .raws: return "raws"
        case .panoramas: return "panoramas"
        case .screenRecordings: return "screenRecordings"
        case .favorites: return "favorites"
        case .text: return "text"
        case .recentlyViewed: return "recentlyViewed"
        case .ratings: return "ratings"
        case .recentlyEdited: return "recentlyEdited"
        case .recentlySaved: return "recentlySaved"
        case .trash: return "trash"
        case .imports: return "imports"
        case .scene(let id): return "scene." + id
        case .revisit: return "revisit"
        case .map: return "map"
        case .places: return "places"
        case .people: return "people"
        case .duplicates: return "duplicates"
        case .health: return "health"
        case .keywords: return "keywords"
        case .keyword(let name): return "keyword." + name
        }
    }

    /// 需要先做端侧识别才能用的范围。
    public var requiresAnalysis: Bool {
        switch self {
        case .text, .scene: return true
        default: return false
        }
    }

    /// 地图 / 位置 / 人物 / 重复项目 / 关键词 / 值得重看 / 图库整理 / 最近编辑 / 最近删除 /
    /// 导入项目在网盘里使用各自的页面，而不是普通照片网格。
    public var usesDedicatedView: Bool {
        switch self {
        case .map, .places, .people, .duplicates, .health, .keywords, .revisit,
             .ratings, .recentlyEdited, .trash, .imports:
            return true
        default:
            return false
        }
    }

    /// 关键词范围能否一键返回关键词总览。
    public var keywordOverviewParent: CloudScope? {
        if case .keyword = self { return .keywords }
        return nil
    }

    /// 「更多项目」入口顺序：与系统图库完全一致，包括只读能力入口（右侧给出对应的只读页面）。
    /// 数量为 0 的重复项目与尚未识别的包含文字按系统图库的规则隐藏。
    public static func moreItems(counts: CloudScopeCounts, analyzedCount: Int) -> [CloudScope] {
        var scopes: [CloudScope] = [.favorites, .health, .ratings, .revisit]
        if counts.duplicates > 0 { scopes.append(.duplicates) }
        scopes += [.map, .places, .people, .keywords]
        if analyzedCount > 0 { scopes.append(.text) }
        scopes += [.recentlyViewed, .recentlyEdited, .recentlySaved, .trash, .imports]
        return scopes
    }
}

/// 网盘的媒体类型与拾光共用同一组标题、图标与顺序；
/// 网盘只能按文件名 / 扩展名 / 像素比例判断，所以只提供能可靠推断的几种类型。
public extension MediaTypeKey {
    var cloudScope: CloudScope? {
        switch self {
        case .videos: return .videos
        case .screenshots: return .screenshots
        case .screenRecordings: return .screenRecordings
        case .panoramas: return .panoramas
        case .animated: return .animated
        case .raws: return .raws
        default: return nil
        }
    }

    /// 网盘可用的媒体类型（保持系统「照片」媒体类型列表的顺序）。
    /// 录屏在系统图库里是专属类型，但网盘可以按文件名判断，所以这里单独纳入。
    static var cloudCases: [MediaTypeKey] {
        allCases.filter { $0.cloudScope != nil }
    }
}


/// 网盘的分区总览：与拾光 / 系统图库一样，点侧边栏分区标题进入卡片墙。
public enum CloudOverviewSection: String, Identifiable, Equatable {
    case mediaTypes
    case moreItems
    case scenes
    case folders

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mediaTypes: return "媒体类型"
        case .moreItems: return "更多项目"
        case .scenes: return "场景"
        case .folders: return "相簿"
        }
    }
}

/// 网盘当前列表的分类计数：一次遍历得出，随目录版本与识别进度缓存。
public struct CloudScopeCounts {
    public var videos = 0
    public var photos = 0
    public var screenshots = 0
    public var animated = 0
    public var raws = 0
    public var panoramas = 0
    public var screenRecordings = 0
    public var favorites = 0
    public var text = 0
    public var recentlyViewed = 0
    public var recentlySaved = 0
    public var ratings = 0
    public var revisit = 0
    public var located = 0
    public var people = 0
    public var duplicates = 0
    public var health = 0
    public var scenes: [String: Int] = [:]
    /// 每个关键词对应的照片数；键数量即关键词总数。
    public var keywords: [String: Int] = [:]

    public func count(for scope: CloudScope) -> Int {
        switch scope {
        case .all: return photos + videos
        case .videos: return videos
        case .photos: return photos
        case .screenshots: return screenshots
        case .animated: return animated
        case .raws: return raws
        case .panoramas: return panoramas
        case .screenRecordings: return screenRecordings
        case .favorites: return favorites
        case .text: return text
        case .recentlyViewed: return recentlyViewed
        case .recentlySaved: return recentlySaved
        case .ratings: return ratings
        case .recentlyEdited, .trash, .imports: return 0
        case .scene(let id): return scenes[id] ?? 0
        case .revisit: return revisit
        case .map, .places: return located
        case .people: return people
        case .duplicates: return duplicates
        case .health: return health
        case .keywords: return keywords.count
        case .keyword(let name): return keywords[name] ?? 0
        }
    }
    public init(
        videos: Int = 0,
        photos: Int = 0,
        screenshots: Int = 0,
        animated: Int = 0,
        raws: Int = 0,
        panoramas: Int = 0,
        screenRecordings: Int = 0,
        favorites: Int = 0,
        text: Int = 0,
        recentlyViewed: Int = 0,
        recentlySaved: Int = 0,
        ratings: Int = 0,
        revisit: Int = 0,
        located: Int = 0,
        people: Int = 0,
        duplicates: Int = 0,
        health: Int = 0,
        scenes: [String: Int] = [:],
        keywords: [String: Int] = [:]
    ) {
        self.videos = videos
        self.photos = photos
        self.screenshots = screenshots
        self.animated = animated
        self.raws = raws
        self.panoramas = panoramas
        self.screenRecordings = screenRecordings
        self.favorites = favorites
        self.text = text
        self.recentlyViewed = recentlyViewed
        self.recentlySaved = recentlySaved
        self.ratings = ratings
        self.revisit = revisit
        self.located = located
        self.people = people
        self.duplicates = duplicates
        self.health = health
        self.scenes = scenes
        self.keywords = keywords
    }
}

/// 网盘照片在本机的评分 / 旗标 / 色标：只写当前图库的 settings（`cloud_marks`），不写回网盘。
public struct CloudMark: Codable, Hashable {
    public var rating: Int?
    public var flag: PhotoFlag?
    public var colorLabel: PhotoColorLabel?

    public var isEmpty: Bool { rating == nil && flag == nil && colorLabel == nil }
    public init(
        rating: Int? = nil,
        flag: PhotoFlag? = nil,
        colorLabel: PhotoColorLabel? = nil
    ) {
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
    }
}

/// 网盘媒体类型按文件名与扩展名推断；EXIF（拍摄时间 / 相机 / GPS）由 `CloudEXIF` 读取文件头部得到。
public enum CloudMediaNaming {
    /// 截屏：主流平台导出的文件名都带 Screenshot / 截屏 等字样。
    public static func looksLikeScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        let english = ["screenshot", "screen shot", "screencapture"]
        if english.contains(where: { lower.contains($0) }) { return true }
        let chinese = ["截屏", "截图", "截圖", "屏幕快照", "屏幕截图"]
        return chinese.contains { name.contains($0) }
    }

    /// 录屏：视频文件名带 Screen Recording / 录屏 等字样。
    public static func looksLikeScreenRecording(_ name: String) -> Bool {
        let lower = name.lowercased()
        let english = ["screen recording", "screenrecording", "screen capture", "screencapture"]
        if english.contains(where: { lower.contains($0) }) { return true }
        let chinese = ["录屏", "錄屏", "屏幕录制", "屏幕录像"]
        return chinese.contains { name.contains($0) }
    }

    /// 全景：文件名带 Pano / 全景，或像素宽高比达到手机全景的常见比例（先看已读到的尺寸）。
    public static func looksLikePanorama(_ name: String, pixelWidth: Int, pixelHeight: Int) -> Bool {
        let lower = name.lowercased()
        if lower.contains("pano") { return true }
        if name.contains("全景") { return true }
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        return Double(pixelWidth) / Double(pixelHeight) >= 2.0
    }
}
