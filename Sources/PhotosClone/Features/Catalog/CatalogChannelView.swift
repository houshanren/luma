import AppKit
import SwiftUI
import LumaContentCore

/// 列表滚动进度：只上报内容偏移与总高度，用于 60% 提前预取下一页。
private struct CatalogScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct CatalogScrollMetricsKey: PreferenceKey {
    static var defaultValue = CatalogScrollMetrics()

    static func reduce(value: inout CatalogScrollMetrics,
                       nextValue: () -> CatalogScrollMetrics) {
        let next = nextValue()
        if next.contentHeight > 0 { value = next }
    }
}

private enum CatalogScrollSpace {
    static let name = "catalog-channel-scroll"
}

/// 框选用的命名坐标系：网格单元格把自身矩形上报到这里，鼠标位置也按它换算。
private enum CatalogMarqueeSpace {
    static let name = "catalog-channel-marquee"
}

private struct CatalogCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 网格空白处拖动框选；从卡片内部按下时让位给卡片自己的点击 / 预览。
private struct CatalogMarqueeModifier: ViewModifier {
    @Binding var selection: Set<String>

    @State private var frames: [String: CGRect] = [:]
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var base: Set<String> = []
    @State private var blockedStart: CGPoint?

    private var marqueeRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x),
                      y: min(start.y, current.y),
                      width: abs(current.x - start.x),
                      height: abs(current.y - start.y))
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .coordinateSpace(name: CatalogMarqueeSpace.name)
            .onPreferenceChange(CatalogCardFrameKey.self) { frames = $0 }
            .overlay(alignment: .topLeading) { marqueeOverlay }
            .simultaneousGesture(blankTapGesture)
            .simultaneousGesture(marqueeGesture)
    }

    /// 点空白处取消选择；点卡片仍走卡片自己的手势。
    private var blankTapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(CatalogMarqueeSpace.name))
            .onEnded { value in
                guard !frames.values.contains(where: { $0.contains(value.location) }) else { return }
                selection.removeAll()
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect, rect.width > 2, rect.height > 2 {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(CatalogMarqueeSpace.name))
            .onChanged { value in
                if let blocked = blockedStart {
                    if blocked == value.startLocation { return }
                    blockedStart = nil
                }
                if start == nil {
                    if frames.values.contains(where: { $0.contains(value.startLocation) }) {
                        blockedStart = value.startLocation
                        return
                    }
                    start = value.startLocation
                    let flags = NSEvent.modifierFlags
                    let additive = flags.contains(.command) || flags.contains(.shift)
                    base = additive ? selection : []
                    if !additive { selection.removeAll() }
                }
                current = value.location
                guard let rect = marqueeRect else { return }
                let hits = frames.filter { $0.value.intersects(rect) }.map(\.key)
                selection = base.union(hits)
            }
            .onEnded { _ in
                start = nil
                current = nil
                base = []
                blockedStart = nil
            }
    }
}

private extension View {
    func catalogMarqueeSelection(_ selection: Binding<Set<String>>) -> some View {
        modifier(CatalogMarqueeModifier(selection: selection))
    }
}

// MARK: - 网络资源频道页

struct CatalogChannelView: View {
    let sourceID: UUID

    @EnvironmentObject private var catalog: CatalogBrowserModel
    /// 顶栏的放大 / 缩小滑杆写的是这个 thumbSize，内容区必须跟着它一起缩放。
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    /// 热门标签收进「标签」这个筛选入口；默认展开，方便直接看到当前分类的二级标签。
    @State private var showTags = true
    @State private var hoveringTag = false
    /// 标签面板里当前查看的一级分组（分类精选 / 题材属性 / 片商…）；为空时取第一组。
    @State private var activeTagGroupID: String?
    /// 一级分类默认全部展开（65 个也一次铺开），需要时再手动收起；状态按源记住。
    @State private var showAllCategories = true
    /// 批量操作：⌘ 点选中的条目 id，底部浮出操作条。
    @State private var selectedIDs: Set<String> = []
    /// 键盘导航的光标：鼠标悬停到哪张卡，方向键就从哪张继续走。
    @State private var cursorID: String?
    @FocusState private var listFocused: Bool
    /// 一级范围的高亮胶囊与二级频道的下划线在这两个命名空间里滑动。
    @Namespace private var chipNamespace

    private var source: CatalogSource? {
        catalog.sources.first(where: { $0.id == sourceID })
    }

    /// 当前正在用哪个热门标签筛选（侧边栏与 chips 都不为它单独高亮）。
    private var activeTag: CatalogCategory? {
        guard case .category(let id) = catalog.section else { return nil }
        return catalog.tags
            .flatMap { [$0] + ($0.children ?? []) }
            .first(where: { $0.id == id })
    }

    /// 分组标签里的叶子项数量（标题上显示的总数）。
    private var tagLeafCount: Int {
        catalog.tags.reduce(0) { sum, tag in
            sum + (tag.children?.count ?? 1)
        }
    }

    var body: some View {
        Group {
            if let activeItem = catalog.inlineDetailItem {
                // 详情不再弹窗：直接占据内容区，返回入口融进窗口工具栏。
                CatalogDetailView(item: activeItem) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        catalog.inlineDetailItem = nil
                    }
                }
                .environmentObject(catalog)
                .transition(.opacity)
            } else {
                channelList
            }
        }
        .task(id: sourceID) {
            // 关闭播放器后回到详情：有代打开条目就直接铺开；
            // 否则若上次退出时停在详情页，这次进入同一个源也直接还原；都没有才回列表。
            if let pending = catalog.pendingInlineItem {
                catalog.pendingInlineItem = nil
                catalog.inlineDetailItem = pending
            } else if let restored = catalog.consumeLaunchInlineDetail(for: sourceID) {
                catalog.inlineDetailItem = restored
            } else {
                catalog.inlineDetailItem = nil
            }
            catalog.focus(sourceID)
            // 分类面板默认展开；如果这个源上次手动收起过，这里恢复收起状态。
            showAllCategories = CatalogStore.string(forKey: categoryExpandedKey) != "0"
            applyDefaultCardSizeIfNeeded()
            if let source {
                // 侧边栏分类图标用分类首图：先读缓存，缺的再后台补一次。
                catalog.prefetchCategoryThumbs(for: source)
            }
            if (source?.isEnabled ?? false), catalog.items.isEmpty, !catalog.isLoading {
                // 还原到上次的分类时列表也是空的，这里要补一次加载。
                switch catalog.section {
                case .continueWatching, .favorites:
                    break
                default:
                    catalog.reload()
                }
            }
        }
        // 工具栏的分类菜单 / 侧边栏切分类时，详情页跟着退出，避免停在上一页内容上。
        .onChange(of: catalog.section) { _, _ in
            catalog.inlineDetailItem = nil
            selectedIDs.removeAll()
        }
    }

    private var channelList: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let source {
                        if source.isEnabled {
                            body(source)
                        } else {
                            gate(source)
                        }
                    } else {
                        missing
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, selectedIDs.isEmpty ? 60 : 96)
                .background {
                    // 只看滚动量：滚到当前内容 60% 时提前取下一页，不等最后几张卡出现。
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CatalogScrollMetricsKey.self,
                            value: CatalogScrollMetrics(
                                offset: proxy.frame(in: .named(CatalogScrollSpace.name)).minY,
                                contentHeight: proxy.size.height))
                    }
                }
            }
            .coordinateSpace(name: CatalogScrollSpace.name)
            .onPreferenceChange(CatalogScrollMetricsKey.self) { metrics in
                prefetchNextPageIfNeeded(metrics, viewportHeight: viewport.size.height)
            }
            .scrollIndicators(.automatic)
            .background(LumaAmbientBackground(intensity: 0.55))
            .overlay(alignment: .bottom) { selectionBar }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.leftArrow) { moveCursor(by: -1); return .handled }
            .onKeyPress(.rightArrow) { moveCursor(by: 1); return .handled }
            .onKeyPress(.upArrow) { moveCursor(by: -currentColumns); return .handled }
            .onKeyPress(.downArrow) { moveCursor(by: currentColumns); return .handled }
            .onKeyPress(.return) { openCursorItem(); return .handled }
            .onKeyPress(.space) { openCursorItem(); return .handled }
            .onKeyPress(keys: ["a"], phases: .down) { press in
                // ⌘A 全选当前已加载的条目；框选则由网格空白处拖动完成。
                guard press.modifiers.contains(.command), !catalog.items.isEmpty else {
                    return .ignored
                }
                selectedIDs = Set(catalog.items.map(\.id))
                return .handled
            }
            .onKeyPress(.escape) {
                if !selectedIDs.isEmpty {
                    selectedIDs.removeAll()
                    return .handled
                }
                cursorID = nil
                return .ignored
            }
            .onDisappear {
                selectedIDs.removeAll()
                cursorID = nil
            }
        }
    }

    /// 滚动到当前内容 60% 时预取下一页；取完新页后内容变长，阈值自然后移，不会连环拉取。
    private func prefetchNextPageIfNeeded(_ metrics: CatalogScrollMetrics,
                                          viewportHeight: CGFloat) {
        guard catalog.hasMore, !catalog.isLoadingMore,
              metrics.contentHeight > viewportHeight else { return }
        let maxOffset = max(1, metrics.contentHeight - viewportHeight)
        let scrolled = max(0, -metrics.offset)
        guard scrolled >= maxOffset * 0.6 else { return }
        catalog.loadMore()
    }

    // MARK: - 键盘导航 / 批量操作

    private var currentColumns: Int {
        guard let source else { return 4 }
        return source.kind.isWebSite ? webColumnCount : posterColumnCount
    }

    /// 悬停时接管键盘焦点，让方向键能继续导航；
    /// 但如果用户正在输入（源内搜索 / 顶栏搜索），不要抢走焦点。
    private func adoptListFocus() {
        if NSApp.keyWindow?.firstResponder is NSTextView { return }
        listFocused = true
    }

    private func moveCursor(by delta: Int) {
        let items = catalog.items
        guard !items.isEmpty else { return }
        adoptListFocus()
        guard let cursorID, let index = items.firstIndex(where: { $0.id == cursorID }) else {
            self.cursorID = items.first?.id
            return
        }
        let next = min(max(index + delta, 0), items.count - 1)
        self.cursorID = items[next].id
    }

    private func openCursorItem() {
        guard let cursorID,
              let item = catalog.items.first(where: { $0.id == cursorID }) else { return }
        openInline(item)
    }

    /// 打开条目详情：状态提到模型里，工具栏才能同步显示返回入口与标题。
    private func openInline(_ item: CatalogItem) {
        withAnimation(.easeOut(duration: 0.16)) {
            catalog.inlineDetailItem = item
        }
    }

    /// 批量操作条：只在有选中项时浮出，不占列表高度。
    @ViewBuilder
    private var selectionBar: some View {
        if !selectedIDs.isEmpty, let source {
            let selected = catalog.items.filter { selectedIDs.contains($0.id) }
            HStack(spacing: 10) {
                Text("已选 \(selectedIDs.count) 条")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("⌘ 点击加选 · 空白处拖动框选 · ⌘A 全选")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                // 全都已在稍后看里时按钮变成「移出」，否则只补加还没加入的条目。
                let allFavorites = !selected.isEmpty && selected.allSatisfy {
                    catalog.isFavorite(sourceID: source.id, itemID: $0.id)
                }
                Button {
                    catalog.setFavorite(!allFavorites, source: source, items: selected)
                    selectedIDs.removeAll()
                } label: {
                    barButton(allFavorites ? "移出稍后看" : "稍后看",
                              symbol: allFavorites ? "bookmark.slash" : "bookmark.fill")
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(catalog.playlists) { playlist in
                        Button(playlist.name) {
                            catalog.addToPlaylist(playlist.id, source: source, items: selected)
                            selectedIDs.removeAll()
                        }
                    }
                    if !catalog.playlists.isEmpty { Divider() }
                    Button("新建片单并加入") {
                        let id = catalog.createPlaylist(name: "片单 \(catalog.playlists.count + 1)")
                        catalog.addToPlaylist(id, source: source, items: selected)
                        selectedIDs.removeAll()
                    }
                } label: {
                    barButton("加入片单", symbol: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    catalog.markWatched(source: source, items: selected)
                    selectedIDs.removeAll()
                } label: {
                    barButton("标记已看", symbol: "checkmark.circle")
                }
                .buttonStyle(.plain)

                if let first = selected.first {
                    Button {
                        store.openCatalogItemInBrowser(source: source, item: first)
                    } label: {
                        barButton("打开原始页", symbol: "safari")
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    selectedIDs.removeAll()
                } label: {
                    barButton("清空", symbol: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func barButton(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.accentColor.opacity(0.13), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.7)
        }
    }

    /// 网络资源第一次打开时给一次更大的默认卡片：竖版海报 5 列、横版网页源 4 列。
    /// 之后拖动顶栏滑杆的位置会按源记住，不再重置。
    private func applyDefaultCardSizeIfNeeded() {
        guard let source else { return }
        let key = "catalog.defaultCardSize.v2.\(source.id.uuidString)"
        // 旧版写在 UserDefaults：迁到图库级存储，避免换库后又重置一次。
        if UserDefaults.standard.bool(forKey: key) {
            CatalogStore.string(forKey: key, value: "1")
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard CatalogStore.string(forKey: key) == nil else { return }
        CatalogStore.string(forKey: key, value: "1")
        store.thumbSize = store.defaultGridThumbSize
    }

    // MARK: - 正文

    @ViewBuilder
    private func body(_ source: CatalogSource) -> some View {
        // 外部源不再单独铺「继续观看」：续看统一收进网络资源总览的「足迹」页。
        chips
        // 断网降级：有本地快照就继续看，只在上方提示「这是什么时候的内容」。
        if let snapshot = catalog.listSnapshotAt, !catalog.items.isEmpty, catalog.error != nil {
            snapshotBanner(snapshot)
            if catalog.errorNeedsVerification {
                verificationBanner(source: source)
            }
        } else if let error = catalog.error {
            // 403 / WAF / PoW：把「在浏览器打开」直接放到页面里，不用先去健康面板。
            if catalog.errorNeedsVerification {
                verificationBanner(source: source)
            } else {
                SourceErrorView(error: catalog.sourceError
                                    ?? SourceError(kind: .unavailable,
                                                   message: error,
                                                   recovery: [.retry])) { action in
                    handleSourceRecovery(action, source: source)
                }
            }
        }
        if let notice = catalog.notice {
            banner(text: notice, isError: false)
        }
        if case .favorites = catalog.section {
            if catalog.currentFavorites.isEmpty {
                emptyState
            } else {
                favoritesList(source)
            }
        } else {
            content(source)
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                // 一级特别多（Avgle 这类近二十项）时胶囊舱会挤成横向滚动条，
                // 换成可换行的分类面板，一屏看全。
                if catalog.categories.count > 8 {
                    categoryPanel
                } else {
                    categoryTray
                }

                // 随便挑一部：从当前列表里随机打开详情，给浏览加一点意外性。
                if catalog.items.count > 3 {
                    surpriseButton.fixedSize()
                }

                // 热门标签不铺一行：收进「标签」筛选，选中的标签直接显示在按钮上。
                if !catalog.tags.isEmpty {
                    tagFilter.fixedSize()
                }
            }
            // 标签不是浮层：点开后直接在分类下面铺开，页面顺势下移。
            if showTags, !catalog.tags.isEmpty {
                tagPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // 二级分类只在点开一级分组后出现，来自当前分组在站点里的频道。
            if !catalog.subCategories.isEmpty {
                subCategoryBar
            }
        }
        .animation(settings.motion.layout, value: showTags)
    }

    /// 一级范围做成一条连体舱体：选中块在舱内滑动，比一排独立灰胶囊更像导航。
    private var categoryTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                CatalogChip(title: "首页",
                            active: catalog.section == .home,
                            namespace: chipNamespace) {
                    catalog.openHome()
                }
                ForEach(catalog.categories) { category in
                    CatalogChip(title: category.title,
                                active: catalog.activeTopCategory?.id == category.id,
                                namespace: chipNamespace) {
                        if category.isRank {
                            catalog.openRank()
                        } else {
                            catalog.openCategory(category)
                        }
                    }
                    .contextMenu {
                        Button(catalog.isFollowed(category) ? "取消关注" : "关注此分类") {
                            catalog.toggleFollow(category)
                        }
                    }
                }
                // 与左侧菜单的「稍后看」一一对应，出现条件也一致。
                if !catalog.currentFavorites.isEmpty {
                    CatalogChip(title: "稍后看",
                                active: catalog.section == .favorites,
                                namespace: chipNamespace) {
                        catalog.openFavorites()
                    }
                }
            }
            .padding(4)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
            }
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
    }

    /// 一级数量过多的分类面板：常用置顶、可换行、超长时折叠。
    private var categoryPanel: some View {
        let ordered = catalog.orderedCategories(catalog.categories)
        let limit = 14
        let expanded = showAllCategories || ordered.count <= limit
        let visible = expanded ? ordered : Array(ordered.prefix(limit))
        let pinnedCount = ordered.filter { catalog.isPinnedCategory($0.id) }.count
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4.5, height: 4.5)
                Text("分类")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                Text("\(ordered.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary.opacity(0.8))
                if pinnedCount > 0 {
                    Text("· \(pinnedCount) 个常用")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary.opacity(0.8))
                }
                Spacer()
                if ordered.count > limit {
                    Button(showAllCategories ? "收起" : "展开全部") {
                        withAnimation(settings.motion.layout) {
                            showAllCategories.toggle()
                            CatalogStore.string(forKey: categoryExpandedKey,
                                                value: showAllCategories ? "1" : "0")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.accentColor)
                }
            }
            CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                CatalogChannelPill(title: "首页", active: catalog.section == .home) {
                    catalog.openHome()
                }
                ForEach(visible) { category in
                    CatalogChannelPill(title: category.title,
                                       active: catalog.activeTopCategory?.id == category.id,
                                       pinned: catalog.isPinnedCategory(category.id)) {
                        if category.isRank {
                            catalog.openRank()
                        } else {
                            catalog.openCategory(category)
                        }
                    }
                    .contextMenu {
                        Button(catalog.isPinnedCategory(category.id) ? "取消常用" : "设为常用") {
                            catalog.togglePinnedCategory(category)
                        }
                        Button(catalog.isFollowed(category) ? "取消关注" : "关注此分类") {
                            catalog.toggleFollow(category)
                        }
                    }
                }
                if !catalog.currentFavorites.isEmpty {
                    CatalogChannelPill(title: "稍后看",
                                       active: catalog.section == .favorites) {
                        catalog.openFavorites()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
                }
        }
    }

    /// 随便挑一部：当前列表随机打开详情。
    private var surpriseButton: some View {
        Button {
            guard let pick = catalog.items.randomElement() else { return }
            openInline(pick)
        } label: {
            Image(systemName: "dice.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.13), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
        .help("从当前列表随便挑一部")
    }

    /// 二级频道：这里是当前分类下再收一层范围，必须一眼看出「可以点」。
    /// 统一用有底色的胶囊（数量多时换行），并补一个「全部」让选中态始终存在。
    private var subCategoryBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4.5, height: 4.5)
                Text("频道")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Text("\(catalog.subCategories.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text("选一个缩小范围")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if catalog.subCategories.count > 8 {
                CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                    allSubChannelsPill
                    ForEach(catalog.subCategories) { sub in
                        CatalogChannelPill(title: sub.title,
                                           active: currentCategoryID == sub.id) {
                            catalog.openCategory(sub)
                        }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        allSubChannelsPill
                        ForEach(catalog.subCategories) { sub in
                            CatalogChannelPill(title: sub.title,
                                               active: currentCategoryID == sub.id) {
                                catalog.openCategory(sub)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
        }
    }

    /// 「全部」= 当前一级分类整体范围；没有选中任何子频道时它就是选中态。
    @ViewBuilder
    private var allSubChannelsPill: some View {
        if let parent = catalog.activeTopCategory {
            CatalogChannelPill(title: "全部",
                               active: currentCategoryID == parent.id) {
                catalog.openCategory(parent)
            }
        }
    }

    /// 标签筛选入口：点开后在分类下方展开标签面板，再点收起。
    /// 用强调色淡底而不是中性灰底：在深色背景上要一眼看到这个筛选入口。
    private var tagFilter: some View {
        Button {
            withAnimation(settings.motion.layout) { showTags.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeTag == nil ? "tag" : "tag.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(activeTag.map { $0.title } ?? "标签")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .rotationEffect(.degrees(showTags ? 180 : 0))
                    .opacity(activeTag == nil ? 0.85 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(activeTag != nil ? Color.white : Color.accentColor)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(activeTag != nil
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor,
                                                                  Color.accentColor.opacity(0.78)],
                                                         startPoint: .top,
                                                         endPoint: .bottom))
                          : AnyShapeStyle(Color.accentColor.opacity(hoveringTag ? 0.22
                                                                               : (showTags ? 0.18 : 0.13))))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(activeTag != nil
                                  ? Color.white.opacity(0.20)
                                  : Color.accentColor.opacity(hoveringTag ? 0.60
                                                                          : (showTags ? 0.50 : 0.34)),
                                  lineWidth: 0.8)
            }
            .shadow(color: Color.accentColor.opacity(activeTag != nil ? 0.34 : 0.18),
                    radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hoveringTag = $0 }
        .animation(.easeOut(duration: 0.12), value: hoveringTag)
        .animation(.easeOut(duration: 0.16), value: showTags)
        .help(activeTag == nil ? "展开热门标签" : "标签筛选：\(activeTag?.title ?? "")（点击更换）")
    }

    /// 展开后的标签面板：一级分组 + 当前分组的标签，点分组切换。
    private var tagPanel: some View {
        let grouped = catalog.tags.filter { $0.children?.isEmpty == false }
        let flat = catalog.tags.filter { $0.children?.isEmpty != false }
        let selectedGroup = grouped.first { $0.id == activeTagGroupID }
            ?? grouped.first { group in
                (group.children ?? []).contains { $0.id == activeTag?.id }
            }
            ?? grouped.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor,
                                                  Color.accentColor.opacity(0.35)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 3, height: 14)
                Text("热门标签")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(tagLeafCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if activeTag != nil {
                    Button("清除筛选") {
                        withAnimation(settings.motion.layout) { showTags = false }
                        catalog.openHome()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                }
                Button("收起") {
                    withAnimation(settings.motion.layout) { showTags = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("收起标签")
            }
            // 没有分组的站点（如黄果）标签很多：直接平铺成多列，不能一条一行。
            if !flat.isEmpty {
                CatalogFlowLayout(spacing: 8, lineSpacing: 10) {
                    ForEach(flat) { tag in
                        CatalogTagPill(title: tag.title,
                                       active: activeTag?.id == tag.id) {
                            catalog.openCategory(tag)
                        }
                    }
                }
            }
            if !grouped.isEmpty {
                // 一级：标签分组；下面只铺当前分组，一屏就能看完，不用来回滚动。
                tagGroupBar(grouped, selectedID: selectedGroup?.id)
                if let children = selectedGroup?.children, !children.isEmpty {
                    CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(children) { child in
                            CatalogTagPill(title: child.title,
                                           active: activeTag?.id == child.id) {
                                catalog.openCategory(child)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
    }

    /// 标签面板的一级分组条：标题 + 数量，选中哪组下面就显示哪组的标签。
    private func tagGroupBar(_ groups: [CatalogCategory], selectedID: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groups) { group in
                    CatalogTagGroupChip(title: group.title,
                                        count: group.children?.count ?? 0,
                                        active: group.id == selectedID) {
                        withAnimation(settings.motion.layout) {
                            activeTagGroupID = group.id
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var currentCategoryID: String? {
        switch catalog.section {
        case .category(let id): return id
        case .rank: return catalog.categories.first(where: { $0.isRank })?.id
        default: return nil
        }
    }

    /// 分类面板展开状态按源记忆：不同站点的分类数量差别很大，互不牵连。
    private var categoryExpandedKey: String {
        "catalog.categories.expanded.v1.\(sourceID.uuidString)"
    }

    /// 网页源默认列数：4。顶栏滑杆以 4 列为基准做缩放（3…6 列）。
    private var webColumnCount: Int {
        let side = max(56, CGFloat(store.thumbSize))
        let base = max(56, store.defaultGridThumbSize)
        let ratio = Double(base) / Double(side)
        return min(6, max(3, Int((4 * ratio).rounded())))
    }

    /// 卡片间距：列与列之间始终留出明显空隙，不随卡片变大被吃掉。
    private var webGap: CGFloat {
        let side = CGFloat(store.thumbSize)
        return min(36, max(26, side * 0.12))
    }

    /// 非网页源（竖版海报）每行张数：以 5 列为基准，顶栏滑杆在此基础上缩放。
    private var posterColumnCount: Int {
        let side = max(56, CGFloat(store.thumbSize))
        let base = max(56, store.defaultGridThumbSize)
        let ratio = Double(base) / Double(side)
        return min(8, max(3, Int((5 * ratio).rounded())))
    }

    @ViewBuilder
    private func content(_ source: CatalogSource) -> some View {
        if catalog.isLoading, catalog.items.isEmpty {
            skeleton(source)
        } else if catalog.items.isEmpty {
            emptyState
        } else {
            if isCollectionIndexSection {
                collectionIndexBanner
            }
            if isRankSection, catalog.items.count >= 3 {
                rankPodium(source, items: Array(catalog.items.prefix(3)))
            }
            let rest = isRankSection ? Array(catalog.items.dropFirst(3)) : catalog.items
            if !rest.isEmpty {
                if !catalog.freshItemKeys.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                        Text("本次刷新新增 \(catalog.freshItemKeys.count) 条")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("剧集标「更新中」、单片标「刚上架」")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 2)
                }
                cardGrid(source, items: rest,
                         columns: source.kind.isWebSite ? webColumnCount : posterColumnCount)
            }
            // 本页排序只在已加载的条目里生效，明确标出来，避免误以为是全站排序。
            if let localSort = catalog.localSort, !catalog.items.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 8.5))
                    Text("按\(localSort.title)排序 · 仅当前已加载 \(catalog.items.count) 条")
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(.tertiary)
            }
            if catalog.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                        .opacity(catalog.isLoadingMore ? 1 : 0)
                    Spacer()
                }
                .frame(height: 24)
                .padding(.top, 2)
            }
        }
    }

    /// 排行榜前三名单独做成大卡：名次是最重要的信息，不该埋在网格里。
    private var isRankSection: Bool {
        if case .rank = catalog.section { return true }
        guard let id = currentCategoryID else { return false }
        return catalog.category(withID: id)?.isRank == true
    }

    /// 精选合集索引页（`set|…`）：列表里每一项是一个合集，而不是单个视频。
    private var isCollectionIndexSection: Bool {
        currentCategoryID?.hasPrefix("set|") == true
    }

    private var collectionIndexBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("精选合集")
                        .font(.system(size: 14, weight: .semibold))
                    Text(catalog.sectionTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Text("\(catalog.items.count) 个合集 · 点开后是该合集的全部视频")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.28))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 0.7)
        }
    }

    private func rankPodium(_ source: CatalogSource, items: [CatalogItem]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                RankPodiumCard(source: source,
                               item: item,
                               rank: index + 1,
                               progress: catalog.progress(sourceID: source.id, itemID: item.id),
                               durationText: durationLabel(source: source, item: item),
                               isMarkedWatched: catalog.isMarkedWatched(sourceID: source.id,
                                                                        itemID: item.id)) {
                    openInline(item)
                }
            }
        }
    }

    /// 等宽列 + 独立列间距：网格列宽由列数统一决定，
    /// 卡片内容（长标题、不同比例的封面）不会再影响列宽，间距也就不会忽大忽小。
    private func cardGrid(_ source: CatalogSource, items: [CatalogItem], columns: Int) -> some View {
        let gap = webGap
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                        count: max(1, columns)),
                         alignment: .leading,
                         spacing: 30) {
            ForEach(items) { item in
                posterCell(source, item: item)
            }
        }
        .catalogMarqueeSelection($selectedIDs)
    }

    private func posterCell(_ source: CatalogSource, item: CatalogItem) -> some View {
        CatalogPosterCell(
            source: source,
            item: item,
            progress: catalog.progress(sourceID: source.id, itemID: item.id),
            isSaving: catalog.savingItemID == item.id,
            isFresh: catalog.isFresh(sourceID: source.id, itemID: item.id),
            isFavorite: catalog.isFavorite(sourceID: source.id, itemID: item.id),
            isMarkedWatched: catalog.isMarkedWatched(sourceID: source.id, itemID: item.id),
            isSelected: selectedIDs.contains(item.id),
            onOpen: { openInline(item) },
            onOpenInBrowser: { store.openCatalogItemInBrowser(source: source, item: item) },
            onSaveVideo: { store.saveCatalogVideoToLibrary(source: source, item: item) },
            onToggleSelect: {
                if selectedIDs.contains(item.id) {
                    selectedIDs.remove(item.id)
                } else {
                    selectedIDs.insert(item.id)
                }
            },
            onHoverChange: { inside in
                guard inside else { return }
                cursorID = item.id
                adoptListFocus()
            },
            durationText: durationLabel(source: source, item: item),
            previewTarget: { await catalog.previewTarget(for: item) }
        )
        .background {
            // 把卡片矩形上报给框选：滚出屏幕的卡片会重新上报，框选始终按当前布局算。
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CatalogCardFrameKey.self,
                    value: [item.id: proxy.frame(in: .named(CatalogMarqueeSpace.name))])
            }
        }
        .onAppear {
            // 滚动到接近末尾时自动续页，不再需要「加载更多」按钮。
            guard catalog.hasMore, !catalog.isLoadingMore,
                  catalog.items.suffix(6).contains(where: { $0.id == item.id })
            else { return }
            catalog.loadMore()
        }
    }

    /// 已经播放过的条目：用进度里的时长回填卡片，站点没给时长的源也能看到片长。
    private func durationLabel(source: CatalogSource, item: CatalogItem) -> String? {
        guard let progress = catalog.progress(sourceID: source.id, itemID: item.id),
              progress.duration.isFinite, progress.duration > 20 else { return nil }
        return Self.formattedDuration(progress.duration)
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, total % 60)
        }
        return "\(minutes):" + String(format: "%02d", total % 60)
    }

    // MARK: - 稍后看

    private func favoritesList(_ source: CatalogSource) -> some View {
        LazyVStack(spacing: 9) {
            ForEach(catalog.currentFavorites) { favorite in
                CatalogFavoriteRow(
                    source: source,
                    favorite: favorite,
                    onOpen: {
                        openInline(CatalogItem(id: favorite.itemID, title: favorite.title,
                                               coverURL: favorite.coverURL,
                                               remark: favorite.remark, categoryID: nil))
                    },
                    onRemove: {
                        catalog.toggleFavorite(
                            source: source,
                            item: CatalogItem(id: favorite.itemID, title: favorite.title,
                                              coverURL: favorite.coverURL,
                                              remark: favorite.remark, categoryID: nil))
                    }
                )
            }
        }
    }

    // MARK: - 状态

    private func skeleton(_ source: CatalogSource) -> some View {
        let columns = source.kind.isWebSite ? webColumnCount : posterColumnCount
        let gap = webGap
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                        count: max(1, columns)),
                         alignment: .leading,
                         spacing: 30) {
            ForEach(0..<12, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .aspectRatio(CGFloat(source.posterRatio), contentMode: .fit)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 10)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.18),
                                                  Color.accentColor.opacity(0.02)],
                                         center: .center,
                                         startRadius: 4,
                                         endRadius: 52))
                Image(systemName: catalog.error == nil
                      ? "rectangle.on.rectangle.slash"
                      : (catalog.errorNeedsVerification ? "lock.shield" : "wifi.exclamationmark"))
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(catalog.error == nil
                                     ? Color.secondary
                                     : (catalog.errorNeedsVerification ? LumaBrand.amber
                                                                       : Color.orange))
            }
            .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text(emptyTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(emptyHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            if catalog.error != nil {
                HStack(spacing: 8) {
                    // 403 / WAF / PoW：空状态里也直接给浏览器入口。
                    if catalog.errorNeedsVerification, let source {
                        Button {
                            store.openCatalogSourceInBrowser(source)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "safari")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("在浏览器打开")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(LumaBrand.amber)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(LumaBrand.amber.opacity(0.13),
                                        in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(LumaBrand.amber.opacity(0.32), lineWidth: 0.8)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        catalog.refresh()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text("重试")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Color.accentColor.opacity(0.13),
                                    in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.8)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var emptyTitle: String {
        if catalog.error != nil {
            return catalog.errorNeedsVerification ? "站点要求先完成验证" : "内容没有加载出来"
        }
        switch catalog.section {
        case .search(_): return "没有找到相关条目"
        case .continueWatching: return "还没有续看记录"
        case .favorites: return "稍后看还是空的"
        default: return "这一页没有内容"
        }
    }

    private var emptyHint: String {
        if catalog.error != nil {
            return catalog.errorNeedsVerification
                ? "403 / 人机验证拦截了请求：先在浏览器打开站点完成验证，再回来点「重试」。"
                : "站点暂时不可达或需要验证，点「重试」再试一次。"
        }
        switch catalog.section {
        case .search(_): return "换一个关键词，或到首页看看推荐。"
        case .continueWatching: return "播放任意一集后，这里会记住上次看到的位置。"
        case .favorites: return "在详情页点「稍后看」，条目就会收在这里。"
        default: return "可以换一个分类，或点右上角刷新重试。"
        }
    }

    private func handleSourceRecovery(_ action: RecoveryAction, source: CatalogSource) {
        switch action {
        case .retry:
            catalog.reload()
        case .reauthorize, .reconfigureSource:
            store.openCatalogSourceInBrowser(source)
        case .openInBrowser(let address):
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        case .openSystemSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(url)
            }
        case .allowInsecureTLS:
            // 站点证书问题在「设置 › 网络资源」里单独处理，页面内不直接放宽。
            break
        }
    }

    private func banner(text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .padding(10)
        .background(Color.red.opacity(isError ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 离线降级提示：列表来自本地快照，标出更新时间，并给一个直接重试的入口。
    private func snapshotBanner(_ date: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("站点暂时连不上，正在显示本地快照")
                    .font(.system(size: 11.5, weight: .medium))
                Text("更新于 \(date.formatted(.dateTime.month().day().hour().minute())) · 仍可浏览与续看")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                catalog.refresh()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(LumaBrand.amber)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(LumaBrand.amber.opacity(0.13), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LumaBrand.amber.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.7)
        }
    }

    /// 403 / WAF / PoW 拦截：页面里直接给「在浏览器打开」，
    /// 用户先在系统浏览器完成人机验证，回来点重试即可。
    private func verificationBanner(source: CatalogSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("站点要求先完成验证")
                    .font(.system(size: 11.5, weight: .medium))
                Text("403 / 人机验证拦截了请求：在浏览器打开站点完成验证后，回来点「重试」。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                store.openCatalogSourceInBrowser(source)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "safari")
                        .font(.system(size: 9, weight: .semibold))
                    Text("在浏览器打开")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(LumaBrand.amber)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(LumaBrand.amber.opacity(0.13), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                catalog.refresh()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.accentColor.opacity(0.13), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LumaBrand.amber.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.7)
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("这个资源已不存在")
                .font(.system(size: 14, weight: .medium))
            Text("可能已在侧边栏移除，可从「网络资源」重新导入。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func gate(_ source: CatalogSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26))
                    .foregroundStyle(LumaBrand.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("「\(source.name)」尚未启用")
                        .font(.system(size: 15, weight: .semibold))
                    Text("资源内容由第三方站点提供，Luma 不内置、不托管内容与解析参数。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text("启用后只在本机展示与播放，不会把条目写入照片图库索引，也不会参与人物、地图与场景分析。请自行确认来源合规与内容分级。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("启用资源") {
                    catalog.setEnabled(source.id, enabled: true)
                }
                .buttonStyle(.borderedProminent)
                Button("打开源页面") {
                    if let url = URL(string: source.baseURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("移除资源", role: .destructive) {
                    catalog.remove(source.id)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.top, 24)
    }
}

// MARK: - 分类胶囊 / 频道 tab

/// 一级范围：舱体里的滑动高亮胶囊，切换时高亮块在舱内滑过去。
/// 二级频道：文字 + 渐变下划线，和上面的胶囊拉开视觉差异，不会两排长得一样。
struct CatalogChip: View {
    enum Style {
        case tray
        case underline
    }

    let title: String
    var active: Bool = false
    var style: Style = .tray
    var namespace: Namespace.ID?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            switch style {
            case .tray: tray
            case .underline: underline
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.20), value: active)
        .help(title)
    }

    // MARK: 一级

    private var tray: some View {
        Text(title)
            .font(.system(size: 12, weight: active ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 6.5)
            .background {
                if active {
                    activePill
                } else if hovering {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Capsule(style: .continuous))
    }

    /// 选中块：强调色渐变 + 顶部高光 + 光晕，靠 matchedGeometry 在舱内滑动。
    private var activePill: some View {
        let pill = Capsule(style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor,
                                          Color.accentColor.opacity(0.72)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .blendMode(.plusLighter)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
            }
            .shadow(color: Color.accentColor.opacity(0.42), radius: 10, y: 3)
        return Group {
            if let namespace {
                pill.matchedGeometryEffect(id: "catalog.chip.tray", in: namespace)
            } else {
                pill
            }
        }
    }

    // MARK: 二级

    private var underline: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? Color.primary
                                        : (hovering ? Color.primary.opacity(0.9)
                                                    : Color.secondary.opacity(0.72)))
            underlineBar
        }
        .padding(.horizontal, 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var underlineBar: some View {
        if active {
            let bar = Capsule(style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor,
                                              Color.accentColor.opacity(0.12)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 2.5)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1)
            if let namespace {
                bar.matchedGeometryEffect(id: "catalog.chip.underline", in: namespace)
            } else {
                bar
            }
        } else {
            Color.clear.frame(height: 2.5)
        }
    }
}

/// 热门标签面板的一级分组：标题 + 标签数，选中项用强调色，下方只显示这一组的标签。
struct CatalogTagGroupChip: View {
    let title: String
    let count: Int
    let active: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .opacity(active ? 0.85 : 0.6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.secondary))
            .background {
                Capsule(style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(
                                colors: [Color.accentColor,
                                         Color.accentColor.opacity(0.82)],
                                startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.22)
                                         : Color.primary.opacity(0.07),
                                  lineWidth: 0.7)
            }
            .shadow(color: active ? Color.accentColor.opacity(0.30) : .clear,
                    radius: 6, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(title)（\(count) 个标签）")
    }
}

/// 平铺用的标签胶囊：宽度随文字，放不下自动换行；字号比分组标签更大，一眼看清。
struct CatalogTagPill: View {
    let title: String
    let active: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("#")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(active ? Color.white.opacity(0.70)
                                            : Color.accentColor.opacity(0.80))
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.primary.opacity(0.92)))
            .background {
                Capsule(style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor,
                                                                  Color.accentColor.opacity(0.82)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.11 : 0.06)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.22)
                                         : Color.primary.opacity(0.07),
                                  lineWidth: 0.7)
            }
            .shadow(color: active ? Color.accentColor.opacity(0.28) : .clear, radius: 6, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
    }
}

/// 二级频道数量很多时的紧凑胶囊：放不下自动换行，一屏看全。
struct CatalogChannelPill: View {
    let title: String
    let active: Bool
    /// 常用分类：标题前加一枚小图钉。
    var pinned: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(active ? Color.white.opacity(0.9)
                                                : Color.accentColor.opacity(0.75))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .foregroundStyle(active ? Color.white
                                        : (hovering ? Color.primary : Color.primary.opacity(0.78)))
                .background {
                    Capsule(style: .continuous)
                        .fill(active
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [Color.accentColor,
                                             Color.accentColor.opacity(0.82)],
                                    startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(active ? Color.white.opacity(0.22)
                                             : Color.primary.opacity(0.07),
                                      lineWidth: 0.7)
                }
                .shadow(color: active ? Color.accentColor.opacity(0.30) : .clear,
                        radius: 6, y: 2)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
    }
}

/// 左对齐的流式布局：一行放不下就换到下一行。
struct CatalogFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? 640
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + lineSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 稍后看 列表行

/// 稍后看行：整行点开详情，右侧移除按钮在悬停时更明显。
struct CatalogFavoriteRow: View {
    let source: CatalogSource
    let favorite: CatalogFavorite
    var onOpen: () -> Void
    var onRemove: () -> Void

    @State private var hovering = false
    @StateObject private var coverTint = CatalogCoverTint()

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    CatalogArtworkImage(source: source, urlString: favorite.coverURL, cornerRadius: 9)
                        .frame(width: 58, height: 86)
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(favorite.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        if !favorite.remark.isEmpty {
                            Text(favorite.remark)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("加入于 \(favorite.addedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "bookmark.slash")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering ? Color.secondary : Color.secondary.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("从稍后看移除")
            .accessibilityLabel("从稍后看移除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background { card }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
            if inside { coverTint.load(source: source, urlString: favorite.coverURL) }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.075 : 0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(hovering ? (coverTint.color.map { $0.opacity(0.55) }
                                            ?? Color.primary.opacity(0.16))
                                           : Color.primary.opacity(0.05),
                                  lineWidth: hovering ? 1.0 : 0.7)
            }
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 12, y: 4)
    }
}

// MARK: - 顶栏控制台
//
// 页面头部的「首页 / 黄果短剧 · huangguoai.io / 刷新 / 在本资源内搜索」整体并入窗口工具栏，
// 与返回、标题、缩放共用同一层 chrome；内容区只保留 chips 与网格（AGENTS.md §17）。

/// 工具栏最左的返回：带文字的强调色胶囊，悬停整体点亮，
/// 尺寸与顶栏其它舱体同一档，避免只留一个孤立的小箭头。
struct CatalogToolbarBackButton: View {
    var title: String = "返回"
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(hovering ? Color.white : Color.accentColor)
            .padding(.leading, 10)
            .padding(.trailing, 13)
            .frame(height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(hovering
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor,
                                                                  Color.accentColor.opacity(0.84)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [Color.accentColor.opacity(0.20),
                                                                  Color.accentColor.opacity(0.08)],
                                                         startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                // 顶部高光：和一级分类的选中胶囊同一套质感。
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(hovering ? 0.24 : 0.16), .clear],
                                         startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(hovering ? Color.white.opacity(0.30)
                                           : Color.accentColor.opacity(0.34),
                                  lineWidth: 0.8)
            }
            .shadow(color: Color.accentColor.opacity(hovering ? 0.38 : 0.16),
                    radius: hovering ? 9 : 4, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .keyboardShortcut(.cancelAction)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 中区信息：当前分类可点开菜单直接跳转（与左侧菜单同一份分类），右侧是刷新。
struct CatalogToolbarConsole: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let item = catalog.inlineDetailItem {
                // 详情页的返回直接融进同一枚胶囊：返回 · 条目标题 · 站点 · 播放，
                // 内容区不再单独浮一个「返回」按钮（顶栏融合 §17）。
                detailConsole(item)
            } else {
                browseConsole
            }
        }
        .onChange(of: catalog.searchFocusToken) { _, _ in
            focused = true
        }
        .onChange(of: catalog.section) { _, newValue in
            if case .search(let keyword) = newValue { text = keyword }
        }
        .onAppear {
            if case .search(let keyword) = catalog.section { text = keyword }
        }
    }

    /// 胶囊舱体的统一外壳：两种模式共用同一层材质与描边，切换时不会「换了个控件」。
    private func consoleChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 5.5)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
    }

    /// 详情模式：返回在窗口工具栏最左侧（与视频播放器一致），
    /// 这枚胶囊只承担「当前条目 · 站点 · 播放」。
    private func detailConsole(_ item: CatalogItem) -> some View {
        let tint = catalog.selectedSource?.kind.sidebarTint ?? Color.accentColor
        return consoleChrome {
            HStack(spacing: 10) {
                Image(systemName: catalog.selectedSource?.kind.sidebarSymbol ?? "play.rectangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)

                if let host = catalog.selectedSource?.host, !host.isEmpty {
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let episode = firstEpisode(of: item) {
                    divider
                    Button {
                        catalog.play(item: item, episode: episode, seconds: 0)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(episode.index > 1 ? "第 \(episode.index) 集" : "播放")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.accentColor, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("从第 \(episode.index) 集开始播放")
                }
            }
        }
    }

    /// 详情已加载且是同一个条目时，工具栏才有「播放」入口。
    private func firstEpisode(of item: CatalogItem) -> CatalogEpisode? {
        guard catalog.detail?.item.id == item.id else { return nil }
        return catalog.detail?.episodes.first
    }

    /// 浏览模式：分类 · 站点 · 排序 · 站内搜索 · 刷新。
    private var browseConsole: some View {
        consoleChrome {
            HStack(spacing: 11) {
                Menu {
                    menu
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: sectionIcon)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(catalog.sectionTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换分类（与左侧菜单同步）")

                if let host = catalog.selectedSource?.host, !host.isEmpty {
                    Text(host)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                divider
                sortMenu
                divider
                searchField
                divider

                Button {
                    catalog.refresh()
                } label: {
                    if catalog.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .disabled(catalog.isLoading)
                .help("刷新当前分类")
                .accessibilityLabel("刷新")
            }
        }
    }

    /// 排序放在窗口工具栏：站点支持的排序 + 本页排序，符合顶栏融合规范（§17）。
    private var sortMenu: some View {
        Menu {
            Section("站点排序") {
                ForEach(catalog.supportedSorts) { option in
                    Button {
                        catalog.setSort(option)
                    } label: {
                        if catalog.sort == option, catalog.localSort == nil {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
            Section("本页排序") {
                ForEach(CatalogLocalSort.allCases) { option in
                    Button {
                        catalog.setLocalSort(option)
                    } label: {
                        if catalog.localSort == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(shortSortTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(catalog.localSort == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(catalog.localSort == nil
              ? "排序：\(catalog.sort.title)"
              : "本页按\(catalog.localSort?.title ?? "")排序，仅作用于已加载的 \(catalog.items.count) 条")
    }

    private var shortSortTitle: String {
        if let localSort = catalog.localSort { return "本页·\(localSort.title)" }
        switch catalog.sort {
        case .latest: return "最新"
        case .hot: return "热播"
        case .newest: return "上架"
        case .collect: return "收藏"
        }
    }

    /// 站内搜索：只搜当前这个资源，提示语直接带上源名，避免和图库搜索混淆。
    private var searchField: some View {
        HStack(spacing: 5) {
            Button {
                focused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(focused ? Color.accentColor : Color.secondary)
                    .frame(width: 13, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(searchPlaceholder)

            TextField(searchPlaceholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit {
                    catalog.search(text)
                    focused = false
                }
                .onExitCommand {
                    if text.isEmpty {
                        focused = false
                    } else {
                        text = ""
                    }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: 24)
        .background(Color.primary.opacity(focused ? 0.09 : 0.055),
                    in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.55)
                                      : Color.primary.opacity(0.06),
                              lineWidth: 0.6)
        }
    }

    private var searchPlaceholder: String {
        "搜索\(catalog.selectedSource?.name ?? "本资源")"
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
    }

    private var sectionIcon: String {
        switch catalog.section {
        case .home: return "house"
        case .rank: return "chart.bar.fill"
        case .search: return "magnifyingglass"
        case .continueWatching: return "clock.arrow.circlepath"
        case .favorites: return "bookmark"
        case .category: return "square.grid.2x2"
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button {
            catalog.openHome()
        } label: {
            Label("首页", systemImage: "house")
        }
        if !catalog.categories.isEmpty {
            Divider()
            ForEach(catalog.categories) { category in
                if let children = category.children, !children.isEmpty {
                    Menu(category.title) {
                        Button("全部") { open(category) }
                        ForEach(children) { child in
                            Button(child.title) { catalog.openCategory(child) }
                        }
                    }
                } else {
                    Button {
                        open(category)
                    } label: {
                        Label(category.title,
                              systemImage: category.isRank ? "chart.bar.fill" : "square.grid.2x2")
                    }
                }
            }
        }
        if !catalog.currentFavorites.isEmpty {
            Divider()
            Button {
                catalog.openFavorites()
            } label: {
                Label("稍后看", systemImage: "bookmark")
            }
        }
    }

    private func open(_ category: CatalogCategory) {
        if category.isRank {
            catalog.openRank()
        } else {
            catalog.openCategory(category)
        }
    }
}

// MARK: - 海报

struct CatalogPosterCell: View {
    let source: CatalogSource
    let item: CatalogItem
    let progress: CatalogProgress?
    /// 正在把这个条目下载到图库。
    var isSaving: Bool = false
    /// 本次刷新才出现（上次缓存里没有）：右下角打「刚上架」。
    var isFresh: Bool = false
    /// 已经在「稍后看」里：左上角挂书签角标。
    var isFavorite: Bool = false
    /// 手动标记已看：没有播放进度也显示「已看」角标。
    var isMarkedWatched: Bool = false
    /// ⌘ 多选中的条目：画品牌色描边 + 勾选角标。
    var isSelected: Bool = false
    var onOpen: () -> Void
    var onOpenInBrowser: () -> Void = {}
    var onSaveVideo: () -> Void = {}
    /// ⌘ 点击切换多选。
    var onToggleSelect: () -> Void = {}
    /// 悬停进出时通知外层（用于把键盘光标跟着鼠标走）。
    var onHoverChange: ((Bool) -> Void)?
    /// 已播放过的条目用进度里的时长回填；站点没给时长时也能显示片长。
    var durationText: String? = nil
    /// 悬停 0.7 秒后才去解析流：避免扫过网格时给站点打一串请求。
    var previewTarget: (() async -> CatalogPreviewTarget?)?

    @State private var isHovering = false
    @State private var previewURL: URL?
    @State private var previewHeaders: [String: String] = [:]
    @State private var previewTask: Task<Void, Never>?
    @State private var previewHandle = VideoPreviewHandle()
    /// 正在解析流地址：悬停后先转圈，避免看起来「什么也没发生」。
    @State private var isPreparingPreview = false
    /// 「刚上架」的呼吸高亮：让新条目在整片网格里第一眼就能被扫到。
    @State private var freshPulse = false
    /// 封面主色：悬停时取一次，描边与光晕跟着封面色系走。
    @StateObject private var coverTint = CatalogCoverTint()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artwork
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(1.5)
                .foregroundStyle(isHovering ? Color.primary : Color.primary.opacity(0.86))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // 固定两行高度：同一行的标题基线一致，网格不会因为长短标题参差。
                .frame(height: 36, alignment: .topLeading)
                .help(item.title)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
            onHoverChange?(hovering)
            if hovering {
                coverTint.load(source: source, urlString: item.coverURL)
                startPreview()
            } else {
                stopPreview()
            }
        }
        .onDisappear { stopPreview() }
        .onChange(of: item.id) { _, _ in stopPreview() }
        .onTapGesture {
            // ⌘ 点击加入批量选择；普通点击仍然打开详情。
            if NSEvent.modifierFlags.contains(.command) {
                withAnimation(.easeOut(duration: 0.14)) { onToggleSelect() }
            } else {
                onOpen()
            }
        }
        .contextMenu {
            CatalogPlaylistMenu(source: source, item: item)
            Button("在浏览器中打开原始页") { onOpenInBrowser() }
            Button(isSaving ? "正在保存…" : "保存视频到图库") { onSaveVideo() }
                .disabled(isSaving)
        }
    }

    // MARK: - 角标

    /// 左上角角标栈：预览、合集、稍后看、观看状态依次往下排，互不遮挡。
    private var leadingBadges: some View {
        VStack(alignment: .leading, spacing: 5) {
            if previewURL != nil {
                HStack(spacing: 3) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 7, weight: .bold))
                    Text("预览")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.5), in: Capsule(style: .continuous))
                .transition(.opacity)
            }
            if isCollectionSet {
                // 精选合集索引里的卡片：和普通视频区分开。
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 7.5, weight: .bold))
                    Text("合集")
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor,
                                                      Color.accentColor.opacity(0.78)],
                                             startPoint: .top, endPoint: .bottom))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.26), lineWidth: 0.5)
                }
                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
            }
            if isFavorite {
                CatalogMiniBadge(symbol: "bookmark.fill", title: "稍后看", tint: LumaBrand.cyan)
            }
            // 合集索引本身没有播放进度，不做未看 / 已看标记。
            if !isCollectionSet { watchBadge }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 本地观看状态：没记录 / 看了一半 / 看完，同一时刻只出现一个角标。
    private enum WatchState {
        case unseen
        case partial(Double)
        case watched
    }

    private var watchState: WatchState {
        guard let progress, progress.fraction > 0.01 else { return .unseen }
        return progress.fraction >= 0.97 ? .watched : .partial(progress.fraction)
    }

    private var isWatched: Bool {
        if isMarkedWatched { return true }
        if case .watched = watchState { return true }
        return false
    }

    @ViewBuilder
    private var watchBadge: some View {
        if isMarkedWatched {
            CatalogMiniBadge(symbol: "checkmark.circle.fill", title: "已看",
                             tint: LumaBrand.mint)
        } else {
            switch watchState {
            case .unseen:
                CatalogMiniBadge(symbol: "circle.dashed", title: "未看",
                                 tint: .white.opacity(0.6))
            case .partial(let fraction):
                CatalogMiniBadge(symbol: "circle.lefthalf.filled",
                                 title: "看至 \(Int((fraction * 100).rounded()))%",
                                 tint: LumaBrand.amber)
            case .watched:
                CatalogMiniBadge(symbol: "checkmark.circle.fill", title: "已看",
                                 tint: LumaBrand.mint)
            }
        }
    }

    private func startPreview() {
        guard previewURL == nil, let previewTarget else { return }
        previewTask?.cancel()
        isPreparingPreview = true
        previewTask = Task { @MainActor in
            // 停留够久再解析：鼠标扫过网格时不该触发请求。
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            // 解析可能撞上并发排队或站点抖动：鼠标还停着就再试两次。
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard !Task.isCancelled else { return }
                }
                if let target = await previewTarget() {
                    guard !Task.isCancelled else { return }
                    isPreparingPreview = false
                    withAnimation(.easeOut(duration: 0.25)) {
                        previewHeaders = target.headers
                        previewURL = target.url
                    }
                    return
                }
                guard !Task.isCancelled else { return }
            }
            isPreparingPreview = false
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
        guard previewURL != nil || !previewHeaders.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            previewURL = nil
            previewHeaders = [:]
        }
    }

    private var artwork: some View {
        // 先用 Color.clear 定住 2:3 / 16:9 的版面，再把封面铺进 overlay：
        // 直接把 aspectRatio 压在 scaledToFill 的图片上，图片会按自身像素撑开，
        // 越过网格列宽后相邻卡片就会贴在一起。
        Color.clear
            .aspectRatio(CGFloat(source.posterRatio), contentMode: .fit)
            .overlay {
                ZStack(alignment: .topTrailing) {
                    // 画面层（封面 / 预览流 / 暗角 / 保存遮罩）单独裁圆角；
                    // 文字与角标画在裁切外层，贴在四角时才不会被圆角吃掉一截。
                    ZStack(alignment: .topLeading) {
                        CatalogArtworkImage(source: source, urlString: item.coverURL, cornerRadius: 14)
                            // 已看过的条目压暗，和「已看」角标一起把二刷列表的噪音降下去。
                            .opacity(isWatched && !isHovering ? 0.62 : 1)

                        // 悬停预览：静音循环播放真实流，移开立即卸载解码器。
                        if let previewURL {
                            HoverVideoSurface(url: previewURL,
                                              headers: previewHeaders,
                                              handle: previewHandle) { _ in }
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }

                        // 底部暗角：让集数信息在浅色封面上也读得清。
                        LinearGradient(colors: [.clear, .clear, .black.opacity(0.74)],
                                       startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)

                        if isSaving {
                            ZStack {
                                Color.black.opacity(0.48)
                                VStack(spacing: 7) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                    Text("保存中")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }

                        // 观看进度条贴着底边，跟画面一起被圆角裁切才自然。
                        // 已看完整条时不再画满格进度条，改由「已看」角标说明状态。
                        if let progress, progress.fraction > 0.01, !isWatched {
                            VStack {
                                Spacer()
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.black.opacity(0.4))
                                        Capsule().fill(LumaBrand.amber)
                                            .frame(width: max(3, proxy.size.width * progress.fraction))
                                    }
                                }
                                .frame(height: 3.5)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // 左上角角标栈：预览、合集、稍后看、观看状态依次往下排，互不遮挡。
                    leadingBadges

            if isSelected {
                // 选中标记放在右上角，替代评分角标，避免两个角标叠在一起。
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 1)
                    .padding(11)
            } else if let score = scoreText {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(LumaBrand.amber)
                    Text(score)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.48), in: Capsule(style: .continuous))
                .padding(11)
            }

            if isFresh {
                CatalogFreshBadge(kind: episodeCount > 1 ? .updating : .new)
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }

            if let info = infoText {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Text(info)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    // 右下角有「刚上架」时给文字让出位置，两者不再叠在一起。
                    .padding(.leading, 11)
                    .padding(.trailing, isFresh ? 80 : 11)
                    .padding(.bottom, 10)
                }
            }

            if isHovering, previewURL == nil {
                if isPreparingPreview {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.95), in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.86)))
                }
            }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderStyle,
                                  lineWidth: isHovering ? 1.8 : (isFresh ? 1.2 : 0.8))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .shadow(color: isFresh ? LumaBrand.coral.opacity(freshPulse ? 0.34 : 0.12)
                                   : .black.opacity(isHovering ? 0.28 : 0.12),
                    radius: isFresh ? (freshPulse ? 12 : 6) : (isHovering ? 16 : 8),
                    y: isHovering ? 8 : 3)
            // 悬停再补一层封面主色光晕，让卡片和画面融在一起。
            .shadow(color: isHovering && !isFresh ? hoverTint.opacity(0.28) : .clear,
                    radius: 18, y: 5)
            // 悬停只做很轻的上浮：放大太多会让相邻卡片看起来挤在一起。
            .scaleEffect(isHovering ? 1.008 : 1)
            .onAppear {
                guard isFresh, !freshPulse else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    freshPulse = true
                }
            }
    }

    /// 封面描边：悬停用封面主色 → 刚上架呼吸渐变 → 常态细描边。
    private var borderStyle: AnyShapeStyle {
        if isHovering {
            // 主色还没取回来时保持中性描边，不要先闪品牌色再过渡到暗色。
            if let tint = coverTint.color {
                return AnyShapeStyle(tint.opacity(0.95))
            }
            return AnyShapeStyle(Color.primary.opacity(0.22))
        }
        if isFresh {
            return AnyShapeStyle(LumaBrand.gradient.opacity(freshPulse ? 1 : 0.5))
        }
        return AnyShapeStyle(Color.primary.opacity(0.10))
    }

    /// 悬停光晕：只在使用封面主色后才出现，取色前后视觉连续。
    private var hoverTint: Color { coverTint.color ?? .clear }

    /// 精选合集索引里的条目：id 以 `set|` 开头。
    private var isCollectionSet: Bool {
        item.id.hasPrefix("set|")
    }

    /// 「更新至 86 集 · 8.4 分」拆成两处展示：集数压在海报底部，评分做成右上角小胶囊。
    private var remarkParts: [String] {
        item.remark
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var scoreText: String? {
        guard let raw = remarkParts.last(where: { $0.contains("分") }) else { return nil }
        let value = raw.replacingOccurrences(of: "分", with: "")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private var infoText: String? {
        switch (remarkParts.first(where: { !$0.contains("分") }), durationText) {
        case let (info?, duration?): return "\(info) · \(duration)"
        case let (info?, nil): return info
        case let (nil, duration?): return duration
        default: return nil
        }
    }

    /// 备注里的集数（`更新至 10 集` / `全 12 集`）；单片返回 0。
    /// 多集条目不叫「刚上架」，改用「更新中」。
    private var episodeCount: Int {
        guard let range = item.remark.range(of: "\\d+\\s*集", options: .regularExpression) else {
            return 0
        }
        let digits = item.remark[range].filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

/// 海报小角标：图标 + 短文案，半透明黑底，压在封面上也能读清。
/// 用于「未看 / 看至 N% / 已看 / 稍后看」这些本地状态。
private struct CatalogMiniBadge: View {
    let symbol: String
    let title: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 5.5)
        .padding(.vertical, 2.5)
        .background(.black.opacity(0.5), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
    }
}

/// 「刚上架 / 更新中」角标：本次刷新才出现、上次缓存里没有的条目。
/// 单片叫「刚上架」，多集叫「更新中」；黑底 + 品牌渐变描边 + 呼吸小灯。
private struct CatalogFreshBadge: View {
    enum Kind {
        case new
        case updating

        var title: String {
            switch self {
            case .new: return "刚上架"
            case .updating: return "更新中"
            }
        }

        var symbol: String {
            switch self {
            case .new: return "sparkles"
            case .updating: return "arrow.triangle.2.circlepath"
            }
        }

        var tint: Color {
            switch self {
            case .new: return LumaBrand.amber
            case .updating: return LumaBrand.cyan
            }
        }
    }

    var kind: Kind = .new

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(kind.tint)
            Text(kind.title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white)
            Circle()
                .fill(LumaBrand.mint)
                .frame(width: 3, height: 3)
                .scaleEffect(pulsing ? 1.7 : 0.7)
                .opacity(pulsing ? 0.35 : 1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(.black.opacity(0.58), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(LumaBrand.gradient, lineWidth: 1)
        }
        .shadow(color: LumaBrand.coral.opacity(0.4), radius: 7, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - 排行榜前三

private struct RankPodiumCard: View {
    let source: CatalogSource
    let item: CatalogItem
    let rank: Int
    let progress: CatalogProgress?
    var durationText: String? = nil
    var isMarkedWatched: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @StateObject private var coverTint = CatalogCoverTint()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .frame(height: 170)
                    .overlay {
                        CatalogArtworkImage(source: source, urlString: item.coverURL, cornerRadius: 14)
                    }
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.66)],
                                       startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .overlay(alignment: .topLeading) {
                        rankBadge
                            .padding(11)
                    }
                    .overlay(alignment: .topTrailing) {
                        // 展台卡片只挂「已看」：名次角标已经占了左上角。
                        if isWatched {
                            CatalogMiniBadge(symbol: "checkmark.circle.fill", title: "已看",
                                             tint: LumaBrand.mint)
                                .padding(9)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress, progress.fraction > 0.01 {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.black.opacity(0.45))
                                    Capsule().fill(LumaBrand.amber)
                                        .frame(width: max(3, proxy.size.width * progress.fraction))
                                }
                            }
                            .frame(height: 3.5)
                            .padding(.horizontal, 9)
                            .padding(.bottom, 7)
                        }
                    }
                    .overlay {
                        if hovering {
                            ZStack {
                                Color.black.opacity(0.16)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.black.opacity(0.82))
                                    .frame(width: 36, height: 36)
                                    .background(.white.opacity(0.95), in: Circle())
                                    .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(hovering ? (coverTint.color.map { $0.opacity(0.9) }
                                                    ?? Color.primary.opacity(0.22))
                                                  : Color.primary.opacity(0.10),
                                          lineWidth: hovering ? 1.7 : 0.8)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.26 : 0.12),
                            radius: hovering ? 16 : 8, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.008 : 1)

                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)

                HStack(spacing: 5) {
                    Circle()
                        .fill(source.kind.sidebarTint)
                        .frame(width: 4.5, height: 4.5)
                    Text(source.name)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if let info = podiumInfoText {
                        Text(info)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside { coverTint.load(source: source, urlString: item.coverURL) }
        }
        .help(item.title)
    }

    /// 备注与进度时长拼成一行；两者都没有时整行留空，只显示来源。
    private var podiumInfoText: String? {
        let parts = [item.remark, durationText ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var isWatched: Bool {
        if isMarkedWatched { return true }
        guard let progress, progress.fraction > 0.01 else { return false }
        return progress.fraction >= 0.97
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rank == 1
                          ? AnyShapeStyle(LinearGradient(colors: [LumaBrand.amber,
                                                                  LumaBrand.amber.opacity(0.7)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.black.opacity(0.52)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.24), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.24), radius: 4, y: 1)
    }
}

// MARK: - 封面

struct CatalogArtworkImage: View {
    enum Quality {
        /// 网格 / 轨道：只读缓存的 320px 缩略图，不再二次拉全尺寸。
        case thumbnail
        /// 详情页大图：需要全尺寸封面。
        case full
    }

    let source: CatalogSource
    let urlString: String
    var cornerRadius: CGFloat = 10
    /// 预览大图时用 fit（完整显示），网格封面用 fill（铺满裁切）。
    var fit: Bool = false
    var quality: Quality = .thumbnail

    @State private var image: NSImage?

    private var quickKey: String {
        CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: true).path
    }

    private var fullKey: String {
        CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: false).path
    }

    init(source: CatalogSource, urlString: String,
         cornerRadius: CGFloat = 10, fit: Bool = false,
         quality: Quality = .thumbnail) {
        self.source = source
        self.urlString = urlString
        self.cornerRadius = cornerRadius
        self.fit = fit
        self.quality = quality
        // 同一会话里切来切去直接命中内存，第一帧就是封面，不再闪占位图。
        guard !urlString.isEmpty else {
            _image = State(initialValue: nil)
            return
        }
        let quick = CatalogArtworkMemory.shared.image(
            for: CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: true).path)
        let full = quality == .full
            ? CatalogArtworkMemory.shared.image(
                for: CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: false).path)
            : nil
        _image = State(initialValue: full ?? quick)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.22, green: 0.19, blue: 0.17),
                                    Color(red: 0.32, green: 0.25, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                if fit {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    // scaledToFill 会按原图比例把自身撑得比卡片还宽；
                    // 直接放进 ZStack 会让整个封面层超出网格列宽（相邻卡片吃掉间距、
                    // 四角角标也被推到卡片外）。用 Color.clear 收住尺寸再画到 overlay 上。
                    Color.clear
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                }
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            guard !urlString.isEmpty else { return }
            // 1) 缩略图：内存 → 磁盘/网络。网格到这一步就够，不再等大图。
            if let cached = CatalogArtworkMemory.shared.image(for: quickKey) {
                image = cached
            } else if let quick = await CatalogArtworkCache.shared.image(source: source,
                                                                         urlString: urlString,
                                                                         quick: true) {
                CatalogArtworkMemory.shared.store(quick, for: quickKey)
                withAnimation(.easeOut(duration: 0.16)) { image = quick }
            }
            // 2) 详情页才补全尺寸；网格保持缩略图，省一次 900px 解码与替换。
            guard quality == .full else { return }
            if let cached = CatalogArtworkMemory.shared.image(for: fullKey) {
                image = cached
            } else if let full = await CatalogArtworkCache.shared.image(source: source,
                                                                        urlString: urlString,
                                                                        quick: false) {
                CatalogArtworkMemory.shared.store(full, for: fullKey)
                withAnimation(.easeOut(duration: 0.16)) { image = full }
            }
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let value = Int(seconds.rounded())
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
