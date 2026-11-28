import Foundation

// MARK: - 模型

/// 星图里的一颗「星」：内置资料库里的人物。
struct AtlasPerson: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let nameJA: String?
    let nameEN: String?
    let region: String
    let birthDate: String?
    let heightCM: Int?
    let bust: Int?
    let waist: Int?
    let hips: Int?
    let cup: String?
    let workCount: Int
    let hasAvatar: Bool
    let tags: [String]
    let birthplace: String?
    let bloodType: String?
    let debutYear: Int?
    let agency: String?
    let aliases: [String]
    let summary: String?
    let hobby: String?
    let officialSite: String?

    var regionTitle: String {
        switch region {
        case "china": return "中国大陆"
        case "taiwan": return "台湾"
        case "hongkong": return "香港"
        case "korea": return "韩国"
        case "western": return "欧美"
        default: return "日本"
        }
    }

    var initial: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
    }
}

/// 长河 / 放映厅里的作品。
struct AtlasWork: Identifiable, Hashable, Sendable {
    let id: Int64
    let dvdID: String
    let title: String
    let titleEN: String?
    let releaseDate: String?
    let coverURL: String?
    let thumbURL: String?
    let samples: [String]
    let trailerURL: String?
    let genres: [String]
    let series: String?
    let label: String?

    var displayTitle: String {
        if let titleEN, !titleEN.isEmpty, title.count < 6 { return titleEN }
        return title
    }
}

struct AtlasGenre: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int
    var id: String { name }
}

struct AtlasCoStar: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let count: Int
}

/// 人物的一条对外联络方式：抖音号、微博、Instagram…没有链接就不出现在界面上。
struct AtlasSocialLink: Identifiable, Hashable, Sendable {
    let kind: String
    let handle: String?
    let url: URL?

    var id: String { "\(kind)|\(handle ?? url?.absoluteString ?? "")" }

    var title: String {
        switch kind {
        case "douyin": return "抖音"
        case "weibo": return "微博"
        case "instagram": return "Instagram"
        case "twitter", "x": return "X"
        case "bilibili": return "哔哩哔哩"
        case "xiaohongshu": return "小红书"
        case "youtube": return "YouTube"
        default: return "主页"
        }
    }

    var symbol: String {
        switch kind {
        case "douyin": return "music.note"
        case "weibo": return "eye"
        case "instagram": return "camera"
        case "twitter", "x": return "bird"
        case "bilibili": return "play.rectangle"
        case "xiaohongshu": return "book"
        case "youtube": return "play.rectangle.fill"
        default: return "globe"
        }
    }

    var displayHandle: String? {
        guard let handle, !handle.isEmpty else { return nil }
        switch kind {
        case "weibo", "bilibili", "xiaohongshu", "youtube", "douyin":
            return handle
        case "instagram", "twitter", "x":
            return handle.hasPrefix("@") ? handle : "@\(handle)"
        default:
            return handle
        }
    }
}

struct AtlasPersonDetail: Sendable {
    let person: AtlasPerson
    let works: [AtlasWork]
    let coStars: [AtlasCoStar]
    let genres: [AtlasGenre]
    let topWorks: [AtlasWork]
    let links: [AtlasSocialLink]
    let labels: [AtlasGenre]
}

struct AtlasYearCount: Identifiable, Hashable, Sendable {
    let year: Int
    let count: Int
    var id: Int { year }
}

// MARK: - 人物检索台的分面

/// 罩杯尺上的一格：字母 + 该罩杯的人数。
struct AtlasCupFacet: Identifiable, Hashable, Sendable {
    let cup: String
    let count: Int
    /// 这一杯的平均胸围，用来把「拟人」落到数字上。
    var averageBust: Int?
    var id: String { cup }
}

/// 身高尺上的一格：5cm 为一段（start...start+4）。
struct AtlasHeightBand: Identifiable, Hashable, Sendable {
    let start: Int
    let count: Int
    var id: Int { start }
    var label: String { "\(start)–\(start + 4)" }
}

/// 标签星座里的一个标签：按人数排序。
struct AtlasTagFacet: Identifiable, Hashable, Sendable {
    let tag: String
    let count: Int
    var id: String { tag }
}

/// 体型矩阵的一格：罩杯 × 身高段的人数。
struct AtlasCupHeightCell: Identifiable, Hashable, Sendable {
    let cup: String
    let band: Int
    let count: Int
    var id: String { "\(cup)|\(band)" }
}

/// 作品量阶梯的一档。
struct AtlasWorkTier: Identifiable, Hashable, Sendable {
    let min: Int
    let max: Int?
    let count: Int
    var id: Int { min }
    var label: String { max.map { "\(min)–\($0)" } ?? "\(min)+" }
}

/// 作品量分档的唯一真相：数据库统计和筛选条件都从这里取，避免两边写歪。
enum AtlasWorkTiers {
    static let bounds: [(min: Int, max: Int?)] = [
        (1000, nil), (500, 999), (200, 499), (50, 199), (0, 49)
    ]

    static func bounds(for min: Int) -> (min: Int, max: Int?)? {
        bounds.first { $0.min == min }
    }
}

/// 人物花名册 / 分析结果的排序方式。
enum AtlasPersonSort: String, CaseIterable, Identifiable {
    case works
    case height
    case cup
    case name
    case birth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .works: return "按作品数"
        case .height: return "按身高"
        case .cup: return "按罩杯"
        case .name: return "按名字"
        case .birth: return "按出生"
        }
    }

    var symbol: String {
        switch self {
        case .works: return "film.stack"
        case .height: return "ruler"
        case .cup: return "heart"
        case .name: return "textformat.abc"
        case .birth: return "calendar"
        }
    }
}

/// 作品集的排序方式。
enum AtlasWorkSort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "最新发行"
        case .oldest: return "最早发行"
        case .code: return "按番号"
        }
    }

    var symbol: String {
        switch self {
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        case .code: return "textformat.abc"
        }
    }
}

// MARK: - 只读数据层

/// 星图资料库（用户在菜单里选择的 catalog.sqlite）的只读查询层。
///
/// 安装包不内置这份数据库，因此没有「默认候选路径」：只有用户选过并且文件还在时才可读。
/// 与 `CatalogNameDictionary` 的分工：那边只加载人物/片商做识别；
/// 星图需要作品、分类、共演关系，这里按需查询，不整库常驻内存。
final class AtlasDatabase {
    private let database: SQLiteDatabase?

    init(path: String? = nil) {
        guard let target = path ?? AtlasCatalogPaths.selectedPath,
              FileManager.default.fileExists(atPath: target) else {
            database = nil
            return
        }
        database = try? SQLiteDatabase(path: target, readonly: true, wal: false)
    }

    var isAvailable: Bool { database != nil }

    // MARK: 总量

    func totals() -> (people: Int, works: Int, genres: Int) {
        guard let database else { return (0, 0, 0) }
        let people = Int((try? database.query("SELECT COUNT(*) AS n FROM actresses"))?.first?["n"]?.int64 ?? 0)
        let works = Int((try? database.query("SELECT COUNT(*) AS n FROM works"))?.first?["n"]?.int64 ?? 0)
        let genres = Int((try? database.query("SELECT COUNT(DISTINCT genre) AS n FROM work_genres"))?.first?["n"]?.int64 ?? 0)
        return (people, works, genres)
    }

    // MARK: 人物

    func people(limit: Int = 1600, region: String? = nil) -> [AtlasPerson] {
        guard let database else { return [] }
        var sql = """
            SELECT id, name, name_ja, name_en, region, birth_date, height_cm, bust, waist, hips, cup,
                   COALESCE(work_count, 0) AS work_count, has_avatar, tags,
                   birthplace, blood_type, debut_year, agency,
                   aliases, summary, hobby, official_site
            FROM actresses
            """
        var binds: [Any?] = []
        if let region {
            sql += " WHERE region = ?"
            binds.append(region)
        }
        sql += " ORDER BY COALESCE(work_count, -1) DESC, id LIMIT ?"
        binds.append(limit)
        let rows = (try? database.query(sql, binds)) ?? []
        return rows.compactMap(person(from:))
    }

    /// 人物页的花名册：地区 / 罩杯 / 身高段 / 标签 / 关键词可以叠加，全部落在 SQL 里，
    /// 这样筛出来的结果和尺子上的计数是同一份数据。
    func rosterPeople(region: String?, cup: String?, heightBand: Int?,
                      tag: String?, workTier: Int?, keyword: String?,
                      sort: AtlasPersonSort = .works,
                      limit: Int = 800) -> [AtlasPerson] {
        guard let database else { return [] }
        let filter = rosterFilter(region: region, cup: cup, heightBand: heightBand,
                                  tag: tag, workTier: workTier, keyword: keyword)
        var binds = filter.binds
        var sql = """
            SELECT id, name, name_ja, name_en, region, birth_date, height_cm, bust, waist, hips, cup,
                   COALESCE(work_count, 0) AS work_count, has_avatar, tags,
                   birthplace, blood_type, debut_year, agency,
                   aliases, summary, hobby, official_site
            FROM actresses
            """
        if !filter.whereClause.isEmpty { sql += " WHERE " + filter.whereClause }
        sql += " ORDER BY " + rosterOrder(sort) + " LIMIT ?"
        binds.append(limit)
        let rows = (try? database.query(sql, binds)) ?? []
        return rows.compactMap(person(from:))
    }

    private func rosterOrder(_ sort: AtlasPersonSort) -> String {
        switch sort {
        case .works:
            return "COALESCE(work_count, -1) DESC, id"
        case .height:
            return "height_cm IS NULL, height_cm DESC, COALESCE(work_count, -1) DESC"
        case .cup:
            return """
                CASE UPPER(TRIM(cup))
                  WHEN 'A' THEN 1 WHEN 'B' THEN 2 WHEN 'C' THEN 3 WHEN 'D' THEN 4
                  WHEN 'E' THEN 5 WHEN 'F' THEN 6 WHEN 'G' THEN 7 WHEN 'H' THEN 8
                  WHEN 'I' THEN 9 WHEN 'J' THEN 10 WHEN 'K' THEN 11 WHEN 'L' THEN 12
                  WHEN 'M' THEN 13 WHEN 'N' THEN 14 WHEN 'O' THEN 15 ELSE 20 END DESC,
                COALESCE(work_count, -1) DESC, id
                """
        case .name:
            return "name ASC, id"
        case .birth:
            return "birth_date IS NULL, birth_date DESC, COALESCE(work_count, -1) DESC"
        }
    }

    /// 当前筛选条件下的总人数（不受花名册 800 条上限影响）。
    func rosterCount(region: String?, cup: String?, heightBand: Int?,
                     tag: String?, workTier: Int?, keyword: String?) -> Int {
        guard let database else { return 0 }
        let filter = rosterFilter(region: region, cup: cup, heightBand: heightBand,
                                  tag: tag, workTier: workTier, keyword: keyword)
        var sql = "SELECT COUNT(*) AS n FROM actresses"
        if !filter.whereClause.isEmpty { sql += " WHERE " + filter.whereClause }
        let rows = (try? database.query(sql, filter.binds)) ?? []
        return rows.first?["n"]?.int ?? 0
    }

    private func rosterFilter(region: String?, cup: String?, heightBand: Int?,
                              tag: String?, workTier: Int?, keyword: String?) -> (whereClause: String, binds: [Any?]) {
        var conditions: [String] = []
        var binds: [Any?] = []
        if let region, !region.isEmpty {
            conditions.append("region = ?")
            binds.append(region)
        }
        if let cup, !cup.isEmpty {
            conditions.append("UPPER(TRIM(cup)) = ?")
            binds.append(cup.uppercased())
        }
        if let heightBand {
            conditions.append("height_cm >= ? AND height_cm < ?")
            binds.append(heightBand)
            binds.append(heightBand + 5)
        }
        if let tag, !tag.isEmpty {
            conditions.append("tags LIKE ?")
            binds.append("%\"\(tag)\"%")
        }
        if let workTier, let bounds = AtlasWorkTiers.bounds(for: workTier) {
            if let max = bounds.max {
                conditions.append("COALESCE(work_count, 0) >= ? AND COALESCE(work_count, 0) <= ?")
                binds.append(bounds.min)
                binds.append(max)
            } else {
                conditions.append("COALESCE(work_count, 0) >= ?")
                binds.append(bounds.min)
            }
        }
        if let keyword, !keyword.isEmpty {
            let like = "%\(keyword)%"
            conditions.append("(name LIKE ? OR IFNULL(name_ja, '') LIKE ? OR IFNULL(name_en, '') LIKE ?)")
            binds.append(like)
            binds.append(like)
            binds.append(like)
        }
        return (conditions.joined(separator: " AND "), binds)
    }

    /// 罩杯分布：A→O 按字母排好，缺的杯不占位。
    func cupFacets(region: String?) -> [AtlasCupFacet] {
        guard let database else { return [] }
        var sql = """
            SELECT UPPER(TRIM(cup)) AS c, COUNT(*) AS n,
                   AVG(CASE WHEN bust > 0 THEN bust END) AS avg_bust
            FROM actresses
            WHERE IFNULL(cup, '') <> ''
            """
        var binds: [Any?] = []
        if let region, !region.isEmpty {
            sql += " AND region = ?"
            binds.append(region)
        }
        sql += " GROUP BY c"
        let rows = (try? database.query(sql, binds)) ?? []
        let order = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"]
        let facets = rows.compactMap { row -> AtlasCupFacet? in
            guard let cup = row["c"]?.string, (row["n"]?.int ?? 0) > 0 else { return nil }
            let average: Int? = row["avg_bust"]?.double.map { Int($0.rounded()) }
            return AtlasCupFacet(cup: cup, count: row["n"]?.int ?? 0, averageBust: average)
        }
        return facets.sorted {
            (order.firstIndex(of: $0.cup) ?? 99) < (order.firstIndex(of: $1.cup) ?? 99)
        }
    }

    /// 身高分布：145...189 按 5cm 分段，没人的段补 0，尺子才不会断。
    func heightBands(region: String?) -> [AtlasHeightBand] {
        guard let database else { return [] }
        var sql = """
            SELECT (height_cm / 5) * 5 AS b, COUNT(*) AS n
            FROM actresses
            WHERE height_cm BETWEEN 145 AND 189
            """
        var binds: [Any?] = []
        if let region, !region.isEmpty {
            sql += " AND region = ?"
            binds.append(region)
        }
        sql += " GROUP BY b"
        let rows = (try? database.query(sql, binds)) ?? []
        var counts: [Int: Int] = [:]
        for row in rows {
            guard let band = row["b"]?.int else { continue }
            counts[band] = row["n"]?.int ?? 0
        }
        return stride(from: 145, through: 185, by: 5).map {
            AtlasHeightBand(start: $0, count: counts[$0] ?? 0)
        }
    }

    /// 标签星座：取作品数最高的一批人物统计 tags JSON，避免扫全库。
    func tagFacets(region: String?, sample: Int = 4000, limit: Int = 40) -> [AtlasTagFacet] {
        guard let database else { return [] }
        var sql = "SELECT tags FROM actresses WHERE tags IS NOT NULL AND tags <> '[]'"
        var binds: [Any?] = []
        if let region, !region.isEmpty {
            sql += " AND region = ?"
            binds.append(region)
        }
        sql += " ORDER BY COALESCE(work_count, -1) DESC LIMIT ?"
        binds.append(sample)
        let rows = (try? database.query(sql, binds)) ?? []
        var counts: [String: Int] = [:]
        for row in rows {
            for tag in Self.decodeArray(row["tags"]?.string) where !tag.isEmpty {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { AtlasTagFacet(tag: $0.key, count: $0.value) }
    }

    /// 体型矩阵：罩杯 × 身高段的人数，用来铺热力图。
    func cupHeightMatrix(region: String?) -> [AtlasCupHeightCell] {
        guard let database else { return [] }
        var sql = """
            SELECT UPPER(TRIM(cup)) AS c, (height_cm / 5) * 5 AS b, COUNT(*) AS n
            FROM actresses
            WHERE IFNULL(cup, '') <> '' AND height_cm BETWEEN 145 AND 189
            """
        var binds: [Any?] = []
        if let region, !region.isEmpty {
            sql += " AND region = ?"
            binds.append(region)
        }
        sql += " GROUP BY c, b"
        let rows = (try? database.query(sql, binds)) ?? []
        return rows.compactMap { row in
            guard let cup = row["c"]?.string, let band = row["b"]?.int else { return nil }
            let count = row["n"]?.int ?? 0
            guard count > 0 else { return nil }
            return AtlasCupHeightCell(cup: cup, band: band, count: count)
        }
    }

    /// 作品量阶梯：每档的人数。
    func workTierFacets(region: String?) -> [AtlasWorkTier] {
        guard let database else { return [] }
        var sql = """
            SELECT CASE
                     WHEN COALESCE(work_count, 0) >= 1000 THEN 1000
                     WHEN work_count >= 500 THEN 500
                     WHEN work_count >= 200 THEN 200
                     WHEN work_count >= 50 THEN 50
                     ELSE 0
                   END AS tier,
                   COUNT(*) AS n
            FROM actresses
            """
        var binds: [Any?] = []
        if let region, !region.isEmpty {
            sql += " WHERE region = ?"
            binds.append(region)
        }
        sql += " GROUP BY tier"
        let rows = (try? database.query(sql, binds)) ?? []
        var counts: [Int: Int] = [:]
        for row in rows {
            guard let tier = row["tier"]?.int else { continue }
            counts[tier] = row["n"]?.int ?? 0
        }
        return AtlasWorkTiers.bounds.map {
            AtlasWorkTier(min: $0.min, max: $0.max, count: counts[$0.min] ?? 0)
        }
    }

    func person(id: Int64) -> AtlasPerson? {
        guard let database else { return nil }
        let rows = (try? database.query("""
            SELECT id, name, name_ja, name_en, region, birth_date, height_cm, bust, waist, hips, cup,
                   COALESCE(work_count, 0) AS work_count, has_avatar, tags,
                   birthplace, blood_type, debut_year, agency,
                   aliases, summary, hobby, official_site
            FROM actresses WHERE id = ?
            """, [id])) ?? []
        return rows.first.flatMap(person(from:))
    }

    /// 人物的社交 / 联络方式：只收抖音、微博这类对外账号，资料站的内链不显示。
    func personLinks(id: Int64) -> [AtlasSocialLink] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT source, url FROM person_links
            WHERE actress_id = ? AND kind = 'profile'
            ORDER BY CASE source
                WHEN 'douyin' THEN 0 WHEN 'weibo' THEN 1 WHEN 'instagram' THEN 2
                WHEN 'twitter' THEN 3 WHEN 'x' THEN 3 WHEN 'bilibili' THEN 4
                WHEN 'xiaohongshu' THEN 5 WHEN 'youtube' THEN 6 ELSE 9 END
            """, [id])) ?? []
        var result: [AtlasSocialLink] = []
        var seen = Set<String>()
        var perKind: [String: Int] = [:]
        for row in rows {
            guard let source = row["source"]?.string?.lowercased(),
                  let raw = row["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let link = Self.socialLink(source: source, raw: raw) else { continue }
            if seen.insert(link.id).inserted {
                // 同一个人常有新旧两个账号，每个平台最多留 2 个，避免名片堆成一片。
                guard (perKind[link.kind] ?? 0) < 2 else { continue }
                perKind[link.kind, default: 0] += 1
                result.append(link)
            }
        }
        return result
    }

    private static func socialLink(source: String, raw: String) -> AtlasSocialLink? {
        let kind = source == "x" ? "twitter" : source
        switch kind {
        case "douyin":
            // 抖音多数存成「抖音号：75968063879」这种文本，也可能是纯账号。
            var handle = raw
            if let range = handle.range(of: "：") ?? handle.range(of: ":") {
                handle = String(handle[range.upperBound...])
            }
            handle = handle
                .replacingOccurrences(of: "抖音号", with: "")
                .replacingOccurrences(of: "抖音", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !handle.isEmpty else { return nil }
            let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
            return AtlasSocialLink(kind: kind, handle: handle,
                                   url: URL(string: "https://www.douyin.com/search/\(encoded)"))
        case "weibo":
            guard let url = normalizedURL(raw) else { return nil }
            return AtlasSocialLink(kind: kind, handle: pathHandle(url) ?? "主页", url: url)
        case "instagram", "twitter":
            guard let url = normalizedURL(raw) else { return nil }
            return AtlasSocialLink(kind: kind, handle: pathHandle(url), url: url)
        case "bilibili":
            guard let url = normalizedURL(raw) else { return nil }
            let uid = pathHandle(url).map { "UID \($0)" }
            return AtlasSocialLink(kind: kind, handle: uid, url: url)
        case "youtube":
            guard let url = normalizedURL(raw) else { return nil }
            return AtlasSocialLink(kind: kind, handle: pathHandle(url), url: url)
        case "xiaohongshu":
            guard let url = normalizedURL(raw) else { return nil }
            return AtlasSocialLink(kind: kind, handle: "小红书", url: url)
        default:
            return nil
        }
    }

    /// 资料里的链接常常省略协议头（weibo.com/u/xxx），补成 https 才能打开。
    private static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    static func webURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        return normalizedURL(raw)
    }

    private static func pathHandle(_ url: URL) -> String? {
        url.path.split(separator: "/").map(String.init).last
    }

    func personWorks(id: Int64, limit: Int = 60) -> [AtlasWork] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT w.id, w.dvd_id, w.title_ja, w.title_en, w.release_date, w.cover_url,
                   w.thumb_url, w.sample_urls, w.trailer_url, w.genres, w.series, w.label
            FROM work_actresses wa
            JOIN works w ON w.id = wa.work_id
            WHERE wa.actress_id = ? AND w.kind = 'video'
            ORDER BY (wa.position IS NULL), wa.position, w.release_date DESC
            LIMIT ?
            """, [id, limit])) ?? []
        return rows.compactMap(work(from:))
    }

    func coStars(id: Int64, limit: Int = 12) -> [AtlasCoStar] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT wa2.actress_id AS aid, a.name AS name, COUNT(*) AS n
            FROM work_actresses wa1
            JOIN work_actresses wa2 ON wa2.work_id = wa1.work_id AND wa2.actress_id <> wa1.actress_id
            JOIN actresses a ON a.id = wa2.actress_id
            WHERE wa1.actress_id = ?
            GROUP BY wa2.actress_id
            ORDER BY n DESC
            LIMIT ?
            """, [id, limit])) ?? []
        return rows.compactMap { row in
            guard let aid = row["aid"]?.int64, let name = row["name"]?.string else { return nil }
            return AtlasCoStar(id: aid, name: name, count: row["n"]?.int ?? 0)
        }
    }

    /// 她作品里出现最多的厂牌 / 发行label。
    func personLabels(id: Int64, limit: Int = 8) -> [AtlasGenre] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT w.label AS label, COUNT(*) AS n
            FROM work_actresses wa
            JOIN works w ON w.id = wa.work_id
            WHERE wa.actress_id = ? AND IFNULL(w.label, '') <> ''
            GROUP BY w.label
            ORDER BY n DESC
            LIMIT ?
            """, [id, limit])) ?? []
        return rows.compactMap { row in
            guard let name = row["label"]?.string else { return nil }
            return AtlasGenre(name: name, count: row["n"]?.int ?? 0)
        }
    }

    func personGenres(id: Int64, limit: Int = 8) -> [AtlasGenre] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT g.genre AS genre, COUNT(*) AS n
            FROM work_actresses wa
            JOIN work_genres g ON g.work_id = wa.work_id
            WHERE wa.actress_id = ?
            GROUP BY g.genre
            ORDER BY n DESC
            LIMIT ?
            """, [id, limit])) ?? []
        return rows.compactMap { row in
            guard let name = row["genre"]?.string else { return nil }
            return AtlasGenre(name: name, count: row["n"]?.int ?? 0)
        }
    }

    // MARK: 作品与分类

    func yearCounts() -> [AtlasYearCount] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT substr(release_date, 1, 4) AS y, COUNT(*) AS n
            FROM works
            WHERE kind = 'video' AND release_date IS NOT NULL AND length(release_date) >= 4
            GROUP BY y
            ORDER BY y DESC
            """)) ?? []
        return rows.compactMap { row in
            guard let raw = row["y"]?.string, let year = Int(raw) else { return nil }
            return AtlasYearCount(year: year, count: row["n"]?.int ?? 0)
        }
    }

    func works(year: Int, limit: Int = 48) -> [AtlasWork] {
        guard let database else { return [] }
        let start = String(format: "%04d-01-01", year)
        let end = String(format: "%04d-01-01", year + 1)
        let rows = (try? database.query("""
            SELECT id, dvd_id, title_ja, title_en, release_date, cover_url, thumb_url,
                   sample_urls, trailer_url, genres, series, label
            FROM works
            WHERE kind = 'video' AND release_date >= ? AND release_date < ?
            ORDER BY release_date DESC, id DESC
            LIMIT ?
            """, [start, end, limit])) ?? []
        return rows.compactMap(work(from:))
    }

    func works(genre: String, limit: Int = 24) -> [AtlasWork] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT w.id, w.dvd_id, w.title_ja, w.title_en, w.release_date, w.cover_url,
                   w.thumb_url, w.sample_urls, w.trailer_url, w.genres, w.series, w.label
            FROM work_genres g
            JOIN works w ON w.id = g.work_id
            WHERE g.genre = ? AND w.kind = 'video'
            ORDER BY w.release_date DESC
            LIMIT ?
            """, [genre, limit])) ?? []
        return rows.compactMap(work(from:))
    }

    func genres(limit: Int = 60) -> [AtlasGenre] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT genre, COUNT(*) AS n
            FROM work_genres
            GROUP BY genre
            ORDER BY n DESC
            LIMIT ?
            """, [limit])) ?? []
        return rows.compactMap { row in
            guard let name = row["genre"]?.string else { return nil }
            return AtlasGenre(name: name, count: row["n"]?.int ?? 0)
        }
    }

    /// 作品集浏览：年份 / 分类 / 排序 + 分页。
    func works(year: Int?, genre: String?, sort: AtlasWorkSort,
               offset: Int, limit: Int) -> [AtlasWork] {
        guard let database else { return [] }
        var conditions = ["w.kind = 'video'"]
        var binds: [Any?] = []
        if let year {
            conditions.append("w.release_date >= ? AND w.release_date < ?")
            binds.append(String(format: "%04d-01-01", year))
            binds.append(String(format: "%04d-01-01", year + 1))
        }
        var join = ""
        if let genre, !genre.isEmpty {
            join = "JOIN work_genres g ON g.work_id = w.id"
            conditions.append("g.genre = ?")
            binds.append(genre)
        }
        let order: String
        switch sort {
        case .newest: order = "w.release_date DESC, w.id DESC"
        case .oldest: order = "w.release_date ASC, w.id ASC"
        case .code: order = "w.dvd_id ASC"
        }
        binds.append(limit)
        binds.append(offset)
        let rows = (try? database.query("""
            SELECT w.id, w.dvd_id, w.title_ja, w.title_en, w.release_date, w.cover_url,
                   w.thumb_url, w.sample_urls, w.trailer_url, w.genres, w.series, w.label
            FROM works w \(join)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order)
            LIMIT ? OFFSET ?
            """, binds)) ?? []
        return rows.compactMap(work(from:))
    }

    /// 当前筛选条件下的作品总数：作品集页头展示，也用于判断是否还能继续加载。
    func workTotal(year: Int?, genre: String?) -> Int {
        guard let database else { return 0 }
        var conditions = ["w.kind = 'video'"]
        var binds: [Any?] = []
        if let year {
            conditions.append("w.release_date >= ? AND w.release_date < ?")
            binds.append(String(format: "%04d-01-01", year))
            binds.append(String(format: "%04d-01-01", year + 1))
        }
        var join = ""
        if let genre, !genre.isEmpty {
            join = "JOIN work_genres g ON g.work_id = w.id"
            conditions.append("g.genre = ?")
            binds.append(genre)
        }
        let rows = (try? database.query("""
            SELECT COUNT(*) AS n FROM works w \(join)
            WHERE \(conditions.joined(separator: " AND "))
            """, binds)) ?? []
        return rows.first?["n"]?.int ?? 0
    }

    func randomWorks(limit: Int = 24) -> [AtlasWork] {
        guard let database else { return [] }
        let rows = (try? database.query("""
            SELECT id, dvd_id, title_ja, title_en, release_date, cover_url, thumb_url,
                   sample_urls, trailer_url, genres, series, label
            FROM works
            WHERE kind = 'video' AND cover_url IS NOT NULL AND trailer_url IS NOT NULL
            ORDER BY RANDOM()
            LIMIT ?
            """, [limit])) ?? []
        return rows.compactMap(work(from:))
    }

    func work(id: Int64) -> AtlasWork? {
        guard let database else { return nil }
        let rows = (try? database.query("""
            SELECT id, dvd_id, title_ja, title_en, release_date, cover_url, thumb_url,
                   sample_urls, trailer_url, genres, series, label
            FROM works WHERE id = ? LIMIT 1
            """, [id])) ?? []
        return rows.first.flatMap(work(from:))
    }

    /// 按番号反查作品：给「网络资源 → 资料库」用。
    func work(code: String) -> AtlasWork? {
        guard let database else { return nil }
        let normalized = code.uppercased().replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }
        let hyphenated: String
        if let range = normalized.range(of: #"^([A-Z]+)(\d+)$"#, options: .regularExpression) {
            let label = String(normalized[range].prefix { $0.isLetter })
            let number = String(normalized.dropFirst(label.count))
            hyphenated = "\(label)-\(number)"
        } else {
            hyphenated = normalized
        }
        let rows = (try? database.query("""
            SELECT id, dvd_id, title_ja, title_en, release_date, cover_url, thumb_url,
                   sample_urls, trailer_url, genres, series, label
            FROM works
            WHERE kind = 'video' AND (UPPER(dvd_id) = ? OR UPPER(dvd_id) = ?)
            LIMIT 1
            """, [normalized, hyphenated])) ?? []
        return rows.first.flatMap(work(from:))
    }

    // MARK: 搜索

    func searchPeople(_ keyword: String, limit: Int = 12) -> [AtlasPerson] {
        guard let database, !keyword.isEmpty else { return [] }
        let like = "%\(keyword)%"
        let rows = (try? database.query("""
            SELECT id, name, name_ja, name_en, region, birth_date, height_cm, bust, waist, hips, cup,
                   COALESCE(work_count, 0) AS work_count, has_avatar, tags,
                   birthplace, blood_type, debut_year, agency,
                   aliases, summary, hobby, official_site
            FROM actresses
            WHERE name LIKE ? OR IFNULL(aliases, '') LIKE ?
               OR IFNULL(name_ja, '') LIKE ? OR IFNULL(name_en, '') LIKE ?
            ORDER BY COALESCE(work_count, -1) DESC
            LIMIT ?
            """, [like, like, like, like, limit])) ?? []
        return rows.compactMap(person(from:))
    }

    func searchWorks(_ keyword: String, limit: Int = 12) -> [AtlasWork] {
        guard let database, !keyword.isEmpty else { return [] }
        let like = "%\(keyword)%"
        let rows = (try? database.query("""
            SELECT id, dvd_id, title_ja, title_en, release_date, cover_url, thumb_url,
                   sample_urls, trailer_url, genres, series, label
            FROM works
            WHERE kind = 'video'
              AND (dvd_id LIKE ? OR IFNULL(title_ja, '') LIKE ? OR IFNULL(title_en, '') LIKE ?)
            ORDER BY release_date DESC
            LIMIT ?
            """, [like, like, like, limit])) ?? []
        return rows.compactMap(work(from:))
    }

    // MARK: 行映射

    private func person(from row: [String: SQLiteValue]) -> AtlasPerson? {
        guard let id = row["id"]?.int64, let name = row["name"]?.string else { return nil }
        return AtlasPerson(
            id: id,
            name: name,
            nameJA: row["name_ja"]?.string,
            nameEN: row["name_en"]?.string,
            region: row["region"]?.string ?? "japan",
            birthDate: row["birth_date"]?.string,
            heightCM: row["height_cm"]?.int,
            bust: Self.positive(row["bust"]?.int),
            waist: Self.positive(row["waist"]?.int),
            hips: Self.positive(row["hips"]?.int),
            cup: row["cup"]?.string,
            workCount: row["work_count"]?.int ?? 0,
            hasAvatar: row["has_avatar"]?.bool ?? false,
            tags: Self.decodeArray(row["tags"]?.string),
            birthplace: row["birthplace"]?.string,
            bloodType: row["blood_type"]?.string,
            debutYear: row["debut_year"]?.int,
            agency: row["agency"]?.string,
            aliases: Self.decodeArray(row["aliases"]?.string)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            summary: row["summary"]?.string,
            hobby: row["hobby"]?.string,
            officialSite: row["official_site"]?.string)
    }

    private func work(from row: [String: SQLiteValue]) -> AtlasWork? {
        guard let id = row["id"]?.int64, let dvd = row["dvd_id"]?.string else { return nil }
        let title = row["title_ja"]?.string ?? row["title_en"]?.string ?? dvd
        return AtlasWork(
            id: id,
            dvdID: dvd,
            title: title,
            titleEN: row["title_en"]?.string,
            releaseDate: row["release_date"]?.string,
            coverURL: row["cover_url"]?.string,
            thumbURL: row["thumb_url"]?.string,
            samples: Self.decodeArray(row["sample_urls"]?.string),
            trailerURL: row["trailer_url"]?.string,
            genres: Self.decodeArray(row["genres"]?.string),
            series: row["series"]?.string,
            label: row["label"]?.string)
    }

    private static func decodeArray(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// 三围字段常被写成 0，当作没有。
    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
