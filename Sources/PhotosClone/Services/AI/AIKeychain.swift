import Foundation
import Security

/// 智能助手 API Key：统一走 `LumaKeychainVault`，绝不进入图库数据库、UserDefaults 或日志。
///
/// 旧版本按 provider 分散在 `com.baymax.luma.ai` 的多个条目里：
/// 只有真正读取 Key 时才尝试迁移一次；`hasKey` 只读属性，不读密文。
enum AIKeychain {
    private static let legacyService = "com.baymax.luma.ai"
    private static let lock = NSLock()
    private static var legacyPresenceCache: [String: Bool] = [:]

    private static func vaultKey(_ provider: AIProvider) -> String {
        "ai.\(provider.keychainAccount)"
    }

    static func key(for provider: AIProvider) -> String {
        if let value = LumaKeychainVault.string(for: vaultKey(provider)), !value.isEmpty {
            return value
        }
        return migrateLegacyKey(for: provider) ?? ""
    }

    /// 只检查是否已配置；优先读统一保险库缓存，旧条目只查一次属性、不读密文。
    static func hasKey(for provider: AIProvider) -> Bool {
        if let value = LumaKeychainVault.string(for: vaultKey(provider)), !value.isEmpty {
            return true
        }
        return legacyPresence(provider)
    }

    static func setKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteKey(for: provider)
            return
        }
        LumaKeychainVault.set(Data(trimmed.utf8), for: vaultKey(provider))
        // 新值已写入统一保险库，旧条目可以删除，避免下次误迁移旧值。
        SecItemDelete(legacyQuery(provider) as CFDictionary)
        setLegacyPresence(false, for: provider)
    }

    static func deleteKey(for provider: AIProvider) {
        LumaKeychainVault.remove(vaultKey(provider))
        SecItemDelete(legacyQuery(provider) as CFDictionary)
        setLegacyPresence(false, for: provider)
    }

    // MARK: - 旧条目迁移

    private static func migrateLegacyKey(for provider: AIProvider) -> String? {
        var query = legacyQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        LumaKeychainVault.set(data, for: vaultKey(provider))
        setLegacyPresence(true, for: provider)
        return value
    }

    private static func legacyPresence(_ provider: AIProvider) -> Bool {
        let key = provider.keychainAccount
        lock.lock()
        if let cached = legacyPresenceCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var query = legacyQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let exists = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        setLegacyPresence(exists, for: provider)
        return exists
    }

    private static func setLegacyPresence(_ value: Bool, for provider: AIProvider) {
        lock.lock()
        legacyPresenceCache[provider.keychainAccount] = value
        lock.unlock()
    }

    private static func legacyQuery(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: legacyService,
         kSecAttrAccount as String: provider.keychainAccount]
    }
}
