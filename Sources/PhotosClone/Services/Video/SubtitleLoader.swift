import Foundation

/// 一条字幕：按完整播放时间轴记录起止秒数。
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// 外挂字幕加载：srt / vtt / ass / ssa。
/// 只做文本渲染，不处理样式与定位（ASS 的复杂排版会被压成纯文本）。
enum SubtitleLoader {
    static let supportedExtensions = ["srt", "vtt", "ass", "ssa"]

    static func load(url: URL) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = decode(data)
        switch url.pathExtension.lowercased() {
        case "ass", "ssa":
            return parseASS(text)
        case "vtt":
            return parseSRT(text)
        default:
            return parseSRT(text)
        }
    }

    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        // 二分查找：大文件字幕可能有上万条。
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if time < cue.start {
                high = mid - 1
            } else if time > cue.end {
                low = mid + 1
            } else {
                return cue
            }
        }
        return nil
    }

    /// 同目录同名的外挂字幕：movie.mkv → movie.srt / movie.zh.srt。
    /// 图库的 originals 分片目录可能有几万个文件，逐个构造 URL 枚举会卡住调用线程：
    /// 先按精确同名做 4 次 stat，实在没有再退回字符串枚举。
    static func discoverSibling(of videoURL: URL) -> URL? {
        guard videoURL.isFileURL else { return nil }
        // 图库里（originals / renders）的文件不会带外挂字幕：一个分片目录可能有几万个文件，
        // 直接跳过整目录扫描，否则打开本地视频会卡住好几秒。
        if videoURL.path.hasPrefix(LibraryPaths.root.path + "/") { return nil }
        let directory = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        for ext in supportedExtensions {
            let exact = directory.appendingPathComponent("\(base).\(ext)", isDirectory: false)
            if fm.fileExists(atPath: exact.path) { return exact }
        }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        var matches: [String] = []
        matches.reserveCapacity(2)
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let stem = (name as NSString).deletingPathExtension
            guard stem.hasPrefix(base) else { continue }
            matches.append(name)
        }
        // 同名（movie.srt）优先，其次按语言后缀的字母序。
        guard let best = matches.min(by: { $0.count < $1.count }) else { return nil }
        return directory.appendingPathComponent(best)
    }

    // MARK: - 解析

    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timeIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = parseTime(times[0]),
                  let end = parseTime(times[1]) else { continue }
            let body = lines[(timeIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = stripTags(body)
            guard !cleaned.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            // Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let body = line.dropFirst("dialogue:".count)
            let fields = body.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count >= 10,
                  let start = parseTime(String(fields[1])),
                  let end = parseTime(String(fields[2])) else { continue }
            var content = String(fields[9])
            content = content.replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            var cleaned = content
            while let range = cleaned.range(of: "\\{[^}]*\\}", options: .regularExpression) {
                cleaned.removeSubrange(range)
            }
            cleaned = stripTags(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// 支持 `00:00:01,000`、`00:00:01.000` 与 ASS 的 `0:00:01.00`。
    private static func parseTime(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let head = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
        let parts = head.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var seconds: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        // 上面的循环按“时:分:秒”累乘，parts 为 2 段时等同于“分:秒”。
        return seconds.isFinite ? seconds : nil
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        // 中文外挂字幕常见 GB18030 编码。
        let gb18030 = String.Encoding(rawValue: 0x80000632)
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
