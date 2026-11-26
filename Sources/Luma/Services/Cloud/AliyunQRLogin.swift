import Foundation
import CoreFoundation
import LumaContentCore

// MARK: - 阿里云盘扫码登录
//
// 走网页登录的二维码接口：应用内展示二维码，用户用阿里云盘 App 扫码确认后，
// 直接拿到网页登录的 refresh_token，再交给现有 Cookie 流程换取开放平台令牌。
// 好处是不需要开发者应用、不用离开应用去复制 Cookie。
//
// 状态机：NEW（待扫码）→ SCANED（已扫码待确认）→ CONFIRMED（确认，拿到令牌）；
// 二维码默认 120 秒过期，过期后由界面自动换一张。

enum AliyunQRLogin {
    struct Session: Equatable {
        var ck: String
        var t: String
        var codeContent: String
        var expiresAt: Date
    }

    enum Status: Equatable {
        case waiting
        case scanned
        case confirmed(refreshToken: String, accessToken: String?)
        /// 已确认，但这一轮响应里还没有登录凭据：继续轮询一次通常就有了。
        case confirmedWithoutCredential
        case expired
        case canceled
    }

    /// 允许本地联调时指向模拟服务。
    static var passportBase: String {
        ProcessInfo.processInfo.environment["LUMA_ALIYUN_QR_BASE"]
            ?? "https://passport.aliyundrive.com"
    }

    private static let appName = "aliyun_drive"
    private static let fromSite = "52"
    /// 接口按这个客户端版本校验；新版号（2.5.x）会返回 EXPIRED。
    private static let clientVersion = "2.0.31"
    private static let referer = "https://www.aliyundrive.com/"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// 本地兜底有效期：服务端没给时长时按 120 秒算。
    static let fallbackValidity: TimeInterval = 120

    static func generate() async throws -> Session {
        logLock.lock()
        loggedMissingCredential = false
        logLock.unlock()
        var components = URLComponents(string: passportBase + "/newlogin/qrcode/generate.do")
        components?.queryItems = [
            URLQueryItem(name: "appName", value: appName),
            URLQueryItem(name: "fromSite", value: fromSite),
            URLQueryItem(name: "appEntrance", value: "web"),
            URLQueryItem(name: "isMobile", value: "false"),
            URLQueryItem(name: "lang", value: "zh_CN"),
            URLQueryItem(name: "returnUrl", value: ""),
            URLQueryItem(name: "bizParams", value: ""),
            URLQueryItem(name: "_bx-v", value: clientVersion)
        ]
        guard let url = components?.url else {
            throw CloudOAuthError.api("扫码地址无效")
        }
        let object = try await get(url)
        guard let content = object["content"] as? [String: Any],
              let data = content["data"] as? [String: Any],
              let ck = data["ck"] as? String, !ck.isEmpty,
              let t = stringValue(data["t"]), !t.isEmpty else {
            throw CloudOAuthError.api(message(in: object) ?? "二维码生成失败，请稍后重试")
        }
        guard let code = data["codeContent"] as? String, !code.isEmpty else {
            throw CloudOAuthError.api("二维码内容为空，请稍后重试")
        }
        let ttl = (data["expiresIn"] as? NSNumber)?.doubleValue
            ?? (data["expiresIn"] as? String).flatMap(Double.init)
            ?? fallbackValidity
        return Session(ck: ck,
                       t: t,
                       codeContent: code,
                       expiresAt: Date().addingTimeInterval(max(60, min(ttl, 300))))
    }

    static func poll(_ session: Session) async throws -> Status {
        // 状态查询必须是 POST 表单：GET 会直接返回 EXPIRED。
        guard let url = URL(string: passportBase
                            + "/newlogin/qrcode/query.do?appName=\(appName)"
                            + "&fromSite=\(fromSite)&_bx-v=\(clientVersion)") else {
            throw CloudOAuthError.api("查询地址无效")
        }
        let object = try await post(url, form: [
            "t": session.t,
            "ck": session.ck,
            "appName": appName,
            "appEntrance": "web",
            "isMobile": "false",
            "lang": "zh_CN",
            "returnUrl": "",
            "fromSite": fromSite,
            "bizParams": "",
            "navlanguage": "zh-CN",
            "navPlatform": "MacIntel"
        ])
        guard let content = object["content"] as? [String: Any],
              let data = content["data"] as? [String: Any] else {
            // 还没轮询到状态：按「等待扫码」处理，不要直接报错。
            return .waiting
        }
        let raw = (data["qrCodeStatus"] as? String)
            ?? (data["qrCodeStatus"] as? NSNumber)?.stringValue
            ?? ""
        switch raw.uppercased() {
        case "NEW":
            return .waiting
        case "SCANED":
            return .scanned
        case "CONFIRMED":
            // 有的会话第一次确认时 bizExt 还没落下来：先继续轮询，不要立刻判失败。
            // 令牌可能在 data 里，也可能挂在 content 上，三层都找一遍。
            let refresh = firstString(for: "refresh_token", in: data)
                ?? firstString(for: "refresh_token", in: content)
                ?? firstString(for: "refresh_token", in: object)
                ?? firstString(for: "refreshToken", in: data)
                ?? firstString(for: "refreshToken", in: content)
                ?? firstString(for: "refresh-token", in: content)
            guard let refresh else {
                recordMissingCredential(content)
                return .confirmedWithoutCredential
            }
            return .confirmed(refreshToken: refresh,
                              accessToken: firstString(for: "access_token", in: content)
                                ?? firstString(for: "accessToken", in: content))
        case "EXPIRED":
            return .expired
        case "CANCELED", "CANCELLED":
            return .canceled
        default:
            return .waiting
        }
    }

    // MARK: - 内部

    private static func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.aliyundrive.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private static func post(_ url: URL, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.aliyundrive.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
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

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let text = raw as? String, !text.isEmpty { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func message(in object: [String: Any]) -> String? {
        if let content = object["content"] as? [String: Any] {
            if let text = content["message"] as? String, !text.isEmpty { return text }
            if let text = content["resultMsg"] as? String, !text.isEmpty { return text }
        }
        if let text = object["message"] as? String, !text.isEmpty { return text }
        return nil
    }

    /// 在任意层级的 JSON 里找第一个非空字符串。
    /// 确认登录后令牌藏在 base64 的 bizExt 里，偶尔还会被套两层 JSON 或 URL 编码。
    private static func firstString(for key: String, in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let text = dict[key] as? String, !text.isEmpty { return text }
            for nested in dict.values {
                if let found = firstString(for: key, in: nested) { return found }
            }
        } else if let list = value as? [Any] {
            for nested in list {
                if let found = firstString(for: key, in: nested) { return found }
            }
        } else if let text = value as? String {
            if let decoded = decodeBizExt(text),
               let found = firstString(for: key, in: decoded) { return found }
        }
        return nil
    }

    /// bizExt 兼容：JSON 文本、标准 / URL-safe base64、被二次编码的 JSON 字符串、十六进制。
    private static func decodeBizExt(_ raw: String, depth: Int = 0) -> Any? {
        guard depth < 3 else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let unescaped = text.removingPercentEncoding, unescaped != text {
            text = unescaped
        }
        if text.hasPrefix("{") || text.hasPrefix("["),
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            return unwrap(object, depth: depth)
        }
        for candidate in base64Candidates(text) {
            guard let data = Data(base64Encoded: candidate,
                                  options: [.ignoreUnknownCharacters]) else { continue }
            if let object = jsonObject(from: data) {
                return unwrap(object, depth: depth)
            }
            if let nestedText = string(from: data),
               nestedText != text,
               let nested = decodeBizExt(nestedText, depth: depth + 1) {
                return nested
            }
        }
        if let data = hexData(text),
           let nestedText = string(from: data),
           nestedText != text,
           let nested = decodeBizExt(nestedText, depth: depth + 1) {
            return nested
        }
        return nil
    }

    /// 登录响应里的中文昵称是 GB18030 编码：直接按 UTF-8 解析会让整段 JSON 失败。
    /// 这里逐级降级，保证只有中文字段被影响，令牌等 ASCII 字段始终能拿到。
    private static func jsonObject(from data: Data) -> Any? {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        // 1) 去掉 BOM 后重试：部分响应会在 JSON 前带 U+FEFF。
        if let text = String(data: data, encoding: .utf8) {
            if let object = parse(json: text) { return object }
        }
        // 2) GB18030 严格解码：把中文双字节还原成 Unicode 再解析。
        if let text = String(data: data, encoding: gb18030),
           let object = parse(json: text) { return object }
        // 3) 宽松 UTF-8：非法字节替换成 U+FFFD，JSON 结构仍是 ASCII，令牌字段不受影响。
        let lenient = String(decoding: data, as: UTF8.self)
        if let object = parse(json: lenient) { return object }
        // 4) 单字节兜底。
        if let text = String(data: data, encoding: .isoLatin1),
           let object = parse(json: text) { return object }
        return nil
    }

    private static func parse(json text: String) -> Any? {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = body.first, first == "{" || first == "[" else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
    }

    private static func string(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: gb18030) { return text }
        return nil
    }

    private static var gb18030: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    }

    private static func base64Candidates(_ text: String) -> [String] {
        var result = [text]
        let compact = text.filter { !$0.isWhitespace }
        if compact != text { result.append(compact) }
        var urlSafe = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while urlSafe.count % 4 != 0 { urlSafe += "=" }
        if urlSafe != text { result.append(urlSafe) }
        return result
    }

    private static func hexData(_ text: String) -> Data? {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 8, compact.count % 2 == 0,
              compact.allSatisfy({ $0.isHexDigit }) else { return nil }
        var data = Data(capacity: compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func unwrap(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 3, let text = value as? String, !text.isEmpty else { return value }
        if let nested = decodeBizExt(text, depth: depth + 1) { return nested }
        return value
    }

    /// 只记结构不记值：确认后拿不到令牌时用它排查响应字段有没有变化。
    private static func outline(_ value: Any, depth: Int = 0) -> String {
        guard depth <= 2, let dict = value as? [String: Any] else { return "…" }
        return dict.keys.sorted().map { key -> String in
            let nested = dict[key] as Any
            if let text = nested as? String { return "\(key):String(\(text.count))" }
            if nested is [String: Any] { return "\(key){\(outline(nested, depth: depth + 1))}" }
            if nested is [Any] { return "\(key):Array" }
            return "\(key):\(type(of: nested))"
        }.joined(separator: ",")
    }

    private static let logLock = NSLock()
    private static var loggedMissingCredential = false

    /// 只记响应结构，不记任何令牌值；用于接口字段变动时排查。
    private static func recordMissingCredential(_ data: [String: Any]) {
        logLock.lock()
        defer { logLock.unlock() }
        guard !loggedMissingCredential else { return }
        loggedMissingCredential = true
        var detail = "content{\(outline(data))}"
        let biz = (data["bizExt"] as? String)
            ?? ((data["data"] as? [String: Any])?["bizExt"] as? String)
        if let biz {
            if let decoded = decodeBizExt(biz) {
                detail += "；bizExt{\(outline(decoded))}"
            } else {
                detail += "；bizExt(未解码) \(bizExtFingerprint(biz))"
                dumpBizExt(biz)
            }
        }
        Diagnostics.record("阿里云盘扫码：CONFIRMED 未解析到令牌，\(detail)")
    }

    private static func bizExtFingerprint(_ raw: String) -> String {
        let compact = raw.filter { !$0.isWhitespace }
        let base64OK = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) != nil
        return "len=\(raw.count) head=\(compact.prefix(6)) base64=\(base64OK) hex=\(hexData(raw) != nil)"
            + " dots=\(compact.filter { $0 == "." }.count) eq=\(compact.filter { $0 == "=" }.count)"
    }

    /// 解码失败时把原始 bizExt 落到日志目录，便于离线分析编码（不进主日志，避免刷屏）。
    private static func dumpBizExt(_ raw: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Luma", isDirectory: true)
        let file = dir.appendingPathComponent("qr-bizext.txt")
        var text = "=== \(ISO8601DateFormatter().string(from: Date())) len=\(raw.count)\n\(raw)\n"
        if let data = Data(base64Encoded: raw.filter { !$0.isWhitespace },
                           options: [.ignoreUnknownCharacters]) {
            text += "--- decoded bytes=\(data.count) hexHead=\(data.prefix(32).map { String(format: "%02x", $0) }.joined())\n"
            text += String(decoding: data, as: UTF8.self) + "\n"
        }
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            text = existing + text
        }
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    static let session = HTTPSessionPool.shared.session(.cloud)
}
