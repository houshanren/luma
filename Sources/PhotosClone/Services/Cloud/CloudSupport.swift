import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS

enum CloudIdentity {
    static func id(mountID: UUID, path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(mountID.uuidString)|\(path)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - 凭据（Keychain）

enum CloudCredentials {
    private static let service = "com.baymax.photosclone.webdav"
    /// 旧版包标识时期使用的 Keychain service，仅用于一次性迁移。
    private static let legacyService = "com.lijialong.photosclone.webdav"

    static func password(for mountID: UUID) -> String {
        let account = mountID.uuidString
        if let value = read(service: service, account: account) {
            return value
        }
        // 从旧 service 迁移一次，避免升级后已保存的 NAS 密码“消失”。
        guard let legacy = read(service: legacyService, account: account) else { return "" }
        setPassword(legacy, for: mountID)
        delete(service: legacyService, account: account)
        return legacy
    }

    static func setPassword(_ password: String, for mountID: UUID) {
        write(Data(password.utf8), service: service, account: mountID.uuidString)
    }

    static func delete(for mountID: UUID) {
        let account = mountID.uuidString
        delete(service: service, account: account)
        delete(service: legacyService, account: account)
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    private static func write(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addition as CFDictionary, nil)
        }
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 缓存路径

enum CloudPaths {
    static func thumbnailURL(mountID: UUID, path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LibraryPaths.cloudThumbs
            .appendingPathComponent(mountID.uuidString, isDirectory: true)
            .appendingPathComponent(String(digest.prefix(40)) + ".jpg")
    }
}

enum CloudPlayback {
    /// AVFoundation 未公开该常量名，但支持注入请求头（百度网盘直链需要 UA）。
    static let headerFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"
}

// MARK: - AList 探测

/// AList / OpenList 的连通性探测与 WebDAV 地址推导。
enum AListProbe {
    static func webdavAddress(_ raw: String) -> String? {
        guard let base = WebDAVClient.normalizedBaseURL(raw) else { return nil }
        var text = base.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        return text + "dav"
    }

    static func check(address: String) async -> (ok: Bool, message: String) {
        guard let base = WebDAVClient.normalizedBaseURL(address),
              let url = URL(string: base.absoluteString + "ping") else {
            return (false, "地址格式不正确，例如 http://127.0.0.1:5244")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "服务器响应异常")
            }
            switch http.statusCode {
            case 200:
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if body.lowercased().contains("pong") {
                    return (true, "AList 连接成功")
                }
                return (true, "已连接（/ping 未返回 pong，可能经过反向代理）")
            case 404:
                return (false, "该地址不是 AList（/ping 返回 404）")
            default:
                return (false, "AList 返回 HTTP \(http.statusCode)")
            }
        } catch {
            return (false, "连接失败：\(error.localizedDescription)")
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
