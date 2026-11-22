import Foundation
import Security

/// 全应用唯一的凭据保险库：网盘、影院、智能助手、未来的电视源都写进**一个**钥匙串条目。
///
/// 目标：
/// - 一次读取后在进程内缓存，设置页 / 侧边栏 / 播放页反复读取不再重复访问钥匙串；
/// - 首次写入时设置只信任当前 App 的 ACL，同一签名重编译后也不再逐项弹授权；
/// - 旧版 `CloudSecretStore` / `CinemaKeychain` 的两个保险库在首次读取时静默迁移进来。
///
/// 数据只存在内存与钥匙串，不落图库数据库、不写 UserDefaults、不打日志。
enum LumaKeychainVault {
    private static let service = "com.baymax.luma.credentials"
    private static let account = "vault"

    private static let legacyCloudService = "com.baymax.photosclone.cloudvault"
    private static let legacyCinemaService = "com.baymax.luma.cinema"

    private static let lock = NSLock()
    private static var cache: [String: Data]?
    private static var didAttemptLegacyMigration = false

    // MARK: - 读写

    static func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storageLocked()[key]
    }

    static func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ key: String) -> Bool {
        data(for: key) != nil
    }

    static func set(_ data: Data?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = storageLocked()
        if let data {
            map[key] = data
        } else {
            guard map.removeValue(forKey: key) != nil else { return }
        }
        persistLocked(map)
    }

    static func remove(_ key: String) {
        set(nil, for: key)
    }

    // MARK: - 内部

    /// 调用方必须持有锁。
    private static func storageLocked() -> [String: Data] {
        if let cache { return cache }
        var map = readVault() ?? [:]
        if !didAttemptLegacyMigration {
            didAttemptLegacyMigration = true
            if migrateLegacyVaults(into: &map) {
                persistLocked(map)
            }
        }
        cache = map
        return map
    }

    private static func readVault() -> [String: Data]? {
        guard let data = readItem(service: service, account: account) else { return nil }
        guard let map = try? JSONDecoder().decode([String: Data].self, from: data) else {
            Diagnostics.record("统一凭据解码失败，将要求重新授权")
            return nil
        }
        return map
    }

    /// 调用方必须持有锁。
    private static func persistLocked(_ map: [String: Data]) {
        cache = map
        guard let data = try? JSONEncoder().encode(map) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary,
                                   update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(service: service, account: account)
            item[kSecValueData as String] = data
            // 只信任当前 App：之后的读取（包括重新编译后）不再弹授权框。
            if let access = currentAppAccess() {
                item[kSecAttrAccess as String] = access
            }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Diagnostics.record("统一凭据写入钥匙串失败 status=\(addStatus)")
            }
        } else if status != errSecSuccess {
            Diagnostics.record("统一凭据更新钥匙串失败 status=\(status)")
        }
    }

    /// 旧版两个保险库只读取一次；读到后合并进新保险库。
    /// 旧条目保留不删：如果新库写入失败，下次仍有机会迁移。
    private static func migrateLegacyVaults(into map: inout [String: Data]) -> Bool {
        var changed = false

        if let data = readItem(service: legacyCloudService, account: account),
           let legacy = try? JSONDecoder().decode([String: Data].self, from: data) {
            for (key, value) in legacy where map["cloud.\(key)"] == nil {
                map["cloud.\(key)"] = value
                changed = true
            }
        }

        if let data = readItem(service: legacyCinemaService, account: account),
           let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            for (key, value) in legacy where map["cinema.\(key)"] == nil {
                map["cinema.\(key)"] = Data(value.utf8)
                changed = true
            }
        }

        return changed
    }

    private static func readItem(service: String, account: String) -> Data? {
        var item = baseQuery(service: service, account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            Diagnostics.record("统一凭据读取钥匙串失败 status=\(status)")
            return nil
        }
        return result as? Data
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func currentAppAccess() -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Luma 统一凭据" as CFString,
                              [trusted] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
