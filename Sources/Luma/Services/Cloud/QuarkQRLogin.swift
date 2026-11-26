import Foundation
import CoreFoundation
import LumaContentCore

// MARK: - 夸克网盘扫码登录
//
// 走夸克开放平台的二维码接口：应用内展示二维码，用户用夸克 App 扫码确认后，
// 直接拿到登录 Cookie，即可调用 QuarkDrive 的 list/videoPlayURL/downloadURL。
// 比阿里云盘更简单：扫码成功后直接获得完整 Cookie，不需要二次 token 交换。
//
// 状态机：waiting（待扫码）→ confirmed（确认，拿到 Cookie）；
// 二维码默认 120 秒过期，过期后由界面自动换一张。

enum QuarkQRLogin {
    struct Session: Equatable {
        var token: String
        var codeContent: String
        var expiresAt: Date
    }

    enum Status: Equatable {
        case waiting
        case confirmed(cookie: String)
        case expired
        case failed
    }

    /// 允许本地联调时指向模拟服务。
    static var apiBase: String {
        ProcessInfo.processInfo.environment["LUMA_QUARK_QR_BASE"]
            ?? "https://uop.quark.cn"
    }

    private static let clientID = "532"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private static let referer = "https://pan.quark.cn"

    /// 本地兜底有效期：服务端没给时长时按 120 秒算。
    static let fallbackValidity: TimeInterval = 120

    /// 生成二维码：调 getTokenForQrcodeLogin 获取 token，
    /// 拼接成扫码 URL（StyledQRCode 直接用此 URL 渲染）。
    static func generate() async throws -> Session {
        let requestID = UUID().uuidString
        var components = URLComponents(string: apiBase + "/cas/ajax/getTokenForQrcodeLogin")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: requestID)
        ]
        guard let url = components?.url else {
            throw CloudOAuthError.api("扫码地址无效")
        }
        let object = try await get(url)
        guard let data = object["data"] as? [String: Any],
              let members = data["members"] as? [String: Any],
              let token = members["token"] as? String, !token.isEmpty else {
            throw CloudOAuthError.api(message(in: object) ?? "二维码生成失败，请稍后重试")
        }
        let qrURL = "https://su.quark.cn/4_eMHBJ?token=\(token)"
            + "&client_id=\(clientID)&ssb=weblogin&uc_param_str="
            + "&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0"
        return Session(token: token,
                       codeContent: qrURL,
                       expiresAt: Date().addingTimeInterval(fallbackValidity))
    }

    /// 轮询扫码状态：调 getServiceTicketByQrcodeToken，
    /// 返回 waiting / expired / failed / confirmed(cookie:)。
    /// 确认后自动用 service_ticket 换取完整登录 Cookie。
    static func poll(token: String) async throws -> Status {
        let requestID = UUID().uuidString
        var components = URLComponents(string: apiBase + "/cas/ajax/getServiceTicketByQrcodeToken")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "request_id", value: requestID)
        ]
        guard let url = components?.url else {
            throw CloudOAuthError.api("查询地址无效")
        }
        let object = try await get(url)
        let status = (object["status"] as? NSNumber)?.intValue ?? 0
        let data = object["data"] as? [String: Any] ?? [:]
        let members = data["members"] as? [String: Any] ?? [:]

        // 夸克扫码接口的状态码：
        //   2000000 = 已确认，拿到 service_ticket
        //   50004001 = 等待扫码（"Query result is empty"）
        //   其他未知码保守按等待处理，由本地 expiresAt 控制超时。
        if status == 2000000, let ticket = members["service_ticket"] as? String, !ticket.isEmpty {
            let cookie = try await exchange(serviceTicket: ticket)
            return .confirmed(cookie: cookie)
        }
        return .waiting
    }

    /// 用 service_ticket 换取登录 Cookie：调 pan.quark.cn/account/info，
    /// 从响应头的 Set-Cookie 提取完整 Cookie 字符串。
    static func exchange(serviceTicket: String) async throws -> String {
        guard let url = URL(string: "https://pan.quark.cn/account/info?st=\(serviceTicket)&lw=scan") else {
            throw CloudOAuthError.api("登录地址无效")
        }
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        // 使用临时 session：不自动跟随重定向、不读写共享 Cookie 存储，
        // 直接从响应头提取 Set-Cookie，避免混入其它请求的 Cookie。
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        let tempSession = URLSession(configuration: config)

        let (_, response) = try await tempSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudOAuthError.api("无法获取 Cookie")
        }

        // allHeaderFields 对重名 Set-Cookie 会合并为逗号分隔；HTTPCookie 解析器能处理。
        let headers = httpResponse.allHeaderFields as? [String: String] ?? [:]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)

        guard !cookies.isEmpty else {
            throw CloudOAuthError.api("登录响应未包含 Cookie，请重试")
        }

        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: 内部

    private static func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CloudOAuthError.api("扫码接口返回 HTTP \(status)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudOAuthError.api("扫码接口返回内容无法解析")
        }
        return object
    }

    private static func message(in object: [String: Any]) -> String? {
        if let text = object["message"] as? String, !text.isEmpty { return text }
        if let content = object["content"] as? [String: Any],
           let text = content["message"] as? String, !text.isEmpty { return text }
        return nil
    }

    static let session = HTTPSessionPool.shared.session(.cloud)
}