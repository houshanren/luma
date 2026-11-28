import Foundation

/// Tuzac 图集站适配器。
///
/// 列表是 `/file/{slug}/{hash}` 卡片，详情每页 5 张 `image.tuzac.com` 大图，
/// 标签入口有：详情页的 `a.tag` 与 `/all-tags` 标签墙。
struct TuzacCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://www.tuzac.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent
    private static let detailPageSize = 5

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "newest", title: "最新"),
        CatalogCategory(id: "tag:女神", title: "女神"),
        CatalogCategory(id: "tag:美胸", title: "美胸"),
        CatalogCategory(id: "tag:ai美女", title: "AI美女"),
        CatalogCategory(id: "tag:黑丝", title: "黑丝"),
        CatalogCategory(id: "tag:大尺度", title: "大尺度"),
        CatalogCategory(id: "tag:无圣光", title: "无圣光"),
        // 站点的「全部分类」有一千多个标签：作为标签墙节点，频道页用搜索 + 分页展示。
        CatalogCategory(id: "alltags", title: "全部分类", isTagWall: true),
        CatalogCategory(id: "featured", title: "精选")
    ]

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    /// 「全部分类」标签墙：站点每页 120 个标签、约 13 页。这里并发取全量，
    /// 界面端再做搜索与客户端分页，避免把上千个胶囊一次性铺出来。
    func allTags(source: CatalogSource) async throws -> [CatalogTag] {
        let root = try WebCatalogSupport.root(source)
        guard let first = try? await WebCatalogSupport.fetchHTML(root + "/all-tags?sort=4",
                                                                 source: source) else { return [] }
        var raw = Self.parseTagWall(first)
        let pages = min(Self.tagWallPageCount(first), 30)
        if pages > 1 {
            // 分小批并发：一次打十几页容易被 Cloudflare 限流，每批 4 页足够快。
            var collected: [(Int, [CatalogTag])] = []
            var next = 2
            while next <= pages {
                let upper = min(pages, next + 3)
                let batch = await withTaskGroup(of: (Int, [CatalogTag]).self) { group in
                    for page in next...upper {
                        group.addTask {
                            guard let html = try? await WebCatalogSupport.fetchHTML(
                                "\(root)/all-tags/\(page)?sort=4", source: source) else {
                                return (page, [])
                            }
                            return (page, Self.parseTagWall(html))
                        }
                    }
                    var values: [(Int, [CatalogTag])] = []
                    for await value in group { values.append(value) }
                    return values
                }
                collected.append(contentsOf: batch)
                next = upper + 1
            }
            for (_, list) in collected.sorted(by: { $0.0 < $1.0 }) {
                raw.append(contentsOf: list)
            }
        }
        var seen = Set<String>()
        var result: [CatalogTag] = []
        for tag in raw where seen.insert(tag.id).inserted { result.append(tag) }
        return result
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: 1, hasMore: !items.isEmpty)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        guard page > 1 else { return try await home(source: source) }
        return try await list(source: source, path: "newest", page: page)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        // 「全部分类」本体不是列表页：标签墙在频道页展开，列表用最新垫底。
        if category.id == "alltags" {
            return try await list(source: source, path: "newest", page: page)
        }
        if let tag = Self.tagRoute(category.id) {
            return try await list(source: source, path: "tags/\(tag)", page: page)
        }
        let path = category.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw CatalogError.parse("分类地址无效") }
        return try await list(source: source, path: path, page: page)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        // 站内搜索入口是 /search?term=；只有一页，`&page=N` 返回的仍是第一页结果。
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        guard let html = try? await WebCatalogSupport.fetchHTML("\(root)/search?term=\(encoded)",
                                                                source: source) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let segment = itemID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let address = "\(root)/file/\(segment)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        var images = Self.parseImages(html)
        let total = Self.totalCount(html) ?? images.count
        let pages = min(30, max(1, Int(ceil(Double(total) / Double(Self.detailPageSize)))))
        if pages > 1 {
            var seen = Set(images)
            for page in 2...pages {
                guard let more = try? await WebCatalogSupport.fetchHTML("\(address)?at=\(page)",
                                                                        source: source) else { break }
                for url in Self.parseImages(more) where seen.insert(url).inserted {
                    images.append(url)
                }
                if images.count >= total { break }
            }
        }

        let title = Self.parseTitle(html, fallback: "图集")
        let cover = images.first ?? ""
        var facts: [CatalogDetailFact] = []
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
        }
        let tags = Self.parseTags(html)
        if !tags.isEmpty {
            facts.append(CatalogDetailFact(label: "标签", value: "\(tags.count) 个"))
        }

        var blocks: [CatalogContentBlock] = []
        if !images.isEmpty {
            blocks.append(CatalogContentBlock(kind: .paragraph,
                                              text: "共 \(images.count) 张图片 · 点击任意一张进入图集浏览"))
        }
        blocks.append(contentsOf: images.map { CatalogContentBlock(kind: .image, text: $0) })

        let item = CatalogItem(id: segment, title: title, coverURL: cover,
                               remark: images.isEmpty ? "" : "\(images.count)P")
        return CatalogDetail(item: item, episodes: [], blocks: blocks, facts: facts,
                             tags: tags.map { $0.1 })
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        throw CatalogError.unavailable("图集条目没有可播放的视频")
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = try await WebCatalogSupport.fetchHTML(base + "/", source: CatalogSource(
            name: "Tuzac 图集",
            kind: .tuzac,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard probe.contains("/file/") || probe.contains("tuzac") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "Tuzac 图集",
                             kind: .tuzac,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 2.0 / 3.0,
                             isEnabled: false)
    }

    // MARK: - 列表

    private func list(source: CatalogSource, path: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        var address = "\(root)/\(path)"
        if page > 1 { address += "/\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: !items.isEmpty)
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        let pattern = #"<a[^>]+href="[^"]*/file/([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var items: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted else { continue }
            let inner = ns.substring(with: match.range(at: 2))

            let rawCover = CatalogHTML.first(#"<img[^>]+data-src="([^"]+)""#, in: inner)
                ?? CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: inner)
                ?? ""
            guard !rawCover.isEmpty else { continue }
            let alt = CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: inner) ?? ""
            let heading = CatalogHTML.first(#"<h[1-6][^>]*>([\s\S]*?)</h[1-6]>"#, in: inner)
                .map(CatalogHTML.stripTags) ?? ""
            let title = [alt, heading].first { !$0.isEmpty } ?? ""
            guard !title.isEmpty else { continue }
            let remark = CatalogHTML.first(#"(\d+)\s*P"#, in: CatalogHTML.stripTags(inner)) ?? ""

            items.append(CatalogItem(id: id,
                                     title: title,
                                     coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                     remark: remark.isEmpty ? "" : "\(remark)P"))
        }
        return items
    }

    // MARK: - 详情

    static func parseImages(_ html: String) -> [String] {
        var images: [String] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(#"<img[^>]+data-photo-num="\d+"[^>]*>"#, in: html) {
            guard let fixed = CatalogHTML.bestImageURL(in: raw, base: "https://image.tuzac.com"),
                  fixed.contains("tuzac.com"), seen.insert(fixed).inserted else { continue }
            images.append(fixed)
        }
        return images
    }

    /// 标签：详情页顶部与底部各有一份 `div.file-tags a.tag`，去重后保留 (slug, 名称)。
    static func parseTags(_ html: String) -> [(String, String)] {
        let pattern = #"<a[^>]+class="tag"[^>]+href="[^"]*/tags/([^"]+)"[^>]*>([\s\S]*?)</a>"#
        var result: [(String, String)] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let slug = CatalogHTML.first(#"href="[^"]*/tags/([^"]+)""#, in: raw),
                  let text = CatalogHTML.first(#">([\s\S]*?)</a>"#, in: raw)
            else { continue }
            let name = CatalogHTML.stripTags(text)
            guard !slug.isEmpty, !name.isEmpty, seen.insert(slug).inserted else { continue }
            result.append((slug, name))
        }
        return result
    }

    /// `/all-tags` 标签墙：`标签名 (数量)`。
    static func parseTagWall(_ html: String, limit: Int = 500) -> [CatalogTag] {
        let pattern = #"<article[^>]+class="[^"]*tag-name[^"]*"[\s\S]*?href="[^"]*/tags/([^"]+)"[^>]*>([\s\S]*?)</a>"#
        var items: [CatalogTag] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let slug = CatalogHTML.first(#"href="[^"]*/tags/([^"]+)""#, in: raw),
                  let text = CatalogHTML.first(#">([\s\S]*?)</a>"#, in: raw)
            else { continue }
            let value = CatalogHTML.stripTags(text)
            guard !slug.isEmpty, !value.isEmpty, seen.insert(slug).inserted else { continue }
            let countText = CatalogHTML.first(#"\((\d+)\)"#, in: value) ?? ""
            let count = Int(countText)
            var title = value
            if !countText.isEmpty {
                title = value.replacingOccurrences(of: " (\(countText))", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            items.append(CatalogTag(id: "tag:\(slug)",
                                    title: title.isEmpty ? value : title,
                                    count: count))
            if items.count >= limit { break }
        }
        return items
    }

    /// `/all-tags` 的总页数：末页链接形如 `/all-tags/13?sort=4`。
    static func tagWallPageCount(_ html: String) -> Int {
        let pattern = #"href="[^"]*/all-tags/(\d+)[^"]*""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 1 }
        let ns = html as NSString
        var maxPage = 1
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if let value = Int(ns.substring(with: match.range(at: 1))) {
                maxPage = max(maxPage, value)
            }
        }
        return maxPage
    }

    static func tagRoute(_ id: String) -> String? {
        guard id.hasPrefix("tag:") else { return nil }
        let value = String(id.dropFirst(4))
        return value.isEmpty ? nil : value
    }

    static func totalCount(_ html: String) -> Int? {
        let value = CatalogHTML.first(#"\((\d+)\s*P\)"#, in: html)
            ?? CatalogHTML.first(#"(\d+)\s*P"#, in: CatalogHTML.stripTags(html))
        return value.flatMap(Int.init)
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        // h1 形如「标题 (100P)」，标题里去掉张数后缀。
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: #"\s*\(\d+\s*P\)"#, with: "",
                                       options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map { clean(CatalogHTML.stripTags($0)) } ?? ""
        if !heading.isEmpty { return heading }
        let og = clean(WebCatalogSupport.meta(html, "og:title"))
        return og.isEmpty ? fallback : og
    }
}
