import Observation
import Foundation
import LumaContentCore

/// 片单页里打开的详情（nil 表示停留在片单列表）。
enum CatalogPlaylistPage: Equatable {
    case manual(UUID)
    case smart(UUID)
}

/// 整本图集保存到本地图库的进度：卡片、详情页与看图模式共用同一份状态。
struct CatalogGallerySaveProgress: Equatable {
    var sourceID: UUID
    var itemID: String
    var title: String
    /// 已处理的张数（成功 + 失败）。
    var completed: Int = 0
    /// 图集总张数；详情刚解析完之前是 0。
    var total: Int = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

/// 网络资源的浏览状态：源列表、当前分类、分页、详情、续看与播放请求。
/// 资源属于「本机配置」而不是某个图库，因此用 UserDefaults 保存，切换图库不受影响。
@MainActor
@Observable
final class CatalogBrowserModel {
    private(set) var sources: [CatalogSource] = []
    var selectedSourceID: UUID?
    var section: CatalogSection = .home
    var categories: [CatalogCategory] = []
    /// 站点热门标签：跨分类的额外筛选入口。
    var tags: [CatalogCategory] = []
    /// 分组标签（分类 / 模特 / 发布商等）：频道页按组展示，点一项即按该标签筛选。
    var tagGroups: [CatalogTagGroup] = []
    /// 「全部分类」标签墙：站点标签上千个，这里一次取全量，界面端做搜索与客户端分页。
    private(set) var tagWallTags: [CatalogTag] = []
    private(set) var isTagWallLoading = false
    /// 当前 tagWallTags 属于哪个源：切源后重新加载，避免串源。
    @ObservationIgnored private var tagWallSourceID: UUID?
    /// 本次运行里已经向站点取过全量标签墙的源：缓存非空时只刷新一次，避免每次进页面重抓十几页。
    @ObservationIgnored private var tagWallLiveSourceIDs: Set<UUID> = []
    /// 博文归档：站点一次给全量（91图图的 archives.json），界面端做月份筛选与标题搜索。
    private(set) var archiveEntries: [CatalogArchiveEntry] = []
    private(set) var isArchiveLoading = false
    @ObservationIgnored private var archiveSourceID: UUID?
    @ObservationIgnored private var archiveLiveSourceIDs: Set<UUID> = []
    var sort: CatalogSort = .latest
    /// 站点不支持服务端排序时，对当前已加载列表做的本页排序。
    var localSort: CatalogLocalSort?

    var items: [CatalogItem] = []
    var isLoading = false
    var isLoadingMore = false
    var hasMore = false
    /// 已加载到第几页：底部翻页提示用。
    var loadedPage: Int { page }
    var error: String?
    /// 结构化错误：界面优先用它统一展示恢复动作。
    var sourceError: SourceError?
    /// 统一任务中心：健康检测、更新日历补录等跨源任务上报到这里。
    var jobCenter: SourceJobCenter?
    /// 任务进度变化回调；由 LibraryStore 接到 `sourceJobRevision`，触发界面刷新。
    var onJobChange: (() -> Void)?
    /// 任务结束后的归档回调：由 LibraryStore 接到 `archiveSourceJob`，写进任务记录。
    var onJobFinished: ((UUID) -> Void)?
    /// 列表当前展示的是缓存快照而不是最新请求结果时，记录快照时间（离线视图提示用）。
    var listSnapshotAt: Date?
    /// 本次刷新相对上次快照新出现的条目（key = "源 UUID|条目 id"）：
    /// 只在「以前缓存过这个列表」时计算，首次进入不会把整页都标成新上架。
    var freshItemKeys: Set<String> = []
    /// 一次性操作结果（例如保存到图库），几秒后自动消失。
    var notice: String?
    /// 正在下载到图库的条目 id：卡片据此显示转圈。
    var savingItemID: String?
    /// 正在把整本图集保存到图库时的进度（nil = 空闲）。
    var gallerySave: CatalogGallerySaveProgress?

    var detail: CatalogDetail?
    /// 关闭播放器后要在频道页里恢复的内联详情条目。
    var pendingInlineItem: CatalogItem?
    /// 当前在频道页里内联展示的详情条目（nil = 列表）。
    /// 提到模型里是为了让窗口工具栏也能读到：返回按钮与详情标题融进顶栏胶囊。
    /// 写入时顺手落盘：退出应用后再打开，仍停在原来那一页详情。
    var inlineDetailItem: CatalogItem? {
        didSet {
            guard oldValue?.id != inlineDetailItem?.id else { return }
            persistInlineDetail()
        }
    }
    /// 频道详情里叠开的人物 / 片商档案（nil = 停留在详情页）。
    /// 工具栏最左的返回按钮据此先退回详情，而不是直接跳出到频道列表。
    var detailPersonTarget: CatalogDetailPersonTarget?
    /// 关注页里打开的人物 / 片商档案（nil = 停留在关注列表）。
    var followedProfile: CatalogFollowedPerson?
    /// 片单页里打开的片单详情（nil = 停留在片单列表）。
    var openPlaylistPage: CatalogPlaylistPage?
    var isLoadingDetail = false
    var detailError: String?

    var searchText = ""
    /// 侧边栏点「搜索」时自增，频道页据此把焦点移入搜索框。
    var searchFocusToken = 0
    var progress: [String: CatalogProgress] = [:]
    var favorites: [String: CatalogFavorite] = [:]
    /// 手动标记已看的条目键（`sourceID|itemID`）：不写假的播放进度，足迹统计不受影响。
    var watchedKeys: Set<String> = []
    /// 当前展开的一级分类。同一个二级 id 可能挂在多个一级下（例如 XSZAV 的「無碼流出」），
    /// 必须记住用户实际点开的是哪个一级，不能按二级 id 反查（会命中第一个）。
    var activeTopCategoryID: String?
    /// 从合集卡片（专题 / 人物与作品实体）下钻前停留的界面：频道页据此显示「返回」。
    private(set) var collectionOrigin: CollectionOrigin?
    /// 当前所在合集的名称（返回按钮旁边显示「合集 · 名称」）。
    private(set) var collectionTitle: String?

    /// 进入合集详情前的上一层界面快照。
    struct CollectionOrigin {
        var section: CatalogSection
        var topCategoryID: String?
        var topTitle: String
        var sort: CatalogSort
        var localSort: CatalogLocalSort?
    }
    /// 侧边栏分类图标：每个分类拿该分类第一张卡片封面当缩略图。
    /// key = "源 UUID|分类 id"，值只在 URL 变化时写盘。
    private(set) var categoryThumbs: [String: String] = [:]
    var playback: CatalogPlaybackRequest?
    var showWizard = false
    /// 导入向导当前服务的域：从网络影院进入只接收影视源，从网络资源进入只接收资源站。
    var wizardDomain: CatalogDomain?

    // MARK: 登录态
    /// 当前打开「粘贴 Cookie」窗口的来源（RootView 的 sheet 绑定它）。
    var cookiePromptSource: CatalogSource?
    /// 本次运行中被登录墙拦下的来源：请求失败时写入，Cookie 更新后移除。
    private(set) var loginRequiredSourceIDs: Set<UUID> = []
    /// 正在静默续期（隐藏 WebView 刷新登录态）的来源：界面可显示「正在自动续期」。
    private(set) var cookieRefreshingSourceIDs: Set<UUID> = []
    private var cookieRefreshAttemptAt: [UUID: Date] = [:]

    // MARK: 网络资源 2.0：发现 / 关注 / 健康度
    /// 每个源最近一次连通性检测的结果。
    var health: [UUID: CatalogSourceHealth] = [:]
    /// 最近一次检测的耗时（毫秒）与时间。
    var healthLatency: [UUID: Int] = [:]
    var healthCheckedAt: [UUID: Date] = [:]
    /// 置顶的源：在总览卡片墙里排在最前。
    var pinnedSourceIDs: [UUID] = []
    /// 每个源置顶的常用分类（分类面板里排最前）。
    var pinnedCategoryIDs: [UUID: [String]] = [:]
    /// 关注的分类（片商 / 题材）：总览页直接跳转。
    var followedCategories: [CatalogFollowedCategory] = []
    /// 有新内容的源：总览卡片上显示红点，进入后清除。
    var newSourceIDs: Set<UUID> = []
    /// 跨源「今日总榜」：各源第一页混排。按域分别缓存，互不覆盖。
    var spotlightByDomain: [CatalogDomain: [CatalogSpotlightItem]] = [:]
    var isSpotlightLoading = false
    /// 总榜维度：最新 / 各源热榜 / 今天新增。
    var spotlightMode: CatalogSpotlightMode = .latest
    var spotlightHotByDomain: [CatalogDomain: [CatalogSpotlightItem]] = [:]
    var isSpotlightHotLoading = false
    /// 「今天新增」的榜单结果：从更新日历派生，改数据时重算一次，
    /// 不在工具栏角标 / 榜单渲染时反复过滤 2400 条日历。
    var todaySpotlight: [CatalogSpotlightItem] = []
    /// 今天新增的图集：同样从更新日历派生，图集分页与「今日精选」直接读这一份。
    var todayGallerySpotlight: [CatalogSpotlightItem] = []
    /// 图集分页的跨源内容：混排 feed + 每个图集站自己的轨道。
    var galleryFeed: [CatalogSpotlightItem] = []
    var galleryBySource: [UUID: [CatalogSpotlightItem]] = [:]
    var isGalleryFeedLoading = false
    var galleryFeedLoaded = false
    /// 继续往下翻：各站下一页页码、已经翻到底的站、整体是否没有更多。
    var galleryNextPage: [UUID: Int] = [:]
    var galleryExhaustedSources: Set<UUID> = []
    var galleryFeedExhausted = false
    var isGalleryFeedLoadingMore = false
    /// 图集悬停预览：条目 key → 前几张原图（解析过一次就复用）。
    var galleryPreviewCache: [String: [String]] = [:]
    /// 榜单 / 日历 / 足迹 / 片单共用的媒体类型筛选。
    var mediaFilter: CatalogMediaFilter = .all {
        didSet {
            guard oldValue != mediaFilter else { return }
            CatalogStore.string(forKey: Self.mediaFilterKey, value: mediaFilter.rawValue)
        }
    }
    /// 跨源聚合搜索。
    var globalQuery = ""
    var globalResults: [CatalogGlobalResult] = []
    /// 这批结果对应哪个查询词：输入新词时先不展示旧结果。
    var globalResultsKeyword = ""
    var isGlobalSearching = false
    /// 最近的跨源搜索词：搜索框聚焦且为空时展示。
    var recentSearches: [String] = []
    /// 自然语言搜索的解析结果（展示成条件胶囊）。
    var globalQueryPlan: CatalogQueryPlan?
    /// 更新日历：本机第一次看到某条内容的日期（从开始使用起累积）。
    var calendarItems: [CatalogCalendarItem] = []
    /// 最近一次补录新进来的条目（`sourceID|itemID`）：日历里高亮并排最前。
    var calendarNewIDs: [String] = []
    /// 正在扫描各源首页，把今天新出现的条目补进日历。
    var isCalendarRefreshing = false
    /// 日历上次选中的日期（跨启动还原）。
    var calendarSelectedDay: Date?
    /// 跨源自定义片单。
    var playlists: [CatalogPlaylist] = []
    /// 聚合片单：按关键字跨源动态聚合。
    var smartPlaylists: [CatalogSmartPlaylist] = []
    /// 每个聚合片单最近一次的结果。
    var smartResults: [UUID: [CatalogGlobalResult]] = [:]
    /// 每个聚合片单相对上一次结果新增的条目（`sourceID|itemID`）。
    var smartNewIDs: [UUID: [String]] = [:]
    var smartLoading: Set<UUID> = []
    /// 网络资源区当前分页：浏览 / 片单 / 更新日历。
    var hubTab: CatalogHubTab = .browse
    /// 关注的女优 / 片商。
    var followedPeople: [CatalogFollowedPerson] = []
    /// 关注页封面墙：每个人跨源聚合到的最新封面（最多 4 张），持久化避免每次重查。
    var followPosters: [String: [CatalogFollowPoster]] = [:]
    /// 关注人物的聚合快照：打开档案先铺历史，再在后台刷新并标出新条目。
    var followAggregates: [String: CatalogFollowAggregate] = [:]
    /// 正在查看的人物档案：按名字跨源聚合的结果。
    var personProfile: CatalogPersonProfile?
    var isPersonLoading = false

    // 以下为发现功能的内部缓存（供 +Discovery 扩展使用）。
    var lastSeenTop: [UUID: String] = [:]
    /// 已加载过榜单的域：两个域各自判断缓存是否新鲜。
    var spotlightLoadedDomains: Set<CatalogDomain> = []
    var spotlightHotLoadedDomains: Set<CatalogDomain> = []
    /// 当前正在补录哪个域的更新日历：两个域共用一套日历表，但扫描与节流各自独立。
    var calendarScanDomain: CatalogDomain?
    var previewCache: [String: CatalogPreviewTarget] = [:]
    var previewMissAt: [String: Date] = [:]
    /// 同时只解析一个悬停预览：鼠标扫过网格时不再给站点打一串请求。
    var previewInFlight = 0
    /// 正在请求的首屏 key：快速切换源时不重复发起同一个请求。
    var inFlightKey: String?
    static let discoveryPinsKey = "catalog.pins.v2"
    static let categoryPinsKey = "catalog.categoryPins.v2"
    static let followsKey = "catalog.follows.v2"
    static let lastSeenTopKey = "catalog.lastSeenTop.v2"
    static let newFlagsKey = "catalog.newFlags.v2"
    static let lastViewKey = "catalog.lastView.v2"
    /// 上次浏览的源：重启后直接回到它，而不是永远落到第一个启用的源。
    static let selectedSourceKey = "catalog.selectedSource.v1"
    /// 退出时停在的频道详情：重启后第一次进入对应源时铺开这一页。
    static let inlineDetailKey = "catalog.inlineDetail.v1"
    static let spotlightModeKey = "catalog.spotlightMode.v1"
    static let calendarSelectedDayKey = "catalog.calendar.selectedDay.v1"
    static let calendarScanAtKey = "catalog.calendar.scanAt.v1"
    /// 每个源补录到第几页：下次继续往下翻，慢慢把日历铺满。
    static let calendarCursorKey = "catalog.calendar.cursor.v1"
    /// 是否已用标题 / 备注里的日期回填过旧日历记录。
    static let calendarDateParseKey = "catalog.calendar.dateParse.v1"
    static let recentSearchesKey = "catalog.recentSearches.v1"
    static let playlistsKey = "catalog.playlists.v1"
    static let smartPlaylistsKey = "catalog.smartPlaylists.v1"
    static let smartResultsKey = "catalog.smartResults.v1"
    static let smartNewIDsKey = "catalog.smartPlaylistNew.v1"
    static let calendarNewIDsKey = "catalog.calendar.newIDs.v1"
    static let hubTabKey = "catalog.hubTab.v1"
    /// 榜单 / 日历 / 足迹 / 片单共用的媒体类型筛选。
    static let mediaFilterKey = "catalog.mediaFilter.v1"
    /// 图集分页的跨源 feed 与各源轨道：启动先铺上次的内容，再后台刷新。
    static let galleryFeedKey = "catalog.gallery.feed.v1"
    static let galleryRailsKey = "catalog.gallery.rails.v1"
    static let peopleKey = "catalog.people.v1"
    static let followPostersKey = "catalog.follow.posters.v1"
    static let followAggregatesKey = "catalog.follow.aggregates.v1"

    /// 播放交给宿主（图库查看器）处理；未绑定时退化到内置小窗口。
    var onPlayback: ((CatalogPlaybackRequest) -> Void)?
    /// 片单整单连播：把多个条目拼成同一个查看器会话。
    var onPlaylistPlayback: (([CatalogPlaylistPlaybackItem]) -> Void)?

    func emit(_ request: CatalogPlaybackRequest) {
        if let onPlayback {
            onPlayback(request)
        } else {
            playback = request
        }
    }

    private var page = 1
    /// 后台任务登记处：首屏加载、发现 / 搜索、日历补录、分类缩略图都走这里。
    let tasks = StoreTaskCenter()
    /// 每次重新加载自增：迟到的请求不能覆盖用户已经切走的页面。
    private var requestToken = 0
    /// 详情请求的代次：快速点不同条目时，旧详情不能覆盖新条目、也不能提前清掉转圈。
    private var detailToken = 0
    /// 更新日历在统一任务中心的登记 id。
    var calendarJobID: UUID?
    /// 操作提示的自增标记：旧的自动消失任务不能清掉新提示。
    private var noticeToken = 0
    /// 二级标签的请求标记：切换分类时迟到的结果不能覆盖新上下文。
    private var tagsToken = 0
    /// 最近浏览位置的内存副本：点击源时只改内存，落盘统一延迟合并，
    /// 避免同步 SQLite 写入把侧边栏点击卡慢。
    @ObservationIgnored var lastViewMemo: [String: [String: String]]?
    @ObservationIgnored var lastViewSaveTask: Task<Void, Never>?
    /// 当前源 ID 与「新内容」红点同样延后落盘，点击只改内存。
    @ObservationIgnored var selectedSourceSaveTask: Task<Void, Never>?
    @ObservationIgnored var newFlagsSaveTask: Task<Void, Never>?
    /// 首页 404 自动重试的节流记录（源 id → 上次重试时间）。
    @ObservationIgnored var home404RetryAt: [UUID: Date] = [:]
    /// 连续「翻页拉回来的全是已有条目」的次数：有些站点偶尔把上一页原样再给一遍，
    /// 一次重复不代表到底，连续两次才停，避免明明还有内容却提示已加载全部。
    @ObservationIgnored private var duplicatePageStreak = 0
    private var cachedPages: [String: CachedPage] = [:]
    /// 上次成功加载的首屏快照：先铺内容再请求最新，切换源时不会先闪一片骨架。
    var pageSnapshots: [String: CatalogPageSnapshot] = [:]
    var cachedDetails: [String: CatalogDetail] = [:]

    private static let sourcesKey = "catalog.sources.v1"
    private static let favoritesKey = "catalog.favorites.v1"
    private static let watchedKey = "catalog.watched.v1"
    private static let categoryThumbsKey = "catalog.categoryThumbs.v1"
    /// 本次启动已经为哪些源补过分类缩略图，避免反复请求站点。
    private var thumbAttemptedSources: Set<UUID> = []

    private struct CachedPage {
        var page: CatalogPage
        var fetchedAt: Date
    }

    init() {}

    // MARK: 退出时记住当前详情

    /// 退出应用时正打开着的频道详情：启动后第一次进入对应源时交给频道页铺开，
    /// 只还原一次，之后切换源或返回列表都不再出现。
    private var launchInlineDetail: (sourceID: UUID, item: CatalogItem)?
    /// 加载图库配置期间不要回写详情：清空旧状态会误删上次保存的那一页。
    private var isLoadingLibraryState = false

    private struct StoredInlineDetail: Codable {
        let sourceID: UUID
        let item: CatalogItem
    }

    /// 频道页进入某个源时调用：返回上次退出时停的详情（只给一次）。
    func consumeLaunchInlineDetail(for sourceID: UUID) -> CatalogItem? {
        defer { launchInlineDetail = nil }
        guard let saved = launchInlineDetail, saved.sourceID == sourceID else { return nil }
        return saved.item
    }

    private static func savedInlineDetail() -> (sourceID: UUID, item: CatalogItem)? {
        guard let data = CatalogStore.data(forKey: Self.inlineDetailKey),
              let saved = try? JSONDecoder().decode(StoredInlineDetail.self, from: data) else { return nil }
        return (saved.sourceID, saved.item)
    }

    private func persistInlineDetail() {
        guard !isLoadingLibraryState else { return }
        guard let item = inlineDetailItem, let sourceID = selectedSourceID,
              let data = try? JSONEncoder().encode(StoredInlineDetail(sourceID: sourceID, item: item)) else {
            CatalogStore.set(nil, forKey: Self.inlineDetailKey)
            return
        }
        CatalogStore.set(data, forKey: Self.inlineDetailKey)
    }

    /// 读取当前图库自己的网络资源配置。
    /// 图库切换后由宿主调用：先清空上一个图库的状态，再加载新图库的数据。
    func loadForCurrentLibrary() {
        let savedInline = Self.savedInlineDetail()
        isLoadingLibraryState = true
        defer { isLoadingLibraryState = false }
        tasks.cancel(.catalogPage)
        requestToken &+= 1
        sources = []
        selectedSourceID = nil
        section = .home
        categories = []
        tags = []
        tagGroups = []
        tagWallTags = []
        tagWallSourceID = nil
        tagWallLiveSourceIDs = []
        isTagWallLoading = false
        archiveEntries = []
        archiveSourceID = nil
        archiveLiveSourceIDs = []
        isArchiveLoading = false
        activeTopCategoryID = nil
        items = []
        detail = nil
        detailError = nil
        inlineDetailItem = nil
        detailPersonTarget = nil
        followedProfile = nil
        openPlaylistPage = nil
        pendingInlineItem = nil
        error = nil
        sourceError = nil
        isLoading = false
        listSnapshotAt = nil
        freshItemKeys = []
        progress = [:]
        favorites = [:]
        categoryThumbs = [:]
        cachedPages = [:]
        cachedDetails = [:]
        pageSnapshots = [:]
        previewCache = [:]
        previewMissAt = [:]
        pinnedSourceIDs = []
        pinnedCategoryIDs = [:]
        followedCategories = []
        followedPeople = []
        followPosters = [:]
        followAggregates = [:]
        newSourceIDs = []
        lastSeenTop = [:]
        calendarItems = []
        calendarNewIDs = []
        calendarSelectedDay = nil
        isCalendarRefreshing = false
        playlists = []
        smartPlaylists = []
        smartResults = [:]
        smartNewIDs = [:]
        smartLoading = []
        spotlightByDomain = [:]
        spotlightHotByDomain = [:]
        todaySpotlight = []
        todayGallerySpotlight = []
        galleryFeed = []
        galleryBySource = [:]
        galleryFeedLoaded = false
        galleryNextPage = [:]
        galleryExhaustedSources = []
        galleryFeedExhausted = false
        isGalleryFeedLoadingMore = false
        galleryPreviewCache = [:]
        spotlightLoadedDomains = []
        spotlightHotLoadedDomains = []
        health = [:]
        healthLatency = [:]
        healthCheckedAt = [:]
        localSort = nil
        sort = .latest
        hubTab = browseTabFromDisk()
        mediaFilter = CatalogMediaFilter(rawValue: CatalogStore.string(forKey: Self.mediaFilterKey) ?? "") ?? .all
        channelRequests = []
        thumbAttemptedSources = []

        load()
        pageSnapshots = CatalogSnapshotStore.load()
        pruneSnapshots()
        if let data = CatalogStore.data(forKey: Self.smartResultsKey),
           let cached = try? JSONDecoder().decode([UUID: [CatalogGlobalResult]].self, from: data) {
            smartResults = cached
        }
        if let data = CatalogStore.data(forKey: Self.smartNewIDsKey),
           let cached = try? JSONDecoder().decode([UUID: [String]].self, from: data) {
            smartNewIDs = cached
        }
        // 总榜按域分别铺上次的结果：网络资源与网络影院各自恢复，不互相覆盖。
        for domain in CatalogDomain.allCases {
            if let data = CatalogStore.data(forKey: Self.spotlightLatestKey(for: domain)),
               let cached = try? JSONDecoder().decode([CatalogSpotlightItem].self, from: data) {
                spotlightByDomain[domain] = cached
            }
            if let data = CatalogStore.data(forKey: Self.spotlightHotKey(for: domain)),
               let cached = try? JSONDecoder().decode([CatalogSpotlightItem].self, from: data) {
                spotlightHotByDomain[domain] = cached
            }
        }
        // 图集分页先铺上次的墙，等页面 task 再后台刷新一次。
        if let data = CatalogStore.data(forKey: Self.galleryFeedKey),
           let cached = try? JSONDecoder().decode([CatalogSpotlightItem].self, from: data) {
            galleryFeed = cached
        }
        if let data = CatalogStore.data(forKey: Self.galleryRailsKey),
           let cached = try? JSONDecoder().decode([UUID: [CatalogSpotlightItem]].self, from: data) {
            galleryBySource = cached
        }
        let storedID = CatalogStore.string(forKey: Self.selectedSourceKey)
            .flatMap(UUID.init(uuidString:))
        // 网络资源只认网页资源站：旧版本可能把影视源存成「当前资源」，这里直接忽略。
        if let storedID,
           let source = sources.first(where: { $0.id == storedID && $0.domain == .networkResource }) {
            selectedSourceID = source.id
            prepare(source: source)
        } else if let first = enabledResourceSources.first ?? resourceSources.first {
            selectedSourceID = first.id
            prepare(source: first)
        }
        CatalogStore.string(forKey: Self.selectedSourceKey, value: selectedSourceID?.uuidString)
        restoreLastView()
        // 上次退出时停在详情页：等频道页第一次进入这个源时再铺开。
        if let savedInline, savedInline.sourceID == selectedSourceID {
            launchInlineDetail = savedInline
        }

        // 后台预热更新日历：避开首屏请求，稍后且用户空闲时逐源补录历史日期。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            self?.refreshCalendarToday()
        }
    }

    private func browseTabFromDisk() -> CatalogHubTab {
        guard let raw = CatalogStore.string(forKey: Self.hubTabKey),
              let tab = CatalogHubTab(rawValue: raw) else { return .browse }
        return tab
    }

    /// 总榜缓存键：两个域各存一份，切模块不会互相覆盖。
    static func spotlightLatestKey(for domain: CatalogDomain) -> String {
        domain == .networkCinema ? "catalog.spotlight.latest.cinema.v1" : "catalog.spotlight.latest.v1"
    }

    static func spotlightHotKey(for domain: CatalogDomain) -> String {
        domain == .networkCinema ? "catalog.spotlight.hot.cinema.v1" : "catalog.spotlight.hot.v1"
    }

    // MARK: - 派生状态

    var selectedSource: CatalogSource? {
        sources.first(where: { $0.id == selectedSourceID })
    }

    /// 用户正在等一份内容：后台补录和悬停预览此时都让路。
    var isUserBusy: Bool {
        isLoading || isLoadingMore || isLoadingDetail || isGlobalSearching
    }

    /// 这次失败更像是站点要求人机验证 / 拦截，而不是单纯网络问题。
    var errorNeedsVerification: Bool {
        if errorNeedsLogin { return false }
        guard let error else { return false }
        if let id = selectedSourceID, health[id] == .limited { return true }
        let text = error.lowercased()
        let marks = ["403", "forbidden", "waf", "pow", "challenge",
                     "cloudflare", "captcha", "验证", "拦截"]
        return marks.contains { text.contains($0) }
    }

    /// 这次失败需要用户登录（Cookie 缺失 / 失效）：页面展示登录入口，而不是「在浏览器打开」。
    var errorNeedsLogin: Bool {
        guard let id = selectedSourceID, let source = selectedSource else { return false }
        guard source.kind.mayRequireLogin else { return false }
        return loginRequiredSourceIDs.contains(id)
    }

    /// 显示一条自动消失的操作提示（保存到图库等）。
    func showNotice(_ text: String) {
        notice = text
        noticeToken &+= 1
        let token = noticeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }

    /// 全部已启用的目录源。跨源聚合必须按域再筛一次，不能直接用这一份。
    var enabledSources: [CatalogSource] {
        sources.filter(\.isEnabled)
    }

    /// 指定域的源清单。
    func sources(in domain: CatalogDomain) -> [CatalogSource] {
        sources.filter { $0.domain == domain }
    }

    /// 指定域内已启用的源清单。
    func enabledSources(in domain: CatalogDomain) -> [CatalogSource] {
        sources.filter { $0.isEnabled && $0.domain == domain }
    }

    /// 网络资源（网页资源站）的源：影视源只在网络影院出现。
    var resourceSources: [CatalogSource] { sources(in: .networkResource) }
    var enabledResourceSources: [CatalogSource] { enabledSources(in: .networkResource) }
    /// 网络影院的影视源。
    var cinemaSources: [CatalogSource] { sources(in: .networkCinema) }
    var enabledCinemaSources: [CatalogSource] { enabledSources(in: .networkCinema) }

    var resourceSourceIDs: Set<UUID> { Set(resourceSources.map(\.id)) }
    var cinemaSourceIDs: Set<UUID> { Set(cinemaSources.map(\.id)) }

    func isSource(_ id: UUID, in domain: CatalogDomain) -> Bool {
        sources.first { $0.id == id }?.domain == domain
    }

    /// 网络资源自己的稍后看：只看网页资源站的条目。
    var resourceFavorites: [CatalogFavorite] {
        let ids = resourceSourceIDs
        return favorites.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// 网络影院自己的稍后看：只看影视源里的条目。
    var cinemaFavorites: [CatalogFavorite] {
        let ids = cinemaSourceIDs
        return favorites.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// 网络资源自己的观看足迹。
    var resourceContinueWatching: [CatalogProgress] {
        let ids = resourceSourceIDs
        return progress.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 网络影院自己的观看足迹。
    var cinemaContinueWatching: [CatalogProgress] {
        let ids = cinemaSourceIDs
        return progress.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var continueWatching: [CatalogProgress] {
        progress.values
            .filter { $0.sourceID == selectedSourceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var allContinueWatching: [CatalogProgress] {
        progress.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var currentFavorites: [CatalogFavorite] {
        favorites.values
            .filter { $0.sourceID == selectedSourceID }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func favoriteCount(for sourceID: UUID) -> Int {
        favorites.values.filter { $0.sourceID == sourceID }.count
    }

    func isFavorite(sourceID: UUID, itemID: String) -> Bool {
        favorites["\(sourceID.uuidString)|\(itemID)"] != nil
    }

    func toggleFavorite(source: CatalogSource, item: CatalogItem) {
        let key = "\(source.id.uuidString)|\(item.id)"
        if favorites[key] != nil {
            favorites[key] = nil
        } else {
            favorites[key] = CatalogFavorite(sourceID: source.id, itemID: item.id,
                                             title: item.title, coverURL: item.coverURL,
                                             remark: item.remark, addedAt: Date())
        }
        saveFavorites()
    }

    /// 批量加入 / 移出稍后看：只处理状态不同的条目，不会把已在稍后看里的又切回去。
    func setFavorite(_ favorite: Bool, source: CatalogSource, items: [CatalogItem]) {
        var changed = 0
        for item in items {
            let key = "\(source.id.uuidString)|\(item.id)"
            guard (favorites[key] != nil) != favorite else { continue }
            if favorite {
                favorites[key] = CatalogFavorite(sourceID: source.id, itemID: item.id,
                                                 title: item.title, coverURL: item.coverURL,
                                                 remark: item.remark, addedAt: Date())
            } else {
                favorites[key] = nil
            }
            changed += 1
        }
        guard changed > 0 else { return }
        saveFavorites()
        showNotice(favorite ? "已加入稍后看 \(changed) 条" : "已移出稍后看 \(changed) 条")
    }

    // MARK: - 手动标记已看

    func isMarkedWatched(sourceID: UUID, itemID: String) -> Bool {
        watchedKeys.contains("\(sourceID.uuidString)|\(itemID)")
    }

    /// 批量标记已看：只写标记，不伪造播放进度，足迹页的时长与统计保持干净。
    func markWatched(source: CatalogSource, items: [CatalogItem]) {
        let keys = items.map { "\(source.id.uuidString)|\($0.id)" }
        let added = keys.filter { !watchedKeys.contains($0) }
        guard !added.isEmpty else {
            showNotice("选中的条目都已标记为已看")
            return
        }
        watchedKeys.formUnion(added)
        saveWatched()
        showNotice("已标记 \(added.count) 条为已看")
    }

    var currentCategory: CatalogCategory? {
        guard case .category(let id) = section else { return nil }
        return categories.first(where: { $0.id == id })
    }

    /// 当前浏览范围所属的一级分类：二级 tab 与高亮都挂在它下面。
    /// 三级站点的二级分类 id 通常带一级前缀；分组节点（如「午夜影院」）自身没有页面，
    /// 需要再看它的 children 是否包含当前分类。
    var activeTopCategory: CatalogCategory? {
        if let id = activeTopCategoryID,
           let match = categories.first(where: { $0.id == id }) {
            return match
        }
        switch section {
        case .category(let id):
            return categories.first(where: { top in
                if top.id == id || id.hasPrefix(top.id + "/") { return true }
                return top.children?.contains(where: { $0.id == id }) == true
            })
        case .rank:
            return categories.first(where: { $0.isRank })
        default:
            return nil
        }
    }

    /// 当前一级分类的二级分类（站点频道页里的 tab）。
    var subCategories: [CatalogCategory] {
        activeTopCategory?.children ?? []
    }

    /// 侧边栏要显示的菜单项：当前源优先用站点实时分类，其余源仍用随源保存的骨架。
    /// 这样左侧菜单与内容区 chips 永远是同一份分类，不会一边「AI 短剧」一边「短剧」。
    func sidebarCategories(for source: CatalogSource) -> [CatalogCategory] {
        if selectedSourceID == source.id, !categories.isEmpty { return categories }
        return source.categories
    }

    /// 当前源里，某个一级分类是否正处于浏览范围（含它下面的二级分类）。
    func isBrowsing(_ category: CatalogCategory, sourceID: UUID) -> Bool {
        guard selectedSourceID == sourceID else { return false }
        return activeTopCategory?.id == category.id
    }

    // MARK: - 分类缩略图

    /// 侧边栏分类行显示用的缩略图：该分类第一张卡片的封面。
    func thumbURL(for category: CatalogCategory, sourceID: UUID) -> String? {
        categoryThumbs[Self.thumbKey(sourceID: sourceID, categoryID: category.id)]
    }

    private static func thumbKey(sourceID: UUID, categoryID: String) -> String {
        "\(sourceID.uuidString)|\(categoryID)"
    }

    private func storeThumb(_ url: String, categoryID: String, sourceID: UUID) {
        guard !url.isEmpty else { return }
        let key = Self.thumbKey(sourceID: sourceID, categoryID: categoryID)
        guard categoryThumbs[key] != url else { return }
        categoryThumbs[key] = url
        saveCategoryThumbs()
    }

    /// 给还没有缩略图的分类补一张首图：串行、少量，且每个源每次启动只补一次。
    /// 缩略图只是锦上添花，请求失败就跳过，不影响分类本身。
    func prefetchCategoryThumbs(for source: CatalogSource) {
        guard source.isEnabled,
              let provider = CatalogProviders.provider(for: source.kind),
              thumbAttemptedSources.insert(source.id).inserted else { return }

        // 侧边栏只显示一级分类：分组就用它的第一个子项取图，缩略图挂在分组 id 上。
        let pending: [(menu: CatalogCategory, target: CatalogCategory)] = sidebarCategories(for: source)
            .compactMap { menu in
                guard !menu.isRank, !menu.id.isEmpty else { return nil }
                let target = menu.isGroupCategory
                    ? menu.children?.first(where: { !$0.isRank && !$0.id.isEmpty })
                    : menu
                guard let target,
                      thumbURL(for: menu, sourceID: source.id) == nil else { return nil }
                return (menu, target)
            }
        guard !pending.isEmpty else { return }

        tasks.adopt(.catalogThumb, Task { [weak self] in
            for entry in pending {
                if Task.isCancelled { break }
                guard let self, self.selectedSourceID == source.id else { break }
                // 分类之间留间隔：一次二十来个分类也不能把源打到限流。
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let page = try? await provider.category(source: source,
                                                              category: entry.target,
                                                              sort: .latest,
                                                              page: 1),
                      let cover = page.items.first(where: { !$0.coverURL.isEmpty })?.coverURL
                else { continue }
                self.storeThumb(cover, categoryID: entry.menu.id, sourceID: source.id)
            }
        })
    }

    /// 新一页到达后预热封面：滚到这些卡片时直接命中缓存，翻页不会一格一格闪白。
    func prefetchCovers(for items: [CatalogItem], source: CatalogSource) {
        let targets = Array(items.filter { !$0.coverURL.isEmpty }.prefix(12))
        guard !targets.isEmpty else { return }
        Task {
            for item in targets {
                if Task.isCancelled { break }
                _ = await CatalogArtworkCache.shared.image(source: source,
                                                           urlString: item.coverURL,
                                                           quick: true)
            }
        }
    }

    /// 按 id 在任何层级里找分类：优先二级分类，保证标题显示的是具体频道。
    func category(withID id: String) -> CatalogCategory? {
        for top in categories {
            if let child = top.children?.first(where: { $0.id == id }) { return child }
        }
        for top in categories where top.id == id { return top }
        // 标签可能是分组结构（片商 / 衣着 / 身材 / 玩法），叶子项也要能找到。
        for group in tags {
            if let child = group.children?.first(where: { $0.id == id }) { return child }
            if group.id == id { return group }
        }
        return nil
    }

    var sectionTitle: String {
        switch section {
        case .home: return "首页"
        case .category(let id):
            if let category = category(withID: id) { return category.title }
            if let tag = tagGroups.flatMap(\.items).first(where: { $0.id == id }) {
                return tag.title
            }
            // 合集详情（专题 / 人物）不在分类树里：用进入时记下的名称。
            if id.hasPrefix("topic/") || id.hasPrefix("entity/"),
               let collectionTitle { return collectionTitle }
            return "分类"
        case .rank: return "排行榜"
        case .search(let keyword): return "搜索“\(keyword)”"
        case .continueWatching: return "继续观看"
        case .favorites: return "稍后看"
        }
    }

    // MARK: - 导航

    func selectSource(_ id: UUID?) {
        // 网络资源只接受网页资源站：影视源只在网络影院里浏览。
        guard let id,
              let source = sources.first(where: { $0.id == id && $0.domain == .networkResource })
        else {
            selectedSourceID = nil
            persistSelectedSource(nil)
            items = []
            return
        }
        selectedSourceID = source.id
        persistSelectedSource(source.id)
        markSourceViewed(source.id)
        prepare(source: source)
        openHome()
    }

    /// 只切换当前源，不重新加载：侧边栏点分类前先调用，随后由具体动作决定加载哪一页。
    func focus(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id && $0.domain == .networkResource }) else { return }
        markSourceViewed(source.id)
        if selectedSourceID != id {
            selectedSourceID = id
            persistSelectedSource(id)
            prepare(source: source)
        }
    }

    /// 选中的源延后 300ms 合并落盘：点击路径上不做同步 SQLite 写入。
    private func persistSelectedSource(_ id: UUID?) {
        selectedSourceSaveTask?.cancel()
        selectedSourceSaveTask = Task { [id] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            CatalogStore.string(forKey: Self.selectedSourceKey, value: id?.uuidString)
        }
    }

    func openHome() {
        section = .home
        activeTopCategoryID = nil
        collectionOrigin = nil
        collectionTitle = nil
        rememberView()
        if let source = selectedSource {
            refreshTags(source: source, category: nil)
        }
        reload()
    }

    func openCategory(_ category: CatalogCategory) {
        // 分组节点（如「午夜影院」）自己没有页面，等价于打开第一个子频道。
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { return }
        // 合集卡片（专题 / 人物与作品实体）下钻：记住上一层界面，频道页可一键返回；
        // 进入普通分类时清掉返回入口，避免停留在过期的上一层。
        if target.isCollectionPage {
            collectionOrigin = CollectionOrigin(section: section,
                                               topCategoryID: activeTopCategoryID,
                                               topTitle: activeTopCategory?.title ?? "上一页",
                                               sort: sort,
                                               localSort: localSort)
            collectionTitle = category.title
        } else {
            collectionOrigin = nil
            collectionTitle = nil
        }
        section = target.isRank ? .rank : .category(target.id)
        // 记住实际点开的一级：同一个二级 id 可能挂在多个一级下，不能按 id 反查。
        if target.isRank {
            activeTopCategoryID = categories.first(where: { $0.isRank })?.id
        } else if let top = topCategory(for: category) {
            activeTopCategoryID = top.id
        }
        // 标签是当前主分类下的二级筛选：点标签时保持上下文，不退回全局标签。
        if let source = selectedSource, !isKnownTag(target) {
            refreshTags(source: source, category: activeTopCategory)
        }
        // 站点把二级频道挂在分类页里（肉视频的片商）：点开一级时再取。
        if let source = selectedSource, let top = activeTopCategory,
           top.children?.isEmpty ?? true {
            loadChannels(source: source, category: top)
        }
        sort = .latest
        localSort = nil
        // 进入「全部分类」或从标签墙点某个标签时，确保标签墙数据可用。
        if let source = selectedSource,
           target.showsTagWall || (activeTopCategory?.showsTagWall ?? false) {
            loadTagWallIfNeeded(source: source)
        }
        // 进入「归档」时加载全量归档数据。
        if let source = selectedSource,
           target.showsArchive || (activeTopCategory?.showsArchive ?? false) {
            loadArchiveIfNeeded(source: source)
        }
        rememberView()
        reload()
    }

    /// 从合集内退回到上一层（专题 / 人物卡片墙）：原样恢复分类、高亮与排序。
    func closeCollectionDetail() {
        guard let origin = collectionOrigin else { return }
        collectionOrigin = nil
        collectionTitle = nil
        section = origin.section
        activeTopCategoryID = origin.topCategoryID
        sort = origin.sort
        localSort = origin.localSort
        rememberView()
        reload()
    }

    /// 返回按钮上显示的上一层名称（如「角色」「专题」）。
    var collectionReturnTitle: String? { collectionOrigin?.topTitle }

    // MARK: - 「全部分类」标签墙

    /// 标签墙按需加载：先用上次缓存铺满（上千个标签不可能每次重抓），再后台刷新一次全量。
    /// 站点 `/all-tags` 每页 120 个、约 13 页，适配器内部并发取回后这里整体缓存。
    func loadTagWallIfNeeded(source: CatalogSource, force: Bool = false) {
        if tagWallSourceID != source.id {
            tagWallSourceID = source.id
            tagWallTags = Self.loadTagWallCache(sourceID: source.id)
            isTagWallLoading = false
        }
        guard force || !tagWallLiveSourceIDs.contains(source.id) else { return }
        // 缓存一天内更新过：直接铺缓存，不再重抓十几页标签。
        if !force, !tagWallTags.isEmpty,
           Self.taxonomyFresh("tagWall", sourceID: source.id) { return }
        guard !isTagWallLoading,
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        tagWallLiveSourceIDs.insert(source.id)
        isTagWallLoading = true
        Task { [weak self] in
            let live = try? await provider.allTags(source: source)
            guard let self else { return }
            self.isTagWallLoading = false
            guard self.selectedSourceID == source.id, let live, !live.isEmpty else {
                // 这次没抓到（断网 / 站点限流）：下次进页面再试，不把失败记成「已加载」。
                self.tagWallLiveSourceIDs.remove(source.id)
                return
            }
            self.tagWallTags = live
            Self.saveTagWallCache(live, sourceID: source.id)
            Self.markTaxonomyFetched("tagWall", sourceID: source.id)
        }
    }

    private static func tagWallCacheKey(_ sourceID: UUID) -> String {
        "catalog.tagWall.v1.\(sourceID.uuidString)"
    }

    private static func loadTagWallCache(sourceID: UUID) -> [CatalogTag] {
        guard let data = CatalogStore.data(forKey: tagWallCacheKey(sourceID)),
              let tags = try? JSONDecoder().decode([CatalogTag].self, from: data) else { return [] }
        return tags
    }

    private static func saveTagWallCache(_ tags: [CatalogTag], sourceID: UUID) {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        CatalogStore.set(data, forKey: tagWallCacheKey(sourceID))
    }

    // MARK: - 博文归档

    /// 归档按需加载：先用本地缓存铺满，再后台拉一次全量（全部条目一次给回，无需逐页抓）。
    func loadArchiveIfNeeded(source: CatalogSource, force: Bool = false) {
        if archiveSourceID != source.id {
            archiveSourceID = source.id
            archiveEntries = Self.loadArchiveCache(sourceID: source.id)
            isArchiveLoading = false
        }
        guard force || !archiveLiveSourceIDs.contains(source.id) else { return }
        // 缓存一天内更新过：先铺缓存，不必每次进归档都重抓全量。
        if !force, !archiveEntries.isEmpty,
           Self.taxonomyFresh("archive", sourceID: source.id) { return }
        guard !isArchiveLoading,
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        archiveLiveSourceIDs.insert(source.id)
        isArchiveLoading = true
        Task { [weak self] in
            let live = try? await provider.archiveEntries(source: source)
            guard let self else { return }
            self.isArchiveLoading = false
            guard self.selectedSourceID == source.id, let live, !live.isEmpty else {
                self.archiveLiveSourceIDs.remove(source.id)
                return
            }
            self.archiveEntries = live
            Self.saveArchiveCache(live, sourceID: source.id)
            Self.markTaxonomyFetched("archive", sourceID: source.id)
        }
    }

    private static func archiveCacheKey(_ sourceID: UUID) -> String {
        "catalog.archive.v1.\(sourceID.uuidString)"
    }

    private static func loadArchiveCache(sourceID: UUID) -> [CatalogArchiveEntry] {
        guard let data = CatalogStore.data(forKey: archiveCacheKey(sourceID)),
              let entries = try? JSONDecoder().decode([CatalogArchiveEntry].self, from: data)
        else { return [] }
        return entries
    }

    private static func saveArchiveCache(_ entries: [CatalogArchiveEntry], sourceID: UUID) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        CatalogStore.set(data, forKey: archiveCacheKey(sourceID))
    }

    // MARK: - 分类 / 标签本地缓存
    //
    // 站点的导航与标签行几乎不变：本地存一份占位，切源 / 切分类先铺缓存，
    // 一天内不再重复抓首页与标签接口，过期后进页面时再后台刷新一次。

    /// 分类 / 标签的刷新周期：一天。
    private static let taxonomyTTL: TimeInterval = 24 * 3600

    private static func taxonomyStampKey(_ kind: String, sourceID: UUID,
                                         scope: String = "root") -> String {
        // 分类结构改版（麻豆导航、JavGG 五个一级、肉视频、JavCl 导航 / 名册去重名合集、
        // Avple 标签分组）需要立刻生效，而不是等 24 小时过期；
        // 标签墙 / 归档缓存不受影响，避免重新抓十几页。
        let version = kind == "categories" ? "v9" : "v3"
        return "catalog.taxonomy.\(kind).\(version).\(sourceID.uuidString)|\(scope)"
    }

    private static func taxonomyFresh(_ kind: String, sourceID: UUID,
                                      scope: String = "root") -> Bool {
        guard let raw = CatalogStore.string(forKey: taxonomyStampKey(kind, sourceID: sourceID,
                                                                     scope: scope)),
              let stamp = TimeInterval(raw) else { return false }
        return Date().timeIntervalSince1970 - stamp < taxonomyTTL
    }

    private static func markTaxonomyFetched(_ kind: String, sourceID: UUID,
                                            scope: String = "root") {
        CatalogStore.string(forKey: taxonomyStampKey(kind, sourceID: sourceID, scope: scope),
                            value: "\(Date().timeIntervalSince1970)")
    }

    /// 一组「当前一级分类下的标签」快照：标签行 + 分组标签一起存。
    private struct TagSnapshot: Codable {
        var tags: [CatalogCategory]
        var groups: [CatalogTagGroup]
    }

    private static func tagSnapshotKey(sourceID: UUID, scope: String) -> String {
        "catalog.taxonomy.tags.v1.\(sourceID.uuidString)|\(scope)"
    }

    private static func loadTagSnapshot(sourceID: UUID, scope: String) -> TagSnapshot? {
        guard let data = CatalogStore.data(forKey: tagSnapshotKey(sourceID: sourceID, scope: scope))
        else { return nil }
        return try? JSONDecoder().decode(TagSnapshot.self, from: data)
    }

    private static func saveTagSnapshot(_ snapshot: TagSnapshot, sourceID: UUID, scope: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        CatalogStore.set(data, forKey: tagSnapshotKey(sourceID: sourceID, scope: scope))
    }

    /// 源被编辑（地址 / Cookie / UA）后，分类与标签缓存立刻作废，下次进页面重新取。
    private static func invalidateTaxonomy(sourceID: UUID) {
        CatalogStore.set(nil, forKey: taxonomyStampKey("categories", sourceID: sourceID))
        CatalogStore.set(nil, forKey: taxonomyStampKey("tagWall", sourceID: sourceID))
        CatalogStore.set(nil, forKey: taxonomyStampKey("archive", sourceID: sourceID))
    }

    func openRank() {
        section = .rank
        activeTopCategoryID = categories.first(where: { $0.isRank })?.id
        collectionOrigin = nil
        collectionTitle = nil
        rememberView()
        if let source = selectedSource {
            refreshTags(source: source, category: nil)
        }
        reload()
    }

    /// 分类所属的一级分组。二级 id 重复挂在不同一级下时（XSZAV 的「無碼流出」
    /// 既在「日本AV」也在「無碼影片」里），优先沿用正在浏览的一级，再退回第一个匹配。
    private func topCategory(for category: CatalogCategory) -> CatalogCategory? {
        if let direct = categories.first(where: { $0.id == category.id }) { return direct }
        if let current = activeTopCategory,
           current.children?.contains(where: { $0.id == category.id }) == true {
            return current
        }
        return categories.first { top in
            top.children?.contains(where: { $0.id == category.id }) ?? false
        }
    }

    func openContinueWatching() {
        openLocalSection(.continueWatching)
    }

    func openFavorites() {
        openLocalSection(.favorites)
    }

    private func openLocalSection(_ target: CatalogSection) {
        tasks.cancel(.catalogPage)
        requestToken &+= 1
        section = target
        activeTopCategoryID = nil
        collectionOrigin = nil
        collectionTitle = nil
        items = []
        hasMore = false
        error = nil
        sourceError = nil
        isLoading = false
        isLoadingMore = false
    }

    func focusSearch() {
        searchFocusToken &+= 1
    }

    func setSort(_ value: CatalogSort) {
        guard sort != value || localSort != nil else { return }
        sort = value
        localSort = nil
        reload()
    }

    /// 站点支持的排序：界面只用这些选项，避免点了没反应。
    var supportedSorts: [CatalogSort] {
        guard let source = selectedSource,
              let provider = CatalogProviders.provider(for: source.kind) else { return [.latest] }
        return provider.supportedSorts
    }

    /// 本页排序：只重排当前已加载的条目，不重新请求站点。
    func setLocalSort(_ value: CatalogLocalSort) {
        localSort = localSort == value ? nil : value
        applyLocalSortIfNeeded()
    }

    func search(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchText = trimmed
        section = .search(trimmed)
        activeTopCategoryID = nil
        collectionOrigin = nil
        collectionTitle = nil
        reload()
    }

    // MARK: - 列表加载

    func refresh() {
        cachedPages.removeAll()
        reload()
    }

    func reload() {
        tasks.cancel(.catalogPage)
        requestToken &+= 1
        let token = requestToken
        isLoadingMore = false
        guard let source = selectedSource else {
            items = []
            hasMore = false
            isLoading = false
            inFlightKey = nil
            return
        }
        guard source.isEnabled else {
            items = []
            hasMore = false
            error = nil
            sourceError = nil
            isLoading = false
            inFlightKey = nil
            return
        }

        page = 1
        error = nil
        sourceError = nil
        freshItemKeys = []
        // Cookie 快过期时顺手在后台续一次；失败会走登录墙分支再提示。
        renewCookieIfNeeded(source)
        let key = cacheKey(source: source, page: 1)
        // 注意：这里不能「同 key 在途就直接 return」。
        // 上面已经取消旧任务并换了 token，旧任务回来时会被 token 校验丢掉；
        // 如果这里直接返回，isLoading 会永远停在 true，之后整个列表都加载不出来。
        inFlightKey = key
        if let cached = cachedPages[key], Date().timeIntervalSince(cached.fetchedAt) < 120 {
            items = cached.page.items
            hasMore = cached.page.hasMore
            listSnapshotAt = nil
            isLoading = false
            inFlightKey = nil
            applyLocalSortIfNeeded()
            return
        }

        isLoading = true
        // 先用上次的首屏快照铺满，再在后台请求最新；没有快照才显示骨架。
        if let snapshot = pageSnapshots[key] {
            items = snapshot.items
            hasMore = snapshot.hasMore
            listSnapshotAt = snapshot.savedAt
            applyLocalSortIfNeeded()
        } else {
            items = []
            listSnapshotAt = nil
        }
        tasks.adopt(.catalogPage, Task { [weak self] in
            await self?.load(page: 1, source: source, token: token)
        })
    }

    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore, let source = selectedSource else { return }
        isLoadingMore = true
        let next = page + 1
        let token = requestToken
        tasks.adopt(.catalogPage, Task { [weak self] in
            await self?.load(page: next, source: source, token: token)
        })
    }

    private func load(page: Int, source: CatalogSource, token: Int) async {
        // 只让「当前这一代」请求收尾：被取消 / 已被替换的请求不能动标志位，
        // 更不能把新请求的 isLoading 提前置 false。
        defer {
            if token == requestToken {
                isLoading = false
                isLoadingMore = false
                inFlightKey = nil
            }
        }
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            error = CatalogError.unsupportedProvider.localizedDescription
            sourceError = .unsupported(error ?? "当前来源不支持这个操作")
            return
        }
        do {
            let result: CatalogPage
            switch section {
            case .home:
                result = try await provider.home(source: source, page: page)
            case .category(let id):
                let category = category(withID: id)
                    ?? CatalogCategory(id: id, title: id)
                result = try await provider.category(source: source, category: category,
                                                     sort: sort, page: page)
            case .rank:
                let category = categories.first(where: { $0.isRank })
                    ?? CatalogCategory(id: "ranks/hot", title: "排行榜", isRank: true)
                result = try await provider.category(source: source, category: category,
                                                     sort: .latest, page: page)
            case .search(let keyword):
                result = try await provider.search(source: source, keyword: keyword, page: page)
            case .continueWatching, .favorites:
                return
            }

            guard !Task.isCancelled, token == requestToken else { return }
            // 浏览过的分类顺手记下首图，侧边栏下次直接用真实缩略图。
            if page == 1, case .category(let id) = section,
               let cover = result.items.first(where: { !$0.coverURL.isEmpty })?.coverURL {
                storeThumb(cover, categoryID: id, sourceID: source.id)
            }
            var nextHasMore = result.hasMore
            if page == 1 {
                duplicatePageStreak = 0
                // 与上次同一列表的快照比较：新出现的条目打「刚上架」。
                let listKey = cacheKey(source: source, page: 1)
                let previousIDs = Set((pageSnapshots[listKey]?.items ?? []).map(\.id))
                if previousIDs.isEmpty {
                    freshItemKeys = []
                } else {
                    freshItemKeys = Set(result.items
                        .filter { !previousIDs.contains($0.id) }
                        .map { "\(source.id.uuidString)|\($0.id)" })
                }
                items = result.items
                if case .home = section, let top = result.items.first {
                    recordTopItem(top.id, sourceID: source.id)
                }
                // 首页与分类页都算「今天看到过」：日历会随着浏览慢慢补齐。
                switch section {
                case .home, .category:
                    recordCalendar(items: Array(result.items.prefix(24)), sourceID: source.id)
                default:
                    break
                }
            } else {
                // 站点偶尔把上一页原样再给一遍：去重后一条没增加只记一次，
                // 连续两次才当作到底，免得明明还有内容却提前停住。
                var seen = Set(items.map(\.id))
                let fresh = result.items.filter { seen.insert($0.id).inserted }
                items.append(contentsOf: fresh)
                if fresh.isEmpty {
                    duplicatePageStreak += 1
                    if duplicatePageStreak >= 2 { nextHasMore = false }
                } else {
                    duplicatePageStreak = 0
                }
                Diagnostics.record("分页 \(source.name) 第 \(page) 页 · 返回 \(result.items.count)"
                                   + " · 新增 \(fresh.count) · 连续重复 \(duplicatePageStreak)"
                                   + " · hasMore \(nextHasMore)")
            }
            hasMore = nextHasMore
            self.page = page
            error = nil
            sourceError = nil
            if page == 1 { listSnapshotAt = nil }
            applyLocalSortIfNeeded()
            let key = cacheKey(source: source, page: page)
            cachedPages[key] = CachedPage(page: result, fetchedAt: Date())
            if page == 1 {
                storeSnapshot(result, for: key)
            }
        } catch {
            guard token == requestToken, !Task.isCancelled else { return }
            // 站点下线 / 改了分类路径：不要再把 404 摆在页面上。
            // 首页永远可用，直接退回首页；分页 404 视为已经到底。
            if isHTTP404(error) {
                switch section {
                case .home:
                    // 站点偶尔会在 Cloudflare / 缓存回源时抽风返回 404：自动重试一次。
                    if page == 1, shouldRetryHome404(source.id) {
                        Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            guard let self, self.requestToken == token,
                                  self.selectedSourceID == source.id,
                                  case .home = self.section else { return }
                            self.reload()
                        }
                        return
                    }
                case .category, .rank:
                    if page == 1 {
                        section = .home
                        activeTopCategoryID = nil
                        self.error = nil
                        self.sourceError = nil
                        rememberView()
                        reload()
                        return
                    }
                    hasMore = false
                    self.error = nil
                    self.sourceError = nil
                    return
                case .search:
                    if page > 1 {
                        hasMore = false
                        self.error = nil
                        self.sourceError = nil
                        return
                    }
                    self.error = "该站点没有可用的搜索入口（HTTP 404）。"
                    self.sourceError = .unavailable(self.error ?? "")
                    return
                default:
                    break
                }
            }
            // 登录态站点被登录墙 / 403 拦下：不要退化成「离线快照」，直接给登录入口。
            if source.kind.mayRequireLogin, Self.isLoginWall(error) {
                markLoginRequired(source.id)
                if page == 1, listSnapshotAt == nil { items = [] }
                self.error = "站点需要登录后才能浏览完整内容。"
                self.sourceError = .unauthorized("站点需要登录后才能浏览完整内容。")
                beginSilentCookieRefresh(source)
                return
            }
            // 有快照就继续显示快照（页面顶部会提示离线视图），没有才退回空态。
            if page == 1, listSnapshotAt == nil { items = [] }
            self.error = error.localizedDescription
            self.sourceError = SourceErrorMapper.map(error)
            Diagnostics.record("影视源加载失败 \(source.name) \(sectionTitle)：\(error.localizedDescription)")
        }
    }

    /// 站点明确回了 404：分类 / 条目已经不存在，和网络故障区分处理。
    private func isHTTP404(_ error: Error) -> Bool {
        guard case .http(let status)? = error as? CatalogError else { return false }
        return status == 404
    }

    /// 首页 404 的自动重试节流：同一源 20 秒内只重试一次，避免真下线时无限循环。
    private func shouldRetryHome404(_ sourceID: UUID) -> Bool {
        if let last = home404RetryAt[sourceID], Date().timeIntervalSince(last) < 20 {
            return false
        }
        home404RetryAt[sourceID] = Date()
        return true
    }

    // MARK: - 本页排序

    /// 首屏快照：每个列表最多 60 条；15 天未更新的按 LRU 淘汰，整体最多留 80 个。
    private func storeSnapshot(_ page: CatalogPage, for key: String) {
        guard !page.items.isEmpty else { return }
        let snapshot = CatalogPageSnapshot(items: Array(page.items.prefix(60)),
                                           page: page.page,
                                           hasMore: page.hasMore,
                                           savedAt: Date())
        pageSnapshots[key] = snapshot
        CatalogSnapshotStore.save(snapshot, forKey: key)
        pruneSnapshots()
    }

    /// 快照的 LRU 收敛：先丢 15 天没碰过的，再按最近更新时间保留 80 个（数据库里同样执行）。
    private func pruneSnapshots() {
        let cutoff = Date().addingTimeInterval(-15 * 24 * 60 * 60)
        pageSnapshots = pageSnapshots.filter { $0.value.savedAt >= cutoff }
        if pageSnapshots.count > 80 {
            let kept = pageSnapshots.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(80)
            pageSnapshots = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        CatalogSnapshotStore.prune(cutoff: cutoff, limit: 80)
    }

    /// 站点不支持排序时的兜底：只重排已经拿到的这一批条目。
    private func applyLocalSortIfNeeded() {
        guard let localSort else { return }
        items = Self.sorted(items, by: localSort, firstSeen: calendarFirstSeen)
    }

    private var calendarFirstSeen: [String: Date] {
        guard let sourceID = selectedSourceID else { return [:] }
        var map: [String: Date] = [:]
        for entry in calendarItems where entry.sourceID == sourceID {
            map[entry.itemID] = entry.firstSeen
        }
        return map
    }

    static func sorted(_ items: [CatalogItem], by sort: CatalogLocalSort,
                       firstSeen: [String: Date]) -> [CatalogItem] {
        switch sort {
        case .title:
            return items.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .year:
            return items.sorted {
                let left = CatalogQueryPlan.year(in: $0.title + " " + $0.remark) ?? 0
                let right = CatalogQueryPlan.year(in: $1.title + " " + $1.remark) ?? 0
                return left > right
            }
        case .duration:
            return items.sorted {
                durationSeconds($0.remark) > durationSeconds($1.remark)
            }
        case .firstSeen:
            return items.sorted {
                (firstSeen[$0.id] ?? .distantPast) > (firstSeen[$1.id] ?? .distantPast)
            }
        }
    }

    /// 从备注里读 `12:34` / `1:02:03` 这类时长。
    static func durationSeconds(_ text: String) -> Int {
        guard let range = text.range(of: #"\d{1,2}(:\d{2}){1,2}"#,
                                     options: .regularExpression) else { return 0 }
        let parts = text[range].split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    // MARK: - 详情

    /// 正在解析的详情：同一部作品重复进入时不重复请求，直接等它的结果。
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var detailTaskKey: String?
    /// 详情解析在任务中心的登记 id：取消 / 归档都靠它。
    @ObservationIgnored private var detailJobID: UUID?

    func loadDetail(item: CatalogItem, force: Bool = false) {
        guard let source = selectedSource else { return }
        let key = detailKey(source: source, itemID: item.id)
        if !force, let cached = cachedDetails[key] {
            detail = cached
            detailError = nil
            isLoadingDetail = false
            // 详情里的女优字段顺手补进识别词典：以后标题里也能认出她。
            learnNamesInBackground(from: cached)
            return
        }
        // 同一部作品已经在后台解析：界面继续转圈，结果到了自然刷新，不再发第二次请求。
        if !force, detailTaskKey == key, detailTask != nil {
            isLoadingDetail = true
            detailError = nil
            return
        }
        detailToken &+= 1
        let token = detailToken
        // 换了一部作品：上一次的解析作废，静默撤掉任务，不在记录里留一串「已取消」。
        abandonDetailParse(discardJob: true)
        isLoadingDetail = true
        detail = nil
        detailError = nil

        // 解析登记成后台任务：页面先展示列表里已有的封面与标题，进度在左下角任务条可见，
        // 离开详情页也不会中断，回来时直接用缓存。
        let jobID = jobCenter?.begin(
            SourceJob(sourceID: .catalog(source.id),
                      kind: .parse,
                      title: "解析《\(item.title)》"),
            cancel: { [weak self] in
                Task { @MainActor in self?.abandonDetailParse(discardJob: false) }
            }
        )
        detailJobID = jobID
        onJobChange?()

        detailTaskKey = key
        detailTask = Task { [weak self] in
            guard let self else { return }
            guard let provider = CatalogProviders.provider(for: source.kind) else {
                self.detailTask = nil
                self.detailTaskKey = nil
                self.isLoadingDetail = false
                self.detailError = CatalogError.unsupportedProvider.localizedDescription
                self.failDetailParse(jobID, message: CatalogError.unsupportedProvider.localizedDescription)
                return
            }
            do {
                var result = try await provider.detail(source: source, itemID: item.id)
                guard !Task.isCancelled else { return }
                if result.item.coverURL.isEmpty { result.item.coverURL = item.coverURL }
                if result.item.title.isEmpty { result.item.title = item.title }
                self.cachedDetails[key] = result
                learnNamesInBackground(from: result)
                self.detailTask = nil
                self.detailTaskKey = nil
                if token == self.detailToken {
                    self.detail = result
                    self.isLoadingDetail = false
                }
                self.finishDetailParse(jobID,
                                       message: result.episodes.isEmpty
                                           ? "\(result.articleImages.count) 张"
                                           : "\(result.episodes.count) 集")
            } catch {
                guard !Task.isCancelled else { return }
                self.detailTask = nil
                self.detailTaskKey = nil
                if token == self.detailToken {
                    if self.isHTTP404(error) {
                        // 快照里的旧条目在站点上已经下架：丢弃这一页的快照，返回列表时会自动刷新。
                        let listKey = self.cacheKey(source: source, page: 1)
                        self.pageSnapshots[listKey] = nil
                        self.cachedPages[listKey] = nil
                        self.detailError = "这条内容可能已经下架（HTTP 404）。返回列表刷新后再试。"
                    } else if source.kind.mayRequireLogin, Self.isLoginWall(error) {
                        self.markLoginRequired(source.id)
                        self.detailError = "站点需要登录后才能查看这条内容。"
                        self.beginSilentCookieRefresh(source)
                    } else {
                        self.detailError = error.localizedDescription
                    }
                    self.isLoadingDetail = false
                }
                self.failDetailParse(jobID, message: error.localizedDescription)
            }
        }
    }

    /// 把详情字段里学到的女优名写进识别词典：读库 + 写库都放后台，
    /// 详情页首帧不再被词典 I/O 占用主线程。
    private func learnNamesInBackground(from detail: CatalogDetail) {
        let names = CatalogNameParser.learnableNames(from: detail)
        guard !names.isEmpty else { return }
        Task.detached(priority: .utility) {
            CatalogNameParser.learn(names: names)
        }
    }

    /// 解析完成：任务中心收尾并归档进任务记录。
    private func finishDetailParse(_ id: UUID?, message: String?) {
        guard let id else { return }
        jobCenter?.finish(id, message: message)
        detailJobID = nil
        onJobChange?()
        onJobFinished?(id)
    }

    private func failDetailParse(_ id: UUID?, message: String?) {
        guard let id else { return }
        jobCenter?.fail(id, message: message)
        detailJobID = nil
        onJobChange?()
        onJobFinished?(id)
    }

    /// 放弃当前解析：`discardJob` 为真时（换作品）连任务记录一起丢掉；
    /// 为假时是用户在任务条里点的取消，保留「已取消」记录。
    private func abandonDetailParse(discardJob: Bool) {
        detailTask?.cancel()
        detailTask = nil
        detailTaskKey = nil
        if let id = detailJobID {
            if discardJob {
                jobCenter?.discard(id)
            } else {
                onJobFinished?(id)
            }
            detailJobID = nil
        }
        isLoadingDetail = false
        onJobChange?()
    }

    func closeDetail() {
        detail = nil
        detailError = nil
        isLoadingDetail = false
        inlineDetailItem = nil
        detailPersonTarget = nil
    }

    // MARK: - 播放

    /// 从详情页点播放时记下的返回目标：关闭播放器后回到那一页详情。
    private var playbackReturnItem: CatalogItem?

    /// 取走并清空返回目标（只在接住这一次播放时有效）。
    func takePlaybackReturnItem() -> CatalogItem? {
        defer { playbackReturnItem = nil }
        return playbackReturnItem
    }

    func play(item: CatalogItem, episode: CatalogEpisode, seconds: Double = 0) {
        guard let source = selectedSource else { return }
        playbackReturnItem = item
        let request = CatalogPlaybackRequest(source: source, item: item,
                                             episodes: detail?.episodes ?? [episode],
                                             startEpisode: episode.index,
                                             startSeconds: seconds)
        emit(request)
    }

    func play(item: CatalogItem, detail: CatalogDetail, episode: CatalogEpisode, seconds: Double) {
        guard let source = selectedSource else { return }
        playbackReturnItem = item
        emit(CatalogPlaybackRequest(source: source, item: item, episodes: detail.episodes,
                                    startEpisode: episode.index, startSeconds: seconds))
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            throw CatalogError.unsupportedProvider
        }
        return try await provider.stream(source: source, episode: episode)
    }

    func closePlayer() {
        playback = nil
    }

    /// 从「继续观看」恢复：先补齐分集，再以保存的秒数起播。
    func resume(_ record: CatalogProgress) {
        guard let source = sources.first(where: { $0.id == record.sourceID }),
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await provider.detail(source: source, itemID: record.itemID)
                guard let episode = detail.episodes.first(where: { $0.index == record.episode })
                        ?? detail.episodes.first else { return }
                self.cachedDetails[self.detailKey(source: source, itemID: record.itemID)] = detail
                self.selectedSourceID = source.id
                self.emit(CatalogPlaybackRequest(
                    source: source, item: detail.item, episodes: detail.episodes,
                    startEpisode: episode.index, startSeconds: record.seconds))
            } catch {
                self.error = error.localizedDescription
                self.sourceError = SourceErrorMapper.map(error)
            }
        }
    }

    /// 从头播放：忽略已保存的秒数，仍按记录的集数起播。
    func restart(_ record: CatalogProgress) {
        var fresh = record
        fresh.seconds = 0
        resume(fresh)
    }

    func progress(sourceID: UUID, itemID: String) -> CatalogProgress? {
        progress[CatalogProgress.key(sourceID: sourceID, itemID: itemID)]
    }

    /// 把一条记录移出观看足迹。
    func removeProgress(_ record: CatalogProgress) {
        progress[record.key] = nil
        CatalogStore.deleteProgress(keys: [record.key])
    }

    /// 清空观看足迹。传 `sourceIDs` 时只清这个范围内的记录（网络影院的足迹页只清影视源）。
    func clearProgress(sourceIDs: Set<UUID>? = nil) {
        let keys: [String] = progress.compactMap { key, record -> String? in
            guard sourceIDs?.contains(record.sourceID) ?? true else { return nil }
            return key
        }
        guard !keys.isEmpty else { return }
        for key in keys { progress[key] = nil }
        CatalogStore.deleteProgress(keys: keys)
    }

    /// 本次刷新才出现、上次快照里没有的条目。
    func isFresh(sourceID: UUID, itemID: String) -> Bool {
        freshItemKeys.contains("\(sourceID.uuidString)|\(itemID)")
    }

    // MARK: - 源管理

    func addSource(_ source: CatalogSource) {
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        saveSources()
        CatalogTrust.sync(sources: sources)
        // 只有网页资源站会切换「网络资源」的当前源；影视源只进网络影院。
        if source.domain == .networkResource {
            selectSource(source.id)
        }
        rebuildTodaySpotlight()
    }

    // MARK: - 配置导入导出

    /// 导出某个域的来源配置：只装这一域的源，导入时不会跨域混入。
    /// 登录态属于本机凭据，导出时一律剔除。
    ///
    /// 顺序按侧边栏看到的样子写：综合站 → 视频站 → 图集站，组内保持手动排序，
    /// 导入时按文件顺序落库，换一台机器也复原同样的排列。
    func exportSourceBundle(domain: CatalogDomain) -> Data? {
        let scoped = sources(in: domain)
        let ordered = CatalogSiteCategory.displayOrder.flatMap { category in
            scoped.filter { $0.kind.siteCategory == category }
        }
        let list = ordered.map { source -> CatalogSource in
            var copy = source
            copy.cookie = nil
            copy.cookieExpiresAt = nil
            // 永久地址是可迁移的站点元数据：显式写进文件，换机器后仍能自动找镜像。
            if copy.addressPageURL == nil {
                copy.addressPageURL = source.kind.defaultAddressPageURL
            }
            return copy
        }
        guard !list.isEmpty else { return nil }
        return SourceTransferJSON.encode(domain.transferScope, items: list)
    }

    /// 侧边栏拖拽排序：顺序同时决定跨源搜索、聚合与榜单的先后。
    /// 只在同域内移动：网络资源的排序不会把影视源的位置挤乱，反之亦然。
    func moveSource(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let item = sources.first(where: { $0.id == id }),
              let target = sources.first(where: { $0.id == targetID }),
              item.domain == target.domain else { return }
        var list = sources(in: item.domain)
        guard let from = list.firstIndex(where: { $0.id == id }),
              let targetIndex = list.firstIndex(where: { $0.id == targetID }) else { return }
        list.remove(at: from)
        let to = from < targetIndex ? targetIndex - 1 : targetIndex
        list.insert(item, at: max(0, min(to, list.count)))
        applyDomainOrder(list, domain: item.domain)
    }

    /// 拖到列表末尾：只在本域内排到最后。
    func moveSourceToEnd(_ id: UUID) {
        guard let item = sources.first(where: { $0.id == id }) else { return }
        var list = sources(in: item.domain)
        guard let from = list.firstIndex(where: { $0.id == id }),
              from < list.count - 1 else { return }
        list.append(list.remove(at: from))
        applyDomainOrder(list, domain: item.domain)
    }

    /// 侧边栏同一分组（综合站 / 视频站 / 图集站）里的源，顺序与侧边栏看到的一致。
    /// 侧边栏按站点类型分组展示，所以上移 / 下移、按钮可用性都只在这一组内算。
    func sourceSiblings(_ id: UUID) -> [CatalogSource] {
        guard let item = sources.first(where: { $0.id == id }) else { return [] }
        return sources(in: item.domain)
            .filter { $0.kind.siteCategory == item.kind.siteCategory }
    }

    /// 右键菜单上移 / 下移：-1 上移，+1 下移。
    /// 只和同组的相邻项换位：跟别的组交换时两组各自的行序其实没变，界面上就会「点了没反应」。
    func moveSource(_ id: UUID, by offset: Int) {
        guard let item = sources.first(where: { $0.id == id }) else { return }
        let siblings = sourceSiblings(id)
        guard let from = siblings.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard siblings.indices.contains(to) else { return }
        var ordered = siblings
        ordered.swapAt(from, to)
        applyGroupOrder(ordered, domain: item.domain, category: item.kind.siteCategory)
    }

    /// 把某一组的新顺序填回域内属于这一组的槽位，其它组的行保持原位。
    private func applyGroupOrder(_ ordered: [CatalogSource],
                                 domain: CatalogDomain,
                                 category: CatalogSiteCategory) {
        var next = ordered.makeIterator()
        let merged = sources.map { current -> CatalogSource in
            guard current.domain == domain,
                  current.kind.siteCategory == category,
                  let replacement = next.next() else { return current }
            return replacement
        }
        guard merged != sources else { return }
        sources = merged
        saveSources()
    }

    /// 把重排后的本域清单写回完整源列表：另一个域的源保持原有位置不动。
    private func applyDomainOrder(_ ordered: [CatalogSource], domain: CatalogDomain) {
        var next = ordered.makeIterator()
        let merged = sources.map { current -> CatalogSource in
            guard current.domain == domain, let replacement = next.next() else { return current }
            return replacement
        }
        guard merged != sources else { return }
        sources = merged
        saveSources()
    }

    func updateSource(_ source: CatalogSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
        saveSources()
        CatalogTrust.sync(sources: sources)
        if let cookie = source.cookie, !cookie.isEmpty {
            loginRequiredSourceIDs.remove(source.id)
        }
        if selectedSourceID == source.id {
            categories = Self.droppingDuplicateHome(source.categories)
            // 地址 / Cookie / UA 变了：分类与归档缓存立即作废并重新取一次。
            Self.invalidateTaxonomy(sourceID: source.id)
            refreshCategories(source: source, force: true)
            // 地址 / Cookie / UA 都是抓取参数：保存后按新配置重新读一遍，
            // 否则用户填完 Cookie 仍然看到旧的登录墙。
            refresh()
        }
    }

    // MARK: - 登录态

    /// 打开「粘贴 Cookie」窗口：Wuso / V2PH 不在应用内登录，统一从浏览器复制 Cookie。
    func presentCookiePrompt(for source: CatalogSource) {
        cookiePromptSource = source
    }

    func dismissCookiePrompt() {
        cookiePromptSource = nil
    }

    /// 保存用户粘贴 / 自动续期拿到的 Cookie，清掉旧缓存并按新登录态重新加载。
    func applyCookie(for source: CatalogSource, cookie: String, expiresAt: Date?,
                     announce: Bool = true) {
        let trimmed = Self.normalizedCookie(cookie)
        guard !trimmed.isEmpty else { return }
        var updated = source
        updated.cookie = trimmed
        updated.cookieExpiresAt = expiresAt
        loginRequiredSourceIDs.remove(source.id)
        health[source.id] = .online
        healthCheckedAt[source.id] = Date()
        // 旧的页面 / 详情可能来自登录墙：按源清掉，避免更新 Cookie 后仍看到旧结果。
        let prefix = source.id.uuidString
        cachedPages = cachedPages.filter { !$0.key.hasPrefix(prefix) }
        cachedDetails = cachedDetails.filter { !$0.key.hasPrefix(prefix) }
        updateSource(updated)
        if selectedSourceID == source.id {
            cachedDetails.removeAll()
            freshItemKeys = []
            if let item = inlineDetailItem { loadDetail(item: item, force: true) }
        }
        if announce { showNotice("已保存 \(source.name) 的 Cookie") }
    }

    /// 从浏览器复制来的 Cookie 常带 `Cookie:` 前缀与换行：统一成请求头格式。
    static func normalizedCookie(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count))
        }
        return value
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    /// 请求命中登录墙：记录状态，页面据此展示「粘贴 Cookie」入口。
    func markLoginRequired(_ sourceID: UUID) {
        loginRequiredSourceIDs.insert(sourceID)
        health[sourceID] = .needsLogin
    }

    /// 页面是否应该提示 Cookie：缺失 / 过期 / 本次请求被登录墙拦下。
    func loginPromptNeeded(for source: CatalogSource) -> Bool {
        guard source.kind.mayRequireLogin else { return false }
        if loginRequiredSourceIDs.contains(source.id) { return true }
        return source.cookieState.needsAttention
    }

    func isRefreshingCookie(_ sourceID: UUID) -> Bool {
        cookieRefreshingSourceIDs.contains(sourceID)
    }

    /// 隐藏 WebView 静默续期：带上现有 Cookie 重新访问站点，
    /// 取回刷新后的 Cookie（Cloudflare clearance / 论坛会话）并替换。
    private func beginSilentCookieRefresh(_ source: CatalogSource) {
        guard source.kind.mayRequireLogin,
              !cookieRefreshingSourceIDs.contains(source.id),
              let cookie = source.cookie, !cookie.isEmpty else { return }
        if let last = cookieRefreshAttemptAt[source.id], Date().timeIntervalSince(last) < 300 {
            return
        }
        cookieRefreshAttemptAt[source.id] = Date()
        cookieRefreshingSourceIDs.insert(source.id)
        Task { [weak self] in
            let result = await CatalogCookieRefreshGate.shared.refresh(source: source)
            guard let self else { return }
            self.cookieRefreshingSourceIDs.remove(source.id)
            guard let result, result.cookie != source.cookie else { return }
            self.applyCookie(for: source, cookie: result.cookie,
                             expiresAt: result.expiresAt, announce: false)
        }
    }

    /// Cookie 快过期时提前在后台续一次（隐藏 WebView，不弹窗）。
    private func renewCookieIfNeeded(_ source: CatalogSource) {
        guard source.kind.mayRequireLogin,
              let cookie = source.cookie, !cookie.isEmpty else { return }
        if source.cookieState == .expiringSoon || source.cookieState == .expired {
            beginSilentCookieRefresh(source)
        }
    }

    /// 登录墙 / 403：与普通网络故障区分，避免把「需要登录」显示成离线快照。
    private static func isLoginWall(_ error: Error) -> Bool {
        guard let catalogError = error as? CatalogError else { return false }
        switch catalogError {
        case .authRequired:
            return true
        case .http(let status):
            return status == 401 || status == 403
        default:
            return false
        }
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = enabled
        saveSources()
        if selectedSourceID == id {
            categories = Self.droppingDuplicateHome(sources[index].categories)
            refreshCategories(source: sources[index])
            reload()
        }
    }

    /// 用户对该源显式放行证书校验；只影响这一个主机，且下次启动仍按源配置生效。
    func setInsecureTLS(_ id: UUID, _ enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].allowsInsecureTLS = enabled
        saveSources()
        CatalogTrust.sync(sources: sources)
        if selectedSourceID == id { refresh() }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].name = trimmed
        saveSources()
        rebuildTodaySpotlight()
    }

    func remove(_ id: UUID) {
        sources.removeAll { $0.id == id }
        CatalogCookieVault.save(nil, for: id)
        CatalogTrust.sync(sources: sources)
        progress = progress.filter { $0.value.sourceID != id }
        favorites = favorites.filter { $0.value.sourceID != id }
        watchedKeys = watchedKeys.filter { !$0.hasPrefix(id.uuidString + "|") }
        cachedPages = cachedPages.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        cachedDetails = cachedDetails.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        pageSnapshots = pageSnapshots.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        CatalogSnapshotStore.remove(prefix: id.uuidString + "|")
        // 网络影院的列表快照与网络资源同源：移除源后一并清掉该源的条目。
        NetworkCinemaSnapshotStore.remove(sourceID: id)
        categoryThumbs = categoryThumbs.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        saveCategoryThumbs()
        saveSources()
        CatalogStore.deleteProgress(sourceID: id)
        CatalogStore.deleteCalendar(sourceID: id)
        calendarItems = calendarItems.filter { $0.sourceID != id }
        saveFavorites()
        saveWatched()
        rebuildTodaySpotlight()
        if selectedSourceID == id {
            // 只在网络资源里挑替补：影视源不会成为资源页的当前源。
            selectedSourceID = enabledResourceSources.first?.id ?? resourceSources.first?.id
            if let source = selectedSource {
                prepare(source: source)
                openHome()
            } else {
                items = []
                categories = []
            }
        }
        Task { await CatalogArtworkCache.shared.clear(sourceID: id) }
    }

    func clearArtwork(_ id: UUID) {
        CatalogArtworkMemory.shared.removeAll()
        Task { await CatalogArtworkCache.shared.clear(sourceID: id) }
    }

    func clearAllArtwork() {
        CatalogArtworkMemory.shared.removeAll()
        Task { await CatalogArtworkCache.shared.clear(sourceID: nil) }
    }

    // MARK: - 内部

    private func prepare(source: CatalogSource) {
        categories = Self.droppingDuplicateHome(source.categories)
        activeTopCategoryID = nil
        collectionOrigin = nil
        collectionTitle = nil
        tags = []
        tagGroups = []
        if tagWallSourceID != source.id {
            tagWallTags = []
            tagWallSourceID = nil
            isTagWallLoading = false
        }
        if archiveSourceID != source.id {
            archiveEntries = []
            archiveSourceID = nil
            isArchiveLoading = false
        }
        // 换源后旧源的排序可能不受支持：退回站点默认顺序，避免界面显示「热播」但结果没变。
        if let provider = CatalogProviders.provider(for: source.kind),
           !provider.supportedSorts.contains(sort) {
            sort = .latest
        }
        localSort = nil
        cachedPages = cachedPages.filter { $0.key.hasPrefix(source.id.uuidString + "|") }
        cachedDetails = cachedDetails.filter { $0.key.hasPrefix(source.id.uuidString + "|") }
        refreshCategories(source: source)
    }

    /// 分类以站点导航为准：先用本地保存的一二级占位，一天内不再重复抓首页；
    /// 缓存过期（或没有缓存）时再后台拉一次站点分类。
    private func refreshCategories(source: CatalogSource, force: Bool = false) {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return }
        if !force, !categories.isEmpty,
           Self.taxonomyFresh("categories", sourceID: source.id) {
            refreshTags(source: source, category: activeTopCategory)
            return
        }
        Task { [weak self] in
            let live = try? await provider.categories(source: source)
            guard let self, self.selectedSourceID == source.id else { return }
            if let live, !live.isEmpty {
                // 已经按需补齐的二级频道不能被实时分类覆盖掉。
                var merged = live.map { fresh in
                    guard fresh.children?.isEmpty ?? true,
                          let local = self.categories.first(where: { $0.id == fresh.id }),
                          let children = local.children, !children.isEmpty else { return fresh }
                    var updated = fresh
                    updated.children = children
                    return updated
                }
                // 苹果CMS 的接口顺序和站点导航不一致：量子资源按站点的真实导航重排，
                // 其它站保留本地已排好的顺序，新增分类追加到末尾。
                if Self.isLzzyBookmark(source) {
                    merged = MacCMSCatalogProvider.alignedWithLzzyNavigation(merged)
                } else if source.kind == .maccms, !self.categories.isEmpty {
                    let order = Dictionary(uniqueKeysWithValues: self.categories.enumerated()
                        .map { ($0.element.id, $0.offset) })
                    merged.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
                }
                self.categories = Self.droppingDuplicateHome(merged)
                // 写回源配置：下次进来第一眼看到的就是最新的一、二级，而不是导入时的旧骨架。
                self.persistCategories(self.categories, for: source.id)
                Self.markTaxonomyFetched("categories", sourceID: source.id)
            }
            self.refreshTags(source: source, category: self.activeTopCategory)
        }
    }

    /// 频道页顶部已经有统一的「首页」入口，站点自带的首頁 / 首页分类会和它重复。
    static func droppingDuplicateHome(_ categories: [CatalogCategory]) -> [CatalogCategory] {
        categories.filter {
            $0.id != "home" && !["首页", "首頁", "主页", "主頁"].contains($0.title)
        }
    }

    /// 实时分类持久化到源上；内容没变就不重复写盘。
    private func persistCategories(_ categories: [CatalogCategory], for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              sources[index].categories != categories else { return }
        sources[index].categories = categories
        saveSources()
    }

    /// 二级标签跟随当前一级分类：肉视频这类站点把片商 / 题材挂在主分类下面。
    /// 每个一级分类的标签各存一份，先铺缓存占位，一天内不重复请求。
    private func refreshTags(source: CatalogSource, category: CatalogCategory?) {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return }
        let scope = category?.id ?? "root"
        let cached = Self.loadTagSnapshot(sourceID: source.id, scope: scope)
        if let cached {
            tags = cached.tags
            tagGroups = cached.groups
        }
        // 缓存命中也要让在途请求失效：否则上一个一级分类的实时结果会覆盖当前标签。
        tagsToken &+= 1
        if cached != nil, Self.taxonomyFresh("tags", sourceID: source.id, scope: scope) {
            return
        }
        let token = tagsToken
        Task { [weak self] in
            let liveTags = try? await provider.tags(source: source, category: category)
            let liveGroups = try? await provider.tagGroups(source: source, category: category)
            guard let self, self.tagsToken == token, self.selectedSourceID == source.id else { return }
            if let liveTags { self.tags = liveTags }
            if let liveGroups { self.tagGroups = liveGroups }
            // 这次完全没取到（断网 / 限流）不写缓存，下次进页面再试。
            guard liveTags != nil || liveGroups != nil else { return }
            let nextTags = self.tags
            let nextGroups = self.tagGroups
            // 空结果同样不写缓存：可能只是这次没取到。
            guard !nextTags.isEmpty || !nextGroups.isEmpty else { return }
            Self.saveTagSnapshot(TagSnapshot(tags: nextTags, groups: nextGroups),
                                 sourceID: source.id, scope: scope)
            Self.markTaxonomyFetched("tags", sourceID: source.id, scope: scope)
        }
    }

    /// 已拉取过二级频道的分类：避免重复点一级时反复请求。
    private var channelRequests: Set<String> = []

    /// 二级频道按需拉取：拉到后挂回分类树，频道行随即出现。
    private func loadChannels(source: CatalogSource, category: CatalogCategory) {
        let key = "\(source.id.uuidString)|\(category.id)"
        guard channelRequests.insert(key).inserted,
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        Task { [weak self] in
            let live = try? await provider.channels(source: source, category: category)
            guard let self, self.selectedSourceID == source.id,
                  let live, !live.isEmpty,
                  let index = self.categories.firstIndex(where: { $0.id == category.id })
            else { return }
            self.categories[index].children = live
            self.persistCategories(self.categories, for: source.id)
        }
    }

    /// 点的是不是已经展示出来的标签（说明它在二级层，不需要重新取上下文）。
    private func isKnownTag(_ category: CatalogCategory) -> Bool {
        tags.contains { tag in
            tag.id == category.id
                || (tag.children?.contains(where: { $0.id == category.id }) ?? false)
        }
    }

    private func cacheKey(source: CatalogSource, page: Int) -> String {
        "\(source.id.uuidString)|\(sectionKey)|\(sort.rawValue)|\(page)"
    }

    func detailKey(source: CatalogSource, itemID: String) -> String {
        "\(source.id.uuidString)|detail|\(itemID)"
    }

    private var sectionKey: String {
        switch section {
        case .home: return "home"
        case .category(let id): return "cat-\(id)"
        case .rank: return "rank"
        case .search(let keyword): return "search-\(keyword)"
        case .continueWatching: return "continue"
        case .favorites: return "favorites"
        }
    }

    // MARK: - 持久化

    private func load() {
        if let data = CatalogStore.data(forKey: Self.sourcesKey),
           let decoded = try? JSONDecoder().decode([CatalogSource].self, from: data) {
            // 站点换域名：爱壹帆迁移到 kubb.tv，量子资源迁移到 lzzy.tv；迁移函数本身幂等。
            let normalized = decoded.map(Self.migratedEndpoint)
            // 旧配置里只有一级：按适配器最新的站点骨架补齐二级分类，并写回。
            let enriched = normalized.map { CatalogProviders.enrich($0) }
            // 登录态 Cookie 从钥匙串恢复；旧版本写在 JSON 里的明文顺便迁进去并抹掉。
            var migratedLegacyCookie = false
            var hydrated: [CatalogSource] = []
            hydrated.reserveCapacity(enriched.count)
            for var source in enriched {
                let legacy = source.cookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !legacy.isEmpty {
                    if CatalogCookieVault.cookie(for: source.id) == nil {
                        CatalogCookieVault.save(legacy, for: source.id)
                    }
                    source.cookie = nil
                    migratedLegacyCookie = true
                }
                source.cookie = CatalogCookieVault.cookie(for: source.id)
                hydrated.append(source)
            }
            sources = hydrated
            if enriched != decoded || migratedLegacyCookie { saveSources() }
        }
        progress = CatalogStore.loadProgress()
        if let data = CatalogStore.data(forKey: Self.favoritesKey),
           let decoded = try? JSONDecoder().decode([String: CatalogFavorite].self, from: data) {
            favorites = decoded
        }
        if let data = CatalogStore.data(forKey: Self.watchedKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            watchedKeys = Set(decoded)
        }
        if let data = CatalogStore.data(forKey: Self.categoryThumbsKey),
           let thumbs = try? JSONDecoder().decode([String: String].self, from: data) {
            categoryThumbs = thumbs
        }
        loadDiscovery()
        CatalogTrust.sync(sources: sources)
    }

    /// 量子资源的接口顺序和站点导航不一致，需要按固定导航对齐分类。
    private static func isLzzyBookmark(_ source: CatalogSource) -> Bool {
        guard source.kind == .maccms else { return false }
        let host = (URL(string: source.baseURL)?.host ?? "").lowercased()
        return host.contains("lzzy.tv")
    }

    /// 站点换域名时就地迁移，保留启用状态与排序：
    /// - 爱壹帆换成了 kubb.tv（同一套接口）。
    /// - 量子资源旧的 cj.lziapi.com 接口已不可达，换成站点自己的 www.lzzy.tv 接口，
    ///   并补齐固定的两级分类骨架（该站 type_id 长期稳定）。
    private static func migratedEndpoint(_ source: CatalogSource) -> CatalogSource {
        let host = (URL(string: source.baseURL)?.host ?? "").lowercased()

        if source.kind == .iyf, host.hasSuffix("iyf.tv") {
            var updated = source
            updated.baseURL = "https://www.kubb.tv"
            updated.referer = "https://www.kubb.tv/"
            updated.configURL = "https://www.kubb.tv/"
            if updated.name.contains("爱壹帆") { updated.name = "Kubb" }
            return updated
        }

        if source.kind == .maccms,
           host.contains("lziapi.com") || host.contains("lzzy.tv") {
            var updated = source
            if host.contains("lziapi.com") {
                updated.baseURL = "https://www.lzzy.tv"
                updated.referer = "https://www.lzzy.tv/"
                updated.configURL = "https://www.lzzy.tv"
                updated.apiBase = "https://www.lzzy.tv/api.php/provide/vod/"
            }
            // 旧源没有分类、顺序和站点导航不一致、或只有一级：按量子资源真实导航重排并补齐。
            updated.categories = MacCMSCatalogProvider.alignedWithLzzyNavigation(updated.categories)
            return updated
        }

        return source
    }

    private func saveSources() {
        // 登录态 Cookie 只写钥匙串；落盘前从 JSON 副本里抹掉，避免明文进图库数据库。
        for source in sources {
            let current = source.cookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stored = CatalogCookieVault.cookie(for: source.id) ?? ""
            if current != stored {
                CatalogCookieVault.save(source.cookie, for: source.id)
            }
        }
        let sanitized = sources.map { source -> CatalogSource in
            var copy = source
            copy.cookie = nil
            return copy
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        CatalogStore.set(data, forKey: Self.sourcesKey)
    }

    /// 播放中每次进度变化只写一行；超出上限时再按更新时间清掉最旧的行。
    /// 写入方只有 `SourcePlaybackProgressStore`，这里负责落盘与容量兜底。
    func persistProgress(_ record: CatalogProgress) {
        CatalogStore.saveProgress(record)
        guard progress.count > 200 else { return }
        let kept = progress.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(200)
        let keptKeys = Set(kept.map(\.key))
        let evicted = progress.keys.filter { !keptKeys.contains($0) }
        progress = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0) })
        CatalogStore.deleteProgress(keys: evicted)
    }

    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        CatalogStore.set(data, forKey: Self.favoritesKey)
    }

    private func saveWatched() {
        guard let data = try? JSONEncoder().encode(Array(watchedKeys)) else { return }
        CatalogStore.set(data, forKey: Self.watchedKey)
    }

    private func saveCategoryThumbs() {
        guard let data = try? JSONEncoder().encode(categoryThumbs) else { return }
        CatalogStore.set(data, forKey: Self.categoryThumbsKey)
    }
}
