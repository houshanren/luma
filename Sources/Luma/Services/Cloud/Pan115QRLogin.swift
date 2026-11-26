import Foundation
import CoreFoundation
import LumaContentCore

// MARK: - 115 网盘扫码登录
//
// 115 的扫码登录分三步：
//   1. GET  qrcodeapi.115.com/api/1.0/web/1.0/token/   → uid / time / sign / qrcode
//   2. GET  qrcodeapi.115.com/get/status/            → 轮询扫码状态
//   3. POST passportapi.115.com/app/1.0/{app}/1.0/login/qrcode/ → 拿到 UID/CID/SEID/KID
//
// 第 3 步会把「扫码设备」绑定为指定端。默认用 tv：
// 用 web 或手机端扫码会把已登录的同端设备挤下线，tv 端几乎没有副作用。

enum Pan115QRLogin {
    struct Session: Equatable {
        var uid: String
        var time: Int
        var sign: String
        var codeContent: String
        var expiresAt: Date
    }

    enum Status: Equatable {
        case waiting
        case scanned
        case confirmed(cookie: String)
        case expired
        case failed
    }

    /// 允许本地联调时指向模拟服务。
    static var apiBase: String {
        ProcessInfo.processInfo.environment["LUMA_115_QR_BASE"]
            ?? "https://qrcodeapi.115.com"
    }

    /// 扫码绑定的设备端。tv 不会挤掉手机 / 网页的登录状态。
    static let bindApp = "tv"

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// 本地兜底有效期：115 未直接给出时长，按 120 秒算。
    static let fallbackValidity: TimeInterval = 120

    /// 生成二维码：拿 uid / time / sign，qrcode 字段就是二维码内容。
    static func generate() async throws -> Session {
        guard let url = URL(string: apiBase + "/api/1.0/web/1.0/token/") else {
            throw CloudOAuthError.api("扫码地址无效")
        }
        let object = try await send(makeRequest(url))
        guard let data = object["data"] as? [String: Any],
              let uid = text(data["uid"]), !uid.isEmpty,
              let sign = text(data["sign"]), !sign.isEmpty,
              let qrcode = text(data["qrcode"]), !qrcode.isEmpty else {
            throw CloudOAuthError.api(message(in: object) ?? "二维码生成失败，请稍后重试")
        }
        let time = (data["time"] as? NSNumber)?.intValue ?? Int(Date().timeIntervalSince1970)
        return Session(uid: uid,
                       time: time,
                       sign: sign,
                       codeContent: qrcode,
                       expiresAt: Date().addingTimeInterval(fallbackValidity))
    }

    /// 轮询扫码状态。
    /// 115 的状态码：0 未扫码、1 已扫码待确认、2 已登录、-1 过期、-2 取消。
    /// `data` 为空时视为未扫码，交给界面按 expiresAt 兜底。
    static func poll(_ session: Session) async throws -> Status {
        var components = URLComponents(string: apiBase + "/get/status/")
        components?.queryItems = [
            URLQueryItem(name: "uid", value: session.uid),
            URLQueryItem(name: "time", value: String(session.time)),
            URLQueryItem(name: "sign", value: session.sign)
        ]
        guard let url = components?.url else {
            throw CloudOAuthError.api("查询地址无效")
        }
        let object = try await send(makeRequest(url))
        let data = object["data"] as? [String: Any] ?? [:]
        let status = (data["status"] as? NSNumber)?.intValue

        switch status {
        case 2:
            let cookie = try await fetchCookie(uid: session.uid)
            return .confirmed(cookie: cookie)
        case 1:
            return .scanned
        case -1, -2:
            return .expired
        default:
            return .waiting
        }
    }

    /// 用 uid 换取登录 Cookie：POST 登录接口，响应里的 data.cookie 就是凭据。
    static func fetchCookie(uid: String) async throws -> String {
        guard let url = URL(string: "https://passportapi.115.com/app/1.0/\(bindApp)/1.0/login/qrcode/") else {
            throw CloudOAuthError.api("登录地址无效")
        }
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "app=\(bindApp)&account=\(uid)".data(using: .utf8)

        let object = try await send(request)
        guard let data = object["data"] as? [String: Any],
              let cookies = data["cookie"] as? [String: Any], !cookies.isEmpty else {
            throw CloudOAuthError.api(message(in: object) ?? "登录成功但未获取到 Cookie")
        }

        // UID / CID / SEID / KID 是 Pan115Drive 依赖的四个字段，固定放在前面，
        // 其余字段原样追加，避免不同设备返回额外字段时丢失。
        let ordered = ["UID", "CID", "SEID", "KID"]
        var parts: [String] = []
        for name in ordered {
            if let value = text(cookies[name]), !value.isEmpty {
                parts.append("\(name)=\(value)")
            }
        }
        for (name, value) in cookies where !ordered.contains(name) {
            if let value = text(value), !value.isEmpty {
                parts.append("\(name)=\(value)")
            }
        }
        guard !parts.isEmpty else {
            throw CloudOAuthError.api("Cookie 内容为空，请重试")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: 内部

    private static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://115.com", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CloudOAuthError.api("115 扫码接口返回 HTTP \(status)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudOAuthError.api("115 扫码接口返回内容无法解析")
        }
        return object
    }

    /// 115 的部分字段可能是数字（如 KID），统一转成字符串。
    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func message(in object: [String: Any]) -> String? {
        if let text = object["message"] as? String, !text.isEmpty { return text }
        if let text = object["error"] as? String, !text.isEmpty { return text }
        return nil
    }

    static let session = HTTPSessionPool.shared.session(.cloud)
}
