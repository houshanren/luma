import Foundation
import Security

/// 影院相关的敏感信息：家长控制 PIN 与在线字幕账号，只写 macOS 钥匙串。
///
/// 所有字段合并进**一个**钥匙串条目，并用显式 ACL 只信任当前 App：
/// - 首次写入后，同一签名的 App 读取不再弹授权框（重新编译只要签名不变也照旧）
/// - 即使签名变化需要重新授权，也只会弹一次，而不是每个字段各弹一次
/// - 读取结果在进程内缓存，设置页反复重建不会再次访问钥匙串
/// - 旧版本分散的条目不再自动读取：逐条读取会逐条弹授权；
///   升级后字幕账号 / PIN 在对应页面重填一次即可，之后都由这个统一条目承载。
enum CinemaKeychain {
    enum Account: String {
        case parentalPIN = "parental_pin"
        case subtitleUsername = "subtitle_username"
        case subtitlePassword = "subtitle_password"
        case subtitleAssrtToken = "subtitle_assrt_token"
    }

    private static let service = "com.baymax.luma.cinema"
    private static let vaultAccount = "vault"

    private static let lock = NSLock()
    private static var cache: [String: String]?

    // MARK: - 读写

    static func value(for account: Account) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storageLocked()[account.rawValue] ?? ""
    }

    /// 只判断是否已设置；数据来自同一个钥匙串条目，不会触发额外的授权框。
    static func has(_ account: Account) -> Bool {
        !value(for: account).isEmpty
    }

    static func set(_ value: String, for account: Account) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        var map = storageLocked()
        if trimmed.isEmpty {
            map[account.rawValue] = nil
        } else {
            map[account.rawValue] = trimmed
        }
        persistLocked(map)
    }

    static func remove(_ account: Account) {
        set("", for: account)
    }

    /// 校验 PIN；未设置过 PIN 时视为通过。
    static func verifyPIN(_ pin: String) -> Bool {
        let saved = value(for: .parentalPIN)
        guard !saved.isEmpty else { return true }
        return saved == pin.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 内部

    /// 调用方必须已经持有锁。
    private static func storageLocked() -> [String: String] {
        if let cache { return cache }
        let map = loadVault() ?? [:]
        cache = map
        return map
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: vaultAccount]
    }

    private static func loadVault() -> [String: String]? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            Diagnostics.record("影院凭据读取钥匙串失败 status=\(status)")
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// 调用方必须已经持有锁。
    private static func persistLocked(_ map: [String: String]) {
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
                Diagnostics.record("影院凭据写入钥匙串失败 status=\(addStatus)")
            }
        } else if status != errSecSuccess {
            Diagnostics.record("影院凭据更新钥匙串失败 status=\(status)")
        }
    }

    private static func currentAppAccess() -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Luma 影院凭据" as CFString,
                              [trusted] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
