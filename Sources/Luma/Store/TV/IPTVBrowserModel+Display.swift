import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 展示

    /// 三种分组方式在「全部源」和单个源里都可用：
    /// 省份模式对海外频道退回按类型分组，不会把它们塞进某个省。
    var effectiveGroupingMode: TVGroupingMode { groupingMode }

    func setGroupingMode(_ mode: TVGroupingMode) {
        guard groupingMode != mode else { return }
        groupingMode = mode
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
    }

    /// 频道的聚合分区：央视 / 省份 / 其他。
    func section(for channel: TVChannel) -> String {
        if channel.region != .mainland { return channel.group }
        return channel.province ?? TVProvinces.section(for: channel.name)
    }

    /// 当前焦点源的频道数；没有焦点时为所有已启用源之和（同名频道只保留一份）。
    var channelsForFocusedSource: [TVChannel] {
        if let cached = focusedChannelsCache,
           cached.id == focusedPlaylistID,
           cached.revision == channelRevision {
            return cached.list
        }
        let list: [TVChannel]
        if let focusedPlaylistID {
            list = channels.filter { $0.playlistID == focusedPlaylistID }
        } else {
            list = aggregatedChannels
        }
        focusedChannelsCache = (focusedPlaylistID, channelRevision, list)
        return list
    }

    /// 聚合频道墙：同名频道只保留一份（源顺序优先，国内源在前）。
    var aggregatedChannels: [TVChannel] {
        if let cached = aggregatedCache { return cached }
        var seen = Set<String>()
        let list = channels.filter { seen.insert(Self.aggregationKey($0.name)).inserted }
        aggregatedCache = list
        return list
    }

    var aggregateChannelCount: Int { aggregatedChannels.count }

    /// 聚合时判断同名频道：忽略大小写、空格与标点，`CCTV-1` 与 `CCTV1` 视为同一台。
    static func aggregationKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var visibleChannels: [TVChannel] {
        let signature = visibleSignature
        guard signature != visibleCacheKey else { return visibleCache }
        visibleCache = computeVisibleChannels()
        visibleCacheKey = signature
        return visibleCache
    }

    /// 只让真正影响频道集合的输入失效：默认浏览不随收藏、最近观看或 EPG 重算。
    var visibleSignature: String {
        let hasProgramSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var signature = "\(channelRevision)|\(hasProgramSearch ? epgRevision : -1)|\(focusedPlaylistID?.uuidString ?? "-")"
            + "|\(regionFilter?.rawValue ?? "-")|\(groupFilter ?? "-")|\(provinceFilter ?? "-")"
            + "|\(countryFilter ?? "-")|\(effectiveGroupingMode.rawValue)|\(quickFilter?.rawValue ?? "-")|\(searchText)"
        if quickFilter == .favorites { signature += "|\(favoriteIDs.sorted().joined(separator: ","))" }
        if quickFilter == .recent { signature += "|\(recentIDs.joined(separator: ","))" }
        return signature
    }

    /// 夜航还依赖节目内容，即使当前频道集合不变也必须随 EPG 失效。
    var tonightDataSignature: String { "\(visibleSignature)|epg:\(epgRevision)" }
    func computeVisibleChannels() -> [TVChannel] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchTokens = TVSearchQuery.tokens(keyword)
        let mode = effectiveGroupingMode
        let filtered = channelsForFocusedSource.filter { channel in
            if let regionFilter, channel.region != regionFilter { return false }
            switch mode {
            case .province:
                if let provinceFilter, section(for: channel) != provinceFilter { return false }
            case .country:
                if let countryFilter, TVCountries.country(for: channel) != countryFilter { return false }
            case .category:
                if let groupFilter, channel.group != groupFilter { return false }
            }
            if !keyword.isEmpty {
                // 搜索同时覆盖频道名、分组 / 省份归属与节目名：
                // 用户可能只记得「新闻联播」，也可能直接按「上海」找本地台（东方卫视等）。
                if TVSearchQuery.matchesChannelIdentity(channel, tokens: searchTokens) {
                    return true
                }
                return programs(for: channel).contains {
                    $0.title.localizedCaseInsensitiveContains(keyword)
                }
            }
            return true
        }
        guard let quickFilter else { return filtered }
        switch quickFilter {
        case .favorites:
            return filtered.filter { favoriteIDs.contains($0.id) }
        case .recent:
            let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
            return recentIDs.compactMap { byID[$0] }
        }
    }

    /// 频道号按当前源的完整频道列表编号；筛选后仍保持稳定。
    func channelNumber(for channel: TVChannel) -> Int {
        let key = "\(channelRevision)-\(focusedPlaylistID?.uuidString ?? "-")"
        guard key != channelNumberIndexKey else { return channelNumberIndex[channel.id] ?? 0 }
        var index: [String: Int] = [:]
        for (offset, item) in channelsForFocusedSource.enumerated() where index[item.id] == nil {
            index[item.id] = offset + 1
        }
        channelNumberIndex = index
        channelNumberIndexKey = key
        return channelNumberIndex[channel.id] ?? 0
    }

    var groupedChannels: [(group: String, channels: [TVChannel])] {
        let list = visibleChannels
        guard visibleCacheKey != groupedCacheKey else { return groupedCache }
        let result: [(group: String, channels: [TVChannel])]
        switch effectiveGroupingMode {
        case .category:
            let grouped = Dictionary(grouping: list, by: \.group)
            result = grouped.keys.sorted { TVGrouping.rank($0) < TVGrouping.rank($1) }
                .map { ($0, grouped[$0] ?? []) }
        case .province:
            let grouped = Dictionary(grouping: list, by: { section(for: $0) })
            result = grouped.keys.sorted { provinceSectionRank($0) < provinceSectionRank($1) }
                .map { key in
                    // 省内排序：卫视在前，其余按频道名，避免城市台压过省台。
                    let list = (grouped[key] ?? []).sorted { left, right in
                        let leftSatellite = TVProvinces.isSatellite(left.name)
                        let rightSatellite = TVProvinces.isSatellite(right.name)
                        if leftSatellite != rightSatellite { return leftSatellite }
                        return left.name.localizedStandardCompare(right.name) == .orderedAscending
                    }
                    return (key, list)
                }
        case .country:
            let grouped = Dictionary(grouping: list, by: { TVCountries.country(for: $0) })
            result = grouped.keys.sorted { TVCountries.rank($0) < TVCountries.rank($1) }
                .map { ($0, TVChannelOrder.sorted(grouped[$0] ?? [])) }
        }
        groupedCache = result
        groupedCacheKey = visibleCacheKey
        return result
    }

    /// 省份分区的顺序：省市按行政区排；海外频道没有省份，退回按频道类型顺序排在后面。
    func provinceSectionRank(_ section: String) -> Int {
        let index = TVProvinces.rank(section)
        guard index >= TVProvinces.ordered.count else { return index }
        return TVProvinces.ordered.count + TVGrouping.rank(section)
    }

    /// 频道墙上「筛选胶囊」的可选项，跟随当前分组方式。
    /// 「按国家」固定列出全部国家 / 地区：源里暂时没有的也保留入口，
    /// 换源或补源之后不用重新找位置。
    var filterOptions: [String] {
        let scoped = regionFilter.map { region in
            channelsForFocusedSource.filter { $0.region == region }
        } ?? channelsForFocusedSource
        switch effectiveGroupingMode {
        case .category:
            return Array(Set(scoped.map(\.group)))
                .sorted { TVGrouping.rank($0) < TVGrouping.rank($1) }
        case .province:
            return Array(Set(scoped.map { section(for: $0) }))
                .sorted { provinceSectionRank($0) < provinceSectionRank($1) }
        case .country:
            return TVCountries.order
        }
    }

    var totalChannelCount: Int { channels.count }
}
