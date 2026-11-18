import Foundation

// MARK: - 影院刮削

enum CinemaMediaKind: String, Codable {
    case movie
    case tv

    var title: String {
        switch self {
        case .movie: return "电影"
        case .tv: return "电视剧"
        }
    }
}

/// 刮削数据源。豆瓣排在最前：免 Key，作为默认数据源。
enum CinemaProvider: String, CaseIterable, Identifiable {
    case douban
    case tmdb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tmdb: return "TMDB"
        case .douban: return "豆瓣"
        }
    }

    var tagline: String {
        switch self {
        case .tmdb: return "官方 API · 全球影视 · 海报与背景图"
        case .douban: return "中文影视更全 · 免 Key · 非官方接口"
        }
    }

    var badge: String? {
        switch self {
        case .tmdb: return "推荐"
        case .douban: return "实验性"
        }
    }
}

/// 影院作用域：本地图库，或某一个网盘实例。刮削结果按作用域分别保存。
enum CinemaScope: Hashable {
    case local
    case mount(UUID)
}

/// 影院顶部的分段：全部 / 电影 / 电视剧。
/// 状态放在 `LibraryStore`，让顶栏控制台与内容页共用同一个选中值。
enum CinemaTab: String, CaseIterable, Identifiable {
    case all
    case movies
    case shows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .movies: return "电影"
        case .shows: return "电视剧"
        }
    }

    var icon: String {
        switch self {
        case .all: return "film.stack"
        case .movies: return "film"
        case .shows: return "tv"
        }
    }
}

/// 不同数据源归一化后的搜索结果，交给 `CinemaScraper` 统一打分。
struct CinemaMatch: Hashable {
    var id: String
    var isTV: Bool
    var title: String
    var originalTitle: String?
    var year: Int?
    var posterURL: String?
    var backdropURL: String?
    var overview: String?
    var rating: Double?
    /// 投票数：同名作品里优先选更热门 / 更权威的那一条。
    var voteCount: Int?
    /// 类型标签（剧情 / 科幻 / 悬疑……），用于影院顶栏的筛选。
    var genres: [String] = []
}

/// 从文件名 + 所在文件夹解析出的基础信息。
struct CinemaParsedName: Equatable {
    var title: String
    /// 与主标题并列的另一语言名（中文名 / 英文名）。
    var altTitle: String?
    var year: Int?
    var season: Int?
    var episode: Int?
    /// 多集文件的结束集号（S01E01-E03）。
    var episodeEnd: Int?
    var isTV: Bool
    /// 从所在文件夹推断的剧名 / 片名。
    var folderTitle: String?
    /// 分辨率，仅用于展示与排查，不参与匹配。
    var resolution: String?
}

/// 参与刮削的一条候选：文件本身 + 所在目录链（用于补全剧名 / 季 / 年份）。
struct CinemaCandidate {
    var photo: PhotoItem
    var folderHint: String?
}

/// 供影院库渲染与播放的轻量视频快照（不依赖网盘目录是否已加载）。
struct CinemaFile: Codable, Hashable {
    var photoID: UUID
    var filename: String
    var capturedAt: Date
    var duration: Double?
    var fileSize: Int64
    var cloudMountID: UUID?
    var cloudPath: String?
    var cloudRemoteID: String?
    var cloudThumbnailURL: String?
    /// 网盘端标记为受限内容时保留，影院播放同样需要给出准确提示。
    var cloudRestricted: Bool?
    var pixelWidth: Int
    var pixelHeight: Int

    init(photo: PhotoItem) {
        photoID = photo.id
        filename = photo.displayFilename
        capturedAt = photo.capturedAt
        duration = photo.duration
        fileSize = photo.fileSize
        cloudMountID = photo.cloudMountID
        cloudPath = photo.cloudPath
        cloudRemoteID = photo.cloudRemoteID
        cloudThumbnailURL = photo.cloudThumbnailURL
        cloudRestricted = photo.cloudRestricted
        pixelWidth = photo.pixelWidth
        pixelHeight = photo.pixelHeight
    }

    var isCloud: Bool { cloudMountID != nil }

    /// 还原成播放器认识的 PhotoItem；本地文件按文件名回到图库中查找。
    var photoItem: PhotoItem {
        var item = PhotoItem(id: photoID,
                             filename: filename,
                             editedFilename: nil,
                             originalName: filename,
                             capturedAt: capturedAt,
                             pixelWidth: pixelWidth,
                             pixelHeight: pixelHeight,
                             fileSize: fileSize,
                             kind: .video)
        item.duration = duration
        item.source = isCloud ? .cloud : .local
        item.cloudMountID = cloudMountID
        item.cloudPath = cloudPath
        item.cloudRemoteID = cloudRemoteID
        item.cloudThumbnailURL = cloudThumbnailURL
        item.cloudRestricted = cloudRestricted
        return item
    }
}

/// 一条刮削结果。未匹配到 TMDB 时也会保留，用于「未识别」列表与再次刮削。
struct CinemaEntry: Codable, Identifiable, Hashable {
    var file: CinemaFile
    var kind: CinemaMediaKind
    var matched: Bool
    var title: String
    var originalTitle: String?
    var year: Int?
    var season: Int?
    var episode: Int?
    var episodeEnd: Int?
    var tmdbID: Int?
    var posterURL: String?
    var backdropURL: String?
    var overview: String?
    var rating: Double?
    var scrapedAt: Date
    /// 刮削时使用的目录链（剧名 / 季），再次刮削时继续用它。
    var folderHint: String?
    /// 类型标签（剧情 / 科幻 / 悬疑……）。旧版本刮削结果没有这一项，重新刮削即可补齐。
    var genres: [String]? = nil

    var id: UUID { file.photoID }

    /// 年代（2020 年代返回 2020），筛选与分组都用它。
    var decade: Int? { year.map { $0 / 10 * 10 } }

    var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if kind == .tv, let season, let episode {
            var value = String(format: "S%02dE%02d", season, episode)
            if let end = episodeEnd, end > episode {
                value = String(format: "S%02dE%02d-E%02d", season, episode, end)
            }
            parts.append(value)
        }
        return parts.joined(separator: " · ")
    }

    var artworkURL: String? { posterURL ?? backdropURL }
    /// 网格单元格是横向的，优先用 backdrop，避免竖版海报被裁得只剩一条。
    var gridArtworkURL: String? { backdropURL ?? posterURL }
}

/// 同一部剧的多集聚合成一张卡片：影院里按「剧」浏览，而不是一集一张。
struct CinemaSeries: Identifiable, Hashable {
    var id: String
    var title: String
    var year: Int?
    var overview: String?
    var rating: Double?
    var posterURL: String?
    var backdropURL: String?
    var episodes: [CinemaEntry]

    var episodeCount: Int { episodes.count }

    /// 聚合里的分集是否已经识别；未识别的剧同样聚合成一张卡。
    var isMatched: Bool { episodes.first?.matched ?? false }

    var latestEpisode: CinemaEntry? {
        episodes.max { lhs, rhs in
            (lhs.season ?? 0, lhs.episode ?? 0) < (rhs.season ?? 0, rhs.episode ?? 0)
        }
    }

    var artworkURL: String? { posterURL ?? backdropURL }
    var gridArtworkURL: String? { backdropURL ?? posterURL }

    var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        parts.append("\(episodeCount) 集")
        if let latest = latestEpisode, let season = latest.season, let episode = latest.episode {
            parts.append(String(format: "最新 S%02dE%02d", season, episode))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 配置检测

/// 「测试连接」的一次结果，只在设置面板里展示。
struct CinemaConnectionResult: Equatable {
    var ok: Bool
    var message: String
}

/// 单条刮削结果：`entry` 为空代表网络 / 接口出错，`error` 为空代表正常（含未匹配）。
struct CinemaScrapeOutcome {
    var entry: CinemaEntry?
    var error: String?
}
