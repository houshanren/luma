import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

// MARK: - 关闭态
struct TVDisabledView: View {
    @Environment(IPTVBrowserModel.self) private var tv

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("网络电视已关闭")
                .font(.system(size: 14, weight: .semibold))
            Text("开启后不会自动接入任何源：可以粘贴自己的 M3U 地址，或导入本地播放列表与拾光分享包。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("开启网络电视") { tv.setEnabled(true) }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - 频道

struct TVChannelsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv

    /// 海报墙负责浏览，列表负责扫台与数字键跳转；两种密度共用同一份筛选结果。
    private enum Density: String, CaseIterable, Identifiable {
        case wall, list
        var id: String { rawValue }
        var title: String { self == .wall ? "海报墙" : "列表" }
        var symbol: String { self == .wall ? "square.grid.2x2" : "list.bullet" }
    }

    @AppStorage("luma.tv.channelDensity") private var densityRaw = Density.wall.rawValue
    private var density: Density {
        get { Density(rawValue: densityRaw) ?? .wall }
        nonmutating set { densityRaw = newValue.rawValue }
    }

    @State private var showMultiview = false
    @State private var showSubscriptions = false
    @State private var collapsedGroups: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            content
        }
        .sheet(isPresented: $showMultiview) {
            TVMultiviewSheet()
                .environment(store)
                .environment(tv)
        }
        .sheet(isPresented: $showSubscriptions) {
            TVSubscriptionsSheet()
                .environment(store)
                .environment(tv)
        }
        .onChange(of: tv.focusedPlaylistID) { _, _ in
            // 侧边栏已经指定了源时，页内的源筛选没有意义，清掉避免「两个源」互相打架。
            tv.channelSourceFilterID = nil
        }
    }

    /// 页内源筛选后的分区：保留原来的分组与排序，只把别的源剔掉。
    private var sourceSections: [(group: String, channels: [TVChannel])] {
        guard let sourceFilterID = tv.channelSourceFilterID else { return tv.groupedChannels }
        return tv.groupedChannels.compactMap { section in
            let list = section.channels.filter { $0.playlistID == sourceFilterID }
            return list.isEmpty ? nil : (group: section.group, channels: list)
        }
    }

    /// 频道墙只摆能播的直播源：所有线路都试过仍抓不到画面的频道先隐藏，
    /// 顶部显示失效数量，网络恢复后一键重试。
    private var sections: [(group: String, channels: [TVChannel])] {
        sourceSections.compactMap { section in
            let list = section.channels.filter { tv.probeState(for: $0.id) != .unavailable }
            return list.isEmpty ? nil : (group: section.group, channels: list)
        }
    }

    /// 全频直播下按源筛选：菜单里列出每个源与频道数，选中后这一页只看该源。
    private var sourceFilterMenu: some View {
        let active = tv.channelSourceFilterID != nil
        return Menu {
            Button {
                tv.channelSourceFilterID = nil
            } label: {
                if tv.channelSourceFilterID == nil {
                    Label("全部源", systemImage: "checkmark")
                } else {
                    Text("全部源")
                }
            }
            Divider()
            ForEach(tv.playlists) { playlist in
                let count = tv.channels.filter { $0.playlistID == playlist.id }.count
                Button {
                    tv.channelSourceFilterID = playlist.id
                } label: {
                    let title = "\(shortSourceName(playlist.name)) · \(count)"
                    if tv.channelSourceFilterID == playlist.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                .disabled(count == 0)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 9, weight: .semibold))
                Text(sourceFilterLabel)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? TVBrand.gold : TVBrand.panel)
            }
            .overlay(Capsule(style: .continuous)
                .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("按源筛选频道")
    }

    private var sourceFilterLabel: String {
        guard let sourceFilterID = tv.channelSourceFilterID,
              let playlist = tv.playlists.first(where: { $0.id == sourceFilterID })
        else { return "全部源" }
        return shortSourceName(playlist.name)
    }

    /// 源名通常写成「我的 IPTV · 国内频道（直连）」：胶囊里只留前半段。
    private func shortSourceName(_ name: String) -> String {
        name.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(currentSourceName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                // 三种分组方式在全部源与单个源里都能用，入口始终可见。
                groupingSwitch
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        quickChip(.favorites)
                        quickChip(.recent)
                        if tv.focusedPlaylistID == nil {
                            Rectangle()
                                .fill(TVBrand.hairline)
                                .frame(width: 1, height: 16)
                                .padding(.horizontal, 2)
                            sourceFilterMenu
                        }
                        Rectangle()
                            .fill(TVBrand.hairline)
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 2)
                        filterChip(nil)
                        ForEach(tv.filterOptions, id: \.self) { option in
                            filterChip(option)
                        }
                    }
                    .padding(.vertical, 1)
                }
                Spacer(minLength: 0)
                headerActions
                densitySwitch
            }

            if let message = tv.error, !message.isEmpty, !tv.channels.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(TVBrand.warning)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// 追剧 / 多画面 / 刷新：从前一行的标题区挪下来，和筛选放在同一行。
    private var headerActions: some View {
        HStack(spacing: 6) {
            compactAction("追剧",
                          systemImage: "bookmark.fill",
                          badge: tv.subscriptions.isEmpty ? nil : tv.subscriptions.count) {
                showSubscriptions = true
            }
            .help("我的追剧：订阅节目，未来 7 天自动提醒")

            compactAction("多画面", systemImage: "square.grid.2x2") {
                showMultiview = true
            }
            .help("2×2 同时看四个频道，声音只跟一个")

            compactAction("刷新", systemImage: "arrow.clockwise") {
                tv.refresh()
            }
            .disabled(tv.isLoading)
            .help("重新拉取当前电视源")
        }
    }

    private func compactAction(_ title: String,
                               systemImage: String,
                               badge: Int? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(TVBrand.gold.opacity(0.16), in: Capsule())
                }
            }
            .foregroundStyle(.primary.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private func quickChip(_ filter: TVQuickFilter) -> some View {
        let active = tv.quickFilter == filter
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                tv.quickFilter = active ? nil : filter
                if !active {
                    tv.groupFilter = nil
                    tv.provinceFilter = nil
                    tv.countryFilter = nil
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(filter.title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? TVBrand.gold : TVBrand.panel)
            }
            .overlay(Capsule(style: .continuous)
                .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help(filter == .favorites ? "只看收藏的频道" : "只看最近看过的频道")
    }

    private func filterChip(_ option: String?) -> some View {
        let mode = tv.effectiveGroupingMode
        let active: Bool
        switch mode {
        case .province:
            active = tv.quickFilter == nil && tv.provinceFilter == option
        case .country:
            active = tv.quickFilter == nil && tv.countryFilter == option
        case .category:
            active = tv.quickFilter == nil && tv.groupFilter == option
        }
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                tv.quickFilter = nil
                switch mode {
                case .province:
                    tv.provinceFilter = option
                case .country:
                    tv.countryFilter = option
                case .category:
                    tv.groupFilter = option
                }
            }
        } label: {
            Text(option ?? "全部")
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? TVBrand.onWave : Color.secondary)
                .padding(.horizontal, 11)
                .frame(height: 25)
                .background {
                    Capsule(style: .continuous)
                        .fill(active ? TVBrand.wave : TVBrand.panel)
                }
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    /// 「按类型 / 按省份 / 按国家」切换：省份模式把地方台按省份聚合成一节，
    /// 国家模式把频道按国家 / 地区聚合成一节。
    private var groupingSwitch: some View {
        HStack(spacing: 2) {
            ForEach(TVGroupingMode.allCases) { mode in
                let active = tv.groupingMode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        tv.setGroupingMode(mode)
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 23)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(TVBrand.gold)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(mode == .province ? "把地方台按省份聚合"
                      : (mode == .country ? "把频道按国家 / 地区聚合" : "按新闻 / 体育等类型分组"))
            }
        }
        .padding(2)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        .fixedSize()
    }

    private var densitySwitch: some View {
        HStack(spacing: 2) {
            ForEach(Density.allCases) { item in
                let active = density == item
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { density = item }
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(active ? TVBrand.onWave : Color.secondary)
                        .frame(width: 24, height: 23)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(TVBrand.wave)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(2)
        .background(TVBrand.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        // 分区过滤要扫全部频道：一次 body 求值里只算一次，下面分支复用同一份结果。
        let groups = sections
        if tv.isLoading, tv.channels.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在拉取各地区频道…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tv.channels.isEmpty, let sourceError = tv.sourceError {
            VStack(spacing: 12) {
                SourceErrorView(error: sourceError) { action in
                    if action == .retry { tv.refresh() }
                }
                .frame(maxWidth: 460)
                Button("重新拉取") { tv.refresh() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if tv.visibleChannels.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            Text(sourceSections.isEmpty
                 ? "这个源在当前筛选下没有频道"
                 : "当前频道全部失效，已从频道墙隐藏。检查网络 / 代理后点顶部「重试」。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if density == .list {
            channelList(groups: groups)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(groups, id: \.group) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                sectionHeader(section)
                                if !collapsedGroups.contains(section.group) { LazyVGrid(columns: columns, spacing: 14) {
                                    ForEach(section.channels) { channel in
                                        TVChannelTile(store: store,
                                                      tv: tv,
                                                      channel: channel,
                                                      number: tv.channelNumber(for: channel),
                                                      isPlaying: playingChannelID == channel.id)
                                            .equatable()
                                    }
                                } }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                    // 滚动锚点挂在容器上：不再用零高度占位视图，顶部就不会多出一段空白。
                    .id("tv-top")
                }
                // 换源时重建滚动视图：上一个源很可能滚到很深处，只剩偏移量会显示空白。
                .id(tv.focusedPlaylistID?.uuidString ?? "tv-all")
                // 换分组 / 换省份 / 换国家 / 换分组方式 / 搜索时回到顶部，避免沿用之前的位置。
                .onChange(of: tv.groupFilter) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.provinceFilter) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.countryFilter) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.groupingMode) { _, _ in scrollToTop(proxy) }
                .onChange(of: tv.searchText) { _, _ in scrollToTop(proxy) }
            }
        }
    }

    /// 列表密度：14–18 行/屏，固定列用于快速扫台；不显示渐变与阴影，保证长列表滚动。
    private func channelList(groups: [(group: String, channels: [TVChannel])]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            sectionHeader(section)
                            if !collapsedGroups.contains(section.group) { VStack(spacing: 1) {
                                ForEach(section.channels) { channel in
                                    TVChannelRow(channel: channel,
                                                 number: tv.channelNumber(for: channel),
                                                 isPlaying: playingChannelID == channel.id) {
                                        store.openTVChannel(channel)
                                    }
                                }
                            } }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .id("tv-top")
            }
            .id(tv.focusedPlaylistID?.uuidString ?? "tv-all")
            .onChange(of: tv.groupFilter) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.provinceFilter) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.countryFilter) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.groupingMode) { _, _ in scrollToTop(proxy) }
            .onChange(of: tv.searchText) { _, _ in scrollToTop(proxy) }
        }
    }

    private func sectionHeader(_ section: (group: String, channels: [TVChannel])) -> some View {
        let collapsed = collapsedGroups.contains(section.group)
        return Button {
            if collapsed { collapsedGroups.remove(section.group) } else { collapsedGroups.insert(section.group) }
        } label: {
            HStack(spacing: 8) {
                Capsule(style: .continuous).fill(TVBrand.signal).frame(width: 3, height: 10)
                Text(section.group)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(section.channels.count)")
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).help(collapsed ? "展开\(section.group)" : "收起\(section.group)")
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("tv-top", anchor: .top)
    }

    private var currentSourceName: String {
        guard let id = tv.focusedPlaylistID else { return "全频直播" }
        return tv.playlistName(for: id)
    }

    /// 当前正在播放的频道：查看器里打开的电视频道。
    private var playingChannelID: String? {
        guard let viewerID = store.viewerID else { return nil }
        return store.tvPlaybackChannel(for: viewerID)?.id
    }

    private var emptyMessage: String {
        if !tv.searchText.isEmpty { return "没有找到「\(tv.searchText)」" }
        if tv.quickFilter == .favorites {
            return "还没有收藏频道。右键频道卡选择「收藏」，之后会出现在这里。"
        }
        if tv.quickFilter == .recent {
            return "还没有最近观看。打开一个频道后会出现在这里。"
        }
        return "这个电视源还没有频道，去「源库」分页点一下检测。"
    }
}

/// 列表密度的一行：频道号 / 台标 / 台名 + 分组 / Now & Next / 进度 / 信号点 / 星标。
struct TVChannelRow: View {
    @Environment(IPTVBrowserModel.self) private var tv
    let channel: TVChannel
    let number: Int
    let isPlaying: Bool
    let onPlay: () -> Void

    @State private var hovered = false

    private var current: TVEPGProgram? { tv.currentProgram(for: channel) }
    private var next: TVEPGProgram? { tv.nextProgram(for: channel) }

    private var statusColor: Color {
        switch tv.probeState(for: channel.id) {
        case .available: return TVBrand.success
        case .unavailable: return TVBrand.signal
        case .probing: return TVBrand.gold
        case .idle: return Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onPlay) { rowContent }
                .buttonStyle(.plain)
            favoriteButton
                .padding(.trailing, 8)
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button(isPlaying ? "重新打开" : "播放", action: onPlay)
            Button(tv.isFavorite(channel) ? "取消收藏" : "收藏频道") { tv.toggleFavorite(channel) }
            Button("重新探测信号") { tv.retryPreview(for: channel) }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Capsule(style: .continuous)
                .fill(isPlaying ? TVBrand.wave : Color.clear)
                .frame(width: 2, height: 22)

            Text(String(format: "%02d", number))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isPlaying ? TVBrand.wave : Color.secondary)
                .frame(width: 30, alignment: .leading)

            TVLogoImage(urlString: channel.logoURL,
                        size: CGSize(width: 32, height: 20),
                        cornerRadius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(channel.group)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 168, alignment: .leading)

            programInfo
                .frame(maxWidth: .infinity, alignment: .leading)

            if let current {
                ProgressView(value: progress(current))
                    .progressViewStyle(.linear)
                    .tint(TVBrand.wave)
                    .controlSize(.mini)
                    .frame(width: 72)
            }

            statusPill
                .help(probeHelp)
        }
        .padding(.leading, 8)
        .padding(.trailing, 28)
        .frame(height: 44)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var favoriteButton: some View {
        Button {
            tv.toggleFavorite(channel)
        } label: {
            Image(systemName: tv.isFavorite(channel) ? "star.fill" : "star")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tv.isFavorite(channel) ? TVBrand.gold : Color.secondary.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tv.isFavorite(channel) ? "取消收藏" : "收藏频道")
    }

    /// 列表行的可播性：不可播放用红色胶囊直接写明，避免只看到一个看不出含义的小圆点。
    @ViewBuilder
    private var statusPill: some View {
        switch tv.probeState(for: channel.id) {
        case .available:
            Text("可播放")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(TVBrand.success)
        case .unavailable:
            HStack(spacing: 2.5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("不可播放")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(TVBrand.signal)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(TVBrand.signal.opacity(0.14), in: Capsule(style: .continuous))
        case .probing:
            Text("检测中")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(TVBrand.gold)
        case .idle:
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private var programInfo: some View {
        if let current {
            HStack(spacing: 6) {
                Text(current.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                Text("\(clock(current.start)) – \(clock(current.end))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                if let next {
                    Text("接下来 \(next.title)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let next {
            Text("接下来 \(clock(next.start)) · \(next.title)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("暂无节目单")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isPlaying ? TVBrand.wave.opacity(0.07)
                            : (hovered ? TVBrand.surfaceHover : Color.clear))
    }

    private var probeHelp: String {
        switch tv.probeState(for: channel.id) {
        case .available: return "信号正常"
        case .unavailable: return "信号异常"
        case .probing: return "正在抓帧"
        case .idle: return "尚未探测"
        }
    }

    private func progress(_ program: TVEPGProgram) -> Double {
        let total = max(1, program.duration)
        return min(max(Date().timeIntervalSince(program.start) / total, 0), 1)
    }

    private func clock(_ date: Date) -> String {
        Self.clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
