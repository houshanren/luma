import CryptoKit
import Foundation
import WebKit

/// JavCl（`javcl.com`）适配器。
///
/// - 列表：WordPress 服务端渲染，卡片是 `div.video-item`，标题在 `h4.video-title`，
///   封面是 `img.video-thumb` 的 `data-src`，分页 ` /page/N/ `。
/// - 分类：直接读 WP REST 的分类表（`/wp-json/wp/v2/categories`），比解析导航稳定。
/// - 搜索：`/search/<关键词>/page/N/`。
/// - 播放：详情页的播放按钮由前端脚本注入 iframe，直接 GET 拿不到地址；
///   用隐藏的 WKWebView 点一次播放按钮，取出 iframe 里的 slug。
///   真正视频地址是 `https://streamcl.click/m3u8/<md5(slug)>.m3u8`。
struct JavClCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://javcl.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 一级与站点导航一致：分类 / 女优 / 片商 / 热门榜（JAV STREAMING 由统一首页入口承担；
    /// JAV HD 是另一个域名，不并进这个源）。二级在打开时再补。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "group|category", title: "分类", isGroup: true),
        CatalogCategory(id: "group|model", title: "女优", isGroup: true),
        CatalogCategory(id: "group|studio", title: "片商", isGroup: true),
        CatalogCategory(id: "group|top", title: "热门榜",
                        children: topCategories, isGroup: true)
    ]

    private static let topCategories: [CatalogCategory] = [
        CatalogCategory(id: "most-views", title: "最多观看"),
        CatalogCategory(id: "top-100-jav-movies-this-week", title: "本周热榜"),
        CatalogCategory(id: "top-jav-movies-this-month", title: "本月热榜")
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        return await Self.loadTaxonomy(source: source, root: root)
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    /// 二级：分类走 WP 分类表；女优 / 片商抓站点目录第一页（每页 300 个）；
    /// 热门榜固定三条榜单页。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        let probe = Self.pageSource(source, root: root)
        switch category.id {
        case "group|category":
            let live = (try? await Self.liveCategories(source: source, root: root)) ?? []
            return live.map { CatalogCategory(id: $0.id, title: Self.translateCategory($0.title)) }
        case "group|model":
            guard let html = try? await WebCatalogSupport.fetchHTML(root + "/model/", source: probe)
            else { return category.children ?? [] }
            return Self.parseDirectory(html, path: "model")
        case "group|studio":
            guard let html = try? await WebCatalogSupport.fetchHTML(root + "/studio/", source: probe)
            else { return category.children ?? [] }
            return Self.parseDirectory(html, path: "studio")
        case "group|top":
            return Self.topCategories
        default:
            return category.children ?? []
        }
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let address = page > 1 ? "\(root)/page/\(page)/" : root + "/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page) || items.count >= 24)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        let slug = target.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !slug.isEmpty else { throw CatalogError.parse("分类地址无效") }
        // 二级还没加载出来时（例如目录页请求失败）用首页兜底，避免落到无效地址。
        if ["group|category", "group|model", "group|studio", "group|top"].contains(slug) {
            return try await home(source: source, page: page)
        }
        var address = "\(root)/\(slug)/"
        if page > 1 { address += "page/\(page)/" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page) || items.count >= 24)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.pathEncoded(keyword) else {
            throw CatalogError.parse("搜索关键词无效")
        }
        var address = "\(root)/search/\(encoded)/"
        if page > 1 { address += "page/\(page)/" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page) || items.count >= 24)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID)/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? itemID
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let models = Self.links(html, path: "/model/")
        let studios = Self.links(html, path: "/studio/")
        let tags = Self.links(html, path: "/tag/")

        var detail = WebCatalogSupport.singleEpisode(id: itemID,
                                                     title: title,
                                                     cover: cover,
                                                     pageURL: address,
                                                     blocks: WebCatalogSupport.tagBlocks(tags))
        if !models.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "女优",
                                                  value: models.joined(separator: "、")))
        }
        if !studios.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "片商",
                                                  value: studios.joined(separator: "、")))
        }
        if !tags.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "类型",
                                                  value: tags.prefix(6).joined(separator: "、")))
        }
        return detail
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let pageURL = URL(string: episode.pageURL) else {
            throw CatalogError.parse("分集地址无效")
        }
        guard let streamURL = await JavClPlayerResolver.shared.resolve(pageURL: pageURL,
                                                                       cacheKey: episode.pageURL) else {
            throw CatalogError.parse("该条目没有可播放的视频")
        }
        return CatalogStream(url: streamURL,
                             headers: [
                                "User-Agent": source.userAgent,
                                "Referer": "https://streamcl.click/",
                                "Origin": "https://streamcl.click"
                             ],
                             isHLS: true)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        var probe = CatalogSource(name: "JavCl",
                                  kind: .javcl,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: [])
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("video-link") || html.contains("javcl") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        probe.categories = await loadTaxonomy(source: probe, root: base)
        return CatalogSource(name: "JavCl",
                             kind: .javcl,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: probe.categories,
                             posterAspect: 3.0 / 4.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    private static func pageSource(_ source: CatalogSource, root: String) -> CatalogSource {
        var copy = source
        copy.referer = root + "/"
        return copy
    }

    /// 一次抓齐导航里的四块：WP 分类表、女优目录、片商目录、热门榜。
    /// 三个网络请求并发；某一块失败时只空着这一块，不影响其它一级。
    private static func loadTaxonomy(source: CatalogSource, root: String) async -> [CatalogCategory] {
        let probe = pageSource(source, root: root)
        async let wpCategories = try? await liveCategories(source: source, root: root)
        async let modelsHTML = try? await WebCatalogSupport.fetchHTML(root + "/model/", source: probe)
        async let studiosHTML = try? await WebCatalogSupport.fetchHTML(root + "/studio/", source: probe)
        let (wp, modelHTML, studioHTML) = await (wpCategories, modelsHTML, studiosHTML)

        let categories = (wp ?? []).map {
            CatalogCategory(id: $0.id, title: translateCategory($0.title))
        }
        let models = modelHTML.map { parseDirectory($0, path: "model") } ?? []
        let studios = studioHTML.map { parseDirectory($0, path: "studio") } ?? []

        return [
            CatalogCategory(id: "group|category", title: "分类",
                            children: categories, isGroup: true),
            CatalogCategory(id: "group|model", title: "女优",
                            children: models, isGroup: true),
            CatalogCategory(id: "group|studio", title: "片商",
                            children: studios, isGroup: true),
            CatalogCategory(id: "group|top", title: "热门榜",
                            children: topCategories, isGroup: true)
        ]
    }

    /// 女优 / 片商目录里的一个方块：
    /// `<div class="border … btn-dark"><h4><a class=text-white href=…/model/<slug>/ >名字</a> (9)</h4></div>`。
    static func parseDirectory(_ html: String, path: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for block in CatalogHTML.fullMatches(
            #"<div class="border py-1 px-2 m-1 text-center btn-dark">[\s\S]*?</div>"#,
            in: html) {
            guard let slug = CatalogHTML.first(
                #"href=https://[^ ]*/\#(path)/([^/]+)/"#, in: block),
                seen.insert(slug).inserted else { continue }
            let raw = CatalogHTML.first(#"<a[^>]*>([\s\S]*?)</a>"#, in: block) ?? ""
            var title = CatalogHTML.stripTags(raw)
            // 站点在方块末尾附了作品数「(98)」，名册里只留名字。
            if title.hasSuffix(")"), let open = title.lastIndex(of: "("),
               title[title.index(after: open)..<title.index(before: title.endIndex)]
                   .allSatisfy(\.isNumber) {
                title = String(title[..<open])
            }
            while title.hasSuffix(",") || title.hasSuffix(" ") {
                title.removeLast()
            }
            // 站点把「多人的合集标签」也铺成方块（Abe Mikako, Aika Mirei, …），
            // 这不是一个人：塞进女优名册会被当成一个名字，星图也就永远匹配不上。
            guard !title.contains(","), !title.contains("、") else { continue }
            // 有的方块名字带 @ 前缀（用户自建标签），去掉前缀再进名册。
            if title.hasPrefix("@") { title.removeFirst() }
            guard !title.isEmpty else { continue }
            result.append(CatalogCategory(id: "\(path)/\(slug)", title: title))
        }
        return result
    }

    /// 站点分类是英文，二级入口换成中文更顺手；没覆盖的保留原文。
    private static func translateCategory(_ title: String) -> String {
        let key = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let map: [String: String] = [
            "a****": "其他",
            "amateur": "素人", "anal": "肛交", "anchorwoman": "女主播",
            "av actress": "女优", "bbw": "丰满", "big tits": "巨乳",
            "blowjobs": "口交", "bondage": "束缚", "bukkake": "颜射",
            "bus guide": "巴士导游", "censored": "有码", "college girl": "大学生",
            "cowgirl": "骑乘", "creampie": "中出", "deep throating": "深喉",
            "facials": "颜射", "gangbang": "轮奸", "gay": "男同",
            "handjob": "手交", "hardcore": "硬核", "lesbians": "女同",
            "maid": "女仆", "married woman": "人妻", "massage": "按摩",
            "milf": "熟女", "older sister": "姐姐", "planning": "企划",
            "pregnant": "孕妇", "sailor suit": "水手服", "school girl": "校服",
            "shotacon": "正太", "slender": "苗条", "teacher": "教师",
            "titty fuck": "乳交", "toys": "玩具", "underwear": "内衣",
            "uniform": "制服", "virginity": "处女", "voyeur": "偷窥"
        ]
        return map[key] ?? title
    }

    /// WP REST 分类表：按内容量排序，空分类直接丢掉。
    private static func liveCategories(source: CatalogSource, root: String) async throws -> [CatalogCategory] {
        let address = root + "/wp-json/wp/v2/categories?per_page=100&orderby=count&order=desc"
        let json = try await WebCatalogSupport.fetchHTML(address, source: pageSource(source, root: root))
        guard let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CatalogError.parse("分类解析失败")
        }
        return list.compactMap { entry in
            guard let slug = entry["slug"] as? String, !slug.isEmpty,
                  let name = entry["name"] as? String,
                  (entry["count"] as? Int ?? 0) > 0 else { return nil }
            let title = CatalogHTML.stripTags(name)
            guard !title.isEmpty else { return nil }
            return CatalogCategory(id: slug, title: title)
        }
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"class="?video-item\b"#, in: html) {
            // 第一个链接是详情页；卡片尾部还有一个空的覆盖链接，会被 seen 去重。
            guard let rawHref = CatalogHTML.first(#"href=(?:"|')?([^"' >]+)"#, in: block),
                  let slug = slug(from: rawHref), seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"class="?h6 video-title[^>]*>([\s\S]*?)</h4>"#, in: block)
                .map(CatalogHTML.stripTags)
                ?? CatalogHTML.first(#"<img[\s\S]*?alt="([^"]*)""#, in: block) ?? ""
            guard !title.isEmpty else { continue }
            let rawCover = CatalogHTML.first(#"data-src=(\S+\.(?:jpg|jpeg|png|webp))"#, in: block) ?? ""
            let cover = rawCover.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result.append(CatalogItem(id: slug,
                                      title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: "",
                                      categoryID: nil))
        }
        return result
    }

    /// `path` 后面必须还有一段 slug，才不是顶部导航里的 `/model/` 这类空入口。
    private static func links(_ html: String, path: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+href=[^ >]*\#(path)[^ >]+[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
    }

    private static func slug(from address: String) -> String? {
        guard let comps = URLComponents(string: address) else { return nil }
        var path = comps.path
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, !path.hasPrefix("wp-"), !path.hasPrefix("search") else { return nil }
        return path
    }

    private static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.range(of: "/page/\(page + 1)/") != nil
            || html.range(of: "paged=\(page + 1)") != nil
    }
}

// MARK: - 播放页解析

/// JavCl 的播放按钮会由前端脚本注入一个跨域 iframe，普通 GET 拿不到地址。
/// 这里用一个隐藏的 WKWebView 点一次播放，读出 iframe 里的 slug；
/// 真正的 m3u8 是 `streamcl.click/m3u8/<md5(slug)>.m3u8`，只靠 slug 就能拼出来。
@MainActor
final class JavClPlayerResolver {
    static let shared = JavClPlayerResolver()

    private var cache: [String: URL] = [:]
    private var running: [String: Task<URL?, Never>] = [:]

    func resolve(pageURL: URL, cacheKey: String) async -> URL? {
        if let cached = cache[cacheKey] { return cached }
        if let task = running[cacheKey] { return await task.value }
        let task = Task<URL?, Never> { [weak self] in
            let slug = await JavClWebRunner.shared.playSlug(pageURL: pageURL)
            guard let slug, !slug.isEmpty else { return nil }
            let digest = Insecure.MD5.hash(data: Data(slug.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return URL(string: "https://streamcl.click/m3u8/\(digest).m3u8")
        }
        running[cacheKey] = task
        let result = await task.value
        running[cacheKey] = nil
        if let result { cache[cacheKey] = result }
        return result
    }
}

/// 加载详情页 → 点播放 → 轮询 iframe src。
@MainActor
private final class JavClWebRunner: NSObject, WKNavigationDelegate {
    static let shared = JavClWebRunner()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var finished = false

    func playSlug(pageURL: URL) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.finished = false
            self.continuation = continuation
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
                                 configuration: config)
            view.navigationDelegate = self
            webView = view
            view.load(URLRequest(url: pageURL))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self.finish(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let value = await evaluate(Self.clickScript), let slug = Self.slug(from: value) {
                    finish(slug)
                    return
                }
            }
            finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(nil)
    }

    private func evaluate(_ script: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func finish(_ slug: String?) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: slug)
        continuation = nil
        webView?.stopLoading()
        webView = nil
    }

    private static let clickScript = """
    (function(){
      try {
        var box = document.querySelector('#videoPlayer');
        var btn = box ? box.querySelector('.play-button') : document.querySelector('.play-button');
        if (btn) { btn.click(); }
        var frame = box ? box.querySelector('iframe') : document.querySelector('#videoPlayer iframe');
        return frame ? frame.src : '';
      } catch (e) { return ''; }
    })();
    """

    /// `https://streamcl.click/play/<slug>.html` → `<slug>`。
    private static func slug(from address: String) -> String? {
        guard !address.isEmpty, let comps = URLComponents(string: address) else { return nil }
        guard let last = comps.path.split(separator: "/").last else { return nil }
        let value = last.replacingOccurrences(of: ".html", with: "")
        return value.isEmpty ? nil : String(value)
    }
}
