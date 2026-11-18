import SwiftUI
import AppKit

// MARK: - 影院库（刮削后的电影 / 电视剧）

struct CinemaLibraryView: View {
    /// nil 表示本地图库的影院；有值表示某一个网盘实例自己的影院。
    let mountID: UUID?

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.openSettings) private var openSettings
    /// 打开设置时直接落在「影院」分页。
    @AppStorage(SettingsKeys.selectedTab) private var settingsTab: SettingsTab = .general

    @State private var hoveredID: UUID?
    @State private var hoveredSeriesID: String?
    /// 正在查看分集的剧；nil 表示没有打开详情。
    @State private var activeSeries: CinemaSeries?

    init(mountID: UUID? = nil) {
        self.mountID = mountID
    }

    private var scope: CinemaScope { mountID.map { .mount($0) } ?? .local }

    /// 这个链接下所有刮削过的条目（含未识别的），页面上要能看到「有视频」。
    private var allEntries: [CinemaEntry] {
        store.cinemaEntries(for: scope).values
            .sorted { $0.file.capturedAt > $1.file.capturedAt }
    }
    private var entries: [CinemaEntry] {
        allEntries.filter { entry in
            guard entry.matched else { return false }
            if let decade = store.cinemaDecade, entry.decade != decade { return false }
            if let genre = store.cinemaGenre, !(entry.genres ?? []).contains(genre) { return false }
            return true
        }
    }
    private var unmatched: [CinemaEntry] { allEntries.filter { !$0.matched } }
    private var movies: [CinemaEntry] { entries.filter { $0.kind == .movie } }
    /// 未识别的剧同样聚合成一张卡，避免一集一张铺满整行。
    private var unmatchedSeries: [CinemaSeries] {
        store.cinemaSeries(for: scope, matched: false)
    }
    private var unmatchedMovies: [CinemaEntry] {
        unmatched.filter { $0.kind == .movie }
    }
    /// 同一部剧的多集合并成一张卡片；筛选条件与条目列表保持一致。
    private var series: [CinemaSeries] {
        store.cinemaSeries(for: scope).filter { item in
            if let decade = store.cinemaDecade,
               !item.episodes.contains(where: { $0.decade == decade }) {
                return false
            }
            if let genre = store.cinemaGenre,
               !item.episodes.contains(where: { ($0.genres ?? []).contains(genre) }) {
                return false
            }
            return true
        }
    }

    /// 是否启用了顶栏筛选（年代 / 类型）。
    private var isFilteringCinema: Bool {
        store.cinemaDecade != nil || store.cinemaGenre != nil
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
        // 控制台整体上移到窗口工具栏（CinemaToolbarConsole），内容区不再单独占一条。
        .task(id: scope) {
            // 只切换影院的作用域，不顺带刮削：影院和「视频」是两个入口，
            // 打开影院不应该等于把这个链接下的视频扫一遍，刮削只由显式点击触发。
            store.activateCinemaScope(scope)
        }
        .sheet(item: $activeSeries) { item in
            CinemaSeriesDetailView(series: item) { entry in
                activeSeries = nil
                store.openCinema(entry)
            }
            .environmentObject(store)
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
        if allEntries.isEmpty {
            emptyState
        } else {
            switch store.cinemaTab {
            case .all:
                if !series.isEmpty {
                    seriesHero()
                    seriesShelf("电视剧", series)
                }
                if !movies.isEmpty {
                    if series.isEmpty { hero(entries: movies) }
                    shelf("电影", Array(movies.prefix(18)))
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
                    } else {
                        tabEmptyState("还没有识别到电影")
                    }
                } else {
                    hero(entries: movies)
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
                    } else {
                        tabEmptyState("还没有识别到电视剧")
                    }
                } else {
                    seriesHero()
                    seriesShelf("全部剧集", series)
                    seriesShelf("按剧名", series.sorted { $0.title < $1.title })
                    if !isFilteringCinema, !unmatchedSeries.isEmpty {
                        unmatchedShelf
                    }
                }
            }
        }
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
                    store.cinemaDecade = nil
                    store.cinemaGenre = nil
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// 顶栏筛选条件的可读描述，例如「2020 年代 · 科幻」。
    private var filterSummary: String {
        var parts: [String] = []
        if let decade = store.cinemaDecade { parts.append("\(decade) 年代") }
        if let genre = store.cinemaGenre { parts.append(genre) }
        return parts.joined(separator: " · ")
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
            CinemaHeroCard(entry: entry) {
                store.openCinema(entry)
            }
        }
    }

    private func shelf(_ title: String, _ list: [CinemaEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(list) { entry in
                        CinemaPosterCard(entry: entry,
                                         hovered: hoveredID == entry.id) {
                            hoveredID = $0 ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
                        } onOpen: {
                            store.openCinema(entry)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 剧集（多集 → 一张卡）

    @ViewBuilder
    private func seriesHero() -> some View {
        if let item = series.first(where: { $0.backdropURL != nil }) ?? series.first {
            CinemaSeriesHeroCard(series: item) {
                activeSeries = item
            }
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
                            activeSeries = item
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
                            activeSeries = item
                        }
                    }
                    ForEach(unmatchedMovies.prefix(18)) { entry in
                        CinemaPosterCard(entry: entry,
                                         hovered: hoveredID == entry.id) {
                            hoveredID = $0 ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
                        } onOpen: {
                            store.openCinema(entry)
                        }
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
    @State private var showStatus = false

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

    /// 当前是否启用了年代 / 类型筛选。
    private var hasFilter: Bool {
        store.cinemaDecade != nil || store.cinemaGenre != nil
    }

    /// 筛选菜单里的年代选项：按库里实际存在的年份动态生成。
    private var decades: [Int] {
        Set(scopeEntries.filter { $0.matched }.compactMap { $0.decade }).sorted(by: >)
    }

    /// 筛选菜单里的类型选项：取已刮削到的类型标签。
    private var genres: [String] {
        Set(scopeEntries.filter { $0.matched }.flatMap { $0.genres ?? [] }).sorted()
    }

    private var filterTitle: String {
        var parts: [String] = []
        if let decade = store.cinemaDecade { parts.append("\(decade)s") }
        if let genre = store.cinemaGenre { parts.append(genre) }
        return parts.joined(separator: "·")
    }

    var body: some View {
        HStack(spacing: 0) {
            identity
            engravedSeparator
            tabs
            engravedSeparator
            filterMenu
            assistantKey
            scrapeKey
            settingsKnob
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background { consolePlate }
        .fixedSize()
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
                        Text("CINEMA")
                            .font(.system(size: 7, weight: .bold))
                            .tracking(2.0)
                            .foregroundStyle(accentText.opacity(0.92))
                    }
                    statusLine
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
                        Text(item.title)
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

    private func segmentWidth(_ item: CinemaTab) -> CGFloat {
        switch item {
        case .all: return 62
        case .movies: return 58
        case .shows: return 78
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

    // MARK: 筛选（年代 / 类型）

    private var filterMenu: some View {
        Menu {
            Section("年代") {
                filterMenuOption("全部年代", selected: store.cinemaDecade == nil) {
                    store.cinemaDecade = nil
                }
                ForEach(decades, id: \.self) { decade in
                    filterMenuOption("\(decade) 年代", selected: store.cinemaDecade == decade) {
                        store.cinemaDecade = decade
                    }
                }
            }

            Section("类型") {
                filterMenuOption("全部类型", selected: store.cinemaGenre == nil) {
                    store.cinemaGenre = nil
                }
                ForEach(genres, id: \.self) { genre in
                    filterMenuOption(genre, selected: store.cinemaGenre == genre) {
                        store.cinemaGenre = genre
                    }
                }
            }

            if hasFilter {
                Divider()
                Button("清除筛选") {
                    store.cinemaDecade = nil
                    store.cinemaGenre = nil
                }
            }
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .help("按年代、类型筛选电影与电视剧")
    }

    /// 菜单项的勾选态由选中值决定，保证「全部 / 某个年代」不会同时被打勾。
    @ViewBuilder
    private func filterMenuOption(_ title: String,
                                  selected: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: 智能助手

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
        .help("智能助手：用自然语言查找照片（只读，不会修改图库）")
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
                Text(settings.cinemaProvider.title)
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
                Button("重新刮削全部") {
                    showStatus = false
                    Task { await store.scrapeCinema(for: scope, force: true) }
                }
                .disabled(isScraping)
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

// MARK: - 剧集卡片（多集聚合）

private struct CinemaSeriesCard: View {
    let series: CinemaSeries
    let hovered: Bool
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
                .frame(width: 156, height: 234)
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
                    HStack(spacing: 4) {
                        Spacer()
                        Text("\(series.episodeCount) 集")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(.black.opacity(0.45), in: Capsule())
                        if !series.isMatched {
                            Text("未识别")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2.5)
                                .background(.black.opacity(0.45), in: Capsule())
                        } else if let rating = series.rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45), in: Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(7)
            }
            .frame(width: 156, height: 234)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: hovered ? 1.2 : 0.5)
            }
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .scaleEffect(hovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.16), value: hovered)
        }
        .frame(width: 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onOpen)
        .help("\(series.title) · \(series.subtitle)")
        .contextMenu {
            Button("查看 \(series.episodeCount) 集") { onOpen() }
            if let latest = series.latestEpisode {
                Button("播放最新一集") { store.openCinema(latest) }
            }
        }
    }
}

// MARK: - 剧集主视觉

private struct CinemaSeriesHeroCard: View {
    let series: CinemaSeries
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

    @Environment(\.dismiss) private var dismiss
    @State private var hoveredEpisode: UUID?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(series.episodes) { episode in
                        episodeCard(episode)
                    }
                }
                .padding(18)
            }
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 760, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: series.backdropURL ?? series.posterURL, contentMode: .fill)
                .frame(height: 190)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 6) {
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
                if let overview = series.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            .padding(18)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .padding(10)
        }
    }

    private func episodeCard(_ episode: CinemaEntry) -> some View {
        Button {
            onPlay(episode)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = episode.gridArtworkURL {
                            CinemaArtwork(urlString: url, contentMode: .fill)
                        } else {
                            PhotoThumbnailView(photo: episode.file.photoItem, purpose: .cover(170))
                        }
                    }
                    .frame(width: 170, height: 96)
                    .clipped()

                    Text(episodeLabel(episode))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(hoveredEpisode == episode.id
                                      ? LumaBrand.amber.opacity(0.65)
                                      : Color.primary.opacity(0.08),
                                      lineWidth: hoveredEpisode == episode.id ? 1 : 0.5)
                }

                Text(episode.file.filename)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 170, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredEpisode = episode.id
            } else if hoveredEpisode == episode.id {
                hoveredEpisode = nil
            }
        }
        .help(episode.file.filename)
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
}

// MARK: - 主视觉卡片

private struct CinemaHeroCard: View {
    let entry: CinemaEntry
    let onPlay: () -> Void
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
                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 620, alignment: .leading)
                }
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
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - 海报卡片

private struct CinemaPosterCard: View {
    let entry: CinemaEntry
    let hovered: Bool
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    @EnvironmentObject private var store: LibraryStore

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
                .frame(width: 156, height: 234)
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
                    HStack(spacing: 4) {
                        Spacer()
                        if !entry.matched {
                            Text("未识别")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.45), in: Capsule())
                        } else if let rating = entry.rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45), in: Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(7)
            }
            .frame(width: 156, height: 234)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: hovered ? 1.2 : 0.5)
            }
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .scaleEffect(hovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.16), value: hovered)
        }
        .frame(width: 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onOpen)
        .help(entry.file.filename)
        .contextMenu {
            Button("播放") { onOpen() }
            Button("重新刮削") {
                Task { await store.rescrapeCinema(entry) }
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
