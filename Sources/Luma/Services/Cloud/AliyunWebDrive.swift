import Foundation
import LumaContentCore

// MARK: - 阿里云盘（网页登录 / 扫码模式）
//
// 扫码拿到的是网页登录的 refresh_token，不能走开放平台接口；
// 这里用网页端同一套 API 浏览与播放，令牌过期自动用 refresh_token 续期。
// 只读：扫描、缩略图、直链与转码播放，删除请到阿里云盘 App。
//
// 端点与官方网页端一致（api.aliyundrive.com / auth.aliyundrive.com），
// 属于非公开接口，失败时会带出可读原因，方便换回开放平台模式。

/// 网页接口限速器：列目录这类轮询请求连得太快会被服务端 429
/// （BlockException / rule:TooManyRequests）。预约式限速：每个请求先领走
/// 一个时间片（相邻请求至少间隔 interval 秒），再睡到自己那一片，并发
/// 调用也会被依次错开，而不是醒来后挤在一起。
private actor AliyunWebRateLimiter {
    private var reserved: Date?
    private let interval: TimeInterval

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func wait() async {
        let now = Date()
        let earliest = reserved.map { $0.addingTimeInterval(interval) } ?? now
        reserved = now > earliest ? now : earliest
        let delay = earliest.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

enum AliyunWebDrive {
    static var authBase: String {
        ProcessInfo.processInfo.environment["LUMA_ALIYUN_WEB_AUTH_BASE"]
            ?? "https://auth.aliyundrive.com"
    }
    static var apiBase: String {
        ProcessInfo.processInfo.environment["LUMA_ALIYUN_WEB_API_BASE"]
            ?? "https://api.aliyundrive.com"
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let referer = "https://www.aliyundrive.com/"
    /// 网页端应用的公开 client_id：扫码拿到的 refresh_token 必须带上它才能续期。
    static let webClientID = "25dzX3vbYqktVxyX"

    // MARK: 令牌

    /// 用 refresh_token 换一组网页登录令牌。
    static func refresh(refreshToken: String) async throws -> CloudToken {
        guard let url = URL(string: apiBase + "/v2/account/token") else {
            throw CloudOAuthError.api("登录地址无效")
        }
        let object = try await send(url: url,
                                    body: ["grant_type": "refresh_token",
                                           "refresh_token": refreshToken,
                                           "client_id": webClientID],
                                    accessToken: nil,
                                    referer: referer)
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw CloudOAuthError.notAuthorized
        }
        let ttl = (object["expires_in"] as? NSNumber)?.doubleValue ?? 7200
        var token = CloudToken(accessToken: access,
                               refreshToken: object["refresh_token"] as? String ?? refreshToken,
                               expiresAt: Date().addingTimeInterval(max(300, ttl - 120)))
        token.driveID = object["default_drive_id"] as? String
        return token
    }

    /// 挂载的可用令牌：优先用钥匙串里的，过期前自动续期并写回轮换后的 refresh_token。
    /// 续期做单飞：扫描会并发列几十个目录，多个请求同时刷新会把 refresh_token 轮换坏。
    static func token(for mount: CloudMount) async throws -> CloudToken {
        if case .token(let stored) = CloudOAuthStore.tokenResult(mountID: mount.id),
           stored.expiresAt > Date().addingTimeInterval(120),
           !stored.accessToken.isEmpty {
            return stored
        }

        refreshLock.lock()
        if let existing = refreshTasks[mount.id] {
            refreshLock.unlock()
            return try await existing.value
        }
        let task = Task<CloudToken, Error> {
            // 排队期间可能已经有人刷新完成，再读一次。
            if case .token(let stored) = CloudOAuthStore.tokenResult(mountID: mount.id),
               stored.expiresAt > Date().addingTimeInterval(120),
               !stored.accessToken.isEmpty {
                return stored
            }
            let refresh: String
            if case .token(let stored) = CloudOAuthStore.tokenResult(mountID: mount.id),
               let value = stored.refreshToken, !value.isEmpty {
                refresh = value
            } else {
                refresh = CloudCredentials.password(for: mount.id)
            }
            guard !refresh.isEmpty else { throw CloudOAuthError.notAuthorized }
            let renewed = try await AliyunWebDrive.refresh(refreshToken: refresh)
            CloudOAuthStore.saveToken(renewed, mountID: mount.id)
            if let rotated = renewed.refreshToken, !rotated.isEmpty {
                CloudCredentials.setPassword(rotated, for: mount.id)
            }
            Diagnostics.record("阿里云盘(web) 令牌已续期 drive=\(renewed.driveID ?? "-")")
            return renewed
        }
        refreshTasks[mount.id] = task
        refreshLock.unlock()

        defer {
            refreshLock.lock()
            refreshTasks[mount.id] = nil
            refreshLock.unlock()
        }
        return try await task.value
    }

    private static let refreshLock = NSLock()
    private static var refreshTasks: [UUID: Task<CloudToken, Error>] = [:]

    static func accessToken(for mount: CloudMount) async throws -> String {
        try await token(for: mount).accessToken
    }

    /// 扫码模式下的盘列表：用网页令牌直接读，避免走开放平台（开放平台不认网页令牌）。
    static func drives(for mount: CloudMount) async throws -> [(id: String, label: String)] {
        let access = try await accessToken(for: mount)
        return try await drives(accessToken: access)
    }

    // MARK: 账号与目录

    /// 扫码模式下的盘列表：默认盘、资源库、备份盘，与挂载主盘的选择保持一致。
    static func drives(accessToken: String) async throws -> [(id: String, label: String)] {
        guard let url = URL(string: apiBase + "/v2/user/get") else {
            throw CloudOAuthError.api("地址无效")
        }
        let object = try await send(url: url, body: [:], accessToken: accessToken, referer: referer)
        var result: [(id: String, label: String)] = []
        func add(_ key: String, _ label: String) {
            guard let id = object[key] as? String, !id.isEmpty,
                  !result.contains(where: { $0.id == id }) else { return }
            result.append((id, label))
        }
        add("default_drive_id", "默认盘")
        add("resource_drive_id", "资源库")
        add("backup_drive_id", "备份盘")
        let keys = ["default_drive_id", "resource_drive_id", "backup_drive_id"].filter {
            guard let id = object[$0] as? String else { return false }
            return !id.isEmpty
        }.joined(separator: ",")
        let summary = result.map { "\($0.label)=\($0.id)" }.joined(separator: ", ")
        Diagnostics.record("阿里云盘(web) 盘字段=\(keys.isEmpty ? "-" : keys) 盘=\(summary.isEmpty ? "-" : summary)")
        return result
    }

    static func list(driveID: String, parentID: String, accessToken: String) async throws -> [CloudEntry] {
        var entries: [CloudEntry] = []
        var marker = ""
        var page = 0
        let parent = parentID.isEmpty ? "root" : parentID
        repeat {
            guard let url = URL(string: apiBase + "/adrive/v3/file/list") else {
                throw CloudOAuthError.api("地址无效")
            }
            var body: [String: Any] = [
                "drive_id": driveID,
                "parent_file_id": parent,
                "limit": 100,
                "order_by": "name",
                "order_direction": "ASC",
                "fields": "*"
            ]
            if !marker.isEmpty { body["marker"] = marker }
            let object = try await send(url: url, body: body, accessToken: accessToken, referer: referer)
            let items = object["items"] as? [[String: Any]] ?? []
            entries.append(contentsOf: items.compactMap { parseEntry($0, driveID: driveID) })
            marker = (object["next_marker"] as? String) ?? ""
            page += 1
        } while !marker.isEmpty && page < 30
        Diagnostics.record("阿里云盘(web) 列目录 drive=\(driveID) parent=\(parent) "
                           + "条目=\(entries.count) 页=\(page) 目录=\(entries.filter(\.isDirectory).count)")
        return entries
    }

    // MARK: 播放与直链

    static func downloadURL(driveID: String, fileID: String, accessToken: String) async throws -> URL {
        guard let url = URL(string: apiBase + "/v2/file/get_download_url") else {
            throw CloudOAuthError.api("地址无效")
        }
        let object = try await send(url: url,
                                    body: ["drive_id": driveID,
                                           "file_id": fileID,
                                           "expire_sec": 900],
                                    accessToken: accessToken,
                                    referer: referer)
        guard let raw = object["url"] as? String, let result = URL(string: raw) else {
            throw CloudOAuthError.api("未获取到下载地址")
        }
        return result
    }

    /// 转码播放地址：网页端播放器用的同一套接口，优先挑已就绪的最高档。
    static func videoURL(driveID: String, fileID: String, accessToken: String) async throws -> URL? {
        guard let url = URL(string: apiBase + "/v2/file/get_video_preview_play_info") else {
            throw CloudOAuthError.api("地址无效")
        }
        let object = try await send(url: url,
                                    body: ["drive_id": driveID,
                                           "file_id": fileID,
                                           "category": "live_transcoding",
                                           "template_id": ""],
                                    accessToken: accessToken,
                                    referer: referer)
        let play = object["video_preview_play_info"] as? [String: Any]
        let tasks = play?["live_transcoding_task_list"] as? [[String: Any]] ?? []
        let finished = tasks.filter {
            ($0["status"] as? String) == "finished"
                && (($0["url"] as? String)?.isEmpty == false)
        }
        let best = finished.max { rank($0) < rank($1) }
        guard let raw = best?["url"] as? String, let result = URL(string: raw) else { return nil }
        return result
    }

    private static func rank(_ task: [String: Any]) -> Int {
        switch (task["template_id"] as? String)?.lowercased() {
        case "fhd": return 4
        case "hd": return 3
        case "sd": return 2
        case "ld": return 1
        default: return 0
        }
    }

    // MARK: 内部

    private static func parseEntry(_ item: [String: Any], driveID: String) -> CloudEntry? {
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
        var entry = CloudEntry(path: "\(driveID)|\(fileID)",
                               name: name,
                               isDirectory: isDirectory,
                               size: size,
                               modifiedAt: parseDate(item["updated_at"] as? String),
                               contentType: category == "video" ? "video/mp4" : nil)
        entry.thumbnailURL = item["thumbnail"] as? String
        entry.pixelWidth = width
        entry.pixelHeight = height
        entry.duration = (videoMeta?["duration"] as? NSNumber)?.doubleValue
        return entry
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func send(url: URL,
                             body: [String: Any],
                             accessToken: String?,
                             referer: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.aliyundrive.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 网页端接口会看这个标记，缺失时容易被判定成异常客户端。
        request.setValue("client=web,app=adrive,version=v4.5.0", forHTTPHeaderField: "x-canary")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            await rateLimiter.wait()
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // 限流重试：退避 1.5 / 3 / 4.5 秒，最多重试 3 次；任务已取消就不再等。
            if status == 429, attempt < 3, !Task.isCancelled {
                attempt += 1
                let pause = TimeInterval(attempt) * 1.5
                Diagnostics.record("阿里云盘(web) 被限流 path=\(url.path) 第\(attempt)次退避重试 等待\(Int(pause))秒")
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                continue
            }
            if status == 401 || status == 403 {
                Diagnostics.record("阿里云盘(web) 未授权 path=\(url.path) status=\(status)")
                throw CloudOAuthError.notAuthorized
            }
            guard status == 200 else {
                let message = (object["message"] as? String)
                    ?? (object["error_description"] as? String)
                    ?? (object["code"] as? String)
                Diagnostics.record("阿里云盘(web) 失败 path=\(url.path) status=\(status) "
                                   + "code=\((object["code"] as? String) ?? "-")")
                throw CloudOAuthError.api(message ?? "阿里云盘返回 HTTP \(status)")
            }
            if let code = object["code"] as? String, !code.isEmpty,
               code != "Success", code != "success" {
                let message = (object["message"] as? String) ?? code
                Diagnostics.record("阿里云盘(web) 返回错误 path=\(url.path) code=\(code)")
                if code.lowercased().contains("token")
                    || code.lowercased().contains("login")
                    || message.contains("登录") {
                    throw CloudOAuthError.notAuthorized
                }
                throw CloudOAuthError.api(message)
            }
            return object
        }
    }

    static let session = HTTPSessionPool.shared.session(.cloud)

    /// 全部网页接口共用的限速器：约 5 请求/秒，扫描整个网盘也不会撞限流。
    private static let rateLimiter = AliyunWebRateLimiter(interval: 0.2)
}
