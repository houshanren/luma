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
private struct TimelineScrollObserver: ViewModifier {
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
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selectionModel: SelectionModel
    @Environment(\.colorScheme) private var scheme
    @State private var isDropTarget = false
    @State private var keyMonitor: Any?
    @State private var pinchBase: Double?
    @State private var hostWindow: NSWindow?
    /// 单元格位置用引用类型缓存：滚动时偏好值频繁变化，不能触发整页重排。
    @State private var frameCache = PhotoFrameCache()
    /// 浮动信息卡：可拖动位置、可拖右下角调整大小（双击标题复位）。
    @State private var infoPanelSize = CGSize(width: 400, height: 560)
    @State private var infoPanelOffset: CGSize = .zero
    @State private var infoDragOrigin: CGSize?
    @State private var infoResizeOrigin: CGSize?
    /// 系统图库（十万～几十万项）网格首屏只渲染这么多项，滚动到底再继续追加，
    /// 避免每次选中或切换都让 SwiftUI 对整库做 diff。
    @State private var systemRenderLimit = 1_200
    /// 「图库」页：滚动条进入虚拟占位区后按排名重定位窗口的防抖任务。
    @State private var timelineJumpTask: Task<Void, Never>?
    /// 首次进入的滚动位置由 `.defaultScrollAnchor(.bottom)` 决定；落位前不能把 offset≈0 当成用户拖动。
    @State private var timelineGridReady = false
    /// 上一次重定位窗口时的滚动位置，避免同一位置反复换页。
    @State private var lastTimelineJumpOffset: CGFloat = -1
    /// 落位确认：最后一次几何值 + 延时复查任务（宽度 / 侧边栏动画期间不能判定可换页）。
    @State private var timelineAnchorReadyTask: Task<Void, Never>?
    @State private var lastTimelineContentHeight: CGFloat = 0
    @State private var lastTimelineViewport: CGFloat = 0
    /// 换页落地后的一小段静默期：系统滚动不算用户拖动，不能再次换页。
    @State private var suppressTimelineJumpsUntil: TimeInterval = 0
    /// 向上接续加载更早一页时的锚点照片（追加完成后滚回它，视野不跳动）。
    @State private var olderLoadAnchor: UUID?
    /// 正序分页网格上一次预取时的滚动偏移，避免逐帧重复请求下一页。
    @State private var lastForwardPreloadOffset: CGFloat = -.greatestFiniteMagnitude
    /// 从年 / 月总览切回「所有照片」：网格是新建的，需要把视野拉回已加载窗口。
    @State private var needsTimelineRestore = false
    /// 位置页的搜索关键词：搜索框已移到顶部工具栏，状态放在这里与内容共享。
    @State private var placesQuery = ""
    /// 顶栏日期范围：上次计算时的滚动偏移，避免逐帧重算。
    @State private var lastDateSpanOffset: CGFloat = .greatestFiniteMagnitude
    /// 最近一次滚动偏移：单元格懒加载时也要用同一偏移重算日期范围。
    @State private var lastScrollOffset: CGFloat = 0
    /// 自定义搜索框的焦点（⌘F 由 store 发请求，这里负责真正聚焦）。
    @FocusState private var isSearchFieldFocused: Bool

    /// 网盘：只有普通照片列表是网格；分类总览与地图 / 位置 / 人物 / 关键词 / 体检 / 重复项目
    /// 都是专用页面，不能套用网格的计数胶囊、键盘操作与缩放控件。
    private var isCloudGridScope: Bool {
        guard store.isCloudScope else { return false }
        return store.cloudOverviewSection == nil && !store.cloudScope.usesDedicatedView
    }

    private var isGridScope: Bool {
        if store.isCloudScope { return isCloudGridScope }
        switch store.sidebarItem {
        case .collections, .systemCollections, .map, .places, .systemMap, .systemPlaces, .systemPeople,
             .allAlbums, .folder, .systemFolder, .people, .duplicates, .health, .systemHealth,
             .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes, .systemScenes,
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages,
             .catalogSources,
             .systemDuplicates, .systemImports, .revisit, .systemRevisit,
             .keywords, .systemKeywords,
             .ratings, .flags, .colorLabels, .systemRatings, .systemFlags, .systemColorLabels,
             .cinema, .cloudCinema, .catalogSource, .videos, .systemVideos:
            return false
        default:
            // 网络存储也使用照片网格：排序、筛选、搜索、缩放与键盘导航一致可用。
            return true
        }
    }

    private var hasSearchText: Bool {
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 全局搜索：命中项跨越整库，结果页需要先按「图片 / 相簿 / 文件夹 / 人物 / 地点」分类。
    private var isGlobalSearchActive: Bool {
        hasSearchText && store.searchScope == .global
    }

    /// 总览 / 卡片墙 / 地图等页面没有照片网格，搜索词一旦非空就改走照片网格，
    /// 否则输入搜索后页面仍停留在分类卡片上，看起来像「搜索没反应」。
    private var showsSearchResultsGrid: Bool {
        hasSearchText && !isGridScope
    }

    /// 总览页搜到的结果展示的是整库（或当前视图）命中项，标题跟着改成「搜索结果」。
    private var displayTitle: String {
        (isGlobalSearchActive || showsSearchResultsGrid) ? "搜索结果" : store.sidebarTitle
    }

    private var isRevisitScope: Bool {
        if store.isCloudScope { return store.cloudScope == .revisit }
        return store.sidebarItem == .revisit || store.sidebarItem == .systemRevisit
    }

    private var isPlacesScope: Bool {
        if store.isCloudScope { return store.cloudScope == .places }
        return store.sidebarItem == .places || store.sidebarItem == .systemPlaces
    }

    private var isMapScope: Bool {
        if store.isCloudScope { return store.cloudScope == .map }
        return store.sidebarItem == .map || store.sidebarItem == .systemMap
    }

    /// 视频页：顶栏承担标题之外的分组 / 筛选 / 布局，内容区不再重复页头。
    private var isVideoHubScope: Bool {
        store.sidebarItem == .videos || store.sidebarItem == .systemVideos
    }

    /// 网络资源频道页：分类信息、刷新与源内搜索整体进窗口工具栏，内容区不再另起控制条。
    private var isCatalogScope: Bool {
        if case .catalogSource = store.sidebarItem { return true }
        return false
    }

    /// 网络资源总览：浏览 / 片单 / 更新日历的分页切换放在工具栏中区。
    private var isCatalogHubScope: Bool {
        store.sidebarItem == .catalogSources
    }

    /// 网络存储总览：存储 / 索引 / 影院 / 续播 / 维护的分页切换同样放在工具栏中区。
    private var isCloudStoragesHubScope: Bool {
        store.sidebarItem == .cloudStorages
    }

    /// 网络资源区里最上层的二级页：工具栏最左的返回按钮据此显示。
    /// 层级顺序：频道详情 > 关注档案 > 片单详情。
    private var catalogBackAction: (title: String, action: () -> Void)? {
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
    private var isOrganizeScope: Bool {
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
    private var isWindowedViewing: Bool {
        settings.viewerLayout == .window && store.viewerPhoto != nil
    }

    /// 收藏的汇总维度页：不是照片网格，缩放、搜索与键盘选择暂时让位。
    private var isFavoritesDigestHub: Bool {
        store.isFavoritesScope && store.favoritesViewMode != .all
            && store.selectedFavoriteBucket == nil
    }

    /// 需要缩放控件的范围：照片/相簿网格，以及人物、位置这类卡片墙。
    private var supportsZoomControl: Bool {
        if isGridScope || showsSearchResultsGrid || isGlobalSearchActive { return !isFavoritesDigestHub }
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
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages, .systemImports,
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
                    .transition(.opacity)
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
        // 影院页的标题由顶栏控制台自己承担，避免「系统标题 + 控制台」两套标题并排。
        .navigationTitle(isWindowedViewing || showsCinemaConsole ? "" : displayTitle)
        .navigationSubtitle(isWindowedViewing || isVideoHubScope || isCatalogScope
                            ? Text("")
                            : Text(store.visibleDateSpanText))
        .onChange(of: store.grouping) { _, grouping in
            if grouping != .all {
                store.visibleDateSpanText = ""
            } else {
                // 回到「所有照片」时网格会重新创建：标记一次视野恢复，交给网格 onAppear 处理。
                needsTimelineRestore = true
            }
            lastDateSpanOffset = .greatestFiniteMagnitude
        }
        .onChange(of: store.sidebarItem) { _, _ in
            store.visibleDateSpanText = ""
            lastDateSpanOffset = .greatestFiniteMagnitude
            // 换到另一个范围时网格整体换页：等新窗口取回后再锚定一次，
            // 避免沿用上一个范围的滚动偏移，停在空白占位或半屏照片上。
            needsTimelineRestore = true
            timelineGridReady = false
            lastTimelineJumpOffset = -1
        }
        // 网盘的 sidebarItem 始终是 `.cloudMount`：切换范围 / 目录 / 总览时同样要重置网格状态。
        .onChange(of: cloudPageIdentity) { _, _ in
            store.visibleDateSpanText = ""
            lastDateSpanOffset = .greatestFiniteMagnitude
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
                    }
                }
                ToolbarItem(placement: .navigation) {
                    navigationToolbarContent
                }
                ToolbarItem(placement: .navigation) {
                    if supportsZoomControl {
                        zoomControl
                    }
                }
                ToolbarItem(placement: .principal) {
                    if isCatalogHubScope {
                        // 网络资源总览：浏览 / 片单 / 更新日历并入工具栏同一行。
                        CatalogHubTabs()
                    } else if isCloudStoragesHubScope {
                        // 网络存储总览：总览 / 存储 / 影院 / 续播 / 管理并入工具栏同一行。
                        CloudStoragesHubTabs()
                    } else if isCatalogScope {
                        // 网络资源：中区是「分类 + 站点 + 刷新」舱体，分类菜单与左侧菜单同源。
                        CatalogToolbarConsole()
                    } else {
                        principalToolbarContent
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if isCatalogScope {
                        // 源内搜索已并入中区舱体；详情模式下右侧动作也让位给返回 / 播放。
                        if catalog.inlineDetailItem == nil {
                            galleryActionPill
                        }
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
            VStack(spacing: 8) {
                if store.isImporting, let progress = store.importProgress {
                    Button {
                        store.requestImportPanel()
                    } label: {
                        HStack(spacing: 8) {
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                                .frame(width: 130)
                            Text("导入中 \(progress.completed.formatted()) / \(progress.total.formatted())")
                                .font(.system(size: 11, design: .monospaced))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .lumaGlassCapsule(shadow: false)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("打开导入窗口")
                }

                if store.isCloudScope, store.isCloudScanning {
                    Button {
                        store.stopCloudAlbumScan()
                    } label: {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("正在扫描网盘… 已扫描 \(store.cloudScanFolderCount.formatted()) 个文件夹")
                                .font(.system(size: 11, design: .monospaced))
                            Text("停止")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .lumaGlassCapsule(shadow: false)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("停止扫描")
                }

                if store.isLoadingSystemLibrary, store.isSystemScope {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(store.systemScanCount > 0
                             ? "正在读取系统图库… \(store.systemScanCount.formatted()) 项"
                             : "正在读取系统图库…")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .lumaGlassCapsule(shadow: false)
                }

                if store.similarScope != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                        Text(store.sidebarTitle)
                            .font(.system(size: 11))
                        Button("完成") { store.clearSimilarScope() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .lumaGlassCapsule(shadow: false)
                    .help("退出相似照片范围")
                }
            }
            // 顶部浮层要避开统一工具栏；否则进度胶囊会被标题栏裁掉一半。
            .padding(.top, 56)
        }
        .animation(settings.motion.overlay, value: store.showLibraryInfo)
        .animation(settings.motion.layout, value: store.sidebarItem)
        .animation(settings.motion.layout, value: store.thumbnailAspect)
        .onAppear { installKeyboardMonitor() }
        .onDisappear { removeKeyboardMonitor() }
        .background(
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
            }
        )
    }

    // MARK: - 顶部上下文条

    /// 人物 / 位置 / 图库体检 / 精选集：把原本占首屏的大标题压缩进统一工具栏。
    private var showsContextChip: Bool {
        if store.isCloudScope {
            switch store.cloudScope {
            case .people, .places, .keywords, .health: return true
            default: return false
            }
        }
        switch store.sidebarItem {
        case .people, .systemPeople, .places, .systemPlaces, .health, .systemHealth,
             .collections, .systemCollections, .keywords, .systemKeywords,
             .systemImportSession:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var contextChip: some View {
        if store.isCloudScope {
            switch store.cloudScope {
            case .people:
                chipPill(icon: "person.2",
                         text: "\(store.cloudPeople.count.formatted()) 位 · 本机聚类")
            case .places:
                if let place = store.selectedPlace {
                    chipPill(icon: "mappin",
                             text: "\(place.title) · \(place.count.formatted()) 张照片")
                } else {
                    chipPill(icon: "mappin.and.ellipse",
                             text: "\(store.placeClusters.count.formatted()) 个地点 · \(store.geoPhotos.count.formatted()) 张")
                }
            case .keywords:
                if let keyword = store.selectedKeyword {
                    chipPill(icon: "tag",
                             text: "#\(keyword) · \(store.visibleCount.formatted()) 张照片")
                } else {
                    let options = store.keywordOptions
                    let photos = options.reduce(0) { $0 + $1.count }
                    chipPill(icon: "tag",
                             text: "\(options.count.formatted()) 个关键词 · \(photos.formatted()) 张")
                }
            case .health:
                if cloud.isScanningHealth {
                    chipPill(icon: "stethoscope",
                             text: "检查中 \(Int((cloud.healthScanProgress * 100).rounded()))%")
                } else if let report = cloud.healthReport {
                    chipPill(icon: "stethoscope",
                             text: "模糊 \(report.blurry.count) · 相似 \(report.similarDuplicatePhotos.count) · 已查 \(report.scannedCount)")
                } else {
                    chipPill(icon: "stethoscope", text: "本机检查照片质量")
                }
            default:
                EmptyView()
            }
        } else {
            switch store.sidebarItem {
        case .collections:
            chipPill(icon: "rectangle.stack", text: "智能汇总 · 照片 / 视频 / 编辑成果")
        case .systemCollections:
            chipPill(icon: "rectangle.stack",
                     text: "只读汇总 · \(store.systemLibraryName ?? "系统照片图库")")
        case .people:
            if let id = store.selectedLocalPersonID,
               let person = store.localPeople.first(where: { $0.id == id }) {
                chipPill(icon: "person.crop.circle",
                         text: "\(person.name) · \(person.assetIDs.count.formatted()) 张照片")
            } else {
                chipPillAction(icon: "person.2",
                               text: "\(store.localPeople.count.formatted()) 位 · 本机聚类") {
                    Button {
                        if store.isClusteringFaces {
                            store.cancelFaceClustering()
                        } else {
                            store.startFaceClustering()
                        }
                    } label: {
                        Image(systemName: store.isClusteringFaces ? "stop.circle" : "wand.and.stars")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(store.isClusteringFaces ? "停止人物分析" : "分析尚未处理过的照片")
                }
            }
        case .systemPeople:
            if let person = store.selectedPerson {
                chipPill(icon: person.isPet ? "pawprint" : "person.crop.circle",
                         text: "\(person.name) · \(person.faceCount.formatted()) 张照片")
            } else {
                chipPill(icon: "person.2",
                         text: "\(store.systemPeople.count.formatted()) 位 · 官方识别")
            }
        case .places, .systemPlaces:
            if let place = store.selectedPlace {
                chipPill(icon: "mappin",
                         text: "\(place.title) · \(place.count.formatted()) 张照片")
            } else {
                chipPill(icon: "mappin.and.ellipse",
                         text: "\(store.placeClusters.count.formatted()) 个地点 · \(store.geoPhotos.count.formatted()) 张")
            }
        case .keywords, .systemKeywords:
            if let keyword = store.selectedKeyword {
                chipPill(icon: "tag",
                         text: "#\(keyword) · \(store.visibleCount.formatted()) 张照片")
            } else {
                let options = store.keywordOptions
                let photos = options.reduce(0) { $0 + $1.count }
                chipPill(icon: "tag",
                         text: "\(options.count.formatted()) 个关键词 · \(photos.formatted()) 张")
            }
        case .health, .systemHealth:
            if store.isScanningHealth {
                chipPill(icon: "stethoscope",
                         text: "检查中 \(Int(store.healthScanProgress * 100))% · 模糊 \(store.healthReport?.blurry.count ?? 0) 张")
            } else if store.isFinalizingHealth {
                chipPill(icon: "stethoscope",
                         text: "整理中 · 已查 \(store.healthReport?.scannedCount ?? 0) 张")
            } else if store.healthReportMatchesCurrentScope, let report = store.healthReport {
                chipPill(icon: "stethoscope",
                         text: "模糊 \(report.blurry.count) · 相似 \(report.similarDuplicatePhotos.count) · 已查 \(report.scannedCount)")
            } else {
                chipPill(icon: "stethoscope", text: "本机检查照片质量")
            }
        case .systemImportSession(let id):
            importSessionChip(id)
        default:
            EmptyView()
            }
        }
    }
    /// 导入批次页的顶栏信息：这批内容的导入时间、照片 / 视频构成与拍摄跨度。
    @ViewBuilder
    private func importSessionChip(_ id: Int64) -> some View {
        let summary = store.systemImportSessionSummary(id)
        HStack(spacing: 9) {
            chipText(icon: "square.and.arrow.down.on.square",
                     text: importSessionDateText(id))
            chipDivider
            chipText(icon: "photo.on.rectangle",
                     text: importCompositionText(summary))
            if let span = importCaptureSpanText(summary) {
                chipDivider
                chipText(icon: "calendar", text: span)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
        .help("这次导入的批次信息")
    }

    private var chipDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 0.6, height: 13)
    }

    private func importSessionDateText(_ id: Int64) -> String {
        guard let session = store.systemImportSessions.first(where: { $0.id == id }) else {
            return "导入批次"
        }
        return "\(DateText.fullFormatter.string(from: session.createdAt)) 导入"
    }

    private func importCompositionText(_ summary: SystemImportSessionSummary?) -> String {
        guard let summary, summary.totalCount > 0 else {
            return "\(store.visibleCount.formatted()) 项"
        }
        if summary.videoCount > 0 {
            let photos = max(0, summary.totalCount - summary.videoCount)
            return "\(photos.formatted()) 照片 · \(summary.videoCount.formatted()) 视频"
        }
        return "\(summary.totalCount.formatted()) 项"
    }

    private func importCaptureSpanText(_ summary: SystemImportSessionSummary?) -> String? {
        guard let summary, let earliest = summary.earliest, let latest = summary.latest else { return nil }
        let calendar = Calendar.current
        if calendar.isDate(earliest, inSameDayAs: latest) {
            return "拍摄于 \(DateText.dayFormatter.string(from: earliest))"
        }
        let start = DateText.dayFormatter.string(from: earliest)
        let end = DateText.dayFormatter.string(from: latest)
        let days = (calendar.dateComponents([.day],
                                            from: calendar.startOfDay(for: earliest),
                                            to: calendar.startOfDay(for: latest)).day ?? 0) + 1
        return "拍摄 \(start) – \(end) · 跨 \(days) 天"
    }

    // MARK: - 工具栏内容

    @ViewBuilder
    private var navigationToolbarContent: some View {
        if showsCinemaConsole {
            // 影院控制台由工具栏里的左右两段承担，这里不再重复显示。
            EmptyView()
        } else if isCloudMountScope,
                  store.cloudBreadcrumbChain.count > 1 || store.cloudOverviewSection != nil {
            LumaBreadcrumbBar(crumbs: cloudBreadcrumbCrumbs) { crumb in
                selectCloudCrumb(crumb)
            }
        } else if store.albumBreadcrumbs.count > 1 {
            LumaBreadcrumbBar(crumbs: store.albumBreadcrumbs.map {
                LumaBreadcrumbBar.Crumb(id: $0.id, title: $0.title)
            }) { crumb in
                if let target = store.albumBreadcrumbs.first(where: { $0.id == crumb.id }) {
                    store.navigate(to: target.item)
                }
            }
        } else if let parent = store.navigationParent {
            Button {
                store.navigateUp()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(parent.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                }
            }
            .help("返回\(parent.title)")
            .accessibilityLabel("返回\(parent.title)")
        }
    }

    private var isCloudMountScope: Bool { store.isCloudScope }

    /// 影院（本地图库或某个网盘的）在顶栏显示专用的控制台。
    private var isCinemaScope: Bool {
        switch store.sidebarItem {
        case .cinema, .cloudCinema: return true
        default: return false
        }
    }

    /// 影院顶栏控制台常驻（搜索时也不换血），避免输入第一个字时整条工具栏重建、搜索框失焦。
    private var showsCinemaConsole: Bool {
        isCinemaScope
    }

    /// 网盘面包屑：整个网盘 → 文件夹相簿链路；分类总览或具体分类再追加一节。
    private var cloudBreadcrumbCrumbs: [LumaBreadcrumbBar.Crumb] {
        var crumbs = store.cloudBreadcrumbChain.map {
            LumaBreadcrumbBar.Crumb(id: "folder:" + $0.id, title: $0.name)
        }
        if let section = store.cloudOverviewSection {
            crumbs.append(LumaBreadcrumbBar.Crumb(id: "overview", title: section.title))
        } else if store.cloudScope != .all {
            crumbs.append(LumaBreadcrumbBar.Crumb(id: "scope", title: store.cloudScope.title))
        }
        return crumbs
    }

    private func selectCloudCrumb(_ crumb: LumaBreadcrumbBar.Crumb) {
        if crumb.id == "overview" {
            store.showCloudOverview(nil)
            return
        }
        if crumb.id == "scope" {
            // 与拾光的分类页一致：点当前分类退回整个网盘（关键词退回关键词总览）。
            store.setCloudScope(store.cloudScope.keywordOverviewParent ?? .all)
            return
        }
        // 总览页点节点：先退出总览与分类，再进入目标目录。
        if store.cloudOverviewSection != nil {
            store.showCloudOverview(nil)
        }
        if store.cloudScope != .all {
            store.setCloudScope(store.cloudScope.keywordOverviewParent ?? .all)
        }
        let path = String(crumb.id.dropFirst("folder:".count))
        store.selectCloudFolder(path: path == store.cloudBreadcrumbRootID ? nil : path)
    }

    /// 网盘工具栏动作：刷新与（可写时）新建 / 上传，与其它工具胶囊同一套外观。
    private var cloudToolbarActions: some View {
        GalleryToolbarPill {
            if store.isCurrentCloudWritable {
                Menu {
                    Button("新建文件夹…") { store.requestCloudNewFolder() }
                    Button("上传照片/视频…") { store.presentCloudUploadPanel() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建文件夹或上传")
            }
            Button {
                store.refreshCloudDirectory()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("重新扫描这个网盘")
        }
    }

    @ViewBuilder
    private var principalToolbarContent: some View {
        if isCloudMountScope {
            // 与拾光 / 系统图库同一套中间栏：总览与专用页面由窗口标题表达；
            // 普通照片列表显示年 / 月 / 所有照片分组，分类页显示对应上下文。
            if store.cloudOverviewSection != nil {
                EmptyView()
            } else if isCloudGridScope, store.isTimelineScope {
                TimelineGroupingSwitch(selection: $store.grouping)
            } else if showsContextChip {
                contextChip
            } else if isOrganizeScope {
                organizeStatsChip
            }
        } else if isGridScope, store.isTimelineScope {
            TimelineGroupingSwitch(selection: $store.grouping)
        } else if isGridScope, store.isFavoritesScope {
            if let bucket = store.selectedFavoriteBucket {
                favoritesBucketChip(bucket)
            } else {
                FavoritesViewModeSwitch()
            }
        } else if isVideoHubScope, !hasSearchText {
            // 与「位置」一致：统计胶囊 + 分段视图 + 筛选靠右，标题留在左侧。
            videoHubPrincipalControls
        } else if showsContextChip {
            contextChip
        } else if isOrganizeScope {
            organizeStatsChip
        }
    }

    @ViewBuilder
    private var primaryActionToolbarContent: some View {
        if isCloudMountScope {
            cloudToolbarActions
        }
        if isPlacesScope {
            PlaceGranularitySwitch()
            placesSearchField
        }
        if isMapScope {
            // 搜索时页面已经切成结果页，地图底图切换不再有意义。
            if !hasSearchText {
                MapStyleSwitch()
            }
            gallerySearchField
        }
        if store.sidebarItem == .people || store.sidebarItem == .systemPeople
            || (store.isCloudScope && store.cloudScope == .people) {
            PeopleGroupFilterSwitch()
        }
        if store.sidebarItem == .health || store.sidebarItem == .systemHealth {
            GalleryToolbarPill { healthToolbarActions }
        }
        if isOrganizeScope {
            OrganizeDimensionSwitch()
        }
        if isGridScope {
            // 收藏汇总维度页也要保留这一组：切维度时右侧工具栏不能突然少两块。
            galleryLayoutPill
        }
        // 网络资源 / 网络存储总览（资源 / 索引 / 影院 …）没有单张照片动作：助手、⋯、信息、分享、
        // 收藏在这里都无意义，只保留搜索。
        if !isCatalogHubScope && !isCloudStoragesHubScope {
            galleryActionPill
        }
        if !isPlacesScope && !isRevisitScope && !isMapScope {
            gallerySearchField
        }
    }

    private func chipPill(icon: String, text: String) -> some View {
        chipText(icon: icon, text: text)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
    }

    /// 整理工作室的汇总：已评分 / 已选 / 已拒绝 / 有颜色，与「位置」的统计胶囊同一套语言。
    private var organizeStatsChip: some View {
        let stats = store.organizeStudioStats
        return HStack(spacing: 8) {
            organizeStatItem("已评分", stats.rated, icon: "star.fill", tint: LumaBrand.amber)
            chipDivider
            organizeStatItem("已选", stats.pick, icon: "flag.fill", tint: LumaBrand.mint)
            chipDivider
            organizeStatItem("已拒绝", stats.reject, icon: "xmark.circle.fill", tint: LumaBrand.coral)
            chipDivider
            organizeStatItem("有颜色", stats.labeled, icon: "paintpalette.fill", tint: LumaBrand.violet)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
        .help("当前图库的评分、旗标与色标汇总")
    }

    private func organizeStatItem(_ title: String, _ value: Int,
                                  icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(value.formatted())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .help(title)
    }

    /// 收藏汇总下钻后的顶栏：返回汇总 + 当前分类 + 数量。
    private func favoritesBucketChip(_ bucket: FavoritesBucketSelection) -> some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    store.clearFavoritesBucket()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(store.favoritesViewMode.title)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回\(store.favoritesViewMode.title)汇总")

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 0.6, height: 13)

            chipText(icon: bucket.dimension == .person ? "person.crop.circle" : bucketIcon(bucket),
                     text: "\(bucket.title) · \(store.visibleCount.formatted()) 项")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
        .help("当前只显示该分类的收藏")
    }

    private func bucketIcon(_ bucket: FavoritesBucketSelection) -> String {
        switch bucket.dimension {
        case .year: return "calendar"
        case .kind: return FavoriteKindBucket(rawValue: bucket.key)?.icon ?? "photo"
        case .place: return "mappin.and.ellipse"
        case .camera: return "camera"
        case .person: return "person.crop.circle"
        }
    }

    private func chipPillAction<Trailing: View>(icon: String,
                                                text: String,
                                                @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            chipText(icon: icon, text: text)
            trailing()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
    }

    private func chipText(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var placesSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索地点", text: $placesQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 120)
            if !placesQuery.isEmpty {
                Button {
                    placesQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .help("搜索地点")
    }

    /// 顶栏搜索框：固定宽度、与两侧胶囊同高，避免系统搜索框铺满整条工具栏。
    private var gallerySearchField: some View {
        HStack(spacing: 6) {
            Button {
                isSearchFieldFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSearchFieldFocused ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("搜索照片（⌘F）")

            TextField("搜索名称、场景、图内文字", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFieldFocused)
                .onSubmit { isSearchFieldFocused = false }
                .onExitCommand {
                    if store.searchText.isEmpty {
                        isSearchFieldFocused = false
                    } else {
                        store.searchText = ""
                    }
                }

            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }

            Button {
                store.searchScope = store.searchScope == .global ? .currentView : .global
            } label: {
                Text(store.searchScope.shortTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("搜索范围：\(store.searchScope.title)（点击切换）")
        }
        .padding(.horizontal, 11)
        .frame(width: 280, height: 32)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(isSearchFieldFocused
                              ? Color.accentColor.opacity(0.55)
                              : Color.primary.opacity(0.10),
                              lineWidth: isSearchFieldFocused ? 1 : 0.5)
        }
        .contentShape(Capsule())
        .help("搜索照片：名称、场景、图内文字（⌘F，Esc 清除）")
        .accessibilityLabel("搜索照片")
    }

    /// 影院顶栏搜索：与放映机控制台同一套内嵌屏质感，浅色下换成香槟白屏。
    private var cinemaSearchField: some View {
        let dark = scheme == .dark
        let accent = dark ? LumaBrand.amber : Color(red: 0.62, green: 0.41, blue: 0.08)
        let primaryText = dark ? Color.white.opacity(0.92) : Color(white: 0.15)
        let placeholder = dark ? Color.white.opacity(0.32) : Color(white: 0.52)
        let iconIdle = dark ? Color.white.opacity(0.50) : Color(white: 0.42)
        let faint = dark ? Color.white.opacity(0.45) : Color(white: 0.55)

        return HStack(spacing: 6) {
            Button {
                isSearchFieldFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isSearchFieldFocused ? accent : iconIdle)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("搜索影片（⌘F）")

            ZStack(alignment: .leading) {
                if store.searchText.isEmpty {
                    Text("搜索名称、场景、图内文字")
                        .font(.system(size: 11))
                        .foregroundStyle(placeholder)
                        .allowsHitTesting(false)
                }
                TextField("", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(primaryText)
                    .focused($isSearchFieldFocused)
                    .onSubmit { isSearchFieldFocused = false }
                    .onExitCommand {
                        if store.searchText.isEmpty {
                            isSearchFieldFocused = false
                        } else {
                            store.searchText = ""
                        }
                    }
            }

            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(faint)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }

            Button {
                store.searchScope = store.searchScope == .global ? .currentView : .global
            } label: {
                Text(store.searchScope.shortTitle)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(store.searchScope == .global ? accent : faint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06),
                                in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("搜索范围：\(store.searchScope.title)（点击切换）")
        }
        .padding(.horizontal, 9)
        .frame(width: 224, height: 26)
        .background {
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: dark
                                     ? [Color(white: 0.14), Color(white: 0.075)]
                                     : [Color(white: 0.995), Color(white: 0.945)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [.black.opacity(dark ? 0.30 : 0.05), .clear],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(isSearchFieldFocused
                              ? accent.opacity(0.70)
                              : (dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)),
                              lineWidth: isSearchFieldFocused ? 1 : 0.7)
        }
        .shadow(color: isSearchFieldFocused ? accent.opacity(0.18) : .clear, radius: 6)
        .contentShape(Capsule())
        .help("搜索影片：名称、场景、图内文字（⌘F，Esc 清除）")
        .accessibilityLabel("搜索影片")
    }

    @ViewBuilder
    private var healthToolbarActions: some View {
        if store.isScanningHealth {
            Button {
                store.cancelHealthScan()
            } label: {
                GalleryToolbarIconLabel(systemName: "stop.circle")
            }
            .buttonStyle(.plain)
            .help("停止本次体检")
        } else {
            Button {
                store.showBeautyPanel = true
            } label: {
                GalleryToolbarIconLabel(systemName: "wand.and.stars")
            }
            .buttonStyle(.plain)
            .disabled(!store.canScanBeauty)
            .help("按画面偏差推荐可批量美化的照片")

            Button {
                store.scanLibraryHealth()
            } label: {
                GalleryToolbarIconLabel(systemName: "stethoscope")
            }
            .buttonStyle(.plain)
            .disabled(!store.canScanHealth || store.isFinalizingHealth)
            .help("扫描当前图库的照片质量与重复内容")
        }
    }

    // MARK: - Keyboard

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSTextField
    }

    private var gridColumnCount: Int {
        store.gridColumnCount
    }

    /// 把真实网格宽度回传给 Store，设置面板「每行几张」与实际网格保持一致。
    private func updateGridContentWidth(_ width: CGFloat) {
        let value = max(120, width)
        if abs(store.gridContentWidth - value) > 0.5 {
            store.gridContentWidth = value
        }
        store.reconcileDefaultDensitiesIfNeeded()
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = hostWindow ?? event.window else { return false }
        guard event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard isGridScope || showsSearchResultsGrid,
              !isFavoritesDigestHub,
              store.viewerID == nil,
              store.editorID == nil,
              !store.showSlideshow,
              store.activeMemory == nil,
              store.activeTrip == nil,
              !store.showNewAlbumSheet,
              !store.showKeywordManager,
              !store.showShortcutHelp,
              // 确认卡片打开时，把键盘交给卡片（避免误触网格操作）。
              !store.hasPendingConfirmation else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            // 文本输入中不劫持 ⌘A/⌘C/⌘F 等系统文本命令。
            if isEditingText { return false }
            if event.keyCode == 51 {
                guard !store.isReadOnlyScope else { return false }
                let ids = selectionModel.ids
                guard !ids.isEmpty else { return false }
                // 最近删除里再按删除就是永久删除（需确认）。
                if flags.contains(.option) || store.sidebarItem == .trash {
                    store.confirmPermanentDelete(ids)
                } else {
                    store.confirmDelete(ids)
                }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                store.selectAll()
                return true
            case "c":
                store.copySelectionToPasteboard()
                return true
            case "v":
                guard !store.isReadOnlyScope else { return false }
                store.pasteFromPasteboard()
                return true
            case "d":
                guard !store.isReadOnlyScope, !selectionModel.ids.isEmpty else { return false }
                store.duplicateCommand()
                return true
            case "f":
                store.focusSearchField()
                return true
            case "r":
                guard !store.isReadOnlyScope else { return false }
                store.rotateCommand(clockwise: !flags.contains(.option))
                return true
            case "0":
                store.resetZoom()
                return true
            default:
                return false
            }
        }
        // 方向键自带 Function / 小键盘标记，不能因此丢弃；
        // 只屏蔽会与菜单快捷键冲突的修饰键。
        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于这条守卫匹配。
        if handleCustomShortcut(event) { return true }

        guard flags.intersection([.option, .control]).isEmpty else { return false }

        // 正在输入搜索词且尚未选中任何项目时，把方向键留给文本输入。
        if isEditingText, selectionModel.ids.isEmpty { return false }

        switch event.keyCode {
        case 123:
            // 「图库」页新照片在底部时，数据顺序与视觉顺序相反，左右键跟随视觉方向。
            store.moveSelection(by: store.timelineShowsNewestAtBottom ? 1 : -1)
            return true
        case 124:
            store.moveSelection(by: store.timelineShowsNewestAtBottom ? -1 : 1)
            return true
        case 126:
            moveSelectionVertically(-1)
            return true
        case 125:
            moveSelectionVertically(1)
            return true
        case 47:
            guard !flags.contains(.shift), !selectionModel.ids.isEmpty,
                  store.canToggleFavorite else { return false }
            store.toggleFavoriteSelection()
            return true
        case 36, 49:
            // 搜索框等文本输入中，空格与回车要正常输入文字。
            if isEditingText { return false }
            guard !selectionModel.ids.isEmpty else { return false }
            store.openSelectionInViewer()
            return true
        case 53:
            guard !selectionModel.ids.isEmpty else { return false }
            store.clearSelection()
            return true
        default:
            return false
        }
    }

    /// 设置 › 快捷键里可自定义的网格动作。
    private func handleCustomShortcut(_ event: NSEvent) -> Bool {
        // 搜索框等文本输入中，回车 / 字母都要正常输入文字。
        guard !isEditingText else { return false }
        if ShortcutStore.matches(event, .galleryOpen) {
            guard !selectionModel.ids.isEmpty else { return false }
            store.openSelectionInViewer()
            return true
        }
        if ShortcutStore.matches(event, .galleryFavorite) {
            guard !selectionModel.ids.isEmpty, store.canToggleFavorite else { return false }
            store.toggleFavoriteSelection()
            return true
        }
        return false
    }

    // MARK: - Content

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if isGlobalSearchActive {
            SearchResultsPage(query: store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                photoContent(width: width)
            }
        } else if showsSearchResultsGrid {
            photoContent(width: width)
        } else {
            switch store.sidebarItem {
            case .cinema:
                CinemaLibraryView()
            case .videos, .systemVideos:
                VideoHubView()
            case .cloudCinema(let mountID):
                CinemaLibraryView(mountID: mountID)
            case .collections:
                CollectionsView()
            case .systemCollections:
                SystemCollectionsView()
            case .map, .systemMap:
                PhotoMapView()
            case .places, .systemPlaces:
                PlaceStatisticsView(query: $placesQuery)
            case .duplicates:
                DuplicatesView()
            case .systemDuplicates:
                DuplicatesView(system: true)
            case .health, .systemHealth:
                LibraryHealthView()
            case .ratings, .systemRatings, .flags, .systemFlags,
                 .colorLabels, .systemColorLabels:
                OrganizeStudioView()
            case .allAlbums:
                AlbumsOverviewView()
            case .folder(let id):
                AlbumsOverviewView(folderID: id)
            case .systemFolder(let id):
                SystemFolderOverviewView(folderID: id)
            case .systemAlbums:
                SystemFolderOverviewView()
            case .mediaTypes, .systemMediaTypes:
                MediaTypesOverviewView()
            case .scenes, .systemScenes:
                ScenesOverviewView()
            case .moreItems:
                MoreItemsOverviewView(system: false)
            case .systemMoreItems:
                MoreItemsOverviewView(system: true)
            case .keywords:
                KeywordGalleryView(system: false)
            case .systemKeywords:
                KeywordGalleryView(system: true)
            case .systemImports:
                ImportSessionsOverviewView()
            case .systemLibraries:
                SystemLibrariesOverviewView()
            case .cloudStorages:
                CloudStoragesHubView()
            case .catalogSources:
                CatalogHubView()
            case .people, .systemPeople:
                PeopleView()
            case .revisit, .systemRevisit:
                RevisitView()
            case .catalogSource(let id):
                CatalogChannelView(sourceID: id)
            case .cloudMount:
                if isCloudGridScope {
                    // 与拾光 / 系统图库同一套网格：分组、排序、筛选、缩放、列表形式与计数胶囊都复用。
                    photoContent(width: width)
                        .task(id: cloudGridPrefetchKey) {
                            guard let task = store.prefetchCloudThumbnails(for: store.visiblePhotos) else { return }
                            await withTaskCancellationHandler {
                                await task.value
                            } onCancel: {
                                task.cancel()
                            }
                        }
                } else if let section = store.cloudOverviewSection {
                    CloudOverviewView(section: section)
                } else {
                    // 网盘专属页面：与拾光 / 系统图库的同名页面共用同一个入口位置。
                    switch store.cloudScope {
                    case .map:
                        PhotoMapView()
                    case .places:
                        PlaceStatisticsView(query: $placesQuery)
                    case .keywords:
                        CloudKeywordGalleryView()
                    case .people:
                        CloudPeopleView()
                    case .duplicates:
                        CloudDuplicatesView()
                    case .health:
                        CloudHealthView()
                    case .revisit:
                        // 与拾光 / 系统图库同一套「值得重看」主体页，数据源切到当前网盘目录。
                        RevisitView()
                    case .ratings:
                        // 与系统图库同一套整理工作台：评分 / 旗标 / 色标只在拾光本地记录。
                        OrganizeStudioView()
                    case .recentlyEdited, .trash, .imports:
                        CloudReadOnlyScopeView(scope: store.cloudScope)
                    default:
                        photoContent(width: width)
                    }
                }
            case .favorites, .systemFavorites:
                if store.favoritesViewMode != .all, store.selectedFavoriteBucket == nil {
                    FavoritesDigestView()
                } else if store.selectedFavoriteBucket != nil {
                    photoContent(width: width)
                        .task(id: store.favoritesDigestToken) {
                            store.loadFavoritesDigestIfNeeded()
                        }
                } else {
                    photoContent(width: width)
                }
            default:
                photoContent(width: width)
            }
        }
    }

    /// 普通照片网格：空状态、加载状态与年 / 月总览都在这里。
    @ViewBuilder
    private func photoContent(width: CGFloat) -> some View {
        // 年 / 月总览的数据来自分区查询，系统图库的内存窗口此时为空，
        // 不能按 visibleCount 判定为「没有照片」，否则会直接显示空状态。
        let showsTimelineOverview = store.isTimelineScope && store.grouping != .all
        if store.visibleCount == 0, !showsTimelineOverview {
            if store.isCloudScope {
                // 网盘的空态还要承担扫描进度、错误与重新授权入口。
                CloudGridEmptyState()
            } else if store.isPagedScope, store.isPagedWindowLoading || !store.hasLoadedPagedWindow {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在读取图库…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isLoadingSystemLibrary, store.isSystemScope {
                // 读取进度统一显示在顶部状态胶囊里，这里留空避免同一句文案出现两遍。
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
            }
        } else {
            photoGrid(width: width)
        }
    }

    // MARK: - 底部计数胶囊

    /// 网格页在底部居中显示当前范围的照片/视频总数（对齐系统「照片」）。
    /// 选中照片后计数标签仍然保留，方便边选边看范围规模。
    private var showsCountPill: Bool {
        (isGridScope || showsSearchResultsGrid) && store.visibleCount > 0
            && !(store.isFavoritesScope && store.favoritesViewMode != .all
                 && store.selectedFavoriteBucket == nil)
    }

    private var countPill: some View {
        HStack(spacing: 6) {
            Image(systemName: store.visibleVideoCount > 0 && store.visibleCount == store.visibleVideoCount
                  ? "video" : "photo.stack")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(countPillText)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .lumaGlassCapsule()
        .animation(settings.motion.overlay, value: countPillText)
        .accessibilityLabel(countPillText)
    }

    private var countPillText: String {
        let total = store.visibleCount
        let videos = store.visibleVideoCount
        let photos = total - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos.formatted()) 张照片") }
        if videos > 0 { parts.append("\(videos.formatted()) 个视频") }
        return parts.joined(separator: "、")
    }

    @ViewBuilder
    private func photoGrid(width: CGFloat) -> some View {
        if store.isTimelineScope {
            switch store.grouping {
            case .years:
                YearOverviewView(width: width)
            case .months:
                MonthOverviewView(width: width)
            case .all:
                allPhotosGrid(width: width)
            }
        } else {
            allPhotosGrid(width: width)
        }
    }

    /// 系统图库超大时按「首屏 1200 张」渐进渲染；索引分页模式由 `loadMoreVisibleWindow` 负责。
    private var systemWindowActive: Bool {
        !store.isSystemPagedScope && store.isSystemScope && store.grouping == .all && store.visibleCount > 1_500
    }

    private var canLoadMoreSystemWindow: Bool {
        systemWindowActive && systemRenderLimit < store.visibleCount
    }

    /// 范围、筛选、搜索或排序变化时，把系统图库的渲染窗口收回首屏。
    private var systemWindowKey: String {
        [String(describing: store.sidebarItem), store.photoFilter.rawValue,
         store.keywordFilter ?? "", store.searchText,
         store.sortKey.rawValue, String(store.sortAscending)]
            .joined(separator: "\u{1F}")
    }

    /// 消费 `store.scrollTargetID`：默认居中，关闭查看器时用最小滚动（已可见就不动）。
    private func scrollToRequestedTarget(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = store.scrollTargetID else { return }
        let anchor: UnitPoint? = store.scrollTargetMinimal ? nil : .center
        store.scrollTargetMinimal = false
        if animated {
            withAnimation(.snappy(duration: 0.28)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
        store.scrollTargetID = nil
    }

    private func windowedPhotos(_ photos: [PhotoItem]) -> [PhotoItem] {
        guard systemWindowActive, photos.count > systemRenderLimit else { return photos }
        return Array(photos.prefix(systemRenderLimit))
    }

    private func allPhotosGrid(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { container in
                if store.timelineShowsNewestAtBottom {
                    reversePhotoGrid(width: width, viewport: container.size, proxy: proxy)
                } else if store.supportsTimelineJump {
                    forwardPagedGrid(width: width, viewport: container.size, proxy: proxy)
                } else {
                    forwardPhotoGrid(width: width, viewport: container.size, proxy: proxy)
                }
            }
        }
        .id(gridPageIdentity)
    }

    /// 回到「所有照片」后把视野拉回已加载窗口：窗口不在最新一页时，
    /// 下方全是按总数生成的空白占位，停在默认位置会整屏空白。
    private func restoreTimelinePosition(_ proxy: ScrollViewProxy) {
        guard needsTimelineRestore else { return }
        // 范围切换后新窗口是异步取回的：旧窗口还在时先不定位，
        // 等 `hasLoadedPagedWindow` 变化后再由调用方补一次。
        if store.isPagedScope, !store.isPagedWindowFresh { return }
        guard let target = store.newestLoadedPhotoID else { return }
        needsTimelineRestore = false
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: store.timelineShowsNewestAtBottom ? .bottom : .top)
        }
    }

    /// 时间轴网格的页面身份：范围 / 分组 / 排序 / 过滤变化时重建滚动视图，
    /// 与 macOS 官方「照片」一致，换页后不再沿用上一页的滚动偏移。
    private var gridPageIdentity: String {
        [String(describing: store.sidebarItem),
         store.grouping.rawValue,
         store.sortKey.rawValue,
         String(store.sortAscending),
         store.photoFilter.rawValue,
         String(store.timelineShowsNewestAtBottom),
         cloudPageIdentity]
            .joined(separator: "|")
    }

    /// 网盘页面身份：sidebarItem 始终是 `.cloudMount`，切换范围 / 目录 / 总览必须显式参与身份。
    private var cloudPageIdentity: String {
        guard store.isCloudScope else { return "" }
        return [store.currentCloudMountID?.uuidString ?? "",
                store.cloudSelectedFolderPath ?? "",
                String(describing: store.cloudScope),
                store.cloudOverviewSection?.rawValue ?? ""]
            .joined(separator: "|")
    }

    /// 网盘缩略图预取键：范围 / 目录 / 数量变化时重启预取。
    private var cloudGridPrefetchKey: String {
        guard store.isCloudScope else { return "" }
        return [cloudPageIdentity,
                String(store.visibleCount / 200)]
            .joined(separator: "|")
    }

    /// 常规方向（最新在上）：分段网格 + 悬浮分段头 + 底部继续加载。
    private func forwardPhotoGrid(width: CGFloat, viewport: CGSize, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // 滚动探针：把内容上移量换算成当前可见区域，驱动顶栏日期范围。
                GeometryReader { geo in
                    Color.clear.preference(
                        key: GalleryScrollOffsetKey.self,
                        value: -geo.frame(in: .named(GalleryScrollSpace.name)).minY
                    )
                }
                .frame(height: 0)

                ForEach(store.sections) { section in
                    Section {
                        sectionGrid(photos: windowedPhotos(section.photos), width: width)
                    } header: {
                        if let title = section.title {
                            SectionHeaderView(title: title, count: section.photos.count)
                        }
                    }
                }
                if store.canLoadMoreVisible || canLoadMoreSystemWindow {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载更多…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .lumaGlassCapsule(shadow: false)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .onAppear {
                        if store.canLoadMoreVisible {
                            store.loadMoreVisibleWindow()
                        } else if canLoadMoreSystemWindow {
                            systemRenderLimit += 1_200
                        }
                    }
                    .onChange(of: store.windowPhotos.count) { _, _ in
                        store.loadMoreVisibleWindow()
                    }
                    .help("继续加载更多照片")
                }
                Color.clear.frame(height: 76)
            }
            .onPreferenceChange(PhotoFramePreferenceKey.self) { frames in
                frameCache.frames = frames
                guard store.grouping == .all else { return }
                lastDateSpanOffset = .greatestFiniteMagnitude
                updateVisibleDateSpan(offset: lastScrollOffset,
                                      viewportHeight: viewport.height)
            }
            .onPreferenceChange(GalleryScrollOffsetKey.self) { offset in
                lastScrollOffset = offset
                updateVisibleDateSpan(offset: offset, viewportHeight: viewport.height)
                // macOS 14 没有 onScrollGeometryChange：用滚动探针换算的偏移兜底驱动取页。
                if #unavailable(macOS 15.0) {
                    preloadForwardPageIfNeeded(offset: offset, viewport: viewport.height, width: width)
                    handleTimelineScroll(offset: offset,
                                         viewport: viewport,
                                         width: width,
                                         orientation: .newestAtTop)
                }
            }
            .photoMarqueeSelection(fillHeight: viewport.height)
        }
        .scrollIndicators(.automatic)
        .coordinateSpace(name: GalleryScrollSpace.name)
        .defaultScrollAnchor(.top)
        .onAppear {
            if store.scrollTargetID != nil {
                DispatchQueue.main.async {
                    scrollToRequestedTarget(proxy, animated: false)
                }
            } else {
                restoreTimelinePosition(proxy)
            }
        }
        .onChange(of: systemWindowKey) { _, _ in systemRenderLimit = 1_200 }
        .onChange(of: store.pagedKey) { _, _ in lastDateSpanOffset = .greatestFiniteMagnitude }
        .simultaneousGesture(pinchGesture)
        .onChange(of: store.scrollTargetID) { _, target in
            guard target != nil else { return }
            scrollToRequestedTarget(proxy, animated: true)
        }
    }

    /// 正序（最新在上）的分页网格：已加载窗口在上，下面按整库总数留出「更早照片」的等高占位，
    /// 滚动条因此一次覆盖整库；滚到窗口下沿自动取下一页，拖进占位区则按排名重定位窗口。
    private func forwardPagedGrid(width: CGFloat, viewport: CGSize, proxy: ScrollViewProxy) -> some View {
        let layout = timelineLayout(width: width, orientation: .newestAtTop)
        return ScrollView {
            // 与反序时间轴同款非懒容器：整库占位交给 VStack 首帧定高，网格内部仍由 LazyVGrid 懒渲染。
            VStack(alignment: .leading, spacing: 0) {
                // 滚动探针：把内容上移量换算成当前可见区域，驱动顶栏日期范围。
                GeometryReader { geo in
                    Color.clear.preference(
                        key: GalleryScrollOffsetKey.self,
                        value: -geo.frame(in: .named(GalleryScrollSpace.name)).minY
                    )
                }
                .frame(height: 0)

                // 窗口上方（更新）未加载的照片。
                if layout.newerCount > 0 {
                    Color.clear.frame(height: layout.newerHeight)
                }
                ForEach(store.sections) { section in
                    if let title = section.title {
                        SectionHeaderView(title: title, count: section.photos.count)
                    }
                    sectionGrid(photos: section.photos, width: width)
                }
                // 窗口下方（更早）未加载的照片：用等高空白代表，滚动条才反映整库长度。
                if layout.olderCount > 0 {
                    Color.clear.frame(height: layout.olderHeight)
                }
                Color.clear.frame(height: 76)
            }
            .onPreferenceChange(PhotoFramePreferenceKey.self) { frames in
                frameCache.frames = frames
                guard store.grouping == .all else { return }
                lastDateSpanOffset = .greatestFiniteMagnitude
                updateVisibleDateSpan(offset: lastScrollOffset, viewportHeight: viewport.height)
            }
            .onPreferenceChange(GalleryScrollOffsetKey.self) { offset in
                lastScrollOffset = offset
                updateVisibleDateSpan(offset: offset, viewportHeight: viewport.height)
            }
            .photoMarqueeSelection(fillHeight: viewport.height)
        }
        .scrollIndicators(.automatic)
        .coordinateSpace(name: GalleryScrollSpace.name)
        .defaultScrollAnchor(.top)
        .overlay(alignment: .top) {
            // 换页 / 接续加载期间给一个浮层提示，不参与内容高度，不会顶动网格。
            if store.isPagedWindowLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .lumaGlassCapsule(shadow: false)
                    .padding(.top, 10)
            }
        }
        .modifier(TimelineScrollObserver { value in
            lastScrollOffset = value.offset
            updateVisibleDateSpan(offset: value.offset, viewportHeight: value.viewport)
            // 提前一屏预取下一页：等滚到占位边缘时数据已经到手，不会出现空白停顿。
            preloadForwardPageIfNeeded(offset: value.offset, viewport: value.viewport, width: width)
            handleTimelineScroll(offset: value.offset,
                                 viewport: CGSize(width: width, height: value.viewport),
                                 width: width,
                                 orientation: .newestAtTop)
        })
        .onAppear {
            lastTimelineJumpOffset = -1
            if store.scrollTargetID != nil {
                DispatchQueue.main.async {
                    scrollToRequestedTarget(proxy, animated: false)
                }
            } else {
                restoreTimelinePosition(proxy)
            }
        }
        .onChange(of: store.pagedKey) { _, _ in
            lastDateSpanOffset = .greatestFiniteMagnitude
            lastTimelineJumpOffset = -1
            timelineJumpTask?.cancel()
        }
        .onChange(of: store.loadedWindowPhotos.count) { _, _ in
            // 换页 / 接续加载完成后占位已重新配平：清掉旧偏移，下一次滚动按新布局重新决策。
            lastTimelineJumpOffset = -1
            restoreTimelinePosition(proxy)
        }
        .onChange(of: store.hasLoadedPagedWindow) { _, loaded in
            // 范围切换后新窗口取回：此时才按真实数据把视野锚回时间轴起点。
            guard loaded else { return }
            restoreTimelinePosition(proxy)
        }
        .onChange(of: store.timelineJumpLandingID) { _, target in
            guard let target else { return }
            // 换页后的第一次滚动由系统执行，期间不要把它当成用户拖动再次换页。
            suppressTimelineJumpsUntil = Date().timeIntervalSince1970 + 1.2
            DispatchQueue.main.async {
                proxy.scrollTo(target, anchor: .center)
                store.timelineJumpLandingID = nil
            }
        }
        .onChange(of: store.scrollTargetID) { _, target in
            guard target != nil else { return }
            scrollToRequestedTarget(proxy, animated: true)
        }
        .simultaneousGesture(pinchGesture)
    }

    /// 「新照片在底部」：内容按旧 → 新排列，进入即停在最新一屏；上方按未加载数量留虚拟占位，
    /// 滚动条因此代表整库长度（整库超高时按比例压缩，避免超出 macOS 可渲染高度导致整屏空白）。
    /// 向上滚到已加载窗口顶部时接续取更早一页；拖动条拖进占位区时按排名整体重定位窗口。
    private func reversePhotoGrid(width: CGFloat, viewport: CGSize, proxy: ScrollViewProxy) -> some View {
        let photos = store.sections.reversed().flatMap { $0.photos.reversed() }
        let layout = timelineLayout(width: width, orientation: .newestAtBottom)
        return ScrollView {
            // 这里必须用非懒容器：外层 LazyVStack 会把「巨大占位 + 网格」一起懒估算，
            // 实测网格内容高度为 0（一张都不渲染）；VStack 让高度在首帧就确定。
            VStack(alignment: .leading, spacing: 0) {
                // 未加载的更早照片：用等高空白代表，滚动条才反映整库长度。
                if layout.olderCount > 0 {
                    Color.clear.frame(height: layout.olderHeight)
                }
                sectionGrid(photos: photos, width: width)
                if layout.newerCount > 0 {
                    Color.clear.frame(height: layout.newerHeight)
                }
                Color.clear.frame(height: 76)
            }
            .onPreferenceChange(PhotoFramePreferenceKey.self) { frames in
                frameCache.frames = frames
                lastDateSpanOffset = .greatestFiniteMagnitude
                updateVisibleDateSpan(offset: lastScrollOffset, viewportHeight: viewport.height)
            }
            .photoMarqueeSelection(fillHeight: viewport.height)
        }
        .scrollIndicators(.automatic)
        .coordinateSpace(name: GalleryScrollSpace.name)
        .defaultScrollAnchor(.bottom)
        .overlay(alignment: .top) {
            // 换页 / 接续加载期间给一个浮层提示，不参与内容高度，不会顶动网格。
            if store.isPagedWindowLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .lumaGlassCapsule(shadow: false)
                    .padding(.top, 10)
            }
        }
        .onChange(of: store.loadedWindowPhotos.count) { _, _ in
            // 窗口异步加载完成：从年 / 月总览回来时在这里补做一次视野恢复。
            restoreTimelinePosition(proxy)
            guard let anchor = olderLoadAnchor else { return }
            olderLoadAnchor = nil
            // 更早的一页追加后，占位会同步缩小但压缩比例不同：
            // 滚回原来最上面那张，视野里的照片保持不动。
            DispatchQueue.main.async {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
        .onChange(of: store.hasLoadedPagedWindow) { _, loaded in
            guard loaded else { return }
            restoreTimelinePosition(proxy)
        }
        .modifier(TimelineScrollObserver { value in
            lastScrollOffset = value.offset
            lastTimelineContentHeight = value.contentHeight
            lastTimelineViewport = value.viewport
            updateVisibleDateSpan(offset: value.offset, viewportHeight: value.viewport)
            // 打开页面时窗口宽度 / 侧边栏在动画，占位高度会跟着变，滚动位置也会连续跳。
            // 只有「已经贴住底部并稳定」才开始响应换页，避免把动画过程当成用户拖动；
            // 落位后不会再有几何回调，所以用延时任务复查最后记录的数值。
            if !timelineGridReady {
                guard value.contentHeight > value.viewport,
                      value.offset >= value.contentHeight - value.viewport - 2 else { return }
                timelineAnchorReadyTask?.cancel()
                timelineAnchorReadyTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    guard lastTimelineContentHeight > lastTimelineViewport,
                          lastScrollOffset >= lastTimelineContentHeight - lastTimelineViewport - 2 else { return }
                    timelineGridReady = true
                }
                return
            }
            handleTimelineScroll(offset: value.offset,
                                 viewport: CGSize(width: width, height: value.viewport),
                                 width: width,
                                 orientation: .newestAtBottom)
        })
        .onAppear {
            timelineGridReady = false
            lastTimelineJumpOffset = -1
            // 网格是新建的：遗留的定位请求（年 / 月总览点某天、选中项定位）在这里消费，
            // 否则它永远不会被 onChange 触发，视野会停在空白占位里。
            if let target = store.scrollTargetID,
               store.loadedWindowPhotos.contains(where: { $0.id == target }) {
                DispatchQueue.main.async {
                    scrollToRequestedTarget(proxy, animated: false)
                }
            } else {
                restoreTimelinePosition(proxy)
            }
        }
        .onChange(of: store.pagedKey) { _, _ in
            lastDateSpanOffset = .greatestFiniteMagnitude
            timelineGridReady = false
            lastTimelineJumpOffset = -1
        }
        .simultaneousGesture(pinchGesture)
        .onChange(of: store.timelineJumpLandingID) { _, target in
            guard let target else { return }
            // 换页后的第一次滚动由系统执行，期间不要把它当成用户拖动再次换页。
            suppressTimelineJumpsUntil = Date().timeIntervalSince1970 + 1.2
            timelineGridReady = true
            // 新一页的视图可能还没完成布局，稍后再滚一次确保真的落到这张照片上。
            DispatchQueue.main.async {
                proxy.scrollTo(target, anchor: .center)
                store.timelineJumpLandingID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .onChange(of: store.scrollTargetID) { _, target in
            guard target != nil else { return }
            scrollToRequestedTarget(proxy, animated: true)
        }
    }

    /// 虚拟占位可用的最大高度。macOS 上滚动内容高度一旦超出可渲染范围（实测约两千万点），
    /// SwiftUI 会直接不绘制内容、整屏空白；所以整库占位统一按比例压缩到安全高度以内，
    /// 排名换算用同一比例还原，滚动条依然覆盖整库而不是只有一页。
    private static let maxVirtualTimelineHeight: CGFloat = 1_500_000

    /// 虚拟占位 / 排名换算用的列数与行高（与网格同一套尺寸估算）。
    private struct TimelineGridMetrics {
        let columns: Int
        let rowHeight: CGFloat
        /// 整库占位相对真实网格高度的压缩比例（1 = 不压缩）。
        let placeholderScale: CGFloat

        func rows(for count: Int) -> Int {
            guard count > 0, columns > 0 else { return 0 }
            return (count + columns - 1) / columns
        }

        /// 已加载窗口的真实高度。
        func windowHeight(for count: Int) -> CGFloat {
            CGFloat(rows(for: count)) * rowHeight
        }

        /// 未加载照片的虚拟占位高度（按整库比例压缩）。
        func placeholderHeight(for count: Int) -> CGFloat {
            CGFloat(rows(for: count)) * rowHeight * placeholderScale
        }
    }

    /// 时间轴网格的排布方向：新照片在底部（反序）或最新在上（正序）。
    private enum TimelineOrientation {
        case newestAtBottom
        case newestAtTop
    }

    /// 时间轴网格的纵向分段：把「窗口前占位 → 已加载窗口 → 窗口后占位」拼成整库长度。
    /// 反序时窗口前是更早的照片、窗口后是更新的照片；正序则相反。
    private struct TimelineLayout {
        let metrics: TimelineGridMetrics
        let orientation: TimelineOrientation
        let olderCount: Int
        let loadedCount: Int
        let newerCount: Int
        let total: Int

        var olderHeight: CGFloat { metrics.placeholderHeight(for: olderCount) }
        var windowHeight: CGFloat { metrics.windowHeight(for: loadedCount) }
        var newerHeight: CGFloat { metrics.placeholderHeight(for: newerCount) }
        var contentHeight: CGFloat { olderHeight + windowHeight + newerHeight }

        /// 已加载窗口在内容坐标里的上沿 / 下沿。
        var windowTop: CGFloat { orientation == .newestAtBottom ? olderHeight : newerHeight }
        var windowBottom: CGFloat { windowTop + windowHeight }

        /// 已加载窗口里最新一张的整库排名（0 = 最新）。
        var startRank: Int {
            orientation == .newestAtBottom
                ? max(0, total - olderCount - loadedCount)
                : max(0, newerCount)
        }

        /// 视口中心落在整库里的第几张（0 = 最新）：占位按压缩比例换算回真实排名。
        func rank(atCenter center: CGFloat) -> Int {
            guard total > 0 else { return 0 }
            let y = min(max(0, center), max(0, contentHeight - 0.5))
            switch orientation {
            case .newestAtBottom:
                if olderCount > 0, olderHeight > 0, y < olderHeight {
                    let ratio = Double((olderHeight - y) / olderHeight)
                    return clampedRank(Double(startRank + loadedCount - 1) + ratio * Double(olderCount))
                }
                if y < olderHeight + windowHeight {
                    let row = Int((y - olderHeight) / max(metrics.rowHeight, 1))
                    return clampedRank(Double(startRank + loadedCount - 1 - row * metrics.columns))
                }
                guard newerCount > 0, newerHeight > 0 else { return clampedRank(Double(startRank)) }
                let ratio = Double((y - olderHeight - windowHeight) / newerHeight)
                return clampedRank(Double(startRank - 1) - ratio * Double(newerCount))
            case .newestAtTop:
                if newerCount > 0, newerHeight > 0, y < newerHeight {
                    let ratio = Double((newerHeight - y) / newerHeight)
                    return clampedRank(Double(startRank) - ratio * Double(newerCount))
                }
                if y < newerHeight + windowHeight {
                    let row = Int((y - newerHeight) / max(metrics.rowHeight, 1))
                    return clampedRank(Double(startRank + row * metrics.columns))
                }
                guard olderCount > 0, olderHeight > 0 else {
                    return clampedRank(Double(startRank + loadedCount - 1))
                }
                let ratio = Double((y - newerHeight - windowHeight) / olderHeight)
                return clampedRank(Double(startRank + loadedCount - 1) + ratio * Double(olderCount))
            }
        }

        private func clampedRank(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return min(max(0, Int(value.rounded())), max(0, total - 1))
        }
    }

    private func timelineMetrics(width: CGFloat, total: Int) -> TimelineGridMetrics {
        let contentWidth = max(120, width)
        let spacing: CGFloat = 2
        let columns: Int
        let rowHeight: CGFloat
        switch store.thumbnailAspect {
        case .square:
            let target = CGFloat(store.thumbSize)
            columns = GridLayout.columns(contentWidth: contentWidth,
                                         targetSize: target,
                                         spacing: spacing)
            let cell = GridLayout.squareCellWidth(contentWidth: contentWidth,
                                                  columns: columns,
                                                  spacing: spacing)
            rowHeight = cell + spacing
        case .actual:
            rowHeight = max(60, CGFloat(store.thumbSize) * 0.92) + spacing
            columns = max(1, Int(contentWidth / max((rowHeight - spacing) * 1.2, 1)))
        case .masonry:
            let target = max(90, CGFloat(store.thumbSize))
            columns = GridLayout.columns(contentWidth: contentWidth,
                                         targetSize: target,
                                         spacing: spacing)
            rowHeight = target * 1.25 + spacing
        case .list:
            columns = 1
            rowHeight = 34
        }
        let safeColumns = max(1, columns)
        let fullRows = (max(total, 0) + safeColumns - 1) / safeColumns
        let fullHeight = CGFloat(fullRows) * rowHeight
        let scale = fullHeight > Self.maxVirtualTimelineHeight
            ? Self.maxVirtualTimelineHeight / fullHeight
            : 1
        return TimelineGridMetrics(columns: safeColumns,
                                   rowHeight: rowHeight,
                                   placeholderScale: scale)
    }

    /// 时间轴网格的当前分段布局。换页 / 接续加载刚完成时视图里捕获的布局已经过期，
    /// 决策时必须以 Store 的实时状态重算，否则会按旧高度算出错误排名、来回跳。
    private func timelineLayout(width: CGFloat, orientation: TimelineOrientation) -> TimelineLayout {
        // 「相似照片」是固定集合的过滤视图，窗口总数不等于可见数量，不能按整库留占位。
        let jumpable = store.supportsTimelineJump && store.similarScope == nil
        return TimelineLayout(metrics: timelineMetrics(width: width, total: store.visibleCount),
                              orientation: orientation,
                              olderCount: jumpable ? store.timelineOlderUnloadedCount : 0,
                              loadedCount: store.loadedWindowPhotos.count,
                              newerCount: jumpable ? store.timelineNewerUnloadedCount : 0,
                              total: store.visibleCount)
    }

    /// 时间轴网格滚动：停下后再决策（滚动途中布局连续变化，按中途状态取页只会来回跳）。
    private func handleTimelineScroll(offset: CGFloat, viewport: CGSize, width: CGFloat,
                                      orientation: TimelineOrientation) {
        guard offset.isFinite, viewport.height > 1 else { return }
        guard Date().timeIntervalSince1970 > suppressTimelineJumpsUntil else { return }
        guard abs(offset - lastTimelineJumpOffset) > 8 else { return }
        lastTimelineJumpOffset = offset
        timelineJumpTask?.cancel()
        timelineJumpTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            decideTimelineWork(offset: offset, viewport: viewport.height, width: width,
                               orientation: orientation)
        }
    }

    private func decideTimelineWork(offset: CGFloat, viewport: CGFloat, width: CGFloat,
                                    orientation: TimelineOrientation) {
        guard store.supportsTimelineJump, !store.isPagedWindowLoading else { return }
        let layout = timelineLayout(width: width, orientation: orientation)
        guard layout.total > 0, layout.loadedCount > 0 else { return }
        let center = offset + viewport / 2
        let edge = layout.metrics.rowHeight * 2
        guard center >= layout.windowTop, center < layout.windowBottom else {
            // 视野落在虚拟占位里（拖动条被拖到远处 / 快速甩动）：按排名整体重定位窗口。
            jumpTimelineTo(centerRank: layout.rank(atCenter: center), layout: layout)
            return
        }
        switch orientation {
        case .newestAtBottom:
            if layout.olderCount > 0, center - layout.windowTop < edge {
                // 正常向上滚动到已加载窗口的顶部：接续取更早一页，高度差用锚点照片补偿。
                loadOlderTimelinePage(restoreAnchor: true)
            } else if layout.newerCount > 0, layout.windowBottom - center < edge {
                // 往下（更新）一侧没有追加接口：整体重定位到当前视野的中心。
                jumpTimelineTo(centerRank: layout.rank(atCenter: center), layout: layout)
            }
        case .newestAtTop:
            if layout.olderCount > 0, layout.windowBottom - center < edge {
                // 正序：更早的照片就在窗口下方，直接追加下一页，顶部锚定不需要补偿。
                loadOlderTimelinePage(restoreAnchor: false)
            } else if layout.newerCount > 0, center - layout.windowTop < edge {
                // 窗口上方还有更新的照片：整体重定位到当前视野的中心。
                jumpTimelineTo(centerRank: layout.rank(atCenter: center), layout: layout)
            }
        }
    }

    private func loadOlderTimelinePage(restoreAnchor: Bool) {
        guard store.canLoadMoreVisible, !store.isPagedWindowLoading else { return }
        olderLoadAnchor = restoreAnchor ? store.loadedWindowPhotos.last?.id : nil
        store.loadMoreVisibleWindow()
    }

    /// 正序网格的提前预取：视口下沿接近已加载窗口底部时先把下一页取回来，
    /// 等真正滚到占位边缘时数据已就绪，不会先看到一片空白再补内容。
    private func preloadForwardPageIfNeeded(offset: CGFloat, viewport: CGFloat, width: CGFloat) {
        guard store.supportsTimelineJump, store.similarScope == nil,
              store.canLoadMoreVisible, !store.isPagedWindowLoading else { return }
        guard abs(offset - lastForwardPreloadOffset) >= 24 else { return }
        lastForwardPreloadOffset = offset
        let layout = timelineLayout(width: width, orientation: .newestAtTop)
        guard layout.olderCount > 0, layout.loadedCount > 0 else { return }
        // 只在窗口内容还占着屏幕时预取；拖进占位区交给滚动停稳后的重定位逻辑。
        guard offset < layout.windowBottom,
              offset + viewport >= layout.windowBottom - layout.metrics.rowHeight * 3 else { return }
        store.loadMoreVisibleWindow()
    }

    /// 把分页窗口整体重定位到「视野中心那张」附近。
    private func jumpTimelineTo(centerRank rank: Int, layout: TimelineLayout) {
        let pageSize = layout.loadedCount
        guard pageSize > 0, layout.total > pageSize else { return }
        let start = layout.startRank
        // 目标本来就在当前窗口里：不需要重定位。
        guard rank < start || rank >= start + pageSize else { return }
        let target = min(max(0, rank - pageSize / 2), max(0, layout.total - pageSize))
        // 换页后内容高度会整体重排并连续回调几何值，静默一小段时间避免被当成新的拖动。
        suppressTimelineJumpsUntil = Date().timeIntervalSince1970 + 1.0
        store.jumpTimelineWindow(toRank: target)
    }

    /// 按当前滚动位置算出顶栏副标题的日期范围（与系统「照片」一致，随滚动动态变化）。
    /// 只统计与视口相交的单元格；快速滚动时若暂时没有命中，用离视口最近的一张兜底，
    /// 避免顶栏日期停在上一屏、和画面里的照片对不上。
    private func updateVisibleDateSpan(offset: CGFloat, viewportHeight: CGFloat) {
        guard store.isTimelineScope, store.grouping == .all else {
            if !store.visibleDateSpanText.isEmpty { store.visibleDateSpanText = "" }
            return
        }
        guard viewportHeight > 0,
              abs(offset - lastDateSpanOffset) >= 8 else { return }
        lastDateSpanOffset = offset

        let frames = frameCache.frames
        guard !frames.isEmpty else { return }
        let lookup = store.photoDateLookup
        let top = offset
        let bottom = offset + viewportHeight
        var start: Date?
        var end: Date?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        var nearestDate: Date?
        for (id, frame) in frames {
            guard let captured = lookup[id] else { continue }
            if frame.maxY >= top, frame.minY <= bottom {
                if start == nil || captured < start! { start = captured }
                if end == nil || captured > end! { end = captured }
            } else {
                let distance = frame.minY > bottom ? frame.minY - bottom : top - frame.maxY
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestDate = captured
                }
            }
        }
        if start == nil, let nearestDate {
            start = nearestDate
            end = nearestDate
        }
        guard let start, let end else { return }
        let text = DateText.span(from: start, to: end)
        if store.visibleDateSpanText != text { store.visibleDateSpanText = text }
    }

    /// 按用户选择的显示形式渲染一段照片：正方形 / 完整宽高比 / 瀑布流 / 列表。
    /// 统一留出顶部间距：无分段标题时（「所有照片」）首排照片不会贴着工具栏。
    @ViewBuilder
    private func sectionGrid(photos: [PhotoItem], width: CGFloat) -> some View {
        Group {
            switch store.thumbnailAspect {
            case .square:
                SquarePhotoGrid(photos: photos, availableWidth: width)
                    .padding(.bottom, 26)
            case .actual:
                JustifiedPhotoGrid(photos: photos,
                                   availableWidth: width,
                                   targetHeight: CGFloat(store.thumbSize) * 0.92)
                    .padding(.bottom, 26)
            case .masonry:
                MasonryPhotoGrid(photos: photos,
                                 availableWidth: width,
                                 targetWidth: CGFloat(store.thumbSize))
                    .padding(.bottom, 26)
            case .list:
                PhotoListView(photos: photos, availableWidth: width)
                    .padding(.bottom, 20)
            }
        }
        .padding(.top, 10)
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: - 键盘上下移动

    /// 上下方向键按单元格的真实位置找「下一排」，落在正下方。
    /// 正方形与瀑布流、跨分段边界都适用；找不到可用行时退回按列数步进。
    private func moveSelectionVertically(_ direction: Int) {
        let frames = frameCache.frames
        guard let currentID = navigationAnchorID(), let current = frames[currentID] else {
            store.moveSelection(by: direction)
            return
        }

        let epsilon: CGFloat = 1
        let candidates = frames.filter { id, frame in
            guard id != currentID else { return false }
            return direction > 0
                ? frame.minY > current.minY + epsilon
                : frame.minY < current.minY - epsilon
        }
        guard !candidates.isEmpty else {
            // 下一排还没被 LazyVGrid 创建：按列数步进，触发滚动后再继续沿真实位置移动。
            // 「图库」页新照片在底部时，数据顺序与视觉顺序相反，步进方向也要跟着翻转。
            let step = store.timelineShowsNewestAtBottom ? -direction : direction
            store.moveSelection(by: step * gridColumnCount)
            return
        }

        // 先锁定最近的一排（上方取最大 minY，下方取最小 minY），再选水平中心最近的一格。
        let targetY = direction > 0
            ? candidates.values.map(\.minY).min() ?? current.minY
            : candidates.values.map(\.minY).max() ?? current.minY
        let row = candidates.filter { abs($0.value.minY - targetY) <= 1.5 }
        guard let best = row.min(by: {
            abs($0.value.midX - current.midX) < abs($1.value.midX - current.midX)
        }) else { return }

        selectionModel.ids = [best.key]
        store.selectionAnchorID = best.key
        store.scrollTargetID = best.key
    }

    private func navigationAnchorID() -> UUID? {
        if let anchor = store.selectionAnchorID, selectionModel.ids.contains(anchor) {
            return anchor
        }
        return selectionModel.ids.first
    }

    // MARK: - Toolbar items

    /// 缩放控件：滑杆拖拽实时跟手（不加动画），按钮/快捷键才用短动画补间。
    /// 卡片墙调每行张数，照片网格调缩略图尺寸。
    private var zoomControl: some View {
        GalleryToolbarPill {
            Button {
                withAnimation(settings.motion.layout) {
                    store.zoomStep(-1)
                }
            } label: {
                GalleryToolbarIconLabel(systemName: "minus")
            }
            .buttonStyle(.plain)
            .disabled(store.isCardWallScope
                      ? store.cardColumns <= LibraryStore.cardColumnsRange.lowerBound
                      : store.thumbSize <= LibraryStore.thumbSizeRange.lowerBound)
            .help("缩小\(zoomControlTitle)（⌘-）")
            .accessibilityLabel("缩小")

            zoomSlider
                .frame(width: 74)
                .controlSize(.mini)
                .accessibilityLabel(zoomControlTitle)

            Button {
                withAnimation(settings.motion.layout) {
                    store.zoomStep(1)
                }
            } label: {
                GalleryToolbarIconLabel(systemName: "plus")
            }
            .buttonStyle(.plain)
            .disabled(store.isCardWallScope
                      ? store.cardColumns >= LibraryStore.cardColumnsRange.upperBound
                      : store.thumbSize >= LibraryStore.thumbSizeRange.upperBound)
            .help("放大\(zoomControlTitle)（⌘+）")
            .accessibilityLabel("放大")
        }
        .help("\(zoomControlTitle)：\(zoomDensityText)（⌘+ / ⌘- / ⌘0，或双指捏合；每个侧边栏页面分别记忆）")
    }

    @ViewBuilder
    private var zoomSlider: some View {
        if store.isCardWallScope {
            Slider(value: Binding(get: { Double(store.cardColumns) },
                                  set: { store.cardColumns = Int($0.rounded()) }),
                   in: Double(LibraryStore.cardColumnsRange.lowerBound)...Double(LibraryStore.cardColumnsRange.upperBound),
                   step: 1)
                .help("\(zoomControlTitle)：\(zoomDensityText)（拖动调节，⌘0 复位）")
        } else {
            Slider(value: $store.thumbSize, in: LibraryStore.thumbSizeRange)
                .help("\(zoomControlTitle)：\(zoomDensityText)（拖动调节，⌘0 复位）")
        }
    }

    /// 缩放控件提示里用张数说明，避免出现看不懂的 pt 值。
    private var zoomDensityText: String {
        if isVideoHubScope || isCatalogScope {
            return "卡片 \(Int(store.thumbSize)) pt"
        }
        return store.isCardWallScope ? "每行 \(store.cardColumns) 张" : "每行 \(store.gridColumnCount) 张"
    }

    private var zoomControlTitle: String {
        switch store.sidebarItem {
        case .videos, .systemVideos: return "视频卡片大小"
        case .catalogSource: return "海报大小"
        case .allAlbums, .folder, .systemFolder: return "相簿卡片大小"
        case .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes,
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages, .systemImports:
            return "卡片大小"
        case .people, .systemPeople: return "人物卡片大小"
        case .places, .systemPlaces: return "地点卡片大小"
        case .keywords, .systemKeywords: return "关键词卡片大小"
        default: return "缩略图大小"
        }
    }

    private var layoutMenu: some View {
        Menu {
            ForEach(ThumbnailAspect.allCases) { aspect in
                Button {
                    guard aspect != store.thumbnailAspect else { return }
                    withAnimation(settings.motion.layout) {
                        store.thumbnailAspect = aspect
                    }
                } label: {
                    if store.thumbnailAspect == aspect {
                        Label(aspect.title, systemImage: "checkmark")
                    } else {
                        Label(aspect.title, systemImage: aspect.icon)
                    }
                }
            }
        } label: {
            GalleryToolbarIconLabel(systemName: store.thumbnailAspect.icon,
                                    active: store.thumbnailAspect != .square)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("显示形式：\(store.thumbnailAspect.title)。可选正方形、完整宽高比、瀑布流、列表")
        .accessibilityLabel("显示形式")
        .accessibilityValue(store.thumbnailAspect.title)
    }

    /// 视图控制（显示形式 / 排序 / 筛选）收进同一个胶囊，避免系统逐个包裹造成大小与间距不一致。
    private var galleryLayoutPill: some View {
        GalleryToolbarPill {
            layoutMenu
            sortMenu
            filterMenu
        }
    }

    /// 常用动作（助手 / 更多 / 信息 / 共享 / 收藏）收进第二个胶囊，与视图控制左右对称。
    private var galleryActionPill: some View {
        GalleryToolbarPill {
            assistantButton
            ellipsisMenu
            infoButton
            shareButton
            favoriteButton
        }
    }

    // MARK: - 视频页顶栏

    /// 与「位置」页一致的顶栏组合：统计胶囊 + 分段视图 + 筛选。
    private var videoHubPrincipalControls: some View {
        HStack(spacing: 8) {
            chipPill(icon: "video.fill", text: store.videoHubStatsText)
            videoLayoutSwitch
            GalleryToolbarPill {
                videoFilterMenu
            }
        }
    }

    private var videoLayoutSwitch: some View {
        VideoHubLayoutSwitch()
    }

    /// 年份与时长收进同一个菜单：工具栏宽度有限，拆成两个菜单会互相挤掉。
    private var videoFilterMenu: some View {
        Menu {
            Section("年份") {
                Button {
                    store.videoHubFilter.year = nil
                } label: {
                    if store.videoHubFilter.year == nil {
                        Label("全部年份", systemImage: "checkmark")
                    } else {
                        Text("全部年份")
                    }
                }
                ForEach(store.videoHubData.availableYears, id: \.self) { year in
                    Button {
                        store.videoHubFilter.year = year
                    } label: {
                        let title = String(year) + " 年"
                        if store.videoHubFilter.year == year {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }

            Section("时长") {
                Button {
                    store.videoHubFilter.duration = nil
                } label: {
                    if store.videoHubFilter.duration == nil {
                        Label("全部时长", systemImage: "checkmark")
                    } else {
                        Text("全部时长")
                    }
                }
                ForEach(VideoDurationBand.allCases) { band in
                    Button {
                        store.videoHubFilter.duration = band
                    } label: {
                        let title = "\(band.title) · \(band.detail)"
                        if store.videoHubFilter.duration == band {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }

            if store.videoHubFilter.isActive {
                Divider()
                Button("清除筛选") {
                    store.videoHubFilter = VideoHubFilter()
                }
            }
        } label: {
            videoFilterLabel(icon: store.videoHubFilter.isActive
                                 ? "line.3.horizontal.decrease.circle.fill"
                                 : "line.3.horizontal.decrease.circle",
                             text: videoFilterSummary ?? "筛选",
                             active: store.videoHubFilter.isActive)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按年份或时长筛选视频")
        .accessibilityLabel("筛选视频")
    }

    private var videoFilterSummary: String? {
        var parts: [String] = []
        if let year = store.videoHubFilter.year {
            parts.append(String(year) + " 年")
        }
        if let duration = store.videoHubFilter.duration {
            parts.append(duration.title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func videoFilterLabel(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .frame(height: 26)
        .padding(.horizontal, 7)
        .contentShape(Rectangle())
    }

    private var isFiltering: Bool {
        store.photoFilter != .all || store.keywordFilter != nil || store.hasMetadataFilters
    }

    /// 悬停即可读懂当前顺序，不必打开菜单。
    private var sortHelpText: String {
        "排序：\(store.sortKey.title) · \(store.sortAscending ? "升序" : "降序")。点击调整排序方式、方向与缩略图信息"
    }

    private var sortMenu: some View {
        Menu {
            Section("排序方式") {
                ForEach(SortKey.allCases) { key in
                    Button {
                        store.applySort(key)
                    } label: {
                        if store.sortKey == key {
                            Label("\(key.title)（\(store.sortAscending ? "升序 ↑" : "降序 ↓")）",
                                  systemImage: "checkmark")
                        } else {
                            Label(key.title, systemImage: key.icon)
                        }
                    }
                }
            }

            Section("排序方向") {
                Button {
                    store.sortAscending = true
                } label: {
                    if store.sortAscending {
                        Label("升序 ↑", systemImage: "checkmark")
                    } else {
                        Text("升序 ↑")
                    }
                }
                Button {
                    store.sortAscending = false
                } label: {
                    if store.sortAscending {
                        Text("降序 ↓")
                    } else {
                        Label("降序 ↓", systemImage: "checkmark")
                    }
                }
            }

            Section("缩略图上显示") {
                metadataOptions()
            }
        } label: {
            GalleryToolbarIconLabel(systemName: "arrow.up.arrow.down",
                                    active: store.sortKey != .capturedAt || store.sortAscending)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(sortHelpText)
        .accessibilityLabel("排序")
        .accessibilityValue("\(store.sortKey.title)，\(store.sortAscending ? "升序" : "降序")")
    }

    @ViewBuilder
    private func metadataOptions() -> some View {
        Toggle("标题", isOn: $settings.metadata.title)
        Toggle("拍摄日期", isOn: $settings.metadata.capturedDate)
        Toggle("关键词", isOn: $settings.metadata.keywords)
        Toggle("已编辑", isOn: $settings.metadata.edited)
        Toggle("文件类型", isOn: $settings.metadata.fileType)
        Toggle("个人收藏", isOn: $settings.metadata.favorite)
        Toggle("位置", isOn: $settings.metadata.location)
        Toggle("相机", isOn: $settings.metadata.camera)
        Toggle("分辨率", isOn: $settings.metadata.resolution)
        Toggle("文件大小", isOn: $settings.metadata.fileSize)
        Toggle("来源", isOn: $settings.metadata.source)
        Toggle("视频时长", isOn: $settings.metadata.duration)
    }

    /// 网络存储没有「已编辑」与「相簿」概念，隐藏这两个无效筛选项。
    private var availableFilters: [PhotoFilter] {
        guard store.isCloudScope else { return PhotoFilter.allCases }
        return PhotoFilter.allCases.filter { $0 != .edited && $0 != .notInAlbum }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(availableFilters) { filter in
                Button {
                    store.photoFilter = filter
                } label: {
                    if store.photoFilter == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Label(filter.title, systemImage: filter.icon)
                    }
                }
            }

            if !store.isSystemScope, !store.isCloudScope {
                Divider()

                Section("评分") {
                    Button {
                        store.ratingFilter = 0
                    } label: {
                        if store.ratingFilter == 0 {
                            Label("不限", systemImage: "checkmark")
                        } else {
                            Text("不限")
                        }
                    }
                    ForEach(1...5, id: \.self) { value in
                        Button {
                            store.ratingFilter = value
                        } label: {
                            if store.ratingFilter == value {
                                Label("\(value) 星及以上", systemImage: "checkmark")
                            } else {
                                Label("\(value) 星及以上", systemImage: "star.fill")
                            }
                        }
                    }
                }

                Section("旗标") {
                    Button {
                        store.flagFilter = nil
                    } label: {
                        if store.flagFilter == nil {
                            Label("不限", systemImage: "checkmark")
                        } else {
                            Text("不限")
                        }
                    }
                    ForEach([PhotoFlag.pick, .reject]) { flag in
                        Button {
                            store.flagFilter = flag
                        } label: {
                            if store.flagFilter == flag {
                                Label(flag.title, systemImage: "checkmark")
                            } else {
                                Label(flag.title, systemImage: flag.icon)
                            }
                        }
                    }
                }

                Section("色标") {
                    Button {
                        store.colorLabelFilter = nil
                    } label: {
                        if store.colorLabelFilter == nil {
                            Label("不限", systemImage: "checkmark")
                        } else {
                            Text("不限")
                        }
                    }
                    ForEach(PhotoColorLabel.allCases.filter { $0 != .none }) { label in
                        Button {
                            store.colorLabelFilter = label
                        } label: {
                            if store.colorLabelFilter == label {
                                Label(label.title, systemImage: "checkmark")
                            } else {
                                Label(label.title, systemImage: "circle.fill")
                            }
                        }
                    }
                }

                if store.hasMetadataFilters {
                    Button("清除评分 / 旗标 / 色标筛选") {
                        store.clearMetadataFilters()
                    }
                }
            }

            Divider()

            if !store.isSystemScope, !store.isCloudScope, !store.keywordOptions.isEmpty {
                Section("关键词") {
                    ForEach(store.keywordOptions.prefix(10)) { option in
                        Button {
                            store.keywordFilter = option.name
                        } label: {
                            if store.keywordFilter == option.name {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Label(option.name, systemImage: "tag")
                            }
                        }
                    }
                    if store.keywordFilter != nil {
                        Button("清除关键词筛选") {
                            store.keywordFilter = nil
                        }
                    }
                }
            }

            if !store.isSystemScope, !store.isCloudScope {
                Button("管理关键词…") {
                    store.showKeywordManager = true
                }
            }
        } label: {
            GalleryToolbarIconLabel(
                systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                active: isFiltering
            )
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(isFiltering ? "筛选：\(filterSummary)" : "筛选：当前显示全部照片（可按收藏、已编辑、关键词等过滤）")
        .accessibilityLabel("筛选")
        .accessibilityValue(isFiltering ? filterSummary : "全部照片")
    }

    /// 菜单未打开时也能从悬停提示看到筛选条件。
    private var filterSummary: String {
        var parts: [String] = []
        if store.photoFilter != .all { parts.append(store.photoFilter.title) }
        if store.ratingFilter > 0 { parts.append("评分 ≥ \(store.ratingFilter)") }
        if let flag = store.flagFilter { parts.append(flag.title) }
        if let label = store.colorLabelFilter { parts.append("色标：\(label.title)") }
        if let keyword = store.keywordFilter { parts.append("关键词：\(keyword)") }
        return parts.isEmpty ? "全部照片" : parts.joined(separator: " · ")
    }

    /// 「更多」只放图库里没有独立入口的动作；排序、元数据、缩略图比例已在工具栏按钮与菜单栏中提供。
    private var ellipsisMenu: some View {
        Menu {
            if store.canImportCurrentSystemScope {
                Button(store.currentSystemScopeImportTitle) {
                    store.importCurrentSystemScopeToLibrary()
                }
                Divider()
            }

            if !selectionModel.ids.isEmpty, !store.isReadOnlyScope {
                Section("所选 \(selectionModel.ids.count) 项") {
                    Button("压缩所选…") {
                        store.presentCompression(for: selectionModel.ids)
                    }
                    Button("导出所选到文件夹…") {
                        store.presentBatchExport()
                    }
                }
                Divider()
            }

            Button(store.isImporting ? "查看导入…" : "导入照片…") {
                store.presentImportPanel()
            }
            if !store.isCloudScope {
                Button("在访达中显示图库") {
                    if store.isSystemScope {
                        store.revealSystemLibraryInFinder()
                    } else {
                        store.revealLibraryInFinder()
                    }
                }
            }
            if store.trashCount > 0 {
                Divider()
                Button("清空最近删除", role: .destructive) {
                    store.confirmEmptyTrash()
                }
            }
        } label: {
            GalleryToolbarIconLabel(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("更多操作：导入照片、压缩 / 导出所选、在访达中显示、清空最近删除")
        .accessibilityLabel("更多操作")
    }

    private var assistantButton: some View {
        Button {
            store.showAIAssistant = true
        } label: {
            GalleryToolbarIconLabel(systemName: "sparkles", active: true)
        }
        .buttonStyle(.plain)
        .help("智能助手：用自然语言查找、整理图库（写操作会先确认）")
        .accessibilityLabel("智能助手")
    }

    private var infoButton: some View {
        Button {
            store.showLibraryInfo.toggle()
        } label: {
            GalleryToolbarIconLabel(systemName: store.showLibraryInfo ? "info.circle.fill" : "info.circle",
                                    active: store.showLibraryInfo)
        }
        .buttonStyle(.plain)
        .help("信息面板：查看图库统计、当前照片详情与存储情况")
        .accessibilityLabel("信息面板")
    }

    /// 浮动信息卡：不随选择变化关闭，方向键切换照片时内容就地更新；
    /// 标题区域可拖动移动，右下角可拖动调整大小，双击标题复位。
    private func libraryInfoPanel(container: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("信息")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .gesture(infoPanelDragGesture(container: container))
                .onTapGesture(count: 2) { resetInfoPanel(container: container) }
                .help("拖动移动；双击复位")

                Button {
                    store.showLibraryInfo = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭信息")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Group {
                    if selectionModel.ids.count == 1,
                       let id = selectionModel.ids.first,
                       let photo = store.anyPhoto(id: id) {
                        PhotoQuickInfoView(photo: photo)
                    } else if store.isCloudScope {
                        CloudMountInfoView()
                    } else if store.isSystemScope {
                        SystemLibraryInfoView()
                    } else {
                        LibraryInfoView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: infoPanelSize.width, height: infoPanelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .gesture(infoPanelResizeGesture(container: container))
                .help("拖动调整大小")
                .padding(4)
        }
        .shadow(color: .black.opacity(0.20), radius: 22, y: 10)
    }

    private func infoPanelDragGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if infoDragOrigin == nil { infoDragOrigin = infoPanelOffset }
                guard let origin = infoDragOrigin else { return }
                infoPanelOffset = clampedInfoOffset(
                    CGSize(width: origin.width + value.translation.width,
                           height: origin.height + value.translation.height),
                    container: container)
            }
            .onEnded { _ in infoDragOrigin = nil }
    }

    private func infoPanelResizeGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if infoResizeOrigin == nil { infoResizeOrigin = infoPanelSize }
                guard let origin = infoResizeOrigin else { return }
                infoPanelSize = clampedInfoSize(
                    CGSize(width: origin.width + value.translation.width,
                           height: origin.height + value.translation.height),
                    container: container)
                infoPanelOffset = clampedInfoOffset(infoPanelOffset, container: container)
            }
            .onEnded { _ in infoResizeOrigin = nil }
    }

    private func resetInfoPanel(container: CGSize) {
        infoPanelSize = clampedInfoSize(CGSize(width: 400, height: 560), container: container)
        infoPanelOffset = .zero
    }

    private func clampedInfoSize(_ size: CGSize, container: CGSize) -> CGSize {
        let maxWidth = max(380, min(760, container.width - 60))
        let maxHeight = max(240, min(900, container.height - 90))
        return CGSize(width: min(max(380, size.width), maxWidth),
                      height: min(max(240, size.height), maxHeight))
    }

    private func clampedInfoOffset(_ offset: CGSize, container: CGSize) -> CGSize {
        let maxLeft = -(container.width - infoPanelSize.width - 28)
        let maxDown = container.height - infoPanelSize.height - 24
        return CGSize(width: min(0, max(maxLeft, offset.width)),
                      height: min(max(0, maxDown), max(0, offset.height)))
    }

    private var shareButton: some View {
        ShareLink(items: store.shareURLs) {
            GalleryToolbarIconLabel(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .disabled(store.shareURLs.isEmpty)
        .help("共享所选照片（未选择时共享当前照片）")
        .accessibilityLabel("共享")
    }

    private var favoriteButton: some View {
        Button {
            store.toggleFavoriteCurrent()
        } label: {
            GalleryToolbarIconLabel(systemName: store.currentIsFavorite ? "heart.fill" : "heart",
                                    active: store.currentIsFavorite,
                                    activeColor: .pink)
        }
        .buttonStyle(.plain)
        .disabled(!store.canToggleFavorite
                  || (selectionModel.ids.isEmpty && store.viewerID == nil))
        .help(store.currentIsFavorite ? "取消收藏当前选择" : "把当前选择加入个人收藏")
        .accessibilityLabel(store.currentIsFavorite ? "取消个人收藏" : "标记为个人收藏")
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.85),
                          style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            .background(Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 56, height: 56)
                        .background(.regularMaterial, in: Circle())
                    Text("松开以导入照片")
                        .font(.system(size: 14, weight: .semibold))
                    Text("支持照片、视频与文件夹")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            store.prepareImport(urls)
        }
        return true
    }
}

// MARK: - 顶部滚动日期

/// 「所有照片」网格的滚动坐标系：探针把内容偏移量换算成可见区域。
private enum GalleryScrollSpace {
    static let name = "galleryScroll"
}

private struct GalleryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 年 / 月 / 所有照片 的磨砂分段切换：悬停与选中都带柔和胶囊，贴合系统「照片」的顶栏。
struct TimelineGroupingSwitch: View {
    @Binding var selection: GridGrouping
    @EnvironmentObject private var settings: AppSettings
    @Namespace private var pill
    @State private var hoveredOption: GridGrouping?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GridGrouping.allCases) { option in
                let active = option == selection
                Button {
                    guard !active else { return }
                    withAnimation(settings.motion.layout) { selection = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .padding(.horizontal, 15)
                        .frame(height: 26)
                        .background {
                            if active {
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.13))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                    }
                                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "groupingPill", in: pill)
                            } else if hoveredOption == option {
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredOption = hovering ? option : (hoveredOption == option ? nil : hoveredOption)
                }
                .help(hint(for: option))
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .help("按时间分组：年 / 月 / 所有照片")
    }

    private func hint(for option: GridGrouping) -> String {
        switch option {
        case .years: return "按年分组浏览照片"
        case .months: return "按月分组浏览照片"
        case .all: return "显示全部照片，顶栏日期随滚动位置实时联动"
        }
    }
}

/// 收藏浏览方式切换：与地图样式切换一致的 segmented 外观。
struct FavoritesViewModeSwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Picker("收藏浏览方式", selection: $store.favoritesViewMode) {
            ForEach(FavoritesViewMode.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(store.favoritesViewMode.hint)
    }
}

struct PlaceGranularitySwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Picker("地点聚合层级", selection: $store.placeGranularity) {
            ForEach(PlaceGranularity.allCases) { option in
                Text(option.shortTitle).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("按省份、城市、区县或街道聚合同一片区域的照片")
    }
}

struct MapStyleSwitch: View {
    @AppStorage("map.style") private var styleRaw = MapStyleMode.map.rawValue

    private var selection: Binding<MapStyleMode> {
        Binding(
            get: { MapStyleMode(rawValue: styleRaw) ?? .map },
            set: { styleRaw = $0.rawValue }
        )
    }

    var body: some View {
        Picker("地图显示方式", selection: selection) {
            ForEach(MapStyleMode.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("切换地图、卫星底图或当前视野的照片网格")
    }
}

/// 整理工作室的维度切换：评分 / 旗标 / 色标 / 关键词。
/// 选中态对齐人物页的系统分段控件：明确的灰色胶囊 + 深色半粗文字，不再靠材质差异提示。
struct OrganizeDimensionSwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OrganizeDimension.allCases) { item in
                let selected = store.organizeDimension == item
                Button {
                    // 只改维度，不在这里开动画：维度切换会换掉下方整块分布面板，
                    // 用 withAnimation 会把结果网格与滚动条一起带动，造成整页抖动。
                    store.organizeDimension = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.13))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                }
                                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.caption)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.15), value: store.organizeDimension)
        .fixedSize()
    }
}

/// 视频页的「海报墙 / 时间轴」切换：图标 + 文字的分段胶囊，
/// 选中项用强调色渐变托底，切换时滑片过渡，与顶栏其它圆角控件同一套材质与描边。
struct VideoHubLayoutSwitch: View {
    @EnvironmentObject private var store: LibraryStore
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VideoHubLayout.allCases) { layout in
                segment(layout)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .fixedSize()
    }

    private func segment(_ layout: VideoHubLayout) -> some View {
        let selected = store.videoHubLayout == layout
        return Button {
            guard !selected else { return }
            withAnimation(.snappy(duration: 0.22)) {
                store.videoHubLayout = layout
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: layout.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(layout.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.32),
                                                      Color.accentColor.opacity(0.13)],
                                             startPoint: .top,
                                             endPoint: .bottom))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 0.6)
                        }
                        .shadow(color: Color.accentColor.opacity(0.20), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "videoHubLayoutSelection", in: selection)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(layout.help)
        .accessibilityLabel(layout.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PeopleGroupFilterSwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Picker("人物筛选", selection: $store.peopleFilter) {
            ForEach(PeopleGroupFilter.allCases) { option in
                Text(option.shortTitle).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(store.peopleFilter.help)
    }
}

// MARK: - 工具栏通用外观

/// 顶栏图标的统一样式：固定点击区域、统一字号与视觉重量，悬停时给一层柔和圆角底。
/// 所有顶栏控件都走这个视图，避免个别图标自带底色/尺寸造成「有的大有的小」。
private struct GalleryToolbarIconLabel: View {
    let systemName: String
    var active: Bool = false
    var activeColor: Color = .accentColor
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? activeColor : Color.primary)
            .frame(width: 32, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 把若干顶栏控件收进同一个磨砂胶囊：间距、高度、描边完全一致，和年 / 月切换保持同一套语言。
private struct GalleryToolbarPill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 3) {
            content
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }
}

/// 相簿 / 文件夹的层级面包屑已抽成通用组件 `LumaBreadcrumbBar`（见 LumaDesign.swift），
/// 网盘目录复用同一套外观。

