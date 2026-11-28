import SwiftUI

/// 网络资源 › 图集分页：把各图集站的套图集中陈列。
///
/// 两种看法可切换：
/// - 瀑布墙：杂志式错落大图，悬停时懒解析这套图并自动翻页预览；
/// - 影院：今日大幕 + 各站点横向轨道，适合按站点逛。
struct CatalogGalleryHubView: View {
    @Environment(CatalogBrowserModel.self) private var catalog
    @Environment(LibraryStore.self) private var store

    @AppStorage("catalog.gallery.presentation") private var presentationRaw = Presentation.wall.rawValue
    @State private var heroCursor = 0
    @State private var containerWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    enum Presentation: String, CaseIterable, Identifiable {
        case wall
        case theater

        var id: String { rawValue }
        var title: String { self == .wall ? "瀑布墙" : "影院" }
        var symbol: String { self == .wall ? "square.grid.3x3.fill" : "film.stack" }
        var caption: String {
            self == .wall ? "错落大图 · 悬停自动翻页" : "今日大幕 · 按站点成排"
        }
    }

    private var presentation: Presentation { Presentation(rawValue: presentationRaw) ?? .wall }
    private var sources: [CatalogSource] { catalog.gallerySources }
    private var feed: [CatalogSpotlightItem] { catalog.galleryFeed }
    private var today: [CatalogSpotlightItem] { catalog.todayGallerySpotlight }
    private var heroCandidates: [CatalogSpotlightItem] { today.isEmpty ? feed : today }

    private var heroItem: CatalogSpotlightItem? {
        guard !heroCandidates.isEmpty else { return nil }
        return heroCandidates[heroCursor % heroCandidates.count]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .id("gallery-top")
                    if sources.isEmpty && feed.isEmpty {
                        emptyState
                    } else {
                        switch presentation {
                        case .wall:
                            wall
                        case .theater:
                            theater
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 14)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.automatic)
            .coordinateSpace(name: "gallery-scroll")
            // 墙底哨兵进入视口就继续翻页；这里用几何位置而不是 onAppear，
            // 因为瀑布墙是普通 VStack，所有子视图一开始就创建好了。
            .onPreferenceChange(GalleryBottomEdge.self) { bottom in
                guard viewportHeight > 0, bottom > 0 else { return }
                guard bottom < viewportHeight + 320 else { return }
                catalog.loadMoreGalleryFeed()
            }
            // 切换看法后回到顶部：影院的大幕与瀑布墙的精选条不在同一位置，留在原地会以为没切换。
            .onChange(of: presentationRaw) { _, _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("gallery-top", anchor: .top)
                }
            }
        }
        .background(LumaAmbientBackground(intensity: 0.55))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        containerWidth = proxy.size.width
                        viewportHeight = proxy.size.height
                    }
                    .onChange(of: proxy.size.width) { _, new in containerWidth = new }
                    .onChange(of: proxy.size.height) { _, new in viewportHeight = new }
            }
        }
        .task {
            catalog.loadGalleryFeed()
            // 今日精选来自更新日历：还没有记录时补一次，已有就等后台增量。
            if catalog.calendarItems.isEmpty { catalog.refreshCalendarToday(domain: .networkResource) }
        }
    }

    private func source(_ id: UUID) -> CatalogSource? {
        catalog.sources.first(where: { $0.id == id })
    }

    private func open(_ entry: CatalogSpotlightItem) {
        store.openCatalogItem(sourceID: entry.sourceID, item: entry.item)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("图集")
                .font(.system(size: 16, weight: .bold, design: .serif))
            Text("\(sources.count) 站 · \(feed.count) 套"
                 + (today.isEmpty ? "" : " · 今日 \(today.count)"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if catalog.isGalleryFeedLoading {
                ProgressView().controlSize(.mini)
            }
            presentationSwitcher
            randomButton
            refreshButton
        }
    }

    /// 看法切换：收进 header 一行的小分段，两种模式的排版差异本身就能说明切换成功。
    private var presentationSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(Presentation.allCases) { mode in
                let active = presentation == mode
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        presentationRaw = mode.rawValue
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        if active {
                            Capsule(style: .continuous).fill(Color.accentColor)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.caption)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private var randomButton: some View {
        Button {
            guard let pick = feed.randomElement() else { return }
            open(pick)
        } label: {
            Image(systemName: "dice.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.13), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.7)
                }
        }
        .buttonStyle(.plain)
        .disabled(feed.isEmpty)
        .help("随便看一套：从当前图集里随机打开")
    }

    private var refreshButton: some View {
        Button {
            catalog.loadGalleryFeed(force: true)
        } label: {
            if catalog.isGalleryFeedLoading {
                ProgressView().controlSize(.mini).frame(width: 26, height: 26)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .help("重新汇总各图集站")
    }

    // MARK: - 瀑布墙

    private var wall: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 瀑布墙不放全宽大幕：先用一条精选横条点题，再进入整面墙。
            if !heroCandidates.isEmpty {
                rail(title: today.isEmpty ? "精选套图" : "今日精选",
                     detail: "\(heroCandidates.count) 套 · 横向滑动",
                     symbol: "sparkles",
                     items: Array(heroCandidates.prefix(12)))
            }
            wallGrid
        }
    }

    private var wallGrid: some View {
        let columns = max(2, min(5, Int(containerWidth / 258)))
        let grouped = distribute(feed, columns: columns)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("全部图集", detail: "各站混排 · 悬停预览")
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(grouped.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 14) {
                        ForEach(column) { entry in
                            if let source = source(entry.sourceID) {
                                CatalogGalleryWallCard(entry: entry,
                                                       source: source,
                                                       height: wallHeight(entry)) {
                                    open(entry)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            feedFooter
        }
    }

    /// 墙底部的「继续加载」：滚到这里自动取各站下一页，到底后显示收尾文案。
    @ViewBuilder
    private var feedFooter: some View {
        if catalog.isGalleryFeedLoadingMore {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载更多…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if catalog.galleryFeedExhausted {
            Text("已经到底了 · 共 \(feed.count) 套")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            Color.clear
                .frame(height: 1)
                .padding(.top, 10)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: GalleryBottomEdge.self,
                            value: proxy.frame(in: .named("gallery-scroll")).maxY)
                    }
                }
        }
    }

    /// 错落排布：按列轮流放，每套的高度由 id 稳定决定，刷新不会跳动。
    private func distribute(_ items: [CatalogSpotlightItem],
                            columns: Int) -> [[CatalogSpotlightItem]] {
        guard columns > 0 else { return [] }
        var result = Array(repeating: [CatalogSpotlightItem](), count: columns)
        for (index, item) in items.enumerated() {
            result[index % columns].append(item)
        }
        return result
    }

    private func wallHeight(_ entry: CatalogSpotlightItem) -> CGFloat {
        let steps: [CGFloat] = [250, 296, 340, 268]
        let seed = entry.item.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return steps[seed % steps.count]
    }

    // MARK: - 影院

    private var theater: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let heroItem {
                CatalogGalleryHero(entry: heroItem,
                                   source: source(heroItem.sourceID),
                                   eyebrow: today.isEmpty ? "精选套图" : "今日精选",
                                   canShuffle: heroCandidates.count > 1) {
                    open(heroItem)
                } onShuffle: {
                    withAnimation(.easeOut(duration: 0.24)) {
                        heroCursor = (heroCursor + 1) % max(1, heroCandidates.count)
                    }
                }
            }
            if !today.isEmpty {
                rail(title: "今日上新",
                     detail: "本机今天第一次看到 · \(today.count) 套",
                     symbol: "sparkles",
                     items: today)
            }
            ForEach(sources) { source in
                let items = catalog.galleryBySource[source.id] ?? []
                if !items.isEmpty {
                    rail(title: source.name,
                         detail: "\(items.count) 套 · \(source.kind.title)",
                         symbol: source.kind.sidebarSymbol,
                         tint: source.kind.sidebarTint,
                         items: items,
                         browseSource: source)
                }
            }
            // 第一次进入还没分流到各站时，先用混排 feed 铺一条轨道，不让「影院」空白。
            if sources.allSatisfy({ (catalog.galleryBySource[$0.id] ?? []).isEmpty }),
               !feed.isEmpty {
                rail(title: "全部图集",
                     detail: "各站混排 · \(feed.count) 套",
                     symbol: "photo.stack.fill",
                     items: feed)
            }
            // 轨道看完还能继续往下逛：底部接整面墙，滚到底继续翻页。
            wallGrid
        }
    }

    private func rail(title: String,
                      detail: String,
                      symbol: String,
                      tint: Color = .accentColor,
                      items: [CatalogSpotlightItem],
                      browseSource: CatalogSource? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let browseSource {
                    Button("浏览站点") { store.openCatalogSource(browseSource.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(items) { entry in
                        if let source = source(entry.sourceID) {
                            CatalogGalleryPosterCard(entry: entry, source: source) {
                                open(entry)
                            }
                        }
                    }
                    // 滑到这条轨道的右端就继续翻这个站下一页。
                    if let browseSource,
                       !catalog.galleryExhaustedSources.contains(browseSource.id) {
                        railLoadMoreTile
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private var railLoadMoreTile: some View {
        Button {
            catalog.loadMoreGalleryFeed()
        } label: {
            VStack(spacing: 9) {
                if catalog.isGalleryFeedLoadingMore {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20, weight: .light))
                }
                Text(catalog.isGalleryFeedLoadingMore ? "正在加载…" : "继续加载")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(width: 168, height: 236)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09),
                                  style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("继续加载这个站点的更多图集")
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                catalog.loadMoreGalleryFeed()
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        LumaEmptyState(symbol: "photo.stack",
                       title: "还没有图集站",
                       message: "把写真 / 套图站接入网络资源后，会在这里按套图铺开浏览。",
                       style: .card,
                       actions: [LumaEmptyAction(title: "接入网络资源…", symbol: nil, filled: true) {
                           store.presentCatalogWizard()
                       }])
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

// MARK: - 今日大幕

/// 图集页顶部的大幕（仅影院模式）：左竖版封面 + 右信息区。
/// 封面按原始比例裁切、读全尺寸图，不会被拉成一条模糊的横幅。
private struct CatalogGalleryHero: View {
    let entry: CatalogSpotlightItem
    let source: CatalogSource?
    /// 「今日精选」或「精选套图」：今天没有新图集时不冒充今日内容。
    var eyebrow: String = "今日精选"
    let canShuffle: Bool
    let onOpen: () -> Void
    let onShuffle: () -> Void

    @State private var hovering = false

    private let height: CGFloat = 300

    private var tint: Color { source?.kind.sidebarTint ?? .accentColor }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: height * 0.76, height: height)
                .overlay {
                    if let source {
                        CatalogArtworkImage(source: source,
                                            urlString: entry.item.coverURL,
                                            cornerRadius: 0,
                                            quality: .full,
                                            placeholderSymbol: "photo.stack")
                    } else {
                        LinearGradient(colors: [tint.opacity(0.55), .black],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.stack.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("套图")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule(style: .continuous))
                    .padding(12)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(eyebrow)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.85), in: Capsule(style: .continuous))
                    if let source {
                        Text(source.name)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.14), in: Capsule(style: .continuous))
                    }
                }
                Text(entry.item.title)
                    .font(.system(size: 25, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                if !entry.item.remark.isEmpty {
                    Text(entry.item.remark)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                HStack(spacing: 9) {
                    Button(action: onOpen) {
                        HStack(spacing: 5) {
                            Image(systemName: "photo.stack.fill")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("整套浏览")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.accentColor, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    if canShuffle {
                        Button(action: onShuffle) {
                            HStack(spacing: 5) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text("换一组")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .frame(height: 28)
                            .background(.white.opacity(0.14), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.6)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color(red: 0.07, green: 0.07, blue: 0.09)
                    LinearGradient(colors: [tint.opacity(0.34), .black.opacity(0.2)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(hovering ? tint.opacity(0.7) : Color.white.opacity(0.10),
                              lineWidth: hovering ? 1.4 : 0.8)
        }
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.18),
                radius: hovering ? 20 : 12, y: hovering ? 10 : 5)
        .scaleEffect(hovering ? 1.004 : 1)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) { hovering = inside }
        }
        .help(entry.item.title)
    }
}

// MARK: - 瀑布墙卡片

private struct CatalogGalleryWallCard: View {
    let entry: CatalogSpotlightItem
    let source: CatalogSource
    let height: CGFloat
    let action: () -> Void

    @Environment(CatalogBrowserModel.self) private var catalog
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CatalogGalleryHoverCover(entry: entry, source: source)
                    .frame(height: height)
                    .overlay {
                        LinearGradient(colors: [.clear, .black.opacity(0.16),
                                                .black.opacity(0.82)],
                                       startPoint: .center, endPoint: .bottom)
                    }
                    .overlay(alignment: .topLeading) {
                        badgeRow
                            .padding(10)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.item.title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(source.kind.sidebarTint)
                                    .frame(width: 4.5, height: 4.5)
                                Text(source.name)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.8))
                                if let category = categoryTitle {
                                    Text("· \(category)")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if let count = catalog.galleryImageCount(sourceID: entry.sourceID,
                                                                        itemID: entry.item.id) {
                                    Text("\(count) 张")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                            }
                        }
                        .padding(12)
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(hovering ? source.kind.sidebarTint.opacity(0.75)
                                           : Color.primary.opacity(0.08),
                                  lineWidth: hovering ? 1.2 : 0.6)
            }
            .shadow(color: .black.opacity(hovering ? 0.24 : 0.12),
                    radius: hovering ? 14 : 7, y: hovering ? 7 : 3)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) { hovering = inside }
        }
        .help(entry.item.title)
    }

    private var categoryTitle: String? {
        guard let id = entry.item.categoryID,
              !id.isEmpty,
              let title = catalog.category(withID: id)?.title,
              !title.isEmpty else { return nil }
        return title
    }

    private var badgeRow: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3.5) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("套图")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.42), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 影院轨道卡片

private struct CatalogGalleryPosterCard: View {
    let entry: CatalogSpotlightItem
    let source: CatalogSource
    let action: () -> Void

    @Environment(CatalogBrowserModel.self) private var catalog
    @State private var hovering = false

    private let width: CGFloat = 168
    private let height: CGFloat = 236

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                CatalogGalleryHoverCover(entry: entry, source: source)
                    .frame(width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "photo.stack.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.42), in: Circle())
                            .padding(7)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let count = catalog.galleryImageCount(sourceID: entry.sourceID,
                                                                itemID: entry.item.id) {
                            Text("\(count) 张")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(.black.opacity(0.45), in: Capsule(style: .continuous))
                                .padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(hovering ? source.kind.sidebarTint.opacity(0.75)
                                                   : Color.primary.opacity(0.08),
                                          lineWidth: hovering ? 1.1 : 0.6)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.24 : 0.12),
                            radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
                Text(entry.item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovering ? 1 : 0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, height: 32, alignment: .topLeading)
                if !entry.item.remark.isEmpty {
                    Text(entry.item.remark)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .help(entry.item.title)
    }
}

// MARK: - 悬停翻页封面

/// 图集封面：悬停后懒解析这套图，按 1.2s 一张淡入翻页；离开立即停下。
/// 解析失败时保留原封面，不显示加载失败。
private struct CatalogGalleryHoverCover: View {
    let entry: CatalogSpotlightItem
    let source: CatalogSource

    @Environment(CatalogBrowserModel.self) private var catalog
    @State private var images: [String] = []
    @State private var index = 0
    @State private var task: Task<Void, Never>?

    private var currentURL: String {
        if images.isEmpty { return entry.item.coverURL }
        return images[index % images.count]
    }

    var body: some View {
        ZStack {
            if !currentURL.isEmpty {
                CatalogArtworkImage(source: source, urlString: currentURL, cornerRadius: 0)
                    .id(currentURL)
                    .transition(.opacity)
            } else {
                ZStack {
                    source.kind.sidebarTint.opacity(0.35)
                    Image(systemName: "photo.stack")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .animation(.easeInOut(duration: 0.45), value: currentURL)
        .onHover { inside in
            if inside { start() } else { stop() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            if images.isEmpty {
                // 悬停 350ms 再解析：鼠标扫过格子时不给站点打一串请求。
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { task = nil; return }
                let urls = await catalog.galleryPreviewImages(sourceID: entry.sourceID,
                                                              itemID: entry.item.id)
                guard !Task.isCancelled, !urls.isEmpty else {
                    task = nil
                    return
                }
                withAnimation(.easeOut(duration: 0.3)) {
                    images = urls
                    index = 0
                }
            }
            // 自动翻页：一张一张淡入，到底回到第一张。
            while !Task.isCancelled, images.count > 1 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, images.count > 1 else { break }
                withAnimation(.easeInOut(duration: 0.45)) {
                    index = (index + 1) % images.count
                }
            }
            task = nil
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        if !images.isEmpty {
            withAnimation(.easeOut(duration: 0.2)) {
                index = 0
            }
        }
    }
}

// MARK: - 媒体类型筛选

/// 榜单 / 日历 / 足迹 / 片单 / 资源页搜索共用的「全部 / 视频 / 图集」筛选胶囊。
/// 不传 `selection` 时直接改全局 `catalog.mediaFilter`；搜索页用自己的局部状态。
struct CatalogMediaFilterChips: View {
    @Environment(CatalogBrowserModel.self) private var catalog
    var selection: Binding<CatalogMediaFilter>? = nil

    private var value: CatalogMediaFilter { selection?.wrappedValue ?? catalog.mediaFilter }

    var body: some View {
        // 没接入任何图集站时，「图集」这个筛选项本身没有意义，整条隐藏。
        if catalog.gallerySources.isEmpty && selection == nil {
            EmptyView()
        } else {
            chips
        }
    }

    private var chips: some View {
        HStack(spacing: 2) {
            ForEach(CatalogMediaFilter.allCases) { filter in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if let selection {
                            selection.wrappedValue = filter
                        } else {
                            catalog.mediaFilter = filter
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.symbol)
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(filter.title)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(value == filter ? Color.white : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        if value == filter {
                            Capsule(style: .continuous).fill(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }
}

/// 瀑布墙底部哨兵的纵向位置：滚到接近视口底部时触发继续加载。
private struct GalleryBottomEdge: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
