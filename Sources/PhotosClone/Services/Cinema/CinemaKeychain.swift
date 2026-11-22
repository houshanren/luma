import Foundation

/// 影院相关的敏感信息：家长控制 PIN 与在线字幕账号，统一走 `LumaKeychainVault`。
///
/// 旧版本的「cinema」保险库由统一保险库首次读取时静默迁移；
/// 这里的字段统一加 `cinema.` 前缀，读取结果只来自保险库的一次性缓存。
enum CinemaKeychain {
    enum Account: String {
        case parentalPIN = "parental_pin"
        case subtitleUsername = "subtitle_username"
        case subtitlePassword = "subtitle_password"
        case subtitleAssrtToken = "subtitle_assrt_token"
    }

    private static func vaultKey(_ account: Account) -> String {
        "cinema.\(account.rawValue)"
    }

    static func value(for account: Account) -> String {
        LumaKeychainVault.string(for: vaultKey(account)) ?? ""
    }

    /// 只判断是否已设置；数据来自同一个保险库缓存，不会触发额外授权框。
    static func has(_ account: Account) -> Bool {
        !value(for: account).isEmpty
    }

    static func set(_ value: String, for account: Account) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            LumaKeychainVault.remove(vaultKey(account))
        } else {
            LumaKeychainVault.set(Data(trimmed.utf8), for: vaultKey(account))
        }
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
}
