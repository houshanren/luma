import Foundation

/// 头像独立表（`person_avatars` / `studio_avatars`）的按需读取器。
///
/// catalog.sqlite 起头像 base64 不再内嵌 `actresses` / `studios` 主表行，
/// 而是拆到独立表按主键单条取：名字字典启动时只加载主表，
/// 不再把 18,863 条 ~15KB 的大文本整库读进内存（省 200MB+ 常驻）。
///
/// 展示头像时（`CatalogAvatarView`）才会走到这里；
/// 结果走 NSCache，列表回滚不重复查库，解码缓存仍由视图层负责。
enum CatalogAvatarStore {
    private static let lock = NSLock()
    private static var database: SQLiteDatabase?

    /// base64 文本缓存：按 id 缓存，上限 ~32MB；空串做负缓存，避免没有头像的人反复点查。
    private static let cache = NSCache<NSString, NSString>()

    private static func connection() -> SQLiteDatabase? {
        lock.lock()
        defer { lock.unlock() }
        if let database { return database }
        for url in databaseCandidates()
        where FileManager.default.fileExists(atPath: url.path) {
            if let database = try? SQLiteDatabase(path: url.path, readonly: true, wal: false) {
                self.database = database
                return database
            }
        }
        return nil
    }

    /// 与 `CatalogNameDictionary` 相同的候选路径（Bundle 资源 / 仓库目录）。
    private static func databaseCandidates() -> [URL] {
        var urls: [URL] = []
        if let resource = Bundle.main.resourceURL {
            urls.append(resource.appendingPathComponent("Catalog/catalog.sqlite"))
        }
        // 开发期 `swift run` 时包资源里没有这份文件，退回仓库路径。
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Catalog/catalog.sqlite"))
        return urls
    }

    /// 人物头像（96×96 JPEG base64）；库里没有该行返回 nil。
    static func personBase64(_ id: Int64) -> String? {
        cached("p\(id)", "SELECT base64 FROM person_avatars WHERE actress_id = ?", id)
    }

    /// 厂牌头像；库里没有该行返回 nil。
    static func studioBase64(_ id: Int64) -> String? {
        cached("s\(id)", "SELECT base64 FROM studio_avatars WHERE studio_id = ?", id)
    }

    private static func cached(_ key: String, _ sql: String, _ id: Int64) -> String? {
        let cacheKey = key as NSString
        cache.totalCostLimit = 32 * 1024 * 1024
        if let hit = cache.object(forKey: cacheKey) {
            return hit.length == 0 ? nil : hit as String
        }
        guard let database = connection(),
              let rows = try? database.query(sql, [id]),
              let value = rows.first?["base64"]?.string else {
            cache.setObject("" as NSString, forKey: cacheKey, cost: 1)
            return nil
        }
        cache.setObject(value as NSString, forKey: cacheKey, cost: value.utf16.count)
        return value
    }
}
