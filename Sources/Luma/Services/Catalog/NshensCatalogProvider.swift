import Foundation

/// 女神网（nshens.com）图集适配器。
///
/// 站点已改为 Nuxt 客户端渲染：HTML 里没有帖子锚点，数据全部在
/// `window.__NUXT__` 的 payload 里。列表用 `latestList` / `postList`，
/// 分类在 `/web/categories` 的 `categoryList`，详情图在
/// `/web/archives/{postId}` 的 `photoList`；详情每页只给 5 张，按 `total` 逐页补齐。
struct NshensCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://nshens.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent
    /// 详情页每页返回的照片数（游客可见）。
    private static let detailPageSize = 5

    /// 主题系列：站点左侧栏的固定入口，走 `/web/tag/{slug}`。
    static let themeTags: [(slug: String, title: String)] = [
        ("nude", "露點"),
        ("porn", "性愛"),
        ("bdsm", "SM"),
        ("cosplay", "Cosplay"),
        ("lesbian", "女同"),
        ("public", "露出"),
        ("tools", "道具"),
        ("xiuren", "秀人網系列")
    ]

    /// 一级模块与站点导航对齐：首頁 / 主題系列 / 目錄列表 / 秀人 / 最新發佈。
    /// 主題系列、目錄列表、秀人自身没有独立页面（`isGroup`）：点开等于进入第一个二级项，
    /// 二级项才是真正的列表页，频道页会把这一层铺成二级胶囊。
    static func modules(folders: [CatalogCategory]) -> [CatalogCategory] {
        [
            CatalogCategory(id: "home", title: "首頁"),
            CatalogCategory(id: "themes", title: "主題系列",
                            children: themeTags.map {
                                CatalogCategory(id: "tag:\($0.slug)", title: $0.title)
                            },
                            isGroup: true),
            CatalogCategory(id: "folders", title: "目錄列表",
                            children: folders,
                            isGroup: true),
            CatalogCategory(id: "xiuren", title: "秀人",
                            children: [
                                CatalogCategory(id: "latestxiuren", title: "最新秀人"),
                                CatalogCategory(id: "category:xiuren", title: "秀人網圖集")
                            ],
                            isGroup: true),
            CatalogCategory(id: "latest", title: "最新發佈")
        ]
    }

    static var defaultCategories: [CatalogCategory] { modules(folders: []) }

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        guard let root = try? WebCatalogSupport.root(source) else {
            return source.categories.isEmpty ? Self.defaultCategories : source.categories
        }
        if let html = try? await WebCatalogSupport.fetchHTML(root + "/web/categories",
                                                              source: source) {
            let folders = Self.parsePhotoCategories(html).map {
                CatalogCategory(id: "category:\($0.slug)", title: $0.title)
            }
            if !folders.isEmpty { return Self.modules(folders: folders) }
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    /// 主题系列已经是二级目录，不再重复成标签行；其余模块仍给一行「主題」快捷筛选。
    func tagGroups(source: CatalogSource,
                   category: CatalogCategory?) async throws -> [CatalogTagGroup] {
        if category?.id == "themes" { return [] }
        return [CatalogTagGroup(id: "themes", title: "主題",
                                items: Self.themeTags.map {
                                    CatalogTag(id: "tag:\($0.slug)", title: $0.title)
                                })]
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/web/", source: source)
        let items = Self.parseCards(html, base: root, section: "latestList")
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    /// 分类页路由：
    /// - `tag:*` → 主题系列，`/web/tag/{slug}/{page}`；
    /// - `category:*` → 目录列表的机构，`/web/category/{slug}/{page}`；
    /// - `home` / `latest` / `latestxiuren` → 首頁 / 最新發佈 / 最新秀人，只有第一页。
    enum Route {
        case list(path: String, section: String, paged: Bool)
        case group
    }

    static func route(_ id: String) -> Route {
        if id.hasPrefix("tag:") {
            return .list(path: "/web/tag/\(String(id.dropFirst(4)))",
                         section: "postList", paged: true)
        }
        if id.hasPrefix("category:") {
            return .list(path: "/web/category/\(String(id.dropFirst(9)))",
                         section: "postList", paged: true)
        }
        switch id {
        case "home": return .list(path: "/web/", section: "latestList", paged: false)
        case "latest": return .list(path: "/web/latestpost", section: "feedList", paged: false)
        case "latestxiuren": return .list(path: "/web/latestxiuren", section: "postList", paged: false)
        default: return .group
        }
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        switch Self.route(category.id) {
        case .list(let path, let section, let paged):
            var address = root + path
            if paged, page > 1 { address += "/\(page)" }
            let html = try await WebCatalogSupport.fetchHTML(address, source: source)
            let items = Self.parseCards(html, base: root, section: section)
            return CatalogPage(items: items, page: page, hasMore: paged && !items.isEmpty)
        case .group:
            // 分组节点自身没有页面（正常会被 openCategory 换成第一个子项），兜底给最新发布。
            let html = try await WebCatalogSupport.fetchHTML(root + "/web/latestpost",
                                                            source: source)
            let items = Self.parseCards(html, base: root, section: "feedList")
            return CatalogPage(items: items, page: 1, hasMore: false)
        }
    }

    /// 站点搜索是路径式 `/web/search/{关键词}`，结果在 Nuxt payload 的 `postList` 里；
    /// `?keyword=` / `?q=` 都不生效，也没有可用翻页，因此一次给全。
    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard page <= 1, !trimmed.isEmpty,
              let encoded = WebCatalogSupport.pathEncoded(trimmed)
        else { return CatalogPage(items: [], page: page, hasMore: false) }
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML("\(root)/web/search/\(encoded)",
                                                                source: source) else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let items = Self.parseCards(html, base: root, section: "postList")
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let postID = Self.postID(from: itemID)
        let address = "\(root)/web/archives/\(postID)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)

        var images = Self.parsePhotoURLs(html)
        let total = Int(CatalogHTML.first(#"total:(\d+)"#, in: Self.payloadText(html)) ?? "")
            ?? images.count
        let pages = min(30, max(1, Int(ceil(Double(total) / Double(Self.detailPageSize)))))
        if pages > 1 {
            var seen = Set(images)
            for page in 2...pages {
                guard let more = try? await WebCatalogSupport.fetchHTML("\(address)/\(page)",
                                                                        source: source) else { break }
                for url in Self.parsePhotoURLs(more) where seen.insert(url).inserted {
                    images.append(url)
                }
                if images.count >= total { break }
            }
        }

        let title = Self.parseTitle(html, fallback: Self.fallbackTitle(postID))
        let videos = Self.parseVideos(html)
        // VIP 帖游客只能拿到封面（`videourl` 被服务端省略），地址为空即未解锁。
        let playableVideos = videos.filter { !$0.url.isEmpty }
        let vipGated = !videos.isEmpty && playableVideos.isEmpty
        let cover = images.first ?? videos.first?.poster ?? ""
        let date = Self.publishDate(html)

        var facts: [CatalogDetailFact] = []
        if let date {
            facts.append(CatalogDetailFact(label: "发布", value: date))
        }
        if !videos.isEmpty {
            facts.append(CatalogDetailFact(label: "视频",
                                           value: vipGated ? "VIP 专享" : "\(videos.count) 个"))
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

        let episodes = playableVideos.enumerated().map { index, video in
            CatalogEpisode(index: index + 1,
                           pageURL: video.url,
                           coverURL: video.poster.isEmpty ? cover : video.poster,
                           name: playableVideos.count > 1 ? "视频 \(index + 1)" : "视频")
        }
        let item = CatalogItem(id: postID, title: title, coverURL: cover,
                               remark: images.isEmpty ? "" : "\(images.count)P",
                               mediaKind: videos.isEmpty ? (images.isEmpty ? nil : .gallery) : .video)
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts,
                             tags: Self.parseTags(html))
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
        let probe = try await WebCatalogSupport.fetchHTML(base + "/web/", source: CatalogSource(
            name: "女神网",
            kind: .nshens,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/web/",
            categories: []
        ))
        guard probe.contains("latestList") || probe.contains("postId")
                || probe.contains("lovestatic") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        var source = CatalogSource(name: "女神网",
                                   kind: .nshens,
                                   baseURL: base,
                                   configURL: address,
                                   userAgent: defaultUserAgent,
                                   referer: base + "/web/",
                                   categories: Self.defaultCategories,
                                   posterAspect: 2.0 / 3.0,
                                   isEnabled: false)
        // 导入时就带上目录列表的机构，第一次打开就能看到完整的二级目录。
        if let live = try? await NshensCatalogProvider().categories(source: source),
           !live.isEmpty {
            source.categories = live
        }
        return source
    }

    // MARK: - 解析

    /// `section` 指定只解析哪个列表（首页 `latestList` / 分类 `postList`），
    /// 不传时在整个 payload 里扫描，便于排查。
    static func parseCards(_ html: String, base: String, section key: String? = nil) -> [CatalogItem] {
        let full = payloadText(html)
        let payload = key.map { Self.section($0, in: full) } ?? full
        let args = nuxtArguments(html)
        let ns = payload as NSString
        guard let regex = try? NSRegularExpression(pattern: #"postId:"(\d+)""#,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        var items: [CatalogItem] = []
        var seen = Set<String>()
        for match in regex.matches(in: payload, range: NSRange(location: 0, length: ns.length)) {
            let postID = ns.substring(with: match.range(at: 1))
            guard seen.insert(postID).inserted else { continue }
            let end = min(ns.length, match.range.location + 520)
            guard end > match.range.location else { continue }
            let block = ns.substring(with: NSRange(location: match.range.location,
                                                   length: end - match.range.location))

            // 综合站：视频条目保留在列表里，只标记类型，不再整条丢弃。
            // Nuxt 序列化把布尔压成 0 / 1，也有页面直接写 true。
            let isVideoFlag = resolve(CatalogHTML.first(#"isVideo:([^,}]+)"#, in: block),
                                      args: args)
            let isVideo = isVideoFlag == "true" || isVideoFlag == "1"
            let slug = CatalogHTML.first(#"slug:"([^"]*)""#, in: block) ?? ""
            let rawCover = unescape(CatalogHTML.first(#"img:"([^"]*)""#, in: block) ?? "")
            let cover = rawCover.isEmpty ? (derivedCover(slug) ?? "") : CatalogHTML.fixURL(rawCover,
                                                                                           base: base)
            let rawTitle = resolve(CatalogHTML.first(#"title:([^,}]+)"#, in: block), args: args)
            let title = rawTitle.isEmpty ? fallbackTitle(slug) : rawTitle
            guard !title.isEmpty else { continue }
            let remark = CatalogHTML.first(#"(\d+)\s*P"#, in: title) ?? ""

            items.append(CatalogItem(id: postID,
                                     title: title,
                                     coverURL: cover,
                                     remark: remark.isEmpty ? "" : "\(remark)P",
                                     mediaKind: isVideo ? .video : .gallery))
        }
        return items
    }

    /// 正文照片：payload 里 `photoList:[{photourl:"…"}]`。
    static func parsePhotoURLs(_ html: String) -> [String] {
        let payload = payloadText(html)
        var images: [String] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(#"photourl:"([^"]+)""#, in: payload) {
            guard let value = CatalogHTML.first(#"photourl:"([^"]+)""#, in: raw) else { continue }
            let url = unescape(value)
            guard url.contains("lovestatic.com"), seen.insert(url).inserted else { continue }
            images.append(url)
        }
        return images
    }

    /// 视频帖：`videoList:[{videoid,videourl,poster}]`，单视频是 `video:{…}`。
    /// 未登录会员的 VIP 帖子只有 `videoid` + `poster`（`videourl` 被服务端省略），
    /// 这类条目仍按视频处理，只是地址留空，由详情提示需要会员。
    static func parseVideos(_ html: String) -> [(url: String, poster: String)] {
        let payload = payloadText(html)
        var regions: [String] = []
        let list = section("videoList", in: payload)
        if !list.isEmpty { regions.append(list) }
        if let single = CatalogHTML.first(#"((?<![A-Za-z])video:\{[^}]*\})"#, in: payload) {
            regions.append(single)
        }
        var result: [(url: String, poster: String)] = []
        var seen = Set<String>()
        for region in regions {
            for block in CatalogHTML.fullMatches(#"\{videoid:"[^"]*"[^}]*\}"#, in: region) {
                let rawURL = CatalogHTML.first(#"videourl:"([^"]+)""#, in: block) ?? ""
                let url = unescape(rawURL)
                let poster = unescape(CatalogHTML.first(#"poster:"([^"]+)""#, in: block) ?? "")
                guard !url.isEmpty || !poster.isEmpty else { continue }
                let key = url.isEmpty ? "poster:\(poster)" : url
                guard seen.insert(key).inserted else { continue }
                result.append((url, poster))
            }
        }
        return result
    }

    static func parseTags(_ html: String) -> [String] {
        let region = section("tagList", in: payloadText(html))
        guard !region.isEmpty else { return [] }
        let args = nuxtArguments(html)
        var tags: [String] = []
        for raw in CatalogHTML.fullMatches(#"\{termId:"\d+",name:([^,]+),slug:"[^"]*""#,
                                           in: region) {
            guard let token = CatalogHTML.first(#"name:([^,]+)"#, in: raw) else { continue }
            let value = resolve(token, args: args)
            guard !value.isEmpty else { continue }
            tags.append(value)
        }
        return WebCatalogSupport.unique(tags)
    }

    /// 目录列表里的机构：`categoryList:[{termId, name, slug, cnName}]`。
    /// 综合站把视频目录也混在同一份列表里，这里全部保留，视频条目会按类型展示。
    static func parsePhotoCategories(_ html: String) -> [(slug: String, title: String)] {
        let region = section("categoryList", in: payloadText(html))
        guard !region.isEmpty else { return [] }
        let args = nuxtArguments(html)
        let pattern = #"\{termId:"\d+",name:([^,]+),slug:"([^"]+)",cnName:([^,}]+)\}"#
        var result: [(slug: String, title: String)] = []
        var seen = Set<String>()
        for raw in CatalogHTML.fullMatches(pattern, in: region) {
            guard let slug = CatalogHTML.first(#"slug:"([^"]+)""#, in: raw),
                  slug != "uncategorized", !slug.contains(","),
                  seen.insert(slug).inserted else { continue }
            let cnName = resolve(CatalogHTML.first(#"cnName:([^,}]+)"#, in: raw), args: args)
            let name = resolve(CatalogHTML.first(#"name:([^,]+)"#, in: raw), args: args)
            let title = !cnName.isEmpty ? cnName
                : (!name.isEmpty ? name : (slug.removingPercentEncoding ?? slug))
            result.append((slug, title))
            if result.count >= 80 { break }
        }
        return result
    }

    // MARK: - __NUXT__ payload

    /// payload 从 `window.__NUXT__` 开始，后面整段都是数据。
    static func payloadText(_ html: String) -> String {
        guard let range = html.range(of: "window.__NUXT__") else { return html }
        return String(html[range.lowerBound...])
    }

    /// `__NUXT__` 用一个立即执行函数把长字符串压缩成单字母参数：
    /// `(function(a,b,…){…return {…}}("2026","11",…))`。
    /// 这里还原「参数名 → 字面量」的映射，用于解析 title / cnName / isVideo 这类被压缩的字段。
    static func nuxtArguments(_ html: String) -> [String: String] {
        guard let signatureStart = html.range(of: "(function("),
              let signatureEnd = html.range(of: "){", range: signatureStart.upperBound..<html.endIndex)
        else { return [:] }
        let params = html[signatureStart.upperBound..<signatureEnd.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let call = html.range(of: "}(", options: .backwards) else { return [:] }

        var values: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escaped = false
        var index = call.upperBound
        while index < html.endIndex {
            let character = html[index]
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inString.toggle()
                current.append(character)
            } else if inString {
                current.append(character)
            } else if character == "(" || character == "[" || character == "{" {
                depth += 1
                current.append(character)
            } else if character == ")" && depth == 0 {
                values.append(current)
                break
            } else if character == ")" || character == "]" || character == "}" {
                depth -= 1
                current.append(character)
            } else if character == "," && depth == 0 {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = html.index(after: index)
        }

        var mapping: [String: String] = [:]
        for (name, raw) in zip(params, values) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") {
                mapping[name] = unescape(String(token.dropFirst().dropLast()))
            } else if token == "true" || token == "false" || token.first?.isNumber == true {
                mapping[name] = token
            }
        }
        return mapping
    }

    /// 取 payload 里某个数组字段的内容（按方括号配对，跳过字符串里的括号）。
    static func section(_ key: String, in payload: String) -> String {
        guard let start = payload.range(of: key + ":[") else { return "" }
        var depth = 1
        var inString = false
        var escaped = false
        var index = start.upperBound
        while index < payload.endIndex {
            let character = payload[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "[" {
                    depth += 1
                } else if character == "]" {
                    depth -= 1
                    if depth == 0 { return String(payload[start.upperBound..<index]) }
                }
            }
            index = payload.index(after: index)
        }
        return ""
    }

    /// payload 里的 JS 字符串转义：斜杠与 & 都是 unicode 转义写法。
    static func unescape(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "\\u002F", with: "/")
        text = text.replacingOccurrences(of: "\\/", with: "/")
        text = text.replacingOccurrences(of: "\\u0026", with: "&")
        text = text.replacingOccurrences(of: "\\u003D", with: "=")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text
    }

    /// 字段值可能是字符串字面量，也可能是压缩后的参数名，统一还原。
    static func resolve(_ token: String?, args: [String: String]) -> String {
        guard let token else { return "" }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return unescape(String(value.dropFirst().dropLast()))
        }
        if value == "true" || value == "false" || value.first?.isNumber == true { return value }
        return args[value] ?? ""
    }

    // MARK: - 小工具

    /// 旧条目 id 是路径，新站点用 postId；两种都归一成数字 id。
    static func postID(from itemID: String) -> String {
        let segment = itemID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if segment.allSatisfy(\.isNumber) { return segment }
        if let id = CatalogHTML.first(#"archives/(\d+)"#, in: segment) { return id }
        return segment
    }

    static func derivedCover(_ itemID: String) -> String? {
        let decoded = itemID.removingPercentEncoding ?? itemID
        let ns = decoded as NSString
        guard let regex = try? NSRegularExpression(pattern: #"(free|vip)(\d+)"#),
              let match = regex.firstMatch(in: decoded,
                                           range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let kind = ns.substring(with: match.range(at: 1))
        let folder = ns.substring(with: match.range(at: 2))
        return "https://s.lovestatic.com/img/origin/\(kind)/\(folder)/snapshot_1.webp"
    }

    private static func parseTitle(_ html: String, fallback: String) -> String {
        let heading = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        if !heading.isEmpty { return heading }
        let og = WebCatalogSupport.meta(html, "og:title").trimmingCharacters(in: .whitespacesAndNewlines)
        if !og.isEmpty { return og }
        if let keywords = CatalogHTML.first(#"metaKeywords:"([^"]+)""#, in: payloadText(html)) {
            let first = keywords.components(separatedBy: ",").first
                .map(unescape) ?? ""
            if !first.isEmpty { return first }
        }
        return fallback
    }

    private static func publishDate(_ html: String) -> String? {
        let args = nuxtArguments(html)
        let payload = payloadText(html)
        // 前面加负向断言，避免把 `postId:` 里的 `d:` 当成日。
        func field(_ key: String) -> String? {
            resolve(CatalogHTML.first(#"(?<![A-Za-z_])\#(key):([^,}]+)"#, in: payload),
                    args: args).nilIfEmpty
        }
        guard let day = field("d"), let month = field("m"), let year = field("y") else {
            return nil
        }
        return "\(year)-\(month)-\(day)"
    }

    private static func fallbackTitle(_ itemID: String) -> String {
        let decoded = itemID.removingPercentEncoding ?? itemID
        let last = decoded.split(separator: "/").last.map(String.init) ?? decoded
        let trimmed = last.replacingOccurrences(of: #"^(free|vip)\d+"#,
                                                with: "",
                                                options: .regularExpression)
        let cleaned = trimmed.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        return last.allSatisfy(\.isNumber) ? "女神网 #\(last)" : last
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
