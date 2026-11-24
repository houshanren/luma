import SwiftUI
import AppKit

/// 网络影院的排序：站点默认顺序之外的三种常用排序。
enum NetworkCinemaSort: String, CaseIterable, Identifiable {
    case recent
    case rating
    case year
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "默认排序"
        case .rating: return "TMDB 评分"
        case .year: return "年份"
        case .title: return "标题"
        }
    }

    var symbol: String {
        switch self {
        case .recent: return "clock.arrow.circlepath"
        case .rating: return "star.fill"
        case .year: return "calendar"
        case .title: return "textformat"
        }
    }
}

/// 工具栏中区的分页胶囊：影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注。
/// 与「网络资源」「网络存储」的工具栏分页同一套样式；页面内容区不再重复一条大胶囊。
struct NetworkCinemaHubTabs: View {
    @EnvironmentObject private var store: LibraryStore
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NetworkCinemaTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        // 工具栏变窄时宁可整体溢出，也不要把标签压成「…」。
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(_ tab: NetworkCinemaTab) -> some View {
        let active = store.networkCinemaTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                store.networkCinemaTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .fixedSize()
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "net-cinema-tab", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("网络影院 · \(tab.title)")
    }
}

/// 点开具体影视源后的工具栏中区：不再是聚合分页，只保留「退回全部影视源 + 当前源」。
struct NetworkCinemaFocusedSourceBar: View {
    @EnvironmentObject private var store: LibraryStore
    let source: CatalogSource

    var body: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    store.networkCinemaSourceID = nil
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("全部影视源")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回全部影视源")

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 0.6, height: 13)

            HStack(spacing: 5) {
                Circle()
                    .fill(source.kind.sidebarTint)
                    .frame(width: 5, height: 5)
                Text(source.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 0.6, height: 13)

            // 具体源里只保留电影 / 电视剧两种内容：与聚合页的分页同一位置，页面里不再写标题。
            HStack(spacing: 2) {
                modeButton(.movies)
                modeButton(.shows)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func modeButton(_ tab: NetworkCinemaTab) -> some View {
        let active = store.networkCinemaTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                store.networkCinemaTab = tab
            }
        } label: {
            Text(tab.title)
                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background {
                    if active {
                        Capsule(style: .continuous).fill(Color.accentColor)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("只看这个源的\(tab.title)")
    }
}

/// 详情页工具栏中区：只显示正在看的这部片，聚合分页与来源筛选都让位。
struct NetworkCinemaDetailTitleBar: View {
    let entry: NetworkCinemaItem

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: entry.isTV ? "tv" : "film")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(entry.item.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Text(entry.isTV ? "剧集" : "电影")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
            Text(entry.source.name)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 网络影院：把已启用的通用影视源聚合成一个浏览区。
///
/// 版式对齐「网络资源 / 网络存储」：影院管理、榜单、电影、电视剧、日历、足迹、关注七个分页，
/// 切换入口在窗口工具栏；电影与电视剧是信息更完整的海报墙，点开条目后原地进入影院式详情页。
struct NetworkCinemaHubView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var catalog: CatalogBrowserModel
    /// 由 `LibraryStore` 持有：切到别的页面，探测与资料补全继续在后台跑。
    @EnvironmentObject private var model: NetworkCinemaModel

    @State private var selectedGenre: String?
    @State private var sort: NetworkCinemaSort = .recent

    private var sources: [CatalogSource] {
        catalog.sources.filter { $0.isEnabled && $0.kind.supportsNetworkCinema }
    }

    /// 「榜单 / 日历 / 足迹」只统计影视源，不把「网络资源」里的其它站点混进来。
    private var scopeIDs: Set<UUID> {
        Set(catalog.sources.filter { $0.kind.supportsNetworkCinema }.map(\.id))
    }

    private var sourceFilterID: UUID? { store.networkCinemaSourceID }
    /// 点开某个源后，这一页只服务它：工具栏分页、来源筛选都让位给源内浏览。
    private var focusedSource: CatalogSource? {
        guard let id = sourceFilterID else { return nil }
        return sources.first { $0.id == id }
    }
    private var sourceIDs: String { sources.map(\.id.uuidString).joined(separator: ",") }
    /// 源内浏览只加载这一家；聚合页才拉全部源。
    private var activeSources: [CatalogSource] {
        focusedSource.map { [$0] } ?? catalog.sources
    }
    private var reloadKey: String {
        "\(store.networkCinemaTab.rawValue)|\(sourceIDs)|\(sourceFilterID?.uuidString ?? "-")"
    }

    private var availableGenres: [String] {
        model.genres(for: model.items)
    }

    private var visibleItems: [NetworkCinemaItem] {
        var list = model.items
        if let id = sourceFilterID {
            list = list.filter { $0.source.id == id }
        }
        if let genre = selectedGenre {
            list = list.filter { entry in
                model.enrichment(for: entry)?.genres.contains(genre) == true
            }
        }
        switch sort {
        case .recent:
            break
        case .rating:
            list.sort {
                (model.enrichment(for: $0)?.rating ?? 0) > (model.enrichment(for: $1)?.rating ?? 0)
            }
        case .year:
            list.sort {
                let lhs = model.enrichment(for: $0)?.year
                    ?? NetworkCinemaEnrichment.year(in: $0.item.title) ?? 0
                let rhs = model.enrichment(for: $1)?.year
                    ?? NetworkCinemaEnrichment.year(in: $1.item.title) ?? 0
                return lhs > rhs
            }
        case .title:
            list.sort {
                let lhs = model.enrichment(for: $0)?.title ?? $0.item.title
                let rhs = model.enrichment(for: $1)?.title ?? $1.item.title
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
        return list
    }

    private var activeFilterCount: Int {
        var count = 0
        if sourceFilterID != nil { count += 1 }
        if selectedGenre != nil { count += 1 }
        if sort != .recent { count += 1 }
        return count
    }

    var body: some View {
        Group {
            if let selected = store.networkCinemaDetail {
                // 返回收起详情由顶栏的返回胶囊统一负责（与网络资源详情同一位置）。
                NetworkCinemaDetailView(entry: selected, model: model)
                    .environmentObject(store)
            } else {
                pageContent
            }
        }
        .background(LumaAmbientBackground(intensity: 0.55))
        .task(id: reloadKey) {
            guard store.networkCinemaTab.browsesContent else { return }
            model.reload(sources: activeSources,
                         tab: store.networkCinemaTab,
                         tmdb: store.tmdbClient())
        }
        .onChange(of: store.networkCinemaTab) { _, tab in
            // 分页在工具栏切换：回到列表，别停在上一个分页留下的详情页。
            store.networkCinemaDetail = nil
            selectedGenre = nil
            if !tab.browsesContent {
                model.clearSearch()
            }
        }
        .onChange(of: store.networkCinemaSourceID) { _, _ in
            selectedGenre = nil
        }
        .onAppear {
            consumePendingItem()
            if let seed = store.networkCinemaSearchSeed {
                store.networkCinemaSearchSeed = nil
                store.searchText = seed
                store.searchScope = .global
            }
        }
        // 已经在网络影院里时，从影院推荐 / 演职员页再点「搜索」也要直接落到搜索态。
        .onChange(of: store.networkCinemaSearchSeed) { _, seed in
            guard let seed else { return }
            store.networkCinemaSearchSeed = nil
            store.networkCinemaDetail = nil
            store.searchText = seed
            store.searchScope = .global
        }
        .onChange(of: store.networkCinemaPendingItem?.id) { _, _ in
            consumePendingItem()
        }
        .onChange(of: sources.map(\.id)) { _, ids in
            if let id = store.networkCinemaSourceID, !ids.contains(id) {
                store.networkCinemaSourceID = nil
            }
        }
    }

    /// 七个分页的内容：管理 / 榜单 / 日历 / 足迹 / 关注读本机聚合数据，电影与电视剧走海报墙。
    @ViewBuilder
    private var pageContent: some View {
        if focusedSource != nil {
            // 点开具体源：只浏览这一家的内容，聚合分页留在「全部影视源」入口。
            browser
        } else {
            switch store.networkCinemaTab {
            case .manage:
                NetworkCinemaManageView()
            case .ranking:
                CatalogRankingView(sourceScope: scopeIDs, compact: true) { sourceID, item in
                    openInCinema(sourceID: sourceID, item: item)
                }
            case .calendar:
                CatalogCalendarView(sourceScope: scopeIDs, compact: true) { entry, source in
                    openInCinema(sourceID: source.id, item: entry.item)
                }
            case .history:
                CatalogHistoryView(sourceScope: scopeIDs, compact: true)
            case .following:
                NetworkCinemaFollowingView { entry in
                    withAnimation(.easeOut(duration: 0.16)) { store.networkCinemaDetail = entry }
                }
            case .movies, .shows:
                browser
            }
        }
    }

    /// 榜单 / 日历点开条目：按条目所属源进网络影院自己的详情页，而不是直接起播。
    private func openInCinema(sourceID: UUID, item: CatalogItem) {
        guard let source = catalog.sources.first(where: { $0.id == sourceID }) else { return }
        let entry = NetworkCinemaItem(source: source,
                                      item: item,
                                      isTV: NetworkCinemaModel.guessIsTV(item))
        withAnimation(.easeOut(duration: 0.16)) {
            store.networkCinemaDetail = entry
        }
    }

    /// 全局搜索点开条目：进来后直接停在这一部的详情页。
    private func consumePendingItem() {
        guard let pending = store.networkCinemaPendingItem else { return }
        store.networkCinemaPendingItem = nil
        store.networkCinemaDetail = pending
    }

    // MARK: - 浏览

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sources.isEmpty {
                    emptySourceState
                } else {
                    filterBar
                    statusLine
                    if model.isLoading && model.items.isEmpty {
                        loadingState("正在读取各影视源…")
                    } else if let error = model.error, visibleItems.isEmpty {
                        errorState(error)
                    } else if visibleItems.isEmpty {
                        emptyContentState
                    } else {
                        posterGrid
                        if model.canLoadMore || model.isLoadingMore {
                            loadMoreFooter
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentError: String? { model.error }

    private var refreshButton: some View {
        Button {
            // 主动刷新：跳过快照新鲜度判断，强制重拉当前范围内的影视源。
            model.reload(sources: activeSources,
                         tab: store.networkCinemaTab,
                         tmdb: store.tmdbClient(),
                         force: true)
        } label: {
            HStack(spacing: 5) {
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(model.isLoading ? "载入中" : "刷新")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isLoading)
        .help("重新聚合各影视源")
    }

    // MARK: 筛选

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                if sources.count > 1 && sourceFilterID == nil {
                    filterLabel("来源")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            NetworkCinemaFilterChip(title: "全部来源",
                                                    active: sourceFilterID == nil) {
                                store.networkCinemaSourceID = nil
                            }
                            ForEach(sources) { source in
                                NetworkCinemaFilterChip(title: source.name,
                                                        tint: source.kind.sidebarTint,
                                                        active: sourceFilterID == source.id) {
                                    store.networkCinemaSourceID = source.id
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                } else {
                    filterLabel("筛选")
                }
                Spacer(minLength: 8)
                Text("\(visibleItems.count) 部")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                refreshButton
                sortMenu
                if activeFilterCount > 0 {
                    Button("清除筛选") {
                        clearFilters()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            }

            if !availableGenres.isEmpty {
                HStack(spacing: 9) {
                    filterLabel("类型")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            NetworkCinemaFilterChip(title: "全部",
                                                    active: selectedGenre == nil) {
                                selectedGenre = nil
                            }
                            ForEach(availableGenres.prefix(14), id: \.self) { genre in
                                NetworkCinemaFilterChip(title: genre,
                                                        active: selectedGenre == genre) {
                                    selectedGenre = selectedGenre == genre ? nil : genre
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
    }

    private func filterLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 26, alignment: .leading)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(NetworkCinemaSort.allCases) { option in
                Button {
                    sort = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sort.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(sort.title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func clearFilters() {
        store.networkCinemaSourceID = nil
        selectedGenre = nil
        sort = .recent
    }

    // MARK: 状态

    @ViewBuilder
    private var statusLine: some View {
        if let progress = model.enrichmentProgress, progress.total > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在补全 TMDB 资料 \(progress.done)/\(progress.total)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else if let error = currentError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LumaBrand.coral)
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else if store.tmdbClient() == nil {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("未配置 TMDB API Key：卡片先用源站海报，评分与演职员暂不补全。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 海报墙

    private var posterGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 196), spacing: 16)],
                  alignment: .leading,
                  spacing: 22) {
            ForEach(visibleItems) { entry in
                NetworkCinemaCard(entry: entry,
                                  enrichment: model.enrichment(for: entry)) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        store.networkCinemaDetail = entry
                    }
                }
                .onAppear {
                    // 最后一张露头就补下一页：LazyVGrid 只在真正滚到时创建它。
                    guard entry.id == visibleItems.last?.id else { return }
                    loadMoreIfNeeded()
                }
            }
        }
    }

    /// 网格底部：加载中显示转圈，否则提示继续下滑。
    private var loadMoreFooter: some View {
        HStack(spacing: 7) {
            if model.isLoadingMore {
                ProgressView().controlSize(.mini)
                Text("正在加载更多…")
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text("继续下滑加载更多")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func loadMoreIfNeeded() {
        guard model.canLoadMore, !model.isLoadingMore else { return }
        model.loadMore(sources: activeSources,
                       tab: store.networkCinemaTab,
                       tmdb: store.tmdbClient())
    }

    private var emptySourceState: some View {
        VStack(spacing: 10) {
            Image(systemName: "popcorn")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("还没有影视源")
                .font(.system(size: 16, weight: .semibold))
            Text("导入 FongMi 配置、苹果CMS 接口，或 FoFo / 爱看片片 / 爱壹帆站点地址，电影与电视剧会聚合到这一页。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("导入影视源…") {
                store.presentCatalogWizard()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private var emptyContentState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("这个分页暂时没有内容")
                .font(.system(size: 15, weight: .semibold))
            Text("换个分页、清除筛选，或到「网络资源」里检查源是否返回了对应分类。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if activeFilterCount > 0 {
                Button("清除筛选") { clearFilters() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func loadingState(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LumaBrand.coral)
            Text("暂时读不到内容")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("重试") {
                model.reload(sources: activeSources,
                             tab: store.networkCinemaTab,
                             tmdb: store.tmdbClient(),
                             force: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - 筛选胶囊

private struct NetworkCinemaFilterChip: View {
    let title: String
    var tint: Color? = nil
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.secondary))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor,
                                                      Color.accentColor.opacity(0.72)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                                .blendMode(.plusLighter)
                        }
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 2)
                } else {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0 : 0.08), lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - 海报卡

private struct NetworkCinemaCard: View {
    let entry: NetworkCinemaItem
    let enrichment: NetworkCinemaEnrichment?
    let onOpen: () -> Void

    @State private var hovering = false

    private var title: String { enrichment?.title ?? entry.item.title }
    private var year: Int? {
        enrichment?.year ?? NetworkCinemaEnrichment.year(in: entry.item.title)
    }
    private var genres: [String] { Array((enrichment?.genres ?? []).prefix(2)) }
    private var isTV: Bool { enrichment?.isTV ?? entry.isTV }
    private var rating: Double? { enrichment?.rating }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay { posterContent }
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.28 : 0.11),
                            radius: hovering ? 14 : 7,
                            y: hovering ? 7 : 3)
                    .scaleEffect(hovering ? 1.02 : 1)

                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    if let year {
                        Text(String(year))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !genres.isEmpty {
                        Text(genres.joined(separator: " · "))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.source.kind.sidebarTint)
                        .frame(width: 5, height: 5)
                    Text(entry.source.name)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .help(helpText)
    }

    private var posterContent: some View {
        ZStack {
            artwork
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.74)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    if let rating, rating > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7.5, weight: .bold))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(LumaBrand.amber, in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Text(isTV ? "剧集" : "电影")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.16), in: Capsule())
                    if let remark = entry.item.episodeBadge {
                        Text(remark)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.90))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
            .allowsHitTesting(false)

            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let poster = enrichment?.posterURL, !poster.isEmpty {
            CinemaArtwork(urlString: poster, maxPixelSize: 700)
        } else if !entry.item.coverURL.isEmpty {
            CatalogArtworkImage(source: entry.source,
                                urlString: entry.item.coverURL,
                                cornerRadius: 13)
        } else {
            LinearGradient(colors: [Color.primary.opacity(0.12), Color.primary.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var helpText: String {
        if let overview = enrichment?.overview, !overview.isEmpty { return overview }
        return "\(title) · \(entry.source.name)"
    }
}
