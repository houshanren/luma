import Foundation
import AppKit
import Network
import ImageIO

// MARK: - 错误

enum CloudOAuthError: LocalizedError {
    case missingCredentials
    case unsupportedProvider
    case notAuthorized
    case invalidCallback
    case stateMismatch
    case cancelled
    case timeout
    case token(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请先填写该平台的 AppID / AppSecret"
        case .unsupportedProvider: return "该接入方式不支持此操作"
        case .notAuthorized: return "尚未授权或授权已失效，请重新登录"
        case .invalidCallback: return "授权回调无效，请重试"
        case .stateMismatch: return "授权校验失败（state 不一致），请重试"
        case .cancelled: return "已取消授权"
        case .timeout: return "等待授权超时，请重新发起"
        case .token(let message): return "获取令牌失败：\(message)"
        case .api(let message): return "接口请求失败：\(message)"
        }
    }
}

// MARK: - 凭据与令牌

struct CloudClientCredentials: Codable {
    var clientID: String
    var clientSecret: String
}

struct CloudToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var accountName: String?
    var driveID: String?
}

enum CloudOAuthStore {
    private static let service = "com.baymax.photosclone.oauth"
    /// 旧版包标识时期使用的 Keychain service，仅用于一次性迁移。
    private static let legacyService = "com.lijialong.photosclone.oauth"

    static func credentials(for kind: CloudKind) -> CloudClientCredentials? {
        guard let data = read(account: "client.\(kind.rawValue)") else { return nil }
        return try? JSONDecoder().decode(CloudClientCredentials.self, from: data)
    }

    static func saveCredentials(_ credentials: CloudClientCredentials, for kind: CloudKind) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        write(data, account: "client.\(kind.rawValue)")
    }

    static func token(mountID: UUID) -> CloudToken? {
        guard let data = read(account: "token.\(mountID.uuidString)") else { return nil }
        return try? JSONDecoder().decode(CloudToken.self, from: data)
    }

    static func saveToken(_ token: CloudToken, mountID: UUID) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        write(data, account: "token.\(mountID.uuidString)")
    }

    static func deleteToken(mountID: UUID) {
        remove(account: "token.\(mountID.uuidString)")
    }

    private static func read(account: String) -> Data? {
        if let data = read(service: service, account: account) {
            return data
        }
        // 旧 service 里的令牌迁移到新 service，避免升级后需要重新授权。
        guard let legacy = read(service: legacyService, account: account) else { return nil }
        write(legacy, account: account)
        remove(service: legacyService, account: account)
        return legacy
    }

    private static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addition as CFDictionary, nil)
        }
    }

    private static func remove(account: String) {
        remove(service: service, account: account)
        remove(service: legacyService, account: account)
    }

    private static func remove(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 本机回调监听

/// 监听 127.0.0.1:53682/callback，接收系统浏览器授权后的 code。
final class OAuthLoopbackServer {
    static let shared = OAuthLoopbackServer()
    static let port: UInt16 = 53682
    static var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    private let queue = DispatchQueue(label: "com.baymax.photosclone.oauth.callback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var isFinished = true

    func waitForCode(state: String, timeout: TimeInterval = 180) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.shutdownLocked()
                self.isFinished = false
                self.expectedState = state
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                        throw CloudOAuthError.invalidCallback
                    }
                    let listener = try NWListener(using: parameters, on: port)
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.stateUpdateHandler = { [weak self] newState in
                        if case .failed(let error) = newState {
                            self?.finish(.failure(error))
                        }
                    }
                    listener.start(queue: self.queue)
                    self.listener = listener
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(CloudOAuthError.timeout))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CloudOAuthError.cancelled)) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.handle(request, connection: connection)
        }
    }

    private func handle(_ request: String, connection: NWConnection) {
        guard let firstLine = request.split(separator: "\r\n").first else {
            respond(connection, message: "无效请求", success: false)
            finish(.failure(CloudOAuthError.invalidCallback))
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            respond(connection, message: "无效请求", success: false)
            finish(.failure(CloudOAuthError.invalidCallback))
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        if let error = value("error") {
            let message = value("error_description") ?? error
            respond(connection, message: "授权失败：\(message)", success: false)
            finish(.failure(CloudOAuthError.token(message)))
            return
        }
        guard let code = value("code"), !code.isEmpty else {
            respond(connection, message: "未收到授权码，请返回 App 重试。", success: false)
            finish(.failure(CloudOAuthError.invalidCallback))
            return
        }
        guard value("state") == expectedState else {
            respond(connection, message: "授权校验失败，请重试。", success: false)
            finish(.failure(CloudOAuthError.stateMismatch))
            return
        }
        respond(connection, message: "授权完成，可以关闭此页面并返回 App。", success: true)
        finish(.success(code))
    }

    private func respond(_ connection: NWConnection, message: String, success: Bool) {
        let color = success ? "#0a7f5a" : "#c0392b"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>授权</title></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;background:#fafafa">
        <div style="text-align:center;padding:32px">
        <div style="font-size:42px;margin-bottom:16px">\(success ? "✅" : "⚠️")</div>
        <h2 style="color:\(color);margin:0 0 8px">\(message)</h2>
        </div></body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard !isFinished else { return }
        isFinished = true
        shutdownLocked()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    private func shutdownLocked() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - 阿里云盘开放平台

enum AliyunOAuth {
    /// 允许本地联调时指向模拟服务（正式运行使用官方地址）。
    static var apiBase: String {
        ProcessInfo.processInfo.environment["PHOTOSCLONE_ALIYUN_API_BASE"]
            ?? "https://openapi.alipan.com"
    }
    static let scopes = "user:base,file:all:read"

    static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL? {
        var components = URLComponents(string: apiBase + "/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    static func exchange(clientID: String, clientSecret: String,
                         code: String, redirectURI: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": redirectURI
        ])
    }

    static func refresh(clientID: String, clientSecret: String,
                        refreshToken: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken
        ])
    }

    static func driveInfo(accessToken: String) async throws -> (driveID: String, name: String?) {
        let object = try await post(path: "/adrive/v1.0/user/getDriveInfo",
                                    body: [:],
                                    accessToken: accessToken)
        let driveID = (object["default_drive_id"] as? String)
            ?? (object["resource_drive_id"] as? String)
            ?? (object["backup_drive_id"] as? String)
        guard let driveID, !driveID.isEmpty else {
            throw CloudOAuthError.api("未获取到网盘 ID")
        }
        let name = (object["name"] as? String) ?? (object["user_name"] as? String)
        return (driveID, name)
    }

    static func list(driveID: String, parentID: String, accessToken: String) async throws -> [CloudEntry] {
        var entries: [CloudEntry] = []
        var marker = ""
        var page = 0
        repeat {
            var body: [String: Any] = [
                "drive_id": driveID,
                "parent_file_id": parentID,
                "limit": 100,
                "order_by": "name",
                "order_direction": "ASC",
                "fields": "*"
            ]
            if !marker.isEmpty { body["marker"] = marker }
            let object = try await post(path: "/adrive/v1.0/openFile/list",
                                        body: body,
                                        accessToken: accessToken)
            let items = object["items"] as? [[String: Any]] ?? []
            entries.append(contentsOf: items.compactMap { parseEntry($0) })
            marker = (object["next_marker"] as? String) ?? ""
            page += 1
        } while !marker.isEmpty && page < 30
        return entries
    }

    static func downloadURL(driveID: String, fileID: String, accessToken: String) async throws -> URL {
        let object = try await post(path: "/adrive/v1.0/openFile/getDownloadUrl",
                                    body: ["drive_id": driveID, "file_id": fileID, "expire_sec": 900],
                                    accessToken: accessToken)
        guard let raw = object["url"] as? String, let url = URL(string: raw) else {
            throw CloudOAuthError.api("未获取到下载地址")
        }
        return url
    }

    static func videoURL(driveID: String, fileID: String, accessToken: String) async throws -> URL? {
        let object = try await post(path: "/adrive/v1.0/openFile/getVideoPreviewPlayInfo",
                                    body: ["drive_id": driveID,
                                           "file_id": fileID,
                                           "category": "live_transcoding",
                                           "url_expire_sec": 900],
                                    accessToken: accessToken)
        let play = object["video_preview_play_info"] as? [String: Any]
        let tasks = play?["live_transcoding_task_list"] as? [[String: Any]] ?? []
        let finished = tasks.filter {
            ($0["status"] as? String) == "finished"
                && (($0["url"] as? String)?.isEmpty == false)
        }
        let best = finished.max { lhs, rhs in
            rank(lhs) < rank(rhs)
        }
        guard let raw = best?["url"] as? String, let url = URL(string: raw) else { return nil }
        return url
    }

    // MARK: 内部

    private static func parseEntry(_ item: [String: Any]) -> CloudEntry? {
        guard let fileID = item["file_id"] as? String,
              let name = item["name"] as? String else { return nil }
        let isDirectory = (item["type"] as? String) == "folder"
        let size = (item["size"] as? NSNumber)?.int64Value ?? 0
        let category = item["category"] as? String
        let imageMeta = item["image_media_metadata"] as? [String: Any]
        let videoMeta = item["video_media_metadata"] as? [String: Any]
        let width = (imageMeta?["width"] as? NSNumber)?.intValue
            ?? (videoMeta?["width"] as? NSNumber)?.intValue
        let height = (imageMeta?["height"] as? NSNumber)?.intValue
            ?? (videoMeta?["height"] as? NSNumber)?.intValue
        let duration = (videoMeta?["duration"] as? NSNumber)?.doubleValue

        var entry = CloudEntry(path: fileID,
                               name: name,
                               isDirectory: isDirectory,
                               size: size,
                               modifiedAt: parseDate(item["updated_at"] as? String),
                               contentType: category == "video" ? "video/mp4" : nil)
        entry.thumbnailURL = item["thumbnail"] as? String
        entry.remoteID = fileID
        entry.pixelWidth = width
        entry.pixelHeight = height
        entry.duration = duration
        return entry
    }

    private static func rank(_ task: [String: Any]) -> Int {
        let template = (task["template_id"] as? String)?.uppercased() ?? ""
        if template.contains("FHD") { return 4 }
        if template.contains("HD") { return 3 }
        if template.contains("SD") { return 2 }
        return 1
    }

    private static func requestToken(_ params: [String: String]) async throws -> CloudToken {
        guard let url = URL(string: apiBase + "/oauth/access_token") else {
            throw CloudOAuthError.token("地址无效")
        }
        let attempts: [(String, Data)] = [
            ("application/json", (try? JSONSerialization.data(withJSONObject: params)) ?? Data()),
            ("application/x-www-form-urlencoded", formData(params))
        ]
        var lastMessage = "未知错误"
        for (contentType, body) in attempts {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let access = object["access_token"] as? String, !access.isEmpty {
                    let expires = (object["expires_in"] as? NSNumber)?.doubleValue
                        ?? (object["expires_in"] as? String).flatMap(Double.init)
                        ?? 7200
                    return CloudToken(accessToken: access,
                                      refreshToken: object["refresh_token"] as? String,
                                      expiresAt: Date().addingTimeInterval(max(300, expires - 60)))
                }
                lastMessage = (object["message"] as? String)
                    ?? (object["error_description"] as? String)
                    ?? (object["code"] as? String)
                    ?? "HTTP \(status)"
            } catch {
                lastMessage = error.localizedDescription
            }
        }
        throw CloudOAuthError.token(lastMessage)
    }

    private static func post(path: String, body: [String: Any], accessToken: String) async throws -> [String: Any] {
        guard let url = URL(string: apiBase + path) else {
            throw CloudOAuthError.api("地址无效")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (object["message"] as? String)
                ?? (object["code"] as? String)
                ?? "HTTP \(status)"
            throw CloudOAuthError.api(message)
        }
        return object
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func formData(_ params: [String: String]) -> Data {
        let text = params.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
        return Data(text.utf8)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text) }
        return nil
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

// MARK: - 百度网盘开放平台

enum BaiduOAuth {
    static var oauthBase: String {
        ProcessInfo.processInfo.environment["PHOTOSCLONE_BAIDU_OAUTH_BASE"]
            ?? "https://openapi.baidu.com"
    }
    static var panBase: String {
        ProcessInfo.processInfo.environment["PHOTOSCLONE_BAIDU_PAN_BASE"]
            ?? "https://pan.baidu.com"
    }
    static let scopes = "basic,netdisk"

    static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL? {
        var components = URLComponents(string: oauthBase + "/oauth/2.0/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "device_id", value: clientID),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    static func exchange(clientID: String, clientSecret: String,
                         code: String, redirectURI: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI
        ])
    }

    static func refresh(clientID: String, clientSecret: String,
                        refreshToken: String) async throws -> CloudToken {
        try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret
        ])
    }

    static func list(dir: String, accessToken: String) async throws -> [CloudEntry] {
        var entries: [CloudEntry] = []
        var start = 0
        let limit = 1000
        while true {
            var components = URLComponents(string: panBase + "/rest/2.0/xpan/file")
            components?.queryItems = [
                URLQueryItem(name: "method", value: "list"),
                URLQueryItem(name: "access_token", value: accessToken),
                URLQueryItem(name: "dir", value: dir),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "start", value: "\(start)"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "order", value: "name")
            ]
            guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }
            let object = try await getJSON(url)
            let errno = (object["errno"] as? NSNumber)?.intValue ?? 0
            guard errno == 0 else {
                let message = (object["errmsg"] as? String) ?? "errno \(errno)"
                if errno == -6 { throw CloudOAuthError.notAuthorized }
                throw CloudOAuthError.api(message)
            }
            let list = object["list"] as? [[String: Any]] ?? []
            entries.append(contentsOf: list.compactMap { parseEntry($0) })
            if list.count < limit { break }
            start += limit
            if start >= 5000 { break }
        }
        return entries
    }

    static func downloadURL(fsID: String, accessToken: String) async throws -> URL {
        var components = URLComponents(string: panBase + "/rest/2.0/xpan/multimedia")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "filemetas"),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "fsids", value: "[\(fsID)]"),
            URLQueryItem(name: "dlink", value: "1")
        ]
        guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }
        let object = try await getJSON(url)
        let errno = (object["errno"] as? NSNumber)?.intValue ?? 0
        guard errno == 0 else {
            throw CloudOAuthError.api((object["errmsg"] as? String) ?? "errno \(errno)")
        }
        let info = object["info"] as? [[String: Any]] ?? []
        guard let dlink = info.first?["dlink"] as? String,
              let result = URL(string: dlink) else {
            throw CloudOAuthError.api("未获取到下载地址")
        }
        return result
    }

    // MARK: 内部

    private static func parseEntry(_ item: [String: Any]) -> CloudEntry? {
        let fsID: String
        if let value = item["fs_id"] as? Int64 {
            fsID = String(value)
        } else if let value = item["fs_id"] as? Int {
            fsID = String(value)
        } else if let value = item["fs_id"] as? NSNumber {
            fsID = String(value.int64Value)
        } else {
            return nil
        }
        guard let path = item["path"] as? String else { return nil }
        let name = (item["server_filename"] as? String) ?? (path as NSString).lastPathComponent
        let isDirectory = ((item["isdir"] as? NSNumber)?.intValue ?? 0) == 1
        let size = (item["size"] as? NSNumber)?.int64Value ?? 0
        let mtime = (item["server_mtime"] as? NSNumber)?.doubleValue
        let category = (item["category"] as? NSNumber)?.intValue ?? 0

        var entry = CloudEntry(path: path,
                               name: name,
                               isDirectory: isDirectory,
                               size: size,
                               modifiedAt: mtime.map { Date(timeIntervalSince1970: $0) },
                               contentType: category == 1 ? "video/mp4" : nil)
        entry.remoteID = fsID
        if let thumbs = item["thumbs"] as? [String: String] {
            entry.thumbnailURL = thumbs["url3"] ?? thumbs["url2"] ?? thumbs["url1"]
        }
        return entry
    }

    private static func requestToken(_ params: [String: String]) async throws -> CloudToken {
        var components = URLComponents(string: oauthBase + "/oauth/2.0/token")
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw CloudOAuthError.token("地址无效") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            let message = (object["error_description"] as? String)
                ?? (object["error"] as? String)
                ?? "HTTP \(status)"
            throw CloudOAuthError.token(message)
        }
        let expires = doubleValue(object["expires_in"]) ?? 2_592_000
        return CloudToken(accessToken: access,
                          refreshToken: object["refresh_token"] as? String,
                          expiresAt: Date().addingTimeInterval(max(300, expires - 60)))
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text) }
        return nil
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

// MARK: - 统一调度

enum CloudService {
    static func list(mount: CloudMount, containerID: String) async throws -> [CloudEntry] {
        switch mount.kind {
        case .webdav:
            guard let client = webdavClient(mount) else {
                throw CloudOAuthError.api("WebDAV 配置无效")
            }
            return try await client.list(path: containerID)
        case .smb:
            guard let client = smbClient(mount) else {
                throw CloudOAuthError.api("SMB 配置无效")
            }
            return try await client.list(path: containerID)
        case .aliyun:
            let token = try await accessToken(for: mount)
            guard let driveID = mount.remoteDriveID, !driveID.isEmpty else {
                throw CloudOAuthError.api("缺少网盘 ID，请重新授权")
            }
            return try await AliyunOAuth.list(driveID: driveID,
                                              parentID: containerID.isEmpty ? "root" : containerID,
                                              accessToken: token)
        case .baidu:
            let token = try await accessToken(for: mount)
            return try await BaiduOAuth.list(dir: containerID.isEmpty ? "/" : containerID,
                                             accessToken: token)
        }
    }

    /// 仅 SMB 支持递归扫描整个共享。
    static func scanTree(mount: CloudMount, path: String) async throws -> [CloudEntry] {
        guard mount.kind == .smb else {
            throw CloudOAuthError.unsupportedProvider
        }
        guard let client = smbClient(mount) else {
            throw CloudOAuthError.api("SMB 配置无效")
        }
        return try await client.scanTree(path: path)
    }

    static func stream(mount: CloudMount, photo: PhotoItem) async throws -> CloudStreamResource {
        switch mount.kind {
        case .webdav:
            guard let client = webdavClient(mount),
                  let url = client.fileURL(path: photo.cloudPath ?? "") else {
                throw CloudOAuthError.api("WebDAV 地址无效")
            }
            return CloudStreamResource(url: url, headers: client.requestHeaders)
        case .smb:
            guard let client = smbClient(mount), let path = photo.cloudPath else {
                throw CloudOAuthError.api("SMB 文件路径无效")
            }
            _ = try await client.ensureMounted()
            guard let url = client.fileURL(path: path) else {
                throw CloudOAuthError.api("SMB 挂载点不可用，请检查共享是否已连接")
            }
            return CloudStreamResource(url: url, headers: [:])
        case .aliyun:
            let token = try await accessToken(for: mount)
            guard let driveID = mount.remoteDriveID,
                  let fileID = photo.cloudPath else {
                throw CloudOAuthError.api("缺少文件 ID")
            }
            if photo.isVideo,
               let videoURL = try? await AliyunOAuth.videoURL(driveID: driveID,
                                                              fileID: fileID,
                                                              accessToken: token) {
                return CloudStreamResource(url: videoURL, headers: [:])
            }
            let url = try await AliyunOAuth.downloadURL(driveID: driveID,
                                                        fileID: fileID,
                                                        accessToken: token)
            return CloudStreamResource(url: url, headers: [:])
        case .baidu:
            let token = try await accessToken(for: mount)
            guard let fsID = photo.cloudRemoteID else {
                throw CloudOAuthError.api("缺少文件 ID")
            }
            let url = try await BaiduOAuth.downloadURL(fsID: fsID, accessToken: token)
            return CloudStreamResource(url: url, headers: ["User-Agent": "pan.baidu.com"])
        }
    }

    static func accessToken(for mount: CloudMount) async throws -> String {
        guard mount.kind.usesOAuth else { throw CloudOAuthError.unsupportedProvider }
        guard let stored = CloudOAuthStore.token(mountID: mount.id) else {
            throw CloudOAuthError.notAuthorized
        }
        if stored.expiresAt > Date().addingTimeInterval(60) {
            return stored.accessToken
        }
        guard let refresh = stored.refreshToken,
              let credentials = CloudOAuthStore.credentials(for: mount.kind) else {
            throw CloudOAuthError.notAuthorized
        }
        let updated: CloudToken
        switch mount.kind {
        case .aliyun:
            updated = try await AliyunOAuth.refresh(clientID: credentials.clientID,
                                                    clientSecret: credentials.clientSecret,
                                                    refreshToken: refresh)
        case .baidu:
            updated = try await BaiduOAuth.refresh(clientID: credentials.clientID,
                                                   clientSecret: credentials.clientSecret,
                                                   refreshToken: refresh)
        case .webdav, .smb:
            throw CloudOAuthError.unsupportedProvider
        }
        var merged = updated
        if merged.refreshToken == nil { merged.refreshToken = refresh }
        merged.accountName = stored.accountName
        merged.driveID = stored.driveID
        CloudOAuthStore.saveToken(merged, mountID: mount.id)
        return merged.accessToken
    }

    static func webdavClient(_ mount: CloudMount) -> WebDAVClient? {
        WebDAVClient(baseURLString: mount.baseURL,
                     username: mount.username,
                     password: CloudCredentials.password(for: mount.id))
    }

    static func smbClient(_ mount: CloudMount) -> SMBClient? {
        SMBClient(mount: mount, password: CloudCredentials.password(for: mount.id))
    }
}

// MARK: - 服务端缩略图下载

enum CloudImageFetcher {
    static func thumbnail(for photo: PhotoItem, urlString: String) async -> NSImage? {
        guard let mountID = photo.cloudMountID, let path = photo.cloudPath,
              let url = URL(string: urlString) else { return nil }
        let cacheURL = CloudPaths.thumbnailURL(mountID: mountID, path: path)
        if let image = NSImage(contentsOf: cacheURL) { return image }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        ImportService.writeJPEG(cgImage, to: cacheURL, quality: 0.9)
        return NSImage(contentsOf: cacheURL)
    }

    static func fullImage(photo: PhotoItem, resource: CloudStreamResource) async -> NSImage? {
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 90)
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
