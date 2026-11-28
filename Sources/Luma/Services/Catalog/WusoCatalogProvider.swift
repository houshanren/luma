import Foundation

/// Wuso 论坛适配器（Discuz）。
///
/// 综合站：圖文板块的帖子列表在 `forum-<板块>-<页码>.html`，帖子详情里是附件图；
/// 影音板块（`forum.php?gid=40`）用瀑布流模板，帖子内是会员专享播放器。
/// 游客只能拿到 200x200 预览图与视频封面（原图 / 播放地址需要登录），
/// 这里如实展示可见内容，并在详情里提示需要会员。
struct WusoCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://wuso.me"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 板块顺序与站点导航一致：影音在前（`forum.php?gid=40`），圖文在后。
    /// 不放进分组节点：板块各自有「类型」筛选，分组会丢掉这个二级标签。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "forum-286", title: "成人影音"),
        CatalogCategory(id: "forum-1141", title: "亞洲線上"),
        CatalogCategory(id: "forum-123", title: "HD有碼日韓影音"),
        CatalogCategory(id: "forum-1367", title: "無碼日韓AV"),
        CatalogCategory(id: "forum-1402", title: "AI短劇"),
        CatalogCategory(id: "forum-1370", title: "頂級影音"),
        CatalogCategory(id: "forum-westav", title: "歐美線上"),
        CatalogCategory(id: "forum-photos", title: "套圖線上看"),
        CatalogCategory(id: "forum-novel", title: "情色文學"),
        CatalogCategory(id: "forum-sextoy", title: "情趣專區"),
        CatalogCategory(id: "forum-144", title: "漫畫區")
    ]

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        // 升级前入库的来源目录是旧版混排（图文 + 分组 + 影音）：不是当前这套就整体换新。
        let ids = Self.defaultCategories.map(\.id)
        if source.categories.map(\.id) == ids { return source.categories }
        return Self.defaultCategories
    }

    /// 板块页顶部那排「優質套圖 / 性感誘惑 / 絲襪…」就是 Discuz 的类型筛选，带帖子数。
    func tagGroups(source: CatalogSource,
                   category: CatalogCategory?) async throws -> [CatalogTagGroup] {
        let board = category?.id ?? "forum-photos"
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML("\(root)/\(board)-1.html",
                                                                 source: source) else { return [] }
        let items = Self.parseTypeFilters(html, board: board)
        guard !items.isEmpty else { return [] }
        return [CatalogTagGroup(id: "types", title: "分类", items: items)]
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/forum-photos-1.html", source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: 1, hasMore: !items.isEmpty)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        try await boardPage(source: source, board: "forum-photos", page: page)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        if let route = Self.parseTypeRoute(category.id) {
            let root = try WebCatalogSupport.root(source)
            let fid = Self.fid(for: route.board)
            var address = "\(root)/forum.php?mod=forumdisplay&fid=\(fid)"
                + "&filter=typeid&typeid=\(route.typeid)"
            if page > 1 { address += "&page=\(page)" }
            let html = try await WebCatalogSupport.fetchHTML(address, source: source)
            let items = Self.parseCards(html, base: root)
            return CatalogPage(items: items, page: page, hasMore: !items.isEmpty)
        }
        let board = category.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !board.isEmpty else { throw CatalogError.parse("板块地址无效") }
        return try await boardPage(source: source, board: board, page: page)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        // Discuz X3.5 的搜索权限按用户组控制：游客会直接被拦成
        // 「您所在的用户组(游客)无法进行此操作」，先在浏览器登录后「粘贴 Cookie」再搜。
        // 登录后带 searchsubmit 的 GET 就会执行搜索，并 302 到结果页（请求会自动跟随）。
        let root = try WebCatalogSupport.root(source)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard page <= 1, !trimmed.isEmpty,
              let encoded = WebCatalogSupport.queryEncoded(trimmed) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let address = "\(root)/search.php?mod=forum&srchtxt=\(encoded)"
            + "&searchsubmit=true&source=hotsearch"
        guard let html = try? await WebCatalogSupport.fetchHTML(address, source: source) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        if html.contains("您所在的用戶組") || html.contains("您所在的用户组") {
            throw CatalogError.authRequired("搜索需要登录：在浏览器登录后右键该站点选「粘贴 Cookie…」再试。")
        }
        let items = Self.parseSearchResults(html)
        // 搜索结果按 searchid 分页，跨调用拿不到同一个 searchid，先只给第一页。
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let tid = itemID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let address = "\(root)/thread-\(tid)-1-1.html"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        if Self.isLoginWall(html) {
            throw CatalogError.authRequired("帖子详情需要登录后才能查看：右键该站点选「粘贴 Cookie…」保存登录状态。")
        }

        let images = Self.parseImages(html, base: root)
        let title = Self.parseTitle(html, fallback: "帖子 \(tid)")
        let metaCover = Self.absoluteURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let tags = Self.parseTags(html)

        // 影音帖：游客页只有「暢遊會員才能播放」的遮罩与封面，playable 为空。
        if Self.isVideoThread(html) {
            var video = Self.parseVideo(html, base: root)
            if video == nil { video = await Self.resolveEmbedVideo(html, source: source) }
            var cover = Self.videoPoster(html, base: root)
            if let video, !video.poster.isEmpty { cover = video.poster }
            if cover.isEmpty { cover = metaCover }
            var facts = [CatalogDetailFact(label: "视频", value: video == nil ? "暢遊會員" : "1 个")]
            if video == nil {
                facts.append(CatalogDetailFact(label: "提示", value: "游客仅可见封面"))
            }
            let episodes = video.map {
                [CatalogEpisode(index: 1, pageURL: $0.url,
                                coverURL: cover, name: "视频")]
            } ?? []
            let item = CatalogItem(id: tid, title: title, coverURL: cover,
                                   remark: "", mediaKind: .video)
            return CatalogDetail(item: item, episodes: episodes, blocks: [],
                                 facts: facts, tags: tags)
        }

        let cover = metaCover.isEmpty ? (images.first ?? "") : metaCover

        var facts: [CatalogDetailFact] = []
        if !images.isEmpty {
            facts.append(CatalogDetailFact(label: "图片", value: "\(images.count) 张"))
        }
        if !images.isEmpty, images.allSatisfy({ $0.contains("_200_200") }) {
            facts.append(CatalogDetailFact(label: "提示", value: "游客仅可见预览图"))
        }

        var blocks: [CatalogContentBlock] = []
        if !images.isEmpty {
            blocks.append(CatalogContentBlock(kind: .paragraph,
                                              text: "共 \(images.count) 张图片 · 点击任意一张进入图集浏览"))
        }
        blocks.append(contentsOf: images.map { CatalogContentBlock(kind: .image, text: $0) })

        let item = CatalogItem(id: tid, title: title, coverURL: cover,
                               remark: images.isEmpty ? "" : "\(images.count)P",
                               mediaKind: .gallery)
        return CatalogDetail(item: item, episodes: [], blocks: blocks, facts: facts,
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
        let probe = try await WebCatalogSupport.fetchHTML(base + "/forum-photos-1.html",
                                                          source: CatalogSource(
            name: "Wuso 论坛",
            kind: .wuso,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard probe.contains("normalthread") || probe.contains("thread-") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        return CatalogSource(name: "Wuso 论坛",
                             kind: .wuso,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: defaultCategories,
                             posterAspect: 2.0 / 3.0,
                             isEnabled: false)
    }

    // MARK: - 标签

    /// 板块类型筛选：`filter=typeid&typeid=<id>`，文字后面跟帖子数。
    static func parseTypeFilters(_ html: String, board: String) -> [CatalogTag] {
        let pattern = #"<a[^>]+href="[^"]*filter=typeid(?:&amp;|&)typeid=(\d+)[^"]*"[^>]*>([\s\S]*?)</a>"#
        var items: [CatalogTag] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: html) {
            guard let typeid = CatalogHTML.first(#"typeid=(\d+)"#, in: raw) else { continue }
            let text = CatalogHTML.stripTags(raw)
            guard !text.isEmpty, seen.insert(typeid).inserted else { continue }
            let digits = CatalogHTML.first(#"(\d[\d,]*)\s*$"#, in: text) ?? ""
            let count = Int(digits.replacingOccurrences(of: ",", with: ""))
            var title = text
            if !digits.isEmpty {
                title = String(text.dropLast(digits.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            items.append(CatalogTag(id: "type:\(board):\(typeid)",
                                    title: title.isEmpty ? "类型 \(typeid)" : title,
                                    count: count))
        }
        return items
    }

    static func parseTypeRoute(_ id: String) -> (board: String, typeid: String)? {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "type",
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }

    static func fid(for board: String) -> String {
        switch board {
        case "forum-novel": return "46"
        case "forum-photos": return "48"
        case "forum-sextoy": return "71"
        case "forum-144": return "144"
        // 地址用别名的板块，板块号与地址无关，需要单独记。
        case "forum-westav": return "42"
        default:
            // 影音板块的板块号与地址一致：forum-286 → fid=286。
            if board.hasPrefix("forum-") { return String(board.dropFirst(6)) }
            return "48"
        }
    }

    // MARK: - 列表

    private func boardPage(source: CatalogSource, board: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(board)-\(max(1, page)).html"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: !items.isEmpty)
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var items: [CatalogItem] = []
        var seen = Set<String>()
        // 圖文板块：Discuz 标准列表，卡片里带类型标签。
        let pattern = #"<li[^>]+id="normalthread_(\d+)"[\s\S]*?</li>"#
        if let regex = try? NSRegularExpression(pattern: pattern,
                                                options: [.dotMatchesLineSeparators]) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let tid = ns.substring(with: match.range(at: 1))
                guard seen.insert(tid).inserted else { continue }
                let block = ns.substring(with: match.range)

                let title = CatalogHTML.first(#"<a[^>]+class="[^"]*s xst[^"]*"[^>]*>([\s\S]*?)</a>"#, in: block)
                    .map(CatalogHTML.stripTags)
                    ?? CatalogHTML.first(#"<a[^>]+href="[^"]*thread-\#(tid)-[^"]*"[^>]*>([\s\S]*?)</a>"#, in: block)
                        .map(CatalogHTML.stripTags)
                    ?? ""
                guard !title.isEmpty else { continue }

                let rawCover = CatalogHTML.first(
                    #"class="[^"]*kmimg_box[^"]*"[\s\S]{0,600}?<img[^>]+src="([^"]+)""#, in: block)
                    ?? CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: block)
                    ?? ""
                let cover = Self.absoluteURL(rawCover, base: base)
                let typeTag = CatalogHTML.first(#"class="[^"]*kmfoot_z[^"]*"[\s\S]{0,300}?>([^<>]{1,20})</a>"#,
                                                in: block).map(CatalogHTML.stripTags) ?? ""

                items.append(CatalogItem(id: tid,
                                         title: title,
                                         coverURL: cover,
                                         remark: typeTag,
                                         mediaKind: .gallery))
            }
        }

        // 影音板块：瀑布流模板 `<ul id="waterfall">`，封面在 `.kmpic`，标题在 `.kmtitle`。
        if let region = CatalogHTML.first(#"(<ul[^>]+id="waterfall"[\s\S]*?</ul>)"#, in: html) {
            for block in CatalogHTML.fullMatches(#"<li[^>]*>[\s\S]*?</li>"#, in: region) {
                guard let tid = CatalogHTML.first(#"thread-(\d+)-\d+-\d+\.html"#, in: block),
                      seen.insert(tid).inserted else { continue }
                let title = CatalogHTML.first(#"class="kmtitle"[\s\S]{0,200}?<a[^>]*>([\s\S]*?)</a>"#,
                                              in: block).map(CatalogHTML.stripTags)
                    ?? CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: block) ?? ""
                guard !title.isEmpty else { continue }
                let rawCover = CatalogHTML.first(#"class="kmpic[\s\S]{0,300}?<img[^>]+src="([^"]+)""#,
                                                 in: block) ?? ""
                items.append(CatalogItem(id: tid,
                                         title: title,
                                         coverURL: Self.absoluteURL(rawCover, base: base),
                                         remark: "",
                                         mediaKind: .video))
            }
        }
        return items
    }

    /// 列表封面与附件地址常是相对地址（`forum.php?mod=image&aid=…`）：
    /// `fixURL` 只补以 `/` 开头的，这里统一补成带主机的绝对地址，否则图片请求发不出去。
    static func absoluteURL(_ raw: String, base: String) -> String {
        let fixed = CatalogHTML.fixURL(raw, base: base)
        guard !fixed.isEmpty else { return "" }
        if fixed.lowercased().hasPrefix("http") { return fixed }
        let path = fixed.hasPrefix("/") ? String(fixed.dropFirst()) : fixed
        return base + "/" + path
    }

    /// 搜索结果页（Discuz `search/thread_list` 模板）：
    /// `<li class="pbw" id="tid"><h3 class="xs3"><a href="forum.php?mod=viewthread&tid=…">标题</a>`。
    static func parseSearchResults(_ html: String) -> [CatalogItem] {
        var items: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.fullMatches(#"<li[^>]+class="[^"]*pbw[^"]*"[\s\S]*?</li>"#, in: html) {
            guard let href = CatalogHTML.first(
                    #"<h3[^>]+class="[^"]*xs3[^"]*"[\s\S]*?<a[^>]+href="([^"]+)""#, in: block),
                  let tid = CatalogHTML.first(#"(?:tid=|thread-)(\d+)"#, in: href),
                  seen.insert(tid).inserted,
                  let title = CatalogHTML.first(
                    #"<h3[^>]+class="[^"]*xs3[^"]*"[\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block)
                    .map(CatalogHTML.stripTags),
                  !title.isEmpty else { continue }
            items.append(CatalogItem(id: tid, title: title, coverURL: "", remark: ""))
        }
        return items
    }

    // MARK: - 详情

    /// 帖子图：登录用户有 `zoomfile`，游客只有 `guestviewthumb_cur` 的 200x200 预览。
    static func parseImages(_ html: String, base: String) -> [String] {
        var images: [String] = []
        var seen = Set<String>()
        func append(_ raw: String) {
            let fixed = Self.absoluteURL(raw, base: base)
            guard !fixed.isEmpty, seen.insert(fixed).inserted,
                  fixed.contains("attachment") || fixed.contains("wuso.me")
                    || fixed.contains("imagehost") || fixed.contains("ibb.co") else { return }
            images.append(fixed)
        }
        for attr in ["zoomfile", "file", "makefile"] {
            let pattern = #"\#(attr)="([^"]+)""#
            for raw in CatalogHTML.fullMatches(pattern, in: html) {
                if let value = CatalogHTML.first(pattern, in: raw) { append(value) }
            }
        }
        if images.isEmpty {
            for tag in CatalogHTML.fullMatches(#"<img[^>]+class="[^"]*guestviewthumb_cur[^"]*"[^>]*>"#,
                                               in: html) {
                if let value = CatalogHTML.first(#"(?:src|file)="([^"]+)""#, in: tag) {
                    append(value)
                }
            }
        }
        return images
    }

    /// 影音帖：游客页用「暢遊會員才能播放」遮罩替代播放器，会员 Cookie 下才是 `<video>`；
    /// 部分帖子直接嵌 PeerTube 播放器，游客也能看。
    /// `wsn-player-bar` 是站点视频插件的付费条：即使播放器被隐藏，也说明这是视频帖。
    static func isVideoThread(_ html: String) -> Bool {
        if html.contains("wuso-pt-gate") || html.contains("<video")
            || html.contains("wsn-player-bar") {
            return true
        }
        return CatalogHTML.first(#"<iframe[^>]+src="[^"]*/videos/embed/[^"]*""#, in: html) != nil
    }

    /// 会员可见的播放地址：正文里的 `<video>` / `<source>`，或直接的 `.m3u8` / `.mp4` 链接。
    static func parseVideo(_ html: String, base: String) -> (url: String, poster: String)? {
        for tag in CatalogHTML.fullMatches(#"<video[^>]*>[\s\S]*?</video>"#, in: html) {
            guard let raw = CatalogHTML.first(#"<source[^>]+src="([^"]+)""#, in: tag)
                    ?? CatalogHTML.first(#"<video[^>]+src="([^"]+)""#, in: tag) else { continue }
            let url = Self.absoluteURL(raw, base: base)
            guard url.hasPrefix("http") else { continue }
            let poster = CatalogHTML.first(#"<video[^>]+poster="([^"]+)""#, in: tag)
                .map { Self.absoluteURL($0, base: base) } ?? ""
            return (url, poster)
        }
        if let raw = CatalogHTML.first(#"(?:src|href)="([^"]+\.(?:m3u8|mp4)(?:\?[^"]*)?)""#, in: html) {
            let url = Self.absoluteURL(raw, base: base)
            if url.hasPrefix("http") { return (url, "") }
        }
        return nil
    }

    /// 站内嵌的 PeerTube 播放器：HTML 里只有 iframe，真实地址要从它的 API 取。
    static func resolveEmbedVideo(_ html: String, source: CatalogSource) async -> (url: String, poster: String)? {
        guard let embed = CatalogHTML.first(#"<iframe[^>]+src="([^"]*/videos/embed/[^"]*)""#, in: html),
              let embedURL = URL(string: CatalogHTML.fixURL(embed, base: source.baseURL)),
              let uuid = embedURL.pathComponents.last, !uuid.isEmpty,
              var comps = URLComponents(url: embedURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.path = "/api/v1/videos/\(uuid)"
        comps.query = nil
        guard let api = comps.url?.absoluteString,
              let json = try? await WebCatalogSupport.fetchHTML(api, source: source),
              let raw = CatalogHTML.first(#""playlistUrl":"([^"]+)""#, in: json)
                ?? CatalogHTML.first(#""fileUrl":"([^"]+)""#, in: json) else { return nil }
        let url = raw.replacingOccurrences(of: "\\/", with: "/")
        let poster = CatalogHTML.first(#""thumbnailPath":"([^"]+)""#, in: json)?
            .replacingOccurrences(of: "\\/", with: "/") ?? ""
        return (url, poster)
    }

    /// 影音帖封面：遮罩里的 `background: url('forum.php?mod=image&aid=…&size=800x450&key=…')`。
    static func videoPoster(_ html: String, base: String) -> String {
        let raw = CatalogHTML.first(#"class="wuso-pt-gate"[^>]*background:[^;]*url\('([^']+)'\)"#,
                                    in: html) ?? ""
        return Self.absoluteURL(raw, base: base)
    }

    /// 游客打开帖子时 Discuz 返回「提示信息」页，要求先登录。
    static func isLoginWall(_ html: String) -> Bool {
        guard html.contains("提示信息") else { return false }
        let hasLogin = html.contains("登錄") || html.contains("登录")
            || html.contains("立即註冊") || html.contains("立即注册")
        return hasLogin && !html.contains("normalthread")
    }

    static func parseTags(_ html: String) -> [String] {
        guard let region = CatalogHTML.first(
            #"class="[^"]*comiis_tag[^"]*"[\s\S]{0,4000}"#, in: html) else { return [] }
        var tags: [String] = []
        for raw in CatalogHTML.fullMatches(#"misc\.php\?mod=tag&(?:amp;)?id=\d+"[^>]*>([^<]+)</a>"#,
                                           in: region) {
            guard let text = CatalogHTML.first(#"misc\.php\?mod=tag&(?:amp;)?id=\d+"[^>]*>([^<]+)</a>"#,
                                               in: raw) else { continue }
            let value = CatalogHTML.stripTags(text)
            guard !value.isEmpty else { continue }
            tags.append(value)
        }
        return WebCatalogSupport.unique(tags)
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        // 帖子页的 h1 里还带 [类型] 前缀，优先取 `thread_subject` 本身。
        if let subject = CatalogHTML.first(#"<span[^>]+id="thread_subject"[^>]*>([\s\S]*?)</span>"#,
                                           in: html) {
            let text = CatalogHTML.stripTags(subject)
            if !text.isEmpty { return text }
        }
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        if !heading.isEmpty { return heading }
        let og = WebCatalogSupport.meta(html, "og:title").trimmingCharacters(in: .whitespacesAndNewlines)
        return og.isEmpty ? fallback : og
    }
}
