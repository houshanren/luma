import Foundation

/// 地点详情「摘要」的派生数据：到访轨迹、四季、时段、地标、同框人物与高光照片。
/// 全部由当前地点的可见照片及其元数据在内存里计算，不落库、不上传。
public struct PlaceInsight {
    public struct YearCount: Identifiable, Equatable {
        public let year: Int
        public let count: Int
        public var id: Int { year }
        public init(
            year: Int,
            count: Int
        ) {
            self.year = year
            self.count = count
        }
    }

    public struct SeasonCount: Identifiable, Equatable {
        public let name: String
        public let count: Int
        public let fraction: Double
        public let symbol: String
        public var id: String { name }
        public init(
            name: String,
            count: Int,
            fraction: Double,
            symbol: String
        ) {
            self.name = name
            self.count = count
            self.fraction = fraction
            self.symbol = symbol
        }
    }

    public struct Spot: Identifiable, Equatable {
        public let name: String
        public let count: Int
        public var id: String { name }
        public init(
            name: String,
            count: Int
        ) {
            self.name = name
            self.count = count
        }
    }

    public struct PeriodSlice: Identifiable, Equatable {
        public let title: String
        public let count: Int
        public let fraction: Double
        public var id: String { title }
        public init(
            title: String,
            count: Int,
            fraction: Double
        ) {
            self.title = title
            self.count = count
            self.fraction = fraction
        }
    }

    public var title = ""
    public var province: String?
    public var group = ""
    public var latitude = 0.0
    public var longitude = 0.0
    public var photoCount = 0
    public var videoCount = 0
    public var firstDate: Date?
    public var lastDate: Date?
    public var years: [YearCount] = []
    public var seasons: [SeasonCount] = []
    public var periods: [PeriodSlice] = []
    /// 细化到景点 / 街道的地标统计。
    public var spots: [Spot] = []
    public var companions: [PhotoCompanion] = []
    public var highlights: [PhotoItem] = []
    public var palettePhotos: [PhotoItem] = []
    /// 每年四季张数（春、夏、秋、冬），用于「全部」页的年份条。
    public var yearSeasons: [Int: [Int]] = [:]

    public var totalCount: Int { photoCount + videoCount }
    public var visitYearCount: Int { years.count }

    public var activeSeason: SeasonCount? {
        seasons.max { $0.fraction < $1.fraction }
    }

    public var dominantPeriod: PeriodSlice? {
        periods.max { $0.fraction < $1.fraction }
    }

    public var coverPhoto: PhotoItem? {
        highlights.first { $0.aspectRatio >= 1.1 } ?? highlights.first
    }

    public var countText: String {
        var parts: [String] = []
        if photoCount > 0 { parts.append("\(photoCount.formatted()) 张照片") }
        if videoCount > 0 { parts.append("\(videoCount.formatted()) 个视频") }
        if parts.isEmpty { parts.append("0 张照片") }
        return parts.joined(separator: "、")
    }

    public var dateRangeText: String {
        guard let firstDate, let lastDate else { return "" }
        let first = DateText.monthFormatter.string(from: firstDate)
        let last = DateText.monthFormatter.string(from: lastDate)
        return first == last ? first : "\(first) – \(last)"
    }

    public var subtitle: String {
        var parts: [String] = []
        if let province, !province.isEmpty, province != title {
            parts.append(province)
        } else if !group.isEmpty {
            parts.append(group)
        }
        parts.append(countText)
        if !dateRangeText.isEmpty { parts.append(dateRangeText) }
        return parts.joined(separator: " · ")
    }

    public var coordinateText: String {
        let lat = String(format: "%.2f°%@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.2f°%@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat) · \(lon)"
    }

    /// 地点画像：只陈述能从照片里直接得出的事实。
    public var narrative: String {
        var parts: [String] = []
        if let firstDate, let lastDate, firstDate != lastDate {
            parts.append("\(DateText.monthFormatter.string(from: firstDate)) 第一次来到这里，最近一次是 \(DateText.monthFormatter.string(from: lastDate))")
        } else if totalCount > 0 {
            parts.append("在这里留下了 \(totalCount.formatted()) 个瞬间")
        }
        if visitYearCount > 1 {
            parts.append("\(visitYearCount) 个年份里共记录 \(totalCount.formatted()) 个瞬间")
        }
        if let season = activeSeason, season.fraction >= 0.35 {
            parts.append("最常出现在\(season.name)季（\(Int((season.fraction * 100).rounded()))%）")
        }
        if let period = dominantPeriod, period.fraction >= 0.35, period.title != "白天" {
            parts.append("镜头多落在\(period.title)")
        }
        if !spots.isEmpty {
            parts.append("常出现在 \(spots.prefix(2).map(\.name).joined(separator: "、"))")
        }
        if let companion = companions.first {
            parts.append("常与 \(companion.name) 同框")
        }
        guard !parts.isEmpty else { return "这里还没有足够的影像来描绘这段旅程。" }
        return parts.joined(separator: "；") + "。"
    }

    // MARK: - 从照片生成

    public static func make(place: PlaceCluster,
                     photos: [PhotoItem],
                     companions: [PhotoCompanion]) -> PlaceInsight {
        let sorted = photos
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt }
        var insight = PlaceInsight()
        insight.title = place.title
        insight.province = place.subtitle
        insight.group = place.group
        insight.latitude = place.latitude
        insight.longitude = place.longitude
        insight.photoCount = sorted.reduce(0) { $0 + ($1.isVideo ? 0 : 1) }
        insight.videoCount = sorted.count - insight.photoCount
        insight.firstDate = sorted.last?.capturedAt
        insight.lastDate = sorted.first?.capturedAt
        insight.companions = companions
        insight.highlights = PhotoInsightSamples.highlights(sorted)
        insight.palettePhotos = PhotoInsightSamples.paletteSamples(sorted, highlights: insight.highlights)
        insight.buildTimeline(sorted)
        return insight
    }

    private mutating func buildTimeline(_ photos: [PhotoItem]) {
        var yearCounts: [Int: Int] = [:]
        var yearSeasonCounts: [Int: [Int]] = [:]
        var seasonCounts = [Int](repeating: 0, count: 4)
        var hourCounts: [Int: Int] = [:]
        var spotCounts: [String: Int] = [:]
        let calendar = Calendar.current

        for photo in photos {
            let year = calendar.component(.year, from: photo.capturedAt)
            let month = calendar.component(.month, from: photo.capturedAt)
            let season = Self.seasonIndex(month: month)
            yearCounts[year, default: 0] += 1
            var mix = yearSeasonCounts[year] ?? [0, 0, 0, 0]
            mix[season] += 1
            yearSeasonCounts[year] = mix
            seasonCounts[season] += 1
            hourCounts[calendar.component(.hour, from: photo.capturedAt), default: 0] += 1
            if let poi = photo.placePOI?.trimmingCharacters(in: .whitespacesAndNewlines),
               !poi.isEmpty {
                spotCounts[poi, default: 0] += 1
            }
        }

        years = yearCounts
            .map { YearCount(year: $0.key, count: $0.value) }
            .sorted { $0.year < $1.year }
        yearSeasons = yearSeasonCounts
        spots = spotCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4)
            .map { Spot(name: $0.key, count: $0.value) }

        let total = max(1, photos.count)
        let names = ["春", "夏", "秋", "冬"]
        let symbols = ["leaf.fill", "sun.max.fill", "wind", "snowflake"]
        seasons = names.indices.map { index in
            SeasonCount(name: names[index],
                        count: seasonCounts[index],
                        fraction: Double(seasonCounts[index]) / Double(total),
                        symbol: symbols[index])
        }

        periods = Self.periods(fromHourCounts: hourCounts)
    }

    private static func seasonIndex(month: Int) -> Int {
        switch month {
        case 3...5: return 0
        case 6...8: return 1
        case 9...11: return 2
        default: return 3
        }
    }

    private static func periods(fromHourCounts counts: [Int: Int]) -> [PeriodSlice] {
        let titles = ["清晨", "白天", "傍晚", "夜晚"]
        var buckets = [Int](repeating: 0, count: titles.count)
        for (hour, count) in counts {
            switch hour {
            case 5..<9: buckets[0] += count
            case 9..<17: buckets[1] += count
            case 17..<20: buckets[2] += count
            default: buckets[3] += count
            }
        }
        let total = max(1, buckets.reduce(0, +))
        return titles.indices.map { index in
            PeriodSlice(title: titles[index],
                        count: buckets[index],
                        fraction: Double(buckets[index]) / Double(total))
        }
    }
    public init(
        title: String = "",
        province: String? = nil,
        group: String = "",
        latitude: Double = 0.0,
        longitude: Double = 0.0,
        photoCount: Int = 0,
        videoCount: Int = 0,
        firstDate: Date? = nil,
        lastDate: Date? = nil,
        years: [YearCount] = [],
        seasons: [SeasonCount] = [],
        periods: [PeriodSlice] = [],
        spots: [Spot] = [],
        companions: [PhotoCompanion] = [],
        highlights: [PhotoItem] = [],
        palettePhotos: [PhotoItem] = [],
        yearSeasons: [Int: [Int]] = [:]
    ) {
        self.title = title
        self.province = province
        self.group = group
        self.latitude = latitude
        self.longitude = longitude
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.years = years
        self.seasons = seasons
        self.periods = periods
        self.spots = spots
        self.companions = companions
        self.highlights = highlights
        self.palettePhotos = palettePhotos
        self.yearSeasons = yearSeasons
    }
}
