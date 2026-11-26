import Foundation

// MARK: - 网络资源（影视源）
//
// 与 `CloudMount` 并列的一类「网络资源」：它没有文件树、没有 OAuth、没有全盘扫描，
// 只有分类、条目、分集与播放页。所有字段都以站点原始字符串为准，便于回溯与改版排查。

package enum CatalogProviderKind: String, Codable, Hashable {
    case huangguo
    case ninetyOne
    case ninetyOnePorna
    case xszAV
    case missav
    case avple
    case shise
    case avgle
    case rouVideo
    case quanji
    case javcl
    case madou
    case javgg
    /// 苹果CMS（MacCMS V10）通用 JSON 接口：国内大量影视站共用同一套协议。
    case maccms
    /// FoFo 影院：自建 PHP 模板站，列表是 HTML，播放地址由 `/source/` 按 sid 换取。
    case fofo
    /// 爱看片片：Next.js 站点，数据在 RSC 负载里，播放走站内的 `/api/lines`。
    case ikanpp
    /// 爱壹帆：Angular 站点，页面内联数据 + 带签名的 JSON 接口。
    case iyf

    package var title: String {
        switch self {
        case .huangguo: return "黄果短剧（FongMi 源）"
        case .ninetyOne: return "91吃瓜（网页源）"
        case .ninetyOnePorna: return "91porna（网页源）"
        case .xszAV: return "XSZAV（网页源）"
        case .missav: return "MissAV（网页源）"
        case .avple: return "Avple（网页源）"
        case .shise: return "视色（网页源）"
        case .avgle: return "Avgle（网页源）"
        case .rouVideo: return "肉视频（网页源）"
        case .quanji: return "91全集（网页源）"
        case .javcl: return "JavCl（网页源）"
        case .madou: return "麻豆社（国产原创）"
        case .javgg: return "JavGG（网页源）"
        case .maccms: return "苹果CMS 影视源"
        case .fofo: return "FoFo 影院"
        case .ikanpp: return "爱看片片"
        case .iyf: return "爱壹帆"
        }
    }

    /// 会聚合进「网络影院」的通用影视源：成人向站点不在此列。
    package var supportsNetworkCinema: Bool {
        switch self {
        case .maccms, .fofo, .ikanpp, .iyf: return true
        default: return false
        }
    }

    /// 目录类来源分两个互不相通的域：网页资源站只进「网络资源」，
    /// 影视源只进「网络影院」。所有聚合、检索、收藏与统计都必须先按域筛。
    package var domain: CatalogDomain {
        supportsNetworkCinema ? .networkCinema : .networkResource
    }

    /// 网页形式的源：卡片是 16:9 横图，默认按 4 列展示。
    /// 以后新增的网页源默认也走这套版式。
    package var isWebSite: Bool {
        if case .huangguo = self { return false }
        // 苹果CMS 是海报型影视站：2:3 竖图，走海报列数。
        if case .maccms = self { return false }
        // FoFo / 爱看片片同样是海报型影视站。
        if case .fofo = self { return false }
        if case .ikanpp = self { return false }
        if case .iyf = self { return false }
        return true
    }
}

/// 站点的产品归属：两个域各自维护源清单、聚合结果与检索，互不混用。
package enum CatalogDomain: String, CaseIterable, Hashable {
    /// 网络资源：网页资源站。
    case networkResource
    /// 网络影院：苹果CMS / FoFo / 爱看片片 / 爱壹帆等影视源。
    case networkCinema

    package var title: String {
        switch self {
        case .networkResource: return "网络资源"
        case .networkCinema: return "网络影院"
        }
    }

    package var symbolName: String {
        switch self {
        case .networkResource: return "play.rectangle.on.rectangle"
        case .networkCinema: return "film.stack"
        }
    }
}

/// 分类页的排序子视图。站点 JSON API 只接受 latest / hot / new / collect。
package enum CatalogSort: String, CaseIterable, Identifiable, Codable, Hashable {
    case latest
    case hot
    case newest
    case collect

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .latest: return "最新更新"
        case .hot: return "当前热播"
        case .newest: return "最新上架"
        case .collect: return "最多收藏"
        }
    }

    /// 排序图标：与网络影院站点页的排序菜单保持同一套符号。
    package var symbol: String {
        switch self {
        case .latest: return "clock.arrow.circlepath"
        case .hot: return "flame.fill"
        case .newest: return "sparkles"
        case .collect: return "bookmark.fill"
        }
    }

    /// 直接用于 JSON API 的 sort 参数。
    package var pathSuffix: String {
        switch self {
        case .latest: return "latest"
        case .hot: return "hot"
        case .newest: return "new"
        case .collect: return "collect"
        }
    }
}

package struct CatalogCategory: Identifiable, Codable, Hashable {
    /// 站点页面路径，去掉首尾斜杠。例如 `ai-duanju`、`original/manju`、`ranks/hot`。
    package var id: String
    package var title: String
    package var isRank: Bool = false
    /// 二级分类（频道页里的 tab，如「全部原创 / 原创漫剧 / 原创短剧」）。
    package var children: [CatalogCategory]? = nil
    /// 只有分组节点才为 true：这种节点自身没有页面，点它等于打开第一个子分类。
    /// 用可选值是为了让已保存的源（没有这个键）仍能正常解码。
    package var isGroup: Bool? = nil

    /// 用来拼接站点地址的分段，例如 `original/manju`。
    package var path: String { id }

    package var isGroupCategory: Bool { isGroup == true }
    package init(
        id: String,
        title: String,
        isRank: Bool = false,
        children: [CatalogCategory]? = nil,
        isGroup: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.isRank = isRank
        self.children = children
        self.isGroup = isGroup
    }
}

package struct CatalogSource: Identifiable, Codable, Hashable {
    package var id: UUID = UUID()
    package var name: String
    package var kind: CatalogProviderKind = .huangguo
    /// 站点根地址，例如 https://huangguoai.com
    package var baseURL: String
    /// 导入时使用的配置地址，仅作记录，便于重新拉取。
    package var configURL: String?
    /// 苹果CMS 的 JSON 接口地址（例如 `https://example.com/api.php/provide/vod/`）。
    /// 其它源为 nil；站点根地址仍放在 `baseURL`，封面与 Referer 用它。
    package var apiBase: String? = nil
    package var userAgent: String
    package var referer: String
    /// 封面解密参数，随源配置保存；导入时从脚本读取，可在编辑中覆盖。
    package var artworkKey: String?
    package var artworkIV: String?
    /// 站点证书不受系统信任时，用户可对这一条源显式放行（仅影响该源）。
    package var allowsInsecureTLS: Bool? = nil
    /// 分类骨架：侧边栏直接渲染，不必等网络。
    package var categories: [CatalogCategory]
    /// 卡片海报的宽高比；缺省 2:3。网页源的封面常是横图（约 2:1），避免竖着裁掉大半。
    package var posterAspect: Double? = nil
    /// 默认关闭：资源内容由第三方站点提供，需要用户显式启用。
    package var isEnabled: Bool = false
    package var createdAt: Date = Date()

    package var host: String {
        (URLComponents(string: baseURL)?.host ?? baseURL).lowercased()
    }

    /// 这条源属于「网络资源」还是「网络影院」：所有跨源聚合先按它分流。
    package var domain: CatalogDomain { kind.domain }

    /// 卡片海报的宽高比：优先用源里保存的值；旧版已导入的网页源没有这个字段，
    /// 按来源给一个合理默认，避免竖着裁掉大半横图。
    package var posterRatio: Double {
        if let posterAspect, posterAspect > 0 { return posterAspect }
        switch kind {
        case .ninetyOne: return 1.95
        case .ninetyOnePorna: return 16.0 / 9.0
        case .xszAV, .missav, .avple, .shise, .avgle, .rouVideo, .quanji: return 16.0 / 9.0
        default: return 2.0 / 3.0
        }
    }

    package var trustsInsecureCertificate: Bool { allowsInsecureTLS == true }
    package init(
        id: UUID = UUID(),
        name: String,
        kind: CatalogProviderKind = .huangguo,
        baseURL: String,
        configURL: String? = nil,
        apiBase: String? = nil,
        userAgent: String,
        referer: String,
        artworkKey: String? = nil,
        artworkIV: String? = nil,
        allowsInsecureTLS: Bool? = nil,
        categories: [CatalogCategory],
        posterAspect: Double? = nil,
        isEnabled: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.configURL = configURL
        self.apiBase = apiBase
        self.userAgent = userAgent
        self.referer = referer
        self.artworkKey = artworkKey
        self.artworkIV = artworkIV
        self.allowsInsecureTLS = allowsInsecureTLS
        self.categories = categories
        self.posterAspect = posterAspect
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

/// 当前正在浏览的范围。
package enum CatalogSection: Hashable {
    case home
    case category(String)
    case rank
    case search(String)
    case continueWatching
    case favorites
}

/// 本地「稍后看」：只记录条目快照，不写远端、不进图库索引。
package struct CatalogFavorite: Codable, Identifiable, Hashable {
    package var sourceID: UUID
    package var itemID: String
    package var title: String
    package var coverURL: String
    package var remark: String
    package var addedAt: Date

    package var id: String { "\(sourceID.uuidString)|\(itemID)" }
    package init(
        sourceID: UUID,
        itemID: String,
        title: String,
        coverURL: String,
        remark: String,
        addedAt: Date
    ) {
        self.sourceID = sourceID
        self.itemID = itemID
        self.title = title
        self.coverURL = coverURL
        self.remark = remark
        self.addedAt = addedAt
    }
}

package struct CatalogItem: Identifiable, Hashable, Codable {
    package var id: String
    package var title: String
    package var coverURL: String
    /// 「更新至 7 集 · 8.1 分」原样保留，站点改版时不影响结构。
    package var remark: String
    package var categoryID: String?
    /// 站点给的上架 / 更新日期：日历按它落位；站点没给时留空。
    package var publishedAt: Date? = nil

    package var episodeBadge: String? {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    package init(
        id: String,
        title: String,
        coverURL: String,
        remark: String,
        categoryID: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.remark = remark
        self.categoryID = categoryID
        self.publishedAt = publishedAt
    }
}

package struct CatalogPage {
    package var items: [CatalogItem]
    package var page: Int
    /// 以「本页非空」为准：站点返回的 pagecount 只是占位值。
    package var hasMore: Bool
    package init(
        items: [CatalogItem],
        page: Int,
        hasMore: Bool
    ) {
        self.items = items
        self.page = page
        self.hasMore = hasMore
    }
}

package struct CatalogEpisode: Identifiable, Hashable {
    package var index: Int
    /// 分集播放页地址，不是 m3u8。
    package var pageURL: String
    /// 单集封面；站点没有时由详情页回退到条目封面。
    package var coverURL: String = ""
    /// 合集里的视频标题；普通剧集为空，仍显示「第 N 集」。
    package var name: String? = nil
    /// 合集的时长或其它副信息。
    package var duration: String? = nil

    package var id: Int { index }
    package var title: String { name ?? "第 \(index) 集" }
    package init(
        index: Int,
        pageURL: String,
        coverURL: String = "",
        name: String? = nil,
        duration: String? = nil
    ) {
        self.index = index
        self.pageURL = pageURL
        self.coverURL = coverURL
        self.name = name
        self.duration = duration
    }
}

/// 图文正文的一个块：保留站点原始顺序，标题 / 段落 / 配图交错排版。
package struct CatalogContentBlock: Hashable {
    package enum Kind: Hashable {
        case heading
        case paragraph
        case image
    }

    package var kind: Kind
    package var text: String
    package init(
        kind: Kind,
        text: String
    ) {
        self.kind = kind
        self.text = text
    }
}

/// 详情页的结构化信息：上线日期、出品方、播放量……由各源按自身返回字段填充。
package struct CatalogDetailFact: Identifiable, Hashable {
    package var label: String
    package var value: String

    package var id: String { "\(label)|\(value)" }
    package init(
        label: String,
        value: String
    ) {
        self.label = label
        self.value = value
    }
}

package struct CatalogDetail {
    package var item: CatalogItem
    package var episodes: [CatalogEpisode]
    /// 图文条目的正文（视频条目通常为空）。
    package var blocks: [CatalogContentBlock] = []
    /// 结构化信息，详情页用网格展示；没有的源留空。
    package var facts: [CatalogDetailFact] = []
    /// 合集（一组互不相关的视频）而不是连续剧集：详情页按视频卡片展示，不写「第 N 集」。
    package var isCollection: Bool = false
    /// 合集在站点上的总数量；只加载了部分页时用来提示。
    package var collectionTotal: Int? = nil

    /// 正文里的全部配图，供大图预览左右翻页。
    package var articleImages: [String] {
        blocks.compactMap { $0.kind == .image ? $0.text : nil }
    }

    package var hasArticle: Bool { !blocks.isEmpty }
    package init(
        item: CatalogItem,
        episodes: [CatalogEpisode],
        blocks: [CatalogContentBlock] = [],
        facts: [CatalogDetailFact] = [],
        isCollection: Bool = false,
        collectionTotal: Int? = nil
    ) {
        self.item = item
        self.episodes = episodes
        self.blocks = blocks
        self.facts = facts
        self.isCollection = isCollection
        self.collectionTotal = collectionTotal
    }
}

package struct CatalogStream {
    package var url: URL
    package var headers: [String: String]
    package var isHLS: Bool = true
    package init(
        url: URL,
        headers: [String: String],
        isHLS: Bool = true
    ) {
        self.url = url
        self.headers = headers
        self.isHLS = isHLS
    }
}

/// 本地续看记录：只存条目与集号，播放地址短时效，不落盘。
package struct CatalogProgress: Codable, Hashable {
    package var sourceID: UUID
    package var itemID: String
    package var episode: Int
    package var seconds: Double
    package var duration: Double
    package var title: String
    package var coverURL: String
    package var updatedAt: Date

    package var key: String { CatalogProgress.key(sourceID: sourceID, itemID: itemID) }

    package static func key(sourceID: UUID, itemID: String) -> String {
        "\(sourceID.uuidString)|\(itemID)"
    }

    package var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }
    package init(
        sourceID: UUID,
        itemID: String,
        episode: Int,
        seconds: Double,
        duration: Double,
        title: String,
        coverURL: String,
        updatedAt: Date
    ) {
        self.sourceID = sourceID
        self.itemID = itemID
        self.episode = episode
        self.seconds = seconds
        self.duration = duration
        self.title = title
        self.coverURL = coverURL
        self.updatedAt = updatedAt
    }
}

/// 一次播放请求：播放器需要条目、完整分集与起播集号。
package struct CatalogPlaybackRequest: Identifiable {
    package let id = UUID()
    package var source: CatalogSource
    package var item: CatalogItem
    package var episodes: [CatalogEpisode]
    package var startEpisode: Int
    package var startSeconds: Double
    package var initialStream: CatalogStream?

    package var startIndex: Int {
        episodes.firstIndex(where: { $0.index == startEpisode }) ?? 0
    }
    package init(
        source: CatalogSource,
        item: CatalogItem,
        episodes: [CatalogEpisode],
        startEpisode: Int,
        startSeconds: Double,
        initialStream: CatalogStream? = nil
    ) {
        self.source = source
        self.item = item
        self.episodes = episodes
        self.startEpisode = startEpisode
        self.startSeconds = startSeconds
        self.initialStream = initialStream
    }
}

/// 查看器里一个虚拟分集：把网络资源的每一集映射成一条可翻页的视频。
package struct CatalogPlaybackContext {
    package var source: CatalogSource
    package var item: CatalogItem
    package var episode: CatalogEpisode
    package init(
        source: CatalogSource,
        item: CatalogItem,
        episode: CatalogEpisode
    ) {
        self.source = source
        self.item = item
        self.episode = episode
    }
}

package enum CatalogError: LocalizedError {
    case unsupportedProvider
    case invalidConfig(String)
    case http(Int)
    case parse(String)
    case decryption
    case tls(String)
    case unavailable(String?)

    package var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "该源类型还没有对应的解析器"
        case .invalidConfig(let message):
            return "源配置无法识别：\(message)"
        case .http(let status):
            return "站点返回 HTTP \(status)"
        case .parse(let message):
            return "页面结构解析失败：\(message)"
        case .decryption:
            return "封面解密失败，源可能需要更新"
        case .tls(let host):
            return "与 \(host) 的 HTTPS 证书校验失败（可能是自签名、已过期或域名不匹配）。"
                + "确认站点可信后，可在导入页开启「允许不受信任的证书」再试。"
        case .unavailable(let detail):
            return detail ?? "资源暂时不可用"
        }
    }
}
