import Foundation

/// V2PH 图集站适配器。
///
/// 列表卡片是 `/album/{id}.html`，缩略图在 `cdn.v2ph.com/album/`；
/// 详情首屏直接给出 `cdn.v2ph.com/photos/` 原图（游客只能看第一页 10 张，后续需要登录）。
struct V2PHCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://www.v2ph.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        guard let root = try? WebCatalogSupport.root(source) else { return source.categories }
        if let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source) {
            let live = Self.parseCategories(html)
            if !live.isEmpty { return live }
        }
        return source.categories
    }

    /// 首页的筛选入口分三类：标签（/category）、模特（/actor）、机构（/company）。
    func tagGroups(source: CatalogSource,
                   category: CatalogCategory?) async throws -> [CatalogTagGroup] {
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source)
        else { return [] }
        var groups: [CatalogTagGroup] = []
        let categories = Self.parseCategories(html)
        if !categories.isEmpty {
            groups.append(CatalogTagGroup(id: "category", title: "标签",
                                          items: categories.map {
                                              CatalogTag(id: "tag:category:\($0.id)", title: $0.title)
                                          }))
        }
        let actors = Self.parseLinks(html, prefix: "/actor/").prefix(24)
        if !actors.isEmpty {
            groups.append(CatalogTagGroup(id: "actor", title: "模特",
                                          items: actors.map {
                                              CatalogTag(id: "tag:actor:\($0.0)", title: $0.1)
                                          }))
        }
        let companies = Self.parseLinks(html, prefix: "/company/").prefix(24)
        if !companies.isEmpty {
            groups.append(CatalogTagGroup(id: "company", title: "机构",
                                          items: companies.map {
                                              CatalogTag(id: "tag:company:\($0.0)", title: $0.1)
                                          }))
        }
        return groups
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
        let dimension: String
        let slug: String
        if let route = Self.parseTagRoute(category.id) {
            dimension = route.dimension
            slug = route.slug
        } else {
            dimension = "category"
            slug = category.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard !slug.isEmpty else { throw CatalogError.parse("分类地址无效") }
        var address = "\(root)/\(dimension)/\(slug)"
        if page > 1 { address += "?page=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: html.range(of: "?page=\(page + 1)") != nil || items.count >= 16)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        // 站内搜索是 `/search/?q=关键字&page=N`；站点带 Cloudflare，
        // 需要先过一次验证（「粘贴 Cookie…」里可以带上浏览器里的 cf_clearance）。
        let root = try WebCatalogSupport.root(source)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let encoded = WebCatalogSupport.queryEncoded(trimmed) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        var address = "\(root)/search/?q=\(encoded)"
        if page > 1 { address += "&page=\(page)" }
        do {
            let html = try await WebCatalogSupport.fetchHTML(address, source: source)
            let items = Self.parseCards(html, base: root)
            return CatalogPage(items: items, page: page,
                               hasMore: html.range(of: "page=\(page + 1)") != nil)
        } catch let error as CatalogError {
            if case .http(let status) = error, status == 403 || status == 492 {
                throw CatalogError.authRequired("搜索前需要过一次 Cloudflare 校验：右键该站点选「粘贴 Cookie…」。")
            }
            throw error
        }
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let segment = itemID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let address = segment.contains(".html") ? "\(root)/album/\(segment)" : "\(root)/album/\(segment).html"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        let images = Self.parseImages(html, base: root)
        let title = Self.parseTitle(html, fallback: "图集")
        let metaCover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let cover = metaCover.isEmpty ? (images.first ?? "") : metaCover

        var tags: [String] = []
        var facts: [CatalogDetailFact] = []
        if let model = Self.firstLink(html, prefix: "/actor/") {
            facts.append(CatalogDetailFact(label: "模特", value: model))
            tags.append(model)
        }
        if let company = Self.firstLink(html, prefix: "/company/") {
            facts.append(CatalogDetailFact(label: "机构", value: company))
            tags.append(company)
        }
        let categories = Self.allLinks(html, prefix: "/category/")
        if !categories.isEmpty {
            facts.append(CatalogDetailFact(label: "标签", value: categories.joined(separator: " · ")))
            tags.append(contentsOf: categories)
        }
        if let date = CatalogHTML.first(#"日期[^0-9]{0,40}(\d{4}-\d{2}-\d{2})"#, in: html) {
            facts.append(CatalogDetailFact(label: "发布", value: date))
        }
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
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
                             tags: WebCatalogSupport.unique(tags))
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
        do {
            let probe = try await WebCatalogSupport.fetchHTML(base + "/", source: CatalogSource(
                name: "V2PH 图集",
                kind: .v2ph,
                baseURL: base,
                userAgent: defaultUserAgent,
                referer: base + "/",
                categories: []
            ))
            guard probe.contains("cdn.v2ph.com") || probe.contains("/album/") else {
                throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
            }
        } catch let error as CatalogError {
            // Cloudflare 的 JS 挑战会返回 403 验证页：允许先入库，再在编辑里填 cf_clearance Cookie。
            if case .http(let status) = error, status == 403 || status == 492 {
                // 继续往下生成来源
            } else {
                throw error
            }
        }
        return CatalogSource(name: "V2PH 图集",
                             kind: .v2ph,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: [],
                             posterAspect: 2.0 / 3.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    /// 列表：`/album/` 链接里带封面图的那一段，标题与张数在同一张卡片后续文本里。
    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        let pattern = #"<a[^>]+href="/album/([^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var entries: [String: CatalogItem] = [:]
        var order: [String] = []
        for (index, match) in matches.enumerated() {
            // 搜索页的链接带 `?hl=` 语言参数，只保留相册 ID。
            let id = ns.substring(with: match.range(at: 1)).split(separator: "?").first.map(String.init) ?? ""
            guard !id.isEmpty else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard end > start else { continue }
            let chunk = ns.substring(with: NSRange(location: start, length: end - start))

            // 搜索页的封面是懒加载：`src` 是占位图，真实地址在 `data-src` 上。
            let rawCover = CatalogHTML.first(#"<img[^>]+data-src="([^"]+)""#, in: chunk)
                ?? CatalogHTML.first(#"<img[^>]+src="([^"]+)"#, in: chunk) ?? ""
            let cover = CatalogHTML.fixURL(rawCover, base: base)
            guard cover.contains("cdn.v2ph.com/album/") else { continue }

            let alt = CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: chunk) ?? ""
            let heading = CatalogHTML.first(#"<h[1-6][^>]*>([\s\S]*?)</h[1-6]>"#, in: chunk)
                .map(CatalogHTML.stripTags) ?? ""
            let title = [alt, heading].first { !$0.isEmpty } ?? "相册"
            let remark = CatalogHTML.first(#"(\d+)\s*P"#, in: CatalogHTML.stripTags(chunk)) ?? ""

            let item = CatalogItem(id: id,
                                   title: title,
                                   coverURL: cover,
                                   remark: remark.isEmpty ? "" : "\(remark)P")
            if var existing = entries[id] {
                if existing.coverURL.isEmpty { existing.coverURL = item.coverURL }
                if existing.title.isEmpty || existing.title == "相册" { existing.title = item.title }
                if existing.remark.isEmpty { existing.remark = item.remark }
                entries[id] = existing
            } else {
                entries[id] = item
                order.append(id)
            }
        }
        return order.compactMap { entries[$0] }
    }

    static func parseImages(_ html: String, base: String) -> [String] {
        var images: [String] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(#"<img[^>]*>"#, in: html) {
            guard let fixed = CatalogHTML.bestImageURL(in: raw, base: base) else { continue }
            guard fixed.contains("cdn.v2ph.com/photos/"),
                  seen.insert(fixed).inserted else { continue }
            images.append(fixed)
        }
        return images
    }

    static func parseCategories(_ html: String) -> [CatalogCategory] {
        parseLinks(html, prefix: "/category/", limit: 24).map {
            CatalogCategory(id: $0.0, title: $0.1)
        }
    }

    /// `/actor/`、`/company/`、`/category/` 通用：返回 (slug, 显示名)。
    static func parseLinks(_ html: String, prefix: String,
                           limit: Int = 40) -> [(String, String)] {
        let pattern = #"<a[^>]+href="\#(prefix)([^"]+)"[^>]*>([\s\S]*?)</a>"#
        var result: [(String, String)] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let slug = CatalogHTML.first(#"href="\#(prefix)([^"]+)""#, in: raw),
                  let text = CatalogHTML.first(#">([\s\S]*?)</a>"#, in: raw)
            else { continue }
            let name = CatalogHTML.stripTags(text)
            guard !slug.isEmpty, !name.isEmpty, seen.insert(slug).inserted else { continue }
            result.append((slug, name))
            if result.count >= limit { break }
        }
        return result
    }

    /// `tag:actor:Yoko-ZaiXia` → (actor, Yoko-ZaiXia)
    static func parseTagRoute(_ id: String) -> (dimension: String, slug: String)? {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "tag",
              ["category", "actor", "company"].contains(parts[1]),
              !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        if !heading.isEmpty { return heading }
        let og = WebCatalogSupport.meta(html, "og:title").trimmingCharacters(in: .whitespacesAndNewlines)
        return og.isEmpty ? fallback : og
    }

    private static func firstLink(_ html: String, prefix: String) -> String? {
        let pattern = #"<a[^>]+href="[^"]*\#(prefix)[^"]*"[^>]*>([^<]+)</a>"#
        guard let text = CatalogHTML.first(pattern, in: html) else { return nil }
        let value = CatalogHTML.stripTags(text)
        return value.isEmpty ? nil : value
    }

    private static func allLinks(_ html: String, prefix: String) -> [String] {
        var result: [String] = []
        for raw in CatalogHTML.fullMatches(#"<a[^>]+href="[^"]*\#(prefix)[^"]*"[^>]*>([^<]+)</a>"#, in: html) {
            let pattern = #"<a[^>]+href="[^"]*\#(prefix)[^"]*"[^>]*>([^<]+)</a>"#
            guard let text = CatalogHTML.first(pattern, in: raw) else { continue }
            let value = CatalogHTML.stripTags(text)
            guard !value.isEmpty else { continue }
            result.append(value)
        }
        return WebCatalogSupport.unique(result)
    }
}
