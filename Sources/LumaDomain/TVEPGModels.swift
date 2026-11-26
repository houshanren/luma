import Foundation

/// 一条 XMLTV 节目。`channelID` 对应 XMLTV 的 `<programme channel="…">`，
/// 播放层再用频道的 `tvgID` / 台名映射过去。
public struct TVEPGProgram: Identifiable, Hashable, Codable {
    public var id: String
    public var channelID: String
    public var title: String
    public var subtitle: String?
    public var overview: String?
    public var start: Date
    public var end: Date

    public var isLive: Bool {
        let now = Date()
        return start <= now && end > now
    }

    public var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }
    public init(
        id: String,
        channelID: String,
        title: String,
        subtitle: String? = nil,
        overview: String? = nil,
        start: Date,
        end: Date
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.start = start
        self.end = end
    }
}

/// 一次 XMLTV 拉取的结果：节目 + 频道别名表（用于没有 `tvg-id` 的源按台名映射）。
public struct TVEPGData {
    public var programs: [TVEPGProgram]
    /// XMLTV channel id -> display names。
    public var channelNames: [String: [String]]
    public init(
        programs: [TVEPGProgram],
        channelNames: [String: [String]]
    ) {
        self.programs = programs
        self.channelNames = channelNames
    }
}
