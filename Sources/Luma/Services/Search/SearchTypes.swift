import Foundation

/// 统一搜索的来源：图库 / 网盘 / 影院 / 网络影院 / 电视 / 资源 / 星图。
/// 独立成模块后，页面只声明自己需要哪些来源，组件就只检索、只展示这些来源。
enum SearchSourceKind: String, CaseIterable, Identifiable, Hashable {
    case library
    case cloud
    case cinema
    /// 网络影院：网络影视源（苹果CMS / FoFo / 爱看片片 / 爱壹帆）聚合出的条目。
    case networkCinema
    case television
    case catalog
    /// 拾光星图：内置资料库里的人物与作品。
    case atlas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "图库"
        case .cloud: return "网盘"
        case .cinema: return "影院"
        case .networkCinema: return "网络影院"
        case .television: return "电视"
        case .catalog: return "资源"
        case .atlas: return "星图"
        }
    }

    var icon: String {
        switch self {
        case .library: return "photo.on.rectangle.angled"
        case .cloud: return "externaldrive.connected.to.line.below"
        case .cinema: return "film.stack"
        case .networkCinema: return "play.tv.fill"
        case .television: return "tv"
        case .catalog: return "safari"
        case .atlas: return "sparkles"
        }
    }
}

/// 命中的内容类型：用于「按类型」筛选，也决定行内图标与徽标。
enum SearchHitKind: String, Hashable {
    case photo
    case video
    case album
    case folder
    case person
    case scene
    case place
    case cloudPhoto
    case cloudVideo
    case cloudFile
    case cloudFolder
    case movie
    case series
    case channel
    /// 节目单里的一档节目：点开按直播 / 回看处理。
    case program
    /// 网络资源里的图集条目（写真 / 套图站）：打开是整套图片，不是视频。
    case catalogGallery
    /// 网络资源里的视频条目：打开直接起播。
    case catalogVideo
    /// 星图里的人物 / 作品。
    case atlasPerson
    case atlasWork

    var title: String {
        switch self {
        case .photo: return "图片"
        case .video: return "视频"
        case .album: return "相簿"
        case .folder: return "文件夹"
        case .person: return "人物"
        case .scene: return "场景"
        case .place: return "位置"
        case .cloudPhoto: return "图片"
        case .cloudVideo: return "视频"
        case .cloudFile: return "文件"
        case .cloudFolder: return "文件夹"
        case .movie: return "电影"
        case .series: return "电视剧"
        case .channel: return "直播"
        case .program: return "节目"
        case .catalogGallery: return "图集"
        case .catalogVideo: return "视频"
        case .atlasPerson: return "人物"
        case .atlasWork: return "作品"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .album: return "rectangle.stack"
        case .folder, .cloudFolder: return "folder"
        case .person: return "person"
        case .scene: return "sparkles"
        case .place: return "mappin.and.ellipse"
        case .cloudPhoto: return "photo"
        case .cloudVideo: return "video"
        case .cloudFile: return "doc"
        case .movie: return "film"
        case .series: return "tv"
        case .channel: return "antenna.radiowaves.left.and.right"
        case .program: return "list.bullet.rectangle"
        case .catalogGallery: return "photo.stack.fill"
        case .catalogVideo: return "play.rectangle.fill"
        case .atlasPerson: return "person.crop.circle"
        case .atlasWork: return "film"
        }
    }
}

/// 行首视觉：只描述「画什么」，具体视图由组件按类型渲染。
enum SearchVisual {
    case photo(PhotoItem)
    case albumCover(PhotoItem?, AlbumPlaceholderStyle)
    case avatar(Data?, isPet: Bool)
    case place
    case scene
    case cloudFile(isVideo: Bool)
    case cloudFolder
    case cinemaPoster(String?, CinemaMediaKind)
    case channelLogo(String?)
    case catalogCover(sourceID: UUID, url: String)
    /// 星图：内置资料库的人物头像 / 作品封面。
    case atlasPerson(id: Int64, name: String)
    case atlasCover(url: String?)
}

/// 点击后的动作数据：不携带闭包，保证可测试、可跨页面复用。
enum SearchPayload {
    case photo(UUID)
    case localAlbum(UUID)
    case localFolder(UUID)
    case systemAlbum(Int64)
    case systemFolder(Int64)
    case localPerson(UUID)
    case systemPerson(SystemPersonInfo)
    case place(PlaceCluster)
    case scene(String)
    case cloudFile(mountID: UUID, folderPath: String?, path: String)
    case cloudFolder(mountID: UUID, path: String)
    case cinema(scopeKey: String, queueTitle: String, entry: CinemaEntry)
    case channel(TVChannel)
    /// 节目单里的节目：正在播直接看直播，已播且支持回看就回看，其它情况落到当天节目单。
    case program(channel: TVChannel, program: TVEPGProgram)
    case catalogItem(sourceID: UUID, item: CatalogItem)
    /// 网络影院条目：点击后进入网络影院并停在这部作品的详情页。
    case networkCinemaItem(sourceID: UUID, item: CatalogItem, isTV: Bool)
    /// 星图：跳到人物档案 / 打开作品详情。
    case atlasPerson(Int64)
    case atlasWork(Int64)
}

/// 一条统一命中。
struct SearchHit: Identifiable {
    let id: String
    let source: SearchSourceKind
    let kind: SearchHitKind
    let title: String
    let subtitle: String
    let badge: String?
    let visual: SearchVisual
    let payload: SearchPayload
    /// 命中所属的「源」：网盘名称、影院范围、电视频道所属播放列表、网络资源站点、图库名称。
    var origin: String? = nil
    /// 源下面的分类：电视频道分组、资源分类等。
    var category: String? = nil
    /// 命中来自哪个图库（跨图库搜索）：nil = 当前图库。
    var libraryPath: String? = nil
    /// 是否来自「其它图库」：图库结果区据此决定继续用照片墙还是改成结果行。
    var isOtherLibrary: Bool = false
}

/// 一个来源的检索结果。
struct SearchSection: Identifiable {
    let source: SearchSourceKind
    var hits: [SearchHit]
    var total: Int
    /// 各内容类型的命中总数（不受 hits 截断影响）。
    var kindCounts: [SearchHitKind: Int]

    var id: String { source.rawValue }

    var orderedKinds: [SearchHitKind] {
        let order: [SearchHitKind] = [.photo, .video, .album, .folder, .person, .scene, .place,
                                      .cloudPhoto, .cloudVideo, .cloudFile, .cloudFolder,
                                      .movie, .series, .channel, .program,
                                      .catalogGallery, .catalogVideo,
                                      .atlasPerson, .atlasWork]
        return order.filter { (kindCounts[$0] ?? 0) > 0 }
    }

    /// 本轮命中涉及的「源」（去重，按命中数排序）；用于结果页的源筛选条。
    var origins: [(title: String, count: Int)] {
        origins(under: nil)
    }

    /// 指定类型下的来源分布：切换「图集 / 视频」时，来源条只保留该类型真正有命中的站点。
    func origins(under kind: SearchHitKind?) -> [(title: String, count: Int)] {
        var counts: [String: Int] = [:]
        for hit in hits {
            if let kind, hit.kind != kind { continue }
            guard let origin = hit.origin, !origin.isEmpty else { continue }
            counts[origin, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (title: $0.key, count: $0.value) }
    }

    /// 指定来源下的类型分布：选中某个站点后，类型条只显示该站点的分布。
    func kindCounts(under origin: String?) -> [SearchHitKind: Int] {
        guard let origin else { return kindCounts }
        var counts: [SearchHitKind: Int] = [:]
        for hit in hits where hit.origin == origin {
            counts[hit.kind, default: 0] += 1
        }
        return counts
    }

    /// 按固定顺序列出某来源下有命中的类型。
    func kinds(under origin: String?) -> [SearchHitKind] {
        guard origin != nil else { return orderedKinds }
        let counts = kindCounts(under: origin)
        return orderedKinds.filter { (counts[$0] ?? 0) > 0 }
    }

    /// 指定源下面的分类（去重，按命中数排序）；未指定源时统计全部。
    func categories(under origin: String?) -> [(title: String, count: Int)] {
        var counts: [String: Int] = [:]
        for hit in hits {
            if let origin, hit.origin != origin { continue }
            guard let category = hit.category, !category.isEmpty else { continue }
            counts[category, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (title: $0.key, count: $0.value) }
    }
}

/// 来源检索器：每个来源一个实现，SearchCenter 并发调度。
@MainActor
protocol SearchProviding: AnyObject {
    var source: SearchSourceKind { get }
    func search(query: String, limit: Int) async -> SearchSection
    /// 增量检索：这一来源内部每完成一部分就回调一次，供结果页逐步上屏。
    /// 默认实现等价于「全部跑完回调一次」，只有内部可拆分的来源（如网络资源的多站点）才需要覆写。
    func search(query: String,
                limit: Int,
                onPartial: @escaping @MainActor (SearchSection) -> Void) async -> SearchSection
}

extension SearchProviding {
    func search(query: String,
                limit: Int,
                onPartial: @escaping @MainActor (SearchSection) -> Void) async -> SearchSection {
        let section = await search(query: query, limit: limit)
        onPartial(section)
        return section
    }
}

/// 统一搜索的轻量模糊匹配。
///
/// 去掉空白与标点、忽略大小写 / 全半角后，**任一方向包含**即命中：
/// 搜「海上海」也能命中「上海」这个地点或相簿，不必逐字完全相同。
enum SearchFuzzyText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    /// 词条与关键词是否模糊命中。
    static func matches(_ value: String?, keyword: String) -> Bool {
        guard let value else { return false }
        let text = normalize(value)
        let query = normalize(keyword)
        guard !query.isEmpty, !text.isEmpty else { return false }
        if text.contains(query) { return true }
        // 反方向包含只对至少 2 个字的条名生效，避免单字名称命中所有关键词。
        return text.count >= 2 && query.contains(text)
    }

    static func matchesAny(_ values: [String?], keyword: String) -> Bool {
        values.contains { matches($0, keyword: keyword) }
    }

    /// 两条文本的相似度（0…1）：归一化后的字符二元组 Dice 系数。
    /// 对中文与英文都稳定，用于相册名 / 文件夹名这类短文本的查重。
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = bigrams(normalize(a))
        let right = bigrams(normalize(b))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var pool = right
        var intersection = 0
        for gram in left {
            if let index = pool.firstIndex(of: gram) {
                pool.remove(at: index)
                intersection += 1
            }
        }
        return 2 * Double(intersection) / Double(left.count + right.count)
    }

    static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count > 1 else { return text.isEmpty ? [] : [text] }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }
}
