import Foundation

/// 源的健康状况：总览卡片上的状态徽章。
package enum CatalogSourceHealth: String, Codable, Hashable {
    case unknown
    case checking
    case online
    case limited
    case offline

    package var title: String {
        switch self {
        case .unknown: return "未检测"
        case .checking: return "检测中"
        case .online: return "在线"
        case .limited: return "需验证"
        case .offline: return "离线"
        }
    }
}

/// 关注的分类（片商 / 题材）：跨源保存在本机，总览页一键跳转。
package struct CatalogFollowedCategory: Codable, Identifiable, Hashable {
    package var sourceID: UUID
    package var categoryID: String
    package var title: String
    package var sourceName: String
    package var addedAt: Date

    package var id: String { "\(sourceID.uuidString)|\(categoryID)" }
    package init(
        sourceID: UUID,
        categoryID: String,
        title: String,
        sourceName: String,
        addedAt: Date
    ) {
        self.sourceID = sourceID
        self.categoryID = categoryID
        self.title = title
        self.sourceName = sourceName
        self.addedAt = addedAt
    }
}

/// 跨源总榜里的一条：带上所属源，便于封面与跳转。
package struct CatalogSpotlightItem: Identifiable, Hashable, Codable {
    package var sourceID: UUID
    package var sourceName: String
    package var item: CatalogItem

    package var id: String { "\(sourceID.uuidString)|\(item.id)" }
    package init(
        sourceID: UUID,
        sourceName: String,
        item: CatalogItem
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.item = item
    }
}

/// 跨源搜索的一组结果。
package struct CatalogGlobalResult: Identifiable, Hashable, Codable {
    package var sourceID: UUID
    package var sourceName: String
    package var items: [CatalogItem]

    package var id: UUID { sourceID }
    package init(
        sourceID: UUID,
        sourceName: String,
        items: [CatalogItem]
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.items = items
    }
}

/// 悬停预览的播放目标：地址 + 站点要求的请求头。
package struct CatalogPreviewTarget {
    package var url: URL
    package var headers: [String: String]
    package init(
        url: URL,
        headers: [String: String]
    ) {
        self.url = url
        self.headers = headers
    }
}

/// 更新日历的一条：某条内容第一次在本机出现的时间。
package struct CatalogCalendarItem: Codable, Hashable, Identifiable {
    package var sourceID: UUID
    package var itemID: String
    package var title: String
    package var coverURL: String
    package var remark: String
    package var firstSeen: Date

    package var id: String { "\(sourceID.uuidString)|\(itemID)" }

    package var item: CatalogItem {
        CatalogItem(id: itemID, title: title, coverURL: coverURL,
                    remark: remark, categoryID: nil)
    }
    package init(
        sourceID: UUID,
        itemID: String,
        title: String,
        coverURL: String,
        remark: String,
        firstSeen: Date
    ) {
        self.sourceID = sourceID
        self.itemID = itemID
        self.title = title
        self.coverURL = coverURL
        self.remark = remark
        self.firstSeen = firstSeen
    }
}

/// 自定义片单里的一条。
package struct CatalogPlaylistEntry: Codable, Hashable, Identifiable {
    package var sourceID: UUID
    package var itemID: String
    package var title: String
    package var coverURL: String
    package var remark: String
    package var addedAt: Date

    package var id: String { "\(sourceID.uuidString)|\(itemID)" }

    package var item: CatalogItem {
        CatalogItem(id: itemID, title: title, coverURL: coverURL,
                    remark: remark, categoryID: nil)
    }
    package init(
        sourceID: UUID,
        itemID: String,
        title: String,
        coverURL: String,
        remark: String,
        addedAt: Date
    ) {
        self.sourceID = sourceID
        self.itemID = itemID
        self.title = title
        self.coverURL = coverURL
        self.remark = remark
        self.addedAt = addedAt
    }
}

/// 跨源片单。
package struct CatalogPlaylist: Codable, Hashable, Identifiable {
    package var id: UUID
    package var name: String
    package var entries: [CatalogPlaylistEntry]
    package var createdAt: Date
    /// 手动指定的封面；为空时用第一条的封面。
    package var coverURL: String? = nil
    package init(
        id: UUID,
        name: String,
        entries: [CatalogPlaylistEntry],
        createdAt: Date,
        coverURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.createdAt = createdAt
        self.coverURL = coverURL
    }
}

/// 聚合片单：输入关键字 + 条件，跨源动态聚合，不占用手动条目。
package struct CatalogSmartPlaylist: Codable, Hashable, Identifiable {
    package var id: UUID
    package var name: String
    /// 自然语言查询，例如「中文字幕 校园 90 年代」。
    package var query: String
    package var createdAt: Date
    package init(
        id: UUID,
        name: String,
        query: String,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.createdAt = createdAt
    }
}

/// 网络资源区的顶层分页。
/// 内置资料库不再作为可见入口：它只作为内部数据，供搜索、片源详情匹配与人物档案使用。
package enum CatalogHubTab: String, CaseIterable, Identifiable, Hashable {
    case browse
    case ranking
    case calendar
    case history
    case playlists
    case following

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .browse: return "资源"
        case .following: return "关注"
        case .ranking: return "榜单"
        case .history: return "足迹"
        case .playlists: return "片单"
        case .calendar: return "日历"
        }
    }

    package var symbol: String {
        switch self {
        case .browse: return "square.grid.2x2.fill"
        case .following: return "star.circle.fill"
        case .ranking: return "chart.bar.fill"
        case .history: return "clock.arrow.circlepath"
        case .playlists: return "rectangle.stack.fill"
        case .calendar: return "calendar"
        }
    }
}

/// 片单连播交给查看器的一项：源 + 条目 + 第一集。
package struct CatalogPlaylistPlaybackItem {
    package var source: CatalogSource
    package var item: CatalogItem
    package var episode: CatalogEpisode
    package init(
        source: CatalogSource,
        item: CatalogItem,
        episode: CatalogEpisode
    ) {
        self.source = source
        self.item = item
        self.episode = episode
    }
}

/// 关注的女优 / 片商。
package struct CatalogFollowedPerson: Codable, Hashable, Identifiable {
    package var name: String
    /// 「女优」或「片商」，只用于文案与分组。
    package var role: String
    /// 关注时所在的源：后台查新只打这一个源，避免每次刷新都跨源搜索。
    package var sourceID: UUID
    /// 已经看过的条目 id。
    package var seenIDs: [String]
    /// 上次检查后新增的数量。
    package var newCount: Int
    package var addedAt: Date

    package var id: String { "\(sourceID.uuidString)|\(role)|\(name)" }
    package init(
        name: String,
        role: String,
        sourceID: UUID,
        seenIDs: [String],
        newCount: Int,
        addedAt: Date
    ) {
        self.name = name
        self.role = role
        self.sourceID = sourceID
        self.seenIDs = seenIDs
        self.newCount = newCount
        self.addedAt = addedAt
    }
}

/// 详情页里点开的人物 / 片商：叠在详情上显示跨源档案。
/// 放在模型里是为了让窗口工具栏的返回按钮能先退回详情页。
package struct CatalogDetailPersonTarget: Identifiable, Equatable {
    package var name: String
    package var role: String
    package var id: String { "\(role)|\(name)" }
    package init(
        name: String,
        role: String
    ) {
        self.name = name
        self.role = role
    }
}

/// 关注页封面墙的一张：记住来源，恢复站点请求头与图片缓存键。
package struct CatalogFollowPoster: Codable, Hashable, Identifiable {
    package var sourceID: UUID
    package var coverURL: String
    package var title: String

    package var id: String { "\(sourceID.uuidString)|\(coverURL)" }
    package init(
        sourceID: UUID,
        coverURL: String,
        title: String
    ) {
        self.sourceID = sourceID
        self.coverURL = coverURL
        self.title = title
    }
}

/// 关注人物的聚合快照：先展示历史，再在后台拉新；新条目排最前并高亮。
package struct CatalogFollowAggregate: Codable, Hashable {
    package var personKey: String
    package var name: String
    package var role: String
    package var groups: [CatalogGlobalResult]
    /// 最近一次刷新相对上一份快照新增的条目（`sourceID|itemID`）。
    package var newIDs: [String]
    package var updatedAt: Date
    package init(
        personKey: String,
        name: String,
        role: String,
        groups: [CatalogGlobalResult],
        newIDs: [String],
        updatedAt: Date
    ) {
        self.personKey = personKey
        self.name = name
        self.role = role
        self.groups = groups
        self.newIDs = newIDs
        self.updatedAt = updatedAt
    }
}

/// 人物档案：跨源搜同名作品，按年份倒序排出时间线。
package struct CatalogPersonProfile: Identifiable, Hashable {
    package var name: String
    package var role: String
    /// 关注时记下的源（用于后台查新）。
    package var sourceID: UUID
    package var groups: [CatalogGlobalResult]
    /// 时间线：所有源的条目合并，按可解析的年份倒序。
    package var timeline: [CatalogSpotlightItem]
    /// 关注后第一次打开时发现的新条目。
    package var newCount: Int
    /// 本次刷新新进库的条目 id（和 `CatalogSpotlightItem.id` 同格式），用来做「新」高亮。
    package var newItemIDs: [String] = []
    package var fetchedAt: Date

    package var id: String { "\(role)|\(name)" }
    package var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    package init(
        name: String,
        role: String,
        sourceID: UUID,
        groups: [CatalogGlobalResult],
        timeline: [CatalogSpotlightItem],
        newCount: Int,
        newItemIDs: [String] = [],
        fetchedAt: Date
    ) {
        self.name = name
        self.role = role
        self.sourceID = sourceID
        self.groups = groups
        self.timeline = timeline
        self.newCount = newCount
        self.newItemIDs = newItemIDs
        self.fetchedAt = fetchedAt
    }
}

/// 站点不支持服务端排序时的「本页排序」：只对已经加载的这一页生效。
package enum CatalogLocalSort: String, CaseIterable, Identifiable, Hashable {
    case title
    case year
    case duration
    case firstSeen

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .title: return "标题"
        case .year: return "年份"
        case .duration: return "时长"
        case .firstSeen: return "首次看到"
        }
    }

    package var symbol: String {
        switch self {
        case .title: return "textformat.abc"
        case .year: return "calendar"
        case .duration: return "timer"
        case .firstSeen: return "sparkles"
        }
    }
}

/// 跨源总榜的维度：不依赖站点排序，用聚合数据自己排。
package enum CatalogSpotlightMode: String, CaseIterable, Identifiable, Hashable {
    case latest
    case hot
    case todayNew

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .latest: return "最新"
        case .hot: return "今日热榜"
        case .todayNew: return "今天新增"
        }
    }

    package var symbol: String {
        switch self {
        case .latest: return "clock.arrow.circlepath"
        case .hot: return "flame.fill"
        case .todayNew: return "sparkles"
        }
    }

    package var subtitle: String {
        switch self {
        case .latest: return "各源第一页轮转混排"
        case .hot: return "各源热榜轮转混排"
        case .todayNew: return "本机今天第一次看到的条目"
        }
    }
}

/// 自然语言搜索的解析结果：把「中文字幕 校园 90 年代」拆成检索词 + 筛选条件。
package struct CatalogQueryPlan: Hashable {
    package var raw: String
    /// 交给站点搜索的词。
    package var keywords: [String]
    package var chineseOnly: Bool
    package var yearFrom: Int?
    package var yearTo: Int?

    package var keyword: String { keywords.joined(separator: " ") }
    package var isEmpty: Bool { keyword.isEmpty }

    package var chips: [String] {
        var result = keywords
        if chineseOnly { result.append("中文字幕") }
        if let from = yearFrom, let to = yearTo {
            result.append(from == to ? "\(from)" : "\(from)–\(to)")
        }
        return result
    }

    /// 结果排序分：命中检索词加分，条件不符扣分。
    package func score(_ item: CatalogItem) -> Int {
        let text = item.title + " " + item.remark
        var score = 0
        for keyword in keywords where text.localizedCaseInsensitiveContains(keyword) {
            score += 3
        }
        if chineseOnly {
            let marks = ["中文字幕", "中字", "中文", "字幕"]
            score += marks.contains(where: { text.localizedCaseInsensitiveContains($0) }) ? 4 : -2
        }
        if yearFrom != nil || yearTo != nil {
            if let year = Self.year(in: text) {
                if year >= (yearFrom ?? 0), year <= (yearTo ?? 9999) { score += 5 } else { score -= 1 }
            } else {
                score -= 1
            }
        }
        return score
    }

    /// 从标题里取出四位年份。
    package static func year(in text: String) -> Int? {
        let pattern = "(19|20)\\d{2}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return Int(text[range])
    }

    package static func parse(_ raw: String) -> CatalogQueryPlan {
        var text = raw.lowercased()
        // 「90 年代」「90s」「90's」先合并成可识别的年份区间。
        let decadePattern = "(\\d{2})\\s*(?:年代|'s|s\\b)"
        if let regex = try? NSRegularExpression(pattern: decadePattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: text),
                      let digitRange = Range(match.range(at: 1), in: text),
                      let decade = Int(text[digitRange]) else { continue }
                let start = decade >= 30 ? 1900 + decade : 2000 + decade
                text.replaceSubrange(range, with: "\(start)年代")
            }
        }

        let separators = CharacterSet(charactersIn: "，,、|/;；:：()（）[]【】\"“”")
        let tokens = text.components(separatedBy: separators)
            .flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }) }
            .map(String.init)

        var keywords: [String] = []
        var chineseOnly = false
        var yearFrom: Int?
        var yearTo: Int?

        for token in tokens {
            if token.contains("字幕") || token == "中字" || token == "中文" {
                chineseOnly = true
                continue
            }
            if token.hasSuffix("年代") {
                if let start = Int(token.dropLast(2)) {
                    let base = start < 100 ? (start >= 30 ? 1900 + start : 2000 + start) : start
                    yearFrom = base
                    yearTo = base + 9
                }
                continue
            }
            if token.count == 4, let year = Int(token), year > 1900, year < 2100 {
                yearFrom = year
                yearTo = year
                continue
            }
            keywords.append(token)
        }

        return CatalogQueryPlan(raw: raw, keywords: keywords, chineseOnly: chineseOnly,
                                yearFrom: yearFrom, yearTo: yearTo)
    }
    package init(
        raw: String,
        keywords: [String],
        chineseOnly: Bool,
        yearFrom: Int? = nil,
        yearTo: Int? = nil
    ) {
        self.raw = raw
        self.keywords = keywords
        self.chineseOnly = chineseOnly
        self.yearFrom = yearFrom
        self.yearTo = yearTo
    }
}
