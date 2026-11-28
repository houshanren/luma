import Foundation

/// 从番号与标题里识别「厂商 / 女优」。
///
/// 站点详情页经常漏字段，但标题里其实已经写着了（例如「JUR-348 麦当娜獨家二週年紀念 衝宫奈美 捆绑解放」）。
/// 识别分三层：
/// 1. 番号：`JUR-355` / `ssni00111` / `FC2-PPV-1234567`，用前缀查厂商表（S1 / MOODYZ / Madonna…）。
/// 2. 词典：内置常见女优名 + 从已解析详情 / 关注 / 档案里学到的名字，做归一化后的最长匹配
///    （繁体 → 简体、去空格标点、大小写不敏感），同一人换写法也能命中。
/// 3. 标记：`主演：X` / `女優：X` 这类显式字段兜底。
enum CatalogNameParser {
    struct Result {
        var code: String?
        /// 番号前缀（JUR / SSIS…）。
        var label: String?
        /// 识别到的厂牌：番号前缀得出的排前面，标题里的品牌排后面。
        var makers: [String] = []
        var actresses: [String] = []
        /// 女优来自词典匹配（比标记猜测更可信）。
        var matchedByDictionary = false
        var isEmpty: Bool {
            code == nil && makers.isEmpty && actresses.isEmpty
        }
    }

    // MARK: 词典

    private static let dictionaryKey = "catalog.actress.names.v1"

    private static func learnedNames() -> [String] {
        guard let data = CatalogStore.data(forKey: dictionaryKey),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    /// 内置资料库（Resources/Catalog/catalog.sqlite）里的名字，按长度降序只排一次；
    /// 学习到的名字数量少，直接追加在后面。
    private static let sortedDictionaryNames: [String] = CatalogNameDictionary.payload.actresses
        .sorted { $0.count > $1.count }

    /// 词典项：名字的归一化结果只算一次。
    /// 以前每个标题都要把上万条名字重新归一化（折叠 + 繁简 + 逐字符过滤），
    /// 打开详情页时会把主线程卡住几百毫秒。
    private struct NameEntry {
        let name: String
        let key: String
        let latin: Bool
    }

    private static func makeEntry(_ name: String) -> NameEntry? {
        let key = normalize(name)
        guard key.count >= 2, key.count <= 24 else { return nil }
        return NameEntry(name: name, key: key, latin: isLatin(name))
    }

    private static let dictionaryEntries: [NameEntry] = sortedDictionaryNames.compactMap(makeEntry)

    /// 学习到的名字：条目缓存到下一次 `learn` 为止，不在每次解析里重读数据库。
    private static let learnedEntryLock = NSLock()
    private static var learnedEntryCache: [NameEntry]?
    /// 学习写库的串行锁：详情 / 关注 / 档案可能同时从后台线程写入。
    private static let learnLock = NSLock()

    private static func learnedEntries() -> [NameEntry] {
        learnedEntryLock.lock()
        if let cached = learnedEntryCache {
            learnedEntryLock.unlock()
            return cached
        }
        learnedEntryLock.unlock()
        let built = learnedNames().compactMap(makeEntry)
        learnedEntryLock.lock()
        learnedEntryCache = built
        learnedEntryLock.unlock()
        return built
    }

    private struct StudioMatcher {
        let name: String
        /// 归一化后的名字，中文厂牌直接做子串匹配。
        let key: String
        /// 拉丁厂牌的词边界正则；中文厂牌为 nil。
        let latin: NSRegularExpression?
    }

    /// 厂牌匹配器只构建一次：以前每个标题都要把几百个厂牌重新归一化 + 编译正则，
    /// 列表页批量补元数据时会明显拖慢解析。
    private static let studioMatchers: [StudioMatcher] = {
        var seen = Set<String>()
        var result: [StudioMatcher] = []
        for name in CatalogNameDictionary.payload.studios {
            let key = normalize(name)
            guard key.count >= 2, seen.insert(key).inserted else { continue }
            if isLatin(name) {
                guard name.count >= 3,
                      let regex = try? NSRegularExpression(
                        pattern: "(?i)(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9])")
                else { continue }
                result.append(StudioMatcher(name: name, key: key, latin: regex))
            } else {
                result.append(StudioMatcher(name: name, key: key, latin: nil))
            }
        }
        return result
    }()

    // MARK: - 轻量标题元数据

    /// 列表页的轻量元数据：只从标题里取番号与厂牌，不扫女优词典。
    struct TitleMetadata {
        var code: String?
        var maker: String?

        var isEmpty: Bool { code == nil && maker == nil }

        /// 直接用作卡片备注，例如「TMW-104 · 天美传媒」。
        var remark: String {
            [code, maker].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private static let metadataLock = NSLock()
    private static var metadataCache: [String: TitleMetadata] = [:]

    /// 站点只给标题时，用番号 / 厂牌补一条卡片备注；结果按标题缓存，滚动回来不重复算。
    static func titleMetadata(_ title: String) -> TitleMetadata {
        guard !title.isEmpty else { return TitleMetadata() }

        metadataLock.lock()
        if let cached = metadataCache[title] {
            metadataLock.unlock()
            return cached
        }
        metadataLock.unlock()

        var meta = TitleMetadata()
        if let code = extractCode(title) { meta.code = code.text }
        meta.maker = matchStudios(in: title).first

        metadataLock.lock()
        if metadataCache.count >= 512 { metadataCache.removeAll() }
        metadataCache[title] = meta
        metadataLock.unlock()
        return meta
    }

    /// 学到新名字（来自详情字段 / 关注 / 档案），下次标题里就能直接点亮。
    static func learn(names: [String]) {
        // 详情解析、关注页、档案页都可能从后台线程学习：串行写入，避免互相覆盖。
        learnLock.lock()
        defer { learnLock.unlock() }
        var current = Set(learnedNames())
        var changed = false
        for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where isValidName(name) {
            if current.insert(name).inserted { changed = true }
        }
        guard changed else { return }
        if let data = try? JSONEncoder().encode(Array(current)) {
            CatalogStore.set(data, forKey: dictionaryKey)
        }
        // 词典变了：条目缓存与解析结果都要作废，否则新名字要等重启才会被认出来。
        learnedEntryLock.lock()
        learnedEntryCache = nil
        learnedEntryLock.unlock()
        parseCacheLock.lock()
        parseCache.removeAll(keepingCapacity: true)
        parseCacheLock.unlock()
    }

    /// 后台预热：把姓名条目、厂牌匹配器、资料库索引提前建好。
    /// 启动后跑一次，详情页首次识别时不再付读库 / 建索引的成本。
    static func prewarm() {
        CatalogNameDictionary.prewarm()
        _ = dictionaryEntries
        _ = studioMatchers
        _ = learnedEntries()
    }

    /// 从详情页已解析的字段里学女优名，供给标题识别使用。
    static func learn(from detail: CatalogDetail) {
        learn(names: learnableNames(from: detail))
    }

    /// 只做字符串提取，不读写词典：调用方可以拿到后台线程再 `learn(names:)`。
    static func learnableNames(from detail: CatalogDetail) -> [String] {
        var names: [String] = []
        for fact in detail.facts {
            let label = fact.label.lowercased()
            let isActress = ["女优", "女優", "演员", "演員", "actress", "cast", "出演"]
                .contains { label.contains($0) }
            guard isActress else { continue }
            names.append(contentsOf: splitNames(fact.value))
        }
        return names
    }

    // MARK: 解析

    /// 解析结果按标题缓存：详情页正文 / 标题会随滚动反复求值，
    /// 以前每一帧都重扫一遍上万条词典，是打开图集时「整页卡住」的主因。
    private static let parseCacheLock = NSLock()
    private static var parseCache: [String: Result] = [:]

    static func parse(title: String) -> Result {
        guard !title.isEmpty else { return Result() }
        parseCacheLock.lock()
        if let cached = parseCache[title] {
            parseCacheLock.unlock()
            return cached
        }
        parseCacheLock.unlock()

        let result = parseUncached(title: title)

        parseCacheLock.lock()
        if parseCache.count >= 256 { parseCache.removeAll(keepingCapacity: true) }
        parseCache[title] = result
        parseCacheLock.unlock()
        return result
    }

    private static func parseUncached(title: String) -> Result {
        var result = Result()
        if let code = extractCode(title) {
            result.code = code.text
            result.label = code.label
            if let maker = CatalogNameDictionary.codeMakers[code.label] {
                result.makers.append(maker)
            }
        }
        for studio in matchStudios(in: title) where !result.makers.contains(studio) {
            result.makers.append(studio)
        }
        let dictionaryHits = matchNames(in: title)
        if !dictionaryHits.isEmpty {
            result.actresses = dictionaryHits
            result.matchedByDictionary = true
        } else {
            result.actresses = markerNames(in: title)
        }
        return result
    }

    // MARK: 厂牌

    /// 标题里的厂牌：中文品牌按子串匹配；拉丁厂牌按词边界匹配，避免 SOD 命中 SODA。
    private static func matchStudios(in text: String) -> [String] {
        let haystack = normalize(text)
        guard !haystack.isEmpty else { return [] }
        var found: [String] = []
        for matcher in studioMatchers {
            if let latin = matcher.latin {
                guard latin.firstMatch(in: text,
                                       range: NSRange(text.startIndex..., in: text)) != nil
                else { continue }
            } else if !haystack.contains(matcher.key) {
                continue
            }
            if !found.contains(matcher.name) { found.append(matcher.name) }
        }
        return found
    }

    private static func isLatin(_ value: String) -> Bool {
        value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "-") }
            && value.contains { $0.isASCII && $0.isLetter }
    }

    // MARK: 番号解析

    private static func extractCode(_ title: String) -> (text: String, label: String)? {
        // FC2 单独处理：FC2-PPV-1234567。
        if let range = title.range(of: "(?i)FC2[-_ ]?PPV[-_ ]?\\d{6,8}", options: .regularExpression) {
            let text = String(title[range]).uppercased()
            return (text, "FC2")
        }
        let pattern = "(?i)(?<![A-Z0-9])([A-Z]{2,6})[-_ ]?(\\d{2,5})(?!\\d)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let labelRange = Range(match.range(at: 1), in: title),
              let numberRange = Range(match.range(at: 2), in: title)
        else { return nil }
        let label = String(title[labelRange]).uppercased()
        let number = String(title[numberRange])
        return ("\(label)-\(number)", label)
    }

    // MARK: 女优名匹配

    private static func matchNames(in text: String) -> [String] {
        let haystack = normalize(text)
        guard !haystack.isEmpty else { return [] }
        let ns = haystack as NSString
        // 词典上万条，先用标题里实际出现过的字符做一次 O(1) 过滤，再做整串查找。
        var present = Set<unichar>()
        for index in 0..<ns.length { present.insert(ns.character(at: index)) }
        var occupied: [NSRange] = []
        var found: [String] = []

        func scan(_ entries: [NameEntry]) {
            for entry in entries {
                guard let first = entry.key.utf16.first, present.contains(first) else { continue }
                var search = NSRange(location: 0, length: ns.length)
                while search.length > 0 {
                    let hit = ns.range(of: entry.key, options: [], range: search)
                    if hit.location == NSNotFound { break }
                    let overlaps = occupied.contains { NSIntersectionRange($0, hit).length > 0 }
                    // 拉丁艺名要求词边界，避免 AKI 命中 MAKINO 这类误判。
                    if !overlaps, !entry.latin || hasWordBoundary(hit, in: ns) {
                        occupied.append(hit)
                        if !found.contains(entry.name) { found.append(entry.name) }
                    }
                    let next = hit.location + max(1, hit.length)
                    guard next < ns.length else { break }
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
        }

        scan(dictionaryEntries)
        scan(learnedEntries())
        return found
    }

    private static func hasWordBoundary(_ range: NSRange, in ns: NSString) -> Bool {
        func isAsciiAlnum(_ unit: unichar?) -> Bool {
            guard let unit else { return false }
            return (unit >= 48 && unit <= 57)      // 0-9
                || (unit >= 65 && unit <= 90)      // A-Z
                || (unit >= 97 && unit <= 122)     // a-z
        }
        let before = range.location > 0 ? ns.character(at: range.location - 1) : nil
        let afterLocation = range.location + range.length
        let after = afterLocation < ns.length ? ns.character(at: afterLocation) : nil
        return !isAsciiAlnum(before) && !isAsciiAlnum(after)
    }

    private static let markerWords = ["主演", "女優", "女优", "演出", "出演"]

    private static func markerNames(in text: String) -> [String] {
        var results: [String] = []
        for marker in markerWords {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: marker, range: searchRange) {
                var rest = text[found.upperBound...]
                while let first = rest.first,
                      first == ":" || first == "：" || first.isWhitespace || first == "・" {
                    rest = rest.dropFirst()
                }
                let candidate = String(rest.prefix { $0.isLetter })
                if isValidName(candidate), !results.contains(candidate) {
                    results.append(candidate)
                }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return results
    }

    private static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 12 else { return false }
        // 名字里不该出现数字 / 拉丁字母 / 常见描述词。
        let banned = ["主演", "女优", "女優", "出演", "作品", "全集", "合集", "无码", "無碼", "中字", "字幕"]
        if banned.contains(where: { trimmed.contains($0) }) { return false }
        return trimmed.allSatisfy { $0.isLetter || $0 == "・" || $0 == "·" }
    }

    private static func splitNames(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "、,，/|·・"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValidName($0) }
    }

    /// 归一化：全角 / 大小写不敏感 + 繁体转简体 + 展开叠字符 + 去空格标点。
    /// 同一个女优在繁简站点里的写法不同，不归一化就会漏。
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        let simplified = folded.applyingTransform(StringTransform("Traditional-Simplified"),
                                                  reverse: false) ?? folded
        let expanded = expandRepetitionMarks(simplified)
        return String(expanded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
    }

    /// 日文叠字符展开：菜々子 → 菜菜子、佐々木 → 佐佐木。
    /// 中文站点常写叠字，不展开「々」就永远匹配不上。
    private static func expandRepetitionMarks(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var previous: Character?
        for character in text {
            if "々ゝゞヽヾ".contains(character) {
                if let previous { result.append(previous) }
            } else {
                result.append(character)
                if !character.isWhitespace { previous = character }
            }
        }
        return result
    }

    /// 把「高宫菜菜子 (高宫菜々子)」拆成主名与括号里的别名。
    /// 关注、搜索、资料库匹配都只拿主名去查，避免括号把整串名字带歪。
    static func splitAliases(_ raw: String) -> (primary: String, aliases: [String]) {
        var primary = ""
        var aliases: [String] = []
        var buffer = ""
        var depth = 0
        for character in raw {
            switch character {
            case "（", "(", "【", "[", "《":
                if depth == 0 { buffer = "" }
                depth += 1
            case "）", ")", "】", "]", "》":
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        let alias = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !alias.isEmpty { aliases.append(alias) }
                        buffer = ""
                    }
                }
            default:
                if depth > 0 { buffer.append(character) } else { primary.append(character) }
            }
        }
        if depth > 0 {
            let alias = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty { aliases.append(alias) }
        }
        let trimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed,
                aliases)
    }
}
