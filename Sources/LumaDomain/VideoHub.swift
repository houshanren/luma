import Foundation

/// 视频页的浏览视角：一屏一个维度，点卡片下钻由查看器承担。
package enum VideoHubDimension: String, CaseIterable, Identifiable {
    case featured
    case years
    case duration
    case places
    case people

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .featured: return "精选"
        case .years: return "年份"
        case .duration: return "时长"
        case .places: return "地点"
        case .people: return "人物"
        }
    }

    package var icon: String {
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
package enum VideoHubLayout: String, CaseIterable, Identifiable {
    case wall
    case timeline

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .wall: return "海报墙"
        case .timeline: return "时间轴"
        }
    }

    package var icon: String {
        switch self {
        case .wall: return "rectangle.grid.2x2"
        case .timeline: return "calendar.day.timeline.left"
        }
    }

    package var help: String {
        switch self {
        case .wall: return "按年份 / 地点 / 人物分组浏览"
        case .timeline: return "按拍摄日排列"
        }
    }
}

/// 时长分档：与「视角 › 时长」共用同一套边界。
package enum VideoDurationBand: String, CaseIterable, Identifiable {
    case instant
    case clip
    case story
    case long

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .instant: return "瞬间"
        case .clip: return "片段"
        case .story: return "故事"
        case .long: return "长镜头"
        }
    }

    package var detail: String {
        switch self {
        case .instant: return "少于 15 秒"
        case .clip: return "15 秒 – 1 分钟"
        case .story: return "1 – 5 分钟"
        case .long: return "5 分钟以上"
        }
    }

    package var range: Range<Double> {
        switch self {
        case .instant: return 0..<15
        case .clip: return 15..<60
        case .story: return 60..<300
        case .long: return 300..<Double.greatestFiniteMagnitude
        }
    }

    package func contains(_ duration: Double?) -> Bool {
        guard let duration else { return false }
        return range.contains(duration)
    }
}

/// 顶栏筛选：具体年份 + 具体时长档，与「视角」的分组互不冲突。
package struct VideoHubFilter: Equatable {
    package var year: Int?
    package var duration: VideoDurationBand?

    package var isActive: Bool { year != nil || duration != nil }

    /// 参与缓存指纹，避免同样的筛选反复重算。
    package var summary: String {
        var parts: [String] = []
        if let year { parts.append("y\(year)") }
        if let duration { parts.append("d\(duration.rawValue)") }
        return parts.joined(separator: "-")
    }
    package init(
        year: Int? = nil,
        duration: VideoDurationBand? = nil
    ) {
        self.year = year
        self.duration = duration
    }
}

package struct VideoGroup: Identifiable {
    package let id: String
    package let title: String
    package let detail: String
    package let videos: [PhotoItem]
    package init(
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
package struct VideoHubData {
    package var videos: [PhotoItem] = []
    package var recent: [PhotoItem] = []
    package var long: [PhotoItem] = []
    package var situations: [PhotoItem] = []
    package var years: [VideoGroup] = []
    package var durations: [VideoGroup] = []
    package var places: [VideoGroup] = []
    package var people: [VideoGroup] = []
    /// 时间轴布局按天分好的组：放在这里预生成，避免视图每次重绘都重新分组。
    package var days: [VideoGroup] = []
    package var availableYears: [Int] = []
    package var totalDuration: Double = 0
    /// 有有效时长的视频数，用于「平均时长」；避免每次重绘都扫一遍全部视频。
    package var durationSamples: Int = 0
    package var recentCount: Int = 0
    package var longest: PhotoItem?
    package init(
        videos: [PhotoItem] = [],
        recent: [PhotoItem] = [],
        long: [PhotoItem] = [],
        situations: [PhotoItem] = [],
        years: [VideoGroup] = [],
        durations: [VideoGroup] = [],
        places: [VideoGroup] = [],
        people: [VideoGroup] = [],
        days: [VideoGroup] = [],
        availableYears: [Int] = [],
        totalDuration: Double = 0,
        durationSamples: Int = 0,
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
        self.days = days
        self.availableYears = availableYears
        self.totalDuration = totalDuration
        self.durationSamples = durationSamples
        self.recentCount = recentCount
        self.longest = longest
    }
}

// MARK: - 展示文案

/// 卡片的副标题：日期 + 地点。视频文件名没有语义，不展示。
package func videoHubDatePlace(_ photo: PhotoItem) -> String {
    var parts = [DateText.dayFormatter.string(from: photo.capturedAt)]
    if let place = videoHubPlaceName(photo) {
        parts.append(place)
    }
    return parts.joined(separator: " · ")
}

/// 详细地点：优先 POI，其次城市 / 省份 / 国家。
package func videoHubPlaceName(_ photo: PhotoItem) -> String? {
    for value in [photo.placePOI, photo.placeCity, photo.placeProvince, photo.placeCountry] {
        if let value, !value.isEmpty { return value }
    }
    return nil
}

/// 首屏标题：用户改过标题就用标题；否则用媒体情境或时段，绝不再显示文件名。
package func videoHubHeadline(_ photo: PhotoItem) -> String {
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

package func videoHubTotalDurationText(_ videos: [PhotoItem]) -> String {
    let total = videos.compactMap(\.duration).reduce(0, +)
    return videoHubDurationText(total)
}

/// 秒数 → 「x 小时 y 分」：汇总结果里已经算好总秒数，视图不必再扫一遍全部视频。
package func videoHubDurationText(_ totalSeconds: Double) -> String {
    let total = Int(totalSeconds.rounded())
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

package func videoHubIsSituation(_ photo: PhotoItem) -> Bool {
    photo.isScreenRecording || photo.isSlowMotion || photo.isTimelapse
        || photo.isCinematic || photo.isSpatial
}

/// 时间轴布局：按天分组。放在 Domain 层预生成，视图每次重绘不必再分组 + 格式化日期。
package func makeVideoDayGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
    guard !videos.isEmpty else { return [] }
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: videos) {
        calendar.startOfDay(for: $0.capturedAt)
    }
    return grouped.keys.sorted(by: >).map { day in
        let items = (grouped[day] ?? []).sorted { $0.capturedAt > $1.capturedAt }
        return VideoGroup(id: "day-\(day.timeIntervalSince1970)",
                          title: VideoHubDayFormat.title.string(from: day),
                          detail: VideoHubDayFormat.weekday.string(from: day),
                          videos: items)
    }
}

private enum VideoHubDayFormat {
    static let title: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter
    }()
}
