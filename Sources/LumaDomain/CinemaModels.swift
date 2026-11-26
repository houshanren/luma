import Foundation

// MARK: - 影院刮削

/// 相似推荐：只存展示所需的最小信息，点击时再回本库找同 tmdbID 的条目。
public struct CinemaRecommendation: Codable, Hashable, Identifiable {
    public var tmdbID: Int
    public var kind: CinemaMediaKind
    public var title: String
    public var year: Int?
    public var posterURL: String?
    public var rating: Double?
    /// 豆瓣条目 ID：豆瓣推荐不能按 tmdbID 回本库，点击时改为打开豆瓣页。
    public var doubanID: String? = nil

    public var id: String {
        if let doubanID { return "douban-\(doubanID)" }
        return "\(kind.rawValue)-\(tmdbID)"
    }
    public init(
        tmdbID: Int,
        kind: CinemaMediaKind,
        title: String,
        year: Int? = nil,
        posterURL: String? = nil,
        rating: Double? = nil,
        doubanID: String? = nil
    ) {
        self.tmdbID = tmdbID
        self.kind = kind
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.rating = rating
        self.doubanID = doubanID
    }
}

/// 推荐分组：详情页每个 tab 一组，来源决定点击行为。
public struct CinemaRecommendationGroup: Codable, Hashable, Identifiable {
    public enum Source: String, Codable {
        case tmdb
        case douban
        case collection
        case director
        case cast
    }

    public var source: Source
    public var title: String
    public var items: [CinemaRecommendation]

    public var id: String { source.rawValue }
    public init(
        source: Source,
        title: String,
        items: [CinemaRecommendation]
    ) {
        self.source = source
        self.title = title
        self.items = items
    }
}

/// TMDB 图片候选：海报 / 背景二选一，写回条目后立即生效。
public struct CinemaArtworkCandidate: Identifiable, Hashable {
    public var url: String
    public var width: Int
    public var height: Int
    public var language: String?
    public var rating: Double?

    public var id: String { url }

    /// 「zh」/「en」/ 无语言三种来源的排序权重：中文优先，其次无语言（通常是原版）。
    public var languageRank: Int {
        switch language {
        case "zh", "cn", "zh-CN": return 0
        case nil, "": return 1
        default: return 2
        }
    }
    public init(
        url: String,
        width: Int,
        height: Int,
        language: String? = nil,
        rating: Double? = nil
    ) {
        self.url = url
        self.width = width
        self.height = height
        self.language = language
        self.rating = rating
    }
}

public enum CinemaMediaKind: String, Codable, CaseIterable, Identifiable {
    case movie
    case tv

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .movie: return "电影"
        case .tv: return "电视剧"
        }
    }
}

/// 刮削数据源。值表示「优先使用哪个」：两个源同时启用，前一个没匹配到再换另一个。
public enum CinemaProvider: String, Codable, CaseIterable, Identifiable {
    case douban
    case tmdb
    case tvdb

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tmdb: return "TMDB"
        case .douban: return "豆瓣"
        case .tvdb: return "TVDB"
        }
    }

    public var tagline: String {
        switch self {
        case .tmdb: return "官方 API · 全球影视 · 海报与背景图"
        case .douban: return "中文影视更全 · 免 Key · 非官方接口"
        case .tvdb: return "剧集资料与分集更细 · 需 API Key"
        }
    }

    public var badge: String? {
        switch self {
        case .tmdb: return "推荐"
        case .douban: return "实验性"
        case .tvdb: return nil
        }
    }
}

/// 影院作用域：本地图库，或某一个网盘实例。刮削结果按作用域分别保存。
public enum CinemaScope: Hashable {
    case local
    case mount(UUID)
}

/// 影院顶部的分段：全部 / 电影 / 电视剧 / 文件夹。
/// 状态放在 `LibraryStore`，让顶栏控制台与内容页共用同一个选中值。
public enum CinemaTab: String, CaseIterable, Identifiable {
    case all
    case movies
    case shows
    case folder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .movies: return "电影"
        case .shows: return "电视剧"
        case .folder: return "文件夹"
        }
    }

    public var icon: String {
        switch self {
        case .all: return "film.stack"
        case .movies: return "film"
        case .shows: return "tv"
        case .folder: return "folder"
        }
    }
}

/// 影院的内容类型：电影 / 电视剧之外，由刮削到的类型标签映射出的细分入口。
/// 内置四个（动漫 / 综艺 / 演唱会 / 纪录片）默认固定在顶栏，其余类型折叠进「类型」弹层。
/// 判定完全基于 TMDB / 豆瓣返回的类型标签，不额外扫目录。
public struct CinemaContentType: Identifiable, Hashable {
    /// 稳定键：内置类型用固定 slug，普通类型直接用类型名。
    public var id: String
    public var title: String
    public var icon: String
    /// 命中任意一个标签都算这个类型：TMDB 与豆瓣的用词不同，这里都收进来。
    public var genreKeys: [String]

    public static let anime = CinemaContentType(id: "anime", title: "动漫",
                                         icon: "sparkles",
                                         genreKeys: ["动画", "动漫"])
    public static let variety = CinemaContentType(id: "variety", title: "综艺",
                                           icon: "theatermasks.fill",
                                           genreKeys: ["真人秀", "脱口秀", "综艺"])
    public static let concert = CinemaContentType(id: "concert", title: "演唱会",
                                           icon: "music.mic",
                                           genreKeys: ["音乐", "演唱会", "音乐会"])
    public static let documentary = CinemaContentType(id: "documentary", title: "纪录片",
                                               icon: "camera.fill",
                                               genreKeys: ["纪录", "纪录片"])

    public static let builtIns: [CinemaContentType] = [anime, variety, concert, documentary]

    public static func builtIn(id: String) -> CinemaContentType? {
        builtIns.first { $0.id == id }
    }

    /// 普通类型（动作 / 喜剧 / 科幻……）：标题就是类型名本身。
    public static func generic(_ genre: String) -> CinemaContentType {
        CinemaContentType(id: genre, title: genre, icon: "tag", genreKeys: [genre])
    }

    public static func descriptor(id: String) -> CinemaContentType {
        builtIn(id: id) ?? generic(id)
    }

    public func matches(_ genres: [String]?) -> Bool {
        guard let genres, !genres.isEmpty else { return false }
        return genres.contains { genre in
            genreKeys.contains { genre == $0 || genre.contains($0) }
        }
    }

    /// 一组标签同时命中内置类型与普通类型（同一个标签不会被算两次）。
    public static func ids(matching genres: [String]) -> [String] {
        var ids = builtIns.filter { $0.matches(genres) }.map(\.id)
        for genre in genres where !builtIns.contains(where: { $0.matches([genre]) }) {
            if !ids.contains(genre) { ids.append(genre) }
        }
        return ids
    }
    public init(
        id: String,
        title: String,
        icon: String,
        genreKeys: [String]
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.genreKeys = genreKeys
    }
}

/// 某个类型在当前影院里的可点条目数：电影按版本去重，剧集按整部计。
public struct CinemaTypeBucket: Identifiable, Hashable {
    public var type: CinemaContentType
    public var count: Int
    public var id: String { type.id }
    public init(
        type: CinemaContentType,
        count: Int
    ) {
        self.type = type
        self.count = count
    }
}

/// 影院里的一个文件夹节点：可以一层层点进去。
/// `photos` 是当前目录直属视频；`subtreePhotos` 含所有子目录，用于统计与整目录刮削。
public struct CinemaFolder: Identifiable {
    public var path: String
    public var name: String
    public var parentPath: String?
    /// 人类可读的目录链（夸克等网盘的 path 是 ID，展示时用它）。
    public var hint: String?
    public var mountID: UUID?
    public var photos: [PhotoItem]
    public var entries: [CinemaEntry]
    public var children: [CinemaFolder]
    public var subtreePhotos: [PhotoItem]
    public var matchedCount: Int
    public var title: String?
    public var kind: CinemaMediaKind?
    public var posterURL: String?
    public var backdropURL: String?
    public var year: Int?
    public var episodeCount: Int

    public var id: String { path }
    public var displayPath: String { hint ?? name }
    public var displayTitle: String { title ?? name }
    public var isMatched: Bool { matchedCount > 0 }
    public var totalCount: Int { subtreePhotos.count }
    public var unmatchedCount: Int { max(0, totalCount - matchedCount) }
    public var firstPhoto: PhotoItem? { photos.first ?? subtreePhotos.first }
    public var hasChildren: Bool { !children.isEmpty }
    public var hasVideos: Bool { !photos.isEmpty }
    public init(
        path: String,
        name: String,
        parentPath: String? = nil,
        hint: String? = nil,
        mountID: UUID? = nil,
        photos: [PhotoItem],
        entries: [CinemaEntry],
        children: [CinemaFolder],
        subtreePhotos: [PhotoItem],
        matchedCount: Int,
        title: String? = nil,
        kind: CinemaMediaKind? = nil,
        posterURL: String? = nil,
        backdropURL: String? = nil,
        year: Int? = nil,
        episodeCount: Int
    ) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.hint = hint
        self.mountID = mountID
        self.photos = photos
        self.entries = entries
        self.children = children
        self.subtreePhotos = subtreePhotos
        self.matchedCount = matchedCount
        self.title = title
        self.kind = kind
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.year = year
        self.episodeCount = episodeCount
    }
}

/// 影院的浏览姿态：书架 / 海报墙 / 列表。只改变呈现，不改变数据。
public enum CinemaViewMode: String, CaseIterable, Identifiable {
    case shelf
    case wall
    case card
    case list

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shelf: return "书架"
        case .wall: return "海报墙"
        case .card: return "卡片"
        case .list: return "列表"
        }
    }

    public var icon: String {
        switch self {
        case .shelf: return "rectangle.stack"
        case .wall: return "square.grid.2x2"
        case .card: return "rectangle.on.rectangle"
        case .list: return "list.bullet"
        }
    }
}

/// 海报墙密度：只改每列的最小宽度与卡片大小，不改数据。
public enum CinemaWallDensity: String, CaseIterable, Identifiable {
    case compact
    case normal
    case large

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: return "紧凑"
        case .normal: return "标准"
        case .large: return "大图"
        }
    }

    /// 海报墙每列最小宽度：越紧凑，同屏放的卡片越多。
    public var minimumColumnWidth: CGFloat {
        switch self {
        case .compact: return 128
        case .normal: return 156
        case .large: return 196
        }
    }

    /// 卡片模式（16:9 宽幅）的最小列宽。
    public var minimumCardWidth: CGFloat {
        switch self {
        case .compact: return 300
        case .normal: return 340
        case .large: return 400
        }
    }
}

/// 影院排序：只改变顺序，不改变集合。
public enum CinemaSort: String, CaseIterable, Identifiable {
    case recent
    case rating
    case year
    case title
    case duration
    /// 随机：同一次进入影院内顺序稳定，下次进入重新洗牌。
    case random

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recent: return "最近添加（新 → 旧）"
        case .rating: return "评分（高 → 低）"
        case .year: return "年份（新 → 旧）"
        case .title: return "片名（A → Z）"
        case .duration: return "时长（长 → 短）"
        case .random: return "随机（每次进入重排）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .recent: return "最近"
        case .rating: return "评分"
        case .year: return "年份"
        case .title: return "片名"
        case .duration: return "时长"
        case .random: return "随机"
        }
    }
}

/// 观看状态筛选：从本地续播记录派生。
public enum CinemaWatchFilter: String, CaseIterable, Identifiable, Hashable {
    case unwatched
    case inProgress
    case finished

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unwatched: return "未看"
        case .inProgress: return "进行中"
        case .finished: return "已看完"
        }
    }
}

/// 分辨率筛选：从文件的像素宽度派生，不做主观画质判断。
public enum CinemaResolutionFilter: String, CaseIterable, Identifiable, Hashable {
    case uhd4k
    case fullHD
    case sd

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .uhd4k: return "4K"
        case .fullHD: return "1080P / 2K"
        case .sd: return "720P 及以下"
        }
    }

    public func matches(_ file: CinemaFile) -> Bool {
        let width = file.pixelWidth
        guard width > 0 else { return false }
        switch self {
        case .uhd4k: return width >= 3000
        case .fullHD: return width >= 1800 && width < 3000
        case .sd: return width < 1800
        }
    }
}

/// 规格筛选：从文件名里的发行标记派生，只做筛选与角标，不参与匹配。
public enum CinemaSpecFilter: String, CaseIterable, Identifiable, Hashable {
    case dolbyVision
    case hdr
    case atmos
    case highFrameRate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dolbyVision: return "杜比视界"
        case .hdr: return "HDR"
        case .atmos: return "杜比全景声"
        case .highFrameRate: return "高帧率"
        }
    }

    public func matches(_ file: CinemaFile) -> Bool {
        switch self {
        case .dolbyVision:
            return file.displayTags.contains("DV")
        case .hdr:
            return file.displayTags.contains { $0 == "DV" || $0.hasPrefix("HDR") }
        case .atmos:
            return file.displayTags.contains("Atmos")
        case .highFrameRate:
            return (file.parsedFrameRate ?? 0) >= 50
        }
    }
}

/// 片长筛选：按分钟分档，剧集用单集时长。
public enum CinemaRuntimeFilter: String, CaseIterable, Identifiable, Hashable {
    case short
    case standard
    case long

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .short: return "短片 <40"
        case .standard: return "标准 40–120"
        case .long: return "长片 >120"
        }
    }

    public func matches(_ minutes: Int?) -> Bool {
        guard let minutes, minutes > 0 else { return false }
        switch self {
        case .short: return minutes < 40
        case .standard: return minutes >= 40 && minutes <= 120
        case .long: return minutes > 120
        }
    }
}

/// 评分筛选：按刮削到的评分分档；「暂无评分」单独一档。
public enum CinemaRatingFilter: String, CaseIterable, Identifiable, Hashable {
    case excellent
    case great
    case good
    case unrated

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .excellent: return "9 分+"
        case .great: return "8 分+"
        case .good: return "7 分+"
        case .unrated: return "暂无评分"
        }
    }

    public func matches(_ rating: Double?) -> Bool {
        switch self {
        case .excellent: return (rating ?? 0) >= 9
        case .great: return (rating ?? 0) >= 8
        case .good: return (rating ?? 0) >= 7
        case .unrated: return (rating ?? 0) <= 0
        }
    }
}

/// 地区 / 语言筛选里显示的语言名：原始值保留 ISO 代码，界面只负责翻译常见项。
public enum CinemaLanguageCatalog {
    public static func title(_ code: String) -> String {
        switch code.lowercased() {
        case "zh": return "中文"
        case "cn": return "粤语"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        case "it": return "意大利语"
        case "ru": return "俄语"
        case "hi": return "印地语"
        case "th": return "泰语"
        case "pt": return "葡萄牙语"
        case "ar": return "阿拉伯语"
        default: return code.uppercased()
        }
    }
}

/// 不同数据源归一化后的搜索结果，交给 `CinemaScraper` 统一打分。
public struct CinemaMatch: Hashable {
    public var id: String
    public var isTV: Bool
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var posterURL: String?
    public var backdropURL: String?
    public var overview: String?
    public var rating: Double?
    /// 投票数：同名作品里优先选更热门 / 更权威的那一条。
    public var voteCount: Int?
    /// 类型标签（剧情 / 科幻 / 悬疑……），用于影院顶栏的筛选。
    public var genres: [String] = []
    /// 这条结果来自哪个数据源；详情（合集 / 演职员 / 预告）只有 TMDB 能补。
    public var provider: CinemaProvider? = nil

    /// 候选唯一键：不同数据源的数字 ID 可能撞号，比较与去重都带上来源。
    public var sourceKey: String { "\(provider?.rawValue ?? "?")-\(id)" }
    public init(
        id: String,
        isTV: Bool,
        title: String,
        originalTitle: String? = nil,
        year: Int? = nil,
        posterURL: String? = nil,
        backdropURL: String? = nil,
        overview: String? = nil,
        rating: Double? = nil,
        voteCount: Int? = nil,
        genres: [String] = [],
        provider: CinemaProvider? = nil
    ) {
        self.id = id
        self.isTV = isTV
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.overview = overview
        self.rating = rating
        self.voteCount = voteCount
        self.genres = genres
        self.provider = provider
    }
}

/// 演职员一条：只存展示需要的名字、角色、头像与 TMDB 人物 ID（人物页要按 ID 拉作品）。
public struct CinemaCastMember: Codable, Hashable, Identifiable {
    public var name: String
    public var character: String?
    public var profileURL: String?
    public var tmdbID: Int? = nil

    public var id: String { name + "|" + (character ?? "") }
    public init(
        name: String,
        character: String? = nil,
        profileURL: String? = nil,
        tmdbID: Int? = nil
    ) {
        self.name = name
        self.character = character
        self.profileURL = profileURL
        self.tmdbID = tmdbID
    }
}

/// 人物页「全部作品」里的一条：来自 TMDB combined_credits，不落库。
public struct CinemaPersonCredit: Hashable, Identifiable {
    public var tmdbID: Int
    public var isTV: Bool
    public var title: String
    public var year: Int?
    public var posterURL: String?
    public var character: String?
    public var job: String?

    public var id: String { "\(isTV ? "tv" : "movie")-\(tmdbID)" }
    public init(
        tmdbID: Int,
        isTV: Bool,
        title: String,
        year: Int? = nil,
        posterURL: String? = nil,
        character: String? = nil,
        job: String? = nil
    ) {
        self.tmdbID = tmdbID
        self.isTV = isTV
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.character = character
        self.job = job
    }
}

/// 人物页数据：简介、出生信息与全部作品。
public struct CinemaPersonProfile: Hashable {
    public var name: String
    public var biography: String?
    public var birthday: String?
    public var placeOfBirth: String?
    public var profileURL: String?
    public var department: String?
    public var credits: [CinemaPersonCredit] = []
    public init(
        name: String,
        biography: String? = nil,
        birthday: String? = nil,
        placeOfBirth: String? = nil,
        profileURL: String? = nil,
        department: String? = nil,
        credits: [CinemaPersonCredit] = []
    ) {
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.placeOfBirth = placeOfBirth
        self.profileURL = profileURL
        self.department = department
        self.credits = credits
    }
}

/// 合集详情：TMDB 合集简介 + 全集列表（用于算出「下一部未入库」）。
public struct CinemaCollectionPart: Hashable {
    public var tmdbID: Int
    public var title: String
    public var year: Int?
    public init(
        tmdbID: Int,
        title: String,
        year: Int? = nil
    ) {
        self.tmdbID = tmdbID
        self.title = title
        self.year = year
    }
}

public struct CinemaCollectionInfo: Hashable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var parts: [CinemaCollectionPart] = []
    public init(
        id: Int,
        name: String,
        overview: String? = nil,
        parts: [CinemaCollectionPart] = []
    ) {
        self.id = id
        self.name = name
        self.overview = overview
        self.parts = parts
    }
}

/// 交给大模型做季集映射的单个文件（index 从 1 开始，和界面里的序号一致）。
public struct CinemaAIMatchFile: Codable, Hashable {
    public var index: Int
    public var filename: String
    public var detectedEpisode: Int?
    public var durationSeconds: Double?
    public var sizeBytes: Int64?
    public init(
        index: Int,
        filename: String,
        detectedEpisode: Int? = nil,
        durationSeconds: Double? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.index = index
        self.filename = filename
        self.detectedEpisode = detectedEpisode
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
    }
}

/// 智能季集映射的输入：剧名、季、文件列表和用户补充要求。
public struct CinemaAIMatchRequest: Codable, Hashable {
    public var title: String
    public var year: Int?
    public var season: Int
    public var files: [CinemaAIMatchFile]
    public var note: String?
    public init(
        title: String,
        year: Int? = nil,
        season: Int,
        files: [CinemaAIMatchFile],
        note: String? = nil
    ) {
        self.title = title
        self.year = year
        self.season = season
        self.files = files
        self.note = note
    }
}

/// 智能季集映射的计划：index → 集号；mode / offset 是模型可选调用的工具结果。
public struct CinemaAIMatchPlan: Hashable {
    public var assignments: [Int: Int]
    public var mode: String?
    public var offset: Int?
    public var note: String?
    public init(
        assignments: [Int: Int],
        mode: String? = nil,
        offset: Int? = nil,
        note: String? = nil
    ) {
        self.assignments = assignments
        self.mode = mode
        self.offset = offset
        self.note = note
    }
}

/// 影院通知：任务结果归档，按今天 / 本周分组，仅保留最近 30 天。
public enum CinemaNotificationKind: String, Codable, Hashable {
    case success
    case failure
    case progress
    case info
}

public struct CinemaNotification: Codable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var kind: CinemaNotificationKind = .info
    public var title: String
    public var detail: String = ""
    public var date: Date = Date()
    public var read = false
    /// 行内动作标题（处理 / 重试 / 重连）；nil 表示只读通知。
    public var action: String? = nil
    public var scopeKey: String? = nil
    public init(
        id: UUID = UUID(),
        kind: CinemaNotificationKind = .info,
        title: String,
        detail: String = "",
        date: Date = Date(),
        read: Bool = false,
        action: String? = nil,
        scopeKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
        self.read = read
        self.action = action
        self.scopeKey = scopeKey
    }
}

/// 右上角 Toast：成功 4 秒消失，失败与进度常驻，最多同时 3 条。
public enum CinemaToastKind: Hashable {
    case success
    case failure
    case progress
    case info
}

public struct CinemaToast: Identifiable {
    public let id = UUID()
    public var kind: CinemaToastKind
    public var title: String
    public var detail: String?
    public var actionTitle: String?
    public var action: (() -> Void)?
    public init(
        kind: CinemaToastKind,
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }
}

/// TMDB 单集信息：剧集详情里每集的标题、简介与剧照（按 tmdbID + 季缓存进图库设置库）。
public struct CinemaEpisodeInfo: Codable, Hashable {
    public var title: String
    public var overview: String?
    public var stillURL: String?
    public init(
        title: String,
        overview: String? = nil,
        stillURL: String? = nil
    ) {
        self.title = title
        self.overview = overview
        self.stillURL = stillURL
    }
}

/// 相簿 / 网格多选右键「手动匹配」的目标：一次可以匹配多个视频（各自按文件名解析季集）。
public struct CinemaQuickMatchRequest: Identifiable {
    public let id = UUID()
    public var photos: [PhotoItem]
    public init(
        photos: [PhotoItem]
    ) {
        self.photos = photos
    }
}

/// TMDB 详情补全结果：合集、演职员、预告片与分级。
public struct CinemaDetails: Hashable {
    public var collectionID: Int?
    public var collectionName: String?
    public var cast: [CinemaCastMember] = []
    public var directors: [String] = []
    public var certification: String?
    public var trailerKey: String?
    // 简介之外的基础资料：详情页「完整信息」用。
    public var tagline: String?
    /// 电影片长 / 剧集单集时长（分钟）。
    public var runtime: Int?
    /// 剧集播出状态：Returning Series / Ended 等。
    public var status: String?
    public var releaseDate: String?
    public var originalLanguage: String?
    public var countries: [String] = []
    public var companies: [String] = []
    /// 剧集播出平台（Networks）。
    public var networks: [String] = []
    public var seasonCount: Int?
    public var episodeCount: Int?
    public var voteCount: Int?
    public var budget: Int64?
    public var revenue: Int64?
    /// 悬停档案 / 未入库作品展示用：简介、评分与类型。
    public var overview: String?
    public var rating: Double?
    public var genres: [String] = []
    public init(
        collectionID: Int? = nil,
        collectionName: String? = nil,
        cast: [CinemaCastMember] = [],
        directors: [String] = [],
        certification: String? = nil,
        trailerKey: String? = nil,
        tagline: String? = nil,
        runtime: Int? = nil,
        status: String? = nil,
        releaseDate: String? = nil,
        originalLanguage: String? = nil,
        countries: [String] = [],
        companies: [String] = [],
        networks: [String] = [],
        seasonCount: Int? = nil,
        episodeCount: Int? = nil,
        voteCount: Int? = nil,
        budget: Int64? = nil,
        revenue: Int64? = nil,
        overview: String? = nil,
        rating: Double? = nil,
        genres: [String] = []
    ) {
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.cast = cast
        self.directors = directors
        self.certification = certification
        self.trailerKey = trailerKey
        self.tagline = tagline
        self.runtime = runtime
        self.status = status
        self.releaseDate = releaseDate
        self.originalLanguage = originalLanguage
        self.countries = countries
        self.companies = companies
        self.networks = networks
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
        self.voteCount = voteCount
        self.budget = budget
        self.revenue = revenue
        self.overview = overview
        self.rating = rating
        self.genres = genres
    }
}

/// 家长控制档位：按分级字符串换算，未识别分级的条目默认放行。
public enum CinemaParentalLevel: Int, CaseIterable, Identifiable {
    case off = 0
    case child = 1
    case teen = 3
    case adult = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: return "关闭"
        case .child: return "儿童（G）"
        case .teen: return "青少年（PG-13）"
        case .adult: return "成人（R）"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "不做任何限制。"
        case .child: return "只显示 G / TV-Y / TV-G 级内容。"
        case .teen: return "允许到 PG / PG-13 / TV-14。"
        case .adult: return "允许到 R / NC-17 / TV-MA，即全部分级。"
        }
    }

    /// 分级字符串 → 1（G）… 4（R）；无法识别返回 nil。
    public static func level(of certification: String?) -> Int? {
        guard let raw = certification?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "G", "TV-Y", "TV-Y7", "TV-G": return 1
        case "PG", "TV-PG": return 2
        case "PG-13", "TV-14": return 3
        case "R", "NC-17", "TV-MA", "18", "18+": return 4
        default: return nil
        }
    }

    public func allows(certification: String?) -> Bool {
        guard self != .off else { return true }
        // 儿童模式：没有分级（未识别 / 刮削缺分级）一律按最严格处理，不冒险展示。
        guard let level = Self.level(of: certification) else { return false }
        return level <= rawValue
    }
}

/// 从文件名 + 所在文件夹解析出的基础信息。
public struct CinemaParsedName: Equatable {
    public var title: String
    /// 与主标题并列的另一语言名（中文名 / 英文名）。
    public var altTitle: String?
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    /// 多集文件的结束集号（S01E01-E03）。
    public var episodeEnd: Int?
    public var isTV: Bool
    /// 从所在文件夹推断的剧名 / 片名。
    public var folderTitle: String?
    /// 分辨率，仅用于展示与排查，不参与匹配。
    public var resolution: String?
    public init(
        title: String,
        altTitle: String? = nil,
        year: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodeEnd: Int? = nil,
        isTV: Bool,
        folderTitle: String? = nil,
        resolution: String? = nil
    ) {
        self.title = title
        self.altTitle = altTitle
        self.year = year
        self.season = season
        self.episode = episode
        self.episodeEnd = episodeEnd
        self.isTV = isTV
        self.folderTitle = folderTitle
        self.resolution = resolution
    }
}

/// 剧集级跳过设置：片头 / 片尾各多少秒（0 表示不跳过）。
/// 按剧（`CinemaSeries.id`）保存，播放时自动应用，对应芝杜的「跳过片头尾」。
public struct CinemaIntroMark: Codable, Hashable {
    public var introSeconds: Int = 0
    public var outroSeconds: Int = 0

    public var isEnabled: Bool { introSeconds > 0 || outroSeconds > 0 }
    public init(
        introSeconds: Int = 0,
        outroSeconds: Int = 0
    ) {
        self.introSeconds = introSeconds
        self.outroSeconds = outroSeconds
    }
}

/// 参与刮削的一条候选：文件本身 + 所在目录链（用于补全剧名 / 季 / 年份）。
public struct CinemaCandidate {
    public var photo: PhotoItem
    public var folderHint: String?
    /// 所在目录的真实路径（网盘是目录 ID）：文件夹视图靠它还原可钻取的目录树。
    public var folderPath: String?
    public init(
        photo: PhotoItem,
        folderHint: String? = nil,
        folderPath: String? = nil
    ) {
        self.photo = photo
        self.folderHint = folderHint
        self.folderPath = folderPath
    }
}

/// 供影院库渲染与播放的轻量视频快照（不依赖网盘目录是否已加载）。
public struct CinemaFile: Codable, Hashable {
    public var photoID: UUID
    public var filename: String
    public var capturedAt: Date
    public var duration: Double?
    public var fileSize: Int64
    public var cloudMountID: UUID?
    public var cloudPath: String?
    public var cloudRemoteID: String?
    public var cloudThumbnailURL: String?
    /// 网盘端标记为受限内容时保留，影院播放同样需要给出准确提示。
    public var cloudRestricted: Bool?
    /// 网盘返回的视频编码（hevc 等），影院播放转封装时同样需要。
    public var videoCodec: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// 蓝光原盘 / ISO 的实际盘根路径；普通视频为空。影院播放也靠它走 `bluray:`。
    public var externalPath: String?

    public init(photo: PhotoItem) {
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
        videoCodec = photo.videoCodec
        pixelWidth = photo.pixelWidth
        pixelHeight = photo.pixelHeight
        externalPath = photo.externalPath
    }

    public var isCloud: Bool { cloudMountID != nil }

    /// 文件名 / 分辨率里的画质与音质标记。按辨识度排序，用于角标、筛选与详情。
    /// 有就全列出来：4K / DV / HDR10+ / 10bit / Atmos / DTS-HD / 60fps。
    public var displayTags: [String] {
        let text = filename.lowercased()
        var tags: [String] = []

        // 画质分辨率
        if pixelWidth >= 3000 {
            tags.append("4K")
        } else if pixelWidth >= 1800 {
            tags.append("2K")
        } else if pixelWidth >= 1200 {
            tags.append("1080P")
        }

        // 动态范围
        if text.range(of: #"(?i)(^|[^a-z0-9])(dv|dovi|dolby[ .]?vision)([^a-z0-9]|$)"#,
                      options: .regularExpression) != nil,
           text.range(of: #"dvd"#, options: .regularExpression) == nil {
            tags.append("DV")
        }
        if text.range(of: #"(?i)hdr10\+|hdr10plus"#, options: .regularExpression) != nil {
            tags.append("HDR10+")
        } else if text.range(of: #"(?i)(^|[^a-z0-9])hdr10([^a-z0-9]|$)"#,
                             options: .regularExpression) != nil {
            tags.append("HDR10")
        } else if text.range(of: #"(?i)(^|[^a-z0-9])(hdr|hlg)([^a-z0-9]|$)"#,
                             options: .regularExpression) != nil {
            tags.append("HDR")
        }
        if text.range(of: #"(?i)(^|[^a-z0-9])10[ .]?bit([^a-z0-9]|$)"#,
                      options: .regularExpression) != nil {
            tags.append("10bit")
        }

        // 音质
        if text.range(of: #"(?i)(^|[^a-z0-9])atmos([^a-z0-9]|$)"#,
                      options: .regularExpression) != nil {
            tags.append("Atmos")
        }
        if text.range(of: #"(?i)dts[ .:-]?x([^a-z0-9]|$)"#, options: .regularExpression) != nil {
            tags.append("DTS:X")
        } else if text.range(of: #"(?i)dts[ .:-]?hd"#, options: .regularExpression) != nil {
            tags.append("DTS-HD")
        } else if text.range(of: #"(?i)(^|[^a-z0-9])dts([^a-z0-9]|$)"#,
                             options: .regularExpression) != nil {
            tags.append("DTS")
        }
        if text.range(of: #"(?i)true[ .]?hd"#, options: .regularExpression) != nil {
            tags.append("TrueHD")
        }

        // 高帧率才值得占一个角标
        if let fps = parsedFrameRate, fps >= 48 {
            tags.append("\(fps)fps")
        }
        return tags
    }

    /// 文件名里的帧率标记（`60fps` / `120 fps`）；没有则为 nil。
    public var parsedFrameRate: Int? {
        guard let range = filename.range(of: #"(?i)\d{2,3}\s?fps"#,
                                         options: .regularExpression) else { return nil }
        let digits = filename[range].prefix { $0.isNumber }
        guard let value = Int(digits), value >= 23, value <= 240 else { return nil }
        return value
    }

    /// 还原成播放器认识的 PhotoItem；本地文件按文件名回到图库中查找。
    public var photoItem: PhotoItem {
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
        item.videoCodec = videoCodec
        item.externalPath = externalPath
        return item
    }
}

/// 一条刮削结果。未匹配到 TMDB 时也会保留，用于「未识别」列表与再次刮削。
public struct CinemaEntry: Codable, Identifiable, Hashable {
    public var file: CinemaFile
    public var kind: CinemaMediaKind
    public var matched: Bool
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var episodeEnd: Int?
    public var tmdbID: Int?
    public var posterURL: String?
    public var backdropURL: String?
    public var overview: String?
    public var rating: Double?
    /// 豆瓣评分：主源是 TMDB 时按需补一次，详情页三源评分牌用。
    public var doubanRating: Double? = nil
    /// IMDb 评分：条目带 imdb_id 并且拿得到时才有。
    public var imdbRating: Double? = nil
    public var scrapedAt: Date
    /// 刮削时使用的目录链（剧名 / 季），再次刮削时继续用它。
    public var folderHint: String?
    /// 类型标签（剧情 / 科幻 / 悬疑……）。旧版本刮削结果没有这一项，重新刮削即可补齐。
    public var genres: [String]? = nil
    /// 详情补全：所属合集、演职员、导演、分级与预告片。
    public var collectionID: Int? = nil
    public var collectionName: String? = nil
    public var cast: [CinemaCastMember]? = nil
    public var directors: [String]? = nil
    public var certification: String? = nil
    public var trailerKey: String? = nil
    /// 详情补全的基础资料：宣传语、片长、状态、上映日期、语言 / 国家 / 公司 / 平台等。
    public var tagline: String? = nil
    public var runtime: Int? = nil
    public var releaseDate: String? = nil
    public var originalLanguage: String? = nil
    public var countries: [String]? = nil
    public var companies: [String]? = nil
    public var networks: [String]? = nil
    public var seasonCount: Int? = nil
    public var episodeTotal: Int? = nil
    public var voteCount: Int? = nil
    public var budget: Int64? = nil
    public var revenue: Int64? = nil
    public var status: String? = nil
    /// 相似推荐（TMDB recommendations）：第一次打开详情时补一次，之后直接复用。
    public var recommendations: [CinemaRecommendation]? = nil
    /// 推荐分组缓存：TMDB / 豆瓣 / 同系列 / 同导演 / 同演员，详情页按 tab 切换。
    public var recommendationGroups: [CinemaRecommendationGroup]? = nil
    /// 推荐分组的抓取时间：旧缓存会按天刷新，避免豆瓣等后加的 tab 永远不出现。
    public var recommendationGroupsAt: Date? = nil
    /// 用户手动挑过海报 / 背景后置为 true，重新刮削时不再覆盖。
    public var artworkLocked: Bool? = nil
    /// 这条结果来自哪个数据源；只有 TMDB 能补详情。
    public var provider: CinemaProvider? = nil

    public var id: UUID { file.photoID }

    /// 年代（2020 年代返回 2020），筛选与分组都用它。
    public var decade: Int? { year.map { $0 / 10 * 10 } }

    public var subtitle: String {
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

    public var artworkURL: String? { posterURL ?? backdropURL }
    /// 网格单元格是横向的，优先用 backdrop，避免竖版海报被裁得只剩一条。
    public var gridArtworkURL: String? { backdropURL ?? posterURL }
    public init(
        file: CinemaFile,
        kind: CinemaMediaKind,
        matched: Bool,
        title: String,
        originalTitle: String? = nil,
        year: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodeEnd: Int? = nil,
        tmdbID: Int? = nil,
        posterURL: String? = nil,
        backdropURL: String? = nil,
        overview: String? = nil,
        rating: Double? = nil,
        doubanRating: Double? = nil,
        imdbRating: Double? = nil,
        scrapedAt: Date,
        folderHint: String? = nil,
        genres: [String]? = nil,
        collectionID: Int? = nil,
        collectionName: String? = nil,
        cast: [CinemaCastMember]? = nil,
        directors: [String]? = nil,
        certification: String? = nil,
        trailerKey: String? = nil,
        tagline: String? = nil,
        runtime: Int? = nil,
        releaseDate: String? = nil,
        originalLanguage: String? = nil,
        countries: [String]? = nil,
        companies: [String]? = nil,
        networks: [String]? = nil,
        seasonCount: Int? = nil,
        episodeTotal: Int? = nil,
        voteCount: Int? = nil,
        budget: Int64? = nil,
        revenue: Int64? = nil,
        status: String? = nil,
        recommendations: [CinemaRecommendation]? = nil,
        recommendationGroups: [CinemaRecommendationGroup]? = nil,
        recommendationGroupsAt: Date? = nil,
        artworkLocked: Bool? = nil,
        provider: CinemaProvider? = nil
    ) {
        self.file = file
        self.kind = kind
        self.matched = matched
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.season = season
        self.episode = episode
        self.episodeEnd = episodeEnd
        self.tmdbID = tmdbID
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.overview = overview
        self.rating = rating
        self.doubanRating = doubanRating
        self.imdbRating = imdbRating
        self.scrapedAt = scrapedAt
        self.folderHint = folderHint
        self.genres = genres
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.cast = cast
        self.directors = directors
        self.certification = certification
        self.trailerKey = trailerKey
        self.tagline = tagline
        self.runtime = runtime
        self.releaseDate = releaseDate
        self.originalLanguage = originalLanguage
        self.countries = countries
        self.companies = companies
        self.networks = networks
        self.seasonCount = seasonCount
        self.episodeTotal = episodeTotal
        self.voteCount = voteCount
        self.budget = budget
        self.revenue = revenue
        self.status = status
        self.recommendations = recommendations
        self.recommendationGroups = recommendationGroups
        self.recommendationGroupsAt = recommendationGroupsAt
        self.artworkLocked = artworkLocked
        self.provider = provider
    }
}

/// 详情页返回记忆：上次查看的季与选中集。
public struct CinemaSeriesMemory {
    public var season: Int?
    public var episodeID: UUID?
    public init(
        season: Int? = nil,
        episodeID: UUID? = nil
    ) {
        self.season = season
        self.episodeID = episodeID
    }
}

/// 影院本地续播记录：只保存播放位置与展示快照，不依赖刮削索引是否仍然存在。
public struct CinemaProgressRecord: Codable, Hashable, Identifiable {
    public var photoID: UUID
    public var mountID: UUID?
    public var title: String
    public var subtitle: String?
    public var artworkURL: String?
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public var id: UUID { photoID }

    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// 接近结尾就视为看完，不再出现在「继续观看」里，但仍保留在观看记录中。
    public var isFinished: Bool { duration > 0 && fraction >= 0.95 }

    public var remainingSeconds: Double { max(0, duration - position) }

    /// 记录是否可信：旧版本起流点换算错误会把整条时间轴放大 1000 倍，
    /// 这类记录的时长远超片源真实时长，既不能拿来续播，也不该出现在「继续观看」里。
    public func isTrustworthy(realDuration: Double?) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0, position >= 0 else { return false }
        if let realDuration, realDuration > 0 {
            return duration <= realDuration * 1.5 + 60
        }
        // 拿不到片源时长时按上限兜底：正常影视不会超过 24 小时。
        return duration <= 24 * 3600
    }
    public init(
        photoID: UUID,
        mountID: UUID? = nil,
        title: String,
        subtitle: String? = nil,
        artworkURL: String? = nil,
        position: Double,
        duration: Double,
        updatedAt: Date
    ) {
        self.photoID = photoID
        self.mountID = mountID
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

/// 影院本地用户状态：收藏 / 想看 / 个人评分。按视频 photoID 存。
public struct CinemaUserState: Codable, Hashable {
    public var photoID: UUID
    public var favorite: Bool = false
    public var watchlist: Bool = false
    /// 0–5；nil 表示未评分。
    public var rating: Int?
    public var updatedAt: Date = Date()
    public init(
        photoID: UUID,
        favorite: Bool = false,
        watchlist: Bool = false,
        rating: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.photoID = photoID
        self.favorite = favorite
        self.watchlist = watchlist
        self.rating = rating
        self.updatedAt = updatedAt
    }
}

/// 自定义清单：手动选片，只存 photoID 引用，不复制元数据。
public struct CinemaListRecord: Codable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    public var icon: String = "list.bullet"
    public var itemIDs: [UUID] = []
    public var createdAt: Date = Date()

    public var count: Int { itemIDs.count }
    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "list.bullet",
        itemIDs: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.itemIDs = itemIDs
        self.createdAt = createdAt
    }
}

/// 同一部剧的多集聚合成一张卡片：影院里按「剧」浏览，而不是一集一张。
public struct CinemaSeries: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var year: Int?
    public var overview: String?
    public var rating: Double?
    public var posterURL: String?
    public var backdropURL: String?
    public var episodes: [CinemaEntry]

    public var episodeCount: Int { episodes.count }

    /// 聚合里的分集是否已经识别；未识别的剧同样聚合成一张卡。
    public var isMatched: Bool { episodes.first?.matched ?? false }

    public var latestEpisode: CinemaEntry? {
        episodes.max { lhs, rhs in
            (lhs.season ?? 0, lhs.episode ?? 0) < (rhs.season ?? 0, rhs.episode ?? 0)
        }
    }

    public var artworkURL: String? { posterURL ?? backdropURL }
    public var gridArtworkURL: String? { backdropURL ?? posterURL }

    /// 类型标签取自分集（同一部剧各集一致），旧刮削结果可能为空。
    public var genres: [String] {
        episodes.lazy.compactMap { $0.genres }.first(where: { !$0.isEmpty }) ?? []
    }

    public var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        parts.append("\(episodeCount) 集")
        if let latest = latestEpisode, let season = latest.season, let episode = latest.episode {
            parts.append(String(format: "最新 S%02dE%02d", season, episode))
        }
        return parts.joined(separator: " · ")
    }
    public init(
        id: String,
        title: String,
        year: Int? = nil,
        overview: String? = nil,
        rating: Double? = nil,
        posterURL: String? = nil,
        backdropURL: String? = nil,
        episodes: [CinemaEntry]
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.overview = overview
        self.rating = rating
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.episodes = episodes
    }
}

// MARK: - 配置检测

/// 「测试连接」的一次结果，只在设置面板里展示。
public struct CinemaConnectionResult: Equatable {
    public var ok: Bool
    public var message: String
    public init(
        ok: Bool,
        message: String
    ) {
        self.ok = ok
        self.message = message
    }
}

/// 单条刮削结果：`entry` 为空代表网络 / 接口出错，`error` 为空代表正常（含未匹配）。
public struct CinemaScrapeOutcome {
    public var entry: CinemaEntry?
    public var error: String?
    /// 本轮每个数据源各自的错误：批量刮削据此只降级出错的源，不整批停。
    public var failedProviders: [CinemaProvider: String] = [:]
    public init(
        entry: CinemaEntry? = nil,
        error: String? = nil,
        failedProviders: [CinemaProvider: String] = [:]
    ) {
        self.entry = entry
        self.error = error
        self.failedProviders = failedProviders
    }
}
