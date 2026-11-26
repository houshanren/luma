import Foundation

/// 视频页的浏览视角：一屏一个维度，点卡片下钻由查看器承担。
public enum VideoHubDimension: String, CaseIterable, Identifiable {
    case featured
    case years
    case duration
    case places
    case people

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .featured: return "精选"
        case .years: return "年份"
        case .duration: return "时长"
        case .places: return "地点"
        case .people: return "人物"
        }
    }

    public var icon: String {
        switch self {
        case .featured: return "sparkles"
        case .years: return "calendar"
        case .duration: return "timer"
        case .places: return "mappin.and.ellipse"
        case .people: return "person.2"
        }
    }
}

/// 视频页的排列方式：海报墙用于挑选，时间轴用于回忆。
public enum VideoHubLayout: String, CaseIterable, Identifiable {
    case wall
    case timeline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wall: return "海报墙"
        case .timeline: return "时间轴"
        }
    }

    public var icon: String {
        switch self {
        case .wall: return "rectangle.grid.2x2"
        case .timeline: return "calendar.day.timeline.left"
        }
    }

    public var help: String {
        switch self {
        case .wall: return "按年份 / 地点 / 人物分组浏览"
        case .timeline: return "按拍摄日排列"
        }
    }
}

/// 时长分档：与「视角 › 时长」共用同一套边界。
public enum VideoDurationBand: String, CaseIterable, Identifiable {
    case instant
    case clip
    case story
    case long

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .instant: return "瞬间"
        case .clip: return "片段"
        case .story: return "故事"
        case .long: return "长镜头"
        }
    }

    public var detail: String {
        switch self {
        case .instant: return "少于 15 秒"
        case .clip: return "15 秒 – 1 分钟"
        case .story: return "1 – 5 分钟"
        case .long: return "5 分钟以上"
        }
    }

    public var range: Range<Double> {
        switch self {
        case .instant: return 0..<15
        case .clip: return 15..<60
        case .story: return 60..<300
        case .long: return 300..<Double.greatestFiniteMagnitude
        }
    }

    public func contains(_ duration: Double?) -> Bool {
        guard let duration else { return false }
        return range.contains(duration)
    }
}

/// 顶栏筛选：具体年份 + 具体时长档，与「视角」的分组互不冲突。
public struct VideoHubFilter: Equatable {
    public var year: Int?
    public var duration: VideoDurationBand?

    public var isActive: Bool { year != nil || duration != nil }

    /// 参与缓存指纹，避免同样的筛选反复重算。
    public var summary: String {
        var parts: [String] = []
        if let year { parts.append("y\(year)") }
        if let duration { parts.append("d\(duration.rawValue)") }
        return parts.joined(separator: "-")
    }
    public init(
        year: Int? = nil,
        duration: VideoDurationBand? = nil
    ) {
        self.year = year
        self.duration = duration
    }
}

public struct VideoGroup: Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let videos: [PhotoItem]
    public init(
        id: String,
        title: String,
        detail: String,
        videos: [PhotoItem]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.videos = videos
    }
}

/// 视频页的派生结果：只由 Store 生成，视图读取展示。
public struct VideoHubData {
    public var videos: [PhotoItem] = []
    public var recent: [PhotoItem] = []
    public var long: [PhotoItem] = []
    public var situations: [PhotoItem] = []
    public var years: [VideoGroup] = []
    public var durations: [VideoGroup] = []
    public var places: [VideoGroup] = []
    public var people: [VideoGroup] = []
    public var availableYears: [Int] = []
    public var totalDuration: Double = 0
    public var recentCount: Int = 0
    public var longest: PhotoItem?
    public init(
        videos: [PhotoItem] = [],
        recent: [PhotoItem] = [],
        long: [PhotoItem] = [],
        situations: [PhotoItem] = [],
        years: [VideoGroup] = [],
        durations: [VideoGroup] = [],
        places: [VideoGroup] = [],
        people: [VideoGroup] = [],
        availableYears: [Int] = [],
        totalDuration: Double = 0,
        recentCount: Int = 0,
        longest: PhotoItem? = nil
    ) {
        self.videos = videos
        self.recent = recent
        self.long = long
        self.situations = situations
        self.years = years
        self.durations = durations
        self.places = places
        self.people = people
        self.availableYears = availableYears
        self.totalDuration = totalDuration
        self.recentCount = recentCount
        self.longest = longest
    }
}

// MARK: - 展示文案

/// 卡片的副标题：日期 + 地点。视频文件名没有语义，不展示。
public func videoHubDatePlace(_ photo: PhotoItem) -> String {
    var parts = [DateText.dayFormatter.string(from: photo.capturedAt)]
    if let place = videoHubPlaceName(photo) {
        parts.append(place)
    }
    return parts.joined(separator: " · ")
}

/// 详细地点：优先 POI，其次城市 / 省份 / 国家。
public func videoHubPlaceName(_ photo: PhotoItem) -> String? {
    for value in [photo.placePOI, photo.placeCity, photo.placeProvince, photo.placeCountry] {
        if let value, !value.isEmpty { return value }
    }
    return nil
}

/// 首屏标题：用户改过标题就用标题；否则用媒体情境或时段，绝不再显示文件名。
public func videoHubHeadline(_ photo: PhotoItem) -> String {
    if let title = photo.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty {
        return title
    }
    if photo.isScreenRecording { return "屏幕录制" }
    if photo.isSlowMotion { return "慢动作" }
    if photo.isTimelapse { return "延时摄影" }
    if photo.isCinematic { return "电影效果" }
    if photo.isSpatial { return "空间视频" }
    for value in [photo.placeCity, photo.placeProvince, photo.placeCountry] {
        if let value, !value.isEmpty { return "\(value)的片段" }
    }
    let hour = Calendar.current.component(.hour, from: photo.capturedAt)
    switch hour {
    case 5..<9: return "清晨的片段"
    case 9..<12: return "上午的片段"
    case 12..<17: return "午后的片段"
    case 17..<20: return "傍晚的影像"
    default: return "夜晚的记录"
    }
}

public func videoHubTotalDurationText(_ videos: [PhotoItem]) -> String {
    let total = Int(videos.compactMap(\.duration).reduce(0, +).rounded())
    guard total > 0 else { return "时长未知" }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 {
        return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时"
    }
    if minutes > 0 {
        return "\(minutes) 分钟"
    }
    return "\(total) 秒"
}

public func videoHubIsSituation(_ photo: PhotoItem) -> Bool {
    photo.isScreenRecording || photo.isSlowMotion || photo.isTimelapse
        || photo.isCinematic || photo.isSpatial
}
