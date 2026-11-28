import Foundation

/// 粘贴 Cookie 的点击验证结果。
enum CatalogCookieVerification: Equatable {
    case success(String)
    case failure(String)
}

/// 用待保存的 Cookie 真发一次页面请求，确认站点是否认这份登录态。
/// 只看 Cookie 字段无法判断游客 / 登录（Discuz 游客也会写一堆 `*_sid` 之类的 Cookie），
/// 必须看站点返回的页面。
@MainActor
enum CatalogCookieVerifier {
    static func verify(source: CatalogSource, cookie: String) async -> CatalogCookieVerification {
        var probe = source
        probe.cookie = CatalogBrowserModel.normalizedCookie(cookie)
        guard let value = probe.cookie, !value.isEmpty else {
            return .failure("请先粘贴 Cookie。")
        }
        guard let root = try? WebCatalogSupport.root(probe) else {
            return .failure("站点地址无效，无法验证。")
        }
        switch source.kind {
        case .wuso:
            // Discuz 页头：游客看到「登錄 / 立即註冊」，登录成功才出现「退出」。
            do {
                let html = try await WebCatalogSupport.fetchHTML(root, source: probe)
                if html.contains("立即註冊") || html.contains("立即注册") {
                    return .failure("仍是游客状态：这份 Cookie 里没有登录态（缺少 *_auth），请在浏览器登录后重新复制。")
                }
                if html.contains("退出") || html.contains("退出登录") {
                    return .success("验证通过：站点已识别为登录状态。")
                }
                return .failure("无法确认登录状态：站点页面里既没有「退出」也没有登录表单，请刷新浏览器后重新复制 Cookie。")
            } catch {
                return .failure("验证失败：\(error.localizedDescription)")
            }
        case .v2ph:
            // Cloudflare 站点没有固定页面能判断账号登录，只能确认校验已通过、页面能正常返回。
            do {
                _ = try await WebCatalogSupport.fetchHTML(root, source: probe)
                return .success("验证通过：站点可正常访问，Cloudflare 校验已通过。")
            } catch let error as CatalogError {
                if case .http(let status) = error, status == 403 || status == 492 {
                    return .failure("Cloudflare 校验未通过：请在浏览器里打开一次站点，再复制最新的 Cookie。")
                }
                return .failure("验证失败：\(error.localizedDescription)")
            } catch {
                return .failure("验证失败：\(error.localizedDescription)")
            }
        default:
            do {
                _ = try await WebCatalogSupport.fetchHTML(root, source: probe)
                return .success("验证通过：站点可正常访问。")
            } catch {
                return .failure("验证失败：\(error.localizedDescription)")
            }
        }
    }
}
