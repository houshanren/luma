import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

// MARK: - 今晚推荐规则

/// 节目分类：直播页的「黄金时段」货架与「今晚」页共用一套标题、颜色与图标。
enum TVGuideCategory: String, CaseIterable, Identifiable {
    case news, sport, drama, variety, movie, documentary, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .news: return "新闻"
        case .sport: return "赛事"
        case .drama: return "剧集"
        case .variety: return "综艺"
        case .movie: return "电影"
        case .documentary: return "纪实"
        case .other: return "精选"
        }
    }

    var tint: Color {
        switch self {
        case .news: return TVBrand.wave
        case .sport: return TVBrand.gold
        case .drama: return LumaBrand.violet
        case .variety: return LumaBrand.coral
        case .movie: return LumaBrand.cyan
        case .documentary: return LumaBrand.mint
        case .other: return Color.secondary
        }
    }

    var symbol: String {
        switch self {
        case .news: return "newspaper"
        case .sport: return "sportscourt"
        case .drama: return "theatermasks"
        case .variety: return "sparkles"
        case .movie: return "film"
        case .documentary: return "leaf"
        case .other: return "square.grid.2x2"
        }
    }
}

/// 一场赛事：同一场比赛在多个频道同播时只留一条，channel 是其中最适合打开的那一台。
struct TVSportEvent: Identifiable {
    let key: String
    var channel: TVChannel
    var program: TVEPGProgram
    var simulcast: Int
    /// 全部同播频道（第 0 条是默认频道）：赛事详情据此给出「换台」列表。
    var channels: [TVChannel] = []
    var id: String { key }
}

/// 赛事角度：当前热播 / 即将开赛 / 历史 / 未来。
enum TVSportAngle: String, CaseIterable, Identifiable {
    case live, upcoming, history, future

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "当前热播"
        case .upcoming: return "即将开赛"
        case .history: return "历史"
        case .future: return "未来"
        }
    }

    var symbol: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .upcoming: return "clock"
        case .history: return "clock.arrow.circlepath"
        case .future: return "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .live: return TVBrand.signal
        case .upcoming: return TVBrand.gold
        case .history: return Color.secondary
        case .future: return TVBrand.wave
        }
    }
}

/// 体育类型：赛事分区上的一排筛选胶囊。
enum TVSportType: String, CaseIterable, Identifiable {
    case all, general, football, basketball, worldCup, olympic, tennis, snooker,
         volleyball, badminton, tableTennis, athletics, aquatics, winter,
         combat, racing, esports, golf, baseball, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .general: return "综合"
        case .football: return "足球"
        case .basketball: return "篮球"
        case .worldCup: return "世界杯"
        case .olympic: return "奥运"
        case .tennis: return "网球"
        case .snooker: return "斯诺克"
        case .volleyball: return "排球"
        case .badminton: return "羽毛球"
        case .tableTennis: return "乒乓球"
        case .athletics: return "田径"
        case .aquatics: return "游泳"
        case .winter: return "冰雪"
        case .combat: return "格斗"
        case .racing: return "赛车"
        case .esports: return "电竞"
        case .golf: return "高尔夫"
        case .baseball: return "棒球"
        case .other: return "其他"
        }
    }

    /// 从赛事标题推断类型：先认「世界杯 / 奥运」这类大赛，再认具体项目。
    static func detect(_ title: String) -> TVSportType {
        let text = title.lowercased()
        func hit(_ words: [String]) -> Bool {
            words.contains { text.contains($0) }
        }
        if hit(["世界杯"]) { return .worldCup }
        if hit(["奥运", "冬奥", "亚运", "全运", "残奥", "大运会"]) { return .olympic }
        if hit(["篮球", "nba", "cba", "wnba", "篮联"]) { return .basketball }
        if hit(["足球", "英超", "欧冠", "中超", "亚冠", "西甲", "意甲", "德甲", "法甲",
                "世预赛", "亚洲杯", "欧洲杯", "足总杯", "足协杯", "美洲杯"]) { return .football }
        if hit(["排球", "女排", "男排", "排超"]) { return .volleyball }
        if hit(["羽毛球", "羽球", "羽超", "汤杯", "尤伯杯", "全英赛"]) { return .badminton }
        if hit(["乒乓", "乒超", "wtt", "世乒赛"]) { return .tableTennis }
        if hit(["网球", "温网", "法网", "美网", "澳网", "wta", "atp", "中网"]) { return .tennis }
        if hit(["斯诺克", "台球", "九球", "中式台球"]) { return .snooker }
        if hit(["田径", "马拉松", "竞走", "钻石联赛", "室内田径"]) { return .athletics }
        if hit(["游泳", "跳水", "花样游泳", "水球", "公开水域"]) { return .aquatics }
        if hit(["滑雪", "滑冰", "冰球", "冰壶", "花滑", "雪车", "钢架雪车", "短道速滑"]) {
            return .winter
        }
        if hit(["拳击", "格斗", "ufc", "mma", "散打", "自由搏击", "摔跤", "柔道",
                "跆拳道", "空手道"]) { return .combat }
        if hit(["赛车", "f1", "摩托", "拉力", "环法", "方程式", "越野赛"]) { return .racing }
        if hit(["电竞", "英雄联盟", "王者荣耀", "kpl", "lpl", "dota", "csgo", "守望先锋"]) {
            return .esports
        }
        if hit(["高尔夫", "pga", "欧巡"]) { return .golf }
        if hit(["棒球", "mlb", "垒球", "棒球联赛"]) { return .baseball }
        if hit(["体操", "举重", "射箭", "击剑", "赛艇", "帆船", "自行车", "攀岩",
                "滑板", "冲浪", "龙舟", "武术", "围棋", "象棋", "国际象棋"]) { return .general }
        return .other
    }
}

/// 综艺 / 纪实等非赛事节目里的一档：同一个节目名跨台只留一条。
struct TVShowPick: Identifiable {
    let key: String
    var channel: TVChannel
    var program: TVEPGProgram
    var simulcast: Int
    var id: String { key }
}

/// 黄金时段的一档精选：带评分与「入选理由」，方便界面解释为什么推荐它。
struct TVPrimePick: Identifiable {
    let key: String
    let channel: TVChannel
    let program: TVEPGProgram
    let category: TVGuideCategory
    let simulcast: Int
    let score: Int
    let reasons: [String]
    var id: String { key }
}

/// 黄金时段里的一个 30 分钟格子：档数按「不同节目」统计，同播只算一档。
struct TVPrimeSlot: Identifiable {
    let index: Int
    let count: Int
    /// 这一格里占比最高的类型，决定格子的颜色。
    let category: TVGuideCategory?
    var id: Int { index }
}

/// 某一天里一个频道的节目：整页快照的输入，纯计算函数不必再碰视图模型。
struct TVChannelDay {
    let channel: TVChannel
    let programs: [TVEPGProgram]
}

/// 「夜航」页整页一次算好的数据：节目单只扫一遍，赛事 / 黄金时段 / 综艺 / 人物
/// 共用同一份分类结果，切换角度、预约、追剧都不再重扫节目单。
struct TVTonightSnapshot {
    var sports: [TVSportEvent] = []
    var history: [TVSportEvent] = []
    var future: [TVSportEvent] = []
    /// 赛事 key → 体育类型：行标签与筛选胶囊直接取，不再逐行推断标题。
    var sportTypes: [String: TVSportType] = [:]
    var picks: [TVPrimePick] = []
    /// 黄金时段每 30 分钟的档数统计：热力条用它，不受精选名额限制。
    var primeSlots: [TVPrimeSlot] = []
    var variety: [TVShowPick] = []
    var people: [TVShowPick] = []
    /// 已追的节目 id：卡片书签状态一次算好，渲染时不再重跑正则。
    var followedProgramIDs: Set<String> = []

    /// 页头统计：节目档数与涉及的频道数。
    var showCount: Int { picks.count + variety.count + people.count }
    var channelCount: Int {
        Set(sports.map(\.channel.id) + picks.map(\.channel.id)
            + variety.map(\.channel.id) + people.map(\.channel.id)).count
    }
}

/// 「今晚赛事 / 黄金时段」的匹配规则：识别、同播合并、频道优先与排序都收在这里，
/// 直播页的两条货架和「夜航」页共用同一份逻辑，不会再各算一套。
enum TVTonightRules {
    /// 赛事关键词：比原先多了世界杯 / 奥运 / 决赛这类「大赛」词，以及田径、赛车、格斗等项目。
    static let sportKeywords: [String] = [
        "体育", "足球", "篮球", "网球", "排球", "羽毛球", "乒乓", "斯诺克", "高尔夫",
        "赛车", "拳击", "格斗", "电竞", "田径", "马拉松", "环法", "滑雪", "冰球", "棒球",
        "联赛", "杯", "球赛", "英超", "欧冠", "中超", "亚冠", "NBA", "CBA", "F1", "UFC",
        "WTT", "ATP", "WTA", "KPL", "LPL", "MLB", "PGA", "世界杯", "奥运", "亚运", "全运",
        "决赛", "半决赛", "德比", "世锦赛", "锦标赛", "公开赛", "大奖赛", "巡回赛",
        "排位赛", "小组赛", "附加赛", "资格赛", "全明星", "乒超", "羽超", "排超",
        "游泳", "跳水", "体操", "举重", "射箭", "击剑", "摔跤", "柔道", "跆拳道",
        "冰壶", "花滑", "短道速滑", "赛艇", "帆船", "攀岩", "滑板", "冲浪", "武术"
    ]

    /// 栏目类标题：名字里有体育但并不比赛事，避免把「体育新闻」当成一场比赛。
    static let sportExclusions: [String] = [
        "体育新闻", "体育世界", "体育晨报", "体育人间", "体坛快讯", "赛事预告",
        "精彩回顾", "体育报道", "赛事集锦", "体育资讯", "运动空间", "健身动起来"
    ]

    /// 黄金时段窗口：19:30 – 23:30。
    static func primeWindow(on day: Date) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: day)
        guard let start = calendar.date(bySettingHour: 19, minute: 30, second: 0, of: today),
              let end = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: today)
        else { return nil }
        return (start, end)
    }

    /// 关键词预先转小写：赛事判定要跑上万次，避免每次都做本地化大小写比较。
    private static let sportKeywordsLower = sportKeywords.map { $0.lowercased() }

    static func isSport(_ program: TVEPGProgram, channel: TVChannel) -> Bool {
        if sportExclusions.contains(where: { program.title.contains($0) }) { return false }
        let lowered = program.title.lowercased()
        if sportKeywordsLower.contains(where: { lowered.contains($0) }) {
            return true
        }
        // 体育频道上的整档节目（足够长）也算赛事：很多联赛只写「焦点战」这类泛标题。
        return channel.group.contains("体育") && program.duration >= 20 * 60
    }

    /// 综艺关键词：常见国民综艺的名字也收进来，光靠「综艺 / 晚会」会漏掉一大半。
    static let varietyKeywords: [String] = [
        "综艺", "晚会", "盛典", "演唱会", "喜剧", "脱口秀", "访谈", "真人秀",
        "歌手", "舞台", "王牌", "奔跑吧", "极限挑战", "你好星期六", "快乐大本营",
        "天天向上", "向往的生活", "中餐厅", "乘风破浪", "披荆斩棘", "明星大侦探",
        "密室大逃脱", "我们的歌", "天赐的声音", "声生不息", "青春环游记", "花儿与少年",
        "非诚勿扰", "中国好声音", "欢乐喜剧人", "一年一度喜剧大赛", "脱口秀大会",
        "春晚", "跨年", "元宵", "中秋"
    ]

    /// 纪实 / 人物关键词。
    static let documentaryKeywords: [String] = [
        "纪录", "纪实", "人文", "地理", "自然", "探索", "档案", "人物", "大师",
        "匠心", "传奇", "历史", "寻访", "走进", "国家记忆", "大国重器", "舌尖",
        "航拍中国", "如果国宝会说话", "我在故宫修文物", "河西走廊", "敦煌", "故事"
    ]

    /// 人物记录：在纪实里优先挑「讲人」的片子。
    static let peopleKeywords: [String] = [
        "人物", "大师", "匠心", "传奇", "人生", "面孔", "故事", "记忆", "时代", "档案"
    ]

    /// 栏目分类的预转小写关键词：整页一次遍历时每档节目只调一次。
    private static let varietyKeywordsLower = varietyKeywords.map { $0.lowercased() }
    private static let documentaryKeywordsLower = documentaryKeywords.map { $0.lowercased() }

    static func category(_ title: String) -> TVGuideCategory {
        if ["新闻", "联播", "朝闻", "焦点访谈", "观察", "资讯"].contains(where: { title.contains($0) }) {
            return .news
        }
        if ["剧场", "电视剧", "连续剧", "第", "集", "季"].contains(where: { title.contains($0) }) {
            return .drama
        }
        let lowered = title.lowercased()
        if varietyKeywordsLower.contains(where: { lowered.contains($0) }) {
            return .variety
        }
        if title.contains("电影") { return .movie }
        if documentaryKeywordsLower.contains(where: { lowered.contains($0) }) {
            return .documentary
        }
        return .other
    }

    static func isPeopleDocumentary(_ title: String) -> Bool {
        peopleKeywords.contains { title.contains($0) }
    }

    /// 频道权重：同一档节目被多个台同播时，优先用这个台播。
    static func channelPriority(_ channel: TVChannel) -> Int {
        let name = channel.name
        var score = 0
        if name.contains("CCTV5") || name.contains("CCTV-5") { score += 30 }
        if name.contains("体育") { score += 20 }
        if name.contains("CCTV") { score += 10 }
        if name.contains("卫视") { score += 6 }
        if channel.isHLS { score += 2 }
        return score
    }

    /// 节目名归一化：用于「同一档节目」的去重与同播统计。
    static func key(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }

    /// 单次遍历生成整页数据。
    /// 原先每个板块各扫一遍节目单（赛事三个角度 + 黄金时段两次 + 综艺两次 + 人物一次），
    /// 现在频道 × 节目只走一遍，赛事判定、栏目分类、体育类型都只算一次。
    static func tonightSnapshot(today: [TVChannelDay],
                                tomorrow: [TVChannelDay],
                                now: Date) -> TVTonightSnapshot {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let dayEnd = startOfDay.addingTimeInterval(86_400)
        let horizon = now.addingTimeInterval(14 * 3600)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? dayEnd
        let tomorrowEnd = tomorrowStart.addingTimeInterval(86_400)
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? startOfDay
        let window = primeWindow(on: now)

        var liveBest: [String: TVSportEvent] = [:]
        var historyBest: [String: TVSportEvent] = [:]
        var futureBest: [String: TVSportEvent] = [:]
        var simulcastIndex: [String: Set<String>] = [:]
        var slotKeys: [Int: Set<String>] = [:]
        var slotCategories: [Int: [TVGuideCategory: Int]] = [:]
        var primeCandidates: [(channel: TVChannel, program: TVEPGProgram,
                               category: TVGuideCategory, programKey: String)] = []
        var eveningShows: [String: TVShowPick] = [:]
        var allDayShows: [String: TVShowPick] = [:]
        var documentaries: [String: TVShowPick] = [:]

        for day in today {
            let channel = day.channel
            for program in day.programs {
                // 赛事判定与栏目分类是整页最贵的两步，每档节目只做一次。
                let sport = isSport(program, channel: channel)
                let guideCategory = category(program.title)
                let titleKey = key(program.title)

                if sport {
                    if program.end > now, program.start <= horizon {
                        let eventKey = titleKey + "#"
                            + String(Int(program.start.timeIntervalSince1970 / 1800))
                        mergeSport(TVSportEvent(key: eventKey, channel: channel,
                                                program: program, simulcast: 1),
                                   channel: channel, into: &liveBest)
                    }
                    if program.end <= now, program.start >= startOfDay {
                        let eventKey = titleKey + "#"
                            + String(Int(program.start.timeIntervalSince1970 / 1800))
                        mergeSport(TVSportEvent(key: eventKey, channel: channel,
                                                program: program, simulcast: 1),
                                   channel: channel, into: &historyBest)
                    }
                }

                // 同播统计覆盖黄金时段内的所有节目（含赛事），与原先一致。
                if let window, program.start >= window.start, program.start < window.end {
                    let bucket = titleKey + "#"
                        + String(Int(program.start.timeIntervalSince1970 / 300))
                    simulcastIndex[bucket, default: []].insert(channel.name)
                    // 时段热度：按「不同节目」计数，同播台只算一档。
                    let slot = Int(program.start.timeIntervalSince(window.start) / 1800)
                    if slotKeys[slot, default: []].insert(bucket).inserted {
                        slotCategories[slot, default: [:]][guideCategory, default: 0] += 1
                    }
                    if !sport, program.end > now, titleKey.count >= 2 {
                        primeCandidates.append((channel, program, guideCategory, titleKey))
                    }
                }

                guard program.start >= startOfDay, program.start < dayEnd, titleKey.count >= 2 else {
                    continue
                }
                if guideCategory == .variety {
                    mergeShow(program, channel: channel, titleKey: titleKey, into: &allDayShows)
                    if program.start >= evening {
                        mergeShow(program, channel: channel, titleKey: titleKey, into: &eveningShows)
                    }
                } else if guideCategory == .documentary {
                    mergeShow(program, channel: channel, titleKey: titleKey, into: &documentaries)
                }
            }
        }

        // 明天的赛事：只扫明天的节目单，避免和「今天」重复判定。
        for day in tomorrow {
            for program in day.programs where program.start >= tomorrowStart {
                guard program.start < tomorrowEnd,
                      isSport(program, channel: day.channel) else { continue }
                let eventKey = key(program.title) + "#"
                    + String(Int(program.start.timeIntervalSince1970 / 1800))
                mergeSport(TVSportEvent(key: eventKey, channel: day.channel,
                                        program: program, simulcast: 1),
                           channel: day.channel, into: &futureBest)
            }
        }

        var snapshot = TVTonightSnapshot()
        snapshot.sports = liveBest.values
            .sorted { $0.program.start < $1.program.start }
            .prefix(40)
            .map { $0 }
        snapshot.history = historyBest.values
            .sorted { $0.program.start > $1.program.start }
            .prefix(16)
            .map { $0 }
        snapshot.future = futureBest.values
            .sorted { $0.program.start < $1.program.start }
            .prefix(16)
            .map { $0 }
        for event in snapshot.sports + snapshot.history + snapshot.future {
            if snapshot.sportTypes[event.key] == nil {
                snapshot.sportTypes[event.key] = TVSportType.detect(event.program.title)
            }
        }

        var picked: [String: TVPrimePick] = [:]
        for candidate in primeCandidates {
            let program = candidate.program
            let bucket = candidate.programKey + "#"
                + String(Int(program.start.timeIntervalSince1970 / 300))
            let simulcast = simulcastIndex[bucket]?.count ?? 1
            let value = score(program: program,
                              category: candidate.category,
                              simulcast: simulcast,
                              channel: candidate.channel,
                              now: now)
            if let current = picked[candidate.programKey], current.score >= value { continue }
            picked[candidate.programKey] = TVPrimePick(key: candidate.programKey,
                                                       channel: candidate.channel,
                                                       program: program,
                                                       category: candidate.category,
                                                       simulcast: simulcast,
                                                       score: value,
                                                       reasons: reasons(program: program,
                                                                        category: candidate.category,
                                                                        simulcast: simulcast))
        }
        // 每个 30 分钟时段只留评分最高的几档：40 个名额平均分到整个黄金时段，
        // 否则会被 19:30 这一档节目占满，后面的时段与热力条全是空的。
        let perSlot = 5
        var bySlot: [Int: [TVPrimePick]] = [:]
        for pick in picked.values {
            let offset = window.map { pick.program.start.timeIntervalSince($0.start) } ?? 0
            let slot = max(0, Int(offset / 1800))
            bySlot[slot, default: []].append(pick)
        }
        var balanced: [TVPrimePick] = []
        for slot in bySlot.keys.sorted() {
            balanced += (bySlot[slot] ?? [])
                .sorted { $0.score > $1.score }
                .prefix(perSlot)
        }
        if balanced.count < 40 {
            let chosen = Set(balanced.map(\.key))
            let rest = picked.values
                .filter { !chosen.contains($0.key) }
                .sorted { $0.score > $1.score }
            balanced += rest.prefix(40 - balanced.count)
        }
        snapshot.picks = balanced.sorted { $0.program.start < $1.program.start }

        // 时段热度用全量节目统计（同播只算一档），和上面精选名额无关。
        if let window {
            let slotCount = max(1, Int(window.end.timeIntervalSince(window.start) / 1800))
            snapshot.primeSlots = (0..<slotCount).map { index in
                let counts = slotCategories[index] ?? [:]
                return TVPrimeSlot(index: index,
                                   count: slotKeys[index]?.count ?? 0,
                                   category: counts.max { $0.value < $1.value }?.key)
            }
        }

        let eveningPicks = sortedShows(eveningShows, limit: 12)
        snapshot.variety = eveningPicks.isEmpty ? sortedShows(allDayShows, limit: 12) : eveningPicks

        let allDocumentaries = sortedShows(documentaries, limit: 40)
        let people = allDocumentaries.filter { isPeopleDocumentary($0.program.title) }
        let rest = allDocumentaries.filter { !isPeopleDocumentary($0.program.title) }
        snapshot.people = Array((people + rest).prefix(10))
        return snapshot
    }

    /// 同名赛事合并：同播台数累加，频道权重高的留下。
    private static func mergeSport(_ event: TVSportEvent,
                                   channel: TVChannel,
                                   into best: inout [String: TVSportEvent]) {
        guard var existing = best[event.key] else {
            var created = event
            created.channels = [channel]
            created.simulcast = 1
            best[event.key] = created
            return
        }
        if existing.channels.isEmpty {
            existing.channels = [existing.channel]
        }
        if !existing.channels.contains(where: { $0.id == channel.id }) {
            existing.channels.append(channel)
        }
        existing.simulcast = existing.channels.count
        if channelPriority(channel) > channelPriority(existing.channel) {
            existing.channel = channel
            existing.program = event.program
        }
        best[event.key] = existing
    }

    /// 同名综艺 / 纪实跨台合并：同播台数累加，频道权重高的留下。
    private static func mergeShow(_ program: TVEPGProgram,
                                  channel: TVChannel,
                                  titleKey: String,
                                  into best: inout [String: TVShowPick]) {
        guard var existing = best[titleKey] else {
            best[titleKey] = TVShowPick(key: titleKey, channel: channel,
                                        program: program, simulcast: 1)
            return
        }
        existing.simulcast += 1
        if channelPriority(channel) > channelPriority(existing.channel) {
            existing.channel = channel
            existing.program = program
        }
        best[titleKey] = existing
    }

    /// 货架排序：正在播的在前，其次按开播时间。
    private static func sortedShows(_ picks: [String: TVShowPick], limit: Int) -> [TVShowPick] {
        picks.values
            .sorted { lhs, rhs in
                if lhs.program.isLive != rhs.program.isLive { return lhs.program.isLive }
                return lhs.program.start < rhs.program.start
            }
            .prefix(limit)
            .map { $0 }
    }

    /// 评分：同播台数 + 类型权重 + 大赛 / 首播 / 直播加权 + 频道权重 + 20:00 时段权重。
    static func score(program: TVEPGProgram,
                      category: TVGuideCategory,
                      simulcast: Int,
                      channel: TVChannel,
                      now: Date) -> Int {
        var score = min(5, simulcast) * 6
        switch category {
        case .news: score += 60
        case .sport: score += 50
        case .drama: score += 40
        case .variety: score += 35
        case .movie: score += 25
        case .documentary: score += 20
        case .other: score += 10
        }
        if program.title.contains("新闻联播") { score += 40 }
        if program.title.contains("首播") { score += 15 }
        if program.title.contains("决赛") { score += 25 }
        if program.title.contains("半决赛") { score += 15 }
        if program.isLive { score += 20 }
        score += channelPriority(channel) / 2
        if program.duration >= 45 * 60 { score += 5 }
        // 越接近 20:00 的节目越靠前。
        let components = Calendar.current.dateComponents([.hour, .minute], from: program.start)
        let minutes = (components.hour ?? 20) * 60 + (components.minute ?? 0)
        score += max(0, 40 - abs(minutes - 20 * 60) / 3)
        return score
    }

    /// 入选理由：界面上直接把这些标签摆出来，推荐不再是黑盒。
    static func reasons(program: TVEPGProgram,
                        category: TVGuideCategory,
                        simulcast: Int) -> [String] {
        var list: [String] = []
        if simulcast > 1 { list.append("\(simulcast) 台同播") }
        if program.title.contains("新闻联播") { list.append("全国联播") }
        if program.title.contains("决赛") { list.append("决赛") }
        if program.title.contains("首播") { list.append("首播") }
        if program.isLive { list.append("直播中") }
        let components = Calendar.current.dateComponents([.hour, .minute], from: program.start)
        let minutes = (components.hour ?? 20) * 60 + (components.minute ?? 20 * 60)
        if abs(minutes - 20 * 60) <= 45 { list.append("20:00 档") }
        if list.isEmpty {
            list.append(category == .other ? "综合精选" : "\(category.title)重点")
        }
        return Array(list.prefix(3))
    }
}
