import Foundation
import LumaContentCore

/// 标记当前请求是否属于后台任务（更新日历补录、健康探测、跨源榜单）。
/// 后台请求走独立的低优先限流通道，用户点开的列表不会排在它们后面。
enum CatalogRequestScope {
    @TaskLocal static var isBackground = false
}

// MARK: - 通用资源解析协议
//
// 每个站点实现一份 `CatalogProvider`；界面与状态层只依赖协议与模型，
// 新增源时不需要改频道页、详情页或播放器。

protocol CatalogProvider {
    func categories(source: CatalogSource) async throws -> [CatalogCategory]
    func home(source: CatalogSource) async throws -> CatalogPage
    /// 首页的后续分页：站点首页能一直往下翻时实现它。
    func home(source: CatalogSource, page: Int) async throws -> CatalogPage
    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage
    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail
    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage
    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream
    /// 封面原始字节（已解密、已裁掉自定义填充）。
    func coverData(source: CatalogSource, urlString: String) async throws -> Data
    /// 站点热门标签（跨分类筛选），默认没有。
    func tags(source: CatalogSource) async throws -> [CatalogCategory]
    /// 当前一级分类下的二级标签：有些站点的标签是挂在主分类下的，不能全局混在一起。
    func tags(source: CatalogSource, category: CatalogCategory?) async throws -> [CatalogCategory]
    /// 带分组的标签（分类 / 模特 / 发布商等）：界面按组展示，点一项即按该标签筛选。
    func tagGroups(source: CatalogSource, category: CatalogCategory?) async throws -> [CatalogTagGroup]
    /// 「全部分类」标签墙：标签非常多时由适配器内部翻页取全量，界面端再做搜索与分页。
    func allTags(source: CatalogSource) async throws -> [CatalogTag]
    /// 博文归档：一次取回按日期排好的全部条目，界面端做月份筛选与标题搜索。
    func archiveEntries(source: CatalogSource) async throws -> [CatalogArchiveEntry]
    /// 一级分类下的二级频道：站点把二级挂在分类页里时按需拉取。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory]
    /// 站点真正支持的排序。默认只有「最新更新」，界面据此隐藏点不动的选项。
    var supportedSorts: [CatalogSort] { get }
}

extension CatalogProvider {
    func tags(source: CatalogSource) async throws -> [CatalogCategory] { [] }

    /// 默认站点没有「全部分类」标签墙。
    func allTags(source: CatalogSource) async throws -> [CatalogTag] { [] }

    /// 默认站点没有博文归档。
    func archiveEntries(source: CatalogSource) async throws -> [CatalogArchiveEntry] { [] }

    /// 默认站点只有自己的默认顺序，没有可切换的服务端排序。
    var supportedSorts: [CatalogSort] { [.latest] }

    /// 默认忽略分类：没有分层标签的站点仍用全局标签。
    func tags(source: CatalogSource, category: CatalogCategory?) async throws -> [CatalogCategory] {
        try await tags(source: source)
    }

    /// 默认把已有标签包成一组，老适配器无需改动就能用新的分组面板。
    func tagGroups(source: CatalogSource,
                   category: CatalogCategory?) async throws -> [CatalogTagGroup] {
        let live = try await tags(source: source, category: category)
        let flat = live.flatMap { tag in
            if let children = tag.children, !children.isEmpty { return children }
            return [tag]
        }
        guard !flat.isEmpty else { return [] }
        return [CatalogTagGroup(id: "tags", title: "标签",
                                items: flat.map { CatalogTag(id: $0.id, title: $0.title) })]
    }

    /// 默认二级已经随分类一起返回。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        category.children ?? []
    }

    /// 默认首页只有第一页，滚动到底就停下。
    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        guard page > 1 else { return try await home(source: source) }
        return CatalogPage(items: [], page: page, hasMore: false)
    }
}

enum CatalogProviders {
    /// 适配器内置的完整分类骨架（含站点二级分类）：用于补齐旧版本保存下来的源。
    static func canonicalCategories(for kind: CatalogProviderKind) -> [CatalogCategory]? {
        switch kind {
        case .fofo: return FoFoCatalogProvider.defaultCategories
        case .ikanpp: return IKanPPCatalogProvider.defaultCategories
        case .iyf: return IYFCatalogProvider.defaultCategories
        case .jliji: return JlijiCatalogProvider.defaultCategories
        case .xxss: return XxssCatalogProvider.defaultCategories
        case .aimeir: return AimeirCatalogProvider.defaultCategories
        case .ninetyOneTutu: return NinetyOneTutuCatalogProvider.defaultCategories
        case .wuso: return WusoCatalogProvider.defaultCategories
        case .tuzac: return TuzacCatalogProvider.defaultCategories
        case .kkc: return KkcCatalogProvider.defaultCategories
        case .knit: return KnitCatalogProvider.defaultCategories
        case .nshens: return NshensCatalogProvider.defaultCategories
        default: return nil
        }
    }

    /// 用最新的站点分类补全保存的源：保留用户原有的一级顺序与标题，
    /// 只补缺失的一级、以及一级下缺失的二级。
    static func enrich(_ source: CatalogSource) -> CatalogSource {
        guard let canonical = canonicalCategories(for: source.kind) else { return source }
        var result = source
        // 女神网从「平铺机构列表」改成「一级模块 + 二级目录」：旧源整体换成新的模块骨架，
        // 否则频道页会同时出现 50 多个旧的一级机构和新模块。二级目录在打开时实时补齐。
        if source.kind == .nshens {
            result.categories = keepingChildren(canonical, from: result.categories)
            return result
        }
        // 图宅的分类是固定导航（最新 / 女神 / … / 全部分类 / 精选）：按站点顺序整体重建，
        // 避免旧源把「精选」排在新增的几个分类前面。
        if source.kind == .tuzac {
            result.categories = keepingChildren(canonical, from: result.categories)
            return result
        }
        // 91图图从「R18 / R17 / R16」的分级导航改成「标签 / 尺度 / 归档」：
        // 旧源里的三个分级已经没有对应页面，整体换成新的入口。
        if source.kind == .ninetyOneTutu {
            result.categories = keepingChildren(canonical, from: result.categories)
            return result
        }
        // 爱美图集补上「首页」与「热门模特」两个新入口：整体重建，
        // 避免旧源保留的 3 个分类顺序与新导航不一致。
        if source.kind == .aimeir {
            result.categories = keepingChildren(canonical, from: result.categories)
            return result
        }
        // JLiji 从「平铺的 8 个分类」改成「分类 / 模特 / 发布商」三个一级：
        // 旧源里的分类 id（`category/taotu`）已经没有对应的一级位置，整体替换。
        if source.kind == .jliji {
            result.categories = keepingChildren(canonical, from: result.categories)
            return result
        }
        for fresh in canonical {
            if let index = result.categories.firstIndex(where: { $0.id == fresh.id }) {
                let saved = result.categories[index]
                guard saved.children?.isEmpty ?? true,
                      let children = fresh.children, !children.isEmpty else { continue }
                result.categories[index].children = children
            } else {
                result.categories.append(fresh)
            }
        }
        return result
    }

    /// 整体替换分类骨架时保留本地已缓存的二级：站点的二级（目录 / 模特 / 机构）
    /// 是打开时实时补齐并写回源里的，重建骨架不能把它们丢掉。
    private static func keepingChildren(_ canonical: [CatalogCategory],
                                        from saved: [CatalogCategory]) -> [CatalogCategory] {
        canonical.map { fresh in
            guard fresh.children?.isEmpty ?? true,
                  let old = saved.first(where: { $0.id == fresh.id }),
                  let children = old.children, !children.isEmpty else { return fresh }
            var updated = fresh
            updated.children = children
            return updated
        }
    }

    static func provider(for kind: CatalogProviderKind) -> CatalogProvider? {
        guard let base = baseProvider(for: kind) else { return nil }
        // 所有源统一补一层「标题元数据」：站点没给备注时从标题派生番号 / 厂牌。
        return CatalogMetadataProvider(base: base)
    }
    private static func baseProvider(for kind: CatalogProviderKind) -> CatalogProvider? {
        switch kind {
        case .huangguo:
            return HuangguoCatalogProvider()
        case .ninetyOne:
            return NinetyOneCatalogProvider()
        case .ninetyOnePorna:
            return NinetyOnePornaCatalogProvider()
        case .xszAV:
            return XszCatalogProvider()
        case .missav:
            return MissavCatalogProvider()
        case .avple:
            return AvpleCatalogProvider()
        case .shise:
            return ShiseCatalogProvider()
        case .avgle:
            return AvgleCatalogProvider()
        case .rouVideo:
            return RouVideoCatalogProvider()
        case .quanji:
            return QuanjiCatalogProvider()
        case .javcl:
            return JavClCatalogProvider()
        case .madou:
            return MadouCatalogProvider()
        case .javgg:
            return JavGGCatalogProvider()
        case .maccms:
            return MacCMSCatalogProvider()
        case .fofo:
            return FoFoCatalogProvider()
        case .ikanpp:
            return IKanPPCatalogProvider()
        case .iyf:
            return IYFCatalogProvider()
        case .jliji:
            return JlijiCatalogProvider()
        case .xxss:
            return XxssCatalogProvider()
        case .aimeir:
            return AimeirCatalogProvider()
        case .v2ph:
            return V2PHCatalogProvider()
        case .nshens:
            return NshensCatalogProvider()
        case .ninetyOneTutu:
            return NinetyOneTutuCatalogProvider()
        case .wuso:
            return WusoCatalogProvider()
        case .tuzac:
            return TuzacCatalogProvider()
        case .kkc:
            return KkcCatalogProvider()
        case .knit:
            return KnitCatalogProvider()
        }
    }
}

/// 单源单页检索的统一入口：给并发搜索加一个超时兜底，
/// 某个站点连不上 / 一直不返回时直接放弃，不拖慢整轮结果。
enum CatalogSearchSupport {
    /// 单个源的单次检索上限：超过就当这个源这一轮没有结果。
    static let sourceTimeoutNanoseconds: UInt64 = 12_000_000_000

    static func search(_ source: CatalogSource,
                       keyword: String,
                       page: Int = 1,
                       timeout: UInt64 = sourceTimeoutNanoseconds) async -> [CatalogItem] {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return [] }
        return await withTaskGroup(of: [CatalogItem]?.self) { group in
            group.addTask {
                guard let result = try? await provider.search(source: source,
                                                              keyword: keyword,
                                                              page: page) else { return nil }
                return result.items
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            // 先完成的那个说了算：结果、失败、超时都不再等其它源。
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }
}

/// 通用标题元数据：列表 / 搜索 / 详情经过这一层时，
/// 没写备注的条目会用标题里的番号 / 厂牌补一条，卡片不再全是空白。
private struct CatalogMetadataProvider: CatalogProvider {
    let base: CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        try await base.categories(source: source)
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        Self.enrich(try await base.home(source: source))
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        Self.enrich(try await base.home(source: source, page: page))
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        Self.enrich(try await base.category(source: source, category: category,
                                            sort: sort, page: page))
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        var detail = try await base.detail(source: source, itemID: itemID)
        detail.item = Self.enrich(detail.item)
        return detail
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        Self.enrich(try await base.search(source: source, keyword: keyword, page: page))
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        try await base.stream(source: source, episode: episode)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await base.coverData(source: source, urlString: urlString)
    }

    func tags(source: CatalogSource) async throws -> [CatalogCategory] {
        try await base.tags(source: source)
    }

    func tags(source: CatalogSource, category: CatalogCategory?) async throws -> [CatalogCategory] {
        try await base.tags(source: source, category: category)
    }

    func tagGroups(source: CatalogSource,
                   category: CatalogCategory?) async throws -> [CatalogTagGroup] {
        try await base.tagGroups(source: source, category: category)
    }

    func allTags(source: CatalogSource) async throws -> [CatalogTag] {
        try await base.allTags(source: source)
    }

    func archiveEntries(source: CatalogSource) async throws -> [CatalogArchiveEntry] {
        try await base.archiveEntries(source: source)
    }

    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        try await base.channels(source: source, category: category)
    }

    var supportedSorts: [CatalogSort] { base.supportedSorts }

    private static func enrich(_ page: CatalogPage) -> CatalogPage {
        var page = page
        page.items = page.items.map(enrich)
        return page
    }

    private static func enrich(_ item: CatalogItem) -> CatalogItem {
        guard item.remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return item }
        let meta = CatalogNameParser.titleMetadata(item.title)
        guard !meta.isEmpty else { return item }
        var copy = item
        copy.remark = meta.remark
        return copy
    }
}

// MARK: - 证书信任

/// 按主机放行不受系统信任的证书：只对用户显式开启过「允许不受信任的证书」的源生效。
/// 这是有意为之的窄口子：全局 ATS 不放开，其他网络请求仍走系统校验。
enum CatalogTrust {
    private static let lock = NSLock()
    private static var hosts = Set<String>()

    static func isTrusted(_ host: String) -> Bool {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        return hosts.contains(key)
    }

    static func setTrusted(_ host: String, _ trusted: Bool) {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if trusted { hosts.insert(key) } else { hosts.remove(key) }
    }

    /// 以当前源列表为准重建白名单，避免删源后残留放行。
    static func sync(sources: [CatalogSource]) {
        let trusted = Set(sources.filter(\.trustsInsecureCertificate).map(\.host))
        lock.lock()
        hosts = trusted
        lock.unlock()
    }
}

// MARK: - HTTP

enum CatalogHTTP {
    /// 页面请求按站点限流：同一个源内部串行，不同源之间互不阻塞。
    /// 后台任务（更新日历补录、健康探测、跨源榜单）走单独的低优先通道，
    /// 用户点开的列表永远不会排在后台请求后面。
    private static let foregroundGates = PageGatePool()
    private static let backgroundGates = PageGatePool()

    private actor PageGatePool {
        private var gates: [String: CloudConcurrencyGate] = [:]

        func gate(for host: String, limit: Int) -> CloudConcurrencyGate {
            if let gate = gates[host] { return gate }
            let gate = CloudConcurrencyGate(limit: limit)
            gates[host] = gate
            return gate
        }
    }

    static func fetchPage(url: URL, source: CatalogSource) async throws -> String {
        try await fetchPage(url: url, source: source, accepting: [200])
    }

    /// 页面请求：命中 429 / 5xx 时退避重试。图集站会按 IP 限流，
    /// 打开分类或连续翻页时偶发的 429 直接重试即可，不必让用户手动点「重试」。
    static let pageRetryPolicy = HTTPRetryPolicy(maxRetries: 2, baseDelay: 0.8)

    /// 有些站点用非 200 状态码返回验证页（例如 492），此时也要把页面正文交给调用方处理。
    static func fetchPage(url: URL, source: CatalogSource,
                          accepting: Set<Int>) async throws -> String {
        let route = CatalogAddressRouter.route(url, source: source)
        do {
            return try await fetchPageOnce(url: route.url, source: route.source,
                                           accepting: accepting)
        } catch {
            // 站点主机连不上：去「永久地址 / 发布页」找当前镜像，再重试一次。
            guard route.isSiteRequest,
                  CatalogAddressRouter.isAddressFailure(error),
                  let base = await CatalogAddressResolver.shared.refresh(source)
            else { throw error }
            let pointed = CatalogAddressRouter.pointed(source, base: base)
            let retry = CatalogAddressRouter.route(url, source: source)
            // refresh 已经把镜像写进缓存，这里按原始源重新路由一次；
            // 若路由没改写（例如发布页本就是主站），再用 pointed 源补齐 Referer。
            let final = retry.url == url
                ? CatalogAddressRoute(url: url, source: pointed, isSiteRequest: true)
                : retry
            return try await fetchPageOnce(url: final.url, source: final.source,
                                           accepting: accepting)
        }
    }

    private static func fetchPageOnce(url: URL, source: CatalogSource,
                                      accepting: Set<Int>) async throws -> String {
        let host = url.host ?? source.host
        let background = CatalogRequestScope.isBackground
        let pool = background ? backgroundGates : foregroundGates
        let gate = await pool.gate(for: host, limit: background ? 1 : 2)
        await gate.acquire()
        defer { Task { await gate.release() } }
        let data = try await fetchData(url: url, headers: pageHeaders(source),
                                       accepting: accepting, retry: pageRetryPolicy)
        return String(decoding: data, as: UTF8.self)
    }

    /// 页面请求头：UA / 语言 / Referer，命中登录态站点时再带上用户粘贴的 Cookie。
    static func pageHeaders(_ source: CatalogSource) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": source.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": source.referer
        ]
        if let cookie = source.cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    static func fetchData(url: URL, headers: [String: String],
                          timeout: TimeInterval = 20,
                          accepting: Set<Int> = [200],
                          retry: HTTPRetryPolicy = .none) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(request, url: url, accepting: accepting, retry: retry)
    }

    static func postJSON(url: URL, headers: [String: String], body: Data,
                         timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(request, url: url)
    }

    private static func perform(_ request: URLRequest, url: URL,
                                accepting: Set<Int> = [200],
                                retry: HTTPRetryPolicy = .none) async throws -> Data {
        // 统一走 HTTPSourceTransport：UA / Referer / 自签证书 / 超时只在一处维护。
        let profile = RequestProfile(headers: RequestProfile.browser.headerFields,
                                    trustSelfSigned: CatalogTrust.isTrusted(url.host ?? ""))
        do {
            let response = try await HTTPSourceTransport.shared.send(
                HTTPTransportRequest(url: url,
                                     method: request.httpMethod ?? "GET",
                                     headers: request.allHTTPHeaderFields ?? [:],
                                     body: request.httpBody,
                                     timeout: request.timeoutInterval > 0 ? request.timeoutInterval : 20,
                                     throwsOnHTTPError: false),
                profile: profile,
                retryPolicy: retry
            )
            guard accepting.contains(response.statusCode) else {
                throw CatalogError.http(response.statusCode)
            }
            return response.data
        } catch let error as SourceError {
            // 现有 Provider 仍按 CatalogError 分支处理，这里做一层等价映射。
            switch error.kind {
            case .http:
                throw CatalogError.http(error.statusCode ?? 0)
            case .tlsUntrusted:
                throw CatalogError.tls(url.host ?? url.absoluteString)
            case .unavailable:
                throw CatalogError.unavailable(error.message)
            default:
                throw error
            }
        }
    }

    /// 导入配置 / 脚本时还没有源对象，用一组中性请求头。
    static func fetchText(url: URL) async throws -> String {
        let data = try await fetchData(url: url, headers: [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/plain,application/json,text/javascript,*/*;q=0.8"
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 轻量 HTML 正则

enum CatalogHTML {
    static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              group < match.numberOfRanges else { return nil }
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    static func fullMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// 从每个匹配的「标签结尾」切到下一个匹配的起点，等价于脚本里的 block 切片。
    static func blocks(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        return matches.enumerated().map { index, match in
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard end > start else { return "" }
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
    }

    static func stripTags(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"<[^>]*>"#, with: "",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: "&nbsp;", with: " ")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&#39;", with: "'")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 补全协议与站点前缀，并还原 HTML 实体。
    static func fixURL(_ raw: String, base: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("/") { value = base + value }
        return value
    }

    /// 从单个 `<img …>` 标签里挑「最大的一张」：
    /// `srcset` 的最大宽度项 > `data-original` / `data-src` / `data-lazy-src` > `src`。
    /// 图集站的正文常用 `src` 放缩略图，真正的原图只在懒加载属性或 `srcset` 里。
    static func bestImageURL(in tag: String, base: String) -> String? {
        if let srcset = first(#"srcset="([^"]+)""#, in: tag),
           let best = largestFromSrcset(srcset) {
            return fixURL(best, base: base)
        }
        for attribute in ["data-original", "data-src", "data-lazy-src", "data-echo", "data-url"] {
            if let raw = first(#"\#(attribute)="([^"]+)""#, in: tag),
               !raw.isEmpty, !raw.hasPrefix("data:") {
                return fixURL(raw, base: base)
            }
        }
        if let raw = first(#"<img[^>]+src="([^"]+)""#, in: tag),
           !raw.isEmpty, !raw.hasPrefix("data:") {
            return fixURL(raw, base: base)
        }
        return nil
    }

    /// `srcset` 里挑宽度最大的一项；`2x` 这类倍率按 2000w 量级折算，便于统一比较。
    private static func largestFromSrcset(_ srcset: String) -> String? {
        var best: (url: String, weight: Double)?
        for part in srcset.split(separator: ",") {
            let pieces = part.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard let url = pieces.first, !url.isEmpty else { continue }
            var weight = 1.0
            if pieces.count > 1 {
                let descriptor = pieces[1].lowercased()
                if descriptor.hasSuffix("w"), let value = Double(descriptor.dropLast()) {
                    weight = value
                } else if descriptor.hasSuffix("x"), let value = Double(descriptor.dropLast()) {
                    weight = value * 1000
                }
            }
            if best == nil || weight > best!.weight { best = (url, weight) }
        }
        return best?.url
    }
}
