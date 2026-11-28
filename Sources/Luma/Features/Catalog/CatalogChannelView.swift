import AppKit
import SwiftUI
import LumaContentCore

enum CatalogScrollSpace {
    static let name = "catalog-channel-scroll"
}

/// 框选用的命名坐标系：网格单元格把自身矩形上报到这里，鼠标位置也按它换算。
enum CatalogMarqueeSpace {
    static let name = "catalog-channel-marquee"
}

struct CatalogCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 实体卡片墙（出镜人物 / 创作者）里每张卡的位置：悬停档案据此贴着卡片浮出。
struct CatalogEntityCardAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 网格空白处拖动框选；从卡片内部按下时让位给卡片自己的点击 / 预览。
struct CatalogMarqueeModifier: ViewModifier {
    @Binding var selection: Set<String>

    @State private var frames: [String: CGRect] = [:]
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var base: Set<String> = []
    @State private var blockedStart: CGPoint?

    var marqueeRect: CGRect? {
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
    var blankTapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(CatalogMarqueeSpace.name))
            .onEnded { value in
                guard !frames.values.contains(where: { $0.contains(value.location) }) else { return }
                selection.removeAll()
            }
    }

    @ViewBuilder
    var marqueeOverlay: some View {
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

    var marqueeGesture: some Gesture {
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

extension View {
    func catalogMarqueeSelection(_ selection: Binding<Set<String>>) -> some View {
        modifier(CatalogMarqueeModifier(selection: selection))
    }
}

// MARK: - 网络资源频道页

struct CatalogChannelView: View {
    let sourceID: UUID

    @Environment(CatalogBrowserModel.self) private var catalog
    /// 顶栏的放大 / 缩小滑杆写的是这个 thumbSize，内容区必须跟着它一起缩放。
    @Environment(LibraryStore.self) private var store

    /// 批量操作：⌘ 点选中的条目 id，底部浮出操作条。
    @State private var selectedIDs: Set<String> = []
    /// 键盘导航的光标：鼠标悬停到哪张卡，方向键就从哪张继续走。
    @State private var cursorID: String?
    @FocusState private var listFocused: Bool
    /// 一级范围的高亮胶囊与二级频道的下划线在这两个命名空间里滑动。
    @Namespace private var chipNamespace
    /// 「全部分类」标签墙：搜索词与当前页（客户端分页，站点标签上千个）。
    @State private var tagWallQuery = ""
    @State private var tagWallPageIndex = 0
    /// 标签墙的语义分组（人物 / 身材 / 衣着 / 场景 / 玩法 / 属性 / 年份 / 其他）。
    @State private var tagBuckets: [CatalogTagBucket] = []
    @State private var tagBucketByID: [String: String] = [:]
    @State private var tagWallBucket: String?
    /// 标签墙里命中星图的名字（人物 / 品牌两组）：标签 id → 星图档案。
    @State private var tagWallRoster: [String: CatalogRosterEntry] = [:]
    /// 标签墙上悬停的是哪个标签：决定浮出谁的星图档案。
    @State private var tagWallHoverID: String?
    @State private var tagWallHoverTask: Task<Void, Never>?
    /// 实体卡片墙（出镜人物 / 创作者）命中星图的档案：item id → 星图档案。
    @State private var entityAtlas: [String: CatalogRosterEntry] = [:]
    /// 实体卡片悬停的是哪一张：决定浮窗显示谁的档案。
    @State private var entityHoverID: String?
    /// 博文归档：标题搜索与月份筛选（数据一次取回，纯本地过滤）。
    @State private var archiveQuery = ""
    @State private var archiveMonth: String?

    var source: CatalogSource? {
        // 频道页只服务网络资源；影视源由网络影院自己的浏览页承载。
        catalog.resourceSources.first(where: { $0.id == sourceID })
    }

    // MARK: - 实体卡片墙 × 星图

    /// 出镜人物 → 女优名册，创作者 → 片商名册；角色 / 作品系列不参与匹配。
    var explicitEntityRosterKind: CatalogRosterKind? {
        guard AtlasCatalogLibrary.shared.isLoaded else { return nil }
        switch catalog.activeTopCategory?.id {
        case "entities/performers": return .people
        case "entities/creators": return .studios
        default: return nil
        }
    }

    /// 专题 / 合集卡片墙：卡片标题常写成「森萝财团精选」「布丁大法写真合集」，
    /// 剥掉装饰词后能命中人物 / 品牌时，也挂星图档案。
    /// 91porna 的「精选合集 · 人物合集 / 品牌合集」卡片是 `set|…`，同样算合集卡片。
    var isCollectionCardWall: Bool {
        catalog.items.contains { $0.isCollectionCard || $0.id.hasPrefix("set|") }
    }

    /// 卡片集合变化（换栏目 / 翻页 / 刷新）时重新匹配一次。
    var entityLoadKey: String {
        "\(catalog.activeTopCategory?.id ?? "")|\(catalog.items.count)|\(catalog.items.first?.id ?? "")"
    }

    /// 用和名册同一套毫秒级匹配把卡片标题换成星图档案，未命中的卡片不挂角标。
    func loadEntityAtlas() async {
        guard AtlasCatalogLibrary.shared.isLoaded, !catalog.items.isEmpty else {
            entityAtlas = [:]
            return
        }
        let categories = catalog.items.map { CatalogCategory(id: $0.id, title: $0.title) }
        let entries: [CatalogRosterEntry]
        if let explicit = explicitEntityRosterKind {
            entries = await CatalogAtlasMatcher.entries(kind: explicit, children: categories)
        } else if isCollectionCardWall {
            // 专题 / 合集卡片：人物与品牌混着写，逐个标题两种都试。
            entries = await CatalogAtlasMatcher.mixedEntries(children: categories)
        } else {
            entityAtlas = [:]
            return
        }
        guard !Task.isCancelled else { return }
        var map: [String: CatalogRosterEntry] = [:]
        for entry in entries where entry.isMatched { map[entry.id] = entry }
        entityAtlas = map
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
                .environment(catalog)
                .transition(.opacity)
            } else {
                channelList
            }
        }
        .task(id: sourceID) {
            // 影视源不在这里浏览，直接跳过，不把它的分类装进资源页状态。
            guard source != nil else { return }
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
            applyDefaultCardSizeIfNeeded()
            if let source {
                // 侧边栏分类图标用分类首图：先读缓存，缺的再后台补一次。
                catalog.prefetchCategoryThumbs(for: source)
                // 列表可能直接来自缓存（不会再触发 isLoading）：进入时先预热首屏封面。
                if !catalog.items.isEmpty {
                    catalog.prefetchCovers(for: Array(catalog.items.prefix(12)), source: source)
                }
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

    var channelList: some View {
        ScrollViewReader { proxy in
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
                // 出镜人物 / 创作者这类实体卡片墙：卡片标题批量匹配星图，悬停出档案。
                .task(id: entityLoadKey) { await loadEntityAtlas() }
                .reportScrollPagingMetrics(space: CatalogScrollSpace.name)
            }
            // 自适应续页：统一走共享翻页模块，离底部不足一屏时预取，不会自己连环翻页。
            .infiniteScrollPaging(space: CatalogScrollSpace.name,
                                  resetKey: pagingResetKey,
                                  isEnabled: catalog.hasMore && (source?.isEnabled ?? false),
                                  isLoading: catalog.isLoading,
                                  isLoadingMore: catalog.isLoadingMore,
                                  onLoadMore: { catalog.loadMore() })
            .scrollIndicators(.automatic)
            .background(LumaAmbientBackground(intensity: 0.55))
            .overlay(alignment: .bottom) {
                selectionBar
                    .padding(.bottom, selectedIDs.isEmpty ? 18 : 0)
            }
            .onChange(of: catalog.isLoadingMore) { oldValue, newValue in
                guard oldValue, !newValue, catalog.loadedPage > 1, let source else { return }
                // 新一页封面提前预热，滚到这些卡片时不会再一格一格闪白。
                catalog.prefetchCovers(for: Array(catalog.items.suffix(12)), source: source)
            }
            .onChange(of: catalog.isLoading) { oldValue, newValue in
                // 首屏加载完成后同样预热封面：视频站与图集站都走这一条。
                guard oldValue, !newValue, catalog.loadedPage <= 1,
                      let source, !catalog.items.isEmpty else { return }
                catalog.prefetchCovers(for: Array(catalog.items.prefix(12)), source: source)
            }
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
            // 方向键移动游标时跟着滚：网格很高时光标不会跑出屏幕。
            .onChange(of: cursorID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onDisappear {
                selectedIDs.removeAll()
                cursorID = nil
            }
        }
    }

    // MARK: - 键盘导航 / 批量操作

    var currentColumns: Int {
        guard source != nil else { return 4 }
        return cardColumnCount
    }

    /// 悬停时接管键盘焦点，让方向键能继续导航；
    /// 但如果用户正在输入（源内搜索 / 顶栏搜索），不要抢走焦点。
    func adoptListFocus() {
        if NSApp.keyWindow?.firstResponder is NSTextView { return }
        listFocused = true
    }

    func moveCursor(by delta: Int) {
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

    func openCursorItem() {
        guard let cursorID,
              let item = catalog.items.first(where: { $0.id == cursorID }) else { return }
        openInline(item)
    }

    /// 打开条目详情：状态提到模型里，工具栏才能同步显示返回入口与标题。
    func openInline(_ item: CatalogItem) {
        // 专题卡片 / 人物与作品实体卡片本身不是图集：点开进入它名下的图集列表。
        if item.isCollectionCard {
            catalog.openCategory(CatalogCategory(id: item.id, title: item.title))
            return
        }
        withAnimation(.easeOut(duration: 0.16)) {
            catalog.inlineDetailItem = item
        }
    }

    /// 批量操作条：只在有选中项时浮出，不占列表高度。
    @ViewBuilder
    var selectionBar: some View {
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

                if !source.kind.isGallerySite {
                    Button {
                        catalog.markWatched(source: source, items: selected)
                        selectedIDs.removeAll()
                    } label: {
                        barButton("标记已看", symbol: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                }

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

    func barButton(_ title: String, symbol: String) -> some View {
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
    func applyDefaultCardSizeIfNeeded() {
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
    func body(_ source: CatalogSource) -> some View {
        // 外部源不再单独铺「继续观看」：续看统一收进网络资源总览的「足迹」页。
        // zIndex：名册悬停档案会浮到下方内容之上，卡片本身不吃点击。
        chips.zIndex(1)
        // 需要登录 / 登录失效：优先给登录入口，不要把「要登录」说成断网。
        if catalog.errorNeedsLogin {
            loginBanner(source: source)
        } else if catalog.loginPromptNeeded(for: source), catalog.error == nil {
            loginBanner(source: source)
        } else if let snapshot = catalog.listSnapshotAt, !catalog.items.isEmpty, catalog.error != nil {
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
        } else if catalog.activeTopCategory?.showsArchive == true {
            // 归档不是卡片墙：按日期分组的紧凑列表，可搜索、按月筛。
            archiveBrowser
        } else {
            content(source)
        }
    }

    var chips: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                categoryTray
                // 随便挑一部：从当前列表里随机打开详情，给浏览加一点意外性。
                if catalog.items.count > 3 {
                    surpriseButton.fixedSize()
                }
            }
            // 从合集卡片（专题 / 人物）下钻后给一个返回入口，点一下回到来时的卡片墙。
            if let returnTitle = catalog.collectionReturnTitle {
                HStack(spacing: 8) {
                    Button {
                        catalog.closeCollectionDetail()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9, weight: .bold))
                            Text("返回\(returnTitle)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(LumaBrand.violet)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(LumaBrand.violet.opacity(0.12),
                                    in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(LumaBrand.violet.opacity(0.3), lineWidth: 0.8)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("返回\(returnTitle)")
                    if let title = catalog.collectionTitle {
                        Text("合集 · \(title)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            // 二级目录与网络影院站点页同一套：点开一级后，把站点挂在它下面的地区 / 题材铺开。
            if catalog.activeTopCategory?.showsTagWall == true {
                // 「全部分类」有上千个标签：换成可搜索、可翻页的标签墙。
                tagWallPanel
            } else if catalog.activeTopCategory != nil, !secondLevelCategories.isEmpty {
                if let kind = atlasRosterKind {
                    // 女优 / 片商这类人名牌：星图开启时换成带头像的星图名册。
                    CatalogAtlasRosterPanel(kind: kind, categories: secondLevelCategories,
                                            activeID: currentCategoryID,
                                            onOpen: { catalog.openCategory($0) },
                                            onOpenAtlasPerson: { id in
                                                AtlasStore.shared.pendingPersonID = id
                                                store.navigate(to: .atlas)
                                            })
                } else if let emblemKind = CatalogTagEmblemPanel.groupKind(catalog.activeTopCategory?.title) {
                    CatalogTagEmblemPanel(groupTitle: emblemKind, source: source, categories: secondLevelCategories,
                                          activeID: currentCategoryID, allActive: currentCategoryID == catalog.activeTopCategory?.id,
                                          onShowAll: resetTagFilter,
                                          onOpen: { catalog.openCategory($0) })
                } else { subCategoryPanel }
            }
            // 分组标签：分类 / 模特 / 发布商 / 站点类型，每组一行，点一项即按标签筛选。
            if !catalog.tagGroups.isEmpty {
                tagGroupPanel
            }
        }
    }

    /// 二级目录：站点给当前一级挂的子分类。
    var secondLevelCategories: [CatalogCategory] {
        catalog.subCategories
    }

    /// 二级目录里如果是人名牌（女优 / 片商 / 厂商 / 模特），星图开启时换成带头像的名册。
    /// 判定统一交给 `CatalogAtlasMatcher`：标题语义优先，其次看名字在资料库里的命中比例。
    var atlasRosterKind: CatalogRosterKind? {
        guard AtlasCatalogLibrary.shared.isLoaded,
              let top = catalog.activeTopCategory,
              !secondLevelCategories.isEmpty else { return nil }
        return CatalogAtlasMatcher.kind(parentTitle: top.title,
                                        children: secondLevelCategories)
    }

    /// 二级目录面板：换行胶囊 + 「全部」，一级胶囊已经表明当前分类，不再重复标题。
    var subCategoryPanel: some View {
        CatalogFlowLayout(spacing: 6, lineSpacing: 7) {
            // 分组节点自身没有列表页（点它会落到第一个子频道），所以不再给「全部」。
            if let parent = catalog.activeTopCategory, !parent.isGroupCategory {
                CatalogDirectoryChip(title: "全部",
                                     active: currentCategoryID == parent.id) {
                    catalog.openCategory(parent)
                }
            }
            ForEach(secondLevelCategories) { sub in
                CatalogDirectoryChip(title: sub.title,
                                     active: currentCategoryID == sub.id) {
                    catalog.openCategory(sub)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
    }

    // MARK: - 「全部分类」标签墙

    /// 标签墙每页多少个：密排小格子，一页铺满二十来列，上千个标签几页就能翻完。
    private var tagWallPageSize: Int { 240 }

    /// 搜索 + 语义分组后的标签；没有筛选时就是全量（站点按数量降序返回）。
    private var tagWallFiltered: [CatalogTag] {
        let query = tagWallQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = catalog.tagWallTags
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(query)
            }
        }
        guard let bucket = tagWallBucket else { return list }
        return list.filter { tagBucketByID[$0.id] == bucket }
    }

    private var tagWallPageCount: Int {
        max(1, (tagWallFiltered.count + tagWallPageSize - 1) / tagWallPageSize)
    }

    private var tagWallCurrentPage: Int {
        min(tagWallPageIndex, tagWallPageCount - 1)
    }

    private var tagWallVisibleTags: [CatalogTag] {
        Array(tagWallFiltered.dropFirst(tagWallCurrentPage * tagWallPageSize)
            .prefix(tagWallPageSize))
    }

    /// 上千个标签不做成一行行胶囊：搜索 + 等高网格 + 底部翻页，远看是一堵分类墙。
    var tagWallPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(catalog.activeTopCategory?.title ?? "全部分类")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.78))
                Text(catalog.tagWallTags.isEmpty
                     ? (catalog.isTagWallLoading ? "正在加载…" : "暂无标签")
                     : "\(catalog.tagWallTags.count) 个标签")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if catalog.isTagWallLoading, !catalog.tagWallTags.isEmpty {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 8)
                Button {
                    guard let source else { return }
                    catalog.loadTagWallIfNeeded(source: source, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(catalog.isTagWallLoading)
                .help("重新抓取全部标签")
                tagWallSearchField
            }

            // 站点把 500 多个标签平铺一堵墙：先按语义选分组（一级），再挑具体标签（二级）。
            tagWallBucketRow

            if tagWallFiltered.isEmpty {
                Text(catalog.isTagWallLoading ? "正在加载全部标签…" : "没有匹配「\(tagWallQuery)」的标签")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                CatalogTagLevelHeader(index: 2, title: "具体标签")
                CatalogFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(tagWallVisibleTags) { tag in
                        let entry = tagWallRoster[tag.id]
                        CatalogTagWallChip(title: tag.title,
                                           count: tag.count,
                                           active: currentCategoryID == tag.id,
                                           atlasEntry: entry,
                                           onAtlas: entry?.atlasPersonID.map { id -> () -> Void in
                                               {
                                                   AtlasStore.shared.pendingPersonID = id
                                                   store.navigate(to: .atlas)
                                               }
                                           },
                                           onHover: { inside in
                                               updateTagWallHover(tag.id, inside: inside)
                                           }) {
                            catalog.openCategory(CatalogCategory(id: tag.id, title: tag.title))
                        }
                        .anchorPreference(key: CatalogTagWallAnchorKey.self, value: .bounds) {
                            [tag.id: $0]
                        }
                    }
                }
                // 命中星图的人 / 品牌：悬停出档案卡，和名册、实体卡片墙共用同一张卡。
                .overlayPreferenceValue(CatalogTagWallAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        if let id = tagWallHoverID,
                           let entry = tagWallRoster[id],
                           let anchor = anchors[id] {
                            CatalogHoverCardBeside(rect: proxy[anchor],
                                                   container: proxy.size) {
                                CatalogRosterInfoCard(entry: entry,
                                                      kind: entry.atlasPersonID != nil
                                                          ? .people : .studios)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }

            HStack(spacing: 6) {
                Text("第 \(tagWallCurrentPage + 1) / \(tagWallPageCount) 页")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                tagWallPagerButton("首页", symbol: "chevron.backward.2",
                                   disabled: tagWallCurrentPage == 0) { tagWallPageIndex = 0 }
                tagWallPagerButton("上一页", symbol: "chevron.left",
                                   disabled: tagWallCurrentPage == 0) {
                    tagWallPageIndex = max(0, tagWallCurrentPage - 1)
                }
                tagWallPagerButton("下一页", symbol: "chevron.right",
                                   disabled: tagWallCurrentPage >= tagWallPageCount - 1) {
                    tagWallPageIndex = min(tagWallPageCount - 1, tagWallCurrentPage + 1)
                }
                tagWallPagerButton("末页", symbol: "chevron.forward.2",
                                   disabled: tagWallCurrentPage >= tagWallPageCount - 1) {
                    tagWallPageIndex = tagWallPageCount - 1
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
        .onChange(of: tagWallQuery) { _, _ in tagWallPageIndex = 0 }
        .onChange(of: tagWallBucket) { _, _ in
            tagWallHoverTask?.cancel()
            tagWallHoverID = nil
        }
        .onChange(of: tagWallPageIndex) { _, _ in
            tagWallHoverTask?.cancel()
            tagWallHoverID = nil
        }
        .task(id: catalog.activeTopCategory?.id) {
            guard let source else { return }
            catalog.loadTagWallIfNeeded(source: source)
        }
        .task(id: tagClassifyKey) { await classifyTagWall() }
    }

    /// 标签集合换了才重新归类；切分组只是本地过滤。
    private var tagClassifyKey: String {
        "\(catalog.tagWallTags.count)|\(catalog.tagWallTags.first?.id ?? "")"
    }

    private func classifyTagWall() async {
        guard !catalog.tagWallTags.isEmpty else {
            tagBuckets = []
            tagBucketByID = [:]
            tagWallBucket = nil
            tagWallRoster = [:]
            return
        }
        let tags = catalog.tagWallTags
        let buckets = CatalogTagClassifier.classify(tags)
        guard !Task.isCancelled else { return }
        tagBuckets = buckets
        var map: [String: String] = [:]
        for bucket in buckets {
            for tag in bucket.tags { map[tag.id] = bucket.id }
        }
        tagBucketByID = map
        if let current = tagWallBucket,
           !buckets.contains(where: { $0.id == current }) {
            tagWallBucket = nil
        }
        await loadTagWallRoster(buckets)
    }

    /// 人物 / 品牌两组标签和星图对一遍名字：命中的标签带头像，悬停直接看档案。
    /// 匹配走 `CatalogAtlasMatcher` 的内存索引，几百个标签也在毫秒级。
    private func loadTagWallRoster(_ buckets: [CatalogTagBucket]) async {
        guard AtlasCatalogLibrary.shared.isLoaded else {
            tagWallRoster = [:]
            return
        }
        let kinds: [(String, CatalogRosterKind)] = [("people", .people), ("brand", .studios)]
        var roster: [String: CatalogRosterEntry] = [:]
        for (bucketID, kind) in kinds {
            guard let bucket = buckets.first(where: { $0.id == bucketID }) else { continue }
            let children = bucket.tags.map { CatalogCategory(id: $0.id, title: $0.title) }
            let entries = await CatalogAtlasMatcher.entries(kind: kind, children: children)
            guard !Task.isCancelled else { return }
            for entry in entries where entry.isMatched { roster[entry.id] = entry }
        }
        tagWallRoster = roster
    }

    @ViewBuilder
    private var tagWallBucketRow: some View {
        if tagBuckets.count > 1 {
            CatalogTagLevelBand(index: 1, title: "分组") {
                CatalogTagBucketChip(title: "全部",
                                     symbol: "square.grid.2x2",
                                     count: catalog.tagWallTags.count,
                                     active: tagWallBucket == nil) {
                    tagWallBucket = nil
                    tagWallPageIndex = 0
                }
                ForEach(tagBuckets) { bucket in
                    CatalogTagBucketChip(title: bucket.title,
                                         symbol: bucket.symbol,
                                         count: bucket.tags.count,
                                         active: tagWallBucket == bucket.id,
                                         atlasMatched: bucket.tags.filter {
                                             tagWallRoster[$0.id] != nil
                                         }.count) {
                        tagWallBucket = bucket.id
                        tagWallPageIndex = 0
                    }
                }
            }
        }
    }

    /// 标签悬停：停留一小会儿才出档案，快速扫过整墙时不弹卡。
    private func updateTagWallHover(_ tagID: String, inside: Bool) {
        tagWallHoverTask?.cancel()
        if inside {
            guard tagWallRoster[tagID] != nil else {
                if tagWallHoverID == tagID { tagWallHoverID = nil }
                return
            }
            tagWallHoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 420_000_000)
                guard !Task.isCancelled else { return }
                tagWallHoverID = tagID
            }
        } else if tagWallHoverID == tagID {
            tagWallHoverID = nil
        }
    }

    private var tagWallSearchField: some View {
        catalogSearchField($tagWallQuery, placeholder: "搜索标签")
    }

    /// 标签墙与归档共用的胶囊搜索框：带放大镜和一键清空。
    private func catalogSearchField(_ text: Binding<String>,
                                    placeholder: String,
                                    width: CGFloat = 128) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5))
                .frame(width: width)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private func tagWallPagerButton(_ title: String, symbol: String,
                                    disabled: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(disabled ? Color.secondary.opacity(0.35)
                                      : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - 博文归档

    /// 月份分组（来自归档数据的发布日期），新的月份在前。
    private var archiveMonths: [(month: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in catalog.archiveEntries {
            counts[entry.month, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.0 > $1.0 }
    }

    private var archiveFiltered: [CatalogArchiveEntry] {
        var list = catalog.archiveEntries
        if let month = archiveMonth {
            list = list.filter { $0.month == month }
        }
        let query = archiveQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        return list
    }

    /// 按天分组，保持归档数据原有的「新 → 旧」顺序。
    private var archiveGroups: [(day: String, items: [CatalogArchiveEntry])] {
        var order: [String] = []
        var map: [String: [CatalogArchiveEntry]] = [:]
        for entry in archiveFiltered {
            if map[entry.day] == nil { order.append(entry.day) }
            map[entry.day, default: []].append(entry)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    /// 归档：一条「月份热度轴」+ 按天分组的时间线列表。
    /// 月份不再是一排灰胶囊：柱高代表当月更新量，选中的月份带渐变与光晕。
    var archiveBrowser: some View {
        VStack(alignment: .leading, spacing: 20) {
            archiveHeader
            if !catalog.archiveEntries.isEmpty {
                archiveMonthRail
            }
            archiveTimeline
        }
        .padding(20)
        .background { archiveSurface }
        .task(id: catalog.activeTopCategory?.id) {
            guard let source else { return }
            catalog.loadArchiveIfNeeded(source: source)
        }
    }

    private var archiveTint: Color { LumaBrand.violet }

    private var archiveHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("ARCHIVE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(2.6)
                }
                .foregroundStyle(archiveTint.opacity(0.9))

                Text("博文归档")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                Text(archiveCountText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if catalog.isArchiveLoading, !catalog.archiveEntries.isEmpty {
                    ProgressView().controlSize(.mini)
                }
                catalogSearchField($archiveQuery, placeholder: "搜索博文标题", width: 190)
                Button {
                    guard let source else { return }
                    catalog.loadArchiveIfNeeded(source: source, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
                        }
                }
                .buttonStyle(.plain)
                .disabled(catalog.isArchiveLoading)
                .help("重新抓取归档")
            }
            .padding(.top, 2)
        }
    }

    // MARK: 月份热度轴

    /// 年份分组：`[("2026", [("2026-04", 430), …]), …]`
    private var archiveYearGroups: [(year: String, months: [(month: String, count: Int)])] {
        var order: [String] = []
        var map: [String: [(month: String, count: Int)]] = [:]
        for item in archiveMonths {
            let year = item.month.count >= 4 ? String(item.month.prefix(4)) : item.month
            if map[year] == nil { order.append(year) }
            map[year, default: []].append((month: item.month, count: item.count))
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var archiveMonthRail: some View {
        let groups = archiveYearGroups
        let peak = max(1, groups.flatMap { $0.months.map(\.count) }.max() ?? 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 18) {
                archiveAllMonthsTile
                ForEach(groups, id: \.year) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.year)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(group.months, id: \.month) { item in
                                archiveMonthBar(item, peak: peak)
                            }
                        }
                    }
                    if group.year != groups.last?.year {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(width: 0.8, height: 58)
                            .padding(.bottom, 10)
                    }
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var archiveAllMonthsTile: some View {
        let active = archiveMonth == nil
        return Button {
            withAnimation(.snappy(duration: 0.22)) { archiveMonth = nil }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                Text("全部")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(Self.archiveCompact(catalog.archiveEntries.count))
                    .font(.system(size: 8.5, design: .monospaced))
                    .opacity(active ? 0.8 : 0.6)
            }
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(width: 58, height: 62)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [archiveTint, archiveTint.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: archiveTint.opacity(0.32), radius: 10, y: 3)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0 : 0.07), lineWidth: 0.6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("全部 \(catalog.archiveEntries.count) 篇")
    }

    private func archiveMonthBar(_ item: (month: String, count: Int), peak: Int) -> some View {
        let active = archiveMonth == item.month
        let ratio = CGFloat(item.count) / CGFloat(peak)
        let suffix = item.month.count >= 7 ? String(item.month.suffix(2)) : item.month
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                archiveMonth = active ? nil : item.month
            }
        } label: {
            VStack(spacing: 5) {
                Text(Self.archiveCompact(item.count))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(active ? archiveTint : Color.secondary.opacity(0.6))
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(active
                              ? AnyShapeStyle(LinearGradient(colors: [archiveTint,
                                                                      LumaBrand.coral.opacity(0.85)],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: 16, height: 8 + 30 * ratio)
                        .shadow(color: active ? archiveTint.opacity(0.35) : .clear,
                                radius: 6, y: 2)
                }
                .frame(width: 16, height: 38, alignment: .bottom)
                Text(suffix)
                    .font(.system(size: 10, weight: active ? .bold : .medium, design: .rounded))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .frame(width: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.month) · \(item.count) 篇")
    }

    // MARK: 时间线

    @ViewBuilder
    private var archiveTimeline: some View {
        if catalog.archiveEntries.isEmpty {
            VStack(spacing: 10) {
                if catalog.isArchiveLoading { ProgressView().controlSize(.small) }
                Text(catalog.isArchiveLoading ? "正在加载归档…" : "暂无归档")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if archiveGroups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("没有匹配「\(archiveQuery)」的博文")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(archiveGroups, id: \.day) { group in
                    archiveDayGroup(group)
                }
            }
            .padding(.top, 2)
        }
    }

    private func archiveDayGroup(_ group: (day: String, items: [CatalogArchiveEntry])) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.archiveShortDay(group.day))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(group.items.count) 篇")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 54, alignment: .leading)
            .padding(.top, 2)

            Rectangle()
                .fill(LinearGradient(colors: [archiveTint.opacity(0.35),
                                              Color.primary.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1)

            VStack(spacing: 2) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, entry in
                    CatalogArchiveRow(index: index + 1, title: entry.title) {
                        openInline(CatalogItem(id: entry.id,
                                               title: entry.title,
                                               coverURL: "",
                                               remark: ""))
                    }
                }
            }
        }
    }

    /// 归档卡片底：一层极淡的渐变 + 左上角品牌色光晕，避免大片纯白显得平。
    private var archiveSurface: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [Color.primary.opacity(0.045),
                                          Color.primary.opacity(0.012)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(archiveTint.opacity(0.10))
                    .frame(width: 240, height: 240)
                    .blur(radius: 80)
                    .offset(x: -70, y: -110)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var archiveCountText: String {
        if catalog.archiveEntries.isEmpty {
            return catalog.isArchiveLoading ? "正在加载…" : "共 0 篇"
        }
        let total = catalog.archiveEntries.count
        let shown = archiveFiltered.count
        let months = Set(catalog.archiveEntries.map(\.month)).count
        if shown == total {
            return "共 \(total.formatted()) 篇 · 覆盖 \(months) 个月"
        }
        return "筛选出 \(shown.formatted()) / \(total.formatted()) 篇 · \(months) 个月跨度"
    }

    private static func archiveShortDay(_ day: String) -> String {
        day.count >= 10 ? String(day.suffix(5)) : day
    }

    private static func archiveCompact(_ value: Int) -> String {
        if value >= 10_000 { return String(format: "%.1fw", Double(value) / 10_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    /// 分组标签面板：每组一行（行首组名），点一项按该标签加载列表；「全部」回到当前一级。
    var tagGroupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(catalog.tagGroups) { group in
                HStack(alignment: .top, spacing: 12) {
                    Text(group.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                        .padding(.top, 5)
                    CatalogFlowLayout(spacing: 6, lineSpacing: 6) {
                        CatalogTagFilterChip(title: "全部",
                                             count: nil,
                                             active: isTagGroupAllActive()) {
                            resetTagFilter()
                        }
                        ForEach(group.items) { tag in
                            CatalogTagFilterChip(title: tag.title,
                                                 count: tag.count,
                                                 active: currentCategoryID == tag.id) {
                                catalog.openCategory(CatalogCategory(id: tag.id, title: tag.title))
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
    }

    /// 没有任何标签被选中时，「全部」高亮。
    func isTagGroupAllActive() -> Bool {
        guard let current = currentCategoryID else { return true }
        return !catalog.tagGroups.contains { group in
            group.items.contains { $0.id == current }
        }
    }

    /// 取消标签筛选：回到当前一级分类；没有一级时回首页。
    func resetTagFilter() {
        if let top = catalog.activeTopCategory {
            catalog.openCategory(top)
        } else {
            catalog.openHome()
        }
    }

    /// 一级范围做成一条连体舱体：选中块在舱内滑动，比一排独立灰胶囊更像导航。
    var categoryTray: some View {
        CatalogFlowLayout(spacing: 3, lineSpacing: 3) {
            // 站点自带的首页分类已在数据层去掉，这里只保留统一的「首页」入口。
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        }
        .padding(.vertical, 2)
    }

    /// 随便挑一部：当前列表随机打开详情。
    var surpriseButton: some View {
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
        .help(source?.kind.isGallerySite == true ? "从当前列表随便挑一套图集" : "从当前列表随便挑一部")
    }

    var currentCategoryID: String? {
        switch catalog.section {
        case .category(let id): return id
        case .rank: return catalog.categories.first(where: { $0.isRank })?.id
        default: return nil
        }
    }

    /// 换源 / 换分类 / 换排序时重置翻页模块的连续补页计数。
    var pagingResetKey: String {
        "\(sourceID)|\(currentCategoryID ?? "home")|\(catalog.sort.rawValue)"
    }

    /// 卡片列数：横向封面（16:9 等）默认 4 列，竖向海报（3:4 / 2:3）默认 5 列。
    /// 顶栏滑杆在各自基准上缩放；视频站与图集站共用同一套口径。
    var cardColumnCount: Int {
        let side = max(56, CGFloat(store.thumbSize))
        let base = max(56, store.defaultGridThumbSize)
        let ratio = Double(base) / Double(side)
        let isLandscape = (source?.posterRatio ?? 1) > 1
        let baseColumns = isLandscape ? 4.0 : 5.0
        let minColumns = isLandscape ? 3 : 4
        let maxColumns = isLandscape ? 6 : 8
        return min(maxColumns, max(minColumns, Int((baseColumns * ratio).rounded())))
    }

    /// 卡片间距：列与列之间始终留出明显空隙，不随卡片变大被吃掉。
    var webGap: CGFloat {
        let side = CGFloat(store.thumbSize)
        return min(36, max(26, side * 0.12))
    }

    @ViewBuilder
    func content(_ source: CatalogSource) -> some View {
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
                        Text(source.kind.siteCategory == .gallery
                             ? "本次刷新新增 \(catalog.freshItemKeys.count) 套图集"
                             : "本次刷新新增 \(catalog.freshItemKeys.count) 条")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(source.kind.siteCategory == .gallery
                             ? "点开就是整套原图，可一键保存到本地图库"
                             : "完结剧标「已完结」、连载剧标「更新中」、单片标「刚上架」")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 2)
                }
                cardGrid(source, items: rest, columns: cardColumnCount)
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
            pagingFooter(source)
        }
    }

    /// 底部翻页区：加载中 / 可继续 / 已到底三种状态，高度固定不顶动网格。
    func pagingFooter(_ source: CatalogSource) -> some View {
        ScrollPagingFooter(isLoadingMore: catalog.isLoadingMore,
                           hasMore: catalog.hasMore,
                           loadedCount: catalog.items.count,
                           unit: source.kind.siteCategory == .gallery ? "套图集" : "条内容")
    }

    /// 排行榜前三名单独做成大卡：名次是最重要的信息，不该埋在网格里。
    var isRankSection: Bool {
        if case .rank = catalog.section { return true }
        guard let id = currentCategoryID else { return false }
        return catalog.category(withID: id)?.isRank == true
    }

    /// 精选合集索引页（`set|…`）：列表里每一项是一个合集，而不是单个视频。
    var isCollectionIndexSection: Bool {
        currentCategoryID?.hasPrefix("set|") == true
    }

    var collectionIndexBanner: some View {
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

    func rankPodium(_ source: CatalogSource, items: [CatalogItem]) -> some View {
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
    func cardGrid(_ source: CatalogSource, items: [CatalogItem], columns: Int) -> some View {
        let gap = webGap
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                        count: max(1, columns)),
                         alignment: .leading,
                         spacing: 30) {
            ForEach(items) { item in
                posterCell(source, item: item)
                    .anchorPreference(key: CatalogEntityCardAnchorKey.self, value: .bounds) {
                        [item.id: $0]
                    }
            }
        }
        .catalogMarqueeSelection($selectedIDs)
        // 实体卡片墙的悬停档案：卡片浮在上面但关掉命中测试，点卡照常进详情。
        .overlayPreferenceValue(CatalogEntityCardAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let id = entityHoverID,
                   let entry = entityAtlas[id],
                   let anchor = anchors[id] {
                    // 贴在卡片旁边，不压住要挑的那张。
                    CatalogHoverCardBeside(rect: proxy[anchor],
                                           container: proxy.size) {
                        CatalogRosterInfoCard(entry: entry,
                                              kind: entry.atlasPersonID != nil ? .people
                                                  : .studios)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    func posterCell(_ source: CatalogSource, item: CatalogItem) -> some View {
        CatalogPosterCell(
            source: source,
            item: item,
            progress: catalog.progress(sourceID: source.id, itemID: item.id),
            isSaving: catalog.savingItemID == item.id,
            isFresh: catalog.isFresh(sourceID: source.id, itemID: item.id),
            isFavorite: catalog.isFavorite(sourceID: source.id, itemID: item.id),
            isMarkedWatched: catalog.isMarkedWatched(sourceID: source.id, itemID: item.id),
            isSelected: selectedIDs.contains(item.id),
            isCursor: cursorID == item.id,
            atlasEntry: entityAtlas[item.id],
            onOpen: { openInline(item) },
            onOpenInBrowser: { store.openCatalogItemInBrowser(source: source, item: item) },
            onSaveVideo: {
                if item.isGallery(in: source) {
                    store.saveCatalogGalleryToLibrary(source: source, item: item)
                } else {
                    store.saveCatalogVideoToLibrary(source: source, item: item)
                }
            },
            onToggleSelect: {
                if selectedIDs.contains(item.id) {
                    selectedIDs.remove(item.id)
                } else {
                    selectedIDs.insert(item.id)
                }
            },
            onHoverChange: { inside in
                guard inside else {
                    if entityHoverID == item.id { entityHoverID = nil }
                    return
                }
                // 只接管键盘焦点，不把光标挪到悬停的卡片上：
                // 光标一动就会自动滚到卡片居中，鼠标再触发悬停，来回抖动会把列表带着跑。
                adoptListFocus()
                // 实体卡片墙里命中星图的人 / 品牌：悬停出档案卡。
                if entityAtlas[item.id] != nil { entityHoverID = item.id }
            },
            durationText: durationLabel(source: source, item: item),
            previewTarget: item.isGallery(in: source)
                ? nil
                : { await catalog.previewTarget(for: item) }
        )
        .background {
            // 把卡片矩形上报给框选：滚出屏幕的卡片会重新上报，框选始终按当前布局算。
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CatalogCardFrameKey.self,
                    value: [item.id: proxy.frame(in: .named(CatalogMarqueeSpace.name))])
            }
        }
    }

    /// 已经播放过的条目：用进度里的时长回填卡片，站点没给时长的源也能看到片长。
    func durationLabel(source: CatalogSource, item: CatalogItem) -> String? {
        guard let progress = catalog.progress(sourceID: source.id, itemID: item.id),
              progress.duration.isFinite, progress.duration > 20 else { return nil }
        return Self.formattedDuration(progress.duration)
    }

    static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, total % 60)
        }
        return "\(minutes):" + String(format: "%02d", total % 60)
    }

    // MARK: - 稍后看

    func favoritesList(_ source: CatalogSource) -> some View {
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

    func skeleton(_ source: CatalogSource) -> some View {
        let columns = cardColumnCount
        let gap = webGap
        return LumaSkeletonGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                               count: max(1, columns)),
                                count: 12,
                                aspectRatio: CGFloat(source.posterRatio),
                                footerLines: 1,
                                spacing: 30)
    }

    var emptyState: some View {
        LumaEmptyState(symbol: catalog.error == nil
                       ? "rectangle.on.rectangle.slash"
                       : (catalog.errorNeedsVerification ? "lock.shield" : "wifi.exclamationmark"),
                       title: emptyTitle,
                       message: emptyHint,
                       actions: emptyActions)
    }

    /// 失败态也复用同一套按钮：能在浏览器完成验证的给浏览器入口，其余给重试。
    var emptyActions: [LumaEmptyAction] {
        var actions: [LumaEmptyAction] = []
        if catalog.errorNeedsVerification, let source {
            actions.append(LumaEmptyAction(title: "在浏览器打开",
                                           symbol: "safari",
                                           tint: LumaBrand.amber) {
                store.openCatalogSourceInBrowser(source)
            })
        }
        if catalog.error != nil {
            actions.append(LumaEmptyAction(title: "重试", symbol: "arrow.clockwise") {
                catalog.refresh()
            })
        }
        return actions
    }

    var emptyTitle: String {
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

    var emptyHint: String {
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

    func handleSourceRecovery(_ action: RecoveryAction, source: CatalogSource) {
        switch action {
        case .retry:
            catalog.reload()
        case .reauthorize:
            // 需要登录的站点直接开「粘贴 Cookie」；其余仍交给系统浏览器过验证。
            if source.kind.mayRequireLogin {
                catalog.presentCookiePrompt(for: source)
            } else {
                store.openCatalogSourceInBrowser(source)
            }
        case .reconfigureSource:
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

    func banner(text: String, isError: Bool) -> some View {
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
    func snapshotBanner(_ date: Date) -> some View {
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
    func verificationBanner(source: CatalogSource) -> some View {
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

    /// 登录态提示条：Cookie 缺失 / 过期 / 被登录墙拦下时，直接给「粘贴 Cookie」入口。
    /// 有已保存的 Cookie 时会在后台自动续期，这里同步显示进度。
    func loginBanner(source: CatalogSource) -> some View {
        let refreshing = catalog.isRefreshingCookie(source.id)
        let state = source.cookieState
        let expired = state == .expired || catalog.loginRequiredSourceIDs.contains(source.id)
        let tint = LumaBrand.violet
        let title: String
        let detail: String
        if refreshing {
            title = "正在自动续期登录状态"
            detail = "后台带着已保存的 Cookie 重新访问站点，成功后这一页会自动刷新。"
        } else if expired {
            title = "登录已失效，需要更新 Cookie"
            detail = "站点要求登录后才能查看内容；从浏览器复制最新 Cookie 粘进来即可恢复。"
        } else if state == .expiringSoon, let date = source.cookieExpiresAt {
            title = "登录状态即将过期"
            detail = "预计 \(date.formatted(.dateTime.month().day().hour().minute())) 失效，建议现在更新一次 Cookie。"
        } else {
            title = "该站点需要登录才能浏览完整内容"
            detail = "在浏览器登录后复制 Cookie 粘贴进来，浏览会自动带上登录状态。"
        }
        return HStack(spacing: 10) {
            if refreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: expired ? "person.crop.circle.badge.exclamationmark" : "person.badge.key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !refreshing {
                Button {
                    catalog.presentCookiePrompt(for: source)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.badge.key")
                            .font(.system(size: 9, weight: .semibold))
                        Text(expired ? "更新 Cookie…" : "粘贴 Cookie…")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(tint.opacity(0.13), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.7)
        }
    }

    var missing: some View {
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

    func gate(_ source: CatalogSource) -> some View {
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

/// 标签筛选胶囊：可选数量徽标（Wuso 的类型筛选会带帖子数）。
private struct CatalogTagFilterChip: View {
    let title: String
    let count: Int?
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                if let count {
                    Text(Self.compact(count))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(active ? Color.white.opacity(0.72)
                                                : Color.secondary.opacity(0.7))
                }
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
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 2)
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
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(count.map { "\(title)（\($0)）" } ?? title)
    }

    /// 大数字压缩成 1.3k / 2.1w，避免筛选行被计数撑开。
    private static func compact(_ value: Int) -> String {
        if value >= 10_000 { return String(format: "%.1fw", Double(value) / 10_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// 归档里的一行博文：序号 + 标题 + 右侧「张数 / 体积」信息胶囊。
/// 标题末尾的 `[54P-75MB]` 会拆成独立徽标，正文更干净；悬停浮出渐变与箭头。
private struct CatalogArchiveRow: View {
    let index: Int
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let parsed = Self.split(title)
        Button(action: action) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .trailing)

                Text(parsed.name)
                    .font(.system(size: 12.5, weight: hovering ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(hovering ? Color.primary : Color.primary.opacity(0.86))

                Spacer(minLength: 8)

                ForEach(parsed.meta, id: \.self) { token in
                    Text(token)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumaBrand.violet.opacity(hovering ? 0.95 : 0.72))
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(LumaBrand.violet.opacity(0.09),
                                    in: Capsule(style: .continuous))
                }

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(LumaBrand.violet)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering
                          ? AnyShapeStyle(LinearGradient(colors: [LumaBrand.violet.opacity(0.10),
                                                                  Color.primary.opacity(0.02)],
                                                         startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Color.clear))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(title)
    }

    /// 标题末尾的 `[54P-75MB]` 拆成右侧信息胶囊，标题本身更干净。
    private static func split(_ title: String) -> (name: String, meta: [String]) {
        guard let open = title.lastIndex(of: "["), title.hasSuffix("]") else {
            return (title, [])
        }
        let name = String(title[..<open]).trimmingCharacters(in: .whitespaces)
        let inside = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
        let parts = inside
            .split(whereSeparator: { $0 == "-" || $0 == "·" || $0 == "|" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        return (name.isEmpty ? title : name, Array(parts.prefix(3)))
    }
}

/// 标签墙里命中星图的标签锚点：悬停浮窗贴在这个格子上。
private struct CatalogTagWallAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 标签墙里的一个条目：宽度随名字走，头像 / 全名 / 数量一起放得下。
/// 命中星图的人 / 品牌带圆头像与星图描边，右键可直接打开星图档案。
private struct CatalogTagWallChip: View {
    let title: String
    let count: Int?
    let active: Bool
    var atlasEntry: CatalogRosterEntry?
    var onAtlas: (() -> Void)?
    let onHover: (Bool) -> Void
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let entry = atlasEntry {
                    if let avatar = entry.avatarBase64, !avatar.isEmpty {
                        CatalogAvatarView(name: entry.title,
                                          base64: avatar,
                                          size: 20,
                                          ringColor: LumaBrand.violet.opacity(hovering ? 0.95 : 0.65))
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(active ? Color.white.opacity(0.9) : LumaBrand.violet)
                    }
                }
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                if let count {
                    Text(Self.compact(count))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(active ? Color.white.opacity(0.85)
                                                : Color.primary.opacity(hovering ? 0.6 : 0.45))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(active ? Color.white
                                    : Color.primary.opacity(hovering ? 1 : 0.86))
            .background {
                Capsule(style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(LumaBrand.violet)
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(atlasEntry != nil && !active
                                  ? LumaBrand.violet.opacity(hovering ? 0.6 : 0.32)
                                  : Color.primary.opacity(active ? 0 : 0.09),
                                  lineWidth: 0.7)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .contextMenu {
            Button("按「\(title)」筛选") { action() }
            if let onAtlas {
                Button("在星图中查看") { onAtlas() }
            }
        }
        .help(atlasEntry != nil ? "\(title) · 星图已收录" : (count.map { "\(title) · \($0)" } ?? title))
    }

    private static func compact(_ value: Int) -> String {
        if value >= 10000 { return String(format: "%.1fw", Double(value) / 10000) }
        if value >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }
}
