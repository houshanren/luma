import Foundation

/// 爱美图集（aimeir5.com）适配器。
///
/// 列表是 `article.album-card` 套图卡片，详情 `#galleryStream` 一次性输出全部原图；
/// 一级导航与站点顶部一致：首页 / 国模套图 / Cosplay / 日韩套图，
/// 首页「热门模特」的整墙标签（`#homeTagsGrid`，约 100 个）作为「热门模特」一级的二级项。
struct AimeirCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://www.aimeir5.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "home", title: "首页"),
        CatalogCategory(id: "guomo", title: "国模套图"),
        CatalogCategory(id: "cosplay", title: "Cosplay"),
        CatalogCategory(id: "rihan", title: "日韩套图"),
        // 热门模特没有独立列表页：点开等于进入第一个模特标签，
        // 模特标签在打开源时从首页「热门模特」墙里补齐。
        CatalogCategory(id: "models", title: "热门模特", children: [], isGroup: true)
    ]

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let fallback = source.categories.isEmpty ? Self.defaultCategories : source.categories
        guard let root = try? WebCatalogSupport.root(source),
              let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source)
        else { return fallback }
        let models = Self.parseModelTags(html).map {
            CatalogCategory(id: "tag:\($0.0)", title: $0.1)
        }
        var list = Self.defaultCategories
        if !models.isEmpty, let index = list.firstIndex(where: { $0.id == "models" }) {
            list[index].children = models
        }
        return list
    }

    /// 「热门模特」的二级项首次没取到时，打开时再补一次。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        guard category.id == "models" else { return category.children ?? [] }
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source)
        else { return [] }
        return Self.parseModelTags(html).map {
            CatalogCategory(id: "tag:\($0.0)", title: $0.1)
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
        // 首页与「热门模特」自身没有独立列表：用首页卡片垫底。
        if category.id == "home" || category.id == "models" {
            guard page <= 1 else { return .empty(page: page) }
            let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
            return CatalogPage(items: Self.parseCards(html, base: root), page: 1, hasMore: false)
        }
        if let tag = Self.tagRoute(category.id) {
            var address = "\(root)/tag/\(tag)/"
            if page > 1 { address += "page/\(page).html" }
            let html = try await WebCatalogSupport.fetchHTML(address, source: source)
            let items = Self.parseCards(html, base: root)
            return CatalogPage(items: items, page: page, hasMore: !items.isEmpty)
        }
        let path = category.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw CatalogError.parse("分类地址无效") }
        var address = "\(root)/\(path)/"
        if page > 1 { address += "page/\(page).html" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: !items.isEmpty)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty(page: page) }
        // 站点自带关键词搜索：`/search?q=…&page=N`，模特 / 机构 / 作品名都能命中。
        // 之前把关键词当标签页（`/tag/<词>/`）去找，只有恰好等于标签名时才有结果，
        // 搜「Lee」这类模特 / 作品名永远是空的。
        if let encoded = WebCatalogSupport.queryEncoded(trimmed) {
            let address = "\(root)/search?q=\(encoded)&page=\(max(1, page))"
            if let html = try? await WebCatalogSupport.fetchHTML(address, source: source) {
                let items = Self.parseCards(html, base: root)
                if !items.isEmpty {
                    // 每页混有 1 张推广卡片（会被 parseCards 跳过），不能按「满 20 条」判断是否还有下一页；
                    // 直接看分页里有没有下一页链接。
                    return CatalogPage(items: items,
                                       page: page,
                                       hasMore: html.contains("/page/\(page + 1).html"))
                }
            }
        }
        // 关键词搜索没有结果时，退回标签页当作「按模特 / 题材找图」的入口。
        guard let encoded = WebCatalogSupport.pathEncoded(trimmed) else { return .empty(page: page) }
        var address = "\(root)/tag/\(encoded)/"
        if page > 1 { address += "page/\(page).html" }
        guard let html = try? await WebCatalogSupport.fetchHTML(address, source: source) else {
            return .empty(page: page)
        }
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: !items.isEmpty && items.count >= 20)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        let images = Self.parseImages(html, base: root)
        let title = Self.parseTitle(html, fallback: "图集")
        let metaCover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let cover = metaCover.isEmpty ? (images.first ?? "") : metaCover

        var facts: [CatalogDetailFact] = []
        if let model = CatalogHTML.first(#"class="[^"]*meta-badge-model[^"]*"[^>]*>([^<]+)<"#, in: html)
            .map(CatalogHTML.stripTags), !model.isEmpty {
            facts.append(CatalogDetailFact(label: "模特", value: model))
        }
        if let agency = CatalogHTML.first(#"class="[^"]*meta-badge-agency[^"]*"[^>]*>([^<]+)<"#, in: html)
            .map(CatalogHTML.stripTags), !agency.isEmpty {
            facts.append(CatalogDetailFact(label: "机构", value: Self.cleanPrefix(agency, "机构")))
        }
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
        }
        if let views = CatalogHTML.first(#"id="viewCountNum"[^>]*>([\d,]+)"#, in: html) {
            facts.append(CatalogDetailFact(label: "浏览", value: views))
        }
        if let date = CatalogHTML.first(#"(\d{4}-\d{2}-\d{2})"#, in: html) {
            facts.append(CatalogDetailFact(label: "发布", value: date))
        }

        var blocks: [CatalogContentBlock] = []
        if !images.isEmpty {
            blocks.append(CatalogContentBlock(kind: .paragraph,
                                              text: "共 \(images.count) 张图片 · 点击任意一张进入图集浏览"))
        }
        blocks.append(contentsOf: images.map { CatalogContentBlock(kind: .image, text: $0) })

        let remark = images.isEmpty ? "" : "\(images.count)P"
        let item = CatalogItem(id: itemID, title: title, coverURL: cover, remark: remark)
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
            name: "爱美图集",
            kind: .aimeir,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard probe.contains("album-card") || probe.contains("/photos/") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "爱美图集",
                             kind: .aimeir,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 3.0 / 4.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        let pattern = #"<article[^>]+class="([^"]*album-card[^"]*)"[^>]*>([\s\S]*?)</article>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var items: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let classes = ns.substring(with: match.range(at: 1))
            guard !classes.contains("promo-album-card") else { continue }
            let inner = ns.substring(with: match.range(at: 2))
            guard let href = CatalogHTML.first(#"<a[^>]+href="([^"]+)""#, in: inner),
                  !href.contains("/go/") else { continue }
            let id = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(id).inserted else { continue }

            let rawCover = CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: inner) ?? ""
            let alt = CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: inner) ?? ""
            let heading = CatalogHTML.first(#"<h[1-6][^>]*>([\s\S]*?)</h[1-6]>"#, in: inner)
                .map(CatalogHTML.stripTags) ?? ""
            let title = !alt.isEmpty ? alt : heading
            guard !title.isEmpty else { continue }

            let remark = CatalogHTML.first(#"(\d+)\s*P"#, in: CatalogHTML.stripTags(inner)) ?? ""
            items.append(CatalogItem(id: id,
                                     title: title,
                                     coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                     remark: remark.isEmpty ? "" : "\(remark)P"))
        }
        return items
    }

    /// 详情原图：`/photos/...` 下的 webp；`cover_*` 是列表封面，排除。
    static func parseImages(_ html: String, base: String) -> [String] {
        var images: [String] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(#"<img[^>]*>"#, in: html) {
            guard let fixed = CatalogHTML.bestImageURL(in: raw, base: base) else { continue }
            let lower = fixed.lowercased()
            guard lower.contains("/photos/"),
                  !lower.contains("/cover_"),
                  !seen.contains(fixed) else { continue }
            seen.insert(fixed)
            images.append(fixed)
        }
        return images
    }

    static func parseTags(_ html: String) -> [String] {
        parseTagLinks(html).map { $0.1 }
    }

    /// 首页「热门模特」墙：`#homeTagsGrid` 里一次性铺好全部模特标签（约 100 个），
    /// 「展开全部模特」只是展开折叠容器，不需要额外请求。
    static func parseModelTags(_ html: String) -> [(String, String)] {
        guard let start = html.range(of: "id=\"homeTagsGrid\""),
              let end = html.range(of: "</section>", range: start.upperBound..<html.endIndex)
        else { return [] }
        return parseTagLinks(String(html[start.upperBound..<end.lowerBound]))
    }

    /// `/tag/{urlencoded}/` → (编码后的 slug, 显示名)
    static func parseTagLinks(_ html: String) -> [(String, String)] {
        let pattern = #"<a[^>]+href="/tag/([^"/]+)/"[^>]*>([^<]+)</a>"#
        var result: [(String, String)] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let slug = CatalogHTML.first(#"href="/tag/([^"/]+)/""#, in: raw),
                  let text = CatalogHTML.first(#">([^<]+)</a>"#, in: raw)
            else { continue }
            let name = CatalogHTML.stripTags(text)
            guard !slug.isEmpty, !name.isEmpty, seen.insert(slug).inserted else { continue }
            result.append((slug, name))
        }
        return result
    }

    /// `tag:%E6%A8%A1%E7%89%B9/` → `%E6%A8%A1%E7%89%B9`
    static func tagRoute(_ id: String) -> String? {
        guard id.hasPrefix("tag:") else { return nil }
        let value = String(id.dropFirst(4))
        return value.isEmpty ? nil : value
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        if !heading.isEmpty { return heading }
        let og = WebCatalogSupport.meta(html, "og:title").trimmingCharacters(in: .whitespacesAndNewlines)
        return og.isEmpty ? fallback : og
    }

    private static func cleanPrefix(_ text: String, _ prefix: String) -> String {
        var value = text
        for mark in ["\(prefix):", "\(prefix)："] where value.hasPrefix(mark) {
            value.removeFirst(mark.count)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CatalogPage {
    static func empty(page: Int) -> CatalogPage {
        CatalogPage(items: [], page: page, hasMore: false)
    }
}
