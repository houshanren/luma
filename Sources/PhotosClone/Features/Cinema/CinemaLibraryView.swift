import SwiftUI
import AppKit

/// 影院详情 / 面板统一深色底：避免跟随系统浅色外观出现白底。
private let cinemaSheetBackground = Color(red: 0.055, green: 0.06, blue: 0.075)

/// 影院详情面板尽量吃满窗口：大屏更大，小屏也不会溢出。
private var cinemaDetailWindowSize: CGSize {
    let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    return CGSize(width: min(1480, max(1000, visible.width - 120)),
                  height: min(980, max(720, visible.height - 100)))
}

// MARK: - 规格角标

/// 角标流式布局：一行放不下自动换行，窄卡也能完整显示 4K / DV / Atmos / 类型。
private struct CinemaBadgeFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                width = max(width, lineWidth)
                height += lineHeight + lineSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 集卡在网格里的位置：悬停时把完整档案浮在该集旁边，而不是覆盖卡片本身。
private struct CinemaEpisodeAnchorKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>],
                       nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 规格角标组：4K / DV / HDR10+ / 10bit / Atmos / DTS-HD / 60fps / 类型。
private struct CinemaSpecBadges: View {
    let tags: [String]
    var fontSize: CGFloat = 8.5
    var tint: Color = .white
    var background: Color = .black.opacity(0.5)

    var body: some View {
        CinemaBadgeFlow(spacing: max(3, fontSize * 0.45),
                        lineSpacing: max(2, fontSize * 0.35)) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.94))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, max(4, fontSize * 0.62))
                    .padding(.vertical, max(1.5, fontSize * 0.3))
                    .background(background, in: Capsule())
            }
        }
    }
}

/// 卡片角标：只挑最重要的 1–2 个 —— 分辨率 > HDR 规格 > 音质，不铺满海报。
private func cinemaBadgeTags(_ file: CinemaFile?, limit: Int = 2) -> [String] {
    guard let file else { return [] }
    let tags = file.displayTags
    let resolution = ["4K", "2K", "1080P"]
    let dynamicRange = ["DV", "HDR10+", "HDR10", "HDR", "HLG"]
    let audio = ["Atmos", "DTS:X", "TrueHD", "DTS-HD", "DTS"]
    var picked: [String] = []
    if let value = resolution.first(where: { tags.contains($0) }) { picked.append(value) }
    if let value = dynamicRange.first(where: { tags.contains($0) }) { picked.append(value) }
    if let value = audio.first(where: { tags.contains($0) }) { picked.append(value) }
    // 没有分辨率 / 音画标记时退回其他标记（10bit / 60fps 等），但不铺满。
    if picked.isEmpty { picked = tags }
    return Array(picked.prefix(limit))
}

// MARK: - 详情页共用的小工具

/// 可展开的长简介：超过 6 行才出现「展开全文」。
private struct CinemaSynopsis: View {
    let text: String

    @State private var expanded = false

    private var isLong: Bool { text.count > 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 12.8))
                .foregroundStyle(.secondary)
                .lineSpacing(6)
                .lineLimit(expanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isLong {
                Button(expanded ? "收起" : "展开全文") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        }
    }
}

/// 2026-11-20 → 2026 年 11 月 20 日
private func cinemaDateText(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let parts = raw.split(separator: "-")
    guard parts.count >= 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
        return raw
    }
    return "\(year) 年 \(month) 月 \(day) 日"
}

private func cinemaMinutesText(_ minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) 分钟" }
    return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
}

private func cinemaStatusText(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw {
    case "Released": return "已上映"
    case "Returning Series": return "连载中"
    case "Ended": return "已完结"
    case "Canceled", "Cancelled": return "已取消"
    case "In Production": return "制作中"
    case "Post Production": return "后期制作"
    case "Planned": return "已计划"
    case "Rumored": return "传闻中"
    default: return raw
    }
}

private func cinemaLanguageName(_ code: String?) -> String? {
    guard let code, !code.isEmpty else { return nil }
    let names: [String: String] = [
        "zh": "汉语", "cn": "汉语", "en": "英语", "ja": "日语", "ko": "韩语",
        "fr": "法语", "de": "德语", "es": "西班牙语", "it": "意大利语",
        "ru": "俄语", "hi": "印地语", "th": "泰语", "pt": "葡萄牙语",
        "sv": "瑞典语", "da": "丹麦语", "nl": "荷兰语", "pl": "波兰语"
    ]
    return names[code.lowercased()] ?? code.uppercased()
}

/// TMDB 国家名是英文：资料卡里换成中文，常见国家之外的保留原文。
private func cinemaCountryName(_ raw: String) -> String {
    let names: [String: String] = [
        "China": "中国", "Hong Kong": "中国香港", "Taiwan": "中国台湾",
        "Japan": "日本", "South Korea": "韩国", "Korea": "韩国",
        "United States of America": "美国", "United States": "美国",
        "United Kingdom": "英国", "France": "法国", "Germany": "德国",
        "Italy": "意大利", "Spain": "西班牙", "India": "印度",
        "Thailand": "泰国", "Canada": "加拿大", "Australia": "澳大利亚",
        "Russia": "俄罗斯", "Singapore": "新加坡", "Malaysia": "马来西亚"
    ]
    return names[raw] ?? raw
}

private func cinemaMoneyText(_ value: Int64?) -> String? {
    guard let value, value > 0 else { return nil }
    if value >= 100_000_000 {
        return String(format: "约 %.2f 亿美元", Double(value) / 100_000_000)
    }
    return String(format: "约 %.0f 万美元", Double(value) / 10_000)
}

// MARK: - 影院库（刮削后的电影 / 电视剧）

/// 影院里的详情目标：剧集 / 影片详情在页面内展示，其余面板仍用 sheet。
private enum CinemaDetailTarget: Identifiable {
    case series(CinemaSeries)
    case entry(CinemaEntry)
    case newList
    case search
    case history
    case tasks
    case notifications
    case pin
    case folder(CinemaFolder)
    case folderMatch(CinemaFolder)
    case match(CinemaEntry)

    var id: String {
        switch self {
        case .series(let series): return "series-\(series.id)"
        case .entry(let entry): return "entry-\(entry.id.uuidString)"
        case .newList: return "new-list"
        case .search: return "search"
        case .history: return "history"
        case .tasks: return "tasks"
        case .notifications: return "notifications"
        case .pin: return "pin"
        case .folder(let folder): return "folder-\(folder.id)"
        case .folderMatch(let folder): return "folder-match-\(folder.id)"
        case .match(let entry): return "match-\(entry.id.uuidString)"
        }
    }
}

/// 自动归组的合集：同一个 TMDB belongs_to_collection。
private struct CinemaCollectionGroup: Identifiable {
    let id: Int
    let name: String
    let entries: [CinemaEntry]
}

/// 海报墙的字母索引：每个首字母指向第一条内容，点击滚过去。
private struct CinemaLetterEntry: Identifiable {
    let letter: String
    let target: String
    var id: String { letter }
}

struct CinemaLibraryView: View {
    /// nil 表示本地图库的影院；有值表示某一个网盘实例自己的影院。
    let mountID: UUID?

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.openSettings) private var openSettings
    /// 打开设置时直接落在「影院」分页。
    @AppStorage(SettingsKeys.selectedTab) private var settingsTab: SettingsTab = .general

    @State private var hoveredID: UUID?
    @State private var hoveredSeriesID: String?
    /// 当前打开的详情（剧集 / 影片）：直接在页面内展示，不再单独弹窗。
    @State private var detailTarget: CinemaDetailTarget?
    /// 搜索 / 观看记录 / 任务等辅助面板仍走 sheet，和详情分开存，互不覆盖。
    @State private var panelTarget: CinemaDetailTarget?
    @State private var selectedCardID: UUID?
    @State private var selectedSeriesCardID: String?
    /// 卡片模式剧集胶片条里被选中的那一集（← → 切换，回车播放）。
    @State private var selectedEpisodeCardID: UUID?
    /// 列表模式的选中行：单击选中、双击详情、空格播放。
    @State private var selectedListEntryID: UUID?
    @State private var selectedListSeriesID: String?
    @FocusState private var cardFocus: Bool
    @FocusState private var listFocus: Bool
    /// 文件夹视图的聚合结果：按目录分组，匹配后显示影片 / 剧集名。
    @State private var folders: [CinemaFolder] = []
    @State private var foldersLoaded = false
    @State private var hoveredFolderID: String?
    @State private var scrapingFolderIDs: Set<String> = []
    /// 当前钻进到哪一层（nil 表示顶层）；可以一直点下去。
    @State private var selectedFolderPath: String?
    /// 默认单击进详情，播放交给详情页里的「播放」按钮；设置里仍可改回单击直接播放。
    @AppStorage("cinema_open_detail_on_click") private var openDetailOnClick = true
    /// 列表表头的升降序：再次点击同一列时反转，只影响列表呈现。
    @State private var listSortReversed = false
    /// F5 首次建库：用户点过「稍后再说」或已有片源后不再出现。
    @AppStorage("cinema_first_run_dismissed") private var firstRunDismissed = false

    init(mountID: UUID? = nil) {
        self.mountID = mountID
    }

    private var scope: CinemaScope { mountID.map { .mount($0) } ?? .local }

    /// 文件夹只在切到该分段时重算；匹配 / 刮削后靠 Store 的刷新信号重新聚合。
    private var folderRefreshKey: String {
        "\(store.cinemaTab.rawValue)|\(LibraryStore.cinemaScopeKey(scope))"
            + "|\(store.cinemaFolderRefreshToken)|\(store.cinemaEntries(for: scope).count)"
    }

    /// 这个链接下所有刮削过的条目（含未识别的），页面上要能看到「有视频」。
    private var allEntries: [CinemaEntry] {
        store.cinemaEntries(for: scope).values
            .sorted { $0.file.capturedAt > $1.file.capturedAt }
    }
    private var entries: [CinemaEntry] {
        allEntries.filter { store.cinemaPassesFilters($0) }
    }
    private var unmatched: [CinemaEntry] { allEntries.filter { !$0.matched } }
    private var movies: [CinemaEntry] {
        sortedEntries(dedupeVersions(entries.filter { $0.kind == .movie }))
    }

    /// 同一部电影的多版本只显示画质最好的一条；版本选择在详情页。
    private func dedupeVersions(_ list: [CinemaEntry]) -> [CinemaEntry] {
        var best: [String: CinemaEntry] = [:]
        for entry in list {
            let key = store.cinemaVersionKey(for: entry)
            if let existing = best[key],
               !store.cinemaIsBetterVersion(entry, existing) {
                continue
            }
            best[key] = entry
        }
        return Array(best.values)
    }
    /// 未识别的剧同样聚合成一张卡，避免一集一张铺满整行。
    private var unmatchedSeries: [CinemaSeries] {
        store.cinemaSeries(for: scope, matched: false)
    }
    private var unmatchedMovies: [CinemaEntry] {
        unmatched.filter { $0.kind == .movie }
    }
    /// 同一部剧的多集合并成一张卡片；筛选条件与条目列表保持一致。
    private var series: [CinemaSeries] {
        let filtered = store.cinemaSeries(for: scope).filter { store.cinemaPassesFilters($0) }
        return sortedSeries(filtered)
    }

    /// 列表模式下的显示顺序：表头再次点击时反转，不改变海报墙与卡片。
    private var listedMovies: [CinemaEntry] {
        listSortReversed ? Array(movies.reversed()) : movies
    }

    private var listedSeries: [CinemaSeries] {
        listSortReversed ? Array(series.reversed()) : series
    }

    private func sortedEntries(_ list: [CinemaEntry]) -> [CinemaEntry] {
        switch store.cinemaSort {
        case .recent:
            return list.sorted { $0.file.capturedAt > $1.file.capturedAt }
        case .rating:
            return list.sorted { lhs, rhs in
                let left = lhs.rating ?? 0
                let right = rhs.rating ?? 0
                if left == right {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        case .year:
            return list.sorted { lhs, rhs in
                let left = lhs.year ?? 0
                let right = rhs.year ?? 0
                if left == right {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        case .title:
            return list.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .duration:
            return list.sorted {
                ($0.file.duration ?? 0) > ($1.file.duration ?? 0)
            }
        }
    }

    private func sortedSeries(_ list: [CinemaSeries]) -> [CinemaSeries] {
        switch store.cinemaSort {
        case .recent:
            return list.sorted { latestDate($0) > latestDate($1) }
        case .rating:
            return list.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .year:
            return list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .title:
            return list.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .duration:
            return list.sorted { totalDuration($0) > totalDuration($1) }
        }
    }

    private func latestDate(_ series: CinemaSeries) -> Date {
        series.episodes.map(\.file.capturedAt).max() ?? .distantPast
    }

    private func totalDuration(_ series: CinemaSeries) -> Double {
        series.episodes.reduce(0) { $0 + ($1.file.duration ?? 0) }
    }

    /// 自动归组：同一 belongs_to_collection 的电影聚成合集，至少 2 部才展示。
    private var cinemaCollections: [CinemaCollectionGroup] {
        var groups: [Int: [CinemaEntry]] = [:]
        for entry in entries where entry.kind == .movie {
            guard let id = entry.collectionID else { continue }
            groups[id, default: []].append(entry)
        }
        return groups.compactMap { id, list in
            let unique = dedupeVersions(list)
            guard unique.count >= 2 else { return nil }
            return CinemaCollectionGroup(
                id: id,
                name: list.first?.collectionName ?? "合集",
                entries: unique.sorted {
                    if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var collectionShelves: some View {
        if !cinemaCollections.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(cinemaCollections) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(group.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(group.entries.count) 部")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(group.entries) { entry in
                                    posterCard(entry)
                                        .frame(width: 132)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
        }
    }

    /// 是否启用了顶栏筛选（年代 / 类型 / 分辨率 / 观看状态 / 智能 / 收藏 / 清单）。
    private var isFilteringCinema: Bool {
        !store.cinemaDecades.isEmpty
            || !store.cinemaGenres.isEmpty
            || !store.cinemaResolutions.isEmpty
            || !store.cinemaSpecFilters.isEmpty
            || !store.cinemaWatchFilters.isEmpty
            || store.cinemaSmartHighRated
            || store.cinemaSmartRecent
            || store.cinemaFavoritesOnly
            || store.cinemaActiveListID != nil
    }

    private var needsConfig: Bool {
        store.cinemaNeedsConfiguration
    }

    /// 先把分页写成「影院」，再打开设置窗口，保证一进来就是影院设置。
    private func openCinemaSettings() {
        settingsTab = .cinema
        openSettings()
    }

    var body: some View {
        ZStack {
            libraryContent
                .opacity(detailTarget == nil ? 1 : 0)
                .allowsHitTesting(detailTarget == nil)
            if let target = detailTarget {
                inlineDetail(target)
                    // 详情之间直接切换（例如合集里的下一部）时重建状态，
                    // 否则 TMDB 补全结果会停在上一个条目上。
                    .id(target.id)
                    .transition(.opacity)
            }
        }
        // 顶栏控制台按这里的读数折叠；探针留在页面内容里，控制台被系统隐藏时也能恢复。
        .background {
            CinemaToolbarWidthReader { width in
                if abs(width - store.cinemaAvailableWidth) > 1 {
                    store.cinemaAvailableWidth = width
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: detailTarget?.id)
        // 列表留在下层，但它仍持有键盘焦点：进详情时交出去，
        // 否则空格 / 回车会被看不见的海报墙截走。
        .onChange(of: detailTarget?.id) { _, current in
            store.cinemaDetailOpen = current != nil
            if current == nil {
                if store.cinemaViewMode == .list { listFocus = true } else { cardFocus = true }
            } else {
                cardFocus = false
                listFocus = false
            }
        }
        // 播放器打开期间把键盘焦点交出去：否则回车 / 空格会被看不见的海报墙截走。
        .onChange(of: store.viewerID) { _, viewing in
            if viewing != nil {
                cardFocus = false
                listFocus = false
            } else if detailTarget == nil {
                if store.cinemaViewMode == .list { listFocus = true } else { cardFocus = true }
            }
        }
        // 顶栏「返回」由详情页自己逐层消费（演职员 → 详情 → 列表）。
        .onDisappear { store.cinemaDetailOpen = false }
    }

    /// 内嵌的剧集 / 影片详情：铺满影院页面，返回后回到原来的列表位置。
    @ViewBuilder
    private func inlineDetail(_ target: CinemaDetailTarget) -> some View {
        switch target {
        case .series(let item):
            CinemaSeriesDetailView(
                series: item,
                onPlay: { store.openCinema($0) },
                onOpenEntry: { detailTarget = .entry($0) },
                onClose: { detailTarget = nil }
            )
            .environmentObject(store)
        case .entry(let entry):
            CinemaDetailView(
                entry: entry,
                onOpenEntry: { detailTarget = .entry($0) },
                onClose: { detailTarget = nil }
            )
            .environmentObject(store)
        default:
            EmptyView()
        }
    }

    /// 书架 / 海报墙 / 列表本体：详情打开时留在下层，关掉后滚动位置不丢。
    private var libraryContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if needsConfig {
                        setupBanner
                    }
                    if store.cinemaScrapeRunning, store.cinemaScrapeScope == scope {
                        progressBar
                    } else if let message = store.cinemaScrapeMessage {
                        statusBanner(message)
                    }
                    content
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .topTrailing) {
                CinemaToastStack()
                    .environmentObject(store)
            }
            .overlay(alignment: .trailing) {
                wallLetterRail(proxy)
            }
        .task(id: scope) {
            // 换片源时收掉详情，避免显示上一个来源的剧集 / 影片。
            detailTarget = nil
            // 兜底：播放失败可能留下「viewerID 有值、但照片已找不到」的幽灵查看器，
            // 它会让顶栏整体让位给查看器，导致影院控制台消失。
            if store.viewerPhoto == nil, store.viewerID != nil {
                store.viewerID = nil
            }
            // 视频全屏标记若在退出系统全屏时没被复位，也会让整个窗口工具栏消失；
            // 回到影院说明已不在全屏，顺手复位。
            if store.viewerModel.videoImmersiveFullScreen,
               NSApp.keyWindow?.styleMask.contains(.fullScreen) != true {
                store.viewerModel.videoImmersiveFullScreen = false
            }
            // 只切换影院的作用域，不顺带刮削：影院和「视频」是两个入口，
            // 打开影院不应该等于把这个链接下的视频扫一遍，刮削只由显式点击触发。
            store.activateCinemaScope(scope)
        }
        .task(id: folderRefreshKey) {
            guard store.cinemaTab == .folder else { return }
            foldersLoaded = false
            await Task.yield()
            folders = store.cinemaFolders(for: scope)
            foldersLoaded = true
            syncFolderSelection()
        }
        // 只有面板走 sheet；剧集 / 影片详情已经改成页面内展示。
        .sheet(item: $panelTarget) { target in
            switch target {
            case .newList:
                CinemaNewListSheet { name in
                    store.createCinemaList(named: name)
                    panelTarget = nil
                } onCancel: {
                    panelTarget = nil
                }
                .environmentObject(store)
            case .search:
                CinemaSearchPanel { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        openDetail(entry)
                    }
                } onOpenSeries: { item in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        detailTarget = .series(item)
                    }
                } onPlay: { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        store.openCinema(entry)
                    }
                }
                .environmentObject(store)
            case .history:
                CinemaHistoryPanel(scope: scope) { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        store.openCinema(entry)
                    }
                }
                .environmentObject(store)
            case .tasks:
                CinemaTaskCenterSheet()
                    .environmentObject(store)
            case .notifications:
                CinemaNotificationSheet()
                    .environmentObject(store)
            case .pin:
                CinemaPINPromptSheet()
                    .environmentObject(store)
            case .folder(let folder):
                CinemaFolderDetailView(folder: folder,
                                       scope: scope,
                                       onPlay: { entry in
                                           panelTarget = nil
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                               store.openCinema(entry)
                                           }
                                       },
                                       onOpenEntry: { entry in
                                           panelTarget = nil
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                               detailTarget = .entry(entry)
                                           }
                                       })
                .environmentObject(store)
            case .folderMatch(let folder):
                CinemaMatchSheet(photos: folder.subtreePhotos, folderHint: folder.hint) {
                    panelTarget = nil
                    refreshFolders()
                }
                .environmentObject(store)
            case .match(let entry):
                CinemaMatchSheet(entry: entry) {
                    panelTarget = nil
                    refreshFolders()
                }
                .environmentObject(store)
            case .series, .entry:
                // 详情页不再走弹窗，这里只是让 switch 保持穷尽。
                EmptyView()
            }
        }
        // 顶栏按钮通过 Store 旗标请求面板；这里统一转成单 sheet，避免多个 sheet 互相覆盖。
        .onChange(of: store.cinemaSearchVisible) { _, visible in
            guard visible else { return }
            store.cinemaSearchVisible = false
            panelTarget = .search
        }
        .onChange(of: store.cinemaHistoryVisible) { _, visible in
            guard visible else { return }
            store.cinemaHistoryVisible = false
            panelTarget = .history
        }
        .onChange(of: store.cinemaNewListVisible) { _, visible in
            guard visible else { return }
            store.cinemaNewListVisible = false
            panelTarget = .newList
        }
        .onChange(of: store.cinemaTasksVisible) { _, visible in
            guard visible else { return }
            store.cinemaTasksVisible = false
            panelTarget = .tasks
        }
        .onChange(of: store.cinemaNotificationsVisible) { _, visible in
            guard visible else { return }
            store.cinemaNotificationsVisible = false
            panelTarget = .notifications
        }
        .onChange(of: store.cinemaPINPromptVisible) { _, visible in
            guard visible else { return }
            store.cinemaPINPromptVisible = false
            panelTarget = .pin
        }
        }
    }

    // MARK: 空状态 / 进度

    private var setupBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 20))
                .foregroundStyle(LumaBrand.violet)
            VStack(alignment: .leading, spacing: 5) {
                Text("先填写 TMDB API Key，再开始刮削")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("影院会用文件名匹配电影 / 剧集，自动补上海报、背景图、年份与简介。TMDB 需要一个免费 Key；也可以切成豆瓣数据源，免 Key 直接刮。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("打开设置 › 影院", action: openCinemaSettings)
                    Button("打开 TMDB 申请页") {
                        open("https://www.themoviedb.org/settings/api")
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(LumaBrand.violet.opacity(0.10)))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(LumaBrand.violet.opacity(0.22))
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在刮削这个链接下的视频  \(store.cinemaScrapeDone) / \(store.cinemaScrapeTotal)")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Int(store.cinemaScrapeProgress * 100))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: store.cinemaScrapeProgress)
                .controlSize(.small)
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if store.cinemaTab == .folder {
            folderContent
        } else if allEntries.isEmpty {
            if showFirstRun {
                firstRunView
            } else {
                emptyState
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if store.cinemaActiveListID != nil {
                    activeListBanner
                }
                if store.cinemaViewMode == .wall {
                    wallStatsBar
                        .padding(.top, -6)
                }
                switch store.cinemaViewMode {
                case .shelf:
                    shelfContent
                case .wall:
                    wallContent
                case .card:
                    cardContent
                case .list:
                    listContent
                }
            }
        }
    }

    @ViewBuilder
    private var activeListBanner: some View {
        if let list = store.cinemaList(store.cinemaActiveListID) {
            HStack(spacing: 8) {
                Image(systemName: list.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("清单 · \(list.name)")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(list.count) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("清除筛选") {
                    store.cinemaActiveListID = nil
                }
                .controlSize(.small)
                Button("删除清单", role: .destructive) {
                    store.deleteCinemaList(list.id)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(LumaBrand.amber.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.8)
            }
        }
    }

    // MARK: 书架

    @ViewBuilder
    private var shelfContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .all:
            if !store.cinemaContinueRecords(for: scope).isEmpty {
                continueShelf
            }
            categoryRow
            if !movies.isEmpty {
                shelf("最近添加", Array(movies.prefix(18)))
                shelf("高分电影", Array(movies.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(18)))
            }
            if !series.isEmpty {
                seriesShelf("剧集", series)
            }
            collectionShelves
            if !store.cinemaLists.isEmpty {
                myListsShelf
            }
            if series.isEmpty, movies.isEmpty, isFilteringCinema {
                filterEmptyState
            }
            // 没匹配上的也摆出来，否则「有 67 个视频但影院是空的」看起来像刮削没跑。
            // 筛选生效时它们没有年份 / 类型可比，先收起来。
            if !isFilteringCinema, !unmatched.isEmpty {
                unmatchedShelf
            }
        case .movies:
            if movies.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电影")
                }
            } else {
                hero(entries: movies)
                collectionShelves
                shelf("最近添加", Array(movies.prefix(18)))
                shelf("高分电影", Array(movies.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(18)))
            }
        case .shows:
            if series.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatchedSeries.isEmpty {
                    // 一集都没识别上时也按剧聚合展示，而不是给一张空页。
                    unmatchedShelf
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电视剧")
                }
            } else {
                seriesHero()
                seriesShelf("全部剧集", series)
                if !isFilteringCinema, !unmatchedSeries.isEmpty {
                    unmatchedShelf
                }
            }
        }
    }

    // MARK: 分类行

    /// 首页第一行分类：全部 / 收藏 / 最近 30 天 / 高分 8+，点一下直接切筛选。
    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("分类")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    categoryChip("全部",
                                 icon: "square.grid.2x2.fill",
                                 count: allEntries.count,
                                 active: !store.cinemaFavoritesOnly
                                     && !store.cinemaSmartRecent
                                     && !store.cinemaSmartHighRated) {
                        store.resetCinemaFilters()
                    }
                    categoryChip("收藏",
                                 icon: "heart.fill",
                                 count: categoryFavoriteCount,
                                 active: store.cinemaFavoritesOnly) {
                        store.cinemaFavoritesOnly.toggle()
                    }
                    categoryChip("最近 30 天",
                                 icon: "clock.fill",
                                 count: categoryRecentCount,
                                 active: store.cinemaSmartRecent) {
                        store.cinemaSmartRecent.toggle()
                    }
                    categoryChip("高分 8+",
                                 icon: "star.fill",
                                 count: categoryHighRatedCount,
                                 active: store.cinemaSmartHighRated) {
                        store.cinemaSmartHighRated.toggle()
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var categoryFavoriteCount: Int {
        allEntries.filter { store.cinemaUserState(for: $0.id).favorite }.count
    }

    private var categoryRecentCount: Int {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        return allEntries.filter { $0.file.capturedAt >= cutoff }.count
    }

    private var categoryHighRatedCount: Int {
        allEntries.filter { ($0.rating ?? 0) >= 8 }.count
    }

    private func categoryChip(_ title: String,
                              icon: String,
                              count: Int,
                              active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(active ? LumaBrand.amber.opacity(0.18) : Color.primary.opacity(0.05))
                    Circle()
                        .strokeBorder(active ? LumaBrand.amber.opacity(0.5) : Color.primary.opacity(0.08),
                                      lineWidth: 0.8)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                }
                .frame(width: 48, height: 48)
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) · \(count) 部")
    }

    // MARK: 文件夹

    private var folderColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16, alignment: .top)]
    }

    private var folderVideoColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 158, maximum: 194), spacing: 12, alignment: .top)]
    }

    /// 整棵文件夹树按路径索引：钻取、面包屑和刷新后的兜底都靠它。
    private var folderIndex: [String: CinemaFolder] {
        var result: [String: CinemaFolder] = [:]
        func walk(_ folder: CinemaFolder) {
            result[folder.path] = folder
            for child in folder.children { walk(child) }
        }
        folders.forEach(walk)
        return result
    }

    private var currentFolder: CinemaFolder? {
        selectedFolderPath.flatMap { folderIndex[$0] }
    }

    private var visibleFolders: [CinemaFolder] {
        currentFolder?.children ?? folders
    }

    /// 从顶层到当前目录的路径链，用于面包屑。
    private var breadcrumbPaths: [String] {
        guard let selected = selectedFolderPath else { return [] }
        let index = folderIndex
        var paths: [String] = []
        var cursor: String? = selected
        while let current = cursor, let folder = index[current] {
            paths.append(current)
            cursor = folder.parentPath
        }
        return paths.reversed()
    }

    @ViewBuilder
    private var folderContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            folderHeader

            if !foldersLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理文件夹…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if folders.isEmpty {
                folderPlaceholder("还没有可聚合的文件夹",
                                  detail: "先在相簿里扫描这个网盘，或点击顶栏「刮削」生成影院条目。")
            } else if selectedFolderPath != nil, currentFolder == nil {
                folderPlaceholder("这个目录已不存在",
                                  detail: "可能刚被删除或重新扫描过了。")
                Button("返回顶层") { goToRoot() }
                    .controlSize(.small)
            } else {
                folderLevel
            }
        }
    }

    @ViewBuilder
    private var folderLevel: some View {
        if !visibleFolders.isEmpty {
            LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 16) {
                ForEach(visibleFolders) { folder in
                    folderCard(folder)
                }
            }
        } else if let currentFolder, currentFolder.photos.isEmpty {
            folderPlaceholder("这个目录里没有视频",
                              detail: "换一层看看，或回到顶层重新扫描。")
        }

        if let currentFolder, !currentFolder.photos.isEmpty {
            folderVideosSection(currentFolder)
        }
    }

    private func folderPlaceholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if currentFolder != nil {
                    Button {
                        goUp()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("返回上一级")
                }
                Text(currentFolder?.displayTitle ?? "文件夹")
                    .font(.system(size: 15, weight: .semibold))
                Text(folderHeadline)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("按目录聚合 · 点进文件夹可一直往下钻")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                if let currentFolder {
                    if scrapingFolderIDs.contains(currentFolder.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            quickScrapeFolder(currentFolder)
                        } label: {
                            Label("刮削本目录", systemImage: "wand.and.stars")
                        }
                        .controlSize(.small)
                        .disabled(currentFolder.subtreePhotos.isEmpty)
                        Button {
                            panelTarget = .folderMatch(currentFolder)
                        } label: {
                            Label("匹配…", systemImage: "magnifyingglass")
                        }
                        .controlSize(.small)
                        .disabled(currentFolder.subtreePhotos.isEmpty)
                    }
                }
                Button {
                    refreshFolders()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            breadcrumb
        }
    }

    private var folderHeadline: String {
        if let currentFolder {
            return "\(currentFolder.photos.count) 个视频 · \(currentFolder.children.count) 个子目录"
        }
        return "\(folders.count) 个顶层目录"
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if currentFolder != nil {
            HStack(spacing: 5) {
                Button("全部文件夹") { goToRoot() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(breadcrumbPaths, id: \.self) { path in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Button(folderIndex[path]?.name ?? LibraryStore.cinemaFolderName(of: path)) {
                        selectedFolderPath = path
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: path == selectedFolderPath ? .semibold : .medium))
                    .foregroundStyle(path == selectedFolderPath ? LumaBrand.amber : Color.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let path = currentFolder?.displayPath {
                    Text(path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: Capsule())
        }
    }

    private func folderCard(_ folder: CinemaFolder) -> some View {
        let hovered = hoveredFolderID == folder.id
        let scraping = scrapingFolderIDs.contains(folder.id)

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = folder.backdropURL ?? folder.posterURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else if let photo = folder.firstPhoto {
                        PhotoThumbnailView(photo: photo, purpose: .cover(420))
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 158)
                .clipped()

                LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.30), .black.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text(folder.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if folder.hasChildren {
                            Text("\(folder.children.count) 个子文件夹")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        if let kind = folder.kind {
                            Text(kind == .tv ? "剧集" : "电影")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))

                    Text(folder.displayTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(folderStatusText(folder))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            Text(folder.hasChildren ? "进入" : "查看")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if scraping {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .padding(6)
                            .background(.black.opacity(0.35), in: Circle())
                    } else {
                        folderActionButton("wand.and.stars", help: "刮削这个目录（含子目录）") {
                            quickScrapeFolder(folder)
                        }
                        folderActionButton("magnifyingglass", help: "手动匹配这个目录") {
                            panelTarget = .folderMatch(folder)
                        }
                    }
                }
                .padding(8)
                .opacity(hovered ? 1 : 0.55)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(folder.isMatched ? LumaBrand.amber : Color.secondary.opacity(0.6))
                    .frame(width: 4, height: 4)
                Text(folder.matchedCount > 0 ? "\(folder.matchedCount) 已识别" : "未识别")
                    .foregroundStyle(folder.isMatched ? LumaBrand.amber : Color.secondary)
                if folder.unmatchedCount > 0 {
                    Text("· \(folder.unmatchedCount) 未识别")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(folder.totalCount) 个视频")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.primary.opacity(0.08),
                              lineWidth: hovered ? 1 : 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            enterFolder(folder)
        }
        .onHover { hovering in
            if hovering {
                hoveredFolderID = folder.id
            } else if hoveredFolderID == folder.id {
                hoveredFolderID = nil
            }
        }
        .contextMenu {
            Button("进入文件夹") { enterFolder(folder) }
            Button("目录详情…") { panelTarget = .folder(folder) }
            Divider()
            Button(folder.subtreePhotos.isEmpty
                   ? "刮削此目录"
                   : "刮削此目录（\(folder.subtreePhotos.count) 个视频）") {
                quickScrapeFolder(folder)
            }
            Button("手动匹配此目录…") { panelTarget = .folderMatch(folder) }
            Divider()
            Button("在影院中查看") {
                if let mountID = folder.mountID {
                    store.navigate(to: .cloudCinema(mountID))
                } else {
                    store.navigate(to: .cinema)
                }
            }
        }
        .help(folder.displayPath)
    }

    /// 当前目录直属的视频：钻到最里层时直接平铺，不用再开面板。
    private func folderVideosSection(_ folder: CinemaFolder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("本目录视频")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(folder.photos.count) 个")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: folderVideoColumns, alignment: .leading, spacing: 12) {
                ForEach(folder.photos) { photo in
                    folderVideoTile(photo)
                }
            }
        }
    }

    private func folderVideoTile(_ photo: PhotoItem) -> some View {
        let entry = store.cinemaEntries(for: scope)[photo.id]
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = entry?.gridArtworkURL ?? entry?.artworkURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        PhotoThumbnailView(photo: photo, purpose: .cover(190))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .clipped()

                LinearGradient(colors: [.black.opacity(0.42), .clear],
                               startPoint: .bottom, endPoint: .top)
                Text(entry?.matched == true ? "已识别" : "未识别")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background((entry?.matched == true ? LumaBrand.amber : Color.black).opacity(0.85),
                                in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(entry?.title ?? photo.displayFilename)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(photo.displayFilename)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let entry {
                detailTarget = .entry(entry)
            } else {
                store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: [photo])
            }
        }
        .contextMenu {
            if let entry {
                Button("播放") { store.openCinema(entry) }
                Button("详情") { detailTarget = .entry(entry) }
                Divider()
            }
            Button("手动匹配…") {
                store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: [photo])
            }
            Button(entry == nil ? "刮削" : "重新刮削") {
                Task { await store.scrapeCinemaPhotos([photo]) }
            }
        }
        .help(photo.displayFilename)
    }

    private func folderActionButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.42), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func folderStatusText(_ folder: CinemaFolder) -> String {
        var parts: [String] = [folder.displayPath]
        if folder.hasChildren {
            parts.append("\(folder.children.count) 个子目录")
        }
        return parts.joined(separator: " · ")
    }

    private func quickScrapeFolder(_ folder: CinemaFolder) {
        guard !scrapingFolderIDs.contains(folder.id) else { return }
        scrapingFolderIDs.insert(folder.id)
        Task {
            await store.scrapeCinemaFolder(folder, scope: scope)
            refreshFolders()
            scrapingFolderIDs.remove(folder.id)
        }
    }

    private func refreshFolders() {
        foldersLoaded = false
        folders = store.cinemaFolders(for: scope)
        foldersLoaded = true
        syncFolderSelection()
    }

    /// 刷新后如果当前目录已不存在（重扫 / 换盘），回到顶层。
    private func syncFolderSelection() {
        guard let selected = selectedFolderPath else { return }
        if folderIndex[selected] == nil {
            selectedFolderPath = nil
        }
    }

    private func enterFolder(_ folder: CinemaFolder) {
        selectedFolderPath = folder.path
    }

    private func goUp() {
        guard let current = currentFolder else { return }
        selectedFolderPath = current.parentPath.flatMap { folderIndex[$0] }?.path
    }

    private func goToRoot() {
        selectedFolderPath = nil
    }

    // MARK: 海报墙

    /// 列宽交给网格自适应，卡片按列宽铺满（不再固定 156 塞进更宽的格子，
    /// 否则每张卡右边会多出一条空白，看着像缩略图没铺满）。
    private var wallColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 156), spacing: 16, alignment: .top)]
    }

    @ViewBuilder
    private var wallContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .all:
            if !series.isEmpty {
                wallSection("电视剧", count: series.count) {
                    ForEach(series) { item in
                        CinemaSeriesCard(series: item,
                                         hovered: hoveredSeriesID == item.id,
                                         fillWidth: true) { hovering in
                            hoveredSeriesID = hovering
                                ? item.id
                                : (hoveredSeriesID == item.id ? nil : hoveredSeriesID)
                        } onOpen: {
                            detailTarget = .series(item)
                        }
                    }
                }
            }
            if !movies.isEmpty {
                wallSection("电影", count: movies.count) {
                    ForEach(movies) { entry in
                        posterCard(entry, fillWidth: true)
                    }
                }
            }
            if series.isEmpty, movies.isEmpty, isFilteringCinema {
                filterEmptyState
            }
            if !isFilteringCinema, !unmatched.isEmpty {
                wallSection("未识别 · 可右键重新刮削",
                            count: unmatchedSeries.count + unmatchedMovies.count) {
                    ForEach(unmatchedSeries) { item in
                        CinemaSeriesCard(series: item,
                                         hovered: hoveredSeriesID == item.id,
                                         fillWidth: true) { hovering in
                            hoveredSeriesID = hovering
                                ? item.id
                                : (hoveredSeriesID == item.id ? nil : hoveredSeriesID)
                        } onOpen: {
                            detailTarget = .series(item)
                        }
                    }
                    ForEach(unmatchedMovies) { entry in
                        posterCard(entry, fillWidth: true)
                    }
                }
            }
        case .movies:
            if movies.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电影")
                }
            } else {
                wallSection("电影", count: movies.count) {
                    ForEach(movies) { entry in
                        posterCard(entry, fillWidth: true)
                    }
                }
            }
        case .shows:
            if series.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatchedSeries.isEmpty {
                    wallSection("未识别 · 可右键重新刮削", count: unmatchedSeries.count) {
                        ForEach(unmatchedSeries) { item in
                            CinemaSeriesCard(series: item,
                                             hovered: hoveredSeriesID == item.id,
                                             fillWidth: true) { hovering in
                                hoveredSeriesID = hovering
                                    ? item.id
                                    : (hoveredSeriesID == item.id ? nil : hoveredSeriesID)
                            } onOpen: {
                                detailTarget = .series(item)
                            }
                        }
                    }
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电视剧")
                }
            } else {
                wallSection("全部剧集", count: series.count) {
                    ForEach(series) { item in
                        CinemaSeriesCard(series: item,
                                         hovered: hoveredSeriesID == item.id,
                                         fillWidth: true) { hovering in
                            hoveredSeriesID = hovering
                                ? item.id
                                : (hoveredSeriesID == item.id ? nil : hoveredSeriesID)
                        } onOpen: {
                            detailTarget = .series(item)
                        }
                    }
                }
            }
        }
    }

    private func posterCard(_ entry: CinemaEntry, fillWidth: Bool = false) -> some View {
        CinemaPosterCard(entry: entry,
                         hovered: hoveredID == entry.id,
                         fillWidth: fillWidth,
                         onHover: { hovering in
                             hoveredID = hovering
                                 ? entry.id
                                 : (hoveredID == entry.id ? nil : hoveredID)
                         },
                         onOpen: {
                             if openDetailOnClick {
                                 openDetail(entry)
                             } else {
                                 store.openCinema(entry)
                             }
                         },
                         onPlay: { store.openCinema(entry) },
                         onDetail: { openDetail(entry) })
            .id(entry.id)
    }

    private func wallSection<Content: View>(_ title: String,
                                            count: Int,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: wallColumns, alignment: .leading, spacing: 18) {
                content()
            }
        }
    }

    // MARK: 卡片模式

    @ViewBuilder
    private var cardContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .movies:
            movieCardContent
        case .shows:
            seriesCardContent
        case .all:
            if !movies.isEmpty {
                movieCardContent
            } else if !series.isEmpty {
                seriesCardContent
            } else if isFilteringCinema {
                filterEmptyState
            } else {
                tabEmptyState("还没有可展示的影片")
            }
        }
    }

    private var selectedMovie: CinemaEntry? {
        movies.first(where: { $0.id == selectedCardID }) ?? movies.first
    }

    private var selectedSeries: CinemaSeries? {
        series.first(where: { $0.id == selectedSeriesCardID }) ?? series.first
    }

    @ViewBuilder
    private var movieCardContent: some View {
        if movies.isEmpty {
            if isFilteringCinema {
                filterEmptyState
            } else {
                tabEmptyState("还没有识别到电影")
            }
        } else if let selected = selectedMovie {
            VStack(alignment: .leading, spacing: 14) {
                movieFeature(selected)
                movieStrip(selected)
            }
            .focusable()
            .focused($cardFocus)
            .onAppear { cardFocus = true }
            .onKeyPress(.leftArrow) {
                stepMovieSelection(-1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                stepMovieSelection(1)
                return .handled
            }
            .onKeyPress(.space) {
                guard store.viewerID == nil else { return .ignored }
                if let entry = selectedMovie { store.openCinema(entry) }
                return .handled
            }
            .onKeyPress(.return) {
                guard store.viewerID == nil else { return .ignored }
                if let entry = selectedMovie { store.openCinema(entry) }
                return .handled
            }
        }
    }

    /// 卡片模式：胶片条与海报墙共用顺序，← → 切换影片，回车播放。
    private func stepMovieSelection(_ delta: Int) {
        guard !movies.isEmpty else { return }
        let current = movies.firstIndex(where: { $0.id == selectedMovie?.id }) ?? 0
        let next = min(max(current + delta, 0), movies.count - 1)
        selectedCardID = movies[next].id
    }

    @ViewBuilder
    private var seriesCardContent: some View {
        if series.isEmpty {
            if isFilteringCinema {
                filterEmptyState
            } else {
                tabEmptyState("还没有识别到电视剧")
            }
        } else if let selected = selectedSeries {
            VStack(alignment: .leading, spacing: 14) {
                seriesFeature(selected)
                episodeStrip(selected)
            }
            .focusable()
            .focused($cardFocus)
            .onAppear { cardFocus = true }
            .onKeyPress(.leftArrow) {
                stepEpisodeSelection(selected, delta: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                stepEpisodeSelection(selected, delta: 1)
                return .handled
            }
            .onKeyPress(.space) {
                guard store.viewerID == nil else { return .ignored }
                if let episode = selectedEpisode(in: selected) { store.openCinema(episode) }
                return .handled
            }
            .onKeyPress(.return) {
                guard store.viewerID == nil else { return .ignored }
                if let episode = selectedEpisode(in: selected) { store.openCinema(episode) }
                return .handled
            }
        }
    }

    private func selectedEpisode(in item: CinemaSeries) -> CinemaEntry? {
        item.episodes.first(where: { $0.id == selectedEpisodeCardID }) ?? item.episodes.first
    }

    private func stepEpisodeSelection(_ item: CinemaSeries, delta: Int) {
        guard !item.episodes.isEmpty else { return }
        let current = item.episodes.firstIndex(where: { $0.id == selectedEpisode(in: item)?.id }) ?? 0
        let next = min(max(current + delta, 0), item.episodes.count - 1)
        selectedEpisodeCardID = item.episodes[next].id
    }

    private func movieFeature(_ entry: CinemaEntry) -> some View {
        HStack(alignment: .top, spacing: 18) {
            posterArtwork(url: entry.posterURL, fallback: entry.file.photoItem)
                .frame(width: 168, height: 252)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(2)
                if let original = entry.originalTitle, !original.isEmpty {
                    Text(original.uppercased())
                        .font(.system(size: 9.5, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    if let rating = entry.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(LumaBrand.amber)
                    }
                    if let year = entry.year { Text(String(year)) }
                    if let genres = entry.genres, !genres.isEmpty {
                        Text(Array(genres.prefix(3)).joined(separator: " / "))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    featureChip(entrySpec(entry))
                    if entry.file.fileSize > 0 {
                        featureChip(ByteCountFormatter.string(fromByteCount: entry.file.fileSize,
                                                              countStyle: .file))
                    }
                    if store.cinemaVersionCount(for: entry) > 1 {
                        featureChip("\(store.cinemaVersionCount(for: entry)) 版本")
                    }
                }

                if let record = store.cinemaProgress[entry.id], record.fraction > 0.01 {
                    HStack(spacing: 8) {
                        ProgressView(value: record.fraction)
                            .tint(LumaBrand.amber)
                            .frame(maxWidth: 220)
                        Text("已看 \(Int(record.fraction * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        store.openCinema(entry)
                    } label: {
                        Label(store.cinemaProgress[entry.id] == nil ? "播放" : "继续播放",
                              systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(LumaBrand.amber, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    Button {
                        openDetail(entry)
                    } label: {
                        Label("详情", systemImage: "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        }
    }

    private func movieStrip(_ selected: CinemaEntry) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(movies) { entry in
                    Button {
                        selectedCardID = entry.id
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            stripArtwork(url: entry.backdropURL ?? entry.posterURL,
                                         fallback: entry.file.photoItem,
                                         finished: store.cinemaProgress[entry.id]?.isFinished == true)
                            Text(entry.title)
                                .font(.system(size: 10.5, weight: selected.id == entry.id ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(5)
                        .background(selected.id == entry.id ? LumaBrand.amber.opacity(0.12)
                                                             : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected.id == entry.id ? LumaBrand.amber.opacity(0.45)
                                                                      : Color.clear,
                                              lineWidth: 0.8)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func seriesFeature(_ item: CinemaSeries) -> some View {
        let resume = resumeEpisode(for: item)
        let hasProgress = resume
            .flatMap { store.cinemaProgress[$0.id] }
            .map { $0.fraction > 0.01 && !$0.isFinished } ?? false
        return HStack(alignment: .top, spacing: 18) {
            posterArtwork(url: item.posterURL, fallback: item.latestEpisode?.file.photoItem)
                .frame(width: 168, height: 252)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if let rating = item.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(LumaBrand.amber)
                    }
                    if let year = item.year { Text(String(year)) }
                    Text("\(item.episodeCount) 集")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        if let resume {
                            store.openCinema(resume)
                        }
                    } label: {
                        Label(hasProgress ? "继续播放" : "开始观看", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(LumaBrand.amber, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    Button {
                        detailTarget = .series(item)
                    } label: {
                        Label("查看剧集", systemImage: "list.bullet")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        }
    }

    private func episodeStrip(_ item: CinemaSeries) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(item.episodes) { episode in
                    let isCurrent = selectedEpisode(in: item)?.id == episode.id
                    Button {
                        selectedEpisodeCardID = episode.id
                        store.openCinema(episode)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            stripArtwork(url: episode.backdropURL ?? episode.posterURL,
                                         fallback: episode.file.photoItem,
                                         finished: store.cinemaProgress[episode.id]?.isFinished == true)
                            Text(episode.subtitle.isEmpty ? episode.title : episode.subtitle)
                                .font(.system(size: 10.5, weight: isCurrent ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(5)
                        .background(isCurrent ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isCurrent ? LumaBrand.amber.opacity(0.45) : Color.clear,
                                              lineWidth: 0.8)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 3)
        }
    }

    /// 胶片条缩略图：已看整块压暗并打勾，颜色与列表状态点一致。
    private func stripArtwork(url: String?, fallback: PhotoItem?, finished: Bool) -> some View {
        ZStack {
            posterArtwork(url: url, fallback: fallback)
            if finished {
                Color.black.opacity(0.55)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: 124, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func featureChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func posterArtwork(url: String?, fallback: PhotoItem?) -> some View {
        if let url {
            CinemaArtwork(urlString: url, contentMode: .fill)
        } else if let fallback {
            PhotoThumbnailView(photo: fallback, purpose: .cover(260))
        } else {
            Color.primary.opacity(0.06)
        }
    }

    // MARK: 列表

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            listHeader
            Divider().opacity(0.5)
            switch store.cinemaTab {
            case .folder:
                EmptyView()
            case .all:
                if !series.isEmpty {
                    ForEach(listedSeries) { item in
                        seriesListRow(item, badge: "剧集")
                    }
                    Divider().opacity(0.4)
                }
                if !movies.isEmpty {
                    ForEach(listedMovies) { entry in
                        entryListRow(entry)
                    }
                }
                if series.isEmpty, movies.isEmpty, isFilteringCinema {
                    filterEmptyState
                }
                if !isFilteringCinema, !unmatched.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(unmatchedSeries) { item in
                        seriesListRow(item, badge: "未识别")
                    }
                    ForEach(unmatchedMovies) { entry in
                        entryListRow(entry)
                    }
                }
            case .movies:
                if movies.isEmpty {
                    if isFilteringCinema {
                        filterEmptyState
                    } else {
                        tabEmptyState("还没有识别到电影")
                    }
                } else {
                    ForEach(listedMovies) { entry in
                        entryListRow(entry)
                    }
                }
            case .shows:
                if series.isEmpty {
                    if isFilteringCinema {
                        filterEmptyState
                    } else if !unmatchedSeries.isEmpty {
                        ForEach(unmatchedSeries) { item in
                            seriesListRow(item, badge: "未识别")
                        }
                    } else {
                        tabEmptyState("还没有识别到电视剧")
                    }
                } else {
                    ForEach(listedSeries) { item in
                        seriesListRow(item, badge: "剧集")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable()
        .focused($listFocus)
        .onAppear { listFocus = true }
        .onKeyPress(.space) {
            guard store.viewerID == nil else { return .ignored }
            playSelectedListRow()
            return .handled
        }
        .onKeyPress(.return) {
            guard store.viewerID == nil else { return .ignored }
            openSelectedListRow()
            return .handled
        }
    }

    private func seriesListRow(_ item: CinemaSeries, badge: String) -> some View {
        let watched = watchedEpisodeCount(item)
        return CinemaListRow(artworkURL: item.artworkURL,
                      fallbackPhoto: item.latestEpisode?.file.photoItem,
                      title: item.title,
                      subtitle: resumeSubtitle(for: item) ?? item.subtitle,
                      year: item.year.map(String.init) ?? "—",
                      rating: item.rating,
                      genres: item.latestEpisode?.genres?.joined(separator: " / ") ?? "—",
                      spec: watched > 0 ? "\(watched)/\(item.episodeCount) 集" : "\(item.episodeCount) 集",
                      badge: badge,
                      progress: nil,
                      onOpen: { detailTarget = .series(item) },
                      selected: selectedListSeriesID == item.id,
                      onSelect: {
                          selectedListEntryID = nil
                          selectedListSeriesID = item.id
                      },
                      onPlay: { if let target = resumeEpisode(for: item) { store.openCinema(target) } },
                      singleClickOpensDetail: openDetailOnClick)
    }

    /// 上次播放优先：进行中的一集 → 最后看完的下一集 → 第一集。
    private func resumeEpisode(for item: CinemaSeries) -> CinemaEntry? {
        let ordered = item.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
        if let inProgress = ordered.first(where: { store.cinemaWatchState(for: $0) == .inProgress }) {
            return inProgress
        }
        if let last = ordered.lastIndex(where: { store.cinemaWatchState(for: $0) == .finished }),
           last + 1 < ordered.count {
            return ordered[last + 1]
        }
        return ordered.first ?? item.latestEpisode
    }

    private func watchedEpisodeCount(_ item: CinemaSeries) -> Int {
        item.episodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
    }

    /// 列表副标题：有进行中的一集时优先显示「上次看到 SxxExx · 已看 yy%」。
    private func resumeSubtitle(for item: CinemaSeries) -> String? {
        guard let target = resumeEpisode(for: item),
              let progress = store.cinemaProgress[target.id],
              progress.fraction > 0.01, !progress.isFinished else { return nil }
        let label: String
        if let season = target.season, let episode = target.episode {
            label = String(format: "S%02dE%02d", season, episode)
        } else if let episode = target.episode {
            label = "第 \(episode) 集"
        } else {
            label = "上次"
        }
        return "上次看到 \(label) · 已看 \(Int(progress.fraction * 100))%"
    }

    private func selectedListSeries() -> CinemaSeries? {
        guard let id = selectedListSeriesID else { return nil }
        return (series + unmatchedSeries).first(where: { $0.id == id })
    }

    private func selectedListEntry() -> CinemaEntry? {
        guard let id = selectedListEntryID else { return nil }
        return (movies + unmatchedMovies).first(where: { $0.id == id })
    }

    private func playSelectedListRow() {
        if let entry = selectedListEntry() {
            store.openCinema(entry)
        } else if let item = selectedListSeries(), let target = resumeEpisode(for: item) {
            store.openCinema(target)
        }
    }

    private func openSelectedListRow() {
        if let entry = selectedListEntry() {
            openDetail(entry)
        } else if let item = selectedListSeries() {
            detailTarget = .series(item)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            sortHeader("片名", sort: .title)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("年份", sort: .year)
                .frame(width: 48, alignment: .leading)
            sortHeader("评分", sort: .rating)
                .frame(width: 48, alignment: .leading)
            Text("类型").frame(width: 150, alignment: .leading)
            Text("规格").frame(width: 90, alignment: .leading)
            HStack(spacing: 4) {
                Text("状态")
                Button {
                    store.cinemaSort = .recent
                    listSortReversed = false
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(store.cinemaSort == .recent ? LumaBrand.amber : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("按最近添加排序")
            }
            .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 表头点击排序：只切排序字段，再次点击同一列反转方向。
    private func sortHeader(_ title: String, sort: CinemaSort) -> some View {
        Button {
            if store.cinemaSort == sort {
                listSortReversed.toggle()
            } else {
                store.cinemaSort = sort
                listSortReversed = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if store.cinemaSort == sort {
                    Image(systemName: sortArrow(sort))
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(store.cinemaSort == sort ? LumaBrand.amber : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    private func sortArrow(_ sort: CinemaSort) -> String {
        let naturalAscending = sort == .title
        let ascending = listSortReversed ? !naturalAscending : naturalAscending
        return ascending ? "chevron.up" : "chevron.down"
    }

    private func entryListRow(_ entry: CinemaEntry) -> some View {
        CinemaListRow(artworkURL: entry.artworkURL,
                      fallbackPhoto: entry.file.photoItem,
                      title: entry.title,
                      subtitle: entry.file.filename,
                      year: entry.year.map(String.init) ?? "—",
                      rating: entry.rating,
                      genres: entry.genres?.joined(separator: " / ") ?? "—",
                      spec: entrySpec(entry),
                      badge: entry.matched ? (entry.kind == .movie ? "电影" : "剧集") : "未识别",
                      progress: store.cinemaProgress[entry.id],
                      onOpen: { openDetail(entry) },
                      selected: selectedListEntryID == entry.id,
                      onSelect: {
                          selectedListSeriesID = nil
                          selectedListEntryID = entry.id
                      },
                      onPlay: { store.openCinema(entry) },
                      singleClickOpensDetail: openDetailOnClick)
    }

    private func entrySpec(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if entry.file.pixelWidth > 0, entry.file.pixelHeight > 0 {
            parts.append("\(entry.file.pixelWidth)×\(entry.file.pixelHeight)")
        }
        if let codec = entry.file.videoCodec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        parts.append(contentsOf: entry.file.displayTags.prefix(2))
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: 详情入口

    private func openDetail(_ entry: CinemaEntry) {
        if entry.kind == .tv,
           let item = store.cinemaSeries(for: scope, matched: entry.matched)
            .first(where: { series in
                series.episodes.contains(where: { $0.id == entry.id })
            }) {
            detailTarget = .series(item)
            return
        }
        detailTarget = .entry(entry)
    }

    /// 筛选把当前分页筛空：告诉用户是筛选而不是刮削没结果，并提供一键复位。
    private var filterEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("没有符合筛选条件的影片")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(filterSummary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("清除筛选") {
                withAnimation(.snappy(duration: 0.16)) {
                    store.resetCinemaFilters()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// 顶栏筛选条件的可读描述，例如「2020 年代 · 科幻 · 4K · 进行中」。
    private var filterSummary: String {
        var parts: [String] = []
        if !store.cinemaDecades.isEmpty {
            parts.append(store.cinemaDecades.sorted(by: >).map { "\($0)s" }.joined(separator: "/"))
        }
        if !store.cinemaGenres.isEmpty {
            parts.append(store.cinemaGenres.sorted().joined(separator: "/"))
        }
        if !store.cinemaResolutions.isEmpty {
            parts.append(store.cinemaResolutions.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaSpecFilters.isEmpty {
            parts.append(store.cinemaSpecFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaWatchFilters.isEmpty {
            parts.append(store.cinemaWatchFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if store.cinemaSmartHighRated { parts.append("高分 8+") }
        if store.cinemaSmartRecent { parts.append("最近 30 天") }
        if store.cinemaFavoritesOnly { parts.append("收藏") }
        if let list = store.cinemaList(store.cinemaActiveListID) { parts.append(list.name) }
        return parts.joined(separator: " · ")
    }

    // MARK: 海报墙统计 / 字母索引

    /// 统计条：规格分布 + 已看，回答「这个库有什么、看了多少」。
    private var wallStatsBar: some View {
        let pool = entries.filter { $0.matched }
        let uhd = pool.filter { $0.file.pixelWidth >= 3000 }.count
        let hd = pool.filter { $0.file.pixelWidth >= 1800 && $0.file.pixelWidth < 3000 }.count
        let sd = pool.filter { $0.file.pixelWidth > 0 && $0.file.pixelWidth < 1800 }.count
        let watched = pool.filter { store.cinemaProgress[$0.id]?.isFinished == true }.count
        return HStack(spacing: 7) {
            statChip("4K", uhd)
            statChip("1080P", hd)
            statChip("720P 及以下", sd)
            statChip("已看", watched)
            statChip("未识别", unmatched.count, tint: LumaBrand.coral)
            Spacer(minLength: 0)
            Text("\(pool.count) 个已识别文件")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func statChip(_ title: String, _ value: Int, tint: Color = LumaBrand.amber) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(value > 0 ? tint : Color.secondary)
        }
        .font(.system(size: 9.5))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private var wallItemCount: Int { movies.count + series.count }

    /// 每部作品取首字符作为索引字母；中文片名直接用首字。
    private var wallLetterEntries: [CinemaLetterEntry] {
        var seen = Set<String>()
        var list: [CinemaLetterEntry] = []
        for entry in movies {
            let letter = wallLetter(entry.title)
            guard seen.insert(letter).inserted else { continue }
            list.append(CinemaLetterEntry(letter: letter, target: entry.id.uuidString))
        }
        for item in series {
            let letter = wallLetter(item.title)
            guard seen.insert(letter).inserted else { continue }
            list.append(CinemaLetterEntry(letter: letter, target: "series-\(item.id)"))
        }
        return list.sorted { $0.letter.localizedStandardCompare($1.letter) == .orderedAscending }
    }

    private func wallLetter(_ title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let upper = String(first).uppercased()
        if upper.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) != nil { return upper }
        if first.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) { return String(first) }
        return "#"
    }

    /// 大库专用：条目超过 200 才出现字母索引。
    @ViewBuilder
    private func wallLetterRail(_ proxy: ScrollViewProxy) -> some View {
        if store.cinemaViewMode == .wall,
           store.cinemaTab != .folder,
           wallItemCount > 200,
           !wallLetterEntries.isEmpty {
            VStack(spacing: 1) {
                ForEach(wallLetterEntries) { item in
                    Button(item.letter) {
                        withAnimation(.snappy(duration: 0.22)) {
                            proxy.scrollTo(item.target, anchor: .top)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                    .frame(width: 18, height: 13)
                    .help("跳到 \(item.letter)")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
            }
            .padding(.trailing, 6)
        }
    }

    private func tabEmptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("已刮削但没匹配上的视频都在「全部」的未识别里，可以右键重新刮削。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// 文档约定 D4：未识别空态给命名示例 + 一个「去匹配」主行动，不写「暂无数据」。
    private var unmatchedEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("\(unmatched.count) 条影片未识别")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("命名不规范会导致匹配失败。试试「片名.年份.分辨率」，或手动搜索片名。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if let entry = unmatched.first {
                Button("去匹配") { panelTarget = .match(entry) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    private var showFirstRun: Bool {
        allEntries.isEmpty && store.cloudMounts.isEmpty && !firstRunDismissed
    }

    /// F5 首次建库：一项主行动 + 三步说明，允许跳过。
    private var firstRunView: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: index == 1
                                             ? [LumaBrand.violet.opacity(0.55), Color.black.opacity(0.35)]
                                             : [LumaBrand.amber.opacity(0.45), Color.black.opacity(0.30)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 96, height: 144)
                        .overlay {
                            Image(systemName: index == 2 ? "tv" : "film")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                }
            }
            .opacity(0.34)
            .padding(.trailing, 34)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("LUMA CINEMA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(LumaBrand.amber)
                    Text("把影片放进来，\n剩下的交给影院")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .lineSpacing(3)
                    Text("选择一个目录或网盘，Luma 会扫描视频、自动匹配电影与剧集、生成海报墙。不需要转码，也不复制文件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .frame(maxWidth: 520, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 18) {
                    firstRunStep("STEP 1", title: "选择来源", detail: "本地目录、夸克、阿里、WebDAV、SMB")
                    firstRunStep("STEP 2", title: "确认扫描规则", detail: "刮削源、NFO、跳过目录")
                    firstRunStep("STEP 3", title: "坐下看片", detail: "继续观看、海报墙、剧集聚合")
                }

                HStack(spacing: 10) {
                    Button {
                        store.presentCloudWizard()
                    } label: {
                        Label("添加片源", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("稍后再说") {
                        firstRunDismissed = true
                    }
                    .controlSize(.large)
                }

                HStack(spacing: 6) {
                    ForEach(["本地目录", "夸克", "阿里云盘", "百度网盘", "WebDAV", "SMB", "AList"], id: \.self) { name in
                        Text(name)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                            .overlay {
                                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                            }
                    }
                }
            }
            .padding(34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [LumaBrand.amber.opacity(0.06), Color.primary.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
    }

    private func firstRunStep(_ index: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(index)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(LumaBrand.amber.opacity(0.85))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 168, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(mountID == nil ? "影院库还是空的" : "这个网盘的影院还是空的")
                .font(.system(size: 16, weight: .semibold))
            Text(needsConfig
                 ? "先在设置里填写 TMDB API Key，或切换成免 Key 的豆瓣数据源，再回到这里刮削。"
                 : (mountID == nil
                    ? "点击顶部的「刮削」按钮开始。会扫描本地视频，按文件名匹配海报、类型与简介。"
                    : "点击顶部的「刮削」按钮会把当前网盘扫描到的视频逐个匹配海报与简介；匹配不上的会放进「未识别」，仍然可以播放。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !needsConfig {
                Button("开始刮削") {
                    Task { await store.scrapeCinema(for: scope) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(store.cinemaScrapeRunning)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: 主视觉

    @ViewBuilder
    private func hero(entries: [CinemaEntry]? = nil) -> some View {
        let pool = entries ?? self.entries
        if let entry = pool.first(where: { $0.backdropURL != nil }) ?? pool.first {
            CinemaHeroCard(entry: entry,
                           onPlay: { store.openCinema(entry) },
                           onDetail: { openDetail(entry) })
        }
    }

    private func shelf(_ title: String, _ list: [CinemaEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(list) { entry in
                        posterCard(entry)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 继续观看

    @ViewBuilder
    private var continueShelf: some View {
        let records = store.cinemaContinueRecords(for: scope)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("继续观看")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(records.count) 部待续播")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(records.prefix(12)) { record in
                            CinemaContinueCard(record: record) {
                                openContinue(record)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func openContinue(_ record: CinemaProgressRecord) {
        guard let entry = store.cinemaEntries(for: scope)[record.photoID] else { return }
        store.openCinema(entry)
    }

    // MARK: 我的清单

    private var myListsShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("我的清单")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(store.cinemaLists.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    panelTarget = .newList
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumaBrand.amber)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(store.cinemaLists) { list in
                        cinemaListCard(list)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func cinemaListCard(_ list: CinemaListRecord) -> some View {
        let active = store.cinemaActiveListID == list.id
        return Button {
            store.cinemaActiveListID = active ? nil : list.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: list.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(list.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(list.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(active ? "已筛选" : "点击筛选")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .padding(11)
            .frame(width: 172, height: 82, alignment: .leading)
            .background(active ? LumaBrand.amber.opacity(0.12)
                               : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? LumaBrand.amber.opacity(0.45)
                                         : Color.primary.opacity(0.06),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除清单", role: .destructive) {
                store.deleteCinemaList(list.id)
            }
        }
    }

    // MARK: 剧集（多集 → 一张卡）

    @ViewBuilder
    private func seriesHero() -> some View {
        if let item = series.first(where: { $0.backdropURL != nil }) ?? series.first {
            CinemaSeriesHeroCard(series: item,
                                 onPlay: {
                                     if let target = resumeEpisode(for: item) {
                                         store.openCinema(target)
                                     }
                                 },
                                 onOpen: { detailTarget = .series(item) })
        }
    }

    private func seriesShelf(_ title: String, _ list: [CinemaSeries]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(list) { item in
                        CinemaSeriesCard(series: item,
                                         hovered: hoveredSeriesID == item.id) { hovering in
                            hoveredSeriesID = hovering
                                ? item.id
                                : (hoveredSeriesID == item.id ? nil : hoveredSeriesID)
                        } onOpen: {
                            detailTarget = .series(item)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 未识别同样按剧聚合：一部剧一张卡，电影仍是一条一张。
    private var unmatchedShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("未识别 · 可右键重新刮削")
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(unmatchedSeries) { item in
                        CinemaSeriesCard(series: item,
                                         hovered: hoveredSeriesID == item.id) { hovering in
                            hoveredSeriesID = hovering
                                ? item.id
                                : (hoveredSeriesID == item.id ? nil : hoveredSeriesID)
                        } onOpen: {
                            detailTarget = .series(item)
                        }
                    }
                    ForEach(unmatchedMovies.prefix(18)) { entry in
                        posterCard(entry)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func open(_ raw: String) {
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - 影院顶栏控制台（拟物化放映机操作台）

/// 影院页的整条控制台：片盒铭牌、机械选片开关、放映开关与调校钮，
/// 全部收进窗口工具栏的一行里，不再占用内容区高度。
/// 深色拉丝金属 + 琥珀指示灯 + 刻字标签，模拟高端放映机的操作面板。
struct CinemaToolbarConsole: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKeys.selectedTab) private var settingsTab: SettingsTab = .general

    @State private var hoveredTab: CinemaTab?
    @State private var hoveredScrape = false
    @State private var hoveredSettings = false
    @State private var hoveredAssistant = false
    @State private var hoveredAutoMatch = false
    @State private var showStatus = false
    @State private var showFilter = false

    private enum WidthTier {
        case full, compact, narrow, minimal
    }

    private var tier: WidthTier {
        // 按「工具栏真正的可用宽度」升档（读数来自影院页面内容里的探针）。
        // 每档的实际占位：全宽约 1270pt、紧凑约 1040pt、窄档约 520pt、极简约 230pt。
        // 档位宽度超过可用宽度时，系统会把整条工具栏项藏起来，顶栏看起来就像「没了」，
        // 所以每个阈值都留出余量，宁可提前折叠也不让整条消失。
        let available = store.cinemaAvailableWidth
        if available < 600 { return .minimal }
        if available < 1060 { return .narrow }
        if available < 1320 { return .compact }
        return .full
    }

    private var scope: CinemaScope {
        if case .cloudCinema(let id) = store.sidebarItem { return .mount(id) }
        return .local
    }

    private var scopeEntries: [CinemaEntry] {
        Array(store.cinemaEntries(for: scope).values)
    }

    private var matchedCount: Int {
        scopeEntries.filter { $0.matched }.count
    }

    private var unmatchedCount: Int {
        scopeEntries.count - matchedCount
    }

    private var mountName: String? {
        if case .mount(let id) = scope,
           let name = store.cloudMounts.first(where: { $0.id == id })?.name {
            return name
        }
        return nil
    }

    private var isScraping: Bool {
        store.cinemaScrapeRunning && store.cinemaScrapeScope == scope
    }

    // MARK: 配色（浅色 / 深色）

    /// 深色是放映机黑金面板；浅色换成香槟银面板，避免在白底工具栏上压一块黑砖。
    private var isDark: Bool { scheme == .dark }

    private var titleColor: Color { isDark ? .white : Color(white: 0.14) }
    private var secondaryText: Color { isDark ? Color.white.opacity(0.70) : Color(white: 0.34) }
    private var tertiaryText: Color { isDark ? Color.white.opacity(0.52) : Color(white: 0.46) }
    private var faintText: Color { isDark ? Color.white.opacity(0.32) : Color(white: 0.55) }

    /// 主强调：深色用亮琥珀，浅色用更深的青铜，保证白底上的对比度。
    private var accentText: Color {
        isDark ? LumaBrand.amber : Color(red: 0.62, green: 0.41, blue: 0.08)
    }

    /// 指示灯：浅色下用更深的金，不再发白。
    private var ledColor: Color {
        isDark ? LumaBrand.amber : Color(red: 0.88, green: 0.60, blue: 0.16)
    }

    private var unmatchedColor: Color {
        isDark ? LumaBrand.coral : Color(red: 0.80, green: 0.34, blue: 0.24)
    }

    private var assistantTint: Color {
        isDark ? LumaBrand.violet : Color(red: 0.44, green: 0.31, blue: 0.82)
    }

    private var plateFill: LinearGradient {
        isDark
            ? LinearGradient(colors: [Color(white: 0.20), Color(white: 0.115), Color(white: 0.065)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.99, green: 0.982, blue: 0.965),
                                      Color(red: 0.955, green: 0.945, blue: 0.925),
                                      Color(red: 0.915, green: 0.900, blue: 0.872)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var plateStroke: LinearGradient {
        isDark
            ? LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02), .black.opacity(0.40)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.30), .black.opacity(0.16)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var topHighlight: Color { isDark ? Color.white.opacity(0.14) : Color.white.opacity(0.90) }
    private var plateShadow: Color { isDark ? Color.black.opacity(0.32) : Color.black.opacity(0.12) }

    private var channelFill: Color { isDark ? Color.black.opacity(0.34) : Color.black.opacity(0.05) }

    private var channelStroke: LinearGradient {
        isDark
            ? LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.07)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.black.opacity(0.14), .white.opacity(0.85)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var keyFill: LinearGradient {
        isDark
            ? LinearGradient(colors: [Color(white: 0.24), Color(white: 0.10)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(white: 0.995), Color(white: 0.925)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var keyStroke: LinearGradient {
        isDark
            ? LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.45)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white.opacity(0.95), .black.opacity(0.16)],
                             startPoint: .top, endPoint: .bottom)
    }

    private func tabIconColor(active: Bool, hovered: Bool) -> Color {
        if active { return accentText }
        return isDark ? Color.white.opacity(hovered ? 0.90 : 0.55)
                      : Color(white: 0.40).opacity(hovered ? 1 : 0.82)
    }

    private func tabTextColor(active: Bool, hovered: Bool) -> Color {
        if active {
            return isDark ? Color.white : Color(red: 0.36, green: 0.25, blue: 0.07)
        }
        return isDark ? Color.white.opacity(hovered ? 0.88 : 0.60)
                      : Color(white: 0.30).opacity(hovered ? 1 : 0.85)
    }

    /// 当前是否启用了年代 / 类型 / 分辨率 / 观看状态 / 智能筛选。
    private var hasFilter: Bool {
        !store.cinemaDecades.isEmpty
            || !store.cinemaGenres.isEmpty
            || !store.cinemaResolutions.isEmpty
            || !store.cinemaSpecFilters.isEmpty
            || !store.cinemaWatchFilters.isEmpty
            || store.cinemaSmartHighRated
            || store.cinemaSmartRecent
            || store.cinemaFavoritesOnly
            || store.cinemaActiveListID != nil
    }

    private var filterCount: Int {
        var count = 0
        if !store.cinemaDecades.isEmpty { count += 1 }
        if !store.cinemaGenres.isEmpty { count += 1 }
        if !store.cinemaResolutions.isEmpty { count += 1 }
        if !store.cinemaSpecFilters.isEmpty { count += 1 }
        if !store.cinemaWatchFilters.isEmpty { count += 1 }
        if store.cinemaSmartHighRated { count += 1 }
        if store.cinemaSmartRecent { count += 1 }
        if store.cinemaFavoritesOnly { count += 1 }
        if store.cinemaActiveListID != nil { count += 1 }
        return count
    }

    private var filterTitle: String {
        if filterCount > 1 { return "筛选 \(filterCount)" }
        var parts: [String] = []
        if let first = store.cinemaDecades.sorted(by: >).first {
            parts.append(store.cinemaDecades.count == 1 ? "\(first)s" : "\(first)s+\(store.cinemaDecades.count - 1)")
        }
        if let first = store.cinemaGenres.sorted().first {
            parts.append(store.cinemaGenres.count == 1 ? first : "\(first)+\(store.cinemaGenres.count - 1)")
        }
        if let first = store.cinemaResolutions.map(\.title).sorted().first {
            parts.append(store.cinemaResolutions.count == 1 ? first : "\(first)+\(store.cinemaResolutions.count - 1)")
        }
        if let first = store.cinemaSpecFilters.map(\.title).sorted().first {
            parts.append(store.cinemaSpecFilters.count == 1 ? first : "\(first)+\(store.cinemaSpecFilters.count - 1)")
        }
        if let first = store.cinemaWatchFilters.map(\.title).sorted().first {
            parts.append(store.cinemaWatchFilters.count == 1 ? first : "\(first)+\(store.cinemaWatchFilters.count - 1)")
        }
        if store.cinemaSmartHighRated { parts.append("高分") }
        if store.cinemaSmartRecent { parts.append("最近") }
        if store.cinemaFavoritesOnly { parts.append("收藏") }
        if let list = store.cinemaList(store.cinemaActiveListID) { parts.append(list.name) }
        return parts.joined(separator: "·")
    }

    var body: some View {
        HStack(spacing: 0) {
            if store.cinemaDetailOpen {
                // 详情页也要保留整条顶栏：铭牌换成「返回」，浏览类控件让位给详情内容。
                detailBackKey
                engravedSeparator
            } else {
                identity
                engravedSeparator
                if tier != .minimal {
                    tabs
                }
                // 文件夹分段按目录组织，视图 / 筛选 / 排序对它不生效，隐藏避免误导。
                if store.cinemaTab != .folder, tier != .minimal {
                    browsingControls
                }
            }
            if tier != .minimal {
                searchKey
            }
            switch tier {
            case .minimal, .narrow:
                overflowKey
            case .full, .compact:
                historyKey
                tasksKey
                notifyKey
                if store.cinemaParentalEnabled {
                    parentalKey
                }
                autoMatchKey
                assistantKey
            }
            if tier == .full || tier == .compact {
                scrapeKey
            } else {
                scrapeCompactKey
            }
            settingsKnob
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background { consolePlate }
    }

    /// 视图 / 继续 / 筛选 / 排序 / 清单：全宽平铺，紧凑与窄档收进「显示」。
    @ViewBuilder
    private var browsingControls: some View {
        if tier == .full {
            viewSwitch
            if let record = store.cinemaContinueRecord(for: scope) {
                continueKey(record)
            }
            engravedSeparator
            filterMenu
            sortMenu
            listsMenu
        } else {
            // 窄窗口按文档折叠：视图 / 排序 / 清单收进「显示 ▾」。
            displayMenu
            if tier == .compact,
               let record = store.cinemaContinueRecord(for: scope) {
                continueKey(record)
            }
            filterCompactKey
        }
    }

    /// 详情页顶栏的返回键：和刻字标签同一套金属底，点一下或按 Esc 回列表。
    private var detailBackKey: some View {
        Button {
            store.cinemaDetailCloseTick += 1
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9.5, weight: .bold))
                Text("返回")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(accentText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(ledColor.opacity(isDark ? 0.12 : 0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(ledColor.opacity(0.36), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .keyboardShortcut(.cancelAction)
        .help("返回影院 (Esc)")
    }

    // MARK: 片盒铭牌

    private var identity: some View {
        Button {
            showStatus.toggle()
        } label: {
            HStack(spacing: 8) {
                filmBadge

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("影院")
                            .font(.system(size: 13.5, weight: .semibold, design: .serif))
                            .foregroundStyle(titleColor)
                        if tier == .full || tier == .compact {
                            Text("CINEMA")
                                .font(.system(size: 7, weight: .bold))
                                .tracking(2.0)
                                .foregroundStyle(accentText.opacity(0.92))
                        }
                    }
                    if tier == .full || tier == .compact {
                        statusLine
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(faintText)
                    .rotationEffect(.degrees(showStatus ? 180 : 0))
            }
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showStatus, arrowEdge: .bottom) { statusPopover }
        .help("放映室状态与数据源")
    }

    private var statusLine: some View {
        HStack(spacing: 5) {
            if let mountName {
                Text(mountName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusDot(faintText.opacity(0.55))
            }
            if scopeEntries.isEmpty {
                Text("未刮削")
                    .foregroundStyle(tertiaryText)
            } else {
                statusDot(ledColor)
                Text("\(matchedCount) 已识别")
                    .foregroundStyle(secondaryText)
                if unmatchedCount > 0 {
                    statusDot(unmatchedColor)
                    Text("\(unmatchedCount) 未识别")
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .font(.system(size: 9, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: 196, alignment: .leading)
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 2.5, height: 2.5)
    }

    /// 小片盒：金属块 + 琥珀灯。
    private var filmBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isDark
                      ? LinearGradient(colors: [Color(white: 0.27), Color(white: 0.11)],
                                       startPoint: .top, endPoint: .bottom)
                      : LinearGradient(colors: [Color(white: 1.0), Color(white: 0.90)],
                                       startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(accentText.opacity(isDark ? 0.52 : 0.45), lineWidth: 0.7)
            Image(systemName: "film.stack")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accentText)
        }
        .frame(width: 21, height: 21)
        .shadow(color: ledColor.opacity(isDark ? 0.25 : 0.18), radius: 4)
    }

    // MARK: 机械选片开关

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(CinemaTab.allCases) { item in
                let active = store.cinemaTab == item
                let hovered = hoveredTab == item
                Button {
                    withAnimation(.snappy(duration: 0.16)) { store.cinemaTab = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tabIconColor(active: active, hovered: hovered))
                        Text(tabTitle(item))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tabTextColor(active: active, hovered: hovered))
                            .shadow(color: ledColor.opacity(active ? (isDark ? 0.55 : 0.16) : 0), radius: 4)
                    }
                    .frame(width: segmentWidth(item), height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(segmentFill(active: active, hovered: hovered))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(active ? ledColor.opacity(isDark ? 0.34 : 0.42) : Color.clear,
                                          lineWidth: 0.7)
                    }
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(active ? ledColor : .clear)
                            .frame(width: 18, height: 1.6)
                            .padding(.bottom, 2.5)
                            .shadow(color: ledColor.opacity(active ? 0.75 : 0), radius: 3)
                    }
                    .shadow(color: ledColor.opacity(active ? 0.14 : 0), radius: 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        hoveredTab = item
                    } else if hoveredTab == item {
                        hoveredTab = nil
                    }
                }
                .help(item.title)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(channelFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(channelStroke, lineWidth: 0.7)
                }
        }
        .padding(.horizontal, 8)
    }

    /// 窄窗口下主导航文字缩写（文档：全部 / 电影 / 剧）。
    private func tabTitle(_ item: CinemaTab) -> String {
        guard tier == .narrow else { return item.title }
        switch item {
        case .all: return "全部"
        case .movies: return "电影"
        case .shows: return "剧"
        case .folder: return "目录"
        }
    }

    private func segmentWidth(_ item: CinemaTab) -> CGFloat {
        if tier == .narrow {
            switch item {
            case .all: return 44
            case .movies: return 44
            case .shows: return 32
            case .folder: return 44
            }
        }
        switch item {
        case .all: return 62
        case .movies: return 58
        case .shows: return 78
        case .folder: return 78
        }
    }

    private func segmentFill(active: Bool, hovered: Bool) -> LinearGradient {
        if active {
            return LinearGradient(colors: [ledColor.opacity(isDark ? 0.20 : 0.24),
                                           ledColor.opacity(isDark ? 0.05 : 0.08)],
                                  startPoint: .top, endPoint: .bottom)
        }
        let hoverBase: Double = isDark ? 0.09 : 0.05
        return LinearGradient(colors: [Color.primary.opacity(hovered ? hoverBase : 0),
                                       Color.primary.opacity(hovered ? hoverBase * 0.4 : 0)],
                              startPoint: .top, endPoint: .bottom)
    }

    // MARK: 继续播放

    private var viewSwitch: some View {
        HStack(spacing: 1) {
            ForEach(CinemaViewMode.allCases) { mode in
                let active = store.cinemaViewMode == mode
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        store.cinemaViewMode = mode
                    }
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(active
                                         ? accentText
                                         : (isDark ? Color.white.opacity(0.46) : Color(white: 0.42)))
                        .frame(width: 24, height: 24)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(ledColor.opacity(isDark ? 0.14 : 0.16))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(.horizontal, 5)
    }

    private func continueKey(_ record: CinemaProgressRecord) -> some View {
        Button {
            openContinue(record)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("继续")
                    .font(.system(size: 11, weight: .semibold))
                if let subtitle = record.subtitle, !subtitle.isEmpty {
                    Text(continueBadge(subtitle))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(accentText.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(accentText)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(ledColor.opacity(isDark ? 0.10 : 0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(ledColor.opacity(0.35), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .help("继续播放 \(record.title)")
    }

    private func openContinue(_ record: CinemaProgressRecord) {
        guard let entry = store.cinemaEntries(for: scope)[record.photoID] else { return }
        store.openCinema(entry)
    }

    /// 顶栏空间有限：剧集只显示 SxxExx，电影保留年份。
    private func continueBadge(_ subtitle: String) -> String {
        if let range = subtitle.range(of: "S", options: .backwards) {
            return String(subtitle[range.lowerBound...])
        }
        return subtitle
    }

    // MARK: 筛选 / 排序

    private var searchKey: some View {
        Button {
            store.cinemaSearchVisible = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isDark ? Color.white.opacity(0.60) : Color(white: 0.34))
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.10),
                                      lineWidth: 0.7)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .keyboardShortcut("f", modifiers: .command)
        .help("搜索影院（⌘F）")
    }

    /// 顶栏小按键的统一外观。
    private func iconKey(_ icon: String,
                         help: String,
                         active: Bool = false,
                         showsDot: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active
                                 ? accentText
                                 : (isDark ? Color.white.opacity(0.60) : Color(white: 0.34)))
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active
                              ? ledColor.opacity(isDark ? 0.12 : 0.16)
                              : (isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(active ? ledColor.opacity(0.36)
                                             : (isDark ? Color.white.opacity(0.09)
                                                       : Color.black.opacity(0.10)),
                                      lineWidth: 0.7)
                }
                .overlay(alignment: .topTrailing) {
                    if showsDot {
                        Circle()
                            .fill(LumaBrand.coral)
                            .frame(width: 5, height: 5)
                            .offset(x: 1.5, y: -1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(help)
    }

    private var historyKey: some View {
        iconKey("clock.arrow.circlepath", help: "观看记录") {
            store.cinemaHistoryVisible = true
        }
    }

    /// 顶栏「我的清单」：收藏、自定义清单与新建入口收在一个下拉里。
    private var listsMenu: some View {
        let favoriteCount = store.cinemaUserStates.values.filter(\.favorite).count
        let active = store.cinemaFavoritesOnly || store.cinemaActiveListID != nil
        return Menu {
            Button {
                store.cinemaFavoritesOnly.toggle()
                store.cinemaActiveListID = nil
            } label: {
                Label("收藏（\(favoriteCount)）",
                      systemImage: store.cinemaFavoritesOnly ? "heart.fill" : "heart")
            }
            if store.cinemaLists.isEmpty {
                Text("还没有自定义清单")
            } else {
                Divider()
                ForEach(store.cinemaLists) { list in
                    Button {
                        store.cinemaActiveListID = list.id
                        store.cinemaFavoritesOnly = false
                    } label: {
                        Label("\(list.name)（\(list.itemIDs.count)）", systemImage: "list.bullet")
                    }
                }
            }
            if active {
                Divider()
                Button("清除清单筛选") {
                    store.cinemaActiveListID = nil
                    store.cinemaFavoritesOnly = false
                }
            }
            Divider()
            Button("新建清单…") { store.cinemaNewListVisible = true }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("清单")
                    .font(.system(size: 9.5, weight: .semibold))
                if !store.cinemaLists.isEmpty {
                    Text("\(store.cinemaLists.count)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(active ? accentText
                                    : (isDark ? Color.white.opacity(0.60) : Color(white: 0.34)))
            .frame(height: 26)
            .padding(.horizontal, 7)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(active
                          ? ledColor.opacity(isDark ? 0.12 : 0.16)
                          : (isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(active ? ledColor.opacity(0.36)
                                         : (isDark ? Color.white.opacity(0.09)
                                                   : Color.black.opacity(0.10)),
                                  lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 4)
        .help("我的清单：收藏 / 自定义清单 / 新建")
    }

    private var tasksKey: some View {
        let needsAttention = store.cinemaTasks.contains { $0.finishedAt == nil || !$0.succeeded }
        return iconKey("checklist", help: "任务中心", active: needsAttention, showsDot: needsAttention) {
            store.cinemaTasksVisible = true
        }
    }

    /// 通知中心：未读用数量角标，而不是只给一个小红点。
    private var notifyKey: some View {
        let unread = store.cinemaUnreadNotificationCount
        return Button {
            store.cinemaNotificationsVisible = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: unread > 0 ? "bell.badge" : "bell")
                    .font(.system(size: 11, weight: .semibold))
                if unread > 0 {
                    Text("\(min(unread, 99))")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
            }
            .foregroundStyle(unread > 0 ? accentText
                                        : (isDark ? Color.white.opacity(0.60) : Color(white: 0.34)))
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, unread > 0 ? 5 : 0)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(unread > 0
                          ? ledColor.opacity(isDark ? 0.12 : 0.16)
                          : (isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(unread > 0 ? ledColor.opacity(0.36)
                                            : (isDark ? Color.white.opacity(0.09)
                                                      : Color.black.opacity(0.10)),
                                  lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(unread > 0 ? "通知中心 · \(unread) 条未读" : "通知中心")
    }

    private var parentalKey: some View {
        let locked = store.cinemaParentalLocked
        return iconKey(locked ? "lock.fill" : "lock.open",
                       help: locked ? "家长控制已启用 · 点击输入 PIN" : "家长控制已解锁 · 点击重新上锁",
                       active: locked) {
            if locked {
                store.cinemaPINPromptVisible = true
            } else {
                store.lockCinemaParental()
            }
        }
    }

    private var filterMenu: some View {
        Button {
            showFilter.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                Text(hasFilter ? filterTitle : "筛选")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(hasFilter ? accentText
                                       : (isDark ? Color.white.opacity(0.60) : Color(white: 0.34)))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hasFilter ? ledColor.opacity(isDark ? 0.10 : 0.14)
                                    : (isDark ? Color.white.opacity(0.035)
                                              : Color.white.opacity(0.55)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(hasFilter ? ledColor.opacity(0.36)
                                            : (isDark ? Color.white.opacity(0.09)
                                                      : Color.black.opacity(0.10)),
                                  lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, 8)
        .help("按年代、类型、分辨率、观看状态筛选")
        .popover(isPresented: $showFilter, arrowEdge: .bottom) {
            CinemaFilterPanel(scope: scope) {
                showFilter = false
            }
            .environmentObject(store)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CinemaSort.allCases) { option in
                Button {
                    store.cinemaSort = option
                } label: {
                    if store.cinemaSort == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(store.cinemaSort.shortTitle)
                    .font(.system(size: 10.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
            }
            .foregroundStyle(isDark ? Color.white.opacity(0.60) : Color(white: 0.34))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.10),
                                  lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("排序：\(store.cinemaSort.title)")
    }

    // MARK: 窄窗口折叠

    /// 窄窗口「显示 ▾」：视图、排序与清单合成一个下拉，控制台才塞得进一行。
    private var displayMenu: some View {
        let favoriteCount = store.cinemaUserStates.values.filter(\.favorite).count
        let listActive = store.cinemaFavoritesOnly || store.cinemaActiveListID != nil
        return Menu {
            Section("视图") {
                ForEach(CinemaViewMode.allCases) { mode in
                    Button {
                        withAnimation(.snappy(duration: 0.16)) { store.cinemaViewMode = mode }
                    } label: {
                        if store.cinemaViewMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Label(mode.title, systemImage: mode.icon)
                        }
                    }
                }
            }
            Section("排序") {
                ForEach(CinemaSort.allCases) { option in
                    Button {
                        store.cinemaSort = option
                    } label: {
                        if store.cinemaSort == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
            Section("清单") {
                Button {
                    store.cinemaFavoritesOnly.toggle()
                    store.cinemaActiveListID = nil
                } label: {
                    Label("收藏（\(favoriteCount)）",
                          systemImage: store.cinemaFavoritesOnly ? "heart.fill" : "heart")
                }
                ForEach(store.cinemaLists) { list in
                    Button {
                        store.cinemaActiveListID = list.id
                        store.cinemaFavoritesOnly = false
                    } label: {
                        Label("\(list.name)（\(list.itemIDs.count)）", systemImage: "list.bullet")
                    }
                }
                if listActive {
                    Button("清除清单筛选") {
                        store.cinemaActiveListID = nil
                        store.cinemaFavoritesOnly = false
                    }
                }
                Button("新建清单…") { store.cinemaNewListVisible = true }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("显示")
                    .font(.system(size: 10.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
            }
            .foregroundStyle(listActive ? accentText
                                        : (isDark ? Color.white.opacity(0.60) : Color(white: 0.34)))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(listActive ? ledColor.opacity(isDark ? 0.10 : 0.14)
                                     : (isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(listActive ? ledColor.opacity(0.36)
                                             : (isDark ? Color.white.opacity(0.09)
                                                       : Color.black.opacity(0.10)),
                                  lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("视图 / 排序 / 清单")
    }

    /// 折叠态筛选：只留漏斗图标，已生效时点亮并带数量。
    private var filterCompactKey: some View {
        Button {
            showFilter.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hasFilter ? accentText
                                               : (isDark ? Color.white.opacity(0.60)
                                                         : Color(white: 0.34)))
                    .frame(width: 26, height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(hasFilter ? ledColor.opacity(isDark ? 0.10 : 0.14)
                                            : (isDark ? Color.white.opacity(0.035)
                                                      : Color.white.opacity(0.55)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(hasFilter ? ledColor.opacity(0.36)
                                                    : (isDark ? Color.white.opacity(0.09)
                                                              : Color.black.opacity(0.10)),
                                          lineWidth: 0.7)
                    }
                if filterCount > 0 {
                    Text("\(min(filterCount, 9))")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .frame(width: 11, height: 11)
                        .background(Circle().fill(ledColor))
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .popover(isPresented: $showFilter, arrowEdge: .bottom) {
            CinemaFilterPanel(scope: scope) {
                showFilter = false
            }
            .environmentObject(store)
        }
        .help("按年代、类型、分辨率、观看状态筛选")
    }

    /// 窄窗口「更多」：观看记录 / 任务 / 通知 / 家长控制 / 助手。
    private var overflowKey: some View {
        Menu {
            Button { store.cinemaHistoryVisible = true } label: {
                Label("观看记录", systemImage: "clock.arrow.circlepath")
            }
            Button { store.cinemaTasksVisible = true } label: {
                Label("任务中心", systemImage: "checklist")
            }
            Button { store.cinemaNotificationsVisible = true } label: {
                Label("通知中心", systemImage: "bell")
            }
            if store.cinemaParentalEnabled {
                Button {
                    if store.cinemaParentalLocked {
                        store.cinemaPINPromptVisible = true
                    } else {
                        store.lockCinemaParental()
                    }
                } label: {
                    Label(store.cinemaParentalLocked ? "家长控制 · 已锁" : "重新上锁",
                          systemImage: "lock")
                }
            }
            Button { store.presentCinemaAutoMatch() } label: {
                Label("一键智能整理", systemImage: "bolt.badge.automatic")
            }
            Button { store.showAIAssistant = true } label: {
                Label("智能助手", systemImage: "sparkles")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isDark ? Color.white.opacity(0.60) : Color(white: 0.34))
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.10),
                                      lineWidth: 0.7)
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 4)
        .help("更多：观看记录 / 任务 / 通知 / 助手")
    }

    /// 窄窗口刮削键：只留图标，任务中变进度图标。
    private var scrapeCompactKey: some View {
        Button {
            Task { await store.scrapeCinema(for: scope) }
        } label: {
            Image(systemName: isScraping ? "light.max" : "wand.and.stars")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accentText)
                .frame(width: 28, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(scrapeFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(ledColor.opacity(isDark ? 0.30 : 0.38), lineWidth: 0.8)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isScraping)
        .padding(.horizontal, 4)
        .help(isScraping
              ? "正在刮削 \(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)"
              : "刮削这个链接下的视频")
        .contextMenu {
            Button("重新刮削全部") {
                Task { await store.scrapeCinema(for: scope, force: true) }
            }
        }
    }

    // MARK: 智能助手

    /// 一键智能整理：把当前影院交给助手，由模型按目录逐部匹配电影 / 剧集与季集。
    private var autoMatchKey: some View {
        let active = hoveredAutoMatch || store.aiIsResponding
        return Button {
            store.presentCinemaAutoMatch()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(keyFill)
                    .brightness(hoveredAutoMatch ? (isDark ? 0.05 : 0.02) : 0)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(keyStroke, lineWidth: 0.7)
                Image(systemName: "bolt.badge.automatic")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(active
                                     ? ledColor
                                     : (isDark ? Color.white.opacity(0.66) : Color(white: 0.40)))
            }
            .frame(width: 26, height: 26)
            .shadow(color: ledColor.opacity(active ? 0.35 : 0), radius: 6)
        }
        .buttonStyle(.plain)
        .onHover { hoveredAutoMatch = $0 }
        .padding(.trailing, 4)
        .help("一键智能整理：让助手按目录树逐部匹配电影 / 剧集，季与集自动对应（先授权后写入）")
        .accessibilityLabel("一键智能整理")
    }

    private var assistantKey: some View {
        Button {
            store.showAIAssistant = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(keyFill)
                    .brightness(hoveredAssistant ? (isDark ? 0.05 : 0.02) : 0)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(keyStroke, lineWidth: 0.7)
                Image(systemName: "sparkles")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hoveredAssistant
                                     ? assistantTint
                                     : (isDark ? Color.white.opacity(0.66) : Color(white: 0.40)))
            }
            .frame(width: 26, height: 26)
            .shadow(color: assistantTint.opacity(hoveredAssistant ? 0.35 : 0), radius: 6)
        }
        .buttonStyle(.plain)
        .onHover { hoveredAssistant = $0 }
        .padding(.trailing, 7)
        .help("智能助手：用自然语言查找、整理图库（写操作会先确认）")
        .accessibilityLabel("智能助手")
    }

    // MARK: 刮削按钮

    /// 悬停才算「点亮」：静止时是一枚黄铜暗键，和整条面板融为一体。
    private var scrapeHot: Bool { hoveredScrape && !isScraping }

    private var scrapeKey: some View {
        Button {
            Task { await store.scrapeCinema(for: scope) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isScraping ? "light.max" : "wand.and.stars")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(isScraping ? "\(Int(store.cinemaScrapeProgress * 100))%" : "刮削")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(scrapeHot ? Color.black.opacity(0.88) : accentText)
            .padding(.horizontal, 13)
            .frame(height: 26)
            .background {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(scrapeFill)
                    if isScraping {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ledColor.opacity(0.85))
                            .frame(height: 1.6)
                            .padding(.horizontal, 5)
                            .padding(.bottom, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scaleEffect(x: max(0.02, store.cinemaScrapeProgress), anchor: .leading)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(scrapeHot ? ledColor.opacity(0.85)
                                            : ledColor.opacity(isDark ? 0.30 : 0.38),
                                  lineWidth: 0.8)
            }
            .shadow(color: ledColor.opacity(scrapeHot ? 0.18 : 0), radius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredScrape = $0 }
        .disabled(isScraping)
        .help(isScraping
              ? "正在刮削 \(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)"
              : "刮削这个链接下的视频")
        .contextMenu {
            Button("重新刮削全部") {
                Task { await store.scrapeCinema(for: scope, force: true) }
            }
        }
    }

    private var scrapeFill: LinearGradient {
        if scrapeHot {
            return LinearGradient(colors: [LumaBrand.amber, LumaBrand.coral],
                                  startPoint: .top, endPoint: .bottom)
        }
        if isScraping {
            return isDark
                ? LinearGradient(colors: [Color(red: 0.22, green: 0.18, blue: 0.11),
                                          Color(red: 0.10, green: 0.085, blue: 0.06)],
                                 startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color(red: 0.975, green: 0.935, blue: 0.855),
                                          Color(red: 0.925, green: 0.865, blue: 0.755)],
                                 startPoint: .top, endPoint: .bottom)
        }
        return isDark
            ? LinearGradient(colors: [Color(red: 0.19, green: 0.16, blue: 0.11),
                                      Color(red: 0.09, green: 0.08, blue: 0.06)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.992, green: 0.968, blue: 0.910),
                                      Color(red: 0.950, green: 0.912, blue: 0.820)],
                             startPoint: .top, endPoint: .bottom)
    }

    // MARK: 调校钮

    private var settingsKnob: some View {
        Button {
            settingsTab = .cinema
            openSettings()
        } label: {
            ZStack {
                Circle()
                    .fill(keyFill)
                Circle()
                    .strokeBorder(keyStroke, lineWidth: 0.8)
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hoveredSettings
                                     ? accentText
                                     : (isDark ? Color.white.opacity(0.58) : Color(white: 0.42)))
            }
            .frame(width: 24, height: 24)
            .rotationEffect(.degrees(hoveredSettings ? 24 : 0))
            .animation(.easeOut(duration: 0.22), value: hoveredSettings)
        }
        .buttonStyle(.plain)
        .onHover { hoveredSettings = $0 }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .help("影院设置")
    }

    // MARK: 面板质感

    private var engravedSeparator: some View {
        Rectangle()
            .fill(isDark
                  ? LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.12), .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                  : LinearGradient(colors: [.white.opacity(0.85), .black.opacity(0.16), .white.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
            .frame(width: 0.8, height: 17)
    }

    /// 深色是黑金放映面板，浅色是香槟银面板：顶部高光、左侧放映灯、两端螺丝与一条克制的底沿灯带。
    private var consolePlate: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(plateFill)

            // 左侧放映灯：把铭牌一侧微微照亮，而不是整条面板泛黄。
            Ellipse()
                .fill(RadialGradient(colors: [ledColor.opacity(isDark ? 0.10 : 0.14), .clear],
                                     center: .center, startRadius: 1, endRadius: 120))
                .frame(width: 260, height: 36)
                .blur(radius: 14)
                .offset(x: -140)

            // 顶部内高光。
            VStack {
                LinearGradient(colors: [topHighlight, .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 1.2)
                Spacer()
            }

            // 底沿灯带：只在中间淡淡亮起，不做整条跑马灯。
            VStack {
                Spacer()
                LinearGradient(colors: [ledColor.opacity(isDark ? 0.30 : 0.35),
                                        unmatchedColor.opacity(isDark ? 0.12 : 0.15),
                                        .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 0.8)
                    .padding(.horizontal, 18)
            }

            HStack {
                screw
                Spacer()
                screw
            }
            .padding(.horizontal, 4)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(plateStroke, lineWidth: 0.8)
        }
        .shadow(color: plateShadow, radius: 7, y: 3)
    }

    private var screw: some View {
        Circle()
            .fill(isDark
                  ? LinearGradient(colors: [.white.opacity(0.30), .black.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                  : LinearGradient(colors: [.white.opacity(0.95), .black.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 2.6, height: 2.6)
    }

    // MARK: 状态详情

    private var statusPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "film.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentText)
                Text("放映室")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                Text("CINEMA")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(settings.cinemaProvider.title) 优先")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(LinearGradient(colors: [ledColor.opacity(0.6), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            VStack(spacing: 7) {
                if let mountName {
                    popoverRow("资料库", mountName)
                }
                popoverRow("已识别", "\(matchedCount) 部")
                popoverRow("未识别", "\(unmatchedCount) 部")
                popoverRow("影片总数", "\(scopeEntries.count) 部")
            }

            if isScraping {
                HStack(spacing: 8) {
                    ProgressView(value: store.cinemaScrapeProgress)
                        .controlSize(.small)
                    Text("\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                // 文档约定 F5：铭牌浮层给「添加片源」这一项主行动。
                Button {
                    showStatus = false
                    store.presentCloudWizard()
                } label: {
                    Label("添加片源", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
                Button("重新刮削全部") {
                    showStatus = false
                    Task { await store.scrapeCinema(for: scope, force: true) }
                }
                .disabled(isScraping)
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("影院设置") {
                    showStatus = false
                    settingsTab = .cinema
                    openSettings()
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 268)
    }

    private func popoverRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - 工具栏可用宽度读数


/// 把「工具栏真正能用的宽度」报给顶栏控制台：窗口减掉左侧边栏与右侧标题位。
/// 探针放在影院页面内容里，不放在控制台内部——控制台比窗口宽时会被系统整条隐藏，
/// 里面的探针也会跟着消失，窗口缩回后就再也恢复不了。
private struct CinemaToolbarWidthReader: NSViewRepresentable {
    /// 系统工具栏右侧标题位大约占用的宽度。
    var trailingReserve: CGFloat = 230
    var onChange: (CGFloat) -> Void

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.observe(window)
        }

        override func layout() {
            super.layout()
            coordinator?.measure()
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        context.coordinator.probe = view
        context.coordinator.onChange = onChange
        context.coordinator.trailingReserve = trailingReserve
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.probe = nsView
        context.coordinator.onChange = onChange
        context.coordinator.trailingReserve = trailingReserve
        context.coordinator.observe(nsView.window)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var probe: ProbeView?
        var onChange: ((CGFloat) -> Void)?
        var trailingReserve: CGFloat = 230
        private weak var window: NSWindow?
        private var token: NSObjectProtocol?

        func observe(_ window: NSWindow?) {
            guard let window else { return }
            guard window !== self.window else { return measure() }
            self.window = window
            if let token {
                NotificationCenter.default.removeObserver(token)
            }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                           object: window,
                                                           queue: .main) { [weak self] _ in
                self?.measure()
            }
            measure()
        }

        func measure() {
            guard let window, let probe, probe.window === window else { return }
            let frame = probe.convert(probe.bounds, to: nil)
            let width = window.frame.width - frame.minX - trailingReserve
            guard width.isFinite else { return }
            // 布局过程中触发：推到下一轮再写状态，避免 «Modifying state during view update»。
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(max(0, width))
            }
        }

        deinit {
            if let token {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}

// MARK: - 筛选面板

private struct CinemaFilterPanel: View {
    let scope: CinemaScope
    let onClose: () -> Void

    @EnvironmentObject private var store: LibraryStore

    private var matchedEntries: [CinemaEntry] {
        store.cinemaEntries(for: scope).values.filter { $0.matched }
    }

    private var decades: [Int] {
        Set(matchedEntries.compactMap(\.decade)).sorted(by: >)
    }

    private var genres: [String] {
        Set(matchedEntries.flatMap { $0.genres ?? [] }).sorted()
    }

    private var matchCount: Int {
        let entries = matchedEntries.filter { store.cinemaPassesFilters($0) }
        let series = store.cinemaSeries(for: scope).filter { store.cinemaPassesFilters($0) }
        return entries.count + series.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("筛选")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(matchCount) 个条目符合")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            group("年代（可多选）") {
                chip("全部", selected: store.cinemaDecades.isEmpty) {
                    store.cinemaDecades = []
                }
                ForEach(decades, id: \.self) { decade in
                    chip("\(decade)s", selected: store.cinemaDecades.contains(decade)) {
                        var next = store.cinemaDecades
                        if next.contains(decade) { next.remove(decade) } else { next.insert(decade) }
                        store.cinemaDecades = next
                    }
                }
            }

            group("类型（可多选）") {
                chip("全部", selected: store.cinemaGenres.isEmpty) {
                    store.cinemaGenres = []
                }
                ForEach(genres, id: \.self) { genre in
                    chip(genre, selected: store.cinemaGenres.contains(genre)) {
                        var next = store.cinemaGenres
                        if next.contains(genre) { next.remove(genre) } else { next.insert(genre) }
                        store.cinemaGenres = next
                    }
                }
            }

            group("分辨率（可多选）") {
                chip("全部", selected: store.cinemaResolutions.isEmpty) {
                    store.cinemaResolutions = []
                }
                ForEach(CinemaResolutionFilter.allCases) { option in
                    chip(option.title, selected: store.cinemaResolutions.contains(option)) {
                        var next = store.cinemaResolutions
                        if next.contains(option) { next.remove(option) } else { next.insert(option) }
                        store.cinemaResolutions = next
                    }
                }
            }

            group("规格（可多选）") {
                chip("全部", selected: store.cinemaSpecFilters.isEmpty) {
                    store.cinemaSpecFilters = []
                }
                ForEach(CinemaSpecFilter.allCases) { option in
                    chip(option.title, selected: store.cinemaSpecFilters.contains(option)) {
                        var next = store.cinemaSpecFilters
                        if next.contains(option) { next.remove(option) } else { next.insert(option) }
                        store.cinemaSpecFilters = next
                    }
                }
            }

            group("观看状态（可多选）") {
                chip("全部", selected: store.cinemaWatchFilters.isEmpty) {
                    store.cinemaWatchFilters = []
                }
                ForEach(CinemaWatchFilter.allCases) { option in
                    chip(option.title, selected: store.cinemaWatchFilters.contains(option)) {
                        var next = store.cinemaWatchFilters
                        if next.contains(option) { next.remove(option) } else { next.insert(option) }
                        store.cinemaWatchFilters = next
                    }
                }
            }

            group("智能") {
                chip("高分 8+", selected: store.cinemaSmartHighRated) {
                    store.cinemaSmartHighRated.toggle()
                }
                chip("最近 30 天", selected: store.cinemaSmartRecent) {
                    store.cinemaSmartRecent.toggle()
                }
            }

            group("我的") {
                chip("仅看收藏", selected: store.cinemaFavoritesOnly) {
                    store.cinemaFavoritesOnly.toggle()
                }
                ForEach(store.cinemaLists) { list in
                    chip("\(list.name) \(list.count)",
                         selected: store.cinemaActiveListID == list.id) {
                        store.cinemaActiveListID = store.cinemaActiveListID == list.id ? nil : list.id
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("重置") { reset() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6, alignment: .leading)],
                      alignment: .leading,
                      spacing: 6) {
                content()
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(selected ? LumaBrand.amber.opacity(0.18)
                                     : Color.primary.opacity(0.055),
                            in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(selected ? LumaBrand.amber.opacity(0.5) : Color.clear,
                                      lineWidth: 0.8)
                }
                .foregroundStyle(selected ? LumaBrand.amber : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func reset() {
        store.resetCinemaFilters()
    }
}

/// 海报卡尺寸：海报墙里跟随网格列宽（按 2:3 由宽度推高），书架里固定 156×234。
/// 这样卡片描边和海报内容始终是同一个矩形，边缘不会再留出空白带。
private struct CinemaWallCardSizing: ViewModifier {
    let fillWidth: Bool

    func body(content: Content) -> some View {
        if fillWidth {
            content.aspectRatio(2.0 / 3.0, contentMode: .fit)
        } else {
            content.frame(width: 156, height: 234)
        }
    }
}

private struct CinemaSeriesCard: View {
    let series: CinemaSeries
    let hovered: Bool
    /// 海报墙里跟随网格列宽（外框和海报永远同宽）；书架里固定 156×234。
    var fillWidth: Bool = false
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    @EnvironmentObject private var store: LibraryStore

    /// 单独声明，避免 body 里的表达式类型检查超时。
    private var overlayGradient: LinearGradient {
        LinearGradient(colors: [Color.clear,
                                Color.black.opacity(0.10),
                                Color.black.opacity(0.72)],
                       startPoint: .center,
                       endPoint: .bottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if series.artworkURL != nil {
                        CinemaArtwork(urlString: series.artworkURL, contentMode: .fill)
                    } else if let latest = series.latestEpisode {
                        PhotoThumbnailView(photo: latest.file.photoItem, purpose: .cover(156))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                overlayGradient

                VStack(alignment: .leading, spacing: 3) {
                    Text(series.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(series.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .padding(9)

                VStack {
                    // 157pt 的竖版卡：左上只放最重要的 1–2 个音画角标，右上留评分。
                    HStack(alignment: .top, spacing: 5) {
                        CinemaSpecBadges(tags: cinemaBadgeTags(series.latestEpisode?.file),
                                         fontSize: 8)
                            .frame(width: 102, alignment: .leading)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            if !series.isMatched {
                                Text("未识别")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(.black.opacity(0.48), in: Capsule())
                            } else if let rating = series.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
            }
            .modifier(CinemaWallCardSizing(fillWidth: fillWidth))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: hovered ? 1.2 : 0.5)
            }
            // 悬停只加深描边与投影，不再放大卡片：放大后描边会溢出格子，外框和海报对不齐。
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .animation(.easeOut(duration: 0.16), value: hovered)
        }
        .frame(maxWidth: fillWidth ? .infinity : 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onOpen)
        .help("\(series.title) · \(series.subtitle)")
        .contextMenu {
            Button("查看 \(series.episodeCount) 集") { onOpen() }
            Divider()
            Button("忽略整部剧（以后不刮削）") {
                store.ignoreCinemaSeries(series)
            }
            Button("删除整部剧文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries(series.episodes, title: series.title)
            }
        }
        .id("series-\(series.id)")
    }
}

// MARK: - 剧集主视觉

private struct CinemaSeriesHeroCard: View {
    let series: CinemaSeries
    var onPlay: (() -> Void)? = nil
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: series.backdropURL ?? series.posterURL, contentMode: .fill)
                .frame(height: 260)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.30), .black.opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(series.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(series.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    if let rating = series.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                }
                let heroTags = cinemaBadgeTags(series.latestEpisode?.file)
                if !heroTags.isEmpty {
                    CinemaSpecBadges(tags: heroTags,
                                     fontSize: 10.5,
                                     background: .white.opacity(0.16))
                        .frame(maxWidth: 620, alignment: .leading)
                }
                if let overview = series.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                Button(action: onOpen) {
                    Label("查看 \(series.episodeCount) 集", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white.opacity(hover ? 0.95 : 0.88), in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .padding(.top, 2)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - 剧集分集

private struct CinemaSeriesDetailView: View {
    let series: CinemaSeries
    let onPlay: (CinemaEntry) -> Void
    /// 演职员页里点开另一部作品：交给上层替换详情目标。
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    /// 顶栏「返回」：没有二级页时关闭整个详情。
    var onClose: () -> Void = {}

    @EnvironmentObject private var store: LibraryStore
    @State private var hoveredEpisode: UUID?
    /// 集卡的两段式操作：第一次点击只选中，第二次点击才播放。
    @State private var selectedEpisodeID: UUID?
    @State private var enriched: CinemaEntry?
    /// 当前季的单集标题 / 简介 / 剧照（TMDB 按季拉取）。
    @State private var episodeInfos: [Int: CinemaEpisodeInfo] = [:]
    /// 当前查看的季；nil 时跟随「下一集」所在季。
    @State private var selectedSeason: Int?
    /// 演职员 → 人物页。
    @State private var personTarget: CinemaCastMember?
    /// 预告片：页面内播放层，不打开浏览器。
    @State private var showTrailer = false
    /// 档案卡里的长简介：默认收 5 行。
    @State private var dossierExpanded = false
    /// 片头尾自动识别进行中。
    @State private var detectingIntro = false
    /// 片头设置范围：整部剧默认值，或只覆盖某一集。
    @State private var introScope: IntroScope = .series
    /// 跳过片头尾的调节面板。
    @State private var showIntroPanel = false
    /// 剧集网格的键盘焦点：方向键选择、空格播放，和图库网格一致。
    @FocusState private var episodeGridFocus: Bool
    /// 网格实际宽度：用来算上下键跨几列。
    @State private var episodeGridWidth: CGFloat = 0
    /// 悬停档案实际高度：贴到底部时把面板整体上移，内容不会被裁掉。
    @State private var hoverPanelHeight: CGFloat = 340
    /// 悬停档案的延迟关闭：鼠标可以从集卡挪到面板上，不立刻消失。
    @State private var hoverDismissTask: DispatchWorkItem?
    /// 鼠标是否正停在档案面板上：这时下面的集卡不能把面板抢走。
    @State private var hoverPanelHovered = false

    private enum IntroScope: Hashable {
        case series
        case episode
    }

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)]

    var body: some View {
        ZStack {
            pageContent
                .opacity(personTarget == nil ? 1 : 0)
                .allowsHitTesting(personTarget == nil)
            if let member = personTarget {
                // 演职员改成页面内二级页：不弹窗，顶栏「返回」逐层后退。
                CinemaPersonDetailView(
                    member: member,
                    onOpenEntry: { entry in
                        personTarget = nil
                        onOpenEntry(entry)
                    },
                    onPlay: onPlay
                )
                .id(member.id)
                .transition(.opacity)
            }
            if showTrailer, let request = trailerRequest {
                // 预告片在页面内播放：不打开浏览器。
                CinemaTrailerOverlay(request: request) {
                    showTrailer = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: personTarget?.id)
        .animation(.easeOut(duration: 0.16), value: showTrailer)
        // 悬停档案挂在整个详情页最上层（在 ScrollView 之外）：贴着集卡显示，
        // 但会被收进窗口可视范围，卡片在边缘时也不会被裁掉。
        .overlayPreferenceValue(CinemaEpisodeAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if personTarget == nil, !showTrailer,
                   let episode = hoverPanelEpisode,
                   let anchor = anchors[episode.id] {
                    let rect = proxy[anchor]
                    let margin: CGFloat = 12
                    let gap: CGFloat = 14
                    let width = min(380, max(260, proxy.size.width - margin * 2))
                    let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                    let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                    let x = min(max(margin, rawX), max(margin, proxy.size.width - width - margin))
                    let y = min(max(margin, rect.minY),
                                max(margin, proxy.size.height - hoverPanelHeight - margin))
                    episodeHoverCard(episode)
                        .frame(width: width)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { hoverPanelHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { _, height in
                                        hoverPanelHeight = height
                                    }
                            }
                        }
                        .offset(x: x, y: y)
                        // 换集时换成新的身份：面板就地淡入淡出，不会从上一张卡横着滑过来。
                        .id(episode.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                            removal: .opacity))
                        // 面板本身可悬停：鼠标挪上来不会消失，可以读完简介、选中复制路径。
                        .onHover { hovering in
                            hoverPanelHovered = hovering
                            if hovering {
                                hoverDismissTask?.cancel()
                                hoverDismissTask = nil
                            } else {
                                scheduleHoverDismiss()
                            }
                        }
                        .onDisappear { hoverPanelHovered = false }
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: hoverPanelEpisode?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cinemaSheetBackground)
        // 只把详情内容切成深色影院风，不改整个窗口外观。
        .environment(\.colorScheme, .dark)
        .task {
            let sample = series.episodes.first(where: { $0.backdropURL != nil })
                ?? series.episodes.first
            guard let sample else { return }
            enriched = await store.enrichCinemaEntry(sample)
            // 打开详情时顺手补一次在线片头片尾：没设置过的剧集自动填上。
            await store.ensureCinemaIntroMark(for: series)
        }
        .task(id: seasonInfoKey) {
            // 切季 / 换剧后旧的选中集已经不在当前列表里。
            selectedEpisodeID = nil
            await loadEpisodeInfos()
        }
        // 顶栏返回：先关预告片，再退演职员页，最后退剧集详情。
        .onChange(of: store.cinemaDetailCloseTick) { _, _ in
            if showTrailer {
                showTrailer = false
            } else if personTarget != nil {
                personTarget = nil
            } else {
                onClose()
            }
        }
        // 进播放器时把键盘交出去，回来后还给剧集网格。
        .onChange(of: store.viewerID) { _, viewing in
            episodeGridFocus = viewing == nil
        }
        .onChange(of: showTrailer) { _, showing in
            if !showing { episodeGridFocus = true }
        }
        .onChange(of: personTarget?.id) { _, current in
            if current == nil { episodeGridFocus = true }
        }
    }

    private var pageContent: some View {
        ZStack {
            ambientBackground
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dossierSection
                    episodesSection
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 36)
                .frame(maxWidth: 1440, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
    }

    /// 剧集详情用剧照虚化铺底：贴着 Hero 往下渐隐到纯深色，
    /// 不再用固定高度硬切，避免中间出现一条突兀的亮色横带。
    private var ambientBackground: some View {
        ZStack(alignment: .top) {
            cinemaSheetBackground
            CinemaArtwork(urlString: series.backdropURL ?? series.posterURL, contentMode: .fill)
                .frame(height: 760)
                .blur(radius: 90, opaque: true)
                .opacity(0.20)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.80), location: 0.38),
                        .init(color: .black.opacity(0.28), location: 0.72),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var seasonInfoKey: String {
        guard currentSeason > 0,
              let tvID = series.episodes.first(where: { $0.tmdbID != nil && $0.provider == .tmdb })?.tmdbID else { return "" }
        return "\(tvID)-\(currentSeason)"
    }

    /// 每集标题 / 简介 / 剧照：先用本地缓存秒开，超过 12 小时再后台补一次最新。
    private func loadEpisodeInfos() async {
        guard currentSeason > 0,
              let tvID = series.episodes.first(where: { $0.tmdbID != nil && $0.provider == .tmdb })?.tmdbID else { return }
        let cached = store.cachedCinemaEpisodeInfos(tvID: tvID, season: currentSeason)
        if let cached {
            episodeInfos = cached.infos
            if cached.fresh { return }
        }
        guard let refreshed = await store.refreshCinemaEpisodeInfos(tvID: tvID, season: currentSeason) else { return }
        guard !Task.isCancelled else { return }
        episodeInfos = refreshed
    }

    // MARK: 季与下一集

    private var orderedEpisodes: [CinemaEntry] {
        series.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
    }

    private var seasons: [Int] {
        Array(Set(orderedEpisodes.map { $0.season ?? 0 })).sorted()
    }

    private var currentSeason: Int {
        selectedSeason ?? nextEpisode.map { $0.season ?? 0 } ?? seasons.first ?? 0
    }

    private var visibleEpisodes: [CinemaEntry] {
        guard seasons.count > 1 else { return orderedEpisodes }
        return orderedEpisodes.filter { ($0.season ?? 0) == currentSeason }
    }

    /// 悬停档案跟随哪一集：鼠标悬停和键盘选中共用同一个状态，
    /// 键盘切换时由 moveEpisodeCursor 把悬停集同步过来，档案才会跟着焦点走。
    private var hoverPanelEpisode: CinemaEntry? {
        guard let id = hoveredEpisode else { return nil }
        return visibleEpisodes.first(where: { $0.id == id })
    }

    /// 鼠标进入集卡或档案面板：取消待关闭，并把档案锁到这一集。
    private func holdHoverPanel(_ id: UUID) {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        // 鼠标在面板上时，面板下面的集卡会继续发 hover，别让它把面板抢走。
        guard !hoverPanelHovered else { return }
        if hoveredEpisode != id {
            hoveredEpisode = id
        }
    }

    /// 离开集卡或面板：留一小段时间再收起，鼠标可以横跨间隙挪到面板上。
    private func scheduleHoverDismiss() {
        hoverDismissTask?.cancel()
        let work = DispatchWorkItem {
            hoveredEpisode = nil
        }
        hoverDismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    /// 优先正在看的一集；否则接在最后看完的一集后面；全部看完返回 nil。
    private var nextEpisode: CinemaEntry? {
        let ordered = orderedEpisodes
        guard !ordered.isEmpty else { return nil }
        if let inProgress = ordered.first(where: { store.cinemaWatchState(for: $0) == .inProgress }) {
            return inProgress
        }
        if let lastFinished = ordered.lastIndex(where: { store.cinemaWatchState(for: $0) == .finished }) {
            let next = lastFinished + 1
            guard next < ordered.count else { return nil }
            return ordered[next]
        }
        return ordered.first
    }

    /// 跳过片头尾：和「继续播放 / 预告片」同高的胶囊，点开是滑杆面板。
    private var introSkipControl: some View {
        let mark = activeIntroMark
        return Button {
            showIntroPanel.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "scissors")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(LumaBrand.amber.opacity(mark.isEnabled ? 1 : 0.55))

                Text("跳过片头尾")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))

                Text(introSummaryText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(mark.isEnabled ? LumaBrand.amber.opacity(0.95)
                                                    : Color.white.opacity(0.45))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 170)
            .background {
                Capsule()
                    .fill(mark.isEnabled ? LumaBrand.amber.opacity(0.16)
                                         : Color.white.opacity(0.14))
            }
            .overlay {
                Capsule()
                    .strokeBorder(mark.isEnabled ? LumaBrand.amber.opacity(0.42)
                                                 : Color.white.opacity(0.10),
                                  lineWidth: 0.7)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showIntroPanel, arrowEdge: .bottom) {
            introSkipPanel
        }
        .help("设置片头 / 片尾跳过的秒数；可以按整部剧或只对当前集生效")
    }

    private var introSummaryText: String {
        let mark = activeIntroMark
        guard mark.isEnabled else { return "未设置" }
        var parts: [String] = []
        if mark.introSeconds > 0 { parts.append("片头 \(mark.introSeconds)s") }
        if mark.outroSeconds > 0 { parts.append("片尾 \(mark.outroSeconds)s") }
        return parts.joined(separator: " · ")
    }

    /// 调节面板：滑杆直接改秒数，自动识别、范围与清除都在这一处。
    private var introSkipPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "scissors")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LumaBrand.amber)
                Text("跳过片头片尾")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                Circle()
                    .fill(activeIntroMark.isEnabled ? LumaBrand.mint : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(activeIntroMark.isEnabled ? "已启用" : "已关闭")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text("开播时自动跳到片头结束；进入片尾区间时直接跳到结尾。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            introSliderRow(title: "片头", seconds: introSecondsBinding)
            introSliderRow(title: "片尾", seconds: outroSecondsBinding)

            HStack(spacing: 8) {
                Text("作用范围")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $introScope) {
                    Text("整部剧").tag(IntroScope.series)
                    Text(introTargetEpisode.map { "本集 \(episodeLabel($0))" } ?? "本集")
                        .tag(IntroScope.episode)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Spacer(minLength: 0)
            }
            if introScope == .episode {
                Text(activeIntroIsOverride
                     ? "本集使用单独设置，修改只影响这一集。"
                     : "本集尚未单独设置，修改后自动成为本集设置。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Button {
                    Task { await runIntroAutoDetect() }
                } label: {
                    Label(detectingIntro ? "识别中…" : "自动识别", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(detectingIntro)

                if canClearIntro {
                    Button("清除") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if introScope == .episode, let episode = introTargetEpisode {
                                store.clearCinemaEpisodeIntroMark(for: episode)
                            } else {
                                store.setCinemaIntroMark(CinemaIntroMark(), forSeriesKey: series.id)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 340)
        .environment(\.colorScheme, .dark)
    }

    private func introSliderRow(title: String, seconds: Binding<Int>) -> some View {
        let value = Binding<Double>(
            get: { Double(seconds.wrappedValue) },
            set: { seconds.wrappedValue = Int($0.rounded()) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 0)
                Text(seconds.wrappedValue > 0 ? "\(seconds.wrappedValue) 秒" : "关闭")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(seconds.wrappedValue > 0 ? LumaBrand.amber : Color.secondary)
            }
            Slider(value: value, in: 0...300, step: 15)
                .tint(LumaBrand.amber)
                .controlSize(.small)
        }
    }

    /// 单集覆盖的目标：优先「当前集（下一集）」，否则第一集。
    private var introTargetEpisode: CinemaEntry? {
        nextEpisode ?? orderedEpisodes.first
    }

    private var activeIntroMark: CinemaIntroMark {
        if introScope == .episode, let episode = introTargetEpisode {
            return store.cinemaIntroMark(for: episode)
        }
        return store.cinemaIntroMark(forSeriesKey: series.id)
    }

    private var activeIntroIsOverride: Bool {
        guard introScope == .episode, let episode = introTargetEpisode else { return false }
        return store.hasCinemaEpisodeIntroMark(for: episode)
    }

    private var canClearIntro: Bool {
        if introScope == .episode, let episode = introTargetEpisode {
            return store.hasCinemaEpisodeIntroMark(for: episode)
        }
        return store.cinemaIntroMark(forSeriesKey: series.id).isEnabled
    }

    private func applyIntroMark(_ mark: CinemaIntroMark) {
        if introScope == .episode, let episode = introTargetEpisode {
            store.setCinemaIntroMark(mark, for: episode)
        } else {
            store.setCinemaIntroMark(mark, forSeriesKey: series.id)
        }
    }

    /// 自动识别：整部剧取第一集，本集取当前这一集；在线库优先，本地静音检测兜底。
    private func runIntroAutoDetect() async {
        guard !detectingIntro else { return }
        detectingIntro = true
        defer { detectingIntro = false }
        let episode = introScope == .episode ? introTargetEpisode : nil
        let detection: LibraryStore.CinemaIntroDetection?
        if let episode {
            detection = await store.detectCinemaIntro(for: episode)
        } else {
            detection = await store.detectCinemaIntro(for: series)
        }
        guard let detection else {
            store.showToast(episode == nil
                            ? "在线库没有这部剧的记录，且没有可分析的本地分集；可手动设置"
                            : "在线库没有这一集的记录，且不是可分析的本地文件；可手动设置")
            return
        }
        let mark = detection.mark
        if let episode {
            store.setCinemaIntroMark(mark, for: episode)
        } else {
            store.setCinemaIntroMark(mark, forSeriesKey: series.id)
        }
        let intro = mark.introSeconds > 0 ? "片头 \(mark.introSeconds) 秒" : "片头未识别"
        let outro = mark.outroSeconds > 0 ? "片尾 \(mark.outroSeconds) 秒" : "片尾未识别"
        let source = detection.online ? "在线库" : "本地静音检测"
        let scope = episode.map { " · \(episodeLabel($0))" } ?? ""
        store.showToast("自动识别完成（\(source)\(scope)）：\(intro) · \(outro)")
    }

    private var introSecondsBinding: Binding<Int> {
        Binding(
            get: { activeIntroMark.introSeconds },
            set: { value in
                var mark = activeIntroMark
                mark.introSeconds = value
                applyIntroMark(mark)
            }
        )
    }

    private var outroSecondsBinding: Binding<Int> {
        Binding(
            get: { activeIntroMark.outroSeconds },
            set: { value in
                var mark = activeIntroMark
                mark.outroSeconds = value
                applyIntroMark(mark)
            }
        )
    }

    /// 季下拉：18 季也不挤、不滚丢；菜单里直接带每季集数与已看数。
    private var seasonMenu: some View {
        Menu {
            ForEach(seasons, id: \.self) { season in
                Button {
                    selectedSeason = season
                } label: {
                    if season == currentSeason {
                        Label(seasonMenuLabel(season), systemImage: "checkmark")
                    } else {
                        Text(seasonMenuLabel(season))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentSeason == 0 ? "未标季" : "第 \(currentSeason) 季")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(visibleEpisodes.count) 集")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LumaBrand.amber.opacity(0.75))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LumaBrand.amber.opacity(0.75))
            }
            .foregroundStyle(LumaBrand.amber)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(LumaBrand.amber.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(LumaBrand.amber.opacity(0.34), lineWidth: 0.7)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(seasons.count > 1 ? "切换季（共 \(seasons.count) 季）" : "本季剧集")
    }

    private func seasonMenuLabel(_ season: Int) -> String {
        let name = season == 0 ? "未标季" : "第 \(season) 季"
        let episodes = orderedEpisodes.filter { ($0.season ?? 0) == season }
        let watched = episodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
        return watched > 0
            ? "\(name) · \(episodes.count) 集 · 已看 \(watched)"
            : "\(name) · \(episodes.count) 集"
    }

    /// 预告片按整部剧找：用详情补全后的条目，没有就退回本剧第一条已识别分集。
    private var trailerRequest: CinemaTrailerRequest? {
        let sample = enriched
            ?? series.episodes.first(where: { $0.backdropURL != nil })
            ?? series.episodes.first
        guard let sample, sample.matched else { return nil }
        return CinemaTrailerRequest(title: sample.title,
                                    originalTitle: sample.originalTitle,
                                    year: sample.year ?? series.year,
                                    isTV: sample.kind == .tv)
    }

    private func castStrip(_ cast: [CinemaCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                if let directors = enriched?.directors, !directors.isEmpty {
                    Text("导演 " + directors.prefix(2).joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        Button {
                            personTarget = member
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    if let url = member.profileURL {
                                        CinemaArtwork(urlString: url, contentMode: .fill)
                                    } else {
                                        Circle().fill(Color.secondary.opacity(0.18))
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                                }
                                Text(member.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text(member.character ?? " ")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 84)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("查看 \(member.name) 的人物页")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func posterCard(width: CGFloat, height: CGFloat) -> some View {
        let radius: CGFloat = width > 100 ? 10 : 5
        return ZStack {
            if let url = series.posterURL {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let first = series.episodes.first {
                PhotoThumbnailView(photo: first.file.photoItem, purpose: .cover(240))
            } else {
                Color.white.opacity(0.06)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.26), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: width > 100 ? 18 : 8, y: width > 100 ? 8 : 3)
    }

    private var actions: some View {
        // 一行放不下时自动换行：窄窗口下「跳过片头尾」不会和「预告片」叠在一起。
        CinemaBadgeFlow(spacing: 9, lineSpacing: 9) {
            if let next = nextEpisode {
                Button {
                    onPlay(next)
                } label: {
                    Label(playLabel(for: next), systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(LumaBrand.amber, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if let first = orderedEpisodes.first, first.id != nextEpisode?.id {
                Button {
                    onPlay(first)
                } label: {
                    Label("从第 1 集开始", systemImage: "backward.end.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.16), in: Capsule())
                        .foregroundStyle(.white.opacity(0.94))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if trailerRequest != nil {
                Button {
                    showTrailer = true
                } label: {
                    Label("预告片", systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.14), in: Capsule())
                        .foregroundStyle(.white.opacity(0.92))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if !orderedEpisodes.isEmpty {
                // 跳过片头尾和预告片同一行：点开就是滑杆面板，不需要记菜单层级。
                introSkipControl
            }
        }
    }

    private func playLabel(for episode: CinemaEntry) -> String {
        if let progress = store.cinemaProgress[episode.id],
           progress.fraction > 0.01, !progress.isFinished {
            return "继续播放 \(episodeLabel(episode))"
        }
        return "开始观看 \(episodeLabel(episode))"
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 多季时把季选择收进标题行：菜单里列出本地每一季的集数与已看数，
            // 18 季也不会横着滚丢当前季；只有一季时直接标明是哪一季。
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("剧集")
                    .font(.system(size: 15, weight: .semibold))
                if seasons.count > 1 {
                    seasonMenu
                } else if currentSeason > 0 {
                    Text("第 \(currentSeason) 季")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                    Text("\(visibleEpisodes.count) 集")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(visibleEpisodes.count) 集")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if hoveredEpisode == nil {
                    Text("方向键选择 · 空格播放")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            ScrollViewReader { scrollProxy in
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(visibleEpisodes) { episode in
                        episodeCard(episode)
                            .anchorPreference(key: CinemaEpisodeAnchorKey.self, value: .bounds) {
                                [episode.id: $0]
                            }
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { episodeGridWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in
                                episodeGridWidth = width
                            }
                    }
                }
                // 和图库网格一致的键盘操作：← → 逐集，↑ ↓ 跨一行，空格 / 回车播放。
                .focusable()
                .focused($episodeGridFocus)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) {
                    moveEpisodeCursor(-1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    moveEpisodeCursor(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveEpisodeCursor(-episodeColumnCount)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveEpisodeCursor(episodeColumnCount)
                    return .handled
                }
                .onKeyPress(.space) {
                    playFocusedEpisode()
                    return .handled
                }
                .onKeyPress(.return) {
                    playFocusedEpisode()
                    return .handled
                }
                .onChange(of: selectedEpisodeID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollProxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async { episodeGridFocus = true }
                }
            }
        }
    }

    /// 方向键跨一行要跳几列：按自适应网格的最小宽度估算。
    private var episodeColumnCount: Int {
        let spacing: CGFloat = 16
        let minimum: CGFloat = 230
        let width = episodeGridWidth > 0 ? episodeGridWidth : 900
        return max(1, Int((width + spacing) / (minimum + spacing)))
    }

    private func moveEpisodeCursor(_ delta: Int) {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        let list = visibleEpisodes
        guard !list.isEmpty else { return }
        guard let id = selectedEpisodeID,
              let current = list.firstIndex(where: { $0.id == id }) else {
            // 还没有选中：先从「下一集」开始。
            let target = nextEpisode ?? list[0]
            selectedEpisodeID = target.id
            hoveredEpisode = target.id
            return
        }
        let next = min(max(current + delta, 0), list.count - 1)
        selectedEpisodeID = list[next].id
        // 键盘切换时把悬停指针一起挪过去，档案面板跟着焦点走而不是停在鼠标下面。
        hoveredEpisode = list[next].id
    }

    private func playFocusedEpisode() {
        guard store.viewerID == nil else { return }
        let list = visibleEpisodes
        guard !list.isEmpty else { return }
        if let id = selectedEpisodeID, let episode = list.first(where: { $0.id == id }) {
            onPlay(episode)
        } else if let target = nextEpisode ?? list.first {
            selectedEpisodeID = target.id
            onPlay(target)
        }
    }

    // MARK: 剧集档案

    /// 剧集档案：把海报、简介、资料与演职员收进同一张卡片。
    /// 海报作视觉锚点，右侧按「原名 / 宣传语 → 简介 → 带图标的资料网格」排，
    /// 底部接演职员，不再让三块内容各占一整行。
    private var dossierSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                dossierPosterColumn
                VStack(alignment: .leading, spacing: 14) {
                    dossierKicker
                    dossierTitleBlock
                    dossierSynopsis
                    dossierFactsGrid
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22)

            if let cast = enriched?.cast, !cast.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                castStrip(cast)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
        }
        .background { dossierPlate }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            Color.white.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
    }

    /// 档案卡底板：深色玻璃 + 左上角一层很淡的琥珀光，和海报的暖色调衔接。
    private var dossierPlate: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.062),
                                          Color.white.opacity(0.022)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
    }

    /// 海报 + 评分牌 + 整剧观看进度：三者共用一列，宽度和海报对齐。
    private var dossierPosterColumn: some View {
        VStack(spacing: 9) {
            posterCard(width: 156, height: 234)
                .shadow(color: LumaBrand.amber.opacity(0.18), radius: 22, y: 10)

            if let rating = seriesRating {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if let votes = enriched?.voteCount, votes > 0 {
                        Text("· \(voteCountText(votes))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.white.opacity(0.07), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6) }
            }

            if watchedCount > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: Double(watchedCount),
                                 total: Double(max(1, orderedEpisodes.count)))
                        .progressViewStyle(.linear)
                        .tint(LumaBrand.amber)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    Text("已看 \(watchedCount) / \(orderedEpisodes.count) 集")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: 156)
            }
        }
        .frame(width: 156, alignment: .top)
    }

    /// 档案抬头：琥珀刻字标签 + 年份 / 季 / 集 + 播出状态。
    private var dossierKicker: some View {
        HStack(spacing: 8) {
            Text("剧集档案")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(LumaBrand.amber.opacity(0.92))
            Rectangle()
                .fill(LumaBrand.amber.opacity(0.35))
                .frame(width: 24, height: 0.8)
            Text(dossierMetaLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
            dossierStatusPill
        }
    }

    /// 片名 / 原名 / 宣传语 / 播放动作：去掉大幅剧照后，这一块承担页面标题。
    private var dossierTitleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(series.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .textSelection(.enabled)

            if let original = enriched?.originalTitle,
               !original.isEmpty,
               original.caseInsensitiveCompare(series.title) != .orderedSame {
                Text(original.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            if let tagline = enriched?.tagline, !tagline.isEmpty {
                Text("「\(tagline)」")
                    .font(.system(size: 12, weight: .medium))
                    .italic()
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }

            actions
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var dossierStatusPill: some View {
        if let status = cinemaStatusText(enriched?.status) {
            let running = enriched?.status == "Returning Series"
                || enriched?.status == "In Production"
                || enriched?.status == "Planned"
            HStack(spacing: 5) {
                Circle()
                    .fill(running ? LumaBrand.mint : Color.white.opacity(0.32))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(running ? LumaBrand.mint : Color.white.opacity(0.72))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6) }
        }
    }

    /// 简介：默认收 5 行，长简介可展开；没有简介时提示换数据源。
    @ViewBuilder
    private var dossierSynopsis: some View {
        let overview = enriched?.overview ?? series.overview ?? ""
        if overview.isEmpty {
            Text("暂无剧情简介。可以在顶栏面板里「重新匹配」换一个数据源，通常会补全简介与演职员。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(overview)
                    .font(.system(size: 12.8))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(6)
                    .lineLimit(dossierExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 860, alignment: .leading)
                    .textSelection(.enabled)
                if overview.count > 180 {
                    Button(dossierExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            dossierExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        }
    }

    /// 资料网格：每项一枚琥珀小图标 + 标签 / 值，和海报卡同一张底板上。
    private var dossierFactsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 178, maximum: 268), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            ForEach(dossierFacts) { fact in
                HStack(spacing: 9) {
                    Image(systemName: fact.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber.opacity(0.90))
                        .frame(width: 24, height: 24)
                        .background(LumaBrand.amber.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                        Text(fact.value)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
    }

    private struct DossierFact: Identifiable {
        let icon: String
        let label: String
        let value: String
        var id: String { label + "|" + value }
    }

    /// 本地与 TMDB 能拿到的资料项都在这里，缺哪项就不占位。
    private var dossierFacts: [DossierFact] {
        var items: [DossierFact] = []
        if let value = cinemaDateText(enriched?.releaseDate) ?? series.year.map({ "\($0) 年" }) {
            items.append(DossierFact(icon: "calendar", label: "首播", value: value))
        }
        if let value = seasonCountText {
            items.append(DossierFact(icon: "rectangle.stack", label: "季数", value: value))
        }
        if let value = episodeCountText {
            items.append(DossierFact(icon: "list.number", label: "集数", value: value))
        }
        if let value = cinemaMinutesText(enriched?.runtime) {
            items.append(DossierFact(icon: "clock", label: "单集", value: value))
        }
        let sampleFile = enriched?.file ?? series.episodes.first?.file
        if let value = sampleFile?.displayTags.first(where: { $0 == "DV" || $0.hasPrefix("HDR") }) {
            items.append(DossierFact(icon: "sparkles.tv",
                                     label: "HDR",
                                     value: value == "DV" ? "Dolby Vision" : value))
        }
        if sampleFile?.displayTags.contains("Atmos") == true {
            items.append(DossierFact(icon: "hifispeaker.2", label: "音轨", value: "Dolby Atmos"))
        }
        if let fps = sampleFile?.parsedFrameRate {
            items.append(DossierFact(icon: "speedometer", label: "帧率", value: "\(fps) fps"))
        }
        if let value = enriched?.genres?.prefix(4).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "theatermasks", label: "类型", value: value))
        }
        if let value = enriched?.certification, !value.isEmpty {
            items.append(DossierFact(icon: "shield.lefthalf.filled", label: "分级", value: value))
        }
        if let value = cinemaLanguageName(enriched?.originalLanguage) {
            items.append(DossierFact(icon: "character.bubble", label: "语言", value: value))
        }
        if let countries = enriched?.countries, !countries.isEmpty {
            let value = countries.prefix(2).map(cinemaCountryName).joined(separator: " / ")
            items.append(DossierFact(icon: "globe.asia.australia", label: "国家", value: value))
        }
        if let value = enriched?.networks?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "antenna.radiowaves.left.and.right", label: "平台", value: value))
        }
        if let value = enriched?.companies?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "building.2", label: "制作", value: value))
        }
        if let value = enriched?.collectionName, !value.isEmpty {
            items.append(DossierFact(icon: "square.stack.3d.up", label: "合集", value: value))
        }
        if let id = enriched?.tmdbID {
            let label = enriched?.provider == .tvdb ? "TVDB" : "TMDB"
            items.append(DossierFact(icon: "number", label: label, value: "\(id)"))
        }
        return items
    }

    private var dossierMetaLine: String {
        var parts: [String] = []
        if let year = enriched?.year ?? series.year, year > 0 {
            parts.append("\(year)")
        }
        if let seasons = seasonCountText {
            parts.append(seasons)
        }
        if let episodes = episodeCountText {
            parts.append(episodes)
        }
        return parts.joined(separator: " · ")
    }

    private var seriesRating: Double? {
        let rating = enriched?.rating ?? series.rating
        guard let rating, rating > 0 else { return nil }
        return rating
    }

    private var watchedCount: Int {
        orderedEpisodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
    }

    private func voteCountText(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f 万人评分", Double(votes) / 10_000)
        }
        return "\(votes) 人评分"
    }

    private var seasonCountText: String? {
        let count = enriched?.seasonCount ?? (seasons.filter { $0 > 0 }.isEmpty ? nil : seasons.filter { $0 > 0 }.count)
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 季" : "\(count) 季"
    }

    private var episodeCountText: String? {
        let total = enriched?.episodeTotal ?? series.episodeCount
        return total > 0 ? "\(total) 集" : nil
    }

    private func minutesText(_ duration: Double?) -> String? {
        guard let duration, duration > 0 else { return nil }
        let minutes = Int((duration / 60).rounded())
        return minutes > 0 ? "\(minutes) 分钟" : nil
    }

    private func episodeCard(_ episode: CinemaEntry) -> some View {
        let watchState = store.cinemaWatchState(for: episode)
        let progress = store.cinemaProgress[episode.id]
        let hovered = hoveredEpisode == episode.id
        let selected = selectedEpisodeID == episode.id
        // 文档约定：当前集用琥珀描边标出，不靠 hover 才看得出「接着看哪一集」。
        let isCurrent = nextEpisode?.id == episode.id
        let info = episode.episode.flatMap { episodeInfos[$0] }
        // 单集剧照优先：TMDB 季接口给的 still 比整部剧的 backdrop 更能区分每一集。
        let artworkURL = info?.stillURL ?? episode.gridArtworkURL
        // 观看状态压在画面里，卡片下面不再重复一行「集号 + 未看」。
        let statusText: String = {
            if watchState == .finished { return "已看完" }
            if let progress, progress.fraction > 0.01 { return "上次看到 \(Int(progress.fraction * 100))%" }
            return isCurrent ? "当前集" : "未看"
        }()
        return Button {
            episodeGridFocus = true
            if selected {
                onPlay(episode)
            } else {
                // 第一次点击先选中并露出播放按钮，第二次点击才真正开播。
                withAnimation(.snappy(duration: 0.18)) {
                    selectedEpisodeID = episode.id
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            Group {
                                if let artworkURL {
                                    CinemaArtwork(urlString: artworkURL, contentMode: .fill)
                                } else {
                                    PhotoThumbnailView(photo: episode.file.photoItem, purpose: .cover(300))
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .opacity(watchState == .finished ? 0.70 : 1)

                    Text(episodeLabel(episode))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                }
                .overlay(alignment: .topLeading) {
                    // 状态标记从卡片下方挪进画面：未看 / 上次看到 N% / 已看完 / 当前集。
                    Text(statusText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(watchState == .finished ? LumaBrand.mint
                                         : (isCurrent || (progress?.fraction ?? 0) > 0.01
                                            ? LumaBrand.amber : Color.white.opacity(0.88)))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            if let progress, progress.fraction > 0.01 {
                                Rectangle()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(2.0, geo.size.width * progress.fraction))
                            }
                        }
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black.opacity(0.20))
                    }
                }
                .overlay(alignment: .center) {
                    if selected || hovered {
                        episodePlayBadge(selected: selected)
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            selected ? LumaBrand.amber
                                : (hovered ? LumaBrand.amber.opacity(0.7)
                                    : (isCurrent ? LumaBrand.amber.opacity(0.85)
                                                 : Color.primary.opacity(0.08))),
                            lineWidth: selected ? 2.2 : (hovered ? 1.2 : (isCurrent ? 1.6 : 0.6)))
                }
                .shadow(color: selected ? LumaBrand.amber.opacity(0.30) : .clear,
                        radius: 10, y: 2)

                Text(episodeTitleText(episode, info: info))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovering in
            if hovering {
                holdHoverPanel(episode.id)
            } else if hoveredEpisode == episode.id {
                scheduleHoverDismiss()
            }
        }
        .help(selected ? "再次点击播放 \(episodeLabel(episode))" : "点击选中，再点播放")
        .contextMenu {
            Button("播放") { onPlay(episode) }
            Button("忽略（以后不刮削）") { store.ignoreCinemaEntry(episode) }
            Divider()
            Button("删除视频文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries([episode], title: episodeLabel(episode))
            }
        }
    }

    /// 集卡中央的播放按钮：悬停时半透明，选中后变成实心琥珀，提示「再点一下就播」。
    private func episodePlayBadge(selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? LumaBrand.amber : Color.black.opacity(0.44))
            if !selected {
                Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            }
            Image(systemName: "play.fill")
                .font(.system(size: selected ? 19 : 15, weight: .bold))
                .foregroundStyle(selected ? Color.black : Color.white)
                .offset(x: selected ? 1.5 : 1)
        }
        .frame(width: selected ? 52 : 42, height: selected ? 52 : 42)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .shadow(color: selected ? LumaBrand.amber.opacity(0.35) : .clear, radius: 12)
    }

    private func episodeTitleText(_ episode: CinemaEntry, info: CinemaEpisodeInfo?) -> String {
        if let title = info?.title, !title.isEmpty { return title }
        if let number = episode.episode { return "第 \(number) 集" }
        return "未命名单集"
    }

    private func episodeLabel(_ episode: CinemaEntry) -> String {
        if let season = episode.season, let number = episode.episode {
            if let end = episode.episodeEnd, end > number {
                return String(format: "S%02dE%02d-E%02d", season, number, end)
            }
            return String(format: "S%02dE%02d", season, number)
        }
        if let number = episode.episode { return String(format: "EP%02d", number) }
        return "EP"
    }

    // MARK: 悬停档案

    /// 悬停集卡时弹出的完整档案：剧照、完整简介、进度、规格与文件名一次看全。
    /// 宽度固定、浮在卡片侧边，鼠标本身仍在集卡上，所以不做交互（避免遮挡点击）。
    private func episodeHoverCard(_ episode: CinemaEntry) -> some View {
        let info = episode.episode.flatMap { episodeInfos[$0] }
        let progress = store.cinemaProgress[episode.id]
        let artworkURL = info?.stillURL ?? episode.gridArtworkURL
        let tags = cinemaBadgeTags(episode.file, limit: 4)
        let overview = info?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            // 剧照上只留标签，不再压标题：标题挪到正文区，靠深底提升可读性。
            Group {
                if let artworkURL {
                    CinemaArtwork(urlString: artworkURL, contentMode: .fill)
                } else {
                    PhotoThumbnailView(photo: episode.file.photoItem, purpose: .cover(480))
                }
            }
            .frame(height: 158)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 62)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(episodeLabel(episode))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(LumaBrand.amber, in: Capsule())
                    if let progress, progress.isFinished {
                        hoverChip("已看完", tint: LumaBrand.mint, darkText: true)
                    } else if let progress, progress.fraction > 0.01 {
                        hoverChip("上次看到 \(Int(progress.fraction * 100))%")
                    } else {
                        hoverChip("未看")
                    }
                }
                .padding(11)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(episodeTitleText(episode, info: info))
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress, progress.fraction > 0.01 {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.14))
                                Capsule()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(3, geo.size.width * progress.fraction))
                            }
                        }
                        .frame(height: 3)
                        HStack(spacing: 6) {
                            Text(progress.isFinished ? "已看完整集" : "已看 \(Int(progress.fraction * 100))%")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(LumaBrand.amber)
                            Spacer(minLength: 0)
                            if !progress.isFinished,
                               let remaining = minutesText(progress.remainingSeconds) {
                                Text("剩余 \(remaining)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }

                if overview.isEmpty {
                    Text("暂无单集简介")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tags.isEmpty {
                    CinemaSpecBadges(tags: tags, fontSize: 9, tint: .white,
                                     background: Color.white.opacity(0.10))
                }

                HStack(spacing: 12) {
                    if let minutes = minutesText(episode.file.duration) {
                        hoverFact("clock", minutes)
                    }
                    if episode.file.fileSize > 0 {
                        hoverFact("internaldrive",
                                  ByteCountFormatter.string(fromByteCount: episode.file.fileSize,
                                                            countStyle: .file))
                    }
                    hoverFact(episode.file.isCloud ? "cloud" : "folder",
                              episode.file.isCloud ? "网盘" : "本地")
                    Spacer(minLength: 0)
                }

                let techFacts = hoverTechFacts(episode.file)
                if !techFacts.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(techFacts, id: \.text) { fact in
                            hoverFact(fact.icon, fact.text)
                        }
                        Spacer(minLength: 0)
                    }
                }

                // 路径用「来源胶囊 + 目录链」展示：中间省略，可选中复制。
                if let location = hoverFileLocation(episode) {
                    HStack(spacing: 6) {
                        Image(systemName: location.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber.opacity(0.82))
                        Text(location.source)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.10), in: Capsule())
                        Text(location.path)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.6)
                    .padding(.top, 1)

                HStack(spacing: 5) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 9, weight: .semibold))
                    Text("点一下选中 · 再点一下播放")
                        .font(.system(size: 10))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.48))

                Text(episode.file.filename)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 14)
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(red: 0.075, green: 0.08, blue: 0.095))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.015)],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.26), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.58), radius: 26, y: 13)
    }

    private func hoverChip(_ text: String, tint: Color = .white, darkText: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(darkText ? Color.black : tint.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(darkText ? 1 : 0.18), in: Capsule())
    }

    private func hoverFact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(LumaBrand.amber.opacity(0.75))
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// 悬停档案的技术信息：分辨率 / 编码 / 码率（按文件大小与时长估算）。
    private func hoverTechFacts(_ file: CinemaFile) -> [(icon: String, text: String)] {
        var facts: [(icon: String, text: String)] = []
        if file.pixelWidth > 0, file.pixelHeight > 0 {
            facts.append(("rectangle.inset.filled", "\(file.pixelWidth)×\(file.pixelHeight)"))
        }
        if let codec = file.videoCodec, !codec.isEmpty {
            facts.append(("film", codec.uppercased()))
        }
        if let duration = file.duration, duration > 1, file.fileSize > 0 {
            let mbps = Double(file.fileSize) * 8 / duration / 1_000_000
            facts.append(("speedometer", String(format: "≈ %.0f Mbps", mbps)))
        }
        return facts
    }

    /// 悬停档案的存放位置：网盘名 + 目录链；本地用刮削时的目录提示。
    private func hoverFileLocation(_ episode: CinemaEntry) -> (icon: String, source: String, path: String)? {
        let file = episode.file
        if let mountID = file.cloudMountID {
            let name = store.cloudMounts.first(where: { $0.id == mountID })?.name ?? "网盘"
            let raw = file.cloudPath ?? ""
            let folder = (raw as NSString).deletingLastPathComponent
            let path = folder.isEmpty ? (episode.folderHint ?? raw) : folder
            return ("cloud", name, path.isEmpty ? "/" : path)
        }
        if let hint = episode.folderHint, !hint.isEmpty {
            return ("folder", "本地", hint)
        }
        return ("folder", "本地", "图库")
    }
}

// MARK: - 主视觉卡片

private struct CinemaHeroCard: View {
    let entry: CinemaEntry
    let onPlay: () -> Void
    let onDetail: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: entry.backdropURL ?? entry.posterURL, contentMode: .fill)
                .frame(height: 260)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.30), .black.opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    if let rating = entry.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                    if entry.kind == .tv {
                        Text("剧集")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                let heroTags = cinemaBadgeTags(entry.file)
                if !heroTags.isEmpty {
                    CinemaSpecBadges(tags: heroTags,
                                     fontSize: 10.5,
                                     background: .white.opacity(0.16))
                        .frame(maxWidth: 620, alignment: .leading)
                }
                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.white.opacity(hover ? 0.95 : 0.88), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .onHover { hover = $0 }

                    Button(action: onDetail) {
                        Label("详情", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onDetail)
    }
}

// MARK: - 海报卡片

private struct CinemaPosterCard: View {
    let entry: CinemaEntry
    let hovered: Bool
    /// 海报墙里跟随网格列宽；书架里固定 156×234。
    var fillWidth: Bool = false
    let onHover: (Bool) -> Void
    let onOpen: () -> Void
    var onPlay: (() -> Void)? = nil
    var onDetail: (() -> Void)? = nil

    @EnvironmentObject private var store: LibraryStore
    @AppStorage("cinema_show_rating_badge") private var showRatingBadge = true
    @AppStorage("cinema_show_format_badge") private var showFormatBadge = true

    private var badgeTags: [String] {
        cinemaBadgeTags(entry.file)
    }

    private var versionCount: Int {
        store.cinemaVersionCount(for: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if entry.artworkURL != nil {
                        CinemaArtwork(urlString: entry.artworkURL, contentMode: .fill)
                    } else {
                        // 没匹配到海报时先显示视频自己的缩略图，至少能看见内容。
                        PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(156))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.10), .black.opacity(0.72)],
                               startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(9)

                VStack {
                    // 左上铺满画质 / 音质 / 类型角标（可换行），右上只留评分与版本。
                    HStack(alignment: .top, spacing: 5) {
                        if showFormatBadge {
                            CinemaSpecBadges(tags: badgeTags, fontSize: 8)
                                .frame(width: 102, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            if versionCount > 1 {
                                Text("\(versionCount) 版本")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                            if !entry.matched {
                                Text("未识别")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.48), in: Capsule())
                            } else if showRatingBadge, let rating = entry.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
            }
            .modifier(CinemaWallCardSizing(fillWidth: fillWidth))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: hovered ? 1.2 : 0.5)
            }
            // 悬停只加深描边与投影，不放大：放大后描边溢出格子，外框和海报内容对不齐。
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .overlay(alignment: .bottomTrailing) {
                if hovered {
                    HStack(spacing: 5) {
                        if let onPlay {
                            Button(action: onPlay) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 22, height: 22)
                                    .background(LumaBrand.amber, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("播放")
                        }
                        if let onDetail {
                            Button(action: onDetail) {
                                Image(systemName: "info")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("详情")
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: fillWidth ? .infinity : 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(count: 2) {
            if let onDetail { onDetail() } else { onOpen() }
        }
        .onTapGesture(perform: onOpen)
        .help(entry.file.filename)
        .contextMenu {
            Button("播放") {
                if let onPlay {
                    onPlay()
                } else {
                    onOpen()
                }
            }
            Button("查看详情") {
                if let onDetail { onDetail() } else { onOpen() }
            }
            Button(store.cinemaUserState(for: entry.id).favorite ? "取消收藏" : "收藏") {
                store.toggleCinemaFavorite(entry.id)
            }
            Button(store.cinemaUserState(for: entry.id).watchlist ? "移出想看" : "加入想看") {
                store.toggleCinemaWatchlist(entry.id)
            }
            if !store.cinemaLists.isEmpty {
                Menu("加入清单") {
                    ForEach(store.cinemaLists) { list in
                        Button(list.name) {
                            store.addToCinemaList(list.id, entryID: entry.id)
                        }
                    }
                }
            }
            Button("重新刮削") {
                Task { await store.rescrapeCinema(entry) }
            }
            Divider()
            Button("忽略（以后不刮削）") {
                store.ignoreCinemaEntry(entry)
            }
            Button("删除视频文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries([entry], title: entry.title)
            }
            if store.cinemaEntries[entry.id]?.file.isCloud == true {
                Button("在资料库中显示") {
                    if let mountID = entry.file.cloudMountID {
                        store.navigate(to: .cloudMount(mountID))
                    }
                }
            }
        }
    }
}

// MARK: - 列表行

private struct CinemaListRow: View {
    let artworkURL: String?
    let fallbackPhoto: PhotoItem?
    let title: String
    let subtitle: String
    let year: String
    let rating: Double?
    let genres: String
    let spec: String
    let badge: String
    let progress: CinemaProgressRecord?
    let onOpen: () -> Void
    /// 单击先选中；默认同时进详情，关掉后单击只选中、双击才进详情。
    var selected = false
    var onSelect: (() -> Void)?
    var onPlay: (() -> Void)?
    var singleClickOpensDetail = true

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            poster
            titleColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(year)
                .frame(width: 48, alignment: .leading)
            ratingView
                .frame(width: 48, alignment: .leading)
            Text(genres)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(spec)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            statusView
                .frame(width: 80, alignment: .trailing)
            if hovered, let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(5)
                        .background(LumaBrand.amber, in: Circle())
                }
                .buttonStyle(.plain)
                .help("播放")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? LumaBrand.amber.opacity(0.10)
                             : (hovered ? Color.primary.opacity(0.05) : Color.clear))
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(LumaBrand.amber)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture {
            onSelect?()
            if singleClickOpensDetail || onSelect == nil {
                onOpen()
            }
        }
        .help(subtitle)
    }

    private var poster: some View {
        ZStack {
            if let artworkURL {
                CinemaArtwork(urlString: artworkURL, contentMode: .fill)
            } else if let fallbackPhoto {
                PhotoThumbnailView(photo: fallbackPhoto, purpose: .cover(50))
            }
        }
        .frame(width: 34, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let progress, progress.fraction > 0.01, !progress.isFinished {
                progressBar(progress.fraction)
            }
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LumaBrand.amber)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 2)
    }

    @ViewBuilder
    private var ratingView: some View {
        if let rating, rating > 0 {
            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        HStack(spacing: 4) {
            // 文档约定：状态点只在列表出现：绿=已看、琥珀=有进度、红=未识别。
            Circle()
                .fill(statusDotColor)
                .frame(width: 5, height: 5)
            if let progress, progress.fraction > 0.01, !progress.isFinished {
                Text("已看 \(Int(progress.fraction * 100))%")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(LumaBrand.amber)
            } else {
                Text(badge)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(badge == "未识别" ? LumaBrand.coral : Color.secondary)
            }
        }
    }

    private var statusDotColor: Color {
        if badge == "未识别" { return LumaBrand.coral }
        guard let progress else { return Color.secondary.opacity(0.35) }
        if progress.isFinished { return .green }
        return progress.fraction > 0.01 ? LumaBrand.amber : Color.secondary.opacity(0.35)
    }
}

// MARK: - 影片详情

private enum CinemaDetailSheet: String, Identifiable {
    case match
    case newList

    var id: String { rawValue }
}

private struct CinemaDetailView: View {
    let entry: CinemaEntry
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    /// 顶栏「返回」：没有二级页时关闭整个详情。
    var onClose: () -> Void = {}

    @EnvironmentObject private var store: LibraryStore
    @State private var activeSheet: CinemaDetailSheet?
    /// TMDB 详情补全后的条目（合集 / 演职员 / 预告 / 分级）。
    @State private var enriched: CinemaEntry?
    /// 演职员 → 人物页；合集 → 独立合集页。
    @State private var personTarget: CinemaCastMember?
    @State private var showCollection = false
    /// 预告片：页面内播放层，不打开浏览器。
    @State private var showTrailer = false
    /// 档案卡里的长简介：默认收 5 行。
    @State private var dossierExpanded = false

    private var current: CinemaEntry {
        enriched ?? store.cinemaEntry(for: entry.id) ?? entry
    }

    private var progress: CinemaProgressRecord? {
        store.cinemaProgress[entry.id]
    }

    private var userState: CinemaUserState {
        store.cinemaUserState(for: entry.id)
    }

    private var versions: [CinemaEntry] {
        store.cinemaVersions(for: entry)
    }

    /// 已识别的影片 / 剧集才去豆瓣找预告片。
    private var trailerRequest: CinemaTrailerRequest? {
        guard current.matched else { return nil }
        return CinemaTrailerRequest(title: current.title,
                                    originalTitle: current.originalTitle,
                                    year: current.year,
                                    isTV: current.kind == .tv)
    }

    var body: some View {
        ZStack {
            pageContent
                .opacity(personTarget == nil ? 1 : 0)
                .allowsHitTesting(personTarget == nil)
            if let member = personTarget {
                // 演职员改成页面内二级页：不弹窗，顶栏「返回」逐层后退。
                CinemaPersonDetailView(
                    member: member,
                    onOpenEntry: { other in
                        personTarget = nil
                        onOpenEntry(other)
                    },
                    onPlay: { other in store.openCinema(other) }
                )
                .id(member.id)
                .transition(.opacity)
            }
            if showTrailer, let request = trailerRequest {
                // 预告片在页面内播放：不打开浏览器。
                CinemaTrailerOverlay(request: request) {
                    showTrailer = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: personTarget?.id)
        .animation(.easeOut(duration: 0.16), value: showTrailer)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cinemaSheetBackground)
        // 只把详情内容切成深色影院风，不改整个窗口外观。
        .environment(\.colorScheme, .dark)
        .task {
            if let updated = await store.enrichCinemaEntry(entry) {
                enriched = updated
            }
        }
        // 顶栏返回：先关预告片，再退演职员页，最后退影片详情。
        .onChange(of: store.cinemaDetailCloseTick) { _, _ in
            if showTrailer {
                showTrailer = false
            } else if personTarget != nil {
                personTarget = nil
            } else {
                onClose()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .match:
                CinemaMatchSheet(entry: entry) {
                    activeSheet = nil
                }
                .environmentObject(store)
            case .newList:
                CinemaNewListSheet { name in
                    let list = store.createCinemaList(named: name)
                    store.addToCinemaList(list.id, entryID: entry.id)
                    activeSheet = nil
                } onCancel: {
                    activeSheet = nil
                }
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $showCollection) {
            CinemaCollectionSheet(collectionID: current.collectionID ?? 0,
                                  name: current.collectionName ?? "合集") { other in
                showCollection = false
                onOpenEntry(other)
            }
            .environmentObject(store)
        }
    }

    private var pageContent: some View {
        ZStack {
            ambientBackground
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dossierSection
                    if !collectionEntries.isEmpty {
                        collectionSection
                    }
                    if versions.count > 1 {
                        versionsSection
                    }
                    technicalSection
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 36)
                .frame(maxWidth: 1440, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
    }

    /// 用同一张剧照虚化铺一层氛围：向下渐隐到深色，和下方内容自然衔接。
    private var ambientBackground: some View {
        ZStack(alignment: .top) {
            cinemaSheetBackground
            CinemaArtwork(urlString: entry.backdropURL ?? entry.posterURL, contentMode: .fill)
                .frame(height: 720)
                .blur(radius: 90, opaque: true)
                .opacity(0.20)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.80), location: 0.38),
                        .init(color: .black.opacity(0.28), location: 0.72),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: 影片档案

    /// 与剧集详情同一套版式：海报作视觉锚点，右侧按「抬头 / 片名 / 简介 / 资料网格」排，
    /// 底部接演职员，整块收进一张深色玻璃卡，不再拆成几张独立小卡。
    private var dossierSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                dossierPosterColumn
                VStack(alignment: .leading, spacing: 14) {
                    dossierKicker
                    dossierTitleBlock
                    dossierSynopsis
                    dossierFactsGrid
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22)

            // 播放进度并进档案卡：电影页同样不再单独占一条。
            if let progress, progress.fraction > 0.01 {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                resumeBar(progress)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }

            if let cast = current.cast, !cast.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                castStrip(cast)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
        }
        .background { dossierPlate }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            Color.white.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
    }

    /// 档案卡底板：深色玻璃 + 左上角一层很淡的琥珀光，和海报的暖色调衔接。
    private var dossierPlate: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.062),
                                          Color.white.opacity(0.022)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
    }

    /// 海报 + 评分牌 + 个人评分 + 观看进度：共用一列，宽度和海报对齐。
    private var dossierPosterColumn: some View {
        VStack(spacing: 9) {
            posterCard(width: 156, height: 234)
                .shadow(color: LumaBrand.amber.opacity(0.18), radius: 22, y: 10)

            if let rating = current.rating, rating > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if let votes = current.voteCount, votes > 0 {
                        Text("· \(voteCountText(votes))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.white.opacity(0.07), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6) }
            }

            if let rating = userState.rating {
                Text("我的评分 " + String(repeating: "★", count: rating))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                    .frame(width: 156)
            }

            if let progress, progress.fraction > 0.01 {
                VStack(spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(LumaBrand.amber)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    Text(progress.isFinished ? "已看完" : "已看 \(Int(progress.fraction * 100))%")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: 156)
            }
        }
        .frame(width: 156, alignment: .top)
    }

    /// 档案抬头：琥珀刻字标签 + 年份 / 片长 / 规格 + 上映状态。
    private var dossierKicker: some View {
        HStack(spacing: 8) {
            Text("影片档案")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(LumaBrand.amber.opacity(0.92))
            Rectangle()
                .fill(LumaBrand.amber.opacity(0.35))
                .frame(width: 24, height: 0.8)
            Text(dossierMetaLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
            dossierStatusPill
        }
    }

    /// 片名 / 原名 / 宣传语 / 播放动作：整页的标题区。
    private var dossierTitleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(displayTitle)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .textSelection(.enabled)

            if let original = current.originalTitle,
               !original.isEmpty,
               original.caseInsensitiveCompare(displayTitle) != .orderedSame {
                Text(original.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            if let tagline = current.tagline, !tagline.isEmpty {
                Text("「\(tagline)」")
                    .font(.system(size: 12, weight: .medium))
                    .italic()
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }

            actions
                .padding(.top, 2)
        }
    }

    private var displayTitle: String {
        let title = current.title
        return title.isEmpty ? entry.title : title
    }

    @ViewBuilder
    private var dossierStatusPill: some View {
        if let status = cinemaStatusText(current.status) {
            let released = current.status == "Released"
            HStack(spacing: 5) {
                Circle()
                    .fill(released ? LumaBrand.mint : Color.white.opacity(0.32))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(released ? LumaBrand.mint : Color.white.opacity(0.72))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6) }
        }
    }

    /// 简介：默认收 5 行，长简介可展开；没有简介时提示换数据源。
    @ViewBuilder
    private var dossierSynopsis: some View {
        let overview = current.overview ?? ""
        if overview.isEmpty {
            Text("暂无剧情简介。可以在顶栏面板里「重新匹配」换一个数据源，通常会补全简介与演职员。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(overview)
                    .font(.system(size: 12.8))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(6)
                    .lineLimit(dossierExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 860, alignment: .leading)
                    .textSelection(.enabled)
                if overview.count > 180 {
                    Button(dossierExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            dossierExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        }
    }

    /// 资料网格：每项一枚琥珀小图标 + 标签 / 值，缺哪项就不占位。
    private var dossierFactsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 178, maximum: 268), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            ForEach(dossierFacts) { fact in
                HStack(spacing: 9) {
                    Image(systemName: fact.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber.opacity(0.90))
                        .frame(width: 24, height: 24)
                        .background(LumaBrand.amber.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                        Text(fact.value)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
    }

    private struct DossierFact: Identifiable {
        let icon: String
        let label: String
        let value: String
        var id: String { label + "|" + value }
    }

    /// 本地与 TMDB 能拿到的资料项都在这里，缺哪项就不占位。
    private var dossierFacts: [DossierFact] {
        var items: [DossierFact] = []
        if let value = cinemaDateText(current.releaseDate) ?? current.year.map({ "\($0) 年" }) {
            items.append(DossierFact(icon: "calendar", label: "上映", value: value))
        }
        if let value = cinemaMinutesText(current.runtime) {
            items.append(DossierFact(icon: "clock", label: "片长", value: value))
        }
        if let value = current.file.displayTags.first(where: { $0 == "DV" || $0.hasPrefix("HDR") }) {
            items.append(DossierFact(icon: "sparkles.tv",
                                     label: "HDR",
                                     value: value == "DV" ? "Dolby Vision" : value))
        }
        if current.file.displayTags.contains("Atmos") {
            items.append(DossierFact(icon: "hifispeaker.2", label: "音轨", value: "Dolby Atmos"))
        }
        if let fps = current.file.parsedFrameRate {
            items.append(DossierFact(icon: "speedometer", label: "帧率", value: "\(fps) fps"))
        }
        if let value = current.genres?.prefix(4).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "theatermasks", label: "类型", value: value))
        }
        if let value = current.certification, !value.isEmpty {
            items.append(DossierFact(icon: "shield.lefthalf.filled", label: "分级", value: value))
        }
        if let value = cinemaLanguageName(current.originalLanguage) {
            items.append(DossierFact(icon: "character.bubble", label: "语言", value: value))
        }
        if let countries = current.countries, !countries.isEmpty {
            let value = countries.prefix(2).map(cinemaCountryName).joined(separator: " / ")
            items.append(DossierFact(icon: "globe.asia.australia", label: "国家", value: value))
        }
        if let value = current.companies?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "building.2", label: "制作", value: value))
        }
        if let value = ratingDetailText {
            items.append(DossierFact(icon: "star", label: "评分", value: value))
        }
        if let value = cinemaMoneyText(current.budget) {
            items.append(DossierFact(icon: "banknote", label: "预算", value: value))
        }
        if let value = cinemaMoneyText(current.revenue) {
            items.append(DossierFact(icon: "chart.line.uptrend.xyaxis", label: "票房", value: value))
        }
        if let value = current.collectionName, !value.isEmpty {
            items.append(DossierFact(icon: "square.stack.3d.up", label: "合集", value: value))
        }
        if let id = current.tmdbID {
            let label = current.provider == .tvdb ? "TVDB" : "TMDB"
            items.append(DossierFact(icon: "number", label: label, value: "\(id)"))
        }
        return items
    }

    private var dossierMetaLine: String {
        var parts: [String] = []
        if let year = current.year, year > 0 {
            parts.append("\(year)")
        }
        if let runtime = current.runtime, runtime > 0 {
            parts.append("\(runtime) 分钟")
        }
        parts.append(resolutionText)
        return parts.joined(separator: " · ")
    }

    private func voteCountText(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f 万人评分", Double(votes) / 10_000)
        }
        return "\(votes) 人评分"
    }

    private func posterCard(width: CGFloat, height: CGFloat) -> some View {
        let radius: CGFloat = width > 100 ? 10 : 5
        return ZStack {
            if let url = current.posterURL ?? entry.posterURL {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else {
                PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(240))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.26), lineWidth: 1)
        }
    }

    private var actions: some View {
        HStack(spacing: 9) {
            Button(action: play) {
                Label(progress == nil ? "播放" : "继续播放", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(LumaBrand.amber, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)

            if trailerRequest != nil {
                Button {
                    showTrailer = true
                } label: {
                    Label("预告片", systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.14), in: Capsule())
                        .foregroundStyle(.white.opacity(0.92))
                }
                .buttonStyle(.plain)
            }

            Button {
                activeSheet = .match
            } label: {
                Label(entry.matched ? "重新匹配" : "手动匹配", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.16), in: Capsule())
                    .foregroundStyle(.white.opacity(0.94))
            }
            .buttonStyle(.plain)

            circleButton(userState.favorite ? "heart.fill" : "heart",
                         active: userState.favorite,
                         help: userState.favorite ? "取消收藏" : "收藏") {
                store.toggleCinemaFavorite(entry.id)
            }

            circleButton(userState.watchlist ? "bookmark.fill" : "bookmark",
                         active: userState.watchlist,
                         activeColor: LumaBrand.amber,
                         help: userState.watchlist ? "移出想看" : "加入想看") {
                store.toggleCinemaWatchlist(entry.id)
            }

            ratingMenu
            listMenu
            moreMenu
        }
    }

    private func circleButton(_ icon: String,
                              active: Bool,
                              activeColor: Color = LumaBrand.coral,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? activeColor : Color.white.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var ratingMenu: some View {
        Menu {
            ForEach(1...5, id: \.self) { star in
                Button(String(repeating: "★", count: star)) {
                    store.setCinemaRating(star, for: entry.id)
                }
            }
            Divider()
            Button("清除评分") {
                store.setCinemaRating(nil, for: entry.id)
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                if let rating = userState.rating {
                    Text("\(rating)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(userState.rating == nil ? Color.white.opacity(0.90) : LumaBrand.amber)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.16), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("个人评分")
    }

    private var listMenu: some View {
        Menu {
            if store.cinemaLists.isEmpty {
                Button("新建清单…") { activeSheet = .newList }
            } else {
                ForEach(store.cinemaLists) { list in
                    Button(list.name) {
                        store.addToCinemaList(list.id, entryID: entry.id)
                    }
                }
                Divider()
                Button("新建清单…") { activeSheet = .newList }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.16), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("加入清单")
    }

    private var moreMenu: some View {
        Menu {
            Button("按文件名重新刮削") {
                Task { await store.rescrapeCinema(entry) }
            }
            if let mountID = entry.file.cloudMountID {
                Button("在资料库中显示") {
                    store.cinemaDetailCloseTick += 1
                    store.navigate(to: .cloudMount(mountID))
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.90))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.14), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    private func play() {
        play(entry)
    }

    private func play(_ version: CinemaEntry) {
        // 详情留在页面下层，播放器关掉后回到原位。
        store.openCinema(version)
    }

    // MARK: 合集 / 演职员

    private var collectionEntries: [CinemaEntry] {
        guard let id = current.collectionID else { return [] }
        return store.cinemaCollection(collectionID: id).filter { $0.id != entry.id }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle(current.collectionName ?? "同一合集",
                             detail: "\(collectionEntries.count + 1) 部")
                Button("查看合集 ›") {
                    showCollection = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
                .help("打开合集详情：按上映顺序播放与合集统计")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(collectionEntries) { other in
                        Button {
                            onOpenEntry(other)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ZStack {
                                    if let url = other.posterURL {
                                        CinemaArtwork(urlString: url, contentMode: .fill)
                                    } else {
                                        PhotoThumbnailView(photo: other.file.photoItem, purpose: .cover(120))
                                    }
                                }
                                .frame(width: 96, height: 144)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                                }
                                Text(other.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.90))
                                    .lineLimit(1)
                                    .frame(width: 96, alignment: .leading)
                                Text(other.year.map(String.init) ?? " ")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(width: 96, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(other.title)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
        }
    }

    /// 演职员条：和剧集详情同款，收在档案卡底部。
    private func castStrip(_ cast: [CinemaCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                if let directors = current.directors, !directors.isEmpty {
                    Text("导演 " + directors.prefix(2).joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        Button {
                            personTarget = member
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    if let url = member.profileURL {
                                        CinemaArtwork(urlString: url, contentMode: .fill)
                                    } else {
                                        Circle().fill(Color.secondary.opacity(0.18))
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                                }
                                Text(member.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text(member.character ?? " ")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 84)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("查看 \(member.name) 的人物页")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 版本

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("版本", detail: "\(versions.count) 个文件")
            ForEach(versions) { version in
                versionRow(version)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
        }
    }

    private func versionRow(_ version: CinemaEntry) -> some View {
        let current = version.id == entry.id
        return Button {
            play(version)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(current ? LumaBrand.amber : Color.white.opacity(0.40))

                VStack(alignment: .leading, spacing: 2) {
                    Text(version.file.filename)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.90))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(resolutionText(version.file)) · \(byteText(version.file)) · \(durationText(version.file))")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Spacer(minLength: 0)

                Text(current ? "当前" : "播放")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(current ? LumaBrand.amber : Color.white.opacity(0.55))
            }
            .padding(8)
            .background(current ? LumaBrand.amber.opacity(0.10) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(current ? LumaBrand.amber.opacity(0.35) : Color.white.opacity(0.08),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 进度 / 技术信息

    /// 有观看进度时置顶一条「继续播放」，和剧集详情的下一集条同一套样式。
    private func resumeBar(_ progress: CinemaProgressRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: progress.isFinished ? "checkmark.circle.fill" : "play.circle.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.isFinished ? "已看完" : "继续观看")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(timeText(progress.position)) / \(timeText(progress.duration)) · 还剩 \(remainingText(progress))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: play) {
                Label(progress.isFinished ? "重看" : "继续播放", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(LumaBrand.amber, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(LumaBrand.amber.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.8)
        }
    }

    /// 技术规格 + 文件信息收进同一张卡：上面是规格 chips，下面是可复制的路径与匹配状态。
    private var technicalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("文件与技术信息", detail: entry.file.filename)
            HStack(spacing: 8) {
                chip(resolutionText)
                if let codec = entry.file.videoCodec, !codec.isEmpty {
                    chip(codec.uppercased())
                }
                chip(fileExtension)
                chip(byteText)
                chip(durationText)
                ForEach(Array(current.file.displayTags.prefix(3)), id: \.self) { tag in
                    chip(tag)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                infoRow("文件名", entry.file.filename)
                Divider().opacity(0.4)
                infoRow("路径", filePathText)
                Divider().opacity(0.4)
                infoRow("大小", byteText)
                Divider().opacity(0.4)
                infoRow("时长", durationText)
                Divider().opacity(0.4)
                infoRow("添加时间", entry.file.capturedAt.formatted(date: .numeric, time: .shortened))
                Divider().opacity(0.4)
                infoRow("匹配", entry.matched
                        ? (entry.tmdbID.map { "已匹配 · \(entry.provider?.title ?? "TMDB") \($0)" } ?? "已匹配")
                        : "未识别")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(Color.white.opacity(0.07), in: Capsule())
            .foregroundStyle(.white.opacity(0.72))
    }

    private func sectionTitle(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LumaBrand.amber)
                .frame(width: 3, height: 13)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var ratingDetailText: String? {
        guard let rating = current.rating, rating > 0 else { return nil }
        var text = String(format: "%.1f", rating)
        if let votes = current.voteCount, votes > 0 {
            text += " · \(votes) 人评分"
        }
        return text
    }

    /// 网盘（尤其夸克）的 cloudPath 是文件 ID，不是人类可读路径：
    /// 有目录链时优先拼成「目录/文件名」，否则再退回原始路径。
    private var filePathText: String {
        let name = entry.file.filename
        if let hint = entry.folderHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            return hint.hasSuffix("/") ? hint + name : hint + "/" + name
        }
        if let raw = entry.file.cloudPath,
           !raw.isEmpty,
           !LibraryStore.cinemaPathLooksLikeID(raw) {
            return raw
        }
        return name
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    // MARK: 格式化

    private var resolutionText: String {
        resolutionText(entry.file)
    }

    private func resolutionText(_ file: CinemaFile) -> String {
        let width = file.pixelWidth
        let height = file.pixelHeight
        if width >= 3000 { return "4K" }
        if width >= 1800 { return "2K" }
        if width >= 1200 { return "1080P" }
        if width > 0, height > 0 { return "\(width)×\(height)" }
        return "分辨率未知"
    }

    private var fileExtension: String {
        let ext = (entry.file.filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : ext
    }

    private var byteText: String {
        byteText(entry.file)
    }

    private func byteText(_ file: CinemaFile) -> String {
        guard file.fileSize > 0 else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
    }

    private var durationText: String {
        durationText(entry.file)
    }

    private func durationText(_ file: CinemaFile) -> String {
        guard let duration = file.duration, duration > 0 else { return "时长未知" }
        let minutes = Int(duration / 60)
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(minutes) 分钟"
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func remainingText(_ progress: CinemaProgressRecord) -> String {
        let minutes = Int(progress.remainingSeconds / 60)
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(max(1, minutes)) 分钟"
    }
}

// MARK: - 新建清单

private struct CinemaNewListSheet: View {
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建清单")
                .font(.system(size: 16, weight: .bold))
            Text("手动选片，只在本机保存，不写回网盘。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("清单名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}

// MARK: - 手动匹配

struct CinemaMatchSheet: View {
    let entry: CinemaEntry?
    let photos: [PhotoItem]
    /// 来自文件夹匹配时的目录链：用来补季 / 剧名，比单个文件更可靠。
    let folderHint: String?
    let onApplied: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// 两步：先选片，再给剧集排季集（参考芝杜的批量匹配流程）。
    private enum Step { case search, episodes }

    /// 手动匹配的来源：可以只查某一个，也可以全部一起查。
    private enum MatchSource: String, CaseIterable, Identifiable {
        case all
        case tmdb
        case douban
        case tvdb

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .tmdb: return "TMDB"
            case .douban: return "豆瓣"
            case .tvdb: return "TVDB"
            }
        }

        var providers: [CinemaProvider]? {
            switch self {
            case .all: return nil
            case .tmdb: return [.tmdb]
            case .douban: return [.douban]
            case .tvdb: return [.tvdb]
            }
        }
    }

    /// 集号来源：文件名里的数字，或按顺序编号（同名多版本共用一集）。
    private enum EpisodeMode: String, CaseIterable, Identifiable {
        case fileName
        case sequential

        var id: String { rawValue }
        var title: String {
            switch self {
            case .fileName: return "文件名数字"
            case .sequential: return "按顺序"
            }
        }
    }

    private struct EpisodeRow: Identifiable {
        let photo: PhotoItem
        var text: String
        /// 从 SxxExx / 纯数字文件名里解析出的原始编号。
        var detected: Int?
        var detectedSeason: Int?
        /// 去掉清晰度 / 版本标记后的文件名主干，用来把 4K 与普通版认成同一集。
        var normalizedName: String

        var id: UUID { photo.id }
    }

    @State private var query: String
    @State private var isTV: Bool
    @State private var yearText: String
    @State private var results: [CinemaMatch] = []
    /// 匹配来源：默认全部一起查，也可以只查某一个。
    @AppStorage("cinema_match_source") private var matchSource: MatchSource = .all
    @State private var selectedKey: String?
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var step: Step = .search
    @State private var chosenMatch: CinemaMatch?
    @State private var season = 1
    @State private var episodeMode: EpisodeMode = .fileName
    /// 集号 = 文件名数字 + 偏移；顺序模式下等于「起始集 - 1」。
    @State private var episodeOffset = 0
    @State private var rows: [EpisodeRow] = []
    /// 智能助手：补充要求、运行状态与回填结果。
    @State private var aiNote = ""
    @State private var showAIPanel = false
    @State private var aiRunning = false
    @State private var aiMessage: String?
    @State private var aiError: String?
    /// 应用助手结果时不要触发「按模式重算」，否则会覆盖模型给的集号。
    @State private var suppressAutoRefresh = false

    init(entry: CinemaEntry, onApplied: @escaping () -> Void) {
        self.entry = entry
        self.photos = []
        self.folderHint = entry.folderHint
        self.onApplied = onApplied
        _query = State(initialValue: entry.title)
        _isTV = State(initialValue: entry.kind == .tv)
        _yearText = State(initialValue: entry.year.map(String.init) ?? "")
    }

    /// 相簿 / 网格直接手动匹配：不必先进入影院，也不必已经刮削过。
    /// `folderHint` 传入所在目录链后，纯数字文件名也能正确补季。
    init(photos: [PhotoItem], folderHint: String? = nil, onApplied: @escaping () -> Void = {}) {
        self.entry = nil
        self.photos = photos
        self.folderHint = folderHint
        self.onApplied = onApplied
        let first = photos.first
        let parsed = CinemaScraper.parse(filename: first?.displayFilename ?? "")
        _query = State(initialValue: parsed.title)
        _isTV = State(initialValue: parsed.isTV)
        _yearText = State(initialValue: parsed.year.map(String.init) ?? "")
    }

    private var targetFilename: String {
        if let entry { return entry.file.filename }
        if photos.count > 1 {
            return "\(photos.count) 个视频 · 各自按文件名解析季集"
        }
        return photos.first?.displayFilename ?? ""
    }

    var body: some View {
        Group {
            switch step {
            case .search:
                searchStep
            case .episodes:
                episodeStep
            }
        }
        .padding(18)
        .frame(width: step == .episodes ? 760 : 680, height: 540)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .task {
            if !hasSearched {
                await search()
            }
        }
    }

    private var searchStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchBar
            Divider()
            resultList
            Divider()
            footer
        }
    }

    // MARK: 季集映射

    private var episodeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            episodeHeader
            episodeControls
            Divider()
            episodeList
            Divider()
            episodeFooter
        }
    }

    private var episodeHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                if let url = chosenMatch?.posterURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .frame(width: 40, height: 60)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("季集映射")
                    .font(.system(size: 16, weight: .bold))
                Text(episodeSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("换个匹配") { step = .search }
                .controlSize(.small)
        }
    }

    private var episodeSubtitle: String {
        var parts: [String] = []
        if let match = chosenMatch {
            parts.append(match.title)
            if let year = match.year { parts.append(String(year)) }
        }
        parts.append("\(photos.count) 个视频")
        parts.append("预填自文件名，可逐条改")
        return parts.joined(separator: " · ")
    }

    private var episodeControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                Stepper(value: $season, in: 1...99) {
                    Text("第 \(season) 季")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                }
                .controlSize(.small)

                Picker("", selection: $episodeMode) {
                    ForEach(EpisodeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: episodeMode) { _, _ in
                    guard !suppressAutoRefresh else { return }
                    refreshAssignments()
                }

                Stepper(value: $episodeOffset, in: -99...99) {
                    Text(episodeOffset == 0
                         ? "偏移 0"
                         : "偏移 \(episodeOffset > 0 ? "+" : "")\(episodeOffset)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                }
                .controlSize(.small)
                .onChange(of: episodeOffset) { _, _ in
                    guard !suppressAutoRefresh else { return }
                    refreshAssignments()
                }

                if episodeMode == .fileName, let minNumber = detectedNumberRange.min, minNumber > 1 {
                    Button("把 \(minNumber) 当作第 1 集") {
                        episodeOffset = 1 - minNumber
                        refreshAssignments()
                    }
                    .controlSize(.small)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(assignmentSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("季与集号会写进影院条目，之后详情页按季集排序、自动接下一集。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                Button {
                    showAIPanel = true
                } label: {
                    Label(aiRunning ? "助手排集中…" : "交给助手", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(aiRunning || rows.isEmpty)
                .popover(isPresented: $showAIPanel, arrowEdge: .bottom) {
                    aiPanel
                }
                .help("把剧名、季、文件和补充要求交给大模型，由它调用工具回填集号")

                Button {
                    prepareEpisodes(resetSeason: false)
                } label: {
                    Label("按文件名重新识别", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)

                Button {
                    sortRowsByEpisode()
                } label: {
                    Label("按集号排序", systemImage: "arrow.up.arrow.down")
                }
                .controlSize(.small)
            }

            if aiRunning || aiMessage != nil || aiError != nil {
                HStack(spacing: 6) {
                    if aiRunning {
                        ProgressView().controlSize(.mini)
                    }
                    if let aiMessage {
                        Text(aiMessage)
                            .foregroundStyle(LumaBrand.amber)
                    }
                    if let aiError {
                        Text(aiError)
                            .foregroundStyle(LumaBrand.coral)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detectedNumberRange: (min: Int?, max: Int?) {
        let values = rows.compactMap(\.detected)
        return (values.min(), values.max())
    }

    /// 多少集、多少文件、有多少文件是同集多版本。
    private var assignmentSummary: String {
        let assigned = rows.filter { (Int($0.text.trimmingCharacters(in: .whitespaces)) ?? 0) > 0 }
        let groups = Dictionary(grouping: assigned, by: { $0.text }).count
        var summary = "\(groups) 集 · \(rows.count) 个文件"
        if rows.count > groups, groups > 0 {
            summary += " · \(rows.count - groups) 个同集多版本"
        }
        return summary
    }

    // MARK: 智能助手

    /// 把剧名、季、文件事实与用户要求交给大模型；模型通过工具回填集号。
    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(LumaBrand.amber)
                Text("交给智能助手")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("把剧名、第 \(season) 季、\(rows.count) 个文件和你下面的要求交给 \(store.aiConfig.model.isEmpty ? "大模型" : store.aiConfig.model)，由它调用工具回填集号。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("补充要求，例如「11 当作第 1 集」「13 之后缺一集」",
                      text: $aiNote,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            if let aiError {
                Text(aiError)
                    .font(.system(size: 10))
                    .foregroundStyle(LumaBrand.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if aiRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在核对 \(rows.count) 个文件…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("取消") { showAIPanel = false }
                    .controlSize(.small)
                Button("开始匹配") { runAIPlan() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .disabled(aiRunning || rows.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func runAIPlan() {
        guard !aiRunning, !rows.isEmpty else { return }
        aiRunning = true
        aiError = nil
        aiMessage = nil
        showAIPanel = false
        let snapshot = rows
        let note = aiNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CinemaAIMatchRequest(
            title: chosenMatch?.title ?? query,
            year: chosenMatch?.year ?? Int(yearText.trimmingCharacters(in: .whitespaces)),
            season: season,
            files: snapshot.enumerated().map { index, row in
                CinemaAIMatchFile(index: index + 1,
                                  filename: row.photo.displayFilename,
                                  detectedEpisode: row.detected,
                                  durationSeconds: row.photo.duration,
                                  sizeBytes: row.photo.fileSize)
            },
            note: note.isEmpty ? nil : note
        )
        Task { @MainActor in
            do {
                let plan = try await store.aiPlanEpisodeMapping(request)
                applyAIPlan(plan, snapshot: snapshot)
            } catch {
                aiError = error.localizedDescription
            }
            aiRunning = false
        }
    }

    private func applyAIPlan(_ plan: CinemaAIMatchPlan, snapshot: [EpisodeRow]) {
        suppressAutoRefresh = true
        if let mode = plan.mode {
            episodeMode = mode == "sequential" ? .sequential : .fileName
        }
        if let offset = plan.offset {
            episodeOffset = max(-99, min(99, offset))
        }
        var applied = 0
        for (index, episode) in plan.assignments {
            guard index >= 1, index <= snapshot.count else { continue }
            let id = snapshot[index - 1].photo.id
            if let rowIndex = rows.firstIndex(where: { $0.id == id }) {
                rows[rowIndex].text = String(episode)
                applied += 1
            }
        }
        sortRowsByEpisode()
        let episodeCount = Set(plan.assignments.values).count
        var message = "助手已排好 \(episodeCount) 集 · \(applied) 个文件"
        if applied < rows.count {
            message += "（\(rows.count - applied) 个未给集号）"
        }
        if let note = plan.note, !note.isEmpty {
            message += " · \(note)"
        }
        aiMessage = message
        // 等 onChange 走完再恢复，避免模式 / 偏移把模型给的集号重算掉。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            suppressAutoRefresh = false
        }
    }

    private var episodeList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    episodeRow(index: index, row: row)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func episodeRow(index: Int, row: EpisodeRow) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            PhotoThumbnailView(photo: row.photo, purpose: .cover(80))
                .frame(width: 64, height: 36)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.photo.displayFilename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rowSourceText(row))
                    .font(.system(size: 9))
                    .foregroundStyle(row.detected == nil && episodeMode == .fileName
                                     ? Color.secondary
                                     : LumaBrand.amber.opacity(0.85))
            }

            Spacer(minLength: 0)

            if episodeShareCount(row) > 1 {
                Text("×\(episodeShareCount(row))")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            Text("E")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("", text: episodeBinding(row.id))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.center)

            Text(episodeBadge(row))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(LumaBrand.amber)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(7)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var episodeFooter: some View {
        HStack(spacing: 10) {
            Text("已分配 \(assignedCount)/\(rows.count) 个文件 · \(assignmentSummary) · 第 \(season) 季")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("返回") { step = .search }
                .controlSize(.small)
            Button("取消") { dismiss() }
                .controlSize(.small)
            Button("应用 \(rows.count) 个文件") { applyEpisodes() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(LumaBrand.amber)
                .disabled(assignedCount == 0)
        }
    }

    private func rowSourceText(_ row: EpisodeRow) -> String {
        if episodeMode == .fileName {
            if let detected = row.detected { return "文件名数字 \(detected)" }
            return "缺号 · 已顺序补齐"
        }
        return "按顺序编号 · 同名版本共用集号"
    }

    private func episodeShareCount(_ row: EpisodeRow) -> Int {
        let text = row.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 1 }
        return rows.filter { $0.text.trimmingCharacters(in: .whitespaces) == text }.count
    }

    private func episodeBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { rows.first(where: { $0.id == id })?.text ?? "" },
            set: { value in
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    rows[index].text = value
                }
            }
        )
    }

    private func episodeBadge(_ row: EpisodeRow) -> String {
        let episode = Int(row.text.trimmingCharacters(in: .whitespaces)) ?? 0
        guard episode > 0 else { return "S\(pad(season))E—" }
        return "S\(pad(season))E\(pad(episode))"
    }

    private func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    private var assignedCount: Int {
        rows.filter { (Int($0.text.trimmingCharacters(in: .whitespaces)) ?? 0) > 0 }.count
    }

    /// 进映射页：先按文件名自然顺序排，再尝试从 SxxExx 或纯数字文件名取集号。
    /// 文件名就是数字（11.mkv / 13 4K.mkv）时按数字识别；完全没数字才退回顺序编号。
    private func prepareEpisodes(resetSeason: Bool = true) {
        let sorted = photos.sorted {
            $0.displayFilename.localizedStandardCompare($1.displayFilename) == .orderedAscending
        }
        let newRows = sorted.map { photo -> EpisodeRow in
            let parsed = parseFilename(photo)
            let loose = looseEpisodeNumber(photo.displayFilename)
            return EpisodeRow(photo: photo,
                              text: "",
                              detected: parsed.episode ?? loose,
                              detectedSeason: parsed.season,
                              normalizedName: normalizedStem(photo.displayFilename))
        }
        if resetSeason {
            season = newRows.compactMap(\.detectedSeason).first ?? 1
        }
        rows = newRows
        episodeMode = newRows.contains(where: { $0.detected != nil }) ? .fileName : .sequential
        episodeOffset = 0
        refreshAssignments()
    }

    /// 按当前模式重新分配集号；同名多版本永远落到同一集。
    private func refreshAssignments() {
        guard !rows.isEmpty else { return }
        if episodeMode == .fileName, rows.contains(where: { $0.detected != nil }) {
            for index in rows.indices {
                if let detected = rows[index].detected {
                    rows[index].text = String(max(1, detected + episodeOffset))
                } else {
                    rows[index].text = ""
                }
            }
            // 少数没带编号的文件：接在已有最大值之后顺序补齐。
            var next = rows.compactMap { Int($0.text) }.max() ?? 0
            for index in rows.indices where rows[index].text.isEmpty {
                next += 1
                rows[index].text = String(next)
            }
        } else {
            // 顺序模式：按文件名主干分组，4K / 1080P 等版本共用一集。
            var assigned: [String: Int] = [:]
            var next = max(1, 1 + episodeOffset)
            for index in rows.indices {
                let fallback = rows[index].photo.id.uuidString
                let key = rows[index].normalizedName.isEmpty ? fallback : rows[index].normalizedName
                if let existing = assigned[key] {
                    rows[index].text = String(existing)
                } else {
                    assigned[key] = next
                    rows[index].text = String(next)
                    next += 1
                }
            }
        }
        sortRowsByEpisode()
    }

    private func sortRowsByEpisode() {
        rows.sort { lhs, rhs in
            let left = Int(lhs.text.trimmingCharacters(in: .whitespaces)) ?? Int.max
            let right = Int(rhs.text.trimmingCharacters(in: .whitespaces)) ?? Int.max
            if left != right { return left < right }
            return lhs.photo.displayFilename.localizedStandardCompare(rhs.photo.displayFilename)
                == .orderedAscending
        }
    }

    /// 去掉 4K / HDR / 编码 / 音轨等版本标记，得到用于「同名多版本」判断的主干。
    private func normalizedStem(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let pattern = #"(?i)(?<![a-z0-9])(4k|8k|2160p|1080p|720p|480p|hdr10\+?|hdr|dv|dolby[ .]?vision|remux|web[- .]?dl|webrip|bluray|bdrip|x265|x264|h[ .]?265|h[ .]?264|hevc|avc|aac|ddp?[ .]?\d(?:[ .]\d)?|atmos|truehd|dts(?:-hd)?(?:[ .]?ma)?|\d{2,3}fps|高码版?|国语|国粤|双语|中字|中文字幕|简繁|英字幕)(?![a-z0-9])"#
        let stripped = base.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        let collapsed = stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return collapsed.isEmpty ? base.lowercased() : collapsed
    }

    /// `11.mkv`、`13 4K.mkv`、`谷雨 11.mkv` 这类把结尾数字当集号。
    private func looseEpisodeNumber(_ filename: String) -> Int? {
        let stem = normalizedStem(filename)
        guard !stem.isEmpty else { return nil }
        if stem.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil {
            return Int(stem)
        }
        if stem.range(of: #"^.+[\s\-_\.]\d{1,3}$"#, options: .regularExpression) != nil,
           let tail = stem.split(whereSeparator: { " -_.".contains($0) }).last,
           let value = Int(tail) {
            return value
        }
        return nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("手动匹配")
                .font(.system(size: 16, weight: .bold))
            Text(targetFilename)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let folderHint, !folderHint.isEmpty {
                Text("目录：\(folderHint)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let entry {
                Text(entry.matched
                     ? "当前匹配：\(entry.title)\(entry.year.map { "（\($0)）" } ?? "")"
                     : "当前未识别 · 选择候选项后只改写这一批文件")
                    .font(.system(size: 9.5))
                    .foregroundStyle(entry.matched ? LumaBrand.amber.opacity(0.85) : LumaBrand.coral)
                    .lineLimit(1)
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入片名 / 剧名", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await search() }
                    }

                Picker("", selection: $isTV) {
                    Text("电影").tag(false)
                    Text("剧集").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 118)

                TextField("年份", text: $yearText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)

                Button {
                    Task { await search() }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).count < 2)
            }

            HStack(spacing: 8) {
                Text("匹配来源")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $matchSource) {
                    ForEach(MatchSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .onChange(of: matchSource) { _, _ in
                    guard hasSearched else { return }
                    Task { await search() }
                }
                Spacer(minLength: 0)
                Text(matchSource == .all
                     ? "同时查全部已配置的数据源"
                     : "只查 \(matchSource.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if isSearching {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在搜索…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text(hasSearched ? (errorMessage ?? "没有找到候选") : "输入片名后搜索")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let errorMessage, hasSearched {
                    Text(errorMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("试试英文名、去掉季集号，或把年份清空。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(results, id: \.sourceKey) { match in
                        matchRow(match)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func matchRow(_ match: CinemaMatch) -> some View {
        Button {
            selectedKey = match.sourceKey
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let url = match.posterURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.06)
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(match.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let original = match.originalTitle, !original.isEmpty {
                        Text(original)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let year = match.year {
                            Text(String(year))
                        }
                        if let rating = match.rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(LumaBrand.amber)
                        }
                        if !match.genres.isEmpty {
                            Text(Array(match.genres.prefix(3)).joined(separator: " / "))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let provider = match.provider {
                    Text(provider.title)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(provider == .tmdb ? LumaBrand.violet : LumaBrand.amber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((provider == .tmdb ? LumaBrand.violet : LumaBrand.amber).opacity(0.12)))
                }

                Image(systemName: selectedKey == match.sourceKey ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selectedKey == match.sourceKey ? LumaBrand.amber : Color.secondary)
            }
            .padding(8)
            .background(selectedKey == match.sourceKey ? LumaBrand.amber.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selectedKey == match.sourceKey ? LumaBrand.amber.opacity(0.5)
                                                                 : Color.primary.opacity(0.06),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorMessage, !results.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !results.isEmpty {
                Text("共 \(results.count) 个候选 · \(targetCountText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("取消") { dismiss() }
                .controlSize(.small)
            Button(needsEpisodeMapping ? "下一步：季集" : "应用匹配") {
                advance()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(LumaBrand.amber)
            .disabled(selectedKey == nil || isSearching)
        }
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        hasSearched = true
        errorMessage = nil
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let outcome = await store.cinemaSearchCandidates(query: query, isTV: isTV, year: year,
                                                         providers: matchSource.providers,
                                                         combineAll: matchSource == .all)
        results = outcome.matches
        errorMessage = outcome.error
        if selectedKey == nil || !results.contains(where: { $0.sourceKey == selectedKey }) {
            selectedKey = results.first?.sourceKey
        }
        isSearching = false
    }

    private var targetCountText: String {
        if entry != nil || photos.count <= 1 { return "只改当前这一条" }
        if needsEpisodeMapping { return "\(photos.count) 个视频 · 下一步确认季集" }
        return "应用到 \(photos.count) 个视频"
    }

    /// 带目录链解析：文件夹名里的「Season 02 / 第 3 季」也能补进预填结果。
    private func parseFilename(_ photo: PhotoItem) -> CinemaParsedName {
        let scope = store.cinemaScope(for: photo)
        let hint = store.cinemaEntries(for: scope)[photo.id]?.folderHint ?? folderHint
        return CinemaScraper.parse(filename: photo.displayFilename, folderHint: hint)
    }

    /// 多选视频 + 剧集：先选剧，再进季集映射页逐集确认。
    /// 单集只有文件名解析不出集号时才走映射页，避免每次都要多点一步。
    private var needsEpisodeMapping: Bool {
        guard entry == nil,
              let match = results.first(where: { $0.sourceKey == selectedKey }),
              match.isTV else { return false }
        if photos.count > 1 { return true }
        guard let photo = photos.first else { return false }
        return parseFilename(photo).episode == nil
    }

    private func advance() {
        guard let match = results.first(where: { $0.sourceKey == selectedKey }) else { return }
        if needsEpisodeMapping {
            chosenMatch = match
            prepareEpisodes()
            step = .episodes
        } else {
            applyMatch(match)
        }
    }

    private func applyMatch(_ match: CinemaMatch) {
        if let entry {
            store.applyCinemaMatch(match, to: entry)
        } else if photos.count > 1 {
            store.applyCinemaMatch(match, to: photos, season: nil, episodes: [:])
        } else if let photo = photos.first {
            store.applyCinemaMatch(match, to: photo)
        }
        onApplied()
        dismiss()
    }

    private func applyEpisodes() {
        guard let match = chosenMatch else { return }
        var mapping: [UUID: Int] = [:]
        for row in rows {
            if let episode = Int(row.text.trimmingCharacters(in: .whitespaces)), episode > 0 {
                mapping[row.photo.id] = episode
            }
        }
        store.applyCinemaMatch(match, to: rows.map(\.photo), season: season, episodes: mapping)
        onApplied()
        dismiss()
    }
}

// MARK: - 继续观看卡片

private struct CinemaContinueCard: View {
    let record: CinemaProgressRecord
    let onOpen: () -> Void

    @State private var hovered = false

    private var remainingText: String {
        let minutes = Int(record.remainingSeconds / 60)
        if minutes >= 60 {
            return "还剩 \(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "还剩 \(max(1, minutes)) 分钟"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                CinemaArtwork(urlString: record.artworkURL, contentMode: .fill)
                    .frame(width: 236, height: 133)
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.78)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Text(record.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 12)

                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.94)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .opacity(hovered ? 1 : 0.92)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule()
                            .fill(LumaBrand.amber)
                            .frame(width: max(3, geo.size.width * record.fraction))
                    }
                }
                .frame(height: 3)
            }
            .frame(width: 236, height: 133)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.85)
                                          : Color.white.opacity(0.10),
                                  lineWidth: 1)
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .animation(.easeOut(duration: 0.16), value: hovered)

            HStack(spacing: 6) {
                Text(remainingText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(Int(record.fraction * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 236)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("继续播放 \(record.title)")
    }
}

// MARK: - 远程海报

private struct CinemaArtwork: View {
    let urlString: String?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.20),
                                    Color(nsColor: .quaternaryLabelColor).opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: urlString) {
            guard let urlString else { image = nil; return }
            image = await CinemaArtworkCache.shared.image(for: urlString)
        }
    }
}

// MARK: - 影院内搜索

private struct CinemaSearchPanel: View {
    let onOpen: (CinemaEntry) -> Void
    let onOpenSeries: (CinemaSeries) -> Void
    let onPlay: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// 搜索范围：默认只看已入库，可切到含未识别文件名。
    @State private var includeUnmatched = false
    @State private var personTarget: CinemaCastMember?
    @FocusState private var focused: Bool
    /// 键盘游标：↑↓ 在电影 / 剧集 / 人物三组之间移动，⏎ 详情、⌘⏎ 播放。
    @State private var cursor = 0
    @State private var keyMonitor: Any?

    /// 把三组结果拍平，便于键盘顺序选择。
    private enum SearchRow: Equatable {
        case entry(UUID)
        case series(String)
        case person(String)
    }

    private var flatRows: [SearchRow] {
        results.entries.map { .entry($0.id) }
            + results.series.map { .series($0.id) }
            + results.people.map { .person($0.name) }
    }

    private var results: (entries: [CinemaEntry], series: [CinemaSeries], people: [CinemaCastMember]) {
        store.cinemaSearchResults(query, includeUnmatched: includeUnmatched)
    }

    private var totalCount: Int {
        results.entries.count + results.series.count + results.people.count
    }
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            scopeBar
            Divider()
            content
        }
        .frame(width: 660, height: 560)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { _, _ in cursor = 0 }
        .sheet(item: $personTarget) { member in
            CinemaPersonSheet(member: member)
                .environmentObject(store)
        }
    }

    // MARK: 键盘

    /// 搜索框聚焦时，SwiftUI 的 ↑↓ 会被文本编辑器吃掉；用本地监听保证结果之间能顺着选。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 人物页弹出时把键盘交还给那个 sheet。
            guard personTarget == nil else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 125:   // ↓
                guard !modifiers.contains(.command) else { return event }
                moveCursor(1)
                return nil
            case 126:   // ↑
                guard !modifiers.contains(.command) else { return event }
                moveCursor(-1)
                return nil
            case 36, 76: // Return / 小键盘 Enter
                guard isSearching, !flatRows.isEmpty else { return event }
                if modifiers.contains(.command) {
                    playCursorRow()
                } else {
                    openCursorRow()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func moveCursor(_ delta: Int) {
        let count = flatRows.count
        guard count > 0 else { return }
        cursor = min(max(cursor + delta, 0), count - 1)
    }

    private func cursorRow() -> SearchRow? {
        let rows = flatRows
        guard rows.indices.contains(cursor) else { return nil }
        return rows[cursor]
    }

    private func openCursorRow() {
        guard let row = cursorRow() else { return }
        switch row {
        case .entry(let id):
            if let entry = results.entries.first(where: { $0.id == id }) { onOpen(entry) }
        case .series(let id):
            if let item = results.series.first(where: { $0.id == id }) { onOpenSeries(item) }
        case .person(let name):
            if let person = results.people.first(where: { $0.name == name }) { personTarget = person }
        }
    }

    private func playCursorRow() {
        guard let row = cursorRow() else { return }
        switch row {
        case .entry(let id):
            if let entry = results.entries.first(where: { $0.id == id }) { onPlay(entry) }
        case .series(let id):
            if let item = results.series.first(where: { $0.id == id }),
               let latest = item.latestEpisode {
                onPlay(latest)
            }
        case .person:
            break
        }
    }

    /// 范围说明：让用户知道搜的是本库还是包含未识别文件名。
    private var scopeBar: some View {
        HStack(spacing: 6) {
            Text("范围")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            scopeChip("仅本库", active: !includeUnmatched) {
                includeUnmatched = false
            }
            scopeChip("含未识别文件名", active: includeUnmatched) {
                includeUnmatched = true
            }
            Spacer(minLength: 0)
            Text("↑↓ 选择 · ⏎ 详情 · ⌘⏎ 播放")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text("在「\(store.cinemaScopeName(store.cinemaActiveScope))」里检索")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func scopeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(active ? LumaBrand.amber.opacity(0.14)
                                                  : Color.primary.opacity(0.05)))
                .overlay {
                    Capsule().strokeBorder(active ? LumaBrand.amber.opacity(0.32)
                                                  : Color.primary.opacity(0.08), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索片名、演员、导演、类型或文件名", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
            Divider().frame(height: 16)
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if !isSearching {
            VStack(alignment: .leading, spacing: 8) {
                Text("在「\(store.cinemaScopeName(store.cinemaActiveScope))」里检索")
                    .font(.system(size: 12, weight: .medium))
                Text("支持片名、原名、文件名、类型，以及补全后的演员与导演。示例：诺兰、科幻、S01E02.mkv。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.cinemaParentalLocked {
                    Label("家长控制已启用，受限分级内容不会出现在结果里。",
                          systemImage: "lock.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LumaBrand.coral)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if totalCount == 0 {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("没有找到匹配内容")
                    .font(.system(size: 12, weight: .medium))
                Text("试试更短的关键词，或先在详情页重新匹配 / 补全演职员。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !results.entries.isEmpty {
                        sectionTitle("电影", count: results.entries.count)
                        ForEach(Array(results.entries.enumerated()), id: \.element.id) { index, entry in
                            movieRow(entry, highlighted: cursor == index)
                        }
                    }
                    if !results.series.isEmpty {
                        sectionTitle("剧集", count: results.series.count)
                        let offset = results.entries.count
                        ForEach(Array(results.series.enumerated()), id: \.element.id) { index, item in
                            seriesRow(item, highlighted: cursor == offset + index)
                        }
                    }
                    if !results.people.isEmpty {
                        sectionTitle("人物", count: results.people.count)
                        let offset = results.entries.count + results.series.count
                        ForEach(Array(results.people.enumerated()), id: \.offset) { index, person in
                            personRow(person, highlighted: cursor == offset + index)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func movieRow(_ entry: CinemaEntry, highlighted: Bool = false) -> some View {
        HStack(spacing: 10) {
            Button {
                onOpen(entry)
            } label: {
                HStack(spacing: 10) {
                    poster(url: entry.posterURL, photo: entry.file.photoItem, width: 44, height: 66)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if let original = entry.originalTitle, !original.isEmpty {
                            Text(original)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(detailLine(entry))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(sourceLabel(entry))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

            Button {
                onPlay(entry)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(LumaBrand.amber, in: Circle())
            }
            .buttonStyle(.plain)
            .help("播放 \(entry.title)")
        }
        .padding(8)
        .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear, lineWidth: 0.8)
        }
    }

    private func seriesRow(_ item: CinemaSeries, highlighted: Bool = false) -> some View {
        Button {
            onOpenSeries(item)
        } label: {
            HStack(spacing: 10) {
                poster(url: item.posterURL, photo: item.episodes.first?.file.photoItem, width: 44, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let genres = item.episodes.first?.genres, !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: " / "))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(sourceLabel(item.episodes.first))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear,
                                  lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func personRow(_ person: CinemaCastMember, highlighted: Bool = false) -> some View {
        Button {
            personTarget = person
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let url = person.profileURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.18))
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(person.character ?? "演职员")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("人物页 ›")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear,
                                  lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func poster(url: String?, photo: PhotoItem?, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let url {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(height * 2))
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// 结果来源：本地图库标「本库」，网盘标挂载名。
    private func sourceLabel(_ entry: CinemaEntry?) -> String {
        guard let entry, let id = entry.file.cloudMountID else { return "本库" }
        return store.cloudMounts.first { $0.id == id }?.name ?? "网盘"
    }

    private func detailLine(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        if let genres = entry.genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: " / "))
        }
        if let cast = entry.cast, let first = cast.first {
            parts.append(first.name)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 观看记录

private struct CinemaHistoryPanel: View {
    let scope: CinemaScope
    let onResume: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingClear = false
    @State private var pendingRemoval: CinemaProgressRecord?
    /// 文档约定：观看记录可按「全部 / 进行中 / 已看完」分段，并按今天 / 本周 / 更早分组。
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, inProgress, finished
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .inProgress: return "进行中"
            case .finished: return "已看完"
            }
        }
    }

    private var records: [CinemaProgressRecord] {
        store.cinemaHistory(for: scope)
    }

    private var filteredRecords: [CinemaProgressRecord] {
        switch filter {
        case .all: return records
        case .inProgress: return records.filter { !$0.isFinished }
        case .finished: return records.filter(\.isFinished)
        }
    }

    /// 今天 / 本周 / 更早三段；空段不显示。
    private var groupedRecords: [(title: String, records: [CinemaProgressRecord])] {
        let calendar = Calendar.current
        let now = Date()
        var today: [CinemaProgressRecord] = []
        var week: [CinemaProgressRecord] = []
        var earlier: [CinemaProgressRecord] = []
        for record in filteredRecords {
            if calendar.isDateInToday(record.updatedAt) {
                today.append(record)
            } else if calendar.isDate(record.updatedAt, equalTo: now, toGranularity: .weekOfYear) {
                week.append(record)
            } else {
                earlier.append(record)
            }
        }
        return [("今天", today), ("本周", week), ("更早", earlier)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, records: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有观看记录")
                        .font(.system(size: 12, weight: .medium))
                    Text("从影院播放任意影片后，进度会出现在这里。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: filter == .finished ? "checkmark.circle" : "play.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(filter == .finished ? "还没有看完的影片" : "没有进行中的影片")
                        .font(.system(size: 12, weight: .medium))
                    Button("查看全部") { filter = .all }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedRecords, id: \.title) { group in
                            HStack(spacing: 6) {
                                Text(group.title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("\(group.records.count)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 4)
                            ForEach(group.records) { record in
                                row(record)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("清除全部观看记录？", isPresented: $pendingClear) {
            Button("清除", role: .destructive) { store.clearCinemaProgress() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空继续观看与所有进度，影片文件不受影响。")
        }
        .confirmationDialog("移出这条观看记录？",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { record in
            Button("移出记录", role: .destructive) {
                store.removeCinemaProgress(record.id)
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: { record in
            Text("「\(record.title)」的进度会被移除，影片文件不受影响。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("观看记录")
                .font(.system(size: 15, weight: .semibold))
            Text("\(filteredRecords.count) 条")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            Spacer(minLength: 0)
            if !records.isEmpty {
                Button("清除全部…") { pendingClear = true }
                    .controlSize(.small)
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func row(_ record: CinemaProgressRecord) -> some View {
        let entry = store.cinemaEntries(for: scope)[record.photoID]
        return HStack(spacing: 10) {
            ZStack {
                if let url = record.artworkURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else if let entry {
                    PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(120))
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 96, height: 54)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                    }
                    Text(record.isFinished ? "已看完" : "剩余 \(remainingText(record))")
                        .foregroundStyle(record.isFinished ? Color.secondary : LumaBrand.amber)
                }
                .font(.system(size: 10))
                .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(record.isFinished ? Color.secondary.opacity(0.5) : LumaBrand.amber)
                            .frame(width: max(3.0, geo.size.width * record.fraction))
                    }
                }
                .frame(height: 3)
            }

            Spacer(minLength: 0)

            if let entry {
                if !record.isFinished {
                    Button {
                        onResume(entry)
                    } label: {
                        Label("继续", systemImage: "play.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .controlSize(.small)
                }
                Button {
                    pendingRemoval = record
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
                .help("移出观看记录")
            } else {
                Text("文件已不在影院")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func remainingText(_ record: CinemaProgressRecord) -> String {
        let minutes = Int((record.remainingSeconds / 60).rounded())
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(max(1, minutes)) 分钟"
    }
}

// MARK: - 任务中心

private struct CinemaTaskCenterSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingClear = false
    /// 文档约定：任务按「全部 / 进行中 / 已完成 / 失败」分段，失败项单独重试。
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, running, done, failed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .running: return "进行中"
            case .done: return "已完成"
            case .failed: return "失败"
            }
        }
    }

    private var filteredTasks: [CinemaTaskRecord] {
        let sorted = store.cinemaTasks.sorted { $0.startedAt > $1.startedAt }
        switch filter {
        case .all:
            return sorted
        case .running:
            return sorted.filter { $0.finishedAt == nil }
        case .done:
            return sorted.filter { $0.finishedAt != nil && $0.succeeded }
        case .failed:
            return sorted.filter { $0.finishedAt != nil && !$0.succeeded }
        }
    }

    /// 近 7 天概览：几次刮削、多少视频、识别多少、失败几次。
    private var recentStats: (runs: Int, videos: Int, matched: Int, failed: Int) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = store.cinemaTasks.filter { $0.startedAt >= cutoff }
        return (recent.count,
                recent.reduce(0) { $0 + $1.total },
                recent.reduce(0) { $0 + $1.matched },
                recent.filter { $0.finishedAt != nil && !$0.succeeded }.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("任务中心")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(filteredTasks.count) 条")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 232)
                Spacer(minLength: 0)
                if filter == .failed, !filteredTasks.isEmpty {
                    Button("重试全部失败") {
                        let failures = filteredTasks
                        Task {
                            for task in failures {
                                await store.retryCinemaTask(task)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                if !store.cinemaTasks.isEmpty {
                    Button("清空…") { pendingClear = true }
                        .controlSize(.small)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            statBar

            Divider()

            if store.cinemaTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有刮削任务")
                        .font(.system(size: 12, weight: .medium))
                    Text("每次刮削与重新匹配都会留下记录，失败可以直接重试。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: filter == .failed ? "checkmark.seal" : "tray")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(emptyText)
                        .font(.system(size: 12, weight: .medium))
                    Button("查看全部") { filter = .all }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredTasks) { task in
                            row(task)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 620, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("清空任务记录？", isPresented: $pendingClear) {
            Button("清空", role: .destructive) { store.clearCinemaTasks() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除任务归档，不影响刮削结果与影片文件。")
        }
    }

    private var emptyText: String {
        switch filter {
        case .failed: return "近 7 天没有失败任务"
        case .running: return "当前没有进行中的任务"
        case .done: return "还没有已完成的任务"
        case .all: return "没有任务记录"
        }
    }

    private var statBar: some View {
        let stats = recentStats
        return HStack(spacing: 10) {
            Text("近 7 天")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("\(stats.runs) 次刮削")
            Text("\(stats.videos) 个视频")
            Text("识别 \(stats.matched)")
                .foregroundStyle(LumaBrand.amber)
            if stats.failed > 0 {
                Text("失败 \(stats.failed) 次")
                    .foregroundStyle(LumaBrand.coral)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func row(_ task: CinemaTaskRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon(task))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor(task))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.scopeName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(task.finishedAt == nil ? "进行中" : (task.succeeded ? "已完成" : "失败"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(statusColor(task))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(statusColor(task).opacity(0.12)))
                    Spacer(minLength: 0)
                    Text(task.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Text("共 \(task.total) 个视频 · 识别 \(task.matched) 个")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if !task.message.isEmpty {
                    Text(task.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if task.finishedAt != nil, !task.succeeded {
                Button("重试") {
                    Task { await store.retryCinemaTask(task) }
                }
                .controlSize(.small)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func statusIcon(_ task: CinemaTaskRecord) -> String {
        if task.finishedAt == nil { return "clock" }
        return task.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(_ task: CinemaTaskRecord) -> Color {
        if task.finishedAt == nil { return LumaBrand.amber }
        return task.succeeded ? .green : LumaBrand.coral
    }
}

// MARK: - 右上角 Toast 栈（F4）

private struct CinemaToastStack: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.cinemaToasts) { toast in
                card(toast)
            }
        }
        .frame(width: 340, alignment: .trailing)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(.snappy(duration: 0.2), value: store.cinemaToasts.map(\.id))
    }

    private func card(_ toast: CinemaToast) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(toast.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint(toast.kind))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    store.dismissCinemaToast(toast.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            }

            Button {
                store.dismissCinemaToast(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tint(toast.kind).opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func icon(_ kind: CinemaToastKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .progress: return "arrow.down.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func tint(_ kind: CinemaToastKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return LumaBrand.coral
        case .progress: return LumaBrand.amber
        case .info: return LumaBrand.violet
        }
    }
}

// MARK: - 人物页（B4）

/// 演职员页：作为影院详情里的二级页铺满内容区（不弹窗），
/// 版式和「剧集档案」同一套：深色玻璃卡 + 琥珀渐变描边 + 大头像作视觉锚点。
private struct CinemaPersonDetailView: View {
    let member: CinemaCastMember
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    var onPlay: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore

    private enum Lane: String, CaseIterable, Identifiable {
        case library = "本库已有"
        case all = "全部作品"
        var id: String { rawValue }
    }

    @State private var lane: Lane = .library
    @State private var profile: CinemaPersonProfile?
    @State private var loading = true
    @State private var bioExpanded = false

    private var works: [CinemaEntry] { store.cinemaPersonWorks(named: member.name) }
    private var credits: [CinemaPersonCredit] { profile?.credits ?? [] }

    var body: some View {
        ZStack {
            ambient
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileCard
                    worksSection
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 36)
                .frame(maxWidth: 1440, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cinemaSheetBackground)
        .environment(\.colorScheme, .dark)
        .task {
            if member.tmdbID != nil {
                profile = await store.cinemaPersonProfile(for: member)
            }
            loading = false
        }
    }

    /// 用本库作品的海报虚化铺底：和影院其他详情页一致的氛围层。
    private var ambient: some View {
        ZStack(alignment: .top) {
            cinemaSheetBackground
            CinemaArtwork(urlString: works.first?.backdropURL ?? works.first?.posterURL,
                          contentMode: .fill)
                .frame(height: 720)
                .blur(radius: 90, opaque: true)
                .opacity(0.16)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.72), location: 0.34),
                        .init(color: .black.opacity(0.22), location: 0.70),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }


    // MARK: 档案卡

    /// 大头像 + 姓名 / 角色 / 生卒地 / 简介：和「剧集档案」同一张玻璃卡。
    private var profileCard: some View {
        HStack(alignment: .top, spacing: 26) {
            avatarColumn
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("演职员档案")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(LumaBrand.amber.opacity(0.92))
                    Rectangle()
                        .fill(LumaBrand.amber.opacity(0.35))
                        .frame(width: 24, height: 0.8)
                    Text(departmentText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(member.name)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)

                if let character = member.character, !character.isEmpty {
                    Text("饰 \(character)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }

                chipRow
                bioBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.062),
                                              Color.white.opacity(0.022)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            Color.white.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
    }

    /// 头像 + 本库作品数：圆形头像带琥珀细环和外圈留白，像一张档案照。
    private var avatarColumn: some View {
        VStack(spacing: 12) {
            ZStack {
                if let url = profile?.profileURL ?? member.profileURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    Circle().fill(Color.white.opacity(0.06))
                    Image(systemName: "person.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: 172, height: 172)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(LumaBrand.amber.opacity(0.30), lineWidth: 1.2)
            }
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8).padding(-7)
            }
            .shadow(color: LumaBrand.amber.opacity(0.16), radius: 26, y: 12)

            HStack(spacing: 5) {
                Image(systemName: "film.stack")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("本库 \(works.count) 部")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.white.opacity(0.07), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6) }
        }
        .frame(width: 172, alignment: .top)
    }

    private var chipRow: some View {
        HStack(spacing: 7) {
            chip("本库 \(works.count) 部", highlight: true)
            chip("全部 \(credits.isEmpty ? "—" : "\(credits.count)") 部")
            if let birthday = profile?.birthday, !birthday.isEmpty {
                chip(birthday)
            }
            if let place = profile?.placeOfBirth, !place.isEmpty {
                chip(place)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var bioBlock: some View {
        if let bio = profile?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(bio)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineSpacing(6)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 980, alignment: .leading)
                    .textSelection(.enabled)
                if bio.count > 160 {
                    Button(bioExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            bioExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        } else if loading {
            ProgressView().controlSize(.mini)
        } else {
            Text(works.isEmpty
                 ? "本库还没有这位参与的作品，重新刮削后可看到更多资料。"
                 : "本库已收录 \(works.count) 部，可直接播放。")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var departmentText: String {
        guard let department = profile?.department, !department.isEmpty else { return "演职员" }
        switch department {
        case "Acting": return "演员"
        case "Directing": return "导演"
        case "Writing": return "编剧"
        case "Production": return "制片"
        case "Camera": return "摄影"
        case "Art": return "美术"
        case "Sound": return "音效"
        case "Editing": return "剪辑"
        case "Costume & Make-Up": return "造型"
        case "Visual Effects": return "视效"
        default: return department
        }
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(highlight ? LumaBrand.amber.opacity(0.12)
                                                 : Color.primary.opacity(0.06)))
            .overlay {
                Capsule().strokeBorder(highlight ? LumaBrand.amber.opacity(0.30)
                                                 : Color.primary.opacity(0.08), lineWidth: 0.6)
            }
    }

    /// 作品区：标题行 + 本库 / 全部切换 + 海报网格。
    private var worksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("作品")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(lane == .library ? works.count : credits.count) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                laneSwitch
            }
            content
        }
    }

    private var laneSwitch: some View {
        HStack(spacing: 4) {
            ForEach(Lane.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.16)) { lane = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(lane == item ? LumaBrand.amber.opacity(0.16)
                                                   : Color.white.opacity(0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(lane == item ? LumaBrand.amber.opacity(0.35)
                                                           : Color.white.opacity(0.07),
                                              lineWidth: 0.7)
                        }
                        .foregroundStyle(lane == item ? LumaBrand.amber : Color.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
            if loading {
                ProgressView().controlSize(.mini).padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch lane {
        case .library:
            if works.isEmpty {
                emptyHint("本库暂时没有这位参与的作品",
                          detail: "到海报墙右键影片重新刮削，补全演职员后这里会自动出现。")
            } else {
                grid {
                    ForEach(works) { entry in
                        workTile(entry)
                    }
                }
            }
        case .all:
            if loading {
                ProgressView("正在读取 TMDB 作品…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if profile == nil {
                emptyHint("没有可用的 TMDB 人物资料",
                          detail: "重新刮削这部影片后会补上人物 ID，就能看到全部作品。")
            } else if credits.isEmpty {
                emptyHint("TMDB 没有收录这位的作品", detail: "可以试试搜索片名或导演。")
            } else {
                grid {
                    ForEach(credits) { credit in
                        creditTile(credit)
                    }
                }
            }
        }
    }

    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16, alignment: .top)],
                  alignment: .leading, spacing: 18) {
            content()
        }
    }

    private func workTile(_ entry: CinemaEntry) -> some View {
        Button {
            play(entry)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                poster(url: entry.artworkURL, photo: entry.file.photoItem)
                    .overlay(alignment: .topLeading) {
                        ownedBadge
                    }
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.kind == .tv ? "剧集 · \(entry.year.map(String.init) ?? "—")"
                                       : (entry.year.map(String.init) ?? "—"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("查看详情") { openDetail(entry) }
            Button("直接播放") { play(entry) }
        }
        .help("点击播放")
    }

    private func creditTile(_ credit: CinemaPersonCredit) -> some View {
        let owned = store.cinemaEntry(forCredit: credit)
        return Button {
            if let owned { play(owned) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                poster(url: credit.posterURL, photo: nil)
                    .overlay(alignment: .topLeading) {
                        if owned != nil { ownedBadge }
                    }
                    .opacity(owned == nil ? 0.72 : 1)
                Text(credit.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle(for: credit))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(owned == nil)
        .help(owned == nil ? "未入库，只做展示" : "点击播放")
    }

    private func subtitle(for credit: CinemaPersonCredit) -> String {
        var parts: [String] = []
        parts.append(credit.isTV ? "剧集" : "电影")
        if let year = credit.year { parts.append(String(year)) }
        if let job = credit.job, !job.isEmpty { parts.append(job) }
        else if let character = credit.character, !character.isEmpty { parts.append(character) }
        return parts.joined(separator: " · ")
    }

    private var ownedBadge: some View {
        Text("在库")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(LumaBrand.amber)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.62)))
            .padding(6)
    }

    private func poster(url: String?, photo: PhotoItem?) -> some View {
        ZStack {
            if let url {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(240))
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        }
    }

    private func emptyHint(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func play(_ entry: CinemaEntry) {
        onPlay(entry)
    }

    private func openDetail(_ entry: CinemaEntry) {
        onOpenEntry(entry)
    }
}

/// 搜索面板本身是 sheet：里面点开人物仍用弹窗承载同一套人物页。
private struct CinemaPersonSheet: View {
    let member: CinemaCastMember
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CinemaPersonDetailView(
            member: member,
            onOpenEntry: { entry in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onOpenEntry(entry) }
            },
            onPlay: { entry in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.openCinema(entry) }
            }
        )
        .frame(width: min(1220, cinemaDetailWindowSize.width),
               height: min(880, cinemaDetailWindowSize.height))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(14)
            .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - 合集详情页（B3）

private struct CinemaCollectionSheet: View {
    let collectionID: Int
    let name: String
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var info: CinemaCollectionInfo?

    private var entries: [CinemaEntry] {
        store.cinemaCollection(collectionID: collectionID)
    }

    private var versionCount: Int {
        entries.reduce(0) { $0 + max(1, store.cinemaVersions(for: $1).count) }
    }

    private var watchedCount: Int {
        entries.filter { store.cinemaProgress[$0.id]?.isFinished == true }.count
    }

    private var nextEntry: CinemaEntry? {
        entries.first { !(store.cinemaProgress[$0.id]?.isFinished ?? false) }
    }

    private var totalHours: String {
        let seconds = entries.reduce(0.0) { $0 + ($1.file.duration ?? 0) }
        guard seconds > 0 else { return "—" }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    /// 未入库的下一部：只提示，不生成空条目。
    private var missingPart: CinemaCollectionPart? {
        guard let info, !info.parts.isEmpty else { return nil }
        // 合集 ID 都是 TMDB 的，只拿 TMDB 条目的 ID 判重。
        let owned = Set(entries.filter { $0.provider == .tmdb }.compactMap(\.tmdbID))
        let pending = info.parts.filter { !owned.contains($0.tmdbID) }
        guard !pending.isEmpty else { return nil }
        let lastYear = entries.last?.year ?? 0
        return pending.first { ($0.year ?? 0) >= lastYear } ?? pending.first
    }

    var body: some View {
        ZStack {
            cinemaSheetBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    posterRow
                    columns
                    fileNote
                }
                .padding(.horizontal, 28)
                .padding(.top, 54)
                .padding(.bottom, 32)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: min(1220, cinemaDetailWindowSize.width),
               height: min(880, cinemaDetailWindowSize.height))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(14)
            .keyboardShortcut(.cancelAction)
        }
        .task {
            info = await store.cinemaCollectionInfo(collectionID: collectionID)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("合集 · COLLECTION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(LumaBrand.amber.opacity(0.9))
                Text(name)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                Text("\(entries.count) 部 · \(versionCount) 个版本 · 已看 \(watchedCount) / \(entries.count) · 总时长 \(totalHours)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    playAll()
                } label: {
                    Label("按上映顺序播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(entries.isEmpty)
                Button("关闭") { dismiss() }
                    .controlSize(.regular)
            }
        }
    }

    private var posterRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                if let url = entry.artworkURL {
                                    CinemaArtwork(urlString: url, contentMode: .fill)
                                } else {
                                    PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(240))
                                }
                            }
                            .frame(width: 118, height: 174)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                            }
                            .overlay(alignment: .topLeading) {
                                if store.cinemaProgress[entry.id]?.isFinished == true {
                                    Text("已看")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(LumaBrand.amber)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.black.opacity(0.62)))
                                        .padding(6)
                                }
                            }
                            Text(entry.year.map(String.init) ?? "—")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(entry.title)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                collectionSectionTitle("合集简介")
                if let overview = info?.overview, !overview.isEmpty {
                    CinemaSynopsis(text: overview)
                } else {
                    Text("TMDB 没有提供合集简介。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack(spacing: 7) {
                    chip("自动合集", highlight: true)
                    chip("TMDB 归属")
                    chip("按年份排序")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                collectionSectionTitle("合集统计")
                VStack(spacing: 0) {
                    statRow("影片", "\(entries.count) 部")
                    statRow("版本", "\(versionCount) 个")
                    statRow("已看", "\(watchedCount) 部")
                    if let missingPart {
                        statRow("下一部", "\(missingPart.title)（\(missingPart.year.map(String.init) ?? "未定") 未入库）",
                                highlight: true)
                    } else if let nextEntry {
                        statRow("下一部", nextEntry.title, highlight: true)
                    } else if !entries.isEmpty {
                        statRow("下一部", "全部看完", highlight: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
                }
            }
            .frame(width: 340)
        }
    }

    private var fileNote: some View {
        Text("同一部片的多版本在合集里折叠为一个海报，播放前可在详情页选版本。未入库的续集只做提示，不生成空条目。")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func collectionSectionTitle(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LumaBrand.amber)
                .frame(width: 3, height: 13)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    private func statRow(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: highlight ? .semibold : .regular))
                .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(highlight ? LumaBrand.amber.opacity(0.12)
                                                 : Color.primary.opacity(0.06)))
            .overlay {
                Capsule().strokeBorder(highlight ? LumaBrand.amber.opacity(0.30)
                                                 : Color.primary.opacity(0.08), lineWidth: 0.6)
            }
    }

    private func playAll() {
        guard let entry = nextEntry ?? entries.first else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.openCinema(entry)
        }
    }

    private func open(_ entry: CinemaEntry) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onOpenEntry(entry)
        }
    }
}

// MARK: - 通知中心（F4）

private struct CinemaNotificationSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var groups: [(String, [CinemaNotification])] {
        let calendar = Calendar.current
        var today: [CinemaNotification] = []
        var week: [CinemaNotification] = []
        var older: [CinemaNotification] = []
        for item in store.cinemaNotifications {
            if calendar.isDateInToday(item.date) {
                today.append(item)
            } else if let days = calendar.dateComponents([.day], from: item.date, to: Date()).day,
                      days < 7 {
                week.append(item)
            } else {
                older.append(item)
            }
        }
        return [("今天", today), ("本周", week), ("更早", older)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if store.cinemaNotifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.0) { group in
                            Text(group.0)
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(.tertiary)
                            ForEach(group.1) { item in
                                row(item)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 620, height: 560)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("通知")
                    .font(.system(size: 14, weight: .semibold))
                Text("仅保留最近 30 天")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if store.cinemaUnreadNotificationCount > 0 {
                Text("\(store.cinemaUnreadNotificationCount) 未读")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(LumaBrand.coral)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(LumaBrand.coral.opacity(0.14)))
            }
            Spacer(minLength: 0)
            Button("全部已读") {
                store.markAllCinemaNotificationsRead()
            }
            .controlSize(.small)
            Button("清空") {
                store.clearCinemaNotifications()
            }
            .controlSize(.small)
            Button("完成") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有通知")
                .font(.system(size: 12.5, weight: .medium))
            Text("刮削完成、匹配失败和字幕下载都会归档到这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: CinemaNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint(item.kind))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: item.read ? .regular : .semibold))
                    .foregroundStyle(item.read ? Color.secondary : Color.primary)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(timeText(item.date))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let action = item.action {
                Button(action) {
                    handle(action, item)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(item.read ? Color.primary.opacity(0.025) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(item.read ? Color.white.opacity(0.04) : Color.white.opacity(0.09),
                              lineWidth: 0.6)
        }
        .onTapGesture {
            markRead(item)
        }
    }

    private func handle(_ action: String, _ item: CinemaNotification) {
        markRead(item)
        if action == "重试", let key = item.scopeKey {
            dismiss()
            Task { await store.retryCinemaScope(key: key) }
        } else {
            store.postCinemaToast(.info, title: "已标记为处理", detail: item.title)
        }
    }

    private func markRead(_ item: CinemaNotification) {
        guard let index = store.cinemaNotifications.firstIndex(where: { $0.id == item.id }),
              !store.cinemaNotifications[index].read else { return }
        store.cinemaNotifications[index].read = true
        store.persistCinemaNotifications()
    }

    private func tint(_ kind: CinemaNotificationKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return LumaBrand.coral
        case .progress: return LumaBrand.amber
        case .info: return LumaBrand.violet
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 文件夹详情

private struct CinemaFolderDetailView: View {
    let scope: CinemaScope
    let onPlay: (CinemaEntry) -> Void
    let onOpenEntry: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var folder: CinemaFolder
    /// 已经钻过的目录链，用来返回上一级。
    @State private var trail: [String]
    @State private var scraping = false
    @State private var matchRequest: CinemaQuickMatchRequest?

    init(folder: CinemaFolder,
         scope: CinemaScope,
         onPlay: @escaping (CinemaEntry) -> Void,
         onOpenEntry: @escaping (CinemaEntry) -> Void) {
        self.scope = scope
        self.onPlay = onPlay
        self.onOpenEntry = onOpenEntry
        _folder = State(initialValue: folder)
        _trail = State(initialValue: [folder.path])
    }

    private var entriesByID: [UUID: CinemaEntry] {
        Dictionary(folder.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var sortedPhotos: [PhotoItem] {
        folder.photos.sorted { lhs, rhs in
            let left = CinemaScraper.parse(filename: lhs.displayFilename, folderHint: folder.hint)
            let right = CinemaScraper.parse(filename: rhs.displayFilename, folderHint: folder.hint)
            if (left.season ?? 0) != (right.season ?? 0) {
                return (left.season ?? 0) < (right.season ?? 0)
            }
            if (left.episode ?? 0) != (right.episode ?? 0) {
                return (left.episode ?? 0) < (right.episode ?? 0)
            }
            return lhs.displayFilename.localizedStandardCompare(rhs.displayFilename) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(folder.children) { child in
                        childRow(child)
                    }
                    if !folder.children.isEmpty, !sortedPhotos.isEmpty {
                        sectionLabel("本目录视频 · \(sortedPhotos.count)")
                    }
                    ForEach(sortedPhotos) { photo in
                        row(photo)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 760, height: 580)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .onChange(of: store.cinemaFolderRefreshToken) { _, _ in
            refresh()
        }
        .sheet(item: $matchRequest) { request in
            CinemaMatchSheet(photos: request.photos, folderHint: folder.hint) {
                matchRequest = nil
                refresh()
            }
            .environmentObject(store)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 7) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func childRow(_ child: CinemaFolder) -> some View {
        Button {
            trail.append(child.path)
            folder = child
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = child.posterURL ?? child.backdropURL {
                            CinemaArtwork(urlString: url, contentMode: .fill)
                        } else if let photo = child.firstPhoto {
                            PhotoThumbnailView(photo: photo, purpose: .cover(120))
                        } else {
                            Color.secondary.opacity(0.12)
                        }
                    }
                    .frame(width: 96, height: 54)
                    .clipped()

                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(child.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(child.matchedCount)/\(child.totalCount) 已识别")
                            .foregroundStyle(child.isMatched ? LumaBrand.amber : Color.secondary)
                        Text(child.displayPath)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 9.5))
                }

                Spacer(minLength: 0)

                if child.hasChildren {
                    Text("\(child.children.count) 个子目录")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text("\(child.photos.count) 个视频")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if trail.count > 1 {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("返回上一级")
                .padding(.top, 32)
            }

            ZStack {
                if let url = folder.posterURL ?? folder.backdropURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else if let photo = folder.firstPhoto {
                    PhotoThumbnailView(photo: photo, purpose: .cover(160))
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 60, height: 90)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.displayTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(folder.displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(folder.matchedCount)/\(folder.totalCount) 已识别")
                        .foregroundStyle(folder.isMatched ? LumaBrand.amber : Color.secondary)
                    if folder.episodeCount > 0 {
                        Text("\(folder.episodeCount) 集")
                            .foregroundStyle(.secondary)
                    }
                    Text("本目录 \(folder.photos.count) · 共 \(folder.totalCount) 个视频")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium))
            }

            Spacer(minLength: 0)

            if scraping {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("刮削中…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("手动匹配…") {
                    matchRequest = CinemaQuickMatchRequest(photos: folder.subtreePhotos)
                }
                .controlSize(.small)
                Button {
                    scrape()
                } label: {
                    Label("刮削此目录", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ photo: PhotoItem) -> some View {
        let entry = entriesByID[photo.id]
        return HStack(spacing: 10) {
            ZStack {
                if let url = entry?.gridArtworkURL ?? entry?.artworkURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    PhotoThumbnailView(photo: photo, purpose: .cover(120))
                }
            }
            .frame(width: 96, height: 54)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.title ?? photo.displayFilename)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let subtitle = entry?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    Text(photo.displayFilename)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 9.5))
            }

            Spacer(minLength: 0)

            Text(entry == nil ? "未刮削" : (entry?.matched == true ? "已识别" : "未识别"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(entry?.matched == true ? LumaBrand.amber : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(entry?.matched == true
                                           ? LumaBrand.amber.opacity(0.14)
                                           : Color.secondary.opacity(0.12)))

            if let entry, entry.matched {
                Button("播放") { onPlay(entry) }
                    .controlSize(.small)
            }
            if let entry {
                Button("详情") { onOpenEntry(entry) }
                    .controlSize(.small)
            }
            if entry?.matched != true {
                Button("匹配") {
                    matchRequest = CinemaQuickMatchRequest(photos: [photo])
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func scrape() {
        guard !scraping else { return }
        scraping = true
        Task {
            await store.scrapeCinemaFolder(folder, scope: scope)
            refresh()
            scraping = false
        }
    }

    private func refresh() {
        if let updated = store.cinemaFolder(path: folder.path, scope: scope) {
            folder = updated
        }
    }

    private func goBack() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        guard let path = trail.last,
              let updated = store.cinemaFolder(path: path, scope: scope) else { return }
        folder = updated
    }
}

// MARK: - 家长控制解锁

private struct CinemaPINPromptSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var hasPIN: Bool {
        CinemaKeychain.has(.parentalPIN)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(LumaBrand.coral)
                Text("家长控制")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(hasPIN
                 ? "输入 4 位 PIN 解锁本次会话；退出应用后会重新上锁。"
                 : "还没有设置 PIN。可直接解锁，建议到 设置 › 影院 › 家长控制 里设置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(unlock)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LumaBrand.coral)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("解锁") { unlock() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func unlock() {
        if store.unlockCinemaParental(pin: pin) {
            dismiss()
        } else {
            errorMessage = "PIN 不正确，请重试。"
            pin = ""
        }
    }
}
