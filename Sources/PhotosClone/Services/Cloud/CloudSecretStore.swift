import Foundation
import Security

/// 云端凭据（OAuth 令牌、网盘 Cookie、NAS 密码）统一存进**一个**钥匙串条目。
///
/// 之前每个令牌 / 密码各占一个条目，每次授权都是独立弹一次框；
/// 这里合并成一个 JSON 条目，并用显式 ACL 只信任当前 App：
/// - 首次写入后，同一签名的 App 读取不再弹授权框（重编译只要签名不变也照旧）
/// - 即使签名变化需要重新授权，也只会弹一次，而不是每个网盘各弹一次
enum CloudSecretStore {
    private static let service = "com.baymax.photosclone.cloudvault"
    private static let account = "vault"

    private static let lock = NSLock()
    private static var cache: [String: Data]?

    // MARK: - 读写

    static func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage()[key]
    }

    static func set(_ data: Data, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = storage()
        map[key] = data
        persist(map)
    }

    static func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = storage()
        guard map.removeValue(forKey: key) != nil else { return }
        persist(map)
    }

    /// 旧版本每个账号一个钥匙串条目：迁移只尝试一次，标记后不再读取。
    static func isMarked(_ name: String) -> Bool {
        data(for: "flag.\(name)") != nil
    }

    static func mark(_ name: String) {
        set(Data(), for: "flag.\(name)")
    }

    // MARK: - 内部

    private static func storage() -> [String: Data] {
        if let cache { return cache }
        let loaded = load() ?? [:]
        cache = loaded
        return loaded
    }

    private static func load() -> [String: Data]? {
        guard let data = readItem() else { return nil }
        guard let map = try? JSONDecoder().decode([String: Data].self, from: data) else {
            Diagnostics.record("云端凭据解码失败，将要求重新授权网盘")
            return nil
        }
        return map
    }

    private static func persist(_ map: [String: Data]) {
        cache = map
        guard let data = try? JSONEncoder().encode(map) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery()
            item[kSecValueData as String] = data
            // 只信任当前 App：之后的读取（包括重新编译后）不再弹授权框。
            if let access = currentAppAccess() {
                item[kSecAttrAccess as String] = access
            }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Diagnostics.record("云端凭据写入钥匙串失败 status=\(addStatus)")
            }
        } else if status != errSecSuccess {
            Diagnostics.record("云端凭据更新钥匙串失败 status=\(status)")
        }
    }

    private static func readItem() -> Data? {
        var item = baseQuery()
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            Diagnostics.record("云端凭据读取钥匙串失败 status=\(status)")
            return nil
        }
        return result as? Data
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func currentAppAccess() -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Luma 云端凭据" as CFString,
                              [trusted] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
