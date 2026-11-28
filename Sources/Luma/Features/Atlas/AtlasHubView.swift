import AVKit
import SwiftUI

/// 星图模块：发现 / 星图 / 影院 / 作品集 / 图集 / 人物。
/// 资料库不随安装包内置，入口由资料库是否加载决定。
struct AtlasHubView: View {
    @Environment(AtlasStore.self) private var atlas

    var body: some View {
        @Bindable var atlas = atlas
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            content
        }
        .background(LumaAmbientBackground(intensity: 0.55))
        .task { atlas.bootstrapIfNeeded() }
        .onAppear { consumePending() }
        .onChange(of: atlas.pendingPersonID) { _, _ in consumePending() }
        .onChange(of: atlas.pendingWorkID) { _, _ in consumePending() }
        .onChange(of: atlas.pendingCode) { _, _ in consumePending() }
        .sheet(item: Binding(get: { atlas.focusedWork }, set: { atlas.focusedWork = $0 })) { work in
            AtlasWorkSheet(work: work)
                .environment(atlas)
        }
    }

    // MARK: 页头

    private var header: some View {
        @Bindable var atlas = atlas
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("拾光星图")
                            .font(.system(size: 20, weight: .bold, design: .serif))
                        Text("FILM ATLAS")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(atlas.mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                totalsChips
            }

            HStack(spacing: 10) {
                searchField
                AtlasModeBar(mode: $atlas.mode)
                Spacer(minLength: 0)
            }

            if atlas.mode == .discover || atlas.mode == .people || atlas.mode == .works {
                regionChips
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false)
        }
    }

    private var searchField: some View {
        @Bindable var atlas = atlas
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            TextField("搜索人物、番号或片名", text: $atlas.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
            if !atlas.searchText.isEmpty {
                Button {
                    atlas.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 236, height: 27)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var totalsChips: some View {
        HStack(spacing: 8) {
            chip("人物", AtlasLook.compact(atlas.totals.people))
            chip("作品", AtlasLook.compact(atlas.totals.works))
            chip("分类", AtlasLook.compact(atlas.totals.genres))
        }
    }

    private func chip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var regionChips: some View {
        @Bindable var atlas = atlas
        let regions: [(String?, String)] = [(nil, "全部"), ("japan", "日本"), ("china", "大陆"),
                                            ("taiwan", "台湾"), ("hongkong", "香港"),
                                            ("korea", "韩国"), ("western", "欧美")]
        return HStack(spacing: 5) {
            ForEach(regions, id: \.1) { item in
                Button {
                    atlas.regionFilter = item.0
                } label: {
                    Text(item.1)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(atlas.regionFilter == item.0 ? Color.white : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background {
                            if atlas.regionFilter == item.0 {
                                Capsule().fill(Color.accentColor.opacity(0.85))
                            } else {
                                Capsule().fill(Color.primary.opacity(0.05))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !atlas.isAvailable && !atlas.isLoading {
            AtlasEmptyState(title: "还没有加载星图资料库",
                            message: "在菜单「文件 › 星图 › 加载星图资料库…」里选择 catalog.sqlite，加载成功后这里才会显示内容。",
                            symbol: "externaldrive.badge.questionmark")
        } else {
            switch atlas.mode {
            case .discover:
                AtlasDiscoverView()
            case .constellation:
                AtlasConstellationView()
            case .theater:
                AtlasTheaterView()
            case .works:
                AtlasWorksView()
            case .galleries:
                AtlasGalleriesView()
            case .people:
                AtlasArchiveView()
            }
        }
    }

    private func consumePending() {
        if let id = atlas.pendingPersonID {
            atlas.mode = .people
            atlas.selectedPersonID = id
            atlas.pendingPersonID = nil
        }
        if let id = atlas.pendingWorkID {
            Task {
                if let work = await atlas.work(id: id) { atlas.focusedWork = work }
                atlas.pendingWorkID = nil
            }
        }
        if let code = atlas.pendingCode {
            Task {
                if let work = await atlas.work(code: code) {
                    atlas.focusedWork = work
                } else {
                    atlas.searchText = code
                    atlas.mode = .works
                }
                atlas.pendingCode = nil
            }
        }
    }
}

// MARK: - 作品详情弹层

struct AtlasWorkSheet: View {
    let work: AtlasWork
    @Environment(AtlasStore.self) private var atlas
    @Environment(CatalogBrowserModel.self) private var catalog
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var playingTrailer = false
    @State private var onlineVideos: [AtlasOnlineEntry] = []
    @State private var isLoadingOnline = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                AtlasRemoteImage(urlString: work.coverURL ?? work.thumbURL, seed: Int(work.id))
                    .frame(width: 190, height: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text(work.title)
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(work.dvdID)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        if let date = work.releaseDate {
                            Text(AtlasLook.shortDate(date))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let series = work.series, !series.isEmpty {
                        Label(series, systemImage: "rectangle.stack")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let label = work.label, !label.isEmpty {
                        Label(label, systemImage: "building.2")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if !work.genres.isEmpty {
                        FlowChips(items: work.genres.prefix(8).map { $0 })
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        if work.trailerURL != nil {
                            Button {
                                playingTrailer = true
                            } label: {
                                Label("播放试看", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("关闭") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)

            if !work.samples.isEmpty {
                Divider().opacity(0.2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(work.samples, id: \.self) { url in
                            AtlasRemoteImage(urlString: url, seed: url.count)
                                .frame(width: 150, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }

            if isLoadingOnline || !onlineVideos.isEmpty {
                Divider().opacity(0.2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                            .font(.system(size: 10))
                        Text("在线资源")
                            .font(.system(size: 11, weight: .semibold))
                        if isLoadingOnline {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer()
                        if !onlineVideos.isEmpty {
                            Text("\(onlineVideos.count) 条")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !onlineVideos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(onlineVideos) { entry in
                                    AtlasOnlineCard(entry: entry,
                                                    source: catalog.sources.first { $0.id == entry.sourceID },
                                                    width: 108) {
                                        open(entry)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 680)
        .background(LumaAmbientBackground(intensity: 0.35))
        .task(id: work.dvdID) { await loadOnline() }
        .sheet(isPresented: $playingTrailer) {
            if let urlString = work.trailerURL, let url = URL(string: urlString) {
                AtlasTrailerPlayer(url: url)
            }
        }
    }

    private func loadOnline() async {
        guard AtlasCatalogPaths.isLoaded else { return }
        isLoadingOnline = true
        await AtlasOnlineStore.shared.load(work.dvdID, catalog: catalog)
        onlineVideos = Array(AtlasOnlineStore.shared.videos.prefix(12))
        isLoadingOnline = false
    }

    private func open(_ entry: AtlasOnlineEntry) {
        dismiss()
        catalog.pendingInlineItem = entry.item
        catalog.focus(entry.sourceID)
        store.navigate(to: .catalogSource(entry.sourceID))
    }
}

struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AtlasTrailerPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .frame(width: 720, height: 405)
            HStack {
                Spacer()
                Button("关闭") {
                    player.pause()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}

/// 极简流式布局：标签自动换行，避免每个页面各写一份。
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
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
