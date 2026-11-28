import Foundation
import LumaContentCore

/// 已解析的可用地址：放在内存 + UserDefaults，拼 URL 时同步读取，不必 await。
/// key 用「站点类型 + 原始域名」，同一台机器上的不同源互不影响。
enum CatalogAddressCache {
    private static let storageKey = "catalog.address.resolved.v1"
    private static let lock = NSLock()
    private static var values: [String: String]?

    static func key(kind: CatalogProviderKind, host: String) -> String {
        "\(kind.rawValue)|\(host.lowercased())"
    }

    static func base(kind: CatalogProviderKind, host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return values?[key(kind: kind, host: host)]
    }

    static func store(_ base: String, kind: CatalogProviderKind, host: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        values?[key(kind: kind, host: host)] = base
        UserDefaults.standard.set(values, forKey: storageKey)
    }

    static func clear(kind: CatalogProviderKind, host: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        values?[key(kind: kind, host: host)] = nil
        UserDefaults.standard.set(values, forKey: storageKey)
    }

    private static func loadIfNeeded() {
        guard values == nil else { return }
        values = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}

/// 一次请求的落点：可能已经把原始域名换成了发布页找到的镜像。
struct CatalogAddressRoute {
    var url: URL
    var source: CatalogSource
    /// 请求落在站点主机（而不是 CDN / 图床）：只有这类失败才值得重新找地址。
    var isSiteRequest: Bool
}

/// 把「原始地址 / 已解析镜像」统一改写到当前可用地址。
enum CatalogAddressRouter {
    static func route(_ url: URL, source: CatalogSource) -> CatalogAddressRoute {
        guard source.kind.usesGenericAddressResolver, let host = url.host?.lowercased() else {
            return CatalogAddressRoute(url: url, source: source, isSiteRequest: false)
        }
        let originalHost = source.host
        guard let base = CatalogAddressCache.base(kind: source.kind, host: originalHost),
              let baseURL = URL(string: base) else {
            return CatalogAddressRoute(url: url, source: source,
                                       isSiteRequest: host == originalHost)
        }
        if host == originalHost {
            return CatalogAddressRoute(url: rewrite(url, to: baseURL),
                                       source: pointed(source, base: base),
                                       isSiteRequest: true)
        }
        if host == baseURL.host?.lowercased() {
            return CatalogAddressRoute(url: url,
                                       source: pointed(source, base: base),
                                       isSiteRequest: true)
        }
        return CatalogAddressRoute(url: url, source: source, isSiteRequest: false)
    }

    /// 源的 baseURL / Referer 指向实际使用的镜像，页面、相对链接与封面都落在同一台。
    static func pointed(_ source: CatalogSource, base: String) -> CatalogSource {
        var copy = source
        let trimmed = trim(base)
        copy.baseURL = trimmed
        copy.referer = trimmed + "/"
        return copy
    }

    static func trim(_ base: String) -> String {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 只换 scheme / host / port，保留原请求的路径与查询串。
    static func rewrite(_ url: URL, to base: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let baseComps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return url }
        comps.scheme = baseComps.scheme ?? comps.scheme
        comps.host = baseComps.host
        comps.port = baseComps.port
        let requestPath = comps.path.hasPrefix("/") ? comps.path : "/" + comps.path
        comps.path = requestPath
        return comps.url ?? url
    }

    /// 封面这类直接拼出来的绝对地址：主机是原始域名时也跟着镜像走。
    static func rewriteSiteURL(_ url: URL, source: CatalogSource) -> URL {
        guard source.kind.usesGenericAddressResolver,
              url.host?.lowercased() == source.host,
              let base = CatalogAddressCache.base(kind: source.kind, host: source.host),
              let baseURL = URL(string: base) else { return url }
        return rewrite(url, to: baseURL)
    }

    /// 有缓存镜像时把源的 baseURL / Referer 一起指过去；没有就原样返回。
    static func currentSource(_ source: CatalogSource) -> CatalogSource {
        guard source.kind.usesGenericAddressResolver,
              let base = CatalogAddressCache.base(kind: source.kind, host: source.host)
        else { return source }
        return pointed(source, base: base)
    }

    /// 只有「地址失效」类错误才值得换域名重试：连不上、超时、5xx、WAF、证书被劫持。
    static func isAddressFailure(_ error: Error) -> Bool {
        if let error = error as? CatalogError {
            switch error {
            case .unavailable, .tls:
                return true
            case .http(let status):
                return status == 0 || status >= 500 || status == 403
            default:
                return false
            }
        }
        if let error = error as? SourceError {
            switch error.kind {
            case .unavailable, .blocked, .tlsUntrusted:
                return true
            case .http:
                return (error.statusCode ?? 0) >= 500
            default:
                return false
            }
        }
        return false
    }
}

/// 站点永久地址 / 最新地址发布页的解析器。
///
/// 木瓜（91全集）、91吃瓜、91porna 共用这套：
/// 1. 主站能连 → 直接用主站；
/// 2. 主站连不上 → 抓源里配置的「永久地址 / 发布页」（缺省按站点类型内置）；
/// 3. 发布页本身可能就是站点（91porna 这类永久入口），先直接探测；
/// 4. 否则收集页面里的链接与脚本域名，并发探测，命中第一个可用地址就缓存。
///
/// 黄果保留自己的轮换子域解析（`HuangguoAddressResolver`），但同样优先读这里的配置页。
actor CatalogAddressResolver {
    static let shared = CatalogAddressResolver()

    private var inFlight: [String: Task<String?, Never>] = [:]
    /// 一次都没找到时短时间不再反复打发布页。
    private var lastFailure: [String: Date] = [:]

    /// 找一次当前可用地址：失败返回 nil，调用方继续用原地址。
    func refresh(_ source: CatalogSource) async -> String? {
        guard source.kind.usesGenericAddressResolver else { return nil }
        let key = CatalogAddressCache.key(kind: source.kind, host: source.host)
        if let failedAt = lastFailure[key], Date().timeIntervalSince(failedAt) < 60 {
            return CatalogAddressCache.base(kind: source.kind, host: source.host)
        }
        if let task = inFlight[key] { return await task.value }

        let original = CatalogAddressRouter.trim(source.baseURL)
        let task = Task<String?, Never> { [source, original] in
            if await Self.probeSite(original, source: source) {
                return original
            }
            guard !Task.isCancelled else { return nil }
            return await Self.discover(source: source)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        guard !Task.isCancelled else { return result }
        if let result {
            CatalogAddressCache.store(result, kind: source.kind, host: source.host)
            lastFailure[key] = nil
            Diagnostics.record("地址发布页：\(source.name) 切换到 \(result)")
        } else {
            lastFailure[key] = Date()
            Diagnostics.record("地址发布页：\(source.name) 没有找到可用地址")
        }
        return result
    }

    // MARK: - 发布页

    private static func discover(source: CatalogSource) async -> String? {
        // 发布页地址：源里显式配置的优先，否则按站点类型内置。
        var pageURLs: [URL] = []
        if let raw = source.effectiveAddressPageURL,
           let url = URL(string: raw) {
            pageURLs.append(url)
        }
        guard !pageURLs.isEmpty else { return nil }

        // 1. 发布页本身可能就是站点（91porna 的永久入口），先直接探测，
        //    命中就用它重定向后的实际域名，省掉后面的候选收集。
        for page in pageURLs {
            if let (html, finalURL) = await fetch(page, source: source, timeout: 8),
               looksLikeSite(html, kind: source.kind) {
                return origin(finalURL)
            }
        }
        guard !Task.isCancelled else { return nil }

        // 2. 抓发布页（可能带「地址发布页」再跟一层）。
        var pages: [(page: URL, html: String)] = []
        await withTaskGroup(of: (URL, String?, URL?).self) { group in
            for page in pageURLs {
                group.addTask {
                    guard let (html, finalURL) = await fetch(page, source: source, timeout: 6)
                    else { return (page, nil, nil) }
                    return (page, html, finalURL)
                }
            }
            for await (page, html, finalURL) in group {
                if let html { pages.append((finalURL ?? page, html)) }
            }
        }
        guard !Task.isCancelled, !pages.isEmpty else { return nil }

        var extraLinks: [URL] = []
        for (page, html) in pages {
            for link in anchorLinks(in: html, base: page) where shouldFollow(link, from: page) {
                extraLinks.append(link)
            }
        }
        if !extraLinks.isEmpty {
            let limited = Array(extraLinks.prefix(3))
            await withTaskGroup(of: (URL, String?, URL?).self) { group in
                for link in limited {
                    group.addTask {
                        guard let (html, finalURL) = await fetch(link, source: source, timeout: 6)
                        else { return (link, nil, nil) }
                        return (link, html, finalURL)
                    }
                }
                for await (page, html, finalURL) in group {
                    if let html { pages.append((finalURL ?? page, html)) }
                }
            }
        }
        guard !Task.isCancelled else { return nil }

        // 3. 汇总候选域名（轮换子域 + 页面链接 + 脚本里裸露的域名）。
        var candidates: [URL] = []
        var seenHosts = Set<String>()
        for (page, html) in pages {
            for candidate in candidateURLs(in: html, page: page) {
                guard let host = candidate.host?.lowercased(),
                      host != page.host?.lowercased(),
                      seenHosts.insert(host).inserted else { continue }
                candidates.append(candidate)
            }
        }
        guard !candidates.isEmpty else { return nil }

        // 4. 并发探测，命中一个立刻返回。
        let probes = Array(candidates.prefix(16))
        return await withTaskGroup(of: String?.self) { group in
            for candidate in probes {
                group.addTask {
                    guard let (html, finalURL) = await fetch(candidate, source: source, timeout: 6),
                          looksLikeSite(html, kind: source.kind) else { return nil }
                    return origin(finalURL)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    // MARK: - 探测

    private static func probeSite(_ base: String, source: CatalogSource) async -> Bool {
        guard let url = URL(string: base + "/"),
              let (html, _) = await fetch(url, source: source),
              looksLikeSite(html, kind: source.kind) else { return false }
        return true
    }

    /// 取页面正文与重定向后的最终地址：发布页常把网关放在 sp123.cc/mugua 这类路径上，
    /// 只有最终地址才是真正要缓存的站点。
    private static func fetch(_ url: URL,
                              source: CatalogSource,
                              timeout: TimeInterval = 6) async -> (String, URL)? {
        let request = HTTPTransportRequest(
            url: url,
            method: "GET",
            headers: [
                "User-Agent": source.userAgent,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9"
            ],
            timeout: timeout,
            throwsOnHTTPError: false
        )
        let profile = RequestProfile(headers: RequestProfile.browser.headerFields,
                                     trustSelfSigned: CatalogTrust.isTrusted(url.host ?? ""))
        guard let response = try? await HTTPSourceTransport.shared.send(
            request, profile: profile, retryPolicy: .none
        ), (200..<400).contains(response.statusCode) else { return nil }
        let html = String(decoding: response.data, as: UTF8.self)
        guard !html.isEmpty else { return nil }
        return (html, response.finalURL ?? url)
    }

    /// 主站标记：发布页一般只有几 KB，真正的站点首页有大量卡片与导航。
    private static func looksLikeSite(_ html: String, kind: CatalogProviderKind) -> Bool {
        guard html.count > 12_000 else { return false }
        switch kind {
        case .quanji:
            // 发布页也会写「木瓜」，只有详情链接才是真正的站点首页。
            return html.contains("watch.jsp?v=")
        case .ninetyOne:
            return html.contains("post-card")
        case .ninetyOnePorna:
            return html.contains("91porn") && html.contains("heiliao")
        case .huangguo:
            return html.contains("hg-drama-card") || html.contains("data-nav-key=\"home\"")
        default:
            return true
        }
    }

    private static func origin(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return CatalogAddressRouter.trim(url.absoluteString)
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        return CatalogAddressRouter.trim(comps.url?.absoluteString ?? url.absoluteString)
    }

    // MARK: - 候选地址

    private static func anchorLinks(in html: String, base: URL) -> [URL] {
        CatalogHTML.fullMatches(#"<a[^>]+href="[^"]+""#, in: html).compactMap { anchor in
            guard let raw = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                  let url = URL(string: raw, relativeTo: base)?.absoluteURL else { return nil }
            return url
        }
    }

    private static func shouldFollow(_ url: URL, from page: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host != page.host?.lowercased(),
              !isExcluded(host) else { return false }
        let path = url.path.lowercased()
        let assets = [".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".webp",
                      ".svg", ".ico", ".mp4", ".m3u8", ".zip"]
        return !assets.contains(where: { path.hasSuffix($0) })
    }

    private static func candidateURLs(in html: String, page: URL) -> [URL] {
        var raws = CatalogHTML.fullMatches(#"https?://[^\s"'<>\\]+"#, in: html)
        raws += CatalogHTML.fullMatches(#"['"]([a-zA-Z0-9-]+\.[a-z]{2,}(?:/[^'"]*)?)['"]"#, in: html)
            .compactMap { CatalogHTML.first(#"['"]([^'"]+)['"]"#, in: $0) }
        raws += CatalogHTML.fullMatches(#"//[a-zA-Z0-9.-]+\.[a-z]{2,}[^\s"'<>\\]*"#, in: html)

        var result: [URL] = []
        for raw in raws {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("//") { text = "https:" + text }
            if !text.lowercased().hasPrefix("http") { text = "https://" + text }
            guard let url = URL(string: text), let host = url.host?.lowercased(),
                  !isExcluded(host) else { continue }
            let path = url.path.lowercased()
            guard !path.hasSuffix(".css"), !path.hasSuffix(".js"), !path.hasSuffix(".png"),
                  !path.hasSuffix(".jpg"), !path.hasSuffix(".jpeg"), !path.hasSuffix(".gif"),
                  !path.hasSuffix(".webp"), !path.hasSuffix(".svg"), !path.hasSuffix(".ico")
            else { continue }
            result.append(url)
        }
        return result
    }

    private static func isExcluded(_ host: String) -> Bool {
        let blocked = [
            "twitter.com", "x.com", "t.me", "telegram", "telegram.org",
            "facebook.com", "instagram.com", "youtube.com", "youtu.be",
            "google.", "gstatic", "googleapis", "googlesyndication",
            "googletagmanager", "doubleclick", "amazon-adsystem",
            "baidu.com", "cnzz.com", "51.la", "weibo.com", "weibo.cn",
            "qq.com", "gmail", "mailto", "outlook", "cloudflare.com",
            "jsdelivr.net", "unpkg.com", "bootstrapcdn.com", "cdnjs.cloudflare.com"
        ]
        return blocked.contains { host.contains($0) }
    }
}
