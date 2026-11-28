import Foundation

/// 麻豆社（`madou.club`）适配器：国产原创片库（麻豆 / 果冻 / 天美 / 星空 / 精东 / 91制片厂等）。
///
/// - 列表：WordPress 服务端渲染，卡片是 `<article class="excerpt">`，标题在 `<h2>`
///   里，封面是 `data-src`，分页 ` /page/N `。
/// - 分类：导航里的 `/category/<slug>` 就是片商 / 系列，顺序按站点导航。
/// - 搜索：WordPress 原生 `?s=<关键词>`，分页 `/page/N/?s=…`。
/// - 播放：详情页正文内嵌 `dash.madou.club/share/<id>` iframe；
///   该页给出一段带 100 秒 token 的 `index.m3u8`，拼上 token 就能播。
struct MadouCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://madou.club"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 一级：麻豆传媒 / 麻豆番外篇 / 麻豆花絮。
    private static let studioCategories: [(id: String, title: String)] = [
        ("category/%e9%ba%bb%e8%b1%86%e4%bc%a0%e5%aa%92", "麻豆传媒"),
        ("category/%e9%ba%bb%e8%b1%86%e7%95%aa%e5%a4%96%e7%af%87", "麻豆番外篇"),
        ("category/%e9%ba%bb%e8%b1%86%e8%8a%b1%e7%b5%ae", "麻豆花絮")
    ]

    /// 「其他原创/企划」下拉里的片商（离线骨架，打开时会用站点实时菜单替换）。
    private static let otherStudios: [(id: String, title: String)] = [
        ("category/hongkongdoll", "HongKongDoll"),
        ("category/psychoporntw", "PsychopornTW"),
        ("category/91%e5%88%b6%e7%89%87%e5%8e%82", "91制片厂"),
        ("category/%e6%9e%9c%e5%86%bb%e4%bc%a0%e5%aa%92", "果冻传媒"),
        ("category/%e8%9c%9c%e6%a1%83%e5%bd%b1%e5%83%8f", "蜜桃影像"),
        ("category/%e5%a4%a9%e7%be%8e%e4%bc%a0%e5%aa%92", "天美传媒"),
        ("category/%e7%9a%87%e5%ae%b6%e5%8d%8e%e4%ba%ba", "皇家华人"),
        ("category/%e5%85%94%e5%ad%90%e5%85%88%e7%94%9f", "兔子先生"),
        ("category/%e6%98%9f%e7%a9%ba%e6%97%a0%e9%99%90%e4%bc%a0%e5%aa%92", "星空无限传媒"),
        ("category/%e9%ba%bb%e8%b1%86%e5%af%bc%e6%bc%94%e7%b3%bb%e5%88%97", "麻豆导演系列"),
        ("category/%e7%b2%be%e4%b8%9c%e5%bd%b1%e4%b8%9a", "精东影业"),
        ("category/%e5%a4%a7%e8%b1%a1%e4%bc%a0%e5%aa%92", "大象传媒"),
        ("category/%e7%8c%ab%e7%88%aa%e5%bd%b1%e5%83%8f", "猫爪影像"),
        ("category/%e6%9d%8f%e5%90%a7", "杏吧"),
        ("category/%e4%b9%90%e6%92%ad%e4%bc%a0%e5%aa%92", "乐播传媒"),
        ("category/%e8%8d%89%e8%8e%93", "草莓"),
        ("category/%e6%8a%96%e9%98%b4", "抖阴"),
        ("category/%e8%b5%b7%e7%82%b9%e4%bc%a0%e5%aa%92-%e6%80%a7%e8%a7%86%e7%95%8c%e4%bc%a0%e5%aa%92", "起点传媒/性视界传媒"),
        ("category/%e5%a4%a7%e9%b8%9f%e5%8d%81%e5%85%ab", "大鸟十八"),
        ("category/%e5%b0%8f%e9%b9%8f%e5%a5%87%e5%95%aa%e8%a1%8c", "小鹏奇啪行"),
        ("category/%e5%a5%b3%e4%bc%98%e6%b7%ab%e5%a8%83%e5%9f%b9%e8%ae%ad%e8%90%a5", "女优淫娃培训营")
    ]

    /// 「筛选」下拉：三个榜单页。
    private static let filterCategories: [CatalogCategory] = [
        CatalogCategory(id: "likes", title: "点赞排行"),
        CatalogCategory(id: "week", title: "7天热门"),
        CatalogCategory(id: "month", title: "30天热门")
    ]

    /// 没有网络时用于渲染侧边栏骨架。
    /// 一级顺序与站点导航一致；下拉菜单和「筛选」是二级，
    /// 「热门标签」的 50 个标签在打开时补成二级。
    static let defaultCategories: [CatalogCategory] = {
        var list = studioCategories.map { CatalogCategory(id: $0.id, title: $0.title) }
        list.append(CatalogCategory(id: "others", title: "其他原创/企划",
                                    children: otherStudios.map {
                                        CatalogCategory(id: $0.id, title: $0.title)
                                    },
                                    isGroup: true))
        list.append(CatalogCategory(id: "tags", title: "热门标签",
                                    children: [], isGroup: true))
        list.append(CatalogCategory(id: "filters", title: "筛选",
                                    children: filterCategories, isGroup: true))
        return list
    }()

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        if let live = try? await Self.liveCategories(source: source, root: root), live.count >= 3 {
            return live
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    /// 一级分类下没有列表的分组，打开时再补二级：
    /// 「热门标签」抓 /tags 的 50 个标签，「其他原创/企划」重取站点下拉菜单。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        switch category.id {
        case "tags":
            guard let html = try? await WebCatalogSupport.fetchHTML(root + "/tags",
                                                                    source: Self.pageSource(source, root: root))
            else { return category.children ?? [] }
            let tags = Self.parseHotTags(html)
            return tags.isEmpty ? (category.children ?? []) : tags
        case "others":
            let live = (try? await Self.liveCategories(source: source, root: root)) ?? []
            return live.first(where: { $0.id == "others" })?.children ?? category.children ?? []
        default:
            return category.children ?? []
        }
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let address = page > 1 ? "\(root)/page/\(page)" : root + "/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        let id = target.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        // 分组节点还没有二级（例如「热门标签」还没抓到）时用首页垫底，避免空白页。
        if ["tags", "filters", "others"].contains(id) {
            return try await home(source: source, page: page)
        }
        var address = "\(root)/"
        // 导航解析出来的 id 已经是 percent-encoding；只有手写的默认分类需要编码，
        // 再次编码会把 `%` 变成 `%25`。
        address += id.contains("%")
            ? id
            : (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
        if page > 1 { address += "/page/\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword) else {
            throw CatalogError.parse("搜索关键词无效")
        }
        let address = page > 1 ? "\(root)/page/\(page)/?s=\(encoded)" : "\(root)/?s=\(encoded)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? itemID
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        // 正文标签里混着导航与长句，只留短标签，详情页不会变成一大段。
        let tags = Self.links(html, path: "/tag/")
            .filter { $0.count <= 12 }
            .prefix(12)
            .map { $0 }
        let studios = Self.categoryTags(html)

        var detail = WebCatalogSupport.singleEpisode(id: itemID,
                                                     title: title,
                                                     cover: cover,
                                                     pageURL: address,
                                                     blocks: WebCatalogSupport.tagBlocks(tags))
        if let studio = studios.first {
            detail.facts.append(CatalogDetailFact(label: "系列", value: studio))
        }
        if !tags.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "类型",
                                                  value: tags.prefix(6).joined(separator: "、")))
        }
        return detail
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let root = try WebCatalogSupport.root(source)
        guard !episode.pageURL.isEmpty else { throw CatalogError.parse("分集地址无效") }
        let address = episode.pageURL
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))

        // 详情页正文里的 iframe 才是播放页；广告 iframe 在正文外，不参与匹配。
        guard let share = CatalogHTML.first(#"(https?://dash\.[^\s"'<>]+/share/[0-9a-zA-Z]+)"#, in: html)
                ?? CatalogHTML.first(#"<iframe[^>]+src=["']?([^"' >]+)"#, in: html) else {
            throw CatalogError.parse("该条目没有可播放的视频")
        }
        let playHTML = try await WebCatalogSupport.fetchHTML(share, source: Self.pageSource(source, root: root))
        guard let rawPath = CatalogHTML.first(#"var m3u8 = '([^']+)'"#, in: playHTML) else {
            throw CatalogError.parse("播放地址解析失败")
        }
        var raw = rawPath
        if !raw.hasPrefix("http") {
            let comps = URLComponents(string: share)
            let host = (comps?.scheme ?? "https") + "://" + (comps?.host ?? "dash.madou.club")
            raw = host + (raw.hasPrefix("/") ? raw : "/" + raw)
        }
        if let token = CatalogHTML.first(#"var token = "([^"]*)""#, in: playHTML), !token.isEmpty {
            raw += (raw.contains("?") ? "&" : "?") + "token=\(token)"
        }
        var stream = try WebCatalogSupport.stream(raw, base: root,
                                                  referer: root + "/",
                                                  userAgent: source.userAgent)
        stream.headers["Origin"] = root
        return stream
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        var probe = CatalogSource(name: "麻豆社",
                                  kind: .madou,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("excerpt"), html.contains("madou") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        if let cats = try? await liveCategories(source: probe, root: base), !cats.isEmpty {
            probe.categories = cats
        }
        return CatalogSource(name: "麻豆社",
                             kind: .madou,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: probe.categories,
                             posterAspect: 4.0 / 3.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    private static func pageSource(_ source: CatalogSource, root: String) -> CatalogSource {
        var copy = source
        copy.referer = root + "/"
        return copy
    }

    /// 站点顶部导航就是一级 / 二级结构：
    /// 平铺链接（麻豆传媒 / 番外 / 花絮 / 热门标签）是一级，
    /// 两个下拉（其他原创/企划、筛选）的菜单项是二级。保持站点原有顺序。
    private static func liveCategories(source: CatalogSource, root: String) async throws -> [CatalogCategory] {
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: pageSource(source, root: root))
        let parsed = parseNavigation(html)
        return parsed.isEmpty ? [] : parsed
    }

    /// 解析 `div.sitenav`：`<li><a href=…>标题</a><ul class="sub-menu">…</ul></li>`。
    /// 正则会把父项连同它的 sub-menu 一起吃掉，所以子项不会被重复当成一级。
    static func parseNavigation(_ html: String) -> [CatalogCategory] {
        guard let nav = CatalogHTML.first(#"<div class="sitenav">([\s\S]*?)<span class="sitenav-on""#,
                                          in: html) else { return [] }
        let pattern = #"<li[^>]*>\s*<a\s+href="([^"]*)"[^>]*>([^<]*)</a>\s*(?:<ul class="sub-menu">([\s\S]*?)</ul>)?"#
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: nav) {
            guard let href = CatalogHTML.first(#"href="([^"]*)""#, in: raw) else { continue }
            let title = CatalogHTML.first(#">([^<]*)</a>"#, in: raw)
                .map(CatalogHTML.stripTags) ?? ""
            guard !title.isEmpty else { continue }
            if let children = CatalogHTML.first(#"<ul class="sub-menu">([\s\S]*?)</ul>"#, in: raw) {
                let items = parseCategoryLinks(children)
                if title.contains("筛选") {
                    // 三个榜单页不是 `category/` 链接，按站点菜单标题直接落到对应路径。
                    result.append(CatalogCategory(id: "filters", title: title,
                                                  children: filterCategories, isGroup: true))
                } else if title.contains("原创") || title.contains("企划") {
                    guard !items.isEmpty else { continue }
                    result.append(CatalogCategory(id: "others", title: title,
                                                  children: items, isGroup: true))
                } else {
                    // 其他下拉暂不展开，避免出现无法识别的空白分组。
                    continue
                }
                continue
            }
            if title == "首页" || href == "/" || href.isEmpty || href == "#" { continue }
            guard let comps = URLComponents(string: href) else { continue }
            let path = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            if path == "tags" {
                result.append(CatalogCategory(id: "tags", title: title,
                                              children: [], isGroup: true))
            } else if path.hasPrefix("category/") {
                result.append(CatalogCategory(id: path, title: title))
            }
        }
        return result
    }

    /// 从一个 `<ul>` 里取站内分类链接（`/category/<slug>`）。
    private static func parseCategoryLinks(_ list: String) -> [CatalogCategory] {
        var items: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in CatalogHTML.fullMatches(#"<a\s+[^>]*href="[^"]*category/[^"]+"[^>]*>[\s\S]*?</a>"#,
                                              in: list) {
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                  let comps = URLComponents(string: href) else { continue }
            let title = CatalogHTML.stripTags(anchor)
            guard !title.isEmpty else { continue }
            let path = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            items.append(CatalogCategory(id: path, title: title))
        }
        return items
    }

    /// 「热门标签」页：`div.tagslist` 里 50 个 `tag/<slug>` 链接。
    static func parseHotTags(_ html: String) -> [CatalogCategory] {
        let pattern = #"<a class="name" href="[^"]*?/tag/([^"]+)">([^<]+)</a>"#
        var items: [CatalogCategory] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let slug = CatalogHTML.first(#"/tag/([^"]+)""#, in: raw),
                  let title = CatalogHTML.first(#">([^<]+)</a>"#, in: raw) else { continue }
            let clean = CatalogHTML.stripTags(title)
            guard !clean.isEmpty, seen.insert(slug).inserted else { continue }
            items.append(CatalogCategory(id: "tag/\(slug)", title: clean))
        }
        return items
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<article class="excerpt\b"#, in: html) {
            guard let href = CatalogHTML.first(#"<h2>\s*<a[^>]+href="([^"]+)""#, in: block)
                    ?? CatalogHTML.first(#"class="?thumbnail"?[^>]+href="([^"]+)""#, in: block),
                  let slug = slug(from: href, base: base),
                  seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"<h2>\s*<a[^>]*>([\s\S]*?)</a>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            guard !title.isEmpty else { continue }
            let rawCover = CatalogHTML.first(#"data-src="([^"]+\.(?:jpg|jpeg|png|webp))""#, in: block) ?? ""
            let views = CatalogHTML.first(#"观看\(([^)]+)\)"#, in: block) ?? ""
            result.append(CatalogItem(id: slug,
                                      title: title,
                                      coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                      remark: views.isEmpty ? "" : "观看 \(views)",
                                      categoryID: nil))
        }
        return result
    }

    /// `https://madou.club/%e5%b7%a8%e4%b9%b3.html` → 保留原来的 percent-encoding，
    /// 不在这里解码，避免拼回详情地址时丢中文。
    private static func slug(from address: String, base: String) -> String? {
        guard let comps = URLComponents(string: address) else { return nil }
        var path = comps.percentEncodedPath
        if path.isEmpty || path == "/" { return nil }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty, !path.hasPrefix("category/"),
              !path.hasPrefix("page/"), !path.hasPrefix("tag/") else { return nil }
        return path
    }

    /// 文章自身所属的系列：站内导航也有大量 `/category/`，只认 `rel="category tag"`。
    private static func categoryTags(_ html: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+rel="category tag"[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty }
    }

    private static func links(_ html: String, path: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+href=[^ >]*\#(path)[^ >]+[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
    }

    private static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.range(of: "/page/\(page + 1)") != nil || html.contains("下一页")
    }
}
