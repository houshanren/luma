import AppKit
import WebKit

/// 静默续期结果：新的 Cookie 头 + 最晚失效时间。
struct CatalogCookieRefreshResult: Sendable {
    var cookie: String
    var expiresAt: Date?
}

/// 登录态站点的自动续期：用一个隐藏的 WKWebView 带着现有 Cookie 重新访问站点，
/// 取回被刷新的 Cookie（论坛会话的 `lastvisit` / `_saltkey`、Cloudflare 的 `cf_clearance`）。
/// 整个过程不需要用户操作；会话真的过期时不会用游客 Cookie 覆盖，界面会提示重新粘贴。
@MainActor
final class CatalogCookieRefreshGate {
    static let shared = CatalogCookieRefreshGate()

    private var running: [UUID: Task<CatalogCookieRefreshResult?, Never>] = [:]

    func refresh(source: CatalogSource) async -> CatalogCookieRefreshResult? {
        if let existing = running[source.id] { return await existing.value }
        let task = Task { await Self.solve(source: source) }
        running[source.id] = task
        let result = await task.value
        running[source.id] = nil
        return result
    }

    private static func solve(source: CatalogSource) async -> CatalogCookieRefreshResult? {
        guard let url = URL(string: source.baseURL) else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
                             configuration: configuration)
        // UA 必须与后续 URLSession 请求一致：Cloudflare 的 clearance 绑定 UA。
        view.customUserAgent = source.userAgent
        // 放到屏幕外：既让 WebKit 正常跑定时器，又不打断用户当前窗口。
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 1280, height: 900),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer {
            view.stopLoading()
            window.orderOut(nil)
        }

        // 续期的语义是「带着现有登录态再访问一次」：从空白会话开始只会拿到游客 Cookie，
        // 覆盖回去等于把用户踢下线。
        let existing = source.cookie ?? ""
        if !existing.isEmpty {
            await injectCookies(existing, into: configuration.websiteDataStore, url: url)
        }

        view.load(URLRequest(url: url))
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let title = await evaluate(view, "document.title") ?? ""
            let lower = title.lowercased()
            let challenging = lower.contains("just a moment")
                || title.contains("请稍候")
                || title.contains("安全验证")
            if !challenging, !title.isEmpty { break }
        }

        let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard !header.isEmpty else { return nil }
        // 登录态已经在服务端失效：刷新结果里没有原来的鉴权 Cookie，
        // 这时保留旧 Cookie，等页面提示用户重新粘贴。
        guard keepsLoginState(existing: existing, refreshed: header) else { return nil }
        let expiry = cookies.filter { isAuthCookieName($0.name) }
            .compactMap(\.expiresDate)
            .max()
        return CatalogCookieRefreshResult(cookie: header, expiresAt: expiry)
    }

    /// 把 Cookie 头还原成 HTTPCookie 写进隐藏会话：域名按站点主机填，路径统一为根。
    private static func injectCookies(_ header: String,
                                      into store: WKWebsiteDataStore,
                                      url: URL) async {
        guard let host = url.host, !host.isEmpty else { return }
        let secure = url.scheme?.lowercased() == "https"
        for pair in header.components(separatedBy: ";") {
            let item = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = item.firstIndex(of: "=") else { continue }
            let name = item[item.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: host, .path: "/"
            ]
            if secure { properties[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            await store.httpCookieStore.setCookie(cookie)
        }
    }

    /// 登录态 Cookie 名：Discuz 只有登录成功才写 `*_auth`，论坛 / 通用站点多有 session / token。
    private static func isAuthCookieName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let keys = ["auth", "session", "token", "login", "member", "userid"]
        return keys.contains { lower.contains($0) }
    }

    /// 续期前有鉴权 Cookie、续期后全没了：说明会话已失效，不能用游客 Cookie 覆盖。
    private static func keepsLoginState(existing: String, refreshed: String) -> Bool {
        let beforeAuth = cookieNames(existing).filter(isAuthCookieName)
        guard !beforeAuth.isEmpty else { return true }
        return !cookieNames(refreshed).filter(isAuthCookieName).isEmpty
    }

    private static func cookieNames(_ header: String) -> [String] {
        header.components(separatedBy: ";").compactMap { pair in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            let name = pair[pair.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            return name.isEmpty ? nil : name
        }
    }

    private static func evaluate(_ view: WKWebView, _ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }
}
