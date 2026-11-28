import Foundation

/// 爱妹子（xx.knit.bid）图集站适配器。
///
/// 站点导航有明确的栏目：最新更新 / 分类浏览 / 专题 / 人物与作品 / 排行榜 / 标签库 /
/// 热门内容 / 热门搜索。这里把它们全部铺成一级入口：
/// - 分类浏览：下拉里的 10 个分类 + 花絮，作为二级；
/// - 专题：二级为「精选专题（第 1 页）」与「其他专题（第 2 页起）」；
/// - 人物与作品：出镜人物 / 角色 / 作品系列 / 创作者各做一个一级，点进去是实体卡片墙；
/// - 排行榜：日榜 / 3天榜 / 周榜 / 月榜作为二级；
/// - 标签库：全站 500 多个标签，用标签墙（搜索 + 分页）展示；
/// - 热门搜索：热搜词作为二级，点词直接走站内搜索。
struct KnitCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://xx.knit.bid"
    static let defaultUserAgent = WebCatalogSupport.userAgent
    /// 详情页每页图片数（站点固定 10 张一页，`/page/N/` 翻页）。
    private static let detailPageSize = 10

    /// 分类浏览下拉里的固定分类：`type:1` 直接拼成 `/type/1/`。
    static let typeCategories: [(id: String, title: String)] = [
        ("type:1", "性感美女"), ("type:2", "清纯美女"), ("type:3", "丝袜美女"),
        ("type:4", "美腿美女"), ("type:5", "美胸美女"), ("type:6", "Cosplay"),
        ("type:7", "制服诱惑"), ("type:8", "网络美女"), ("type:9", "大尺度美女"),
        ("type:10", "AI美女"), ("type:bits", "花絮")
    ]

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "sort/new", title: "最新更新"),
        CatalogCategory(id: "types", title: "分类浏览",
                        children: typeCategories.map {
                            CatalogCategory(id: $0.id, title: $0.title)
                        },
                        isGroup: true),
        CatalogCategory(id: "topics", title: "专题",
                        children: [
                            CatalogCategory(id: "topics:featured", title: "精选专题"),
                            CatalogCategory(id: "topics:other", title: "其他专题")
                        ],
                        isGroup: true),
        CatalogCategory(id: "entities/performers", title: "出镜人物"),
        CatalogCategory(id: "entities/characters", title: "角色"),
        CatalogCategory(id: "entities/franchises", title: "作品系列"),
        CatalogCategory(id: "entities/creators", title: "创作者"),
        CatalogCategory(id: "rankings", title: "排行榜",
                        children: [
                            CatalogCategory(id: "rankings:daily", title: "日榜"),
                            CatalogCategory(id: "rankings:3days", title: "3天榜"),
                            CatalogCategory(id: "rankings:weekly", title: "周榜"),
                            CatalogCategory(id: "rankings:monthly", title: "月榜")
                        ],
                        isGroup: true),
        // 标签库是标签墙节点：频道页用搜索 + 分页展示全站 500 多个标签。
        CatalogCategory(id: "tag", title: "标签库", isTagWall: true),
        CatalogCategory(id: "sort/hot", title: "热门内容"),
        // 热门搜索：二级是热搜词，随分类一起补齐（取不到时打开再补）。
        CatalogCategory(id: "hotsearch", title: "热门搜索", children: [], isGroup: true)
    ]

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        var list = source.categories.isEmpty ? Self.defaultCategories : source.categories
        // 热搜词跟分类一起补齐：有了本地缓存后，一天最多取一次。
        if let index = list.firstIndex(where: { $0.id == "hotsearch" }),
           list[index].children?.isEmpty ?? true,
           let terms = try? await Self.hotSearchTerms(source: source), !terms.isEmpty {
            list[index].children = terms.map {
                CatalogCategory(id: "search:\($0.title)", title: $0.title)
            }
        }
        return list
    }

    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        guard category.id == "hotsearch" else { return category.children ?? [] }
        guard let terms = try? await Self.hotSearchTerms(source: source) else {
            return category.children ?? []
        }
        return terms.map { CatalogCategory(id: "search:\($0.title)", title: $0.title) }
    }

    /// 「标签库」：`/tag/` 一页给出全部标签，每项带 `×数量`。
    func allTags(source: CatalogSource) async throws -> [CatalogTag] {
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/tag/", source: source)
        else { return [] }
        return Self.parseTagList(html)
    }

    // MARK: - 首页 / 分类

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await list(source: source, path: "sort/new", page: 1, parse: Self.parseArticleCards)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        try await list(source: source, path: "sort/new", page: page, parse: Self.parseArticleCards)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let id = category.id
        // 标签墙与热搜分组自身不是列表页：用最新列表垫底。
        if id == "tag" || id == "hotsearch" {
            return try await list(source: source, path: "sort/new", page: 1,
                                  parse: Self.parseArticleCards)
        }
        // 分类浏览：`type:1` → /type/1/，`type:bits` → /bits-of-news/。
        if id.hasPrefix("type:") {
            let value = String(id.dropFirst("type:".count))
            let path = value == "bits" ? "bits-of-news" : "type/\(value)"
            return try await list(source: source, path: path, page: page,
                                  parse: Self.parseArticleCards)
        }
        // 专题：精选从第 1 页开始，其他从第 2 页开始，列表是专题卡片。
        if id == "topics:featured" || id == "topics:other" {
            let root = try WebCatalogSupport.root(source)
            let offset = id == "topics:other" ? 1 : 0
            let current = max(1, page) + offset
            let address = current > 1 ? "\(root)/topics/page/\(current)/" : "\(root)/topics/"
            let html = try await WebCatalogSupport.fetchHTML(address, source: source)
            let items = Self.parseTopicCards(html, base: root)
            return CatalogPage(items: items, page: page,
                               hasMore: Self.hasNext(html, page: current))
        }
        // 专题卡片：点开看该专题的图集列表。
        if id.hasPrefix("topic/") {
            let slug = String(id.dropFirst("topic/".count))
            return try await list(source: source, path: "topic/\(slug)", page: page,
                                  parse: Self.parseArticleCards)
        }
        // 人物与作品：`entities/performers` 是实体卡片墙；`entity/...` 是该实体的图集。
        if id.hasPrefix("entities/") {
            return try await list(source: source, path: id, page: page,
                                  parse: Self.entityCardsParser)
        }
        if id.hasPrefix("entity/") {
            return try await list(source: source, path: id, page: page,
                                  parse: Self.parseArticleCards)
        }
        // 排行榜：日榜 / 3天榜 / 周榜 / 月榜。
        if id.hasPrefix("rankings:") {
            let value = String(id.dropFirst("rankings:".count))
            return try await list(source: source, path: "rankings/\(value)", page: page,
                                  parse: Self.parseArticleCards)
        }
        // 标签库里的标签：`tag:1503` → /tag/1503/。
        if id.hasPrefix("tag:") {
            let value = String(id.dropFirst("tag:".count))
            return try await list(source: source, path: "tag/\(value)", page: page,
                                  parse: Self.parseArticleCards)
        }
        // 热门搜索词：直接走站内搜索。
        if id.hasPrefix("search:") {
            let term = String(id.dropFirst("search:".count))
            return try await search(source: source, keyword: term, page: page)
        }
        guard !id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        return try await list(source: source, path: id, page: page,
                              parse: Self.parseArticleCards)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let encoded = WebCatalogSupport.queryEncoded(trimmed) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let current = max(1, page)
        var address = "\(root)/search/?s=\(encoded)"
        if current > 1 { address = "\(root)/search/page/\(current)/?s=\(encoded)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseArticleCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: Self.hasNext(html, page: page))
    }

    // MARK: - 详情

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let articleID = itemID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let address = "\(root)/article/\(articleID)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        var images = Self.parseImages(html, base: root)
        let total = Self.totalImages(html) ?? images.count
        let perPage = max(1, images.count > 0 ? images.count : Self.detailPageSize)
        let pages = min(30, max(1, Int(ceil(Double(total) / Double(perPage)))))
        if pages > 1 {
            var seen = Set(images)
            for page in 2...pages {
                guard let more = try? await WebCatalogSupport.fetchHTML(
                    "\(address)page/\(page)/", source: source) else { break }
                let batch = Self.parseImages(more, base: root)
                if batch.isEmpty { break }
                for url in batch where seen.insert(url).inserted {
                    images.append(url)
                }
            }
        }

        let title = Self.parseTitle(html, fallback: "图集 \(articleID)")
        let videos = Self.parseVideoSources(html, base: root)
        let cover = images.first ?? videos.first?.poster ?? ""
        var facts: [CatalogDetailFact] = []
        if !videos.isEmpty {
            facts.append(CatalogDetailFact(label: "视频", value: "\(videos.count) 个"))
        }
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
        }
        let tags = Self.parseDetailTags(html)
        if !tags.isEmpty {
            facts.append(CatalogDetailFact(label: "标签", value: "\(tags.count) 个"))
        }
        if let date = CatalogHTML.first(#"<time[^>]*>(\d{4}-\d{2}-\d{2})</time>"#, in: html) {
            facts.append(CatalogDetailFact(label: "发布", value: date))
        }

        var blocks: [CatalogContentBlock] = []
        if !images.isEmpty {
            blocks.append(CatalogContentBlock(kind: .paragraph,
                                              text: "共 \(images.count) 张图片 · 点击任意一张进入图集浏览"))
        }
        blocks.append(contentsOf: images.map { CatalogContentBlock(kind: .image, text: $0) })

        let episodes = videos.enumerated().map { index, video in
            CatalogEpisode(index: index + 1,
                           pageURL: video.url,
                           coverURL: video.poster.isEmpty ? cover : video.poster,
                           name: videos.count > 1 ? "视频 \(index + 1)" : "视频")
        }
        let item = CatalogItem(id: articleID, title: title, coverURL: cover,
                               remark: images.isEmpty ? "" : "\(images.count)P",
                               mediaKind: videos.isEmpty ? (images.isEmpty ? nil : .gallery) : .video)
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts,
                             tags: tags)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let url = URL(string: episode.pageURL) else {
            throw CatalogError.parse("视频地址无效")
        }
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent, "Referer": source.referer],
                             isHLS: url.pathExtension.lowercased() == "m3u8")
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = try await WebCatalogSupport.fetchHTML(base + "/", source: CatalogSource(
            name: "爱妹子 图集",
            kind: .knit,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard probe.contains("/article/") || probe.contains("knit") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "爱妹子 图集",
                             kind: .knit,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 3.0 / 2.0,
                             isEnabled: false)
    }

    // MARK: - 列表

    private func list(source: CatalogSource, path: String, page: Int,
                      parse: (String, String) -> [CatalogItem]) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let current = max(1, page)
        var address = "\(root)/\(path)/"
        if current > 1 { address = "\(root)/\(path)/page/\(current)/" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = parse(html, root)
        return CatalogPage(items: items, page: page, hasMore: Self.hasNext(html, page: page))
    }

    /// 站点分页统一是 `/page/N/`：看 `<link rel="next">` 或页尾链接有没有下一页。
    static func hasNext(_ html: String, page: Int) -> Bool {
        if html.contains("rel=\"next\"") { return true }
        return html.contains("/page/\(max(1, page) + 1)/")
    }

    // MARK: - 解析

    /// 图集卡片：`article.excerpt`，标题里带「97P」张数。
    static func parseArticleCards(_ html: String, base: String) -> [CatalogItem] {
        let pattern = #"<article[^>]+class="[^"]*excerpt[^"]*"[^>]*>([\s\S]*?)</article>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var items: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: match.range(at: 1))
            guard let id = CatalogHTML.first(#"href="/article/(\d+)/""#, in: inner),
                  seen.insert(id).inserted else { continue }

            let heading = CatalogHTML.first(#"<h2[^>]*>([\s\S]*?)</h2>"#, in: inner)
                .map(CatalogHTML.stripTags) ?? ""
            let alt = CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: inner) ?? ""
            let title = [heading, alt].first { !$0.isEmpty } ?? ""
            guard !title.isEmpty else { continue }

            let lazyCover = CatalogHTML.first(#"data-original-src="([^"]+)""#, in: inner)
            let noscriptCover = CatalogHTML.first(#"<noscript>\s*<img[^>]+src="([^"]+)""#,
                                                  in: inner)
            let rawCover = lazyCover ?? noscriptCover ?? ""
            let remark = CatalogHTML.first(#"(\d+)\s*P"#, in: title) ?? ""
            // 综合站：标题里的「26V」是多视频合集，「97P」是图集；
            // 两者都没有时按图集展示，详情页解析到视频后再按视频排版。
            let hasVideos = CatalogHTML.first(#"(\d+)\s*V"#, in: title) != nil
            let mediaKind: CatalogItemKind? = hasVideos ? .video : (remark.isEmpty ? nil : .gallery)

            items.append(CatalogItem(id: id,
                                     title: title,
                                     coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                     remark: remark.isEmpty ? "" : "\(remark)P",
                                     mediaKind: mediaKind))
        }
        return items
    }

    /// 专题 / 实体卡片：`a.discovery-card`，带封面、标题与「N 条内容」。
    static func parseCollectionCards(_ html: String, base: String,
                                     prefix: String) -> [CatalogItem] {
        let pattern = #"<a[^>]+class="discovery-card"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var items: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: match.range(at: 1))
            guard href.hasPrefix(prefix) else { continue }
            let id = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(id).inserted else { continue }
            let inner = ns.substring(with: match.range(at: 2))

            let title = CatalogHTML.first(#"<h3[^>]*>([\s\S]*?)</h3>"#, in: inner)
                .map(CatalogHTML.stripTags) ?? ""
            guard !title.isEmpty else { continue }
            let rawCover = CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: inner) ?? ""
            let count = CatalogHTML.first(#"<small[^>]*>([\s\S]*?)</small>"#, in: inner)
                .map(CatalogHTML.stripTags) ?? ""

            items.append(CatalogItem(id: id,
                                     title: title,
                                     coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                     remark: count))
        }
        return items
    }

    static func parseTopicCards(_ html: String, base: String) -> [CatalogItem] {
        parseCollectionCards(html, base: base, prefix: "/topic/")
    }

    static func entityCardsParser(_ html: String, base: String) -> [CatalogItem] {
        parseCollectionCards(html, base: base, prefix: "/entity/")
    }

    /// 标签库 / 热门搜索：`div.tagslist` 里每项是 `名称 ×数量`。
    static func parseTagList(_ html: String) -> [CatalogTag] {
        let pattern = #"<li>\s*<a[^>]+href="/tag/(\d+)/"[^>]*>([^<]{1,80})</a>\s*<small>([^<]{1,40})</small>"#
        var items: [CatalogTag] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let tagID = CatalogHTML.first(#"href="/tag/(\d+)/""#, in: raw),
                  let text = CatalogHTML.first(#">([^<]+)</a>"#, in: raw),
                  let countText = CatalogHTML.first(#"<small>([^<]+)</small>"#, in: raw)
            else { continue }
            let title = CatalogHTML.stripTags(text)
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            let digits = CatalogHTML.first(#"(\d+)"#, in: countText) ?? ""
            items.append(CatalogTag(id: "tag:\(tagID)", title: title, count: Int(digits)))
        }
        return items
    }

    /// 热搜词：同一个 `tagslist`，但链接是 `/search/?s=词`。
    static func parseHotSearch(_ html: String) -> [(title: String, count: Int?)] {
        let pattern = #"<li>\s*<a[^>]+href="/search/\?s=[^"]*"[^>]*>([^<]{1,80})</a>\s*<small>([^<]{1,40})</small>"#
        var items: [(title: String, count: Int?)] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let text = CatalogHTML.first(#">([^<]+)</a>"#, in: raw),
                  let countText = CatalogHTML.first(#"<small>([^<]+)</small>"#, in: raw)
            else { continue }
            let title = CatalogHTML.stripTags(text)
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            let digits = CatalogHTML.first(#"(\d+)"#, in: countText) ?? ""
            items.append((title: title, count: Int(digits)))
        }
        return items
    }

    private static func hotSearchTerms(source: CatalogSource) async throws -> [CatalogTag] {
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/hot-search",
                                                                source: source) else { return [] }
        return parseHotSearch(html).map { CatalogTag(id: "search:\($0.title)",
                                                     title: $0.title, count: $0.count) }
    }

    /// 详情视频：文章顶部可能有一到多段 `article-video-block`，
    /// 真实地址在 `<video><source src="….m3u8">` 上，按出现顺序作为分集。
    static func parseVideoSources(_ html: String, base: String) -> [(url: String, poster: String)] {
        var result: [(url: String, poster: String)] = []
        var seen = Set<String>()
        for tag in CatalogHTML.fullMatches(#"<video[^>]*>[\s\S]*?</video>"#, in: html) {
            guard let raw = CatalogHTML.first(#"<source[^>]+src="([^"]+)""#, in: tag)
                    ?? CatalogHTML.first(#"<video[^>]+src="([^"]+)""#, in: tag) else { continue }
            let url = CatalogHTML.fixURL(raw, base: base)
            guard !url.isEmpty, seen.insert(url).inserted else { continue }
            let poster = CatalogHTML.first(#"<video[^>]+poster="([^"]+)""#, in: tag)
                .map { CatalogHTML.fixURL($0, base: base) } ?? ""
            result.append((url, poster))
        }
        return result
    }

    /// 详情正文图：`img.item-image__img`，懒加载时真实地址在 `data-src`。
    static func parseImages(_ html: String, base: String) -> [String] {
        var images: [String] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(#"<img[^>]+class="item-image__img[^"]*"[^>]*>"#, in: html) {
            guard let value = CatalogHTML.bestImageURL(in: raw, base: base),
                  !value.contains("timg.gif"), value.contains("/static/") else { continue }
            guard seen.insert(value).inserted else { continue }
            images.append(value)
        }
        return images
    }

    /// 详情页总张数：ld+json 里 `numberOfItems`，标题里的 `97P` 兜底。
    static func totalImages(_ html: String) -> Int? {
        if let value = CatalogHTML.first(#""numberOfItems":\s*(\d+)"#, in: html),
           let total = Int(value), total > 0 {
            return total
        }
        if let value = CatalogHTML.first(#"(\d+)\s*P"#, in: html) {
            return Int(value)
        }
        return nil
    }

    static func parseDetailTags(_ html: String) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        let pattern = #"<a[^>]+href="/tag/\d+/"[^>]*>([^<]+)</a>"#
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let text = CatalogHTML.first(pattern, in: raw) else { continue }
            let value = CatalogHTML.stripTags(text)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            tags.append(value)
        }
        return tags
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        if !heading.isEmpty { return heading }
        let og = WebCatalogSupport.meta(html, "og:title")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return og.isEmpty ? fallback : og
    }
}
