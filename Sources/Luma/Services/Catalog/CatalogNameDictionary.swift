import Foundation

/// 内置的 AV 女优 / 片商资料库，数据来自仓库里的 `Resources/Catalog/catalog.sqlite`。
///
/// 这张库在构建时由 `Tools/catalog_build/build/build_catalog_db.py` 生成：
/// - 女优：姓名与别名、地区、出生日期、年龄、身高、三围、罩杯、作品数、标签、简介
/// - 片商：名称与别名、地区、作品数、简介
/// - 番号前缀 → 片商
///
/// 识别器用它做标题匹配，人物档案用它直接展示资料，不必再联网搜索。
enum CatalogNameDictionary {
    struct Payload {
        var japanese: [String] = []
        var korean: [String] = []
        var western: [String] = []
        var chinese: [String] = []
        var studios: [String] = []
        var codeMakers: [String: String] = [:]

        var actresses: [String] { japanese + korean + western + chinese }
    }

    static let payload: Payload = makePayload()
    static let codeMakers: [String: String] = makeCodeMakers()

    /// 后台预热：首次读取资料库、构建姓名索引要一两秒。
    /// 以前第一次打开详情页才在主线程触发，整窗会明显卡住；现在启动时放到后台跑一次。
    static func prewarm() {
        _ = actresses
        _ = studios
        _ = payload
        _ = actressIndex
        _ = studioIndex
        _ = actressLooseIndex
        _ = studioLooseIndex
        _ = codeMakers
        // 短名索引要在后台建好：频道页的星图名册一进来就会用它。
        shortIndexLock.lock()
        if shortActressCache == nil { shortActressCache = makeShortActressIndex() }
        if shortStudioCache == nil { shortStudioCache = makeShortStudioIndex() }
        shortIndexLock.unlock()
    }

    /// 所有女优的名字与别名（识别标题用）。
    static var allActressNames: [String] {
        actresses.flatMap { [$0.name] + $0.aliases }
    }

    /// 资料库浏览页用：全部人物 / 全部机构。
    static var allActresses: [CatalogActressRecord] { actresses }
    static var allStudios: [CatalogStudioRecord] { studios }

    static var allStudioNames: [String] {
        studios.flatMap { [$0.name] + $0.aliases }
    }

    /// 按姓名 / 别名查一个人：繁简、大小写、叠字符（々）、括号里的别名都做归一化；
    /// 精确命不中时再做包含匹配，让「高宫菜菜子 (高宫菜々子)」这类写法也能落到同一条记录。
    static func actress(matching name: String) -> CatalogActressRecord? {
        for key in lookupKeys(for: name) {
            if let hit = actressIndex[key] { return hit }
        }
        return fuzzyActress(name)
    }

    static func studio(matching name: String) -> CatalogStudioRecord? {
        for key in lookupKeys(for: name) {
            if let hit = studioIndex[key] { return hit }
        }
        return fuzzyStudio(name)
    }

    /// 名册展示用的严格匹配：只认归一化后完全相等的名字，不做包含匹配。
    /// 「YUI」「RICA」这类很短的英文名容易模糊命中别人，展示匹配宁可空缺也不要认错人。
    /// 站点常在厂牌尾巴挂渠道词（`10 MUSUME AV`、`HEYZO AV`、`JAV HD`、`PRESTIGE PREMIUM`），
    /// 资料库里存的是裸名字：先按原样精确匹配，命不中再把尾巴去掉试一次。
    static func exactActress(matching name: String) -> CatalogActressRecord? {
        let keys = lookupKeys(for: name)
        // 「写真图集精选」这类纯装饰标题不是名字，别拿去短名索引里撞别人。
        guard keys.contains(where: { !isGenericOnly($0) }) else { return nil }
        // 1. 原样精确命中（三字以内的短名只认主名 / 英文名）。
        for key in keys {
            if let hit = actressIndex[key], isPrimary(key, name: hit.name, nameEN: hit.nameEN) {
                return hit
            }
        }
        // 2. 去掉渠道尾巴（`Yui AV` → `Yui`）。
        for key in keys {
            guard let loose = looseKey(key) else { continue }
            if let hit = actressIndex[loose] ?? actressLooseIndex[loose] { return hit }
        }
        // 3. 站点装饰词与中英混写（`樱桃喵精选`、`Mio Ishikawa 石川澪`）：
        //    剥出来的候选常常正好是别名，三字以上放开别名匹配。
        let expanded = expandedKeys(keys)
        for key in expanded {
            if let hit = actressIndex[key], isPlausibleAlias(key, record: hit) { return hit }
            if let hit = actressLooseIndex[key] { return hit }
            if let loose = looseKey(key),
               let hit = actressIndex[loose] ?? actressLooseIndex[loose] { return hit }
        }
        // 4. 两三个字的短名（`金鱼精选` → `金鱼` → `Yui金鱼`、`鹿八岁精选` → `鹿八岁`）。
        //    只认剥过装饰词的候选，原始两字词（`少女`、`合集`）不拿来撞前缀 / 后缀。
        for key in decorationStrippedKeys(keys) {
            if let hit = shortActress(key) { return hit }
        }
        return nil
    }

    static func exactStudio(matching name: String) -> CatalogStudioRecord? {
        let keys = lookupKeys(for: name)
        // 同上：只由「写真 / 图集 / 精选」这类通用词组成的标题不匹配任何机构。
        guard keys.contains(where: { !isGenericOnly($0) }) else { return nil }
        for key in keys {
            if let hit = studioIndex[key], isPrimary(key, name: hit.name, nameEN: hit.nameEN) {
                return hit
            }
        }
        for key in keys {
            guard let loose = looseKey(key) else { continue }
            if let hit = studioIndex[loose] ?? studioLooseIndex[loose] { return hit }
        }
        // 站点给名字挂装饰（`森萝财团精选`、`[Madou 视频]`）：剥掉装饰词再查一次。
        let expanded = expandedKeys(keys)
        for key in expanded {
            if let hit = studioIndex[key], isPlausibleAlias(key, record: hit) { return hit }
            if let hit = studioLooseIndex[key] { return hit }
            if let loose = looseKey(key),
               let hit = studioIndex[loose] ?? studioLooseIndex[loose] { return hit }
        }
        for key in decorationStrippedKeys(keys) {
            if let hit = shortStudio(key) { return hit }
        }
        return nil
    }

    /// 三字以内的短名只认主名 / 英文名，避免命中别人的别名。
    private static func isPrimary(_ key: String, name: String, nameEN: String?) -> Bool {
        guard key.count < 4 else { return true }
        return [name, nameEN ?? ""]
            .map(CatalogNameParser.normalize)
            .contains(key)
    }

    /// 站点用来标渠道 / 画质的尾巴词，以及厂牌名里的通用词（`Madou Media` → `Madou`）：
    /// 名称去掉这些词之后，才是站点上常用的短名字。
    private static let channelSuffixes = ["premium", "official", "channel", "uncensored",
                                          "media", "japan", "jav", "av", "hd", "tv",
                                          "4k", "8k", "com", "net", "jp"]

    /// 去掉名称尾巴上的渠道词；一个都没去掉就返回 nil，
    /// 免得宽松索引再查一遍同一个键（也避免把普通名字误当成带后缀的名字）。
    private static func looseKey(_ key: String) -> String? {
        var key = key
        var changed = false
        while key.count > 3,
              let suffix = channelSuffixes.first(where: {
                  key.count - $0.count >= 3 && key.hasSuffix($0)
              }) {
            key.removeLast(suffix.count)
            changed = true
        }
        return changed ? key : nil
    }

    /// 站点挂在名字尾巴上的装饰词：`[IMiss爱蜜社 视频]`、`[Madou 视频]`、`[某某 圖集]`，
    /// 以及合集卡片把人物包起来的写法（`森萝财团精选`、`布丁大法写真合集`）。
    /// 归一化会把方括号当标点去掉，但「视频」「精选」这类词会留下来，去掉它们才是资料库里的裸名字。
    private static let decorationSuffixes = ["视频", "視頻", "影片", "图集", "圖集",
                                             "套图", "套圖", "系列", "合集", "作品",
                                             "专区", "專區", "频道", "頻道",
                                             "精选", "精選", "写真", "寫真", "特辑", "特輯",
                                             "全集", "打包", "资源", "資源"]

    /// 合集卡片也会把装饰词放在名字前面（`精选合集 · 森萝财团`）。
    private static let decorationPrefixes = ["精选", "精選", "合集", "最新", "热门", "熱門",
                                             "推荐", "推薦", "独家", "獨家", "福利"]

    /// 通用词：站点用来分栏 / 标装饰的词，本身不是名字。
    ///
    /// 短名索引会从机构名里切出两字前缀 / 后缀（`丝慕写真` → `写真`、`麻豆传媒` → `视频`），
    /// 若不排除，像「写真图集精选」这种只由通用词拼成的合集标题就会撞到第一条带该后缀的记录
    /// （实测撞成了「丝慕GIRL」），卡片上就挂出了完全不相干的星图档案。
    private static let genericWords: Set<String> = [
        "写真", "寫真", "图集", "圖集", "套图", "套圖", "视频", "視頻", "影片",
        "系列", "合集", "作品", "精选", "精選", "特辑", "特輯", "全集",
        "打包", "资源", "資源", "专区", "專區", "频道", "頻道",
        "最新", "热门", "熱門", "推荐", "推薦", "独家", "獨家", "福利",
        "美女", "模特", "素人", "少女", "主播", "网红", "網紅",
        "国产", "國產", "日本", "韩国", "韓國", "欧美", "歐美", "亚洲", "亞洲"
    ]

    /// 标题是否只由装饰 / 通用词拼成：从两端反复剥，剥空就说明没有真名。
    private static func isGenericOnly(_ key: String) -> Bool {
        var value = key
        var stripped = true
        while stripped, !value.isEmpty {
            stripped = false
            for word in genericWords where value.hasPrefix(word) || value.hasSuffix(word) {
                if value.count == word.count { return true }
                if value.hasPrefix(word) {
                    value.removeFirst(word.count)
                } else {
                    value.removeLast(word.count)
                }
                stripped = true
                break
            }
        }
        return value.isEmpty
    }

    /// 逐层剥掉结尾的装饰词，返回每一层的候选键（不含原键）。
    /// 中文名可以剥到两个字（`金鱼精选` → `金鱼`），其它至少留三个字符，
    /// 免得把「人妻视频」剥成两字短名误命中别人。
    private static func strippedKeys(_ key: String) -> [String] {
        var key = key
        var keys: [String] = []
        while let suffix = decorationSuffixes.first(where: {
            guard key.hasSuffix($0) else { return false }
            let remainder = key.count - $0.count
            return remainder >= 3 || (remainder == 2 && containsCJK(key))
        }) {
            key.removeLast(suffix.count)
            keys.append(key)
        }
        return keys
    }

    private static func strippedPrefixKeys(_ key: String) -> [String] {
        var key = key
        var keys: [String] = []
        while let prefix = decorationPrefixes.first(where: {
            guard key.hasPrefix($0) else { return false }
            let remainder = key.count - $0.count
            return remainder >= 3 || (remainder == 2 && containsCJK(key))
        }) {
            key.removeFirst(prefix.count)
            keys.append(key)
        }
        return keys
    }

    /// 把候选名展开成更多写法：
    /// - 去掉为了规避搜索加的前后单字母（`w黑米粥w` → `黑米粥`）；
    /// - 逐层剥掉「精选 / 合集 / 写真 / 视频」这类装饰词；
    /// - 拆出中英混写里的每一段（`Mio Ishikawa 石川澪` → `mioishikawa` / `石川澪`）。
    private static func expandedKeys(_ keys: [String]) -> [String] {
        var result = decorationStrippedKeys(keys)
        func append(_ value: String) {
            guard !value.isEmpty, !keys.contains(value), !result.contains(value) else { return }
            result.append(value)
        }
        for value in Array(result) {
            for part in partKeys(value) { append(part) }
        }
        for key in keys {
            for part in partKeys(key) { append(part) }
        }
        return result
    }

    /// 只保留「装饰词剥出来的」候选：短名索引只用这些，
    /// 免得原始标题里的通用两字词（`少女`、`合集`）拿前缀 / 后缀去撞人名。
    private static func decorationStrippedKeys(_ keys: [String]) -> [String] {
        var result: [String] = []
        func append(_ value: String) {
            guard !value.isEmpty, !keys.contains(value), !result.contains(value) else { return }
            result.append(value)
        }
        for key in keys {
            let trimmed = stripLetterAffixes(key)
            append(trimmed)
            for candidate in (trimmed == key ? [key] : [key, trimmed]) {
                for value in strippedKeys(candidate) { append(value) }
                for value in strippedPrefixKeys(candidate) { append(value) }
            }
        }
        return result
    }

    /// 微博 / 小红书昵称常在前或后加一个单字母规避搜索：`w黑米粥w` → `黑米粥`。
    private static func stripLetterAffixes(_ key: String) -> String {
        var value = key
        if let first = value.first, first.isASCII, first.isLetter, value.count > 2,
           let second = value.dropFirst().first, isCJK(second) {
            value.removeFirst()
        }
        if let last = value.last, last.isASCII, last.isLetter, value.count > 2,
           let before = value.dropLast().last, isCJK(before) {
            value.removeLast()
        }
        return value
    }

    /// 中英混写的艺名归一化后连成一串，拆回拉丁段与汉字段分别匹配。
    private static func partKeys(_ key: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var currentIsASCII: Bool?
        for character in key {
            let ascii = character.isASCII && (character.isLetter || character.isNumber)
            if let currentIsASCII, currentIsASCII != ascii, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            currentIsASCII = ascii
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.filter { part in
            containsCJK(part) ? part.count >= 2 : part.count >= 3
        }
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
        }
    }

    private static func isCJK(_ character: Character) -> Bool {
        containsCJK(String(character))
    }

    private static func isShortCJK(_ key: String) -> Bool {
        containsCJK(key) && (2...3).contains(key.count)
    }

    /// 装饰词剥出来的键往往正好是别名（`樱桃喵` 是 `桜桃喵` 的别名）：
    /// 三字以上放开别名匹配，两字仍只认主名，避免短别名误命中。
    private static func isPlausibleAlias(_ key: String, record: CatalogActressRecord) -> Bool {
        if isPrimary(key, name: record.name, nameEN: record.nameEN) { return true }
        guard key.count >= 3 else { return false }
        // 短拉丁别名多半是平台 / 品牌（JVID / COS），交给厂牌匹配，别认成人名。
        if !containsCJK(key), key.count <= 4 { return false }
        return record.aliases.contains { CatalogNameParser.normalize($0) == key }
    }

    private static func isPlausibleAlias(_ key: String, record: CatalogStudioRecord) -> Bool {
        if isPrimary(key, name: record.name, nameEN: record.nameEN) { return true }
        guard key.count >= 3 else { return false }
        return record.aliases.contains { CatalogNameParser.normalize($0) == key }
    }

    // MARK: - 短名（两三个字）

    /// 两三个字的短名索引：`金鱼` → `Yui金鱼`、`鹿八岁` → `鹿八岁baby`。
    ///
    /// 合集卡片会把人物写成前缀 / 后缀（`金鱼精选`、`鹿八岁精选`），而资料库存的是完整艺名。
    /// 只给国产人物收 3–6 字的短名（索引规模不到全库十分之一），
    /// 记录本来就按作品数从多到少排，同名冲突时先登记的更完整。
    private static let shortIndexLock = NSLock()
    private static var shortActressCache: [String: CatalogActressRecord]?
    private static var shortStudioCache: [String: CatalogStudioRecord]?

    private static let shortDomesticRegions: Set<String> = ["china", "taiwan", "hongkong"]

    private static func shortActress(_ key: String) -> CatalogActressRecord? {
        guard isShortCJK(key), !genericWords.contains(key) else { return nil }
        shortIndexLock.lock()
        if let cached = shortActressCache {
            shortIndexLock.unlock()
            return cached[key]
        }
        let built = makeShortActressIndex()
        shortActressCache = built
        shortIndexLock.unlock()
        return built[key]
    }

    private static func shortStudio(_ key: String) -> CatalogStudioRecord? {
        guard isShortCJK(key), !genericWords.contains(key) else { return nil }
        shortIndexLock.lock()
        if let cached = shortStudioCache {
            shortIndexLock.unlock()
            return cached[key]
        }
        let built = makeShortStudioIndex()
        shortStudioCache = built
        shortIndexLock.unlock()
        return built[key]
    }

    private static func makeShortActressIndex() -> [String: CatalogActressRecord] {
        var index: [String: CatalogActressRecord] = [:]
        for record in actresses where shortDomesticRegions.contains(record.region) {
            for name in [record.name] + record.aliases {
                for key in shortKeys(name) where index[key] == nil {
                    index[key] = record
                }
            }
        }
        return index
    }

    private static func makeShortStudioIndex() -> [String: CatalogStudioRecord] {
        var index: [String: CatalogStudioRecord] = [:]
        for record in studios {
            for name in [record.name] + record.aliases {
                for key in shortKeys(name) where index[key] == nil {
                    index[key] = record
                }
            }
        }
        return index
    }

    /// 短名前缀 / 后缀：`Yui金鱼` → `yui`（拉丁，不进索引）/ `金鱼`。
    private static func shortKeys(_ name: String) -> [String] {
        let key = CatalogNameParser.normalize(name)
        guard containsCJK(key), (3...6).contains(key.count) else { return [] }
        var keys: [String] = []
        for length in 2...min(3, key.count - 1) {
            for candidate in [String(key.prefix(length)), String(key.suffix(length))] {
                guard !genericWords.contains(candidate) else { continue }
                keys.append(candidate)
            }
        }
        return keys
    }

    // MARK: - 模糊匹配

    /// 候选键：主名 + 括号里的别名，各自归一化。
    private static func lookupKeys(for name: String) -> [String] {
        let split = CatalogNameParser.splitAliases(name)
        var keys: [String] = []
        for candidate in [split.primary] + split.aliases + [name] {
            let key = CatalogNameParser.normalize(candidate)
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// 包含匹配：查询名与库里的名字一方包含另一方即可，
    /// 同分时优先资料更全的那条（作品数、出生、身高等）。
    private static func fuzzyActress(_ name: String) -> CatalogActressRecord? {
        let queries = lookupKeys(for: name).filter { $0.count >= 3 }
        guard !queries.isEmpty else { return nil }
        var best: (record: CatalogActressRecord, score: Int)?
        for (key, record) in actressIndex where key.count >= 3 {
            for query in queries {
                guard key.contains(query) || query.contains(key) else { continue }
                let score = min(key.count, query.count) * 10 + richness(record)
                if best == nil || score > (best?.score ?? .min) {
                    best = (record, score)
                }
            }
        }
        return best?.record
    }

    private static func fuzzyStudio(_ name: String) -> CatalogStudioRecord? {
        let queries = lookupKeys(for: name).filter { $0.count >= 2 }
        guard !queries.isEmpty else { return nil }
        var best: (record: CatalogStudioRecord, score: Int)?
        for (key, record) in studioIndex where key.count >= 2 {
            for query in queries {
                guard key.contains(query) || query.contains(key) else { continue }
                let score = min(key.count, query.count) * 10 + richness(record)
                if best == nil || score > (best?.score ?? .min) {
                    best = (record, score)
                }
            }
        }
        return best?.record
    }

    private static func richness(_ record: CatalogActressRecord) -> Int {
        var score = min(record.workCount ?? 0, 300) / 3
        if record.birthDate?.isEmpty == false { score += 20 }
        if record.heightCM != nil { score += 10 }
        if record.cup?.isEmpty == false { score += 6 }
        if record.summary?.isEmpty == false { score += 15 }
        score += record.aliases.count + record.tags.count
        return score
    }

    private static func richness(_ record: CatalogStudioRecord) -> Int {
        var score = min(record.workCount ?? 0, 300) / 3
        if record.summary?.isEmpty == false { score += 20 }
        if record.imageURL?.isEmpty == false { score += 6 }
        score += record.aliases.count
        return score
    }

    // MARK: - 读取

    private static let actresses: [CatalogActressRecord] = {
        guard let database = openDatabase() else { return [] }
        let rows = (try? database.query("""
            SELECT id, name, name_ja, name_en, aliases, region, birth_date, age,
                   age_asof, height_cm, bust, waist, hips, cup, work_count, tags,
                   summary, description, image_url, has_avatar, source_url, source
            FROM actresses
            ORDER BY COALESCE(work_count, -1) DESC, name
            """)) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.int64, let name = row["name"]?.string else { return nil }
            return CatalogActressRecord(
                id: id,
                name: name,
                nameJA: row["name_ja"]?.string,
                nameEN: row["name_en"]?.string,
                aliases: decodeArray(row["aliases"]?.string),
                region: row["region"]?.string ?? "japan",
                birthDate: row["birth_date"]?.string,
                age: row["age"]?.int,
                ageAsOf: row["age_asof"]?.string,
                heightCM: row["height_cm"]?.int,
                bust: row["bust"]?.int,
                waist: row["waist"]?.int,
                hips: row["hips"]?.int,
                cup: row["cup"]?.string,
                workCount: row["work_count"]?.int,
                tags: decodeArray(row["tags"]?.string),
                summary: row["summary"]?.string,
                description: row["description"]?.string,
                imageURL: row["image_url"]?.string,
                hasAvatar: row["has_avatar"]?.bool ?? false,
                sourceURL: row["source_url"]?.string,
                source: row["source"]?.string ?? ""
            )
        }
    }()

    private static let studios: [CatalogStudioRecord] = {
        guard let database = openDatabase() else { return [] }
        let rows = (try? database.query("""
            SELECT id, name, name_en, aliases, region, kind, work_count, summary,
                   logo_url, has_avatar, website, source_url, source
            FROM studios
            ORDER BY COALESCE(work_count, -1) DESC, name
            """)) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.int64, let name = row["name"]?.string else { return nil }
            return CatalogStudioRecord(
                id: id,
                name: name,
                nameEN: row["name_en"]?.string,
                aliases: decodeArray(row["aliases"]?.string),
                region: row["region"]?.string ?? "japan",
                kind: row["kind"]?.string ?? "studio",
                workCount: row["work_count"]?.int,
                summary: row["summary"]?.string,
                imageURL: row["logo_url"]?.string,
                hasAvatar: row["has_avatar"]?.bool ?? false,
                website: row["website"]?.string,
                sourceURL: row["source_url"]?.string,
                source: row["source"]?.string ?? ""
            )
        }
    }()

    private static let actressIndex: [String: CatalogActressRecord] = {
        var index: [String: CatalogActressRecord] = [:]
        for record in actresses {
            let names = [record.name] + record.aliases
                + [record.nameJA, record.nameEN].compactMap { $0 }
            for name in names {
                let key = CatalogNameParser.normalize(name)
                guard !key.isEmpty, index[key] == nil else { continue }
                index[key] = record
            }
        }
        return index
    }()

    private static let studioIndex: [String: CatalogStudioRecord] = {
        var index: [String: CatalogStudioRecord] = [:]
        for record in studios {
            let names = [record.name] + record.aliases + [record.nameEN].compactMap { $0 }
            for name in names {
                let key = CatalogNameParser.normalize(name)
                guard !key.isEmpty, index[key] == nil else { continue }
                index[key] = record
            }
        }
        return index
    }()

    /// 宽松索引：把资料库里的名字也去掉渠道后缀，站点那侧带 `AV / HD / PREMIUM` 也能落回来。
    /// 记录按作品数从多到少排列，同名冲突时优先资料更全的那条。
    private static let actressLooseIndex: [String: CatalogActressRecord] = {
        var index: [String: CatalogActressRecord] = [:]
        for record in actresses {
            let names = [record.name] + record.aliases
                + [record.nameJA, record.nameEN].compactMap { $0 }
            for name in names {
                guard let loose = looseKey(CatalogNameParser.normalize(name)),
                      index[loose] == nil else { continue }
                index[loose] = record
            }
        }
        return index
    }()

    private static let studioLooseIndex: [String: CatalogStudioRecord] = {
        var index: [String: CatalogStudioRecord] = [:]
        for record in studios {
            let names = [record.name] + record.aliases + [record.nameEN].compactMap { $0 }
            for name in names {
                guard let loose = looseKey(CatalogNameParser.normalize(name)),
                      index[loose] == nil else { continue }
                index[loose] = record
            }
        }
        return index
    }()

    private static func openDatabase() -> SQLiteDatabase? {
        for url in databaseCandidates() where FileManager.default.fileExists(atPath: url.path) {
            if let database = try? SQLiteDatabase(path: url.path, readonly: true, wal: false) {
                return database
            }
        }
        return nil
    }

    private static func databaseCandidates() -> [URL] {
        var urls: [URL] = []
        // 用户在菜单里加载的星图资料库：识别词典与星图共用同一份数据。
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

    private static func decodeArray(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func makePayload() -> Payload {
        var payload = Payload()
        for record in actresses {
            let names = [record.name] + record.aliases
            switch record.region {
            case "korea": payload.korean += names
            case "western": payload.western += names
            case "china", "taiwan", "hongkong": payload.chinese += names
            default: payload.japanese += names
            }
        }
        payload.studios = allStudioNames
        payload.codeMakers = codeMakers
        return payload
    }

    private static func makeCodeMakers() -> [String: String] {
        guard let database = openDatabase() else { return [:] }
        let rows = (try? database.query("SELECT prefix, studio_name FROM code_makers")) ?? []
        var makers: [String: String] = [:]
        for row in rows {
            guard let prefix = row["prefix"]?.string,
                  let studio = row["studio_name"]?.string else { continue }
            makers[prefix] = studio
        }
        return makers
    }
}

// MARK: - 记录

struct CatalogActressRecord: Identifiable, Hashable {
    var id: Int64
    var name: String
    var nameJA: String?
    var nameEN: String?
    var aliases: [String]
    var region: String
    var birthDate: String?
    var age: Int?
    var ageAsOf: String?
    var heightCM: Int?
    var bust: Int?
    var waist: Int?
    var hips: Int?
    var cup: String?
    var workCount: Int?
    var tags: [String]
    var summary: String?
    var description: String?
    var imageURL: String?
    /// 主表 `has_avatar` 标志：列表过滤用它，不必取大文本。
    var hasAvatar: Bool
    var sourceURL: String?
    var source: String

    /// 头像 base64：头像已拆到独立表 `person_avatars`，展示时按 id 单条取。
    var avatarBase64: String? {
        hasAvatar ? CatalogAvatarStore.personBase64(id) : nil
    }

    var regionTitle: String { CatalogRegion.title(for: region) }

    /// 福利姬 / 秀人 / 网红系模特，而不是 AV 女优。
    var isModel: Bool {
        tags.contains("福利姬") || tags.contains("秀人") || tags.contains("网红")
    }

    /// 「88-59-94」；三项都有才显示。
    var measurements: String? {
        guard let bust, let waist, let hips else { return nil }
        return "\(bust)-\(waist)-\(hips)"
    }

    var allNames: [String] { [name] + aliases }
}

struct CatalogStudioRecord: Identifiable, Hashable {
    var id: Int64
    var name: String
    var nameEN: String?
    var aliases: [String]
    var region: String
    /// 厂牌类型：studio（片商）/ photo（写真机构）/ platform（平台）。
    var kind: String
    var workCount: Int?
    var summary: String?
    var imageURL: String?
    /// 主表 `has_avatar` 标志：列表过滤用它，不必取大文本。
    var hasAvatar: Bool
    var website: String?
    var sourceURL: String?
    var source: String

    /// 头像 base64：头像已拆到独立表 `studio_avatars`，展示时按 id 单条取。
    var avatarBase64: String? {
        hasAvatar ? CatalogAvatarStore.studioBase64(id) : nil
    }

    var regionTitle: String { CatalogRegion.title(for: region) }

    var kindTitle: String {
        switch kind {
        case "photo": return "写真机构"
        case "platform": return "平台"
        default: return "片商"
        }
    }

    var allNames: [String] { [name] + aliases }
}

enum CatalogRegion {
    static func title(for region: String) -> String {
        switch region {
        case "japan": return "日本"
        case "korea": return "韩国"
        case "taiwan": return "台湾"
        case "hongkong": return "香港"
        case "china": return "中国大陆"
        case "western": return "欧美"
        default: return region
        }
    }
}
