import Foundation

/// 91图图（91tutu.cc）适配器。
///
/// Astro 静态站：列表是 `/posts/{slug}/` 卡片，详情正文一次性内联全部 webp 图片；
/// 文章页有 `/tags/{标签}/{页码}/` 标签入口，直接作为标签展示。
struct NinetyOneTutuCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://91tutu.cc"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        // 标签：站点有几百个标签，频道页用搜索 + 分页的标签墙展示。
        CatalogCategory(id: "tags", title: "标签", isTagWall: true),
        // 尺度：三个站点给出的尺度分类，各自是独立列表页。
        CatalogCategory(id: "scales", title: "尺度", children: [
            CatalogCategory(id: "scale:healthy", title: "健康"),
            CatalogCategory(id: "scale:borderline", title: "擦边"),
            CatalogCategory(id: "scale:explicit", title: "大尺度")
        ], isGroup: true),
        // 归档：按日期分组、可搜索 / 按月筛选的博文归档。
        CatalogCategory(id: "archive", title: "归档", isArchive: true)
    ]

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    /// 「标签」一级：站点把全量标签内联在 `/tags/` 的 `tagsJson` 里，按数量降序交给标签墙。
    func allTags(source: CatalogSource) async throws -> [CatalogTag] {
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/tags/", source: source)
        else { return [] }
        var tags = Self.parseTagIndex(html)
        tags.sort { lhs, rhs in
            let left = lhs.count ?? 0
            let right = rhs.count ?? 0
            if left != right { return left > right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return tags
    }

    /// 「归档」一级：`/api/archives.json` 一次给全部 1943 篇（日期 + 标题），
    /// 界面端做月份筛选与标题搜索，不需要逐页抓取。
    func archiveEntries(source: CatalogSource) async throws -> [CatalogArchiveEntry] {
        let root = try WebCatalogSupport.root(source)
        guard let raw = try? await WebCatalogSupport.fetchHTML(root + "/api/archives.json",
                                                                source: source),
              let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { dict in
            guard let slug = dict["id"] as? String,
                  let title = dict["title"] as? String,
                  !title.isEmpty else { return nil }
            let day = (dict["pubDate"] as? String) ?? ""
            return CatalogArchiveEntry(id: "posts/\(slug)", title: title, day: day)
        }
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        // 标签墙 / 归档自身不是列表页：标签墙用首页垫底，归档由专门的归档视图承载。
        if category.id == "tags" {
            let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
            let items = Self.parseCards(html, base: root)
            return CatalogPage(items: items, page: 1, hasMore: false)
        }
        if category.id == "archive" {
            return CatalogPage(items: [], page: 1, hasMore: false)
        }
        if category.id.hasPrefix("scale:") {
            let slug = String(category.id.dropFirst("scale:".count))
            return try await Self.scalePage(source: source, root: root,
                                            scale: slug, page: max(1, page))
        }
        if let tag = Self.tagSlug(category.id) {
            let encoded = WebCatalogSupport.pathEncoded(tag) ?? tag
            let address = "\(root)/tags/\(encoded)/\(max(1, page))/"
            let html = try await WebCatalogSupport.fetchHTML(address, source: source)
            let items = Self.parseCards(html, base: root)
            return CatalogPage(items: items, page: page, hasMore: items.count >= 12)
        }
        let slug = category.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !slug.isEmpty else { throw CatalogError.parse("分类地址无效") }
        let address = "\(root)/category/\(slug)/\(max(1, page))/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: items.count >= 12)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        // 站点没有全文搜索：`/tags/{标签}/{页码}/` 是可抓的关键词入口，
        // 但只认完整标签名，所以精确命中不到时再从 sitemap 的标签地址里补找包含关键词的标签。
        let root = try WebCatalogSupport.root(source)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CatalogPage(items: [], page: page, hasMore: false) }
        let current = max(1, page)
        if let encoded = WebCatalogSupport.pathEncoded(trimmed),
           let html = try? await WebCatalogSupport.fetchHTML("\(root)/tags/\(encoded)/\(current)/",
                                                             source: source) {
            let items = Self.parseCards(html, base: root)
            return CatalogPage(items: items, page: page, hasMore: items.count >= 12)
        }
        guard current == 1,
              let sitemap = try? await WebCatalogSupport.fetchHTML(root + "/sitemap-0.xml",
                                                                   source: source),
              let slug = Self.matchingTagSlug(inSitemap: sitemap, keyword: trimmed),
              let html = try? await WebCatalogSupport.fetchHTML("\(root)/tags/\(slug)/1/",
                                                                source: source) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let segment = itemID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let address = "\(root)/\(segment)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        let images = Self.parseImages(html, base: root)
        let title = Self.parseTitle(html, fallback: "图集")
        let metaCover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let cover = metaCover.isEmpty ? (images.first ?? "") : metaCover

        var facts: [CatalogDetailFact] = []
        if let category = CatalogHTML.first(#"分类[:：]\s*(?:<[^>]+>\s*)*([^<·\n]+)"#, in: html)
            .map(CatalogHTML.stripTags), !category.isEmpty {
            facts.append(CatalogDetailFact(label: "分类", value: category))
        }
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
        }
        if let date = CatalogHTML.first(#"(20\d{2}-\d{2}-\d{2})"#, in: html) {
            facts.append(CatalogDetailFact(label: "发布", value: date))
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
                             tags: Self.parseTags(html))
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
            name: "91图图",
            kind: .ninetyOneTutu,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard probe.contains("/posts/") || probe.contains("91tutu") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "91图图",
                             kind: .ninetyOneTutu,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 标签

    /// `/tags/` 把全量标签内联在 `const tagsJson = "…"` 里：
    /// `[{"tag":"宫本桜","count":1,"lastDate":…,"coverUrl":…}]`。
    static func parseTagIndex(_ html: String) -> [CatalogTag] {
        guard let literal = jsStringLiteral(after: "const tagsJson = ", in: html),
              let data = literal.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var items: [CatalogTag] = []
        var seen = Set<String>()
        for dict in array {
            guard let tag = dict["tag"] as? String,
                  !tag.isEmpty, seen.insert(tag).inserted else { continue }
            items.append(CatalogTag(id: "tag:\(tag)",
                                    title: tag,
                                    count: dict["count"] as? Int))
        }
        return items
    }

    /// 尺度页：`/api/scale-list/` 给出当页 slug 与分页信息，
    /// 卡片信息（标题 / 封面）从尺度页内联的全量索引里取。
    static func scalePage(source: CatalogSource, root: String, scale: String,
                          page: Int) async throws -> CatalogPage {
        let size = 12
        let address = "\(root)/api/scale-list/?scale=\(scale)&page=\(page)&pageSize=\(size)"
        guard let raw = try? await WebCatalogSupport.fetchHTML(address, source: source),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return CatalogPage(items: [], page: page, hasMore: false) }
        let slugs = dict["slugs"] as? [String] ?? []
        let pagination = dict["pagination"] as? [String: Any]
        let hasMore = pagination?["hasMore"] as? Bool ?? (slugs.count >= size)
        guard !slugs.isEmpty else { return CatalogPage(items: [], page: page, hasMore: false) }

        var index = await TutuScaleIndex.shared.cached(base: root)
        if index == nil {
            let html = (try? await WebCatalogSupport.fetchHTML("\(root)/scale/\(scale)/1/",
                                                               source: source)) ?? ""
            index = await TutuScaleIndex.shared.store(html: html, base: root)
        }
        let items = slugs.compactMap { index?[$0] }
        return CatalogPage(items: items, page: page, hasMore: hasMore && !items.isEmpty)
    }

    /// 尺度页把全量 1943 篇内联在 `const postsJson = "…"` 里（当页内容由前端按 slug 挑选）。
    static func parseScalePosts(_ html: String, base: String) -> [CatalogItem] {
        guard let literal = jsStringLiteral(after: "const postsJson = ", in: html),
              let data = literal.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { dict in
            guard let slug = dict["slug"] as? String,
                  let title = dict["title"] as? String,
                  !slug.isEmpty, !title.isEmpty else { return nil }
            let cover = CatalogHTML.fixURL(dict["cover"] as? String ?? "", base: base)
            let pages = CatalogHTML.first(#"(\d+)\s*P"#, in: title) ?? ""
            return CatalogItem(id: "posts/\(slug)",
                               title: title,
                               coverURL: cover,
                               remark: pages.isEmpty ? "" : "\(pages)P")
        }
    }

    /// 取出 `prefix` 后面那段 JS 双引号字符串，并还原 `\"`、`\\`、`\uXXXX` 等转义。
    static func jsStringLiteral(after prefix: String, in html: String) -> String? {
        guard let start = html.range(of: prefix) else { return nil }
        var index = start.upperBound
        guard index < html.endIndex, html[index] == "\"" else { return nil }
        index = html.index(after: index)
        var result = ""
        var escaped = false
        while index < html.endIndex {
            let character = html[index]
            if escaped {
                switch character {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "u":
                    let hexStart = html.index(after: index)
                    let hexEnd = html.index(hexStart, offsetBy: 4, limitedBy: html.endIndex)
                        ?? html.endIndex
                    let hex = String(html[hexStart..<hexEnd])
                    if let scalar = UInt32(hex, radix: 16),
                       let unicode = Unicode.Scalar(scalar) {
                        result.append(Character(unicode))
                        index = hexEnd
                        escaped = false
                        continue
                    }
                    result.append("\\u")
                default:
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// `tag:半半子` → `半半子`（保留页面里的编码形式）。
    static func tagSlug(_ id: String) -> String? {
        guard id.hasPrefix("tag:") else { return nil }
        let value = String(id.dropFirst(4))
        return value.isEmpty ? nil : value
    }

    /// 从 sitemap 的 `/tags/{标签}/1/` 里找包含关键词的标签，返回页面里的编码形式。
    static func matchingTagSlug(inSitemap xml: String, keyword: String) -> String? {
        let target = keyword.lowercased()
        for raw in CatalogHTML.fullMatches(#"<loc>[^<]*/tags/([^<]+)/1/</loc>"#, in: xml) {
            guard let slug = CatalogHTML.first(#"/tags/([^<]+)/1/</loc>"#, in: raw),
                  !slug.isEmpty else { continue }
            let name = (slug.removingPercentEncoding ?? slug).lowercased()
            if name.contains(target) { return slug }
        }
        return nil
    }

    // MARK: - 解析

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        let pattern = #"<a[^>]+href="(/posts/[^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var entries: [String: CatalogItem] = [:]
        var order: [String] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: match.range(at: 1))
            let id = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let inner = ns.substring(with: match.range(at: 2))

            let rawCover = CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: inner) ?? ""
            let heading = CatalogHTML.first(#"<h[1-6][^>]*>([\s\S]*?)</h[1-6]>"#, in: inner)
                .map(CatalogHTML.stripTags) ?? ""
            let alt = CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: inner) ?? ""
            let title = [heading, alt].first { !$0.isEmpty } ?? ""
            guard !title.isEmpty else { continue }

            let remark = CatalogHTML.first(#"(\d+)\s*P"#, in: title) ?? ""
            let item = CatalogItem(id: id,
                                   title: title,
                                   coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                   remark: remark.isEmpty ? "" : "\(remark)P")
            if var existing = entries[id] {
                if existing.coverURL.isEmpty { existing.coverURL = item.coverURL }
                if existing.title.isEmpty { existing.title = item.title }
                if existing.remark.isEmpty { existing.remark = item.remark }
                entries[id] = existing
            } else {
                entries[id] = item
                order.append(id)
            }
        }
        return order.compactMap { entries[$0] }
    }

    /// 正文图：`image.91tutu.cc/image/...webp`，排除列表用的 cover.webp。
    /// 站点正文可能把缩略图放 `src`，按「最大一张」的规则取地址。
    static func parseImages(_ html: String, base: String) -> [String] {
        var images: [String] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(#"<img[^>]*>"#, in: html) {
            guard let fixed = CatalogHTML.bestImageURL(in: raw, base: base) else { continue }
            let lower = fixed.lowercased()
            guard lower.contains("image.91tutu.cc/image/"),
                  !lower.hasSuffix("/cover.webp"),
                  seen.insert(fixed).inserted else { continue }
            images.append(fixed)
        }
        return images
    }

    static func parseTags(_ html: String) -> [String] {
        var tags: [String] = []
        let pattern = #"<a[^>]+href="/tags/[^"]+"[^>]*>([^<]+)</a>"#
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let text = CatalogHTML.first(pattern, in: raw) else { continue }
            let value = CatalogHTML.stripTags(text)
            guard !value.isEmpty else { continue }
            tags.append(value)
        }
        return WebCatalogSupport.unique(tags)
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        if !heading.isEmpty { return heading }
        let og = WebCatalogSupport.meta(html, "og:title").trimmingCharacters(in: .whitespacesAndNewlines)
        return og.isEmpty ? fallback : og
    }
}

/// 尺度页的卡片索引：站点把全量博文内联在尺度页的 `postsJson` 里（约 1MB），
/// 但页码与当页 slug 由 `/api/scale-list/` 单独给出。全量索引按站点缓存一次，翻页不再重抓。
private actor TutuScaleIndex {
    static let shared = TutuScaleIndex()

    private var base: String?
    private var items: [String: CatalogItem] = [:]

    func cached(base: String) -> [String: CatalogItem]? {
        self.base == base && !items.isEmpty ? items : nil
    }

    func store(html: String, base: String) -> [String: CatalogItem] {
        var map: [String: CatalogItem] = [:]
        for item in NinetyOneTutuCatalogProvider.parseScalePosts(html, base: base) {
            let slug = item.id.hasPrefix("posts/") ? String(item.id.dropFirst(6)) : item.id
            map[slug] = item
        }
        if !map.isEmpty {
            self.base = base
            items = map
        }
        return map
    }
}
