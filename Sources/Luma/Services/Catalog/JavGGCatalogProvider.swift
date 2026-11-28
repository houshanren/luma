import Foundation

/// JavGG（`javgg.com`）适配器。
///
/// - 列表：KVS 站，卡片是 `<li class="thumbs__item">`，标题在链接的 `title`，
///   封面在 `data-original`，时长在 `thumbs__item-duration`。
/// - 翻页：服务端认 `?from=N`（每页 24 条），分类 / 搜索同样带这个参数。
/// - 一级：站点导航 Home / Videos / Categories / Models / Channels。
///   首页由频道页统一的「首页」入口承担，分类里只建另外四项。
/// - 二级：视频页的排序与时长筛选、分类页的 19 个题材、女优页的女优名册、片商页的片商标。
/// - 播放：详情页直接给出 mp4（`_720p.mp4` 带 `v-acctoken`），跟着 302 跳到 CDN，
///   不需要浏览器脚本，也不需要解密。
struct JavGGCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://javgg.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    // MARK: - 一级 / 二级骨架

    /// 视频页的筛选：站点「Filter」弹层里的排序与时长。
    /// 「视频」自己就是默认的最新列表，下面每一项是一条二级筛选入口。
    private static let videoFilters: [CatalogCategory] = [
        CatalogCategory(id: "latest-updates", title: "最新"),
        CatalogCategory(id: "latest-updates?sort_by=rating", title: "高分"),
        CatalogCategory(id: "latest-updates?sort_by=video_viewed", title: "最多观看"),
        CatalogCategory(id: "latest-updates?sort_by=duration", title: "最长"),
        CatalogCategory(id: "latest-updates?duration_from=0&duration_to=300", title: "短片 ≤5 分"),
        CatalogCategory(id: "latest-updates?duration_from=300&duration_to=1200", title: "中片 5–20 分"),
        CatalogCategory(id: "latest-updates?duration_from=1200&duration_to=0", title: "长片 20 分+")
    ]

    /// 分类页的 19 个题材（站点顺序），抓不到实时分类时兜底。
    private static let fallbackCategories: [CatalogCategory] = [
        CatalogCategory(id: "categories/anal", title: "肛交"),
        CatalogCategory(id: "categories/blowjob", title: "口交"),
        CatalogCategory(id: "categories/big-tits", title: "巨乳"),
        CatalogCategory(id: "categories/amateur", title: "素人"),
        CatalogCategory(id: "categories/uncensored", title: "无码"),
        CatalogCategory(id: "categories/cheating", title: "出轨"),
        CatalogCategory(id: "categories/creampie", title: "中出"),
        CatalogCategory(id: "categories/cougar", title: "熟女"),
        CatalogCategory(id: "categories/cuckold", title: "绿帽"),
        CatalogCategory(id: "categories/milf", title: "人妻"),
        CatalogCategory(id: "categories/mature", title: "成熟"),
        CatalogCategory(id: "categories/threesome", title: "3P"),
        CatalogCategory(id: "categories/teen-18", title: "18岁少女"),
        CatalogCategory(id: "categories/squirting", title: "潮吹"),
        CatalogCategory(id: "categories/bukkake", title: "颜射"),
        CatalogCategory(id: "categories/bondage", title: "束缚"),
        CatalogCategory(id: "categories/domination", title: "支配"),
        CatalogCategory(id: "categories/submissive", title: "顺从"),
        CatalogCategory(id: "categories/gangbang", title: "轮奸")
    ]

    /// 片商页的 11 个厂牌（站点顺序），抓不到实时列表时兜底。
    private static let fallbackChannels: [CatalogCategory] = [
        CatalogCategory(id: "channels/10musume", title: "10 MUSUME AV"),
        CatalogCategory(id: "channels/jav-hd", title: "JAV HD"),
        CatalogCategory(id: "channels/siro", title: "SIRO"),
        CatalogCategory(id: "channels/luxu", title: "LUXU"),
        CatalogCategory(id: "channels/gana", title: "GANA"),
        CatalogCategory(id: "channels/prestige-premium", title: "PRESTIGE PREMIUM"),
        CatalogCategory(id: "channels/fc2", title: "FC2 JAV"),
        CatalogCategory(id: "channels/heyzo-av", title: "HEYZO AV"),
        CatalogCategory(id: "channels/tokyo-hot", title: "TOKYO HOT AV"),
        CatalogCategory(id: "channels/1pondo-av", title: "1PONDO AV"),
        CatalogCategory(id: "channels/caribbeancom-av", title: "CARIBBEANCOM AV")
    ]

    /// 没有网络时用于渲染侧边栏骨架。
    /// 一级与站点导航一致；分类 / 片商的二级静态可确定，女优名册打开时再补。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "latest-updates", title: "视频", children: videoFilters),
        CatalogCategory(id: "categories", title: "分类",
                        children: fallbackCategories, isGroup: true),
        CatalogCategory(id: "models", title: "女优", children: [], isGroup: true),
        CatalogCategory(id: "channels", title: "片商",
                        children: fallbackChannels, isGroup: true)
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        return await Self.loadTaxonomy(source: source, root: root)
    }

    /// 一级分组下没有列表页，打开时再补二级：
    /// 「分类」「片商」抓目录页，「女优」抓完整名册，视频页直接给静态筛选。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        let probe = Self.pageSource(source, root: root)
        switch category.id {
        case "latest-updates":
            return Self.videoFilters
        case "categories":
            guard let html = try? await WebCatalogSupport.fetchHTML(root + "/categories/", source: probe)
            else { return category.children ?? Self.fallbackCategories }
            let live = Self.parseDirectory(html, prefix: "categories", translateTitles: true)
            return live.isEmpty ? (category.children ?? Self.fallbackCategories) : live
        case "models":
            guard let html = try? await WebCatalogSupport.fetchHTML(root + "/models/", source: probe)
            else { return category.children ?? [] }
            return Self.parseModels(html)
        case "channels":
            guard let html = try? await WebCatalogSupport.fetchHTML(root + "/channels/", source: probe)
            else { return category.children ?? Self.fallbackChannels }
            let live = Self.parseDirectory(html, prefix: "channels", translateTitles: false)
            return live.isEmpty ? (category.children ?? Self.fallbackChannels) : live
        default:
            return category.children ?? []
        }
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let address = page > 1
            ? "\(root)/latest-updates/?from=\(page)"
            : "\(root)/latest-updates/"
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
        let html = try await WebCatalogSupport.fetchHTML(Self.address(id, root: root, page: page),
                                                         source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.pathEncoded(keyword) else {
            throw CatalogError.parse("搜索关键词无效")
        }
        var address = "\(root)/search/\(encoded)/"
        if page > 1 { address += "?from=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? itemID
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let models = Self.taggedTitles(html, path: "models")
        let channels = Self.taggedTitles(html, path: "channels")
        let tags = Self.taggedTitles(html, path: "tags").map {
            $0.hasPrefix("#") ? String($0.dropFirst()) : $0
        }

        var detail = WebCatalogSupport.singleEpisode(id: itemID,
                                                     title: title,
                                                     cover: cover,
                                                     pageURL: address,
                                                     blocks: WebCatalogSupport.tagBlocks(tags))
        if !models.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "女优",
                                                  value: models.joined(separator: "、")))
        }
        if !channels.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "片商",
                                                  value: channels.joined(separator: "、")))
        }
        if !tags.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "类型",
                                                  value: tags.prefix(6).joined(separator: "、")))
        }
        return detail
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard !episode.pageURL.isEmpty else { throw CatalogError.parse("分集地址无效") }
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(episode.pageURL,
                                                         source: Self.pageSource(source, root: root))
        // 详情页里有多种 mp4：720p 正片（带 token）、hover 预览。优先正片。
        // 结尾必须是 `.mp4` / `.mp4/` / `.mp4?token`，避免把预览图 `xxx.mp4.jpg` 当成视频。
        let urls = CatalogHTML.fullMatches(
            #"https?://[^"'\s<>]+\.mp4(?:\?[^"'\s<>]*|/(?:\?[^"'\s<>]*)?)?"#, in: html)
            .map(Self.decodeEntities)
        let tokened = urls.filter { $0.contains("v-acctoken") }
        guard let raw = tokened.first(where: { $0.contains("_720p.mp4") })
                ?? tokened.first(where: { !$0.contains("_preview") })
                ?? urls.first(where: { !$0.contains("_preview") })
                ?? urls.first else {
            throw CatalogError.parse("该条目没有可播放的视频")
        }
        guard let url = URL(string: raw) else {
            throw CatalogError.parse("视频地址解析失败")
        }
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": root + "/"],
                             isHLS: false)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        var probe = CatalogSource(name: "JavGG",
                                  kind: .javgg,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/latest-updates/", source: probe)
        guard html.contains("thumbs__item") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        probe.categories = await loadTaxonomy(source: probe, root: base)
        return CatalogSource(name: "JavGG",
                             kind: .javgg,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: probe.categories,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 站点结构

    private static func pageSource(_ source: CatalogSource, root: String) -> CatalogSource {
        var copy = source
        copy.referer = root + "/"
        return copy
    }

    /// 一次抓齐三个目录页（分类 / 女优 / 片商）拼出一级 + 二级。
    /// 全部并发；某个目录失败就用静态骨架兜底，不影响其余层级。
    private static func loadTaxonomy(source: CatalogSource, root: String) async -> [CatalogCategory] {
        let probe = pageSource(source, root: root)
        async let categoriesPage = try? await WebCatalogSupport.fetchHTML(root + "/categories/",
                                                                         source: probe)
        async let modelsPage = try? await WebCatalogSupport.fetchHTML(root + "/models/",
                                                                     source: probe)
        async let channelsPage = try? await WebCatalogSupport.fetchHTML(root + "/channels/",
                                                                       source: probe)
        let (categoryHTML, modelHTML, channelHTML) = await (categoriesPage, modelsPage, channelsPage)

        let categories = categoryHTML.map {
            parseDirectory($0, prefix: "categories", translateTitles: true)
        } ?? []
        let models = modelHTML.map(parseModels) ?? []
        let channels = channelHTML.map {
            parseDirectory($0, prefix: "channels", translateTitles: false)
        } ?? []

        return [
            CatalogCategory(id: "latest-updates", title: "视频", children: videoFilters),
            CatalogCategory(id: "categories", title: "分类",
                            children: categories.isEmpty ? fallbackCategories : categories,
                            isGroup: true),
            CatalogCategory(id: "models", title: "女优", children: models, isGroup: true),
            CatalogCategory(id: "channels", title: "片商",
                            children: channels.isEmpty ? fallbackChannels : channels,
                            isGroup: true)
        ]
    }

    /// 分类 / 片商目录页的卡片：`<a href="…/categories/<slug>/" title="Anal">`。
    /// 侧边导航里也有同一批链接，按 path 去重，顺序以页面里第一次出现为准。
    private static func parseDirectory(_ html: String,
                                       prefix: String,
                                       translateTitles: Bool) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        let pattern = #"<a[^>]+href="https?://[^"]*/\#(prefix)/[^"]+"[^>]*>[\s\S]*?</a>"#
        for anchor in CatalogHTML.fullMatches(pattern, in: html) {
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                  let comps = URLComponents(string: href) else { continue }
            let path = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard path.hasPrefix(prefix + "/"), seen.insert(path).inserted else { continue }
            let raw = CatalogHTML.first(#"title="([^"]+)""#, in: anchor) ?? CatalogHTML.stripTags(anchor)
            let title = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let slug = String(path.dropFirst(prefix.count + 1))
            result.append(CatalogCategory(id: path,
                                          title: translateTitles ? translate(slug) : title))
        }
        return result
    }

    /// 女优名册：`<li class="models__item">` 里的头像链接与名字。
    private static func parseModels(_ html: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<li class="models__item\b"#, in: html) {
            guard let href = CatalogHTML.first(#"href="(https?://[^"]+/models/[^"]+)""#, in: block),
                  let comps = URLComponents(string: href) else { continue }
            let path = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard path.hasPrefix("models/"), seen.insert(path).inserted else { continue }
            let raw = CatalogHTML.first(#"class="models__item-name"[^>]*>([^<]+)<"#, in: block)
                ?? CatalogHTML.first(#"title="([^"]+)""#, in: block)
                ?? ""
            let title = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            result.append(CatalogCategory(id: path, title: title))
        }
        return result
    }

    /// 二级分类 id 可能自带筛选参数（`latest-updates?sort_by=rating`）：
    /// 拆成路径与查询串，翻页参数接在后面。
    private static func address(_ id: String, root: String, page: Int) -> String {
        let parts = id.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var query: [String] = []
        if parts.count > 1 {
            query = parts[1].split(separator: "&").map(String.init)
        }
        if page > 1 { query.append("from=\(page)") }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        return "\(root)/\(path)/\(suffix)"
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<li class="?thumbs__item\b"#, in: html) {
            guard let href = CatalogHTML.first(#"href="(https?://[^"]+/video/[^"]+)""#, in: block),
                  let slug = slug(from: href),
                  seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"title="([^"]*)""#, in: block)
                ?? CatalogHTML.first(#"alt="([^"]*)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let rawCover = CatalogHTML.first(#"data-original="([^"]+)""#, in: block)
                ?? CatalogHTML.first(#"data-webp="([^"]+)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#"thumbs__item-duration">([^<]+)<"#, in: block) ?? ""
            result.append(CatalogItem(id: slug,
                                      title: decodeEntities(title),
                                      coverURL: CatalogHTML.fixURL(decodeEntities(rawCover), base: base),
                                      remark: duration,
                                      categoryID: nil))
        }
        return result
    }

    /// `https://javgg.com/video/1024/slug/` → `video/1024/slug`。
    private static func slug(from address: String) -> String? {
        guard let comps = URLComponents(string: address) else { return nil }
        var path = comps.percentEncodedPath
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("video/") else { return nil }
        return path
    }

    /// 详情页里 `models` / `channels` / `tags` 三组标签，优先取链接的 `title`。
    private static func taggedTitles(_ html: String, path: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+href="https?://[^"]*/\#(path)/[^"]+"[^>]*>[\s\S]*?</a>"#, in: html)
            .compactMap { anchor in
                let value = CatalogHTML.first(#"title="([^"]+)""#, in: anchor)
                    ?? CatalogHTML.stripTags(anchor)
                let text = decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
    }

    private static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.contains("from:\(page + 1)") || html.contains("from=\(page + 1)")
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") || text.contains("\\&") else { return text }
        var value = text
            .replacingOccurrences(of: "\\&#34;", with: "\"")
            .replacingOccurrences(of: "\\&#39;", with: "'")
            .replacingOccurrences(of: "\\&quot;", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // 剩下 `&#123;` 这类数字实体统一还原。
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = value as NSString
            let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let digits = ns.substring(with: match.range(at: 1))
                guard let code = UInt32(digits), let scalar = Unicode.Scalar(code) else { continue }
                value = (value as NSString).replacingCharacters(in: match.range,
                                                                 with: String(Character(scalar)))
            }
        }
        return value
    }

    /// 站点分类是英文，二级入口用中文更顺手；没映射的保留原文。
    private static func translate(_ slug: String) -> String {
        let map: [String: String] = [
            "big-tits": "巨乳", "creampie": "中出", "amateur": "素人", "milf": "人妻",
            "anal": "肛交", "bondage": "束缚", "blowjob": "口交", "bukkake": "颜射",
            "cheating": "出轨", "cuckold": "绿帽", "mature": "成熟", "mature-woman": "成熟",
            "gangbang": "轮奸", "cougar": "熟女", "gilf": "高龄熟女",
            "submissive": "顺从", "domination": "支配", "squirting": "潮吹",
            "teen-18": "18岁少女", "threesome": "3P", "uncensored": "无码"
        ]
        return map[slug.lowercased()] ?? slug
    }
}
