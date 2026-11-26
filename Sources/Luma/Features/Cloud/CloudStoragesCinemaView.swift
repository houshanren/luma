import SwiftUI
import AppKit
import Foundation
import LumaContentCore

/// 网盘影院、续播与网盘管理页。

// MARK: - 影院页

/// 影院页：把所有网盘的刮削结果汇成一面真实海报墙。
/// 先看「最近刮削」与「接着看」，再按电影 / 剧集浏览；点海报直接开播，底部保留每个存储的刮削入口。
struct CloudStoragesCinemaView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CloudBrowserModel.self) private var cloud

    /// 控制台状态：与图2 一致的「来源 → 分段 → 姿态 → 筛选 / 排序」结构。
    @State private var selectedMountID: UUID?
    @State private var tab: CinemaTab = .all
    @State private var viewMode: CinemaViewMode = .shelf
    @State private var filter: CinemaWallFilter = .all
    @State private var sortOrder: CinemaWallSort = .recent
    @State private var query = ""
    /// 聚合页里的详情：与本地 / 网盘影院同一套内联详情页，点海报先进详情再播放。
    @State private var detailTarget: CinemaDetailTarget?

    var body: some View {
        let wall = buildWall()
        let items = filteredItems(wall)

        return ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    console(wall)

                    if cloud.mounts.isEmpty {
                        LumaEmptyState(symbol: "film.stack",
                                       title: "还没有存储影院",
                                       message: "接入网络存储并打开影院后，视频会被识别成电影与剧集，汇总到这里。",
                                       style: .card,
                                       actions: [LumaEmptyAction(title: "接入存储",
                                                                 symbol: "plus") {
                                           store.presentCloudWizard()
                                       }])
                    } else {
                        if viewMode == .shelf {
                            shelfContent(wall, items: items)
                        } else if items.isEmpty {
                            noMatchState
                        } else {
                            wallTitle(items)
                            switch viewMode {
                            case .wall:
                                posterWall(items)
                            case .card:
                                wideCardWall(items)
                            case .list:
                                itemList(items)
                            case .shelf:
                                EmptyView()
                            }
                        }

                        if viewMode == .shelf {
                            mountSection(filteredMounts(wall))
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let target = detailTarget {
                inlineDetail(target)
                    .overlay(alignment: .topLeading) {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil }
                            store.cinemaDetailOpen = false
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .bold))
                                Text("返回聚合影院")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                            }
                            .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .padding(18)
                        .help("返回聚合影院 (Esc)")
                    }
                    .onDisappear { store.cinemaDetailOpen = false }
            }
        }
    }

    /// 内联详情：复用本地影院的详情组件，返回后仍停在聚合页原来的位置。
    @ViewBuilder
    private func inlineDetail(_ target: CinemaDetailTarget) -> some View {
        switch target {
        case .series(let series):
            CinemaSeriesDetailView(
                series: series,
                onPlay: { entry in store.openCinema(entry) },
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environment(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        case .entry(let entry):
            CinemaDetailView(
                entry: entry,
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environment(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        default:
            EmptyView()
        }
    }

    // MARK: - 控制台

    private func console(_ wall: CloudCinemaWall) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    mountMenu(wall)
                    Divider().frame(height: 22)
                    categoryTabs
                    Divider().frame(height: 22)
                    viewModeTabs
                    Divider().frame(height: 22)
                    filterMenu
                    sortMenu
                    searchField
                    Spacer(minLength: 4)
                    scrapeMenu
                    moreMenu(wall)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .scrollClipDisabled()

            Divider().opacity(0.45).padding(.horizontal, 12)

            compactStats(wall)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.07),
                                              Color.primary.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.14),
                                                      .clear,
                                                      .black.opacity(0.12)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: 0.9)
        }
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    /// 读数整合进同一条控制台：切换来源 / 分段时，下面的数字同步变。
    private func compactStats(_ wall: CloudCinemaWall) -> some View {
        let stats = statsScope(wall)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                statCell("已识别", "\(stats.matched)", "部",
                         symbol: "checkmark.seal.fill", tint: LumaBrand.mint)
                cellDivider
                statCell("电影", "\(stats.movies)", "部",
                         symbol: "film.fill", tint: LumaBrand.violet)
                cellDivider
                statCell("剧集", "\(stats.series)", "部",
                         symbol: "tv.fill", tint: LumaBrand.cyan)
                cellDivider
                statCell("待识别", "\(stats.unmatched)", "项",
                         symbol: "questionmark.circle.fill", tint: LumaBrand.amber)
                cellDivider
                statCell("续看", "\(stats.continueCount)", "条",
                         symbol: "play.circle.fill", tint: LumaBrand.coral)
                Spacer(minLength: 0)
            }
        }
        .scrollClipDisabled()
    }

    private func statCell(_ title: String, _ value: String, _ unit: String,
                          symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.6, height: 13)
    }

    private func statsScope(_ wall: CloudCinemaWall) -> (matched: Int, movies: Int, series: Int,
                                                         unmatched: Int, continueCount: Int) {
        if let id = selectedMountID,
           let item = wall.mounts.first(where: { $0.mount.id == id }) {
            return (item.summary.matched,
                    item.summary.movies,
                    item.summary.shows,
                    item.summary.unmatched,
                    wall.continueRecords.filter { $0.mountID == id }.count)
        }
        return (wall.movies.count + wall.series.count,
                wall.movies.count,
                wall.series.count,
                wall.unmatched,
                wall.continueRecords.count)
    }

    private func mountMenu(_ wall: CloudCinemaWall) -> some View {
        Menu {
            Button {
                selectedMountID = nil
            } label: {
                Label("全部存储", systemImage: selectedMountID == nil ? "checkmark" : "externaldrive.connected.to.line.below")
            }
            Divider()
            ForEach(wall.mounts) { item in
                Button {
                    selectedMountID = item.mount.id
                } label: {
                    Label("\(item.mount.name) · \(item.summary.matched) 已识别",
                          systemImage: selectedMountID == item.mount.id ? "checkmark" : "externaldrive")
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumaBrand.violet)
                VStack(alignment: .leading, spacing: 0) {
                    Text("影院")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(selectedMountName(wall))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text("\(matchedCount(wall)) 已识别")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择影院来源")
    }

    private var categoryTabs: some View {
        HStack(spacing: 2) {
            ForEach([CinemaTab.all, .movies, .shows]) { item in
                let active = tab == item
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { tab = item }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background {
                        if active {
                            Capsule(style: .continuous).fill(Color.accentColor)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button {
                browseFolders()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .semibold))
                    Text("文件夹")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("到存储里按文件夹浏览")
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var viewModeTabs: some View {
        HStack(spacing: 2) {
            ForEach(CinemaViewMode.allCases) { mode in
                let active = viewMode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { viewMode = mode }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var filterMenu: some View {
        Menu {
            ForEach(CinemaWallFilter.allCases) { option in
                Button {
                    filter = option
                } label: {
                    Label(option.title, systemImage: filter == option ? "checkmark" : option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(filter == .all ? "筛选" : filter.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(filter == .all ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CinemaWallSort.allCases) { option in
                Button {
                    sortOrder = option
                } label: {
                    Label(option.title, systemImage: sortOrder == option ? "checkmark" : option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(sortOrder.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索片名 / 存储", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit {
                    store.startModuleSearch(.cinema, query: query)
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 176, height: 26)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private var scrapeMenu: some View {
        Menu {
            if let id = selectedMountID, let mount = cloud.mounts.first(where: { $0.id == id }) {
                Button("刮削「\(mount.name)」") { store.startCinemaScrape(for: .mount(id)) }
                Button("强制重新刮削「\(mount.name)」") {
                    store.startCinemaScrape(for: .mount(id), force: true)
                }
            } else {
                ForEach(cloud.mounts) { mount in
                    Button("刮削「\(mount.name)」") {
                        store.startCinemaScrape(for: .mount(mount.id))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if store.cinemaScrapeRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(store.cinemaScrapeRunning
                     ? "\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)"
                     : "刮削")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(LumaBrand.amber)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(LumaBrand.amber.opacity(0.12), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.30), lineWidth: 0.7)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.cinemaScrapeRunning)
        .help("识别电影与剧集")
    }

    private func moreMenu(_ wall: CloudCinemaWall) -> some View {
        Menu {
            if let id = selectedMountID {
                Button("进入「\(selectedMountName(wall))」影院") { enterCinema(mountID: id) }
                Button("在存储中打开") { browseFolders() }
                Divider()
                Button("回到全部存储") { selectedMountID = nil }
            } else {
                Button("按文件夹浏览存储") {
                    cloud.setStoragesTab(.storages)
                }
            }
            Button("网络存储管理") { cloud.setStoragesTab(.storages) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 聚合内容

    /// 书架：最近刮削 + 接着看 + 电影 / 剧集两组海报。
    @ViewBuilder
    private func shelfContent(_ wall: CloudCinemaWall, items: [CloudCinemaWallItem]) -> some View {
        let spotlight = items.filter { $0.backdropURL != nil }.max { $0.date < $1.date } ?? items.first
        if let spotlight {
            spotlightCard(spotlight)
        }

        let records = filteredContinue(wall)
        if !records.isEmpty {
            continueShelf(records)
        }

        if items.isEmpty {
            if wall.movies.isEmpty && wall.series.isEmpty {
                scrapeHint
            } else {
                noMatchState
            }
        } else {
            let movies = items.filter { $0.series == nil }
            let series = items.filter { $0.series != nil }
            if !movies.isEmpty {
                posterSection(title: "电影", symbol: "film.fill",
                              tint: LumaBrand.violet, items: movies)
            }
            if !series.isEmpty {
                posterSection(title: "剧集", symbol: "tv.fill",
                              tint: LumaBrand.cyan, items: series)
            }
        }
    }

    private func wallTitle(_ items: [CloudCinemaWallItem]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "film.stack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.violet)
            Text(tab == .movies ? "电影" : (tab == .shows ? "剧集" : "全部影片"))
                .font(.system(size: 14, weight: .semibold))
            Text("\(items.count) 部")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// 海报墙：只留竖版海报，密度交给自适应列宽。
    private func posterWall(_ items: [CloudCinemaWallItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 106, maximum: 132), spacing: 14)],
                  alignment: .leading,
                  spacing: 16) {
            ForEach(items) { item in
                CloudCinemaPosterCard(item: item) { openDetail(item) }
                    .contextMenu {
                        Button("查看详情") { openDetail(item) }
                        Button("播放") { open(item) }
                        Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
                    }
            }
        }
    }

    /// 卡片：16:9 横版，适合快速扫一眼剧情封面。
    private func wideCardWall(_ items: [CloudCinemaWallItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)],
                  alignment: .leading,
                  spacing: 14) {
            ForEach(items) { item in
                wideCard(item)
            }
        }
    }

    private func wideCard(_ item: CloudCinemaWallItem) -> some View {
        Button { openDetail(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                CloudHubArtwork(urlString: item.artworkURL, cornerRadius: 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 136)
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 7.5, weight: .semibold))
                            Text(item.mountName)
                                .font(.system(size: 8.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.35), in: Capsule(style: .continuous))
                        .padding(8)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(item.detail)
                        Text(CloudHubFormat.relative(item.date))
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看「\(item.title)」详情")
        .contextMenu {
            Button("查看详情") { openDetail(item) }
            Button("播放") { open(item) }
            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
        }
    }

    /// 列表：一行一部，扫描时信息最密。
    private func itemList(_ items: [CloudCinemaWallItem]) -> some View {
        CloudHubPanel(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                itemRow(items[index])
                if index < items.count - 1 {
                    Divider().opacity(0.35).padding(.leading, 64)
                }
            }
        }
    }

    private func itemRow(_ item: CloudCinemaWallItem) -> some View {
        Button { openDetail(item) } label: {
            HStack(spacing: 11) {
                CloudHubArtwork(urlString: item.artworkURL, cornerRadius: 6)
                    .frame(width: 56, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(item.detail) · \(item.mountName)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(CloudHubFormat.relative(item.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(LumaBrand.amber.opacity(0.92)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看「\(item.title)」详情")
    }

    private var noMatchState: some View {
        LumaEmptyState(symbol: "line.3.horizontal.decrease.circle",
                       title: "没有匹配的影片",
                       message: "换一个存储、分段或关键词试试。")
    }

    // MARK: - 控制台数据

    private func filteredItems(_ wall: CloudCinemaWall) -> [CloudCinemaWallItem] {
        var result: [CloudCinemaWallItem]
        switch tab {
        case .movies: result = wall.movies
        case .shows: result = wall.series
        default: result = wall.movies + wall.series
        }
        if let id = selectedMountID {
            result = result.filter { $0.mountID == id }
        }
        switch filter {
        case .all:
            break
        case .artwork:
            result = result.filter { $0.artworkURL != nil }
        case .recent:
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            result = result.filter { $0.date > cutoff }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.mountName.localizedCaseInsensitiveContains(keyword)
            }
        }
        switch sortOrder {
        case .recent: result.sort { $0.date > $1.date }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year: result.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        }
        return result
    }

    private func filteredContinue(_ wall: CloudCinemaWall) -> [CinemaProgressRecord] {
        guard let id = selectedMountID else { return wall.continueRecords }
        return wall.continueRecords.filter { $0.mountID == id }
    }

    private func filteredMounts(_ wall: CloudCinemaWall) -> [CloudMountCinemaItem] {
        guard let id = selectedMountID else { return wall.mounts }
        return wall.mounts.filter { $0.mount.id == id }
    }

    private func selectedMountName(_ wall: CloudCinemaWall) -> String {
        guard let id = selectedMountID,
              let item = wall.mounts.first(where: { $0.mount.id == id }) else { return "全部存储" }
        return item.mount.name
    }

    private func matchedCount(_ wall: CloudCinemaWall) -> Int {
        if let id = selectedMountID {
            return wall.mounts.first { $0.mount.id == id }?.summary.matched ?? 0
        }
        return wall.movies.count + wall.series.count
    }

    /// 「文件夹」分段：回到存储本身按目录浏览。
    private func browseFolders() {
        if let id = selectedMountID {
            store.navigate(to: .cloudMount(id))
        } else {
            cloud.setStoragesTab(.storages)
        }
    }

    // MARK: 最近刮削

    func spotlightCard(_ item: CloudCinemaWallItem) -> some View {
        Button { openDetail(item) } label: {
            ZStack(alignment: .bottomLeading) {
                CloudHubArtwork(urlString: item.backdropURL ?? item.artworkURL, cornerRadius: 20)
                    .frame(maxWidth: .infinity)
                    .frame(height: 232)

                LinearGradient(colors: [.black.opacity(0.02),
                                        .black.opacity(0.34),
                                        .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("最近刮削")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(.white.opacity(0.18), in: Capsule(style: .continuous))
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text(item.mountName)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.78))
                    }
                    Text(item.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("查看详情")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 13)
                        .frame(height: 27)
                        .background(.white.opacity(0.95), in: Capsule(style: .continuous))

                        Text("刮削于 \(CloudHubFormat.relative(item.date))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .padding(.top, 2)
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 232)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .help("查看「\(item.title)」详情")
        .contextMenu {
            Button("查看详情") { openDetail(item) }
            Button("播放") { open(item) }
            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
        }
    }

    // MARK: 接着看

    func continueShelf(_ records: [CinemaProgressRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("接着看", count: records.count, unit: "条",
                         symbol: "play.circle.fill", tint: LumaBrand.coral)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(records.prefix(12))) { record in
                        CloudCinemaContinueCard(record: record,
                                                mountName: mountName(for: record)) {
                            resume(record)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 海报墙

    func posterSection(title: String,
                               symbol: String,
                               tint: Color,
                               items: [CloudCinemaWallItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, count: items.count, unit: "部", symbol: symbol, tint: tint)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 106, maximum: 132), spacing: 14)],
                      alignment: .leading,
                      spacing: 16) {
                ForEach(items) { item in
                    CloudCinemaPosterCard(item: item) { openDetail(item) }
                        .contextMenu {
                            Button("查看详情") { openDetail(item) }
                            Button("播放") { open(item) }
                            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
                        }
                }
            }
        }
    }

    var scrapeHint: some View {
        CloudHubPanel {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LumaBrand.amber.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有刮削出海报")
                        .font(.system(size: 12, weight: .semibold))
                    Text("在下面的存储行里点「刮削」，识别出的电影与剧集会出现在这面墙上。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
        }
    }

    // MARK: 按存储

    func mountSection(_ items: [CloudMountCinemaItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("按存储", count: items.count, unit: "个",
                         symbol: "externaldrive.fill", tint: LumaBrand.amber)
            CloudHubPanel(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    mountRow(items[index])
                    if index < items.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 56)
                    }
                }
            }
        }
    }

    func mountRow(_ item: CloudMountCinemaItem) -> some View {
        let scope = CinemaScope.mount(item.mount.id)
        let scraping = store.cinemaScrapeRunning && store.cinemaScrapeScope == scope
        let tint = item.mount.kind.hubTint
        let continueCount = store.cinemaContinueRecords(for: scope).count
        let connection = connectionSummary(item.mount)
        let scanText = scanSummary(item.mount)

        return HStack(spacing: 12) {
            CloudMountBadge(mount: item.mount, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.mount.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    CloudHubTag(text: item.summary.matched > 0 ? "已识别 \(item.summary.matched)" : "未刮削",
                                tint: item.summary.matched > 0 ? LumaBrand.mint : Color.secondary)
                }
                HStack(spacing: 10) {
                    Text("电影 \(item.summary.movies)")
                    Text("剧集 \(item.summary.shows)")
                    Text("续看 \(continueCount)")
                    if let scraped = item.summary.lastScrapedAt {
                        Text("刮削于 \(CloudHubFormat.relative(scraped))")
                    }
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                // 每个源都有一行汇总：连接状态 + 上次扫描时间，不用点进详情。
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(connection.tint)
                            .frame(width: 5, height: 5)
                        Text(connection.text)
                    }
                    Text("上次扫描 \(scanText)")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 10)

            if scraping {
                ProgressView().controlSize(.mini)
                Text("\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            CloudHubCapsuleButton(title: "刮削", symbol: "wand.and.stars", tint: tint) {
                store.startCinemaScrape(for: scope)
            }
            CloudHubCapsuleButton(title: "进入影院", symbol: "arrow.up.right",
                                  tint: tint, prominent: true) {
                enterCinema(mountID: item.mount.id)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 最近一次连接检测的结果：没有检测记录时标「未检测」。
    func connectionSummary(_ mount: CloudMount) -> (text: String, tint: Color) {
        let job = store.recentSourceJobs(kind: .connectivity).first {
            $0.sourceID.uuidValue == mount.id
        }
        guard let job else { return ("未检测", .secondary) }
        if job.phase == .finished {
            return ("在线 · \(CloudHubFormat.relative(job.updatedAt))", LumaBrand.mint)
        }
        return ("离线 · \(CloudHubFormat.relative(job.updatedAt))", LumaBrand.coral)
    }

    /// 上次完整扫描时间：深度扫描时间优先，其次刮削时间，都没有就提示未扫描。
    func scanSummary(_ mount: CloudMount) -> String {
        if let date = store.cloudDeepScanDate(mount.id) {
            return CloudHubFormat.relative(date)
        }
        if let states = store.cloudIndexStates()[mount.id] {
            return CloudHubFormat.relative(states.updatedAt)
        }
        return "未扫描"
    }

    func sectionTitle(_ title: String,
                              count: Int,
                              unit: String,
                              symbol: String,
                              tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text("\(count) \(unit)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: 数据

    func buildWall() -> CloudCinemaWall {
        var wall = CloudCinemaWall()
        wall.continueRecords = store.cloudMountContinueRecords

        for mount in cloud.mounts {
            let entries = Array(store.cinemaEntries(for: .mount(mount.id)).values)
            let summary = CloudCinemaSummary(entries: entries)
            wall.mounts.append(CloudMountCinemaItem(mount: mount, summary: summary))
            wall.unmatched += summary.unmatched

            for entry in entries where entry.matched && entry.kind == .movie {
                wall.movies.append(CloudCinemaWallItem(
                    id: "movie-\(mount.id)-\(entry.id)",
                    mountID: mount.id,
                    mountName: mount.name,
                    title: entry.title,
                    detail: movieDetail(entry),
                    artworkURL: entry.posterURL ?? entry.backdropURL,
                    backdropURL: entry.backdropURL,
                    date: entry.scrapedAt,
                    entry: entry,
                    series: nil))
            }

            for series in store.cinemaSeries(for: .mount(mount.id)) {
                wall.series.append(CloudCinemaWallItem(
                    id: "series-\(mount.id)-\(series.id)",
                    mountID: mount.id,
                    mountName: mount.name,
                    title: series.title,
                    detail: series.subtitle,
                    artworkURL: series.posterURL ?? series.backdropURL,
                    backdropURL: series.backdropURL,
                    date: series.latestEpisode?.scrapedAt ?? .distantPast,
                    entry: nil,
                    series: series))
            }
        }

        wall.movies.sort { $0.date > $1.date }
        wall.series.sort { $0.date > $1.date }

        let all = wall.movies + wall.series
        wall.spotlight = all.filter { $0.backdropURL != nil }.max { $0.date < $1.date }
            ?? all.max { $0.date < $1.date }
        return wall
    }

    func movieDetail(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        parts.append("电影")
        if let runtime = entry.runtime, runtime > 0 { parts.append("\(runtime) 分钟") }
        return parts.joined(separator: " · ")
    }

    /// 点海报 / 卡片：先进入该条目所属存储的影院作用域，再打开同一套内联详情。
    func openDetail(_ item: CloudCinemaWallItem) {
        store.activateCinemaScope(.mount(item.mountID))
        store.cinemaDetailOpen = true
        withAnimation(.easeOut(duration: 0.2)) {
            if let series = item.series {
                detailTarget = .series(series)
            } else if let entry = item.entry {
                detailTarget = .entry(entry)
            }
        }
    }

    func open(_ item: CloudCinemaWallItem) {
        store.activateCinemaScope(.mount(item.mountID))
        if let entry = item.entry {
            store.openCinema(entry)
            return
        }
        guard let series = item.series else { return }
        // 有进度就看那一集，否则从第一集开始。
        let watched = Set(store.cloudMountContinueRecords.map(\.photoID))
        if let resume = series.episodes.first(where: { watched.contains($0.file.photoID) }) {
            store.openCinema(resume)
        } else if let first = series.episodes.first {
            store.openCinema(first)
        }
    }

    func resume(_ record: CinemaProgressRecord) {
        guard let mountID = record.mountID else { return }
        store.activateCinemaScope(.mount(mountID))
        if let entry = store.cinemaIndexes[.mount(mountID)]?[record.photoID] {
            store.openCinema(entry)
        } else {
            store.navigate(to: .cloudCinema(mountID))
        }
    }

    func enterCinema(mountID: UUID) {
        store.activateCinemaScope(.mount(mountID))
        store.navigate(to: .cloudCinema(mountID))
    }

    func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return cloud.mounts.first { $0.id == mountID }?.name ?? "网络存储"
    }
}
