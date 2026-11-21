import Foundation

/// 目录级 NFO（Kodi / tinyMediaManager / Jellyfin 通用）的最小解析。
/// 只取匹配与展示真正用得到的字段；图片路径按原样保留，本地文件不在这里读取。
struct CinemaNFO {
    var title: String?
    var originalTitle: String?
    var year: Int?
    var overview: String?
    /// 片长 / 单集时长，单位分钟。
    var runtime: Int?
    var rating: Double?
    var genres: [String] = []
    var tmdbID: Int?
    var isTV = false
    var season: Int?
    var episode: Int?
    var posterURL: String?
    var backdropURL: String?

    static func parse(data: Data) -> CinemaNFO? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1),
            !text.isEmpty else { return nil }

        var nfo = CinemaNFO()
        nfo.title = value("title", in: text)
        nfo.originalTitle = value("originaltitle", in: text)
        nfo.year = value("year", in: text).flatMap { Int($0.prefix(4)) }
        nfo.overview = value("plot", in: text) ?? value("outline", in: text)
        nfo.runtime = value("runtime", in: text).flatMap { Int($0.prefix(5)) }
        nfo.rating = value("rating", in: text).flatMap { Double($0) }
            ?? value("value", in: text).flatMap { Double($0) }
        nfo.genres = allValues("genre", in: text)
        nfo.season = value("season", in: text).flatMap { Int($0.prefix(4)) }
        nfo.episode = value("episode", in: text).flatMap { Int($0.prefix(4)) }
        nfo.tmdbID = uniqueID(type: "tmdb", in: text)
            ?? value("tmdbid", in: text).flatMap { Int($0.prefix(10)) }
        nfo.posterURL = value("poster", in: text)
            ?? value("thumb", in: text)
        nfo.backdropURL = fanartThumb(in: text)
        nfo.isTV = nfo.season != nil
            || nfo.episode != nil
            || text.range(of: "<tvshow", options: .caseInsensitive) != nil
            || text.range(of: "<episodedetails", options: .caseInsensitive) != nil

        // 标题都没有的 NFO 没有使用价值，交给网络刮削。
        guard let title = nfo.title, !title.isEmpty else { return nil }
        nfo.title = title
        return nfo
    }

    private static func value(_ tag: String, in text: String) -> String? {
        let pattern = "<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return clean(String(text[valueRange]))
    }

    private static func allValues(_ tag: String, in text: String) -> [String] {
        let pattern = "<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            let value = clean(String(text[valueRange]))
            return value.isEmpty ? nil : value
        }
    }

    private static func uniqueID(type: String, in text: String) -> Int? {
        let pattern = "<uniqueid[^>]*type=[\"']\(type)[\"'][^>]*>(.*?)</uniqueid>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(clean(String(text[valueRange])).prefix(10))
    }

    /// `<fanart><thumb>…</thumb></fanart>` 里的第一张背景图。
    private static func fanartThumb(in text: String) -> String? {
        guard let block = value("fanart", in: text) else { return nil }
        return value("thumb", in: block)
    }

    /// 去掉 NFO 里常见的 CDATA / HTML 实体与首尾空白。
    private static func clean(_ raw: String) -> String {
        var value = raw
        value = value.replacingOccurrences(of: "<![CDATA[", with: "")
        value = value.replacingOccurrences(of: "]]>", with: "")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&apos;", with: "'")
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
