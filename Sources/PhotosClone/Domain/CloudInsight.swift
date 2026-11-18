import Foundation

/// 网络存储的浏览范围：侧边栏条目与网格筛选共用同一份枚举，互斥切换。
enum CloudScope: Hashable {
    case all
    case videos
    case photos
    case screenshots
    case animated
    case raws
    case favorites
    case text
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

    var title: String {
        switch self {
        case .all: return "全部项目"
        case .videos: return "视频"
        case .photos: return "照片"
        case .screenshots: return "截屏"
        case .animated: return "动图"
        case .raws: return "RAW"
        case .favorites: return "个人收藏"
        case .text: return "包含文字"
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

    var icon: String {
        switch self {
        case .all: return "photo.stack"
        case .videos: return "video"
        case .photos: return "photo"
        case .screenshots: return "camera.viewfinder"
        case .animated: return "photo.on.rectangle.angled"
        case .raws: return "camera.aperture"
        case .favorites: return "heart.fill"
        case .text: return "text.viewfinder"
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
    var key: String {
        switch self {
        case .all: return "all"
        case .videos: return "videos"
        case .photos: return "photos"
        case .screenshots: return "screenshots"
        case .animated: return "animated"
        case .raws: return "raws"
        case .favorites: return "favorites"
        case .text: return "text"
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
    var requiresAnalysis: Bool {
        switch self {
        case .text, .scene: return true
        default: return false
        }
    }

    /// 地图 / 位置 / 人物 / 重复项目 / 关键词在网盘里使用各自的只读派生视图，而不是照片网格。
    var usesDedicatedView: Bool {
        switch self {
        case .map, .places, .people, .duplicates, .health, .keywords: return true
        default: return false
        }
    }

    /// 关键词范围能否一键返回关键词总览。
    var keywordOverviewParent: CloudScope? {
        if case .keyword = self { return .keywords }
        return nil
    }
}


/// 网盘的分区总览：与拾光 / 系统图库一样，点侧边栏分区标题进入卡片墙。
enum CloudOverviewSection: String, Identifiable, Equatable {
    case mediaTypes
    case moreItems
    case scenes
    case folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mediaTypes: return "媒体类型"
        case .moreItems: return "更多项目"
        case .scenes: return "场景"
        case .folders: return "相簿"
        }
    }
}

/// 网盘当前列表的分类计数：一次遍历得出，随目录版本与识别进度缓存。
struct CloudScopeCounts {
    var videos = 0
    var photos = 0
    var screenshots = 0
    var animated = 0
    var raws = 0
    var favorites = 0
    var text = 0
    var revisit = 0
    var located = 0
    var people = 0
    var duplicates = 0
    var health = 0
    var scenes: [String: Int] = [:]
    /// 每个关键词对应的照片数；键数量即关键词总数。
    var keywords: [String: Int] = [:]

    func count(for scope: CloudScope) -> Int {
        switch scope {
        case .all: return photos + videos
        case .videos: return videos
        case .photos: return photos
        case .screenshots: return screenshots
        case .animated: return animated
        case .raws: return raws
        case .favorites: return favorites
        case .text: return text
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
}

/// 网盘媒体类型按文件名与扩展名推断；EXIF（拍摄时间 / 相机 / GPS）由 `CloudEXIF` 读取文件头部得到。
enum CloudMediaNaming {
    /// 截屏：主流平台导出的文件名都带 Screenshot / 截屏 等字样。
    static func looksLikeScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        let english = ["screenshot", "screen shot", "screencapture"]
        if english.contains(where: { lower.contains($0) }) { return true }
        let chinese = ["截屏", "截图", "截圖", "屏幕快照", "屏幕截图"]
        return chinese.contains { name.contains($0) }
    }
}
