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

    /// 与 `CatalogNameDictionary` 相同的候选路径（用户加载的星图库 / Bundle 资源 / 仓库目录）。
    private static func databaseCandidates() -> [URL] {
        var urls: [URL] = []
        if let selected = AtlasCatalogPaths.selectedPath {
            urls.append(URL(fileURLWithPath: selected))
        }
        if let resource = Bundle.main.resourceURL {
            urls.append(resource.appendingPathComponent("Catalog/catalog.sqlite"))
        }
        // 开发期 `swift run` 时包资源里没有这份文件，退回仓库路径。
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Catalog/catalog.sqlite"))
        return urls
    }

    /// 星图资料库加载 / 卸载 / 更换后换连接：丢掉旧连接与缓存，下一次取头像用新库。
    static func reset() {
        lock.lock()
        database = nil
        lock.unlock()
        cache.removeAllObjects()
    }

    /// 人物头像（96×96 JPEG base64）；库里没有该行返回 nil。
    static func personBase64(_ id: Int64) -> String? {
        cached("p\(id)", "SELECT base64 FROM person_avatars WHERE actress_id = ?", id)
    }

    /// 厂牌头像；库里没有该行返回 nil。
    static func studioBase64(_ id: Int64) -> String? {
        cached("s\(id)", "SELECT base64 FROM studio_avatars WHERE studio_id = ?", id)
    }

    /// 批量取头像：星图名册一次几十个人，逐条查库会白白多几十次 SQL。
    /// 先查内存缓存，再把剩下的 id 合成一条 `IN (…)` 查回来。
    static func personBase64(ids: [Int64]) -> [Int64: String] {
        batch(prefix: "p", table: "person_avatars", column: "actress_id", ids: ids)
    }

    static func studioBase64(ids: [Int64]) -> [Int64: String] {
        batch(prefix: "s", table: "studio_avatars", column: "studio_id", ids: ids)
    }

    private static func batch(prefix: String,
                              table: String,
                              column: String,
                              ids: [Int64]) -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int64: String] = [:]
        var missing: [Int64] = []
        for id in Set(ids) {
            let key = "\(prefix)\(id)" as NSString
            if let hit = cache.object(forKey: key) {
                if hit.length > 0 { result[id] = hit as String }
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty,
              let database = connection() else { return result }
        let placeholders = Array(repeating: "?", count: missing.count).joined(separator: ",")
        let sql = "SELECT \(column) AS id, base64 FROM \(table) WHERE \(column) IN (\(placeholders))"
        let rows = (try? database.query(sql, missing)) ?? []
        for row in rows {
            guard let id = row["id"]?.int64, let value = row["base64"]?.string else { continue }
            result[id] = value
            cache.setObject(value as NSString, forKey: "\(prefix)\(id)" as NSString,
                            cost: value.utf16.count)
        }
        // 不在库里的 id 做负缓存，下次同一批名册不会重复查。
        let found = Set(rows.compactMap { $0["id"]?.int64 })
        for id in missing where !found.contains(id) {
            cache.setObject("" as NSString, forKey: "\(prefix)\(id)" as NSString, cost: 1)
        }
        return result
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
