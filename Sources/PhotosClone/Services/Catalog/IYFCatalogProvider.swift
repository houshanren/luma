import Foundation
import CryptoKit

/// 爱壹帆（iyf.tv）适配器。
///
/// 站点是 Angular 应用，数据有两层来源：
/// - 首页 / 频道页的服务端渲染里带 `var injectJson = {...}`，有海报与频道条目；
/// - 列表分页、搜索、详情、分集与播放都走 `m10.iyf.tv` / `rankv21.iyf.tv` 的 JSON 接口。
///
/// 接口要求 `vv` / `pub` 签名：
/// `vv = md5(publicKey + "&" + 小写查询串 + "&" + privateKey)`，`pub = publicKey`。
/// 签名材料从页面 `injectJson.config[0].pConfig` 读取，读不到时使用内置的一份兜底。
struct IYFCatalogProvider: CatalogProvider {
    static let userAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "0,1,3", title: "电影"),
        CatalogCategory(id: "0,1,4", title: "电视剧"),
        CatalogCategory(id: "0,1,5", title: "综艺"),
        CatalogCategory(id: "0,1,6", title: "动漫")
    ]

    /// 频道页路径：服务端渲染的海报比列表接口里的动图更清晰。
    private static let landingPaths: [String: String] = [
        "0,1,3": "movie",
        "0,1,4": "drama",
        "0,1,5": "variety",
        "0,1,6": "anime"
    ]

    var supportedSorts: [CatalogSort] { [.latest] }

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        var items: [CatalogItem] = []
        var hasMore = false
        var failure: Error?
        if let ssr = try? await Self.ssrItems(path: "/", source: source) {
            items = ssr
        } else {
            failure = CatalogError.parse("首页没有解析到内容")
        }
        if let api = try? await Self.apiList(cid: "0", page: 1, source: source) {
            items = Self.merge(ssr: items, api: api.items)
            hasMore = api.hasMore
        } else {
            failure = CatalogError.unavailable("列表接口暂时不可用")
        }
        guard !items.isEmpty else { throw failure ?? CatalogError.unavailable("暂时没有内容") }
        return CatalogPage(items: items, page: 1, hasMore: hasMore)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        guard page > 1 else { return try await home(source: source) }
        let api = try await Self.apiList(cid: "0", page: page, source: source)
        return CatalogPage(items: api.items, page: page, hasMore: api.hasMore)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        var items: [CatalogItem] = []
        if page <= 1, let path = Self.landingPaths[category.id],
           let ssr = try? await Self.ssrItems(path: "/" + path, source: source) {
            items = ssr
        }
        guard let api = try? await Self.apiList(cid: category.id, page: page, source: source) else {
            guard !items.isEmpty else {
                throw CatalogError.unavailable("列表接口暂时不可用")
            }
            return CatalogPage(items: items, page: page, hasMore: false)
        }
        items = Self.merge(ssr: items, api: api.items)
        return CatalogPage(items: items, page: page, hasMore: api.hasMore)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        guard let query = WebCatalogSupport.queryEncoded(trimmed) else {
            throw CatalogError.invalidConfig("搜索词无效")
        }
        let address = "cinema=1&tags=\(query)&orderby=4&page=\(page)&size=20&desc=0&isserial=-1&istitle=1&v=1"
        let body = try JSONSerialization.data(withJSONObject: ["tags": trimmed])
        let object = try await Self.apiPost(base: Self.rankV3(source) + "/list/briefsearch",
                                            query: address,
                                            body: body,
                                            source: source)
        let info = Self.infoArray(object)
        guard let first = info.first else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let results = first["result"] as? [[String: Any]] ?? []
        let total = Self.int(first["recordcount"]) ?? 0
        let items = results.compactMap(Self.item(fromSearch:))
        return CatalogPage(items: items,
                           page: page,
                           hasMore: total > page * 20)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        guard let key = WebCatalogSupport.queryEncoded(itemID) else {
            throw CatalogError.invalidConfig("条目地址无效")
        }
        let query = "ispath=false&cinema=1&id=\(key)&device=desktop&player=CkPlayer"
            + "&tech=HLS&country=HU&lang=cns&v=1"
        let object = try await Self.apiGet(base: Self.apiV3(source) + "/video/detail",
                                           query: query,
                                           source: source)
        guard let raw = Self.infoArray(object).first else {
            throw CatalogError.parse("没有找到条目资料")
        }

        let title = Self.text(raw["title"]) ?? ""
        guard !title.isEmpty else { throw CatalogError.parse("没有找到条目标题") }
        let cover = CatalogHTML.fixURL(Self.text(raw["imgPath"]) ?? "", base: source.baseURL)
        let channel = Self.text(raw["channel"]) ?? ""
        let genre = Self.text(raw["videoType"]) ?? ""
        let region = Self.text(raw["regional"]) ?? ""
        let language = Self.text(raw["language"]) ?? ""
        let score = Self.text(raw["score"]) ?? ""
        let directors = Self.text(raw["directors"] as Any?) ?? ""
        let stars = Self.text(raw["stars"] as Any?) ?? ""
        let synopsis = CatalogHTML.stripTags(Self.text(raw["contxt"]) ?? "")
        let cid = Self.text(raw["cid"]) ?? ""
        let isSerial = Self.bool(raw["isSerial"])
        let serialCount = Self.int(raw["serialCount"]) ?? 0

        var facts: [CatalogDetailFact] = []
        if !channel.isEmpty { facts.append(CatalogDetailFact(label: "频道", value: channel)) }
        if !genre.isEmpty { facts.append(CatalogDetailFact(label: "类型", value: genre)) }
        if !region.isEmpty { facts.append(CatalogDetailFact(label: "地区", value: region)) }
        if !language.isEmpty { facts.append(CatalogDetailFact(label: "语言", value: language)) }
        if !directors.isEmpty { facts.append(CatalogDetailFact(label: "导演", value: directors)) }
        if !stars.isEmpty { facts.append(CatalogDetailFact(label: "主演", value: stars)) }
        if !score.isEmpty { facts.append(CatalogDetailFact(label: "评分", value: score)) }
        if isSerial, serialCount > 0 {
            facts.append(CatalogDetailFact(label: "集数", value: "\(serialCount) 集"))
        }

        var episodes: [CatalogEpisode] = []
        if isSerial {
            let listQuery = "cinema=1&vid=\(key)&lsk=1&taxis=0&cid=\(cid)&v=1"
            if let listObject = try? await Self.apiGet(base: Self.apiV3(source) + "/video/languagesplaylist",
                                                       query: listQuery,
                                                       source: source),
               let playList = Self.infoArray(listObject).first?["playList"] as? [[String: Any]] {
                episodes = playList.enumerated().compactMap { index, entry in
                    guard let episodeKey = Self.text(entry["key"]) else { return nil }
                    let name = Self.text(entry["name"]) ?? "第 \(index + 1) 集"
                    return CatalogEpisode(index: index + 1,
                                          pageURL: "iyf://ep/\(episodeKey)",
                                          name: name)
                }
            }
        }
        if episodes.isEmpty {
            episodes = [CatalogEpisode(index: 1,
                                       pageURL: "iyf://movie/\(key)",
                                       name: "正片")]
        }

        let blocks = synopsis.isEmpty
            ? []
            : [CatalogContentBlock(kind: .paragraph, text: synopsis)]
        let item = CatalogItem(id: itemID,
                               title: title,
                               coverURL: cover,
                               remark: "",
                               categoryID: cid)
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let address = episode.pageURL
        let key: String
        let isEpisode: Bool
        if address.hasPrefix("iyf://ep/") {
            key = String(address.dropFirst("iyf://ep/".count))
            isEpisode = true
        } else if address.hasPrefix("iyf://movie/") {
            key = String(address.dropFirst("iyf://movie/".count))
            isEpisode = false
        } else {
            throw CatalogError.parse("播放地址无效")
        }
        guard let encoded = WebCatalogSupport.queryEncoded(key) else {
            throw CatalogError.parse("播放地址无效")
        }
        let query = "cinema=1&id=\(encoded)&a=\(isEpisode ? 0 : 1)&usersign=1"
            + "&region=GL.&device=1&isMasterSupport=1&v=1"
        let object = try await Self.apiGet(base: Self.apiV3(source) + "/video/play",
                                           query: query,
                                           source: source)
        guard let info = Self.infoArray(object).first,
              let paths = info["flvPathList"] as? [[String: Any]] else {
            throw CatalogError.unavailable("暂时没有可用的播放线路")
        }
        let hls = paths.first {
            Self.bool($0["isHls"]) && (Self.text($0["result"]) ?? "").contains(".m3u8")
        }
        // `flvPathList` 的第一条常是 20 秒广告（mp4）；没有正片 HLS 时不要把它当成播放地址。
        let fallback = paths.first {
            guard (Self.text($0["result"]) ?? "").lowercased().hasPrefix("http") else { return false }
            let duration = Self.int($0["duration"]) ?? 0
            return duration == 0 || duration > 30
        }
        guard let chosen = hls ?? fallback,
              let raw = Self.text(chosen["result"]),
              let url = URL(string: raw) else {
            throw CatalogError.unavailable("该片可能需要会员，或暂时没有可用线路")
        }
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": source.referer],
                             isHLS: url.absoluteString.lowercased().contains(".m3u8"))
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 服务端渲染的频道条目

    private static func ssrItems(path: String, source: CatalogSource) async throws -> [CatalogItem] {
        let root = try WebCatalogSupport.root(source)
        guard let url = URL(string: root + path) else {
            throw CatalogError.parse("页面地址无效")
        }
        let data = try await CatalogHTTP.fetchData(url: url, headers: pageHeaders(source))
        let html = String(decoding: data, as: UTF8.self)
        guard let json = injectJSON(html) else {
            throw CatalogError.parse("页面数据解析失败")
        }
        if let signature = signature(from: json) {
            remember(signature, host: domain(source))
        }
        var seen = Set<String>()
        var items: [CatalogItem] = []
        for value in json.values {
            guard let list = value as? [[String: Any]] else { continue }
            for raw in list {
                guard let id = text(raw["listPath"]) ?? text(raw["key"]),
                      !id.isEmpty,
                      seen.insert(id).inserted,
                      let title = text(raw["title"]), !title.isEmpty,
                      !bool(raw["external"]) else { continue }
                let cover = text(raw["img"]) ?? text(raw["image"]) ?? ""
                items.append(CatalogItem(id: id,
                                         title: title,
                                         coverURL: CatalogHTML.fixURL(cover, base: source.baseURL),
                                         remark: text(raw["subTitle"]) ?? ""))
            }
        }
        return items
    }

    // MARK: - 列表接口

    private static func apiList(cid: String,
                                page: Int,
                                source: CatalogSource) async throws
        -> (items: [CatalogItem], hasMore: Bool) {
        let query = "cinema=1&page=\(max(1, page))&cid=\(cid)&size=24&isn=0&isfree=-1&v=1"
        let object = try await apiGet(base: apiHost(source) + "/api/list/index",
                                      query: query,
                                      source: source)
        let list = infoArray(object)
        let items = list.compactMap { item(fromList: $0) }
        return (items, items.count >= 24)
    }

    private static func item(fromList raw: [String: Any]) -> CatalogItem? {
        guard let id = text(raw["key"]), !id.isEmpty,
              let title = text(raw["title"]), !title.isEmpty else { return nil }
        var remark = ""
        if bool(raw["isSerial"]) {
            let last = text(raw["lastName"]) ?? ""
            let total = int(raw["serialCount"]) ?? 0
            if let number = Int(last), number > 0 {
                if total == number, total > 0 {
                    remark = "全\(total)集"
                } else {
                    remark = "更新至\(number)集"
                }
            } else {
                remark = last
            }
        } else {
            remark = text(raw["vipResource"]) ?? text(raw["score"]) ?? ""
        }
        return CatalogItem(id: id,
                           title: title,
                           coverURL: CatalogHTML.fixURL(text(raw["image"]) ?? "", base: ""),
                           remark: remark)
    }

    private static func item(fromSearch raw: [String: Any]) -> CatalogItem? {
        // 搜索结果把可播放的 key 放在 contxt 里，个别版本会给 key / link。
        let rawKey = text(raw["key"])
            ?? text(raw["contxt"]).flatMap { $0.range(of: #"^[A-Za-z0-9_-]{6,24}$"#,
                                                      options: .regularExpression) != nil ? $0 : nil }
            ?? text(raw["link"]).flatMap { URLComponents(string: $0)?.path.split(separator: "/").last.map(String.init) }
        guard let id = rawKey, !id.isEmpty,
              let title = text(raw["title"]), !title.isEmpty else { return nil }
        var remark = ""
        if bool(raw["isSerial"]) {
            let last = text(raw["lastName"]) ?? ""
            if !last.isEmpty { remark = "更新至\(last)集" }
        }
        if remark.isEmpty { remark = text(raw["score"]) ?? "" }
        return CatalogItem(id: id,
                           title: title,
                           coverURL: CatalogHTML.fixURL(text(raw["imgPath"]) ?? "", base: ""),
                           remark: remark)
    }

    // MARK: - 签名与请求

    private struct Signature: Sendable {
        var publicKey: String
        var privateKey: String
    }

    /// 站点 `pConfig` 读不到时的兜底（与页面内联配置一致）。
    private static let fallbackSignature = Signature(
        publicKey: "CJSvDJGuD3KtE2utCLya9QzCZGmC3erDc4mEZXZCZevCp5cEcKrPcCwP3GmC3fYPMOqEcCqOpbVCJWtDpCpCs8rPJOrD64rDpbbOcCoCcPXCZ4tOM8vE3DVOJGvCp4rCJGuEJ8nPZOtDpSsOJTcDZPcC38pEJOmCp3",
        privateKey: "SvDJJSvDJGuD3KtE2utC"
    )

    private static let signatureLock = NSLock()
    private static var signatureCache: [String: Signature] = [:]

    private static func cachedSignature(_ host: String) -> Signature? {
        signatureLock.lock()
        defer { signatureLock.unlock() }
        return signatureCache[host]
    }

    private static func remember(_ signature: Signature, host: String) {
        signatureLock.lock()
        signatureCache[host] = signature
        signatureLock.unlock()
    }

    private static func forget(host: String) {
        signatureLock.lock()
        signatureCache[host] = nil
        signatureLock.unlock()
    }

    private static func signature(for source: CatalogSource,
                                  json: [String: Any]? = nil) async throws -> Signature {
        let host = domain(source)
        if let cached = cachedSignature(host) { return cached }
        if let json, let parsed = signature(from: json) {
            remember(parsed, host: host)
            return parsed
        }
        if let root = URL(string: try WebCatalogSupport.root(source) + "/"),
           let data = try? await CatalogHTTP.fetchData(url: root, headers: pageHeaders(source)),
           let parsed = signature(from: injectJSON(String(decoding: data, as: UTF8.self))) {
            remember(parsed, host: host)
            return parsed
        }
        remember(fallbackSignature, host: host)
        return fallbackSignature
    }

    private static func signature(from json: [String: Any]?) -> Signature? {
        guard let configs = json?["config"] as? [[String: Any]],
              let pConfig = configs.first?["pConfig"] as? [String: Any],
              let publicKey = text(pConfig["publicKey"]), !publicKey.isEmpty,
              let list = pConfig["privateKey"] as? [Any],
              let privateKey = list.compactMap({ text($0) }).first, !privateKey.isEmpty else {
            return nil
        }
        return Signature(publicKey: publicKey, privateKey: privateKey)
    }

    private static func signedURL(_ base: String,
                                  query: String,
                                  signature: Signature) throws -> URL {
        let digest = Insecure.MD5.hash(data: Data(
            (signature.publicKey + "&" + query.lowercased() + "&" + signature.privateKey).utf8
        ))
        let vv = digest.map { String(format: "%02x", $0) }.joined()
        let raw = base + "?" + query + "&vv=" + vv + "&pub=" + signature.publicKey
        guard let url = URL(string: raw) else {
            throw CatalogError.parse("接口地址无效")
        }
        return url
    }

    private static func apiGet(base: String,
                               query: String,
                               source: CatalogSource) async throws -> [String: Any] {
        let host = domain(source)
        var signature = try await signature(for: source)
        var object = try await sendGet(base: base, query: query, signature: signature, source: source)
        if isSignatureError(object) {
            forget(host: host)
            signature = try await Self.signature(for: source)
            object = try await sendGet(base: base, query: query, signature: signature, source: source)
        }
        return object
    }

    private static func apiPost(base: String,
                                query: String,
                                body: Data,
                                source: CatalogSource) async throws -> [String: Any] {
        let host = domain(source)
        var signature = try await signature(for: source)
        var object = try await sendPost(base: base, query: query, body: body,
                                        signature: signature, source: source)
        if isSignatureError(object) {
            forget(host: host)
            signature = try await Self.signature(for: source)
            object = try await sendPost(base: base, query: query, body: body,
                                        signature: signature, source: source)
        }
        return object
    }

    private static func sendGet(base: String,
                                query: String,
                                signature: Signature,
                                source: CatalogSource) async throws -> [String: Any] {
        let url = try signedURL(base, query: query, signature: signature)
        let data = try await CatalogHTTP.fetchData(url: url, headers: pageHeaders(source))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.parse("接口返回的不是 JSON")
        }
        return object
    }

    private static func sendPost(base: String,
                                 query: String,
                                 body: Data,
                                 signature: Signature,
                                 source: CatalogSource) async throws -> [String: Any] {
        let url = try signedURL(base, query: query, signature: signature)
        var headers = pageHeaders(source)
        headers["Content-Type"] = "application/json"
        let data = try await CatalogHTTP.postJSON(url: url, headers: headers, body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.parse("接口返回的不是 JSON")
        }
        return object
    }

    private static func isSignatureError(_ object: [String: Any]) -> Bool {
        guard let data = object["data"] as? [String: Any],
              int(data["code"]) == 1,
              let message = text(data["msg"]) else { return false }
        return message.contains("签名")
    }

    private static func infoArray(_ object: [String: Any]) -> [[String: Any]] {
        (object["data"] as? [String: Any])?["info"] as? [[String: Any]] ?? []
    }

    private static func pageHeaders(_ source: CatalogSource) -> [String: String] {
        ["User-Agent": source.userAgent,
         "Referer": source.referer,
         "Accept": "text/html,application/json,application/xhtml+xml,*/*;q=0.8",
         "Accept-Language": "zh-CN,zh;q=0.9"]
    }

    // MARK: - 站点内联数据

    private static func injectJSON(_ html: String) -> [String: Any]? {
        let ns = html as NSString
        let marker = ns.range(of: "var injectJson = ")
        guard marker.location != NSNotFound else { return nil }
        let begin = marker.location + marker.length
        guard let end = matchingBrace(ns, from: begin), end > begin else { return nil }
        let raw = ns.substring(with: NSRange(location: begin, length: end - begin + 1))
        return try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    }

    private static func matchingBrace(_ ns: NSString, from start: Int) -> Int? {
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
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

    // MARK: - 合并与小工具

    private static func merge(ssr: [CatalogItem], api: [CatalogItem]) -> [CatalogItem] {
        var seen = Set<String>()
        var result: [CatalogItem] = []
        for item in ssr + api where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    private static func domain(_ source: CatalogSource) -> String {
        var host = (URL(string: source.baseURL)?.host ?? source.host).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func apiHost(_ source: CatalogSource) -> String {
        "https://m10." + domain(source)
    }

    private static func apiV3(_ source: CatalogSource) -> String {
        apiHost(source) + "/v3"
    }

    private static func rankV3(_ source: CatalogSource) -> String {
        "https://rankv21." + domain(source) + "/v3"
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return value == "true" || value == "1"
        default: return false
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        case let value as [Any]:
            let parts = value.compactMap { text($0) }
            return parts.isEmpty ? nil : parts.joined(separator: "、")
        default:
            return nil
        }
    }
}

// MARK: - 导入

extension IYFCatalogProvider {
    static func importSource(from address: String) async throws -> CatalogSource {
        let root = try WebCatalogSupport.base(from: address)
        let host = URL(string: root)?.host ?? root
        let name = host.contains("iyf") ? "爱壹帆" : host
        let source = CatalogSource(name: name,
                                   kind: .iyf,
                                   baseURL: root,
                                   configURL: address,
                                   userAgent: userAgent,
                                   referer: root + "/",
                                   categories: defaultCategories)
        let page = try await IYFCatalogProvider().home(source: source)
        guard !page.items.isEmpty else {
            throw CatalogError.invalidConfig("首页没有解析到影视内容")
        }
        return source
    }
}
