import Foundation
import CoreGraphics
import LumaDomain

/// 回忆影片的风格模板：控制 Ken Burns 的方向、幅度与画面比例。
package enum MemoryStyle: String, CaseIterable, Identifiable, Hashable {
    case classic
    case cinematic
    case fresh

    package var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "经典"
        case .cinematic: return "电影"
        case .fresh: return "清新"
        }
    }

    var icon: String {
        switch self {
        case .classic: return "photo.on.rectangle"
        case .cinematic: return "film"
        case .fresh: return "sun.max"
        }
    }

    /// 起始 / 结束缩放（Ken Burns）。
    var zoomRange: (start: CGFloat, end: CGFloat) {
        switch self {
        case .classic: return (1.0, 1.12)
        case .cinematic: return (1.16, 1.02)
        case .fresh: return (1.02, 1.07)
        }
    }

    /// 平移幅度（相对画面宽度的比例）。
    var panAmount: CGFloat {
        switch self {
        case .classic: return 0.02
        case .cinematic: return 0.04
        case .fresh: return 0.012
        }
    }

    /// 电影风格增加上下黑边。
    var showsLetterbox: Bool { self == .cinematic }
}

/// 自动生成的回忆影片。
package struct PhotoMemory: Identifiable, Hashable {
    package enum Kind: String, Hashable {
        case month
        case place
        case favorites
        case throwback
    }

    package let id: String
    package let title: String
    package let subtitle: String
    package let kind: Kind
    package let photos: [PhotoItem]
    package var style: MemoryStyle

    package init(id: String,
                 title: String,
                 subtitle: String,
                 kind: Kind,
                 photos: [PhotoItem],
                 style: MemoryStyle = .classic) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.photos = photos
        self.style = style
    }
}

package enum MemoryBuilder {
    package static func build(from photos: [PhotoItem], limit: Int = 10) -> [PhotoMemory] {
        let candidates = photos.filter { $0.deletedAt == nil && !$0.isHidden && !$0.isVideo }
        guard candidates.count >= 12 else { return [] }

        let calendar = Calendar.current
        var memories: [PhotoMemory] = []

        // 1. 按月：每个月至少 12 张照片。
        var byMonth: [String: [PhotoItem]] = [:]
        for photo in candidates {
            let comps = calendar.dateComponents([.year, .month], from: photo.capturedAt)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            byMonth[key, default: []].append(photo)
        }
        for (key, items) in byMonth where items.count >= 12 {
            let sorted = items.sorted { $0.capturedAt < $1.capturedAt }
            let coverDate = sorted.first?.capturedAt ?? Date()
            memories.append(PhotoMemory(id: "month-" + key,
                                        title: monthTitle(coverDate),
                                        subtitle: "\(items.count) 张照片",
                                        kind: .month,
                                        photos: evenlySample(sorted, limit: 30)))
        }

        // 2. 按地点：同一城市至少 15 张。
        var byPlace: [String: [PhotoItem]] = [:]
        for photo in candidates {
            guard let city = photo.placeCity ?? photo.placeProvince, !city.isEmpty else { continue }
            byPlace[city, default: []].append(photo)
        }
        for (city, items) in byPlace where items.count >= 15 {
            let sorted = items.sorted { $0.capturedAt < $1.capturedAt }
            memories.append(PhotoMemory(id: "place-" + city,
                                        title: city,
                                        subtitle: "\(items.count) 张照片",
                                        kind: .place,
                                        photos: evenlySample(sorted, limit: 24)))
        }

        // 3. 个人收藏。
        let favorites = candidates.filter { $0.isFavorite }
        if favorites.count >= 10 {
            let sorted = favorites.sorted { $0.capturedAt > $1.capturedAt }
            memories.append(PhotoMemory(id: "favorites",
                                        title: "个人收藏",
                                        subtitle: "\(favorites.count) 张照片",
                                        kind: .favorites,
                                        photos: evenlySample(sorted, limit: 24)))
        }

        // 4. 往年今日：按年分组，每个有照片的年份各生成一条回忆（最多取最近 3 年）。
        let today = calendar.dateComponents([.month, .day, .year], from: Date())
        var throwbackByYear: [Int: [PhotoItem]] = [:]
        for photo in candidates {
            let comps = calendar.dateComponents([.month, .day, .year], from: photo.capturedAt)
            guard comps.month == today.month, comps.day == today.day,
                  let year = comps.year, year != today.year else { continue }
            throwbackByYear[year, default: []].append(photo)
        }
        for (year, items) in throwbackByYear.sorted(by: { $0.key > $1.key }).prefix(3) {
            let yearsAgo = max(1, (today.year ?? year) - year)
            let sorted = items.sorted { $0.capturedAt > $1.capturedAt }
            memories.append(PhotoMemory(id: "throwback-\(year)",
                                        title: yearsAgo == 1 ? "去年的今天" : "\(yearsAgo) 年前的今天",
                                        subtitle: "\(items.count) 张照片",
                                        kind: .throwback,
                                        photos: evenlySample(sorted, limit: 20),
                                        style: .cinematic))
        }

        // 往年今日置顶，其余按时间从新到旧。
        let ordered = memories.sorted { lhs, rhs in
            if (lhs.kind == .throwback) != (rhs.kind == .throwback) {
                return lhs.kind == .throwback
            }
            return (lhs.photos.first?.capturedAt ?? .distantPast) > (rhs.photos.first?.capturedAt ?? .distantPast)
        }
        return Array(ordered.prefix(limit))
    }

    private static func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }

    /// 在保持时间顺序的前提下均匀取样，避免回忆过长。
    private static func evenlySample(_ items: [PhotoItem], limit: Int) -> [PhotoItem] {
        guard items.count > limit, limit > 1 else { return items }
        let step = Double(items.count - 1) / Double(limit - 1)
        var result: [PhotoItem] = []
        for index in 0..<limit {
            let position = min(items.count - 1, Int((Double(index) * step).rounded()))
            result.append(items[position])
        }
        return result
    }
}
