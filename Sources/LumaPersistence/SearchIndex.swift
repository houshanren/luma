import Foundation
import LumaCore

/// 系统图库的全文搜索索引（FTS5 trigram）。
///
/// 直接在 `Photos.sqlite` 上用 `lower(ZFILENAME) LIKE '%词%'` 搜索要全表扫 137 万行：
/// 本机实测一个词 108～135 秒，而计数还会把同样一条查询再跑一遍。
/// 这里把「文件名 / 原始文件名 / 标题 / 相机型号」铺平成一张 FTS5 表（trigram 分词，
/// 支持任意子串，等价于 `LIKE '%词%'`），搜索变成索引查找，任意词都在 0.3 秒内。
///
/// 索引固定写本机应用目录（`resources/system-search/`）：图库常在外置盘上，
/// 边读 26GB 的 Photos.sqlite 边把 600 多 MB 索引写回同一块盘会退化成随机读写。
package final class SearchIndex: @unchecked Sendable {
    /// schema 或分词方式变化时递增，旧索引文件自动重建。
    /// v2：文本改成「字符间插空格」再交给 trigram（否则「上海」这类两字词查不到）。
    package static let version = 2
    /// 一次搜索最多下推多少个主键：翻页、筛选都在这个集合里做。
    /// 太大 SQL 会变长（主键 IN 列表），太小翻不了几页；2 万覆盖 100 页 × 200 行。
    package static let candidateLimit = 20_000
    /// 建索引时每批写入行数；每批之后主动让出 IO，避免和前台翻页抢盘。
    private static let batchSize = 5_000
    private static let batchPause: TimeInterval = 0.15
    /// 同一进程里可能有多份 `SearchIndex`（主图库 + 跨图库搜索）指向同一个文件，
    /// 重建必须串行，否则一边 `DROP TABLE` 一边写会互相破坏。
    private static let buildLock = NSLock()

    private let lock = NSLock()
    private let db: SQLiteDatabase
    private let photosPath: String
    private var ready = false
    private var indexedCount = 0
    private var building = false
    private var builtRows = 0
    private var expectedRows = 0

    /// 索引是否已经建好且与当前图库一致。
    package var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    /// 已收录的项目数（建索引时统计）。
    package var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexedCount
    }

    /// 是否正在后台建索引。界面可据此提示「正在建立搜索索引」，避免用户以为搜索坏了。
    package var isBuilding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return building
    }

    /// 建索引进度（已写入行数 / 预计总行数），0…1。
    package var buildProgress: Double {
        lock.lock()
        defer { lock.unlock() }
        guard building, expectedRows > 0 else { return ready ? 1 : 0 }
        return min(1, Double(builtRows) / Double(expectedRows))
    }

    package init?(libraryURL: URL, photosPath: String) {
        guard let file = LibraryPaths.systemSearchFile(for: libraryURL) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let database = try? SQLiteDatabase(path: file.path, readonly: false) else { return nil }
        db = database
        self.photosPath = photosPath
        // 建索引是一次性批量写：关掉 fsync 让写入不再逐条落盘（崩了最多重建）。
        try? db.execute("PRAGMA journal_mode=WAL")
        try? db.execute("PRAGMA synchronous=OFF")
        try? db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        refreshReadyState()
    }

    // MARK: - 状态

    /// 指纹取「索引版本 + Photos.sqlite 大小 + 修改时间」：
    /// 每次导入 / 删除照片都会写 WAL，文件大小或修改时间随之变化，据此判断是否需要重建。
    private var currentSignature: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: photosPath)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "v\(Self.version)-\(Int64(size))-\(Int64(mtime))"
    }

    private func storedMeta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key = ?", [key]))?.first?["value"]?.string
    }

    private func setMeta(_ key: String, _ value: String) {
        try? db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [key, value])
    }

    private func refreshReadyState() {
        let signature = currentSignature
        let stored = storedMeta("signature")
        let storedCount = Int(storedMeta("count") ?? "") ?? 0
        // 索引表必须真的存在，否则只凭 meta 会把空表当成可用。
        let hasTable = (try? db.query("SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'table' AND name = 'search'"))?
            .first?["c"]?.int ?? 0
        lock.lock()
        ready = stored == signature && hasTable > 0 && storedCount > 0
        indexedCount = storedCount
        lock.unlock()
    }

    // MARK: - 建索引

    /// 需要时在后台重建索引。低优先级、分批写盘、每批让出 IO：
    /// 用户要求「不卡主界面，慢一点没关系」，整库建完约 4～6 分钟。
    package func buildIfNeeded() async {
        refreshReadyState()
        guard !isReady else { return }
        let signature = currentSignature
        await Task.detached(priority: .background) { [self] in
            rebuild(signature: signature)
        }.value
    }

    private func rebuild(signature: String) {
        Self.buildLock.lock()
        defer { Self.buildLock.unlock() }
        // 进锁后重查一次：并发的另一份实例可能已经把同一份索引建完了。
        refreshReadyState()
        guard !isReady else { return }
        lock.lock()
        building = true
        builtRows = 0
        ready = false
        lock.unlock()
        defer {
            lock.lock()
            building = false
            lock.unlock()
        }
        try? db.execute("DROP TABLE IF EXISTS search")
        guard (try? db.execute("""
            CREATE VIRTUAL TABLE search USING fts5(pk UNINDEXED, date UNINDEXED, text, tokenize='trigram')
            """)) != nil else { return }
        // 独立只读连接读 Photos.sqlite：建索引会连续读几十 GB，
        // 不能挂在主连接那把锁上，否则翻页、侧栏计数全被堵住。
        guard let photos = try? SQLiteDatabase(path: photosPath, readonly: true) else { return }
        // 预计行数只用于进度显示（取整库资产数，已删除 / 隐藏项会被过滤掉，所以略偏大）。
        let estimate = (try? photos.query("SELECT COUNT(*) AS c FROM ZASSET"))?.first?["c"]?.int ?? 0
        lock.lock()
        expectedRows = estimate
        lock.unlock()

        var inserted = 0
        var batch: [[Any?]] = []
        batch.reserveCapacity(Self.batchSize)
        let insertSQL = "INSERT INTO search(pk, date, text) VALUES (?, ?, ?)"
        let flush: () -> Void = { [self] in
            guard !batch.isEmpty else { return }
            let rows = batch
            batch.removeAll(keepingCapacity: true)
            try? db.transaction {
                try? db.executeMany(insertSQL, rows: rows)
            }
            inserted += rows.count
            lock.lock()
            builtRows = inserted
            lock.unlock()
            Thread.sleep(forTimeInterval: Self.batchPause)
        }

        try? photos.forEachRow("""
            SELECT a.Z_PK AS pk, a.ZDATECREATED AS d,
                   lower(COALESCE(a.ZFILENAME, '') || ' ' || COALESCE(aa.ZORIGINALFILENAME, '') || ' ' ||
                         COALESCE(aa.ZTITLE, '') || ' ' || COALESCE(e.ZCAMERAMAKE, '') || ' ' ||
                         COALESCE(e.ZCAMERAMODEL, '') || ' ' || COALESCE(e.ZLENSMODEL, '')) AS t
            FROM ZASSET a
            LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK
            WHERE a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
            """) { row in
            guard let pk = row["pk"]?.int64 else { return }
            batch.append([pk, row["d"]?.double ?? 0, Self.interleaved(row["t"]?.string ?? "")])
            if batch.count >= Self.batchSize { flush() }
        }
        flush()

        guard inserted > 0 else { return }
        // 合并 trigram 段（查询更快），再把 WAL 收回主库：分批写会让 WAL 涨到与主库同量级，
        // 不收的话磁盘占用会翻倍（本机实测 904MB 主库 + 近 1GB WAL）。
        try? db.execute("INSERT INTO search(search) VALUES('optimize')")
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        setMeta("signature", signature)
        setMeta("count", String(inserted))
        lock.lock()
        ready = true
        indexedCount = inserted
        lock.unlock()
    }

    // MARK: - 搜索

    /// 命中的 ZASSET 主键（按拍摄时间倒序）。多个词取交集，语义与原来的
    /// 「每个词都要命中」一致。
    package func primaryKeys(matching terms: [String], limit: Int = SearchIndex.candidateLimit) -> [Int64] {
        guard isReady else { return [] }
        let words = terms.filter { !$0.isEmpty }
        guard let first = words.first else { return [] }
        var candidates = matchPrimaryKeys(first, limit: limit)
        for word in words.dropFirst() {
            guard !candidates.isEmpty else { return [] }
            let set = Set(matchPrimaryKeys(word, limit: limit))
            candidates = candidates.filter { set.contains($0) }
        }
        return candidates
    }

    /// 命中总数。单个词是精确值；多个词时只统计交集后的候选数（交集要取全量，太贵），
    /// 界面上多词组合的「总数」本来就是近似。
    package func matchCount(terms: [String]) -> Int {
        guard isReady else { return 0 }
        let words = terms.filter { !$0.isEmpty }
        guard let first = words.first else { return 0 }
        if words.count > 1 {
            return primaryKeys(matching: words).count
        }
        if let phrase = Self.matchQuery(first) {
            return (try? db.query("SELECT COUNT(*) AS c FROM search WHERE text MATCH ?", [phrase]))?
                .first?["c"]?.int ?? 0
        }
        // 单字查询：trigram 至少要三个字符，退回对本地索引的 LIKE 全扫。
        // 索引就在本机 SSD 上（不是 26GB 的 Photos.sqlite），一次约一两秒。
        return (try? db.query("SELECT COUNT(*) AS c FROM search WHERE text LIKE ?", ["%\(first)%"]))?
            .first?["c"]?.int ?? 0
    }

    private func matchPrimaryKeys(_ term: String, limit: Int) -> [Int64] {
        if let phrase = Self.matchQuery(term) {
            return ((try? db.query(
                "SELECT pk FROM search WHERE text MATCH ? ORDER BY date DESC LIMIT ?",
                [phrase, limit])) ?? []).compactMap { $0["pk"]?.int64 }
        }
        return ((try? db.query(
            "SELECT pk FROM search WHERE text LIKE ? ORDER BY date DESC LIMIT ?",
            ["%\(term)%", limit])) ?? []).compactMap { $0["pk"]?.int64 }
    }

    /// 把查询词转成 FTS5 短语查询。
    ///
    /// trigram 至少要三个连续字符才建索引，所以入库时把文本「逐字符插空格」
    /// （`上海外滩` → `上 海 外 滩`）。查询时同样插空格，`上海` 变成三字符的
    /// `"上 海"`，`img` 变成 `"i m g"`，都能走索引。单字无法构成 trigram，返回 nil，
    /// 由调用方退回 LIKE。
    private static func matchQuery(_ term: String) -> String? {
        // 插空格后长度 = 2n - 1：n = 1 时只有 1 个字符，进不了 trigram。
        guard term.count >= 2 else { return nil }
        let joined = term.map(String.init).joined(separator: " ")
        return "\"" + joined.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 入库前的文本变换：每个字符之间插一个空格。
    /// 这样 trigram 能覆盖到「两字词」这种中文搜索里最常见的长度。
    private static func interleaved(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count * 2)
        for char in text {
            if !out.isEmpty { out.append(" ") }
            out.append(char)
        }
        return out
    }
}
