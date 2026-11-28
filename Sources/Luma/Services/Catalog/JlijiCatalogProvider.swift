import Foundation

/// JLiji 图集站适配器。
///
/// 列表是套图卡片（`/set/{id}`），详情页是一组图片：
/// 缩略图在 `.../thumbs/N.webp`，原图在 `.../N.jpg` 并写在 `data-full` 上。
/// 站点没有视频，详情页的「分集」为空，正文全部是图片。
struct JlijiCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://www.jliji.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 一级导航与首页筛选行一致：分类 / 模特 / 发布商。
    /// 三个一级自身没有页面（`isGroup`），点开等于进入各自二级里的第一项；
    /// 二级（具体分类 / 模特 / 发布商）才是真正的列表页。
    static var defaultCategories: [CatalogCategory] { modules(from: defaultTagGroups) }

    static func modules(from groups: [CatalogTagGroup]) -> [CatalogCategory] {
        groups.map { group in
            CatalogCategory(id: group.id, title: group.title,
                            children: group.items.map {
                                CatalogCategory(id: $0.id, title: $0.title)
                            },
                            isGroup: true)
        }
    }

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let fallback = source.categories.isEmpty ? Self.defaultCategories : source.categories
        guard let root = try? WebCatalogSupport.root(source),
              let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source) else {
            return fallback
        }
        let groups = Self.parseTagGroups(html)
        return groups.isEmpty ? fallback : Self.modules(from: groups)
    }

    /// 三个一级的二级项首次没取到时，打开时再补一次。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        guard ["category", "model", "publisher"].contains(category.id) else {
            return category.children ?? []
        }
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source)
        else { return category.children ?? [] }
        return Self.parseTagGroups(html)
            .first(where: { $0.id == category.id })?
            .items.map { CatalogCategory(id: $0.id, title: $0.title) } ?? []
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await list(source: source, path: nil, page: 1, sort: .newest)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        try await list(source: source, path: nil, page: page, sort: .newest)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        // 标签行（模特 / 发布商 / 分类）把路由编码成 `tag:维度:slug`。
        if let route = Self.parseTagRoute(category.id) {
            return try await list(source: source,
                                  path: "\(route.dimension)/\(route.slug)",
                                  page: page,
                                  sort: sort)
        }
        // 分组节点本身没有列表页：二级还没取到时用首页列表兜底。
        if ["category", "model", "publisher"].contains(category.id) {
            return try await list(source: source, path: nil, page: page, sort: sort)
        }
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        return try await list(source: source, path: target.id, page: page, sort: sort)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root)/images/search?q=\(encoded)"
        if page > 1 { address += "&page=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        // 站点搜索只有一页（`&page=2` 返回空），按页脚链接判断是否还有下一页。
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page))
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/set/\(itemID)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        let images = Self.parseImages(html, base: root)
        let title = Self.parseTitle(html, fallback: "图集 \(itemID)")
        let metaCover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let cover = metaCover.isEmpty ? (images.first.map(Self.thumbnailURL) ?? "") : metaCover

        var facts: [CatalogDetailFact] = []
        var tags: [String] = []
        if let category = Self.firstLink(html, prefix: "/category/") {
            facts.append(CatalogDetailFact(label: "分类", value: category))
            tags.append(category)
        }
        if let model = Self.firstLink(html, prefix: "/model/") {
            facts.append(CatalogDetailFact(label: "模特", value: model))
            tags.append(model)
        }
        if let publisher = Self.firstLink(html, prefix: "/publisher/") {
            facts.append(CatalogDetailFact(label: "发布商", value: publisher))
            tags.append(publisher)
        }
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
        }
        if let views = CatalogHTML.first(#"(\d+)\s*次浏览"#, in: html) {
            facts.append(CatalogDetailFact(label: "浏览", value: "\(views) 次"))
        }

        var blocks: [CatalogContentBlock] = []
        if !images.isEmpty {
            blocks.append(CatalogContentBlock(kind: .paragraph,
                                              text: "共 \(images.count) 张图片 · 点击任意一张进入图集浏览"))
        }
        blocks.append(contentsOf: images.map { CatalogContentBlock(kind: .image, text: $0) })

        let item = CatalogItem(id: itemID, title: title, coverURL: cover,
                               remark: images.isEmpty ? "" : "\(images.count)P")
        return CatalogDetail(item: item, episodes: [], blocks: blocks, facts: facts,
                             tags: WebCatalogSupport.unique(tags))
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        throw CatalogError.unavailable("图集条目没有可播放的视频")
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    var supportedSorts: [CatalogSort] { [.newest, .hot] }

    // MARK: - 标签

    static let defaultTagGroups: [CatalogTagGroup] = [
        CatalogTagGroup(id: "category", title: "分类",
                        items: [("taotu", "甜系图鉴"), ("wanghong", "次元COS"),
                                ("laosiji", "私房特辑"), ("han-guo-xie-zhen", "韩系风情"),
                                ("ri-ben-xie-zhen", "日系风情"), ("ou-mei-feng-qing", "欧美风情"),
                                ("ou-mei-you-wu", "欧美尤物"), ("ai", "AI幻想")]
                            .map { CatalogTag(id: "tag:category:\($0.0)", title: $0.1) }),
        CatalogTagGroup(id: "model", title: "模特",
                        items: [("bu-ding-da-fa", "布丁大法"), ("chun-mo-mo", "蠢沫沫"),
                                ("byoru", "Byoru"), ("umekoj", "UmekoJ"),
                                ("tai-he-jin-titi", "钛合金TiTi"), ("lu-ba-sui", "鹿八岁"),
                                ("poppachan", "PoppaChan"), ("pingping", "PingPing")]
                            .map { CatalogTag(id: "tag:model:\($0.0)", title: $0.1) }),
        CatalogTagGroup(id: "publisher", title: "发布商",
                        items: [("jp", "JP"), ("xiu-ren-wang", "秀人网"),
                                ("guo-mo-tao-tu", "国模套图"), ("jvid", "JVID"),
                                ("xing-yan-she", "星颜社"), ("si-gou-liu-chu", "私购流出"),
                                ("zishy", "Zishy"), ("xr-uncensored", "XR Uncensored")]
                            .map { CatalogTag(id: "tag:publisher:\($0.0)", title: $0.1) })
    ]

    /// 首页筛选行：按 `/category/`、`/model/`、`/publisher/` 三种链接分组。
    static func parseTagGroups(_ html: String) -> [CatalogTagGroup] {
        let dimensions: [(String, String)] = [("category", "分类"),
                                              ("model", "模特"),
                                              ("publisher", "发布商")]
        var groups: [CatalogTagGroup] = []
        for (dimension, title) in dimensions {
            let pattern = #"<a[^>]+href="[^"]*/\#(dimension)/([^"/?]+)[^"]*"[^>]*>([^<]+)</a>"#
            var items: [CatalogTag] = []
            var seen = Set<String>()
            for raw in CatalogHTML.fullMatches(pattern, in: html) {
                guard let slug = CatalogHTML.first(
                        #"href="[^"]*/\#(dimension)/([^"/?]+)[^"]*""#, in: raw),
                      let text = CatalogHTML.first(#">([^<]+)</a>"#, in: raw)
                else { continue }
                let name = CatalogHTML.stripTags(text)
                guard !slug.isEmpty, !name.isEmpty,
                      seen.insert(slug + "|" + name).inserted else { continue }
                items.append(CatalogTag(id: "tag:\(dimension):\(slug)", title: name))
                if items.count >= 40 { break }
            }
            if !items.isEmpty {
                groups.append(CatalogTagGroup(id: dimension, title: title, items: items))
            }
        }
        return groups
    }

    /// `tag:model:byoru` → (model, byoru)
    static func parseTagRoute(_ id: String) -> (dimension: String, slug: String)? {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "tag",
              ["category", "model", "publisher"].contains(parts[1]),
              !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }

    // MARK: - 列表

    private func list(source: CatalogSource, path: String?, page: Int,
                      sort: CatalogSort) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        var components = URLComponents(string: root + (path.map { "/\($0)" } ?? "/"))
        var query = [URLQueryItem(name: "sort", value: Self.sortValue(sort))]
        if page > 1 { query.append(URLQueryItem(name: "page", value: "\(page)")) }
        components?.queryItems = query
        guard let address = components?.url?.absoluteString else {
            throw CatalogError.parse("列表地址无效")
        }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page)
                               || items.count >= 24)
    }

    /// 站点排序参数：最新 / 近期最热。
    private static func sortValue(_ sort: CatalogSort) -> String {
        switch sort {
        case .hot: return "hot"
        default: return "newest"
        }
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = try await WebCatalogSupport.fetchHTML(base + "/", source: CatalogSource(
            name: "JLiji 图集",
            kind: .jliji,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard probe.contains("/set/") || probe.contains("cdn.jliji.com") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "JLiji 图集",
                             kind: .jliji,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 3.0 / 4.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    /// 卡片：`<a href="/set/{id}">` 包着缩略图与标题，附近带「20P」张数。
    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        let pattern = #"<a[^>]+href="[^"]*/set/(\d+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let id = ns.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted else { continue }
            let inner = ns.substring(with: match.range(at: 2))

            let rawCover = CatalogHTML.first(#"<img[^>]+data-src="([^"]+)""#, in: inner)
                ?? CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: inner)
                ?? ""
            let cover = CatalogHTML.fixURL(rawCover, base: base)
            let alt = CatalogHTML.stripTags(
                CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: inner) ?? "")
            let text = CatalogHTML.stripTags(inner)
            let title = alt.isEmpty ? Self.trimmedTitle(text) : alt
            guard !title.isEmpty else { continue }

            let remark = CatalogHTML.first(#"(\d+)\s*P(?![\w])"#, in: text) ?? ""
            result.append(CatalogItem(id: id,
                                      title: title,
                                      coverURL: cover,
                                      remark: remark.isEmpty ? "" : "\(remark)P",
                                      categoryID: nil))
        }
        return result
    }

    /// 详情页图片：优先 `data-full` 原图；只有缩略图时按站点规律还原原图地址。
    static func parseImages(_ html: String, base: String) -> [String] {
        var images: [String] = []
        var seen = Set<String>()
        func append(_ raw: String) {
            let fixed = CatalogHTML.fixURL(raw, base: base)
            guard fixed.contains("cdn.jliji.com/galleries/"),
                  seen.insert(fixed).inserted else { return }
            images.append(fixed)
        }
        for raw in CatalogHTML.fullMatches(#"data-full="([^"]+)""#, in: html) {
            if let url = CatalogHTML.first(#"data-full="([^"]+)""#, in: raw) {
                append(url)
            }
        }
        if images.isEmpty {
            for raw in CatalogHTML.fullMatches(#"<img[^>]+(?:data-src|src)="([^"]+)""#, in: html) {
                guard let url = CatalogHTML.first(#"<img[^>]+data-src="([^"]+)""#, in: raw)
                        ?? CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: raw) else { continue }
                append(fullURL(fromThumbnail: url, base: base))
            }
        }
        return images
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        if !heading.isEmpty { return heading }
        let og = WebCatalogSupport.meta(html, "og:title")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return og.isEmpty ? fallback : og
    }

    private static func firstLink(_ html: String, prefix: String) -> String? {
        let pattern = #"<a[^>]+href="[^"]*\#(prefix)[^"]*"[^>]*>([^<]+)</a>"#
        guard let value = CatalogHTML.first(pattern, in: html) else { return nil }
        let text = CatalogHTML.stripTags(value)
        return text.isEmpty ? nil : text
    }

    /// `.../thumbs/3.webp` → `.../3.jpg`：站点原图与缩略图共用同一目录层级。
    private static func fullURL(fromThumbnail raw: String, base: String) -> String {
        let fixed = CatalogHTML.fixURL(raw, base: base)
        guard let range = fixed.range(of: "/thumbs/", options: .backwards) else { return fixed }
        let name = fixed[range.upperBound...]
            .replacingOccurrences(of: ".webp", with: ".jpg")
            .replacingOccurrences(of: ".png", with: ".jpg")
        return String(fixed[..<range.lowerBound]) + "/" + name
    }

    /// `.../3.jpg` → `.../thumbs/3.webp`：网格用缩略图，省流量也更快出图。
    static func thumbnailURL(_ raw: String) -> String {
        var value = raw
        guard value.range(of: "/thumbs/", options: .backwards) == nil,
              let slash = value.lastIndex(of: "/") else { return raw }
        var name = String(value[value.index(after: slash)...])
        if name.hasSuffix(".jpg") {
            name = String(name.dropLast(4)) + ".webp"
        } else if name.hasSuffix(".png") {
            name = String(name.dropLast(4)) + ".webp"
        } else {
            return raw
        }
        value = String(value[..<slash]) + "/thumbs/" + name
        return value
    }

    /// 卡片文字里常带「分类 + 张数」，没有 alt 时用它兜底并去掉尾部统计。
    private static func trimmedTitle(_ text: String) -> String {
        var value = text
        if let range = value.range(of: #"\s+\d+\s*P\s*$"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
