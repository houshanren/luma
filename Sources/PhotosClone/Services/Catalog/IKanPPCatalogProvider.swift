import Foundation

/// 爱看片片（ikanpp）适配器。
///
/// 站点是 Next.js 应用，页面数据全部在 `self.__next_f.push([...])` 的 RSC 负载里：
/// - 列表 / 搜索：从负载里抽取 `entityId` 形如 `ik999141` 的条目对象。
/// - 详情：`/title/<entityId>` 的负载里有完整 entity（简介、导演、演员、类型）。
/// - 播放：`/api/lines?title=<entityId>` 返回各线路的分集，多数线路直接给 m3u8。
///
/// 该接口要求同源请求头（`Sec-Fetch-Site` 等），否则返回 403。
struct IKanPPCatalogProvider: CatalogProvider {
    static let userAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "movie", title: "电影"),
        CatalogCategory(id: "tv", title: "电视剧"),
        CatalogCategory(id: "anime", title: "动漫"),
        CatalogCategory(id: "variety", title: "综艺"),
        CatalogCategory(id: "documentary", title: "纪录片"),
        CatalogCategory(id: "short", title: "短剧")
    ]

    var supportedSorts: [CatalogSort] { [.latest] }

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
        let items = Self.parseItems(html, source: source)
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        guard page <= 1 else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/" + category.path, source: source)
        let items = Self.parseItems(html, source: source)
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        guard page <= 1 else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        guard let query = WebCatalogSupport.queryEncoded(keyword) else {
            throw CatalogError.invalidConfig("搜索词无效")
        }
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/search?q=" + query,
                                                         source: source)
        let items = Self.parseItems(html, source: source)
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let titlePath = root + "/title/" + itemID
        let html = try await WebCatalogSupport.fetchHTML(titlePath, source: source)
        let text = Self.rscText(html)
        let objects = Self.jsonObjects(containing: "\"entityId\":\"\(itemID)\"", in: text)
        let entity = objects.first {
            Self.text($0["cover"]) != nil && Self.text($0["description"]) != nil
        } ?? objects.first ?? [:]

        let title = Self.text(entity["title"]) ?? ""
        guard !title.isEmpty else {
            throw CatalogError.parse("没有找到条目资料")
        }
        let cover = CatalogHTML.fixURL(Self.text(entity["cover"]) ?? "",
                                       base: source.baseURL)
        let year = Self.text(entity["year"]) ?? ""
        let type = Self.text(entity["type"]) ?? ""
        let description = Self.text(entity["description"]) ?? ""
        let genres = Self.strings(entity["genres"])
        let directors = Self.strings(entity["directors"])
        let actors = Self.strings(entity["actors"])
        let region = Self.text(entity["region"]) ?? ""
        let status = Self.text(entity["status"]) ?? ""

        var facts: [CatalogDetailFact] = []
        if !genres.isEmpty {
            facts.append(CatalogDetailFact(label: "类型", value: genres.joined(separator: " / ")))
        }
        if !year.isEmpty { facts.append(CatalogDetailFact(label: "年份", value: year)) }
        if !region.isEmpty { facts.append(CatalogDetailFact(label: "地区", value: region)) }
        if !directors.isEmpty {
            facts.append(CatalogDetailFact(label: "导演", value: directors.joined(separator: "、")))
        }
        if !actors.isEmpty {
            facts.append(CatalogDetailFact(label: "主演", value: actors.joined(separator: "、")))
        }
        if !status.isEmpty { facts.append(CatalogDetailFact(label: "状态", value: status)) }

        let blocks = description.isEmpty
            ? []
            : [CatalogContentBlock(kind: .paragraph, text: description)]
        let episodes = await Self.lines(source: source,
                                        itemID: itemID,
                                        referer: titlePath)

        let item = CatalogItem(id: itemID,
                               title: title,
                               coverURL: cover,
                               remark: status,
                               categoryID: type)
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let raw = CatalogHTML.fixURL(episode.pageURL, base: source.baseURL)
        guard let url = URL(string: raw) else {
            throw CatalogError.parse("播放地址无效")
        }
        let looksLikePage = raw.contains("/api/play")
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": source.referer,
                                       "Accept": "*/*"],
                             isHLS: raw.lowercased().contains(".m3u8") || looksLikePage)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 列表解析

    static func parseItems(_ html: String, source: CatalogSource) -> [CatalogItem] {
        let payload = rscText(html)
        guard !payload.isEmpty else { return [] }
        var seen = Set<String>()
        var items: [CatalogItem] = []
        for object in jsonObjects(containing: "\"entityId\":\"ik", in: payload) {
            guard let id = text(object["entityId"]),
                  id.hasPrefix("ik"),
                  let title = text(object["title"]), !title.isEmpty,
                  seen.insert(id).inserted else { continue }
            let cover = CatalogHTML.fixURL(text(object["cover"]) ?? "", base: source.baseURL)
            var remark = text(object["updateBadge"]) ?? ""
            if remark.isEmpty { remark = text(object["episodes_info"]) ?? "" }
            if remark.isEmpty { remark = text(object["remarks"]) ?? "" }
            items.append(CatalogItem(id: id,
                                     title: title,
                                     coverURL: cover,
                                     remark: remark,
                                     categoryID: text(object["type"])))
            if items.count >= 240 { break }
        }
        return items
    }

    // MARK: - 分集

    /// `/api/lines` 返回多条线路；优先挑「直链 m3u8 最多」的那条，
    /// 避开需要再跳一次 `/api/play` 的线路。
    private static func lines(source: CatalogSource,
                              itemID: String,
                              referer: String) async -> [CatalogEpisode] {
        guard let root = try? WebCatalogSupport.root(source),
              let encoded = WebCatalogSupport.queryEncoded(itemID),
              let url = URL(string: root + "/api/lines?title=" + encoded)
        else { return [] }
        guard let data = try? await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Referer": referer,
            "Accept": "*/*",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty"
        ]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = object["lines"] as? [[String: Any]] else {
            return []
        }

        var best: [[String: Any]] = []
        var bestScore = -1
        for line in lines {
            guard let episodes = line["episodes"] as? [[String: Any]], !episodes.isEmpty else {
                continue
            }
            let direct = episodes.filter {
                let raw = text($0["url"]) ?? ""
                return raw.lowercased().hasPrefix("http") && !raw.contains("/api/play")
            }.count
            let score = direct * 1000 + episodes.count
            if score > bestScore {
                bestScore = score
                best = episodes
            }
        }

        return best.enumerated().compactMap { index, raw in
            let address = CatalogHTML.fixURL(text(raw["url"]) ?? "", base: source.baseURL)
            guard !address.isEmpty else { return nil }
            return CatalogEpisode(index: index + 1,
                                  pageURL: address,
                                  name: text(raw["name"]) ?? "第 \(index + 1) 集")
        }
    }

    // MARK: - RSC 负载

    /// 把 HTML 里所有 `self.__next_f.push([1,"…"])` 的字符串拼接起来。
    private static func rscText(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)"#
        ) else { return "" }
        let ns = html as NSString
        var output = ""
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: match.range(at: 1))
            if let data = ("\"" + body + "\"").data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data,
                                                               options: .fragmentsAllowed) as? String {
                output += decoded
            }
        }
        return output
    }

    /// 找出负载里所有包含指定片段的 JSON 对象（按花括号配对，跳过字符串内部）。
    private static func jsonObjects(containing needle: String,
                                    in text: String) -> [[String: Any]] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var results: [[String: Any]] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let hit = ns.range(of: needle, options: [], range: search)
            if hit.location == NSNotFound { break }
            let prefix = NSRange(location: 0, length: hit.location)
            let brace = ns.range(of: "{", options: .backwards, range: prefix)
            if brace.location != NSNotFound,
               let end = matchingBrace(ns, from: brace.location), end > brace.location {
                let raw = ns.substring(with: NSRange(location: brace.location,
                                                     length: end - brace.location + 1))
                if let data = raw.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    results.append(object)
                }
            }
            let next = hit.location + hit.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return results
    }

    private static func matchingBrace(_ ns: NSString, from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < ns.length {
            let code = ns.character(at: index)
            if inString {
                if escaped {
                    escaped = false
                } else if code == 0x5C {
                    escaped = true
                } else if code == 0x22 {
                    inString = false
                }
            } else if code == 0x22 {
                inString = true
            } else if code == 0x7B {
                depth += 1
            } else if code == 0x7D {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - 小工具

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { text($0) } ?? []
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

// MARK: - 导入

extension IKanPPCatalogProvider {
    static func importSource(from address: String) async throws -> CatalogSource {
        let root = try WebCatalogSupport.base(from: address)
        let host = URL(string: root)?.host ?? root
        let name = host.contains("ikanpp") ? "爱看片片" : host
        let source = CatalogSource(name: name,
                                   kind: .ikanpp,
                                   baseURL: root,
                                   configURL: address,
                                   userAgent: userAgent,
                                   referer: root + "/",
                                   categories: defaultCategories)
        let page = try await IKanPPCatalogProvider().home(source: source)
        guard !page.items.isEmpty else {
            throw CatalogError.invalidConfig("首页没有解析到影视内容")
        }
        return source
    }
}
