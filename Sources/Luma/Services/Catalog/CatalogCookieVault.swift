import Foundation

/// 站点登录态 Cookie 的存放处：只进钥匙串（统一凭据保险库），
/// 不写图库数据库、不写 UserDefaults、也不随「导出资源」外带。
enum CatalogCookieVault {
    private static let prefix = "catalog.cookie."

    static func cookie(for sourceID: UUID) -> String? {
        let value = LumaKeychainVault.string(for: key(sourceID))
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// 传空值即删除该来源的登录态。
    static func save(_ cookie: String?, for sourceID: UUID) {
        let trimmed = cookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            LumaKeychainVault.remove(key(sourceID))
        } else if let data = trimmed.data(using: .utf8) {
            if !LumaKeychainVault.set(data, for: key(sourceID)) {
                Diagnostics.record("站点登录态写入钥匙串失败 source=\(sourceID.uuidString)")
            }
        }
    }

    private static func key(_ sourceID: UUID) -> String {
        prefix + sourceID.uuidString
    }
}
