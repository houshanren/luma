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
        }
    }

    /// 需要先做端侧识别才能用的范围。
    var requiresAnalysis: Bool {
        switch self {
        case .text, .scene: return true
        default: return false
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
    var scenes: [String: Int] = [:]

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
        }
    }
}

/// 网盘没有可读的 EXIF / Photos.sqlite，类型只能按文件名与扩展名推断。
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
