import Foundation
import LumaDomain

// MARK: - 缺集报告

/// 一条缺集记录：剧集按季缺集，或电影系列缺未入库的部件。
struct CinemaGapGroup: Identifiable {
    let id: String
    let title: String
    let kind: CinemaMediaKind
    /// 已入库多少。
    let owned: String
    /// 缺失项（S01E03 或片名）。
    let missing: [String]
    /// 一句话说明。
    let detail: String
}

// MARK: - 观影计划

enum CinemaPlanMood: String, CaseIterable, Identifiable {
    case any, relax, brain, cry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "随便"
        case .relax: return "轻松"
        case .brain: return "烧脑"
        case .cry: return "催泪"
        }
    }

    var symbol: String {
        switch self {
        case .any: return "sparkles"
        case .relax: return "sun.max"
        case .brain: return "brain.head.profile"
        case .cry: return "drop"
        }
    }

    /// 命中这些类型的片子加权。
    var genres: Set<String> {
        switch self {
        case .any: return []
        case .relax: return ["喜剧", "动画", "家庭", "爱情", "音乐", "冒险"]
        case .brain: return ["科幻", "悬疑", "惊悚", "犯罪", "剧情", "神秘"]
        case .cry: return ["剧情", "爱情", "家庭", "战争", "历史"]
        }
    }
}

struct CinemaPlanItem: Identifiable {
    let entry: CinemaEntry
    let reason: String
    var id: UUID { entry.id }
}

struct CinemaWatchPlan {
    let mood: CinemaPlanMood
    let minutes: Int
    let items: [CinemaPlanItem]
    let note: String

    var totalMinutes: Int {
        items.reduce(0) { $0 + CinemaWatchPlan.runtime(of: $1.entry) }
    }

    static func runtime(of entry: CinemaEntry) -> Int {
        if let runtime = entry.runtime, runtime > 0 { return runtime }
        let seconds = entry.file.duration ?? 0
        return seconds > 0 ? Int(seconds / 60) : 0
    }
}

extension LibraryStore {
    /// 顶栏控制台里的当前影院：网盘影院按挂载点，其余按本地。
    var cinemaConsoleScope: CinemaScope {
        if case .cloudCinema(let id) = sidebarItem { return .mount(id) }
        return .local
    }

    // MARK: 缺集（纯本地，不发网络请求）

    /// 剧集缺集：按季找 1…maxEpisode 的空洞；单季缺过 30 集视为数据不全，不报。
    func cinemaEpisodeGaps(for scope: CinemaScope) -> [CinemaGapGroup] {
        var result: [CinemaGapGroup] = []
        for series in cinemaSeries(for: scope) {
            var bySeason: [Int: Set<Int>] = [:]
            for episode in series.episodes {
                guard let season = episode.season, let number = episode.episode else { continue }
                bySeason[season, default: []].insert(number)
            }
            guard !bySeason.isEmpty else { continue }
            var missing: [String] = []
            var details: [String] = []
            for (season, numbers) in bySeason.sorted(by: { $0.key < $1.key }) {
                guard let maxEpisode = numbers.max(), maxEpisode > 1, maxEpisode <= 200 else { continue }
                let holes = (1...maxEpisode).filter { !numbers.contains($0) }
                guard !holes.isEmpty, holes.count <= 30 else { continue }
                missing.append(contentsOf: holes.map { String(format: "S%02dE%02d", season, $0) })
                details.append("第 \(season) 季缺 \(holes.count) 集")
            }
            guard !missing.isEmpty else { continue }
            result.append(CinemaGapGroup(
                id: "tv-\(series.id)",
                title: series.title,
                kind: .tv,
                owned: "已入库 \(series.episodes.count) 集",
                missing: Array(missing.prefix(60)),
                detail: details.joined(separator: " · ")
            ))
        }
        return result.sorted { $0.missing.count > $1.missing.count }
    }

    /// 电影合集缺片：需要 TMDB 合集详情；只查有正数合集 ID 的前几个，失败就跳过。
    func cinemaMovieCollectionGaps(for scope: CinemaScope, limit: Int = 6) async -> [CinemaGapGroup] {
        let entries = Array(cinemaEntries(for: scope).values)
        let collections = cinemaCollections(from: entries).prefix(limit)
        guard !collections.isEmpty else { return [] }
        var result: [CinemaGapGroup] = []
        for group in collections {
            guard group.id > 0,
                  let info = await cinemaCollectionInfo(collectionID: group.id),
                  !info.parts.isEmpty else { continue }
            let ownedIDs = Set(group.entries.filter { $0.provider == .tmdb }.compactMap(\.tmdbID))
            let missingParts = info.parts.filter { !ownedIDs.contains($0.tmdbID) }
            guard !missingParts.isEmpty else { continue }
            result.append(CinemaGapGroup(
                id: "collection-\(group.id)",
                title: group.name,
                kind: .movie,
                owned: "已入库 \(group.entries.count) 部",
                missing: missingParts.map { part in
                    part.year.map { "\($0) · \(part.title)" } ?? part.title
                },
                detail: "还有 \(missingParts.count) 部未入库"
            ))
        }
        return result
    }

    // MARK: 观影计划

    /// 按可用时长与心情挑片：优先未看完、收藏、评分与类型匹配；不联网。
    func cinemaWatchPlan(scope: CinemaScope,
                         minutes: Int,
                         mood: CinemaPlanMood) -> CinemaWatchPlan {
        var seen = Set<String>()
        var pool: [CinemaEntry] = []
        for entry in cinemaEntries(for: scope).values
        where entry.matched && entry.kind == .movie && !cinemaIsRestricted(entry) {
            let key = cinemaVersionKey(for: entry)
            guard seen.insert(key).inserted else { continue }
            pool.append(entry)
        }
        // 已看完的不进计划；如果全都看完了，就允许重看。
        let unfinished = pool.filter { cinemaProgress[$0.id]?.isFinished != true }
        let candidates = unfinished.isEmpty ? pool : unfinished

        let moodGenres = mood.genres
        let scored = candidates.compactMap { entry -> (entry: CinemaEntry, score: Double, reason: String)? in
            let runtime = CinemaWatchPlan.runtime(of: entry)
            guard runtime > 0 else { return nil }
            var score = (entry.rating ?? 0) * 12
            var reasons: [String] = []
            let hit = (entry.genres ?? []).first { moodGenres.contains($0) }
            if let hit {
                score += 25
                reasons.append(hit)
            }
            if entry.provider == .tmdb, (entry.doubanRating ?? 0) > (entry.rating ?? 0) {
                score += 2
            }
            if cinemaUserStates[entry.id]?.favorite == true {
                score += 20
                reasons.append("收藏")
            }
            if cinemaProgress[entry.id] != nil, cinemaProgress[entry.id]?.isFinished != true {
                score += 30
                reasons.append("上次没看完")
            }
            if minutes > 0 {
                // 时长越贴近可用时间越优先，但不硬性排除稍长的片子。
                score -= Double(abs(runtime - minutes)) * 0.15
            }
            if reasons.isEmpty {
                if let rating = entry.rating, rating > 0 {
                    reasons.append(String(format: "评分 %.1f", rating))
                } else {
                    reasons.append("片库随机")
                }
            }
            reasons.append("\(runtime) 分钟")
            return (entry, score, reasons.prefix(3).joined(separator: " · "))
        }
        .sorted { $0.score > $1.score }

        guard !scored.isEmpty else {
            return CinemaWatchPlan(mood: mood, minutes: minutes, items: [],
                                   note: "当前影院还没有可播放的已识别电影。")
        }

        var chosen: [CinemaPlanItem] = []
        var total = 0
        if minutes <= 0 {
            chosen = scored.prefix(3).map { CinemaPlanItem(entry: $0.entry, reason: $0.reason) }
            return CinemaWatchPlan(mood: mood, minutes: 0, items: chosen,
                                   note: "不限时长，按心情排了 \(chosen.count) 部。")
        }

        for item in scored {
            let runtime = CinemaWatchPlan.runtime(of: item.entry)
            if chosen.isEmpty, runtime > Int(Double(minutes) * 1.35) { continue }
            if !chosen.isEmpty, total + runtime > minutes + 10 { continue }
            chosen.append(CinemaPlanItem(entry: item.entry, reason: item.reason))
            total += runtime
            if total >= Int(Double(minutes) * 0.7) || chosen.count >= 3 { break }
        }
        if chosen.isEmpty {
            let longestAllowed = scored.first {
                CinemaWatchPlan.runtime(of: $0.entry) <= Int(Double(minutes) * 1.35)
            }
            if let fallback = longestAllowed ?? scored.first {
                chosen = [CinemaPlanItem(entry: fallback.entry, reason: fallback.reason)]
                total = CinemaWatchPlan.runtime(of: fallback.entry)
            }
        }
        let note: String
        if chosen.isEmpty {
            note = "没有找到合适时长的片子。"
        } else if total > minutes {
            note = "没有刚好够时长的，这一部 \(total) 分钟，会比计划多 \(total - minutes) 分钟。"
        } else {
            note = "共 \(chosen.count) 部 \(total) 分钟，留了 \(minutes - total) 分钟余量。"
        }
        return CinemaWatchPlan(mood: mood, minutes: minutes, items: chosen, note: note)
    }
}
