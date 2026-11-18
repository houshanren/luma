import Foundation

// MARK: - 阿里云盘 Cookie / 令牌登录
//
// 官方 OAuth 需要自己创建开发者应用，很多人只想快速接入。
// 这里用网页登录后得到的 refresh_token（通常夹在浏览器 Cookie / 本地存储的 token 里），
// 通过 AList 的公共换 token 服务换取开放平台 access_token，不需要申请应用。

enum AliyunCookieAuth {
    static var authBase: String {
        ProcessInfo.processInfo.environment["PHOTOSCLONE_ALIYUN_TOKEN_BASE"]
            ?? "https://api.alistgo.com"
    }

    /// 从用户粘贴的 Cookie / token 文本里找出 refresh_token 并换取访问令牌。
    static func token(from input: String) async throws -> CloudToken {
        guard let refresh = extractRefreshToken(input) else {
            throw CloudOAuthError.api(
                "没找到登录凭据。请登录 alipan.com 后打开开发者工具 →「应用 / Application」→"
                + "「本地存储」→ https://www.alipan.com，展开 token，把里面的 refresh_token 整段复制过来。"
            )
        }
        return try await exchange(refreshToken: refresh)
    }

    static func exchange(refreshToken: String) async throws -> CloudToken {
        guard let url = URL(string: authBase + "/alist/ali_open/token") else {
            throw CloudOAuthError.token("地址无效")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200,
              let access = object["access_token"] as? String,
              !access.isEmpty else {
            let message = (object["message"] as? String)
                ?? (object["error"] as? String)
                ?? (object["error_description"] as? String)
                ?? "HTTP \(status)"
            throw CloudOAuthError.token(message)
        }
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue
            ?? (object["expires_in"] as? String).flatMap(Double.init)
            ?? 7200
        return CloudToken(accessToken: access,
                          refreshToken: (object["refresh_token"] as? String) ?? refreshToken,
                          expiresAt: Date().addingTimeInterval(max(300, expires - 60)))
    }

    /// 支持三种粘贴内容：
    /// 1. JSON / 表单里的 refresh_token（含 Cookie 中的 refresh_token=…）
    /// 2. 整段就是 refresh_token（以 ey 开头的一长串）
    /// 3. 只有 Cookie 时，用其中的 __puus 兜底尝试
    static func extractRefreshToken(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let patterns = [
            #""refresh_token"\s*:\s*"([^"]+)""#,
            #"refresh_token\s*=\s*([^;"\s&]+)"#
        ]
        for pattern in patterns {
            if let value = match(pattern, in: text), !value.isEmpty {
                return value
            }
        }

        // 直接粘贴了一整个 refresh_token。
        let compact = text.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        if compact.count > 40,
           !compact.contains(" "),
           !compact.contains(";"),
           !compact.contains("=") {
            return compact
        }

        return match(#"__puus=([^;"\s&]+)"#, in: text)
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: range),
              result.numberOfRanges > 1,
              let valueRange = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
