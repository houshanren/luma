import Foundation

/// 网络影院的分页：影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注。
/// 与「网络存储」里的影院完全独立：这里只聚合网络影视源（苹果CMS 等）的条目。
/// 版式对齐「网络资源」与「网络存储」：管理、发现、浏览、回看各占一页，切换入口在窗口工具栏。
public enum NetworkCinemaTab: String, CaseIterable, Identifiable {
    case manage
    case ranking
    case movies
    case shows
    case calendar
    case history
    case following

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manage: return "影院管理"
        case .ranking: return "榜单"
        case .movies: return "电影"
        case .shows: return "电视剧"
        case .calendar: return "日历"
        case .history: return "足迹"
        case .following: return "关注"
        }
    }

    public var symbol: String {
        switch self {
        case .manage: return "slider.horizontal.3"
        case .ranking: return "chart.bar.fill"
        case .movies: return "film.fill"
        case .shows: return "tv.fill"
        case .calendar: return "calendar"
        case .history: return "clock.arrow.circlepath"
        case .following: return "star.circle.fill"
        }
    }

    /// 只有电影 / 电视剧会去影视源拉列表；管理、榜单、日历、足迹、关注都读本机聚合数据。
    public var browsesContent: Bool {
        self == .movies || self == .shows
    }

    /// 分页记忆：重开应用后仍停在上一页。
    public static let storageKey = "networkCinema.tab.v1"

    public static var persisted: NetworkCinemaTab {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let tab = NetworkCinemaTab(rawValue: raw) else { return .movies }
        return tab
    }
}

/// 聚合后的一个条目：保留所属源，点击时直接走该源的详情与播放。
/// Codable 用于列表快照：重新进入网络影院时先用上次内容铺满。
public struct NetworkCinemaItem: Identifiable, Hashable, Codable {
    public var source: CatalogSource
    public var item: CatalogItem
    /// 用来决定 TMDB 按电影还是电视剧检索，以及卡片上的类型标记。
    public var isTV: Bool

    public var id: String { "\(source.id.uuidString)|\(item.id)" }

    public var enrichmentKey: String {
        NetworkCinemaEnrichment.key(title: item.title, isTV: isTV)
    }
    public init(
        source: CatalogSource,
        item: CatalogItem,
        isTV: Bool
    ) {
        self.source = source
        self.item = item
        self.isTV = isTV
    }
}

/// TMDB 补全的元数据：海报、评分、简介、年份与类型。
public struct NetworkCinemaEnrichment: Codable, Hashable {
    public var tmdbID: Int
    public var isTV: Bool
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var posterURL: String?
    public var backdropURL: String?
    public var overview: String?
    public var rating: Double?
    public var voteCount: Int?
    public var genres: [String] = []

    /// 缓存键：标题归一化 + 电影/剧集，避免同名电影与剧集互相覆盖。
    public static func key(title: String, isTV: Bool) -> String {
        normalized(cleanedTitle(title)) + "|" + (isTV ? "tv" : "movie")
    }

    /// 只保留字母与数字：中文标题里的空格、标点、副标题符号都不参与比较。
    public static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 去掉年份、括号说明与常见清晰度 / 语言后缀，提升 TMDB 命中率。
    public static func cleanedTitle(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"[\(\[【（][^\)\]】）]*[\)\]】）]"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(19|20)\d{2}"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "国语|粤语|中字|双字|高清|蓝光|完整版|未删减|HD|4K",
                                         with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从标题里认出年份（常见写法「沙丘2 (2024)」），没有就返回 nil。
    public static func year(in raw: String) -> Int? {
        guard let range = raw.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return Int(raw[range])
    }
    public init(
        tmdbID: Int,
        isTV: Bool,
        title: String,
        originalTitle: String? = nil,
        year: Int? = nil,
        posterURL: String? = nil,
        backdropURL: String? = nil,
        overview: String? = nil,
        rating: Double? = nil,
        voteCount: Int? = nil,
        genres: [String] = []
    ) {
        self.tmdbID = tmdbID
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
    }
}
