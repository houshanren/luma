import Foundation

/// 行形涉摄（xxss.me）图文站适配器。
///
/// 站点是 WordPress：列表卡片在 `article.preview` 里，缩略图走 `data-src` 懒加载；
/// 详情页正文由章节标题、段落与配图组成，图片地址为 `/wp-content/uploads/...`。
/// 部分文章带视频，但这里按图文处理：详情页展示图集，不强行解析视频。
struct XxssCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://xxss.me"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 站点分类：路径取自导航，保留 WordPress 的百分号编码形式。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "category/figure", title: "形 Figure"),
        CatalogCategory(id: "category/exhibit", title: "摄 Exhibit"),
        CatalogCategory(id: "category/cross", title: "涉 Cross"),
        CatalogCategory(id: "category/%e6%bc%ab-animate", title: "漫 Animate"),
        CatalogCategory(id: "category/%e7%88%b1-ai", title: "爱 AI"),
        CatalogCategory(id: "category/%e7%89%a9-create", title: "物 Create"),
        CatalogCategory(id: "category/%e7%95%aa-fantasy", title: "番 Fantasy"),
        CatalogCategory(id: "category/%e7%9f%a5-learn", title: "知 Learn"),
        CatalogCategory(id: "category/travel", title: "行 Travel")
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await list(source: source, path: nil, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        try await list(source: source, path: nil, page: page)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        return try await list(source: source, path: target.id, page: page)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root)/?s=\(encoded)"
        if page > 1 { address += "&paged=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: html.range(of: "/page/\(page + 1)/") != nil)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        let blocks = Self.parseArticle(html, base: root)
        let images = blocks.compactMap { $0.kind == .image ? $0.text : nil }
        let title = Self.parseTitle(html, fallback: itemID.uppercased())
        let metaCover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let cover = metaCover.isEmpty ? (images.first ?? "") : metaCover

        var facts: [CatalogDetailFact] = []
        if let date = Self.publishedDate(html) {
            facts.append(CatalogDetailFact(label: "发布", value: date))
        }
        if let author = Self.author(html) {
            facts.append(CatalogDetailFact(label: "作者", value: author))
        }
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
        }

        let item = CatalogItem(id: itemID, title: title, coverURL: cover,
                               remark: images.isEmpty ? "" : "\(images.count)P")
        return CatalogDetail(item: item, episodes: [], blocks: blocks, facts: facts,
                             tags: Self.parseTags(html))
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        throw CatalogError.unavailable("图文条目没有可播放的视频")
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 列表

    private func list(source: CatalogSource, path: String?, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        var address = root + (path.map { "/\($0)" } ?? "")
        if page > 1 { address += "/page/\(page)" }
        address += "/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: html.range(of: "/page/\(page + 1)/") != nil)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = try await WebCatalogSupport.fetchHTML(base + "/", source: CatalogSource(
            name: "行形涉摄",
            kind: .xxss,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard probe.contains("wp-content") || probe.lowercased().contains("xxss") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "行形涉摄",
                             kind: .xxss,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 4.0 / 3.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    /// 卡片：`article.preview` 里的标题链接与懒加载缩略图。
    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<article[^>]+class="[^"]*preview[^"]*"[\s\S]*?</article>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }

        let ns = html as NSString
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: match.range)
            guard let href = CatalogHTML.first(#"<h2[^>]+class="[^"]*preview-title[^"]*"[^>]*>[\s\S]*?<a[^>]+href="([^"]+)""#, in: block)
                    ?? CatalogHTML.first(#"<a[^>]+class="[^"]*preview-media-link[^"]*"[^>]+href="([^"]+)""#, in: block),
                  let id = slug(from: href),
                  seen.insert(id).inserted else { continue }

            let rawTitle = CatalogHTML.first(#"<h2[^>]+class="[^"]*preview-title[^"]*"[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block)
                ?? ""
            let title = CatalogHTML.stripTags(rawTitle)
            guard !title.isEmpty else { continue }

            let lazy = CatalogHTML.first(#"<img[^>]+data-src="([^"]+)""#, in: block) ?? ""
            let noscript = CatalogHTML.first(#"<noscript>[\s\S]*?<img[^>]+src="([^"]+)""#, in: block) ?? ""
            var rawCover = lazy.isEmpty ? noscript : lazy
            if rawCover.isEmpty {
                // 首屏第一张卡片直接写真实 src（其余是 data: 占位符，不能当封面）。
                let direct = CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: block) ?? ""
                if direct.hasPrefix("http") { rawCover = direct }
            }

            result.append(CatalogItem(id: id,
                                      title: title,
                                      coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                      remark: "",
                                      categoryID: nil))
        }
        return result
    }

    /// 正文：按出现顺序保留章节标题、段落与配图；同一张图只留一次。
    static func parseArticle(_ html: String, base: String) -> [CatalogContentBlock] {
        let content = articleContent(html)
        let pattern = #"<h2[^>]*>([\s\S]*?)</h2>|<p[^>]*>([\s\S]*?)</p>|<img[^>]+>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = content as NSString
        var blocks: [CatalogContentBlock] = []
        var seenImages = Set<String>()
        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 1).location != NSNotFound {
                let text = CatalogHTML.stripTags(ns.substring(with: match.range(at: 1)))
                if !text.isEmpty {
                    blocks.append(CatalogContentBlock(kind: .heading, text: text))
                }
            } else if match.range(at: 2).location != NSNotFound {
                let text = CatalogHTML.stripTags(ns.substring(with: match.range(at: 2)))
                if !text.isEmpty {
                    blocks.append(CatalogContentBlock(kind: .paragraph, text: text))
                }
            } else {
                let tag = ns.substring(with: match.range)
                guard let fixed = CatalogHTML.bestImageURL(in: tag, base: base),
                      isContentImage(fixed), seenImages.insert(fixed).inserted else { continue }
                blocks.append(CatalogContentBlock(kind: .image, text: fixed))
            }
        }
        return blocks
    }

    /// 只取 `entry-content` 到 `</article>` 之间的正文，避免侧栏与相关推荐的图片混进来。
    private static func articleContent(_ html: String) -> String {
        guard let start = html.range(of: "entry-content") else { return html }
        let end = html.range(of: "</article>", range: start.upperBound..<html.endIndex)
        return String(html[start.lowerBound..<(end?.lowerBound ?? html.endIndex)])
    }

    private static func isContentImage(_ url: String) -> Bool {
        guard url.contains("/wp-content/uploads/") else { return false }
        let lower = (url.split(separator: "?").first.map(String.init) ?? url).lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".avif"].contains { lower.hasSuffix($0) }
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        let heading = CatalogHTML.first(#"<h1[^>]+class="[^"]*entry-title[^"]*"[^>]*>([\s\S]*?)</h1>"#, in: html)
            ?? CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
        let text = heading.map(CatalogHTML.stripTags) ?? ""
        if !text.isEmpty { return text }
        let og = WebCatalogSupport.meta(html, "og:title")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return og.isEmpty ? fallback : og
    }

    private static func publishedDate(_ html: String) -> String? {
        let raw = WebCatalogSupport.meta(html, "article:published_time")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let date = ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        return CatalogHTML.first(#"发布日期：\s*(?:<[^>]+>\s*)*([0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日)"#, in: html)
    }

    private static func author(_ html: String) -> String? {
        let raw = CatalogHTML.first(#"<a[^>]+rel="author"[^>]*>([^<]+)</a>"#, in: html)
            ?? CatalogHTML.first(#"<span[^>]+class="[^"]*author[^"]*"[^>]*>([^<]+)</span>"#, in: html)
        guard let raw else { return nil }
        let text = CatalogHTML.stripTags(raw)
        return text.isEmpty ? nil : text
    }

    /// 标签：优先取正文里的 `/tags/`、`/tag/` 链接，没有时退回 meta keywords。
    static func parseTags(_ html: String) -> [String] {
        var tags: [String] = []
        for pattern in [#"<a[^>]+href="[^"]*/tags/[^"]*"[^>]*>([^<]+)</a>"#,
                        #"<a[^>]+href="[^"]*/tag/[^"]*"[^>]*>([^<]+)</a>"#] {
            for raw in CatalogHTML.fullMatches(pattern, in: html) {
                guard let text = CatalogHTML.first(pattern, in: raw) else { continue }
                let value = CatalogHTML.stripTags(text)
                guard !value.isEmpty else { continue }
                tags.append(value)
            }
        }
        if tags.isEmpty {
            tags = WebCatalogSupport.meta(html, "keywords")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return WebCatalogSupport.unique(tags)
    }

    /// 卡片链接转条目 id：只接受根级 slug（如 `xs220`）。
    static func slug(from href: String) -> String? {
        let address = href.hasPrefix("http") ? href : "https://xxss.me" + (href.hasPrefix("/") ? href : "/" + href)
        guard let components = URLComponents(string: address) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 1, let value = parts.first, !value.isEmpty else { return nil }
        let reserved: Set<String> = ["category", "page", "tag", "tags", "author",
                                     "xmap", "fav", "feed", "wp-json", "wp-content"]
        return reserved.contains(value.lowercased()) ? nil : value
    }
}
