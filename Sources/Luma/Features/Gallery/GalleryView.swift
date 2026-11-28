import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaCore

/// 时间轴网格的滚动几何：偏移、内容高度、视口高度。
struct TimelineScrollMetrics: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var viewport: CGFloat
}

/// 观察滚动内容几何。macOS 15+ 用官方 `onScrollGeometryChange`（比偏好值探针可靠得多），
/// 旧系统上退化为不观察（此时只是不会自动翻页）。
struct TimelineScrollObserver: ViewModifier {
    let onChange: (TimelineScrollMetrics) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: TimelineScrollMetrics.self) { geo in
                TimelineScrollMetrics(offset: geo.contentOffset.y + geo.contentInsets.top,
                                      contentHeight: geo.contentSize.height,
                                      viewport: geo.containerSize.height)
            } action: { _, newValue in
                onChange(newValue)
            }
        } else {
            content
        }
    }
}

struct GalleryView: View {
    @Environment(LibraryStore.self) var store
    @Environment(CloudBrowserModel.self) var cloud
    @Environment(CatalogBrowserModel.self) var catalog
    @Environment(AppSettings.self) var settings
    @Environment(SelectionModel.self) var selectionModel
    /// 搜索框里的「改写」是一次性 AI 任务：状态单独观察，避免拖慢整页刷新。
    @ObservedObject var aiAssist = AIAssistCenter.shared
    /// 图库总览的合计读数：标题与副标题直接读这一份，与页面内容同源。
    @EnvironmentObject var libraryAggregate: LibraryAggregateModel
    @AppStorage(LibraryHubTab.storageKey) var libraryHubTabRaw = LibraryHubTab.resources.rawValue
    @Environment(\.colorScheme) var scheme
    @State var isDropTarget = false
    @State var keyMonitor: Any?
    @State var pinchBase: Double?
    @State var hostWindow: NSWindow?
    /// 窗口较窄时顶栏搜索收成图标，点开才是输入框，避免被系统收进溢出菜单。
    @State var toolbarCompact = false
    @State var showSearchPopover = false
    /// 单元格位置用引用类型缓存：滚动时偏好值频繁变化，不能触发整页重排。
    @State var frameCache = PhotoFrameCache()
    /// 浮动信息卡：可拖动位置、可拖右下角调整大小（双击标题复位）。
    @State var infoPanelSize = CGSize(width: 400, height: 560)
    @State var infoPanelOffset: CGSize = .zero
    @State var infoDragOrigin: CGSize?
    @State var infoResizeOrigin: CGSize?
    /// 系统图库（十万～几十万项）网格首屏只渲染这么多项，滚动到底再继续追加，
    /// 避免每次选中或切换都让 SwiftUI 对整库做 diff。
    @State var systemRenderLimit = 1_200
    /// 「图库」页：滚动条进入虚拟占位区后按排名重定位窗口的防抖任务。
    @State var timelineJumpTask: Task<Void, Never>?
    /// 缩放停手后补齐分页窗口的防抖任务（捏合过程中不取页）。
    @State var zoomFillTask: Task<Void, Never>?
    /// 首次进入的滚动位置由 `.defaultScrollAnchor(.bottom)` 决定；落位前不能把 offset≈0 当成用户拖动。
    @State var timelineGridReady = false
    /// 上一次重定位窗口时的滚动位置，避免同一位置反复换页。
    /// 落位确认：最后一次几何值 + 延时复查任务（宽度 / 侧边栏动画期间不能判定可换页）。
    @State var timelineAnchorReadyTask: Task<Void, Never>?
    /// 换页落地后的一小段静默期：系统滚动不算用户拖动，不能再次换页。
    @State var suppressTimelineJumpsUntil: TimeInterval = 0
    /// 向上接续加载更早一页时的锚点照片（追加完成后滚回它，视野不跳动）。
    @State var olderLoadAnchor: UUID?
    /// 从年 / 月总览切回「所有照片」：网格是新建的，需要把视野拉回已加载窗口。
    @State var needsTimelineRestore = false
    /// 位置页的搜索关键词：搜索框已移到顶部工具栏，状态放在这里与内容共享。
    @State var placesQuery = ""
    /// 滚动记账：只服务分页与顶栏日期范围计算，不参与渲染。
    ///
    /// 这些值在滚动过程中每一帧都会变。若放在 `@State` 里，每次赋值都会让
    /// `GalleryView` 整体重新求值——几千张照片的相册会因此每帧重算整段网格布局，
    /// 表现为「越往下翻越卡」。用引用类型持有后，更新只改字段、不触发视图刷新。
    @State var scrollBook = GalleryScrollBookkeeping()

    var lastTimelineJumpOffset: CGFloat {
        get { scrollBook.lastTimelineJumpOffset }
        nonmutating set { scrollBook.lastTimelineJumpOffset = newValue }
    }

    var lastForwardPreloadOffset: CGFloat {
        get { scrollBook.lastForwardPreloadOffset }
        nonmutating set { scrollBook.lastForwardPreloadOffset = newValue }
    }

    var lastScrollOffset: CGFloat {
        get { scrollBook.lastScrollOffset }
        nonmutating set { scrollBook.lastScrollOffset = newValue }
    }

    /// 自定义搜索框的焦点（⌘F 由 store 发请求，这里负责真正聚焦）。
    @FocusState var isSearchFieldFocused: Bool

    /// 网盘：只有普通照片列表是网格；分类总览与地图 / 位置 / 人物 / 关键词 / 体检 / 重复项目
    /// 都是专用页面，不能套用网格的计数胶囊、键盘操作与缩放控件。
    var isCloudGridScope: Bool {
        guard store.isCloudScope else { return false }
        return store.cloudOverviewSection == nil && !store.cloudScope.usesDedicatedView
    }

    var isGridScope: Bool {
        if store.isCloudScope { return isCloudGridScope }
        switch store.sidebarItem {
        case .collections, .systemCollections, .map, .places, .systemMap, .systemPlaces, .systemPeople,
             .allAlbums, .folder, .systemFolder, .people, .duplicates, .health, .systemHealth,
             .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes, .systemScenes,
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages,
             .catalogSources, .networkCinema, .atlas,
             .systemDuplicates, .systemImports, .revisit, .systemRevisit,
             .keywords, .systemKeywords,
             .ratings, .flags, .colorLabels, .systemRatings, .systemFlags, .systemColorLabels,
             .cinema, .cloudCinema, .catalogSource, .videos, .systemVideos,
             .iptv, .assistant:
            return false
        default:
            // 网络存储也使用照片网格：排序、筛选、搜索、缩放与键盘导航一致可用。
            return true
        }
    }

    var hasSearchText: Bool {
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 结果页搜索：全局或模块内都会离开当前页面，进入统一的结果页。
    var isUnifiedSearchActive: Bool {
        hasSearchText && store.searchScope != .currentView
    }

    /// 模块内搜索的来源范围：只搜当前功能自己的来源；模块主动指定来源时以它为准。
    var moduleSearchScopes: [SearchSourceKind] {
        if let pending = store.pendingSearchScope { return [pending] }
        switch store.sidebarItem {
        case .networkCinema:
            return [.networkCinema]
        case .catalogSources, .catalogSource:
            return [.catalog]
        case .atlas:
            return [.atlas]
        case .cinema, .cloudCinema:
            return [.cinema]
        case .iptv:
            return [.television]
        case .cloudStorages, .cloudMount:
            return [.cloud]
        default:
            return store.isCloudScope ? [.cloud] : [.library]
        }
    }

    /// 影院 / 网络资源 / 电视 / 各总览页展示的是导航卡片或影视条目，没有可过滤的照片窗口。
    var supportsWindowSearch: Bool {
        if isHubBarScope || isNetworkCinemaScope || isCatalogScope || isTVHubScope { return false }
        switch store.sidebarItem {
        case .cinema, .cloudCinema, .atlas, .assistant: return false
        default: return true
        }
    }

    /// 顶栏搜索范围的三个档位：全局 / 模块内 / 窗口内。
    var availableSearchScopes: [SearchScope] { SearchScope.allCases }

    /// 搜索结果页的身份：范围 / 模块指定来源 / 当前页面变化时都要按新来源重新初始化调度。
    var searchPageIdentity: String {
        [store.searchScope.rawValue,
         store.pendingSearchScope?.rawValue ?? "-",
         String(describing: store.sidebarItem)].joined(separator: "|")
    }

    /// 总览 / 卡片墙 / 地图等页面没有照片网格，搜索词一旦非空就改走照片网格，
    /// 否则输入搜索后页面仍停留在分类卡片上，看起来像「搜索没反应」。
    var showsSearchResultsGrid: Bool {
        hasSearchText && !isGridScope
    }

    /// 窗口内搜索改用照片网格展示命中项：只对本身有可过滤内容的卡片墙生效；
    /// 影院 / 网络资源 / 电视这类页面留在原地，由页面自己过滤当前窗口。
    var showsWindowSearchGrid: Bool {
        store.searchScope == .currentView && showsSearchResultsGrid && supportsWindowSearch
    }

    /// 总览页搜到的结果展示的是整库（或当前视图）命中项，标题跟着改成「搜索结果」。
    var displayTitle: String {
        if isUnifiedSearchActive || showsWindowSearchGrid { return "搜索结果" }
        // 图库总览的三个分页各有页面名：标题随页头一起上移到窗口标题区。
        if isLibraryHubScope {
            switch LibraryHubTab(rawValue: libraryHubTabRaw) ?? .resources {
            case .resources: return "图库资源"
            case .photos: return "照片聚合"
            case .favorites: return "收藏聚合"
            }
        }
        return store.sidebarTitle
    }

    /// 顶栏副标题：显示已加载窗口的日期跨度。
    /// 只读窗口首尾两张（O(1)），不随滚动重算——之前逐帧扫全部单元格并写 `@Observable`，
    /// 每帧都会让整棵网格重新求值，是上下拖动发卡的主因。
    var navigationSubtitleText: String {
        guard !isLibraryHubScope, store.isTimelineScope, store.grouping == .all else { return "" }
        let photos = store.loadedWindowPhotos.isEmpty ? store.visiblePhotos : store.loadedWindowPhotos
        guard let first = photos.first, let last = photos.last else { return "" }
        return DateText.span(from: min(first.capturedAt, last.capturedAt),
                             to: max(first.capturedAt, last.capturedAt))
    }

    var isRevisitScope: Bool {
        if store.isCloudScope { return store.cloudScope == .revisit }
        return store.sidebarItem == .revisit || store.sidebarItem == .systemRevisit
    }

    var isPlacesScope: Bool {
        if store.isCloudScope { return store.cloudScope == .places }
        return store.sidebarItem == .places || store.sidebarItem == .systemPlaces
    }

    var isMapScope: Bool {
        if store.isCloudScope { return store.cloudScope == .map }
        return store.sidebarItem == .map || store.sidebarItem == .systemMap
    }

    /// 视频页：顶栏承担标题之外的分组 / 筛选 / 布局，内容区不再重复页头。
    var isVideoHubScope: Bool {
        store.sidebarItem == .videos || store.sidebarItem == .systemVideos
    }

    /// 网络资源频道页：分类信息、刷新与源内搜索整体进窗口工具栏，内容区不再另起控制条。
    var isCatalogScope: Bool {
        if case .catalogSource = store.sidebarItem { return true }
        return false
    }

    /// 网络资源总览：浏览 / 片单 / 更新日历的分页切换放在工具栏中区。
    var isCatalogHubScope: Bool {
        store.sidebarItem == .catalogSources
    }

    /// 图集详情：显示形式与缩略图缩放搬到窗口工具栏，与普通图库一致；
    /// 正文里不再单独占一条控制条。
    var showsCatalogGalleryToolbar: Bool {
        guard isCatalogScope,
              catalog.inlineDetailItem != nil,
              catalog.selectedSource?.kind.isGallerySite == true,
              let detail = catalog.detail,
              detail.item.id == catalog.inlineDetailItem?.id else { return false }
        return !detail.articleImages.isEmpty
    }

    /// 网络存储总览：存储 / 索引 / 影院 / 续播 / 维护的分页切换同样放在工具栏中区。
    var isCloudStoragesHubScope: Bool {
        store.sidebarItem == .cloudStorages
    }

    /// 图库总览：资源 / 照片 / 收藏的分页切换放在工具栏中区。
    var isLibraryHubScope: Bool {
        store.sidebarItem == .systemLibraries
    }

    /// 网络电视总览：频道 / 电视源 / 状态的分页切换放在工具栏中区。
    var isTVHubScope: Bool {
        store.sidebarItem == .iptv
    }

    /// 网络影院：电影 / 电视剧 / 最近更新的分页切换同样放在工具栏中区。
    var isNetworkCinemaScope: Bool {
        store.sidebarItem == .networkCinema
    }

    /// 网络资源区里最上层的二级页：工具栏最左的返回按钮据此显示。
    /// 层级顺序：频道详情 > 关注档案 > 片单详情。
    var catalogBackAction: (title: String, action: () -> Void)? {
        if isCatalogScope {
            // 详情里叠开的人物档案：先退回详情，再退回频道列表。
            if catalog.detailPersonTarget != nil {
                return ("返回详情 (Esc)", { catalog.detailPersonTarget = nil })
            }
            if catalog.inlineDetailItem != nil {
                return ("返回频道列表 (Esc)", { catalog.inlineDetailItem = nil })
            }
        }
        if isCatalogHubScope {
            if catalog.followedProfile != nil {
                return ("返回关注 (Esc)", { catalog.followedProfile = nil })
            }
            if catalog.openPlaylistPage != nil {
                return ("返回片单 (Esc)", { catalog.openPlaylistPage = nil })
            }
        }
        return nil
    }

    /// 整理工作室：评分 / 旗标 / 色标 / 关键词四种维度共用同一个页面与顶栏控件。
    var isOrganizeScope: Bool {
        if store.isCloudScope { return store.cloudScope == .ratings }
        switch store.sidebarItem {
        case .ratings, .flags, .colorLabels,
             .systemRatings, .systemFlags, .systemColorLabels:
            return true
        default:
            return false
        }
    }

    /// 窗口内浏览时工具栏交给查看器（返回 / 缩放 / 拍摄时间 / 操作），网格工具栏整体让位。
    /// 只看 viewerPhoto：播放失败可能留下 viewerID 有值但照片已不存在的幽灵查看器，
    /// 那种状态下查看器不会渲染，工具栏却会被清空。
    var isWindowedViewing: Bool {
        settings.viewerLayout == .window && store.viewerPhoto != nil
    }

    /// 收藏的汇总维度页：不是照片网格，缩放、搜索与键盘选择暂时让位。
    var isFavoritesDigestHub: Bool {
        store.isFavoritesScope && store.favoritesViewMode != .all
            && store.selectedFavoriteBucket == nil
    }

    /// 需要缩放控件的范围：照片/相簿网格，以及人物、位置这类卡片墙。
    var supportsZoomControl: Bool {
        // 查看器打开时网格不在最前：这个滑杆调不动照片，容易让人以为「缩不小」，
        // 顶栏改由查看器自己的「− 100% +」接管。
        if store.viewerPhoto != nil { return false }
        // 总览类分页（图库 / 网络资源 / 网络存储 / 影院 / 电视）是导航卡片，没有可缩放的网格。
        if isLibraryHubScope || isCatalogHubScope || isCloudStoragesHubScope
            || isNetworkCinemaScope || isTVHubScope {
            return false
        }
        if isGridScope || showsWindowSearchGrid || isUnifiedSearchActive { return !isFavoritesDigestHub }
        if store.isCloudScope {
            // 分类总览的卡片墙与拾光一样保留缩放控件；人物 / 位置 / 关键词卡片墙同理。
            if store.cloudOverviewSection != nil { return true }
            switch store.cloudScope {
            case .people, .places, .keywords: return true
            default: return false
            }
        }
        // 网络资源详情：卡片尺寸滑杆对详情页没有意义，让位给工具栏里的返回 / 播放。
        if case .catalogSource = store.sidebarItem {
            return catalog.inlineDetailItem == nil
        }
        switch store.sidebarItem {
        case .allAlbums, .folder, .systemFolder, .people, .systemPeople, .places, .systemPlaces,
             .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes, .systemScenes,
             .moreItems, .systemMoreItems, .systemImports,
             .keywords, .systemKeywords, .videos, .systemVideos:
            return true
        default:
            return false
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                content(width: proxy.size.width)
                    // 左侧切换页面时重建内容区：滚动位置、列表状态都从顶部重新开始。
                    // 不做淡入过渡：切换瞬间新旧两页会同时活着再各自布局一遍，
                    // 重页面（影院 / 电视 / 网盘）叠一起就是「点一下卡一下」。
                    .id(store.sidebarItem)
                if showsCountPill {
                    countPill
                        .padding(.bottom, 16)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if store.showLibraryInfo {
                    libraryInfoPanel(container: proxy.size)
                        .padding(.top, 10)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(infoPanelOffset)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(3)
                }
            }
            .onAppear { updateGridContentWidth(proxy.size.width) }
            .onChange(of: proxy.size.width) { _, newValue in updateGridContentWidth(newValue) }
        }
        .task(id: store.pagedKey) {
            // 大图库：筛选/排序/分段下推到 SQLite，这里只加载窗口的第一页。
            store.reloadVisibleWindowIfNeeded()
        }
        // 缩放档位（600 / 1200 / 2400 一页）变化后才补齐窗口：
        // 捏合过程中不取页，停手 0.26 秒再按缺口追加，缩放路径上没有任何加载与整表替换。
        .onChange(of: store.windowPageSizeForCurrentZoom) { _, _ in
            scheduleZoomWindowFill()
        }
        // 影院页的标题由顶栏控制台自己承担，避免「系统标题 + 控制台」两套标题并排。
        // 分页胶囊本身已表明当前模块，五个总览页不再单独写窗口标题。
        .navigationTitle(isWindowedViewing || showsCinemaConsole
                         || isLibraryHubScope || isCatalogHubScope || isCloudStoragesHubScope
                         || isNetworkCinemaScope || isCatalogScope || isTVHubScope
                         ? "" : displayTitle)
        // 影院 / 电视 / 各总览分页的读数由标题右侧的读数条承担，这里不再叠一行纯文字。
        .navigationSubtitle(isWindowedViewing || isVideoHubScope || isCatalogScope
                            || isNetworkCinemaScope || isTVHubScope
                            || isLibraryHubScope || isCatalogHubScope
                            || isCloudStoragesHubScope
                            ? Text("")
                            : Text(navigationSubtitleText))
        .onChange(of: store.grouping) { _, grouping in
            if grouping == .all {
                // 回到「所有照片」时网格会重新创建：标记一次视野恢复，交给网格 onAppear 处理。
                needsTimelineRestore = true
            }
        }
        .onChange(of: store.sidebarItem) { _, _ in
            // 换到另一个范围时网格整体换页：等新窗口取回后再锚定一次，
            // 避免沿用上一个范围的滚动偏移，停在空白占位或半屏照片上。
            needsTimelineRestore = true
            timelineGridReady = false
            lastTimelineJumpOffset = -1
        }
        // 网盘的 sidebarItem 始终是 `.cloudMount`：切换范围 / 目录 / 总览时同样要重置网格状态。
        .onChange(of: cloudPageIdentity) { _, _ in
            needsTimelineRestore = true
            timelineGridReady = false
            lastTimelineJumpOffset = -1
        }
        .toolbar {
            // 影院控制台由 CinemaTitlebarConsoleHost 直接铺在标题栏上，
            // 不走 NSToolbar 项，窗口变窄时不会被系统整条收进溢出菜单。
            if !isWindowedViewing, !showsCinemaConsole {
                // 网络资源二级页（频道详情 / 关注档案 / 片单详情）：返回放在最左侧，
                // 与视频播放器的返回位置保持一致。
                ToolbarItem(placement: .navigation) {
                    if let back = catalogBackAction {
                        CatalogToolbarBackButton(help: back.title) {
                            withAnimation(.easeOut(duration: 0.18)) { back.action() }
                        }
                    } else if isNetworkCinemaScope, store.networkCinemaDetail != nil {
                        // 网络影院详情页：返回与「网络资源」详情同一位置、同一套胶囊。
                        CatalogToolbarBackButton(title: "网络影院", help: "返回网络影院") {
                            withAnimation(.easeOut(duration: 0.18)) {
                                store.networkCinemaDetail = nil
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigation) {
                    navigationToolbarContent
                }
                ToolbarItem(placement: .navigation) {
                    if supportsZoomControl {
                        zoomControl
                    } else if showsCatalogGalleryToolbar {
                        // 图集详情：显示形式 + 缩放进顶栏，正文只留图片。
                        CatalogGalleryToolbarControls()
                    }
                }
                ToolbarItem(placement: .navigation) {
                    if isNetworkCinemaScope,
                       store.networkCinemaSourceID != nil,
                       store.networkCinemaDetail == nil {
                        NetworkCinemaZoomControl()
                    }
                }
                ToolbarItem(placement: .navigation) {
                    // 网络资源频道页：与网络影院站点页同一套顶栏版式，
                    // 缩放胶囊之后紧接「分类 · 站点 · 排序 · 站内搜索 · 刷新」舱体。
                    if isCatalogScope, catalog.inlineDetailItem == nil {
                        CatalogToolbarConsole()
                    }
                }
                ToolbarItem(placement: .navigation) {
                    if isHubBarScope {
                        // 总览页把「分页按钮 + 读数」整组钉在标题栏最左侧：
                        // 按钮在左、读数在右，切换分页时位置不动。
                        HStack(spacing: 10) {
                            principalBarContent
                            if showsModuleReadout {
                                ModuleReadoutStrip(items: moduleReadoutItems,
                                                   accent: moduleReadoutAccent)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    // 频道页的舱体已经钉在标题栏左侧，中区留空，避免出现两枚控制台。
                    if !isHubBarScope, !isCatalogScope {
                        principalBarContent
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if isCatalogScope {
                        // 与网络影院站点页同一套顶栏：右侧只留智能助手，不再放照片动作胶囊；
                        // 统一搜索（照片 / 影片 / 频道 / 资源）保持常驻。
                        if !toolbarCompact {
                            GalleryToolbarPill {
                                assistantButton
                            }
                        }
                        gallerySearchField
                    } else {
                        primaryActionToolbarContent
                    }
                }
            }
        }
        // 播放器关闭后系统工具栏偶尔整条不回来（返回键一起消失）：主动让窗口重新校验可见项。
        .onChange(of: isWindowedViewing) { _, windowed in
            guard !windowed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.keyWindow?.toolbar?.validateVisibleItems()
            }
        }
        .onChange(of: store.searchFocusRequest) { _, _ in
            // 网络资源没有照片索引：⌘F 应该落到源内搜索，而不是隐藏的图库搜索框。
            if isCatalogScope {
                catalog.focusSearch()
            } else {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: store.searchText) { _, newValue in
            // 收藏汇总维度页没有可过滤的列表：一开始搜索就回到「全部」，让结果落在照片网格上。
            if isFavoritesDigestHub, !newValue.isEmpty {
                store.favoritesViewMode = .all
            }
            store.prepareSemanticSearch()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTarget {
                dropOverlay
            }
        }
        .overlay(alignment: .top) {
            GalleryStatusOverlay()
        }
        .animation(settings.motion.overlay, value: store.showLibraryInfo)
        // 不再对 sidebarItem 套整页动画：切页是销毁 + 重建整棵内容树，
        // 拿弹簧把它补间一遍只会让重页面在首帧多渲染几轮，手感反而发滞。
        .animation(settings.motion.layout, value: store.thumbnailAspect)
        .onAppear { installKeyboardMonitor() }
        .onDisappear { removeKeyboardMonitor() }
        .background(
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
                if let window { updateToolbarCompact(window) }
            }
        )
    }

    /// 窗口窄到放不下「分页胶囊 + 搜索框」时，搜索收成图标，防止整个工具栏溢出。
    func updateToolbarCompact(_ window: NSWindow) {
        let compact = window.frame.width < 1080
        if compact != toolbarCompact { toolbarCompact = compact }
    }

}

/// 相簿 / 文件夹的层级面包屑已抽成通用组件 `LumaBreadcrumbBar`（见 LumaDesign.swift），
/// 网盘目录复用同一套外观。

/// 画廊滚动的记账本：只保存「上一帧的偏移 / 高度」这类中间量。
///
/// 用引用类型而不是 `@State`，是因为这些字段在滚动时每帧都会写；
/// 走 `@State` 会让 `GalleryView` 每帧重新求值，几万张照片的相册会明显掉帧。
@MainActor
final class GalleryScrollBookkeeping {
    var lastScrollOffset: CGFloat = 0
    var lastForwardPreloadOffset: CGFloat = -.greatestFiniteMagnitude
    var lastTimelineJumpOffset: CGFloat = -1
    /// 最后一次按视野中心预取缩略图的位置（窗口下标）与时间：避免每帧重复排队。
    var lastPrefetchCenterIndex: Int = -1
    var lastPrefetchStamp: TimeInterval = 0
    /// 反序网格上一次检查「向上接续下一页」的偏移：连续上滑时按 24pt 节流。
    var lastReversePreloadOffset: CGFloat = .greatestFiniteMagnitude
}

