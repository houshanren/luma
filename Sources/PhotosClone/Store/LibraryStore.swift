import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaCore

struct LibraryData: Codable {
    var photos: [PhotoItem] = []
    var albums: [Album] = []
    var folders: [AlbumFolder] = []

    init() {}

    init(photos: [PhotoItem] = [], albums: [Album] = [], folders: [AlbumFolder] = []) {
        self.photos = photos
        self.albums = albums
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photos = (try? container.decodeIfPresent([PhotoItem].self, forKey: .photos)) ?? []
        albums = (try? container.decodeIfPresent([Album].self, forKey: .albums)) ?? []
        folders = (try? container.decodeIfPresent([AlbumFolder].self, forKey: .folders)) ?? []
    }
}

/// 搜索范围：当前视图内 / 全库。
enum SearchScope: String, CaseIterable {
    case currentView
    case global

    var title: String {
        switch self {
        case .currentView: return "当前视图"
        case .global: return "全局"
        }
    }

    var shortTitle: String {
        switch self {
        case .currentView: return "视图内"
        case .global: return "全局"
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var photos: [PhotoItem] = [] {
        didSet { contentRevision &+= 1 }
    }
    @Published var albums: [Album] = [] {
        didSet { contentRevision &+= 1 }
    }
    @Published var folders: [AlbumFolder] = [] {
        didSet { contentRevision &+= 1 }
    }
    /// 智能相簿：按条件自动筛选，不需要手动加入照片。
    @Published var smartAlbums: [SmartAlbum] = [] {
        didSet { contentRevision &+= 1 }
    }
    /// 被固定到侧边栏「固定」分区的相簿与文件夹（按固定顺序展示）。
    @Published var pinnedItems: [PinnedSidebarItem] = []
    /// 正在编辑的智能相簿草稿（非空时弹出编辑器）。
    @Published var editingSmartAlbum: SmartAlbum?

    @Published var sidebarItem: SidebarItem = .library {
        didSet {
            guard sidebarItem != oldValue else { return }
            // 每个侧边栏页面各自记住滑杆位置：离开前存下当前范围，进入目标范围时恢复。
            thumbSizes[thumbSizeScopeKey(for: oldValue)] = thumbSize
            if let saved = thumbSizes[thumbSizeScopeKey(for: sidebarItem)] {
                thumbSize = saved
            } else {
                // 新打开的页面用设置里的默认大小，不再沿用上一个页面可能调小后的值。
                thumbSize = defaultGridThumbSize
                thumbSizes[thumbSizeScopeKey(for: sidebarItem)] = thumbSize
            }
            persistThumbSizes()
            // 卡片墙的每行张数同样按页面记忆。
            cardColumnsByScope[cardColumnsScopeKey(for: oldValue)] = cardColumns
            if let saved = cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] {
                cardColumns = saved
            } else {
                cardColumns = Self.defaultCardColumnsValue
                cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] = cardColumns
            }
            persistCardColumns()
            loadSystemLibraryIfNeeded(sidebarItem)
        }
    }
    @Published var grouping: GridGrouping = .all {
        didSet { persistViewPreference(SettingsKeys.grouping, grouping.rawValue) }
    }
    /// 「个人收藏」的浏览方式（全部 / 年 / 类型 / 地点 / 相机 / 人物），随当前图库保存；默认先看年份。
    @Published var favoritesViewMode: FavoritesViewMode = .years {
        didSet {
            guard favoritesViewMode != oldValue else { return }
            persistViewPreference(SettingsKeys.favoritesViewMode, favoritesViewMode.rawValue)
            selectedFavoriteBucket = nil
        }
    }
    /// 收藏汇总页正在下钻的分类；非空时网格只显示该类收藏。
    @Published var selectedFavoriteBucket: FavoritesBucketSelection?
    @Published var favoritesDigest: FavoritesDigest?
    @Published var isLoadingFavoritesDigest = false
    /// 汇总数据源（完整收藏列表），卡片封面与下钻过滤共用。
    var favoritesDigestSource: [PhotoItem] = []
    var favoritesDigestLoadedToken = ""
    var favoritesDigestTask: Task<Void, Never>?
    /// 缩略图 / 卡片尺寸范围（pt）：滑杆、按钮、⌘+ / ⌘-、捏合都按这个范围夹紧。
    static let thumbSizeRange: ClosedRange<Double> = 56...360

    /// 正方形照片网格的格子间距（与 SquarePhotoGrid 一致）。
    static let gridSpacing: CGFloat = 2
    /// 设置面板还没拿到真实网格宽度时的估算宽度。
    static let gridFallbackWidth: CGFloat = 1000

    /// 图库网格内容区宽度，由 GalleryView 的布局回传；设置面板据此换算出真实的每行张数。
    @Published var gridContentWidth: CGFloat = 0

    /// 换算用的内容宽度：还没渲染过照片网格时按常见窗口宽度估算。
    var gridLayoutWidth: CGFloat {
        gridContentWidth > 200 ? gridContentWidth : Self.gridFallbackWidth
    }

    /// 当前页面在真实内容宽度下每行能放下几张（与网格实际列数一致）。
    var gridColumnCount: Int {
        Self.gridColumnCount(forThumbSize: thumbSize, contentWidth: gridLayoutWidth)
    }

    static func gridColumnCount(forThumbSize size: Double, contentWidth: CGFloat) -> Int {
        max(1, GridLayout.columns(contentWidth: max(120, contentWidth),
                                  targetSize: CGFloat(size),
                                  spacing: gridSpacing))
    }

    /// 反算：让这个宽度下正好每行 `columns` 张的缩略图尺寸。
    static func thumbSize(forGridColumns columns: Int, contentWidth: CGFloat) -> Double {
        let width = max(120, contentWidth)
        let count = CGFloat(max(1, columns))
        let raw = (width + gridSpacing) / count - gridSpacing - 0.01
        return min(thumbSizeRange.upperBound, max(thumbSizeRange.lowerBound, Double(raw)))
    }

    /// 「图片列表新页面默认」在当前窗口宽度下对应的缩略图尺寸。
    var defaultGridThumbSize: Double {
        Self.thumbSize(forGridColumns: AppSettings.shared.defaultGridColumns,
                       contentWidth: gridLayoutWidth)
    }

    @Published var thumbSize: Double = LibraryStore.thumbSize(forGridColumns: AppSettings.shared.defaultGridColumns,
                                                              contentWidth: LibraryStore.gridFallbackWidth) {
        didSet {
            let clamped = min(Self.thumbSizeRange.upperBound,
                              max(Self.thumbSizeRange.lowerBound, thumbSize))
            if clamped != thumbSize {
                thumbSize = clamped
                return
            }
            persistViewPreference(SettingsKeys.thumbSize, String(thumbSize))
            // 记住当前侧边栏页面自己的滑杆位置。
            let key = thumbSizeScopeKey(for: sidebarItem)
            if thumbSizes[key] != thumbSize {
                thumbSizes[key] = thumbSize
                persistThumbSizes()
            }
        }
    }

    /// 每个侧边栏页面的缩略图尺寸（「放大 / 缩小」滑杆位置），随当前图库保存。
    private var thumbSizes: [String: Double] = [:]

    /// 滑杆记忆的键：同一相簿 / 文件夹 / 场景各自独立。
    func thumbSizeScopeKey(for item: SidebarItem) -> String {
        String(describing: item)
    }

    private func persistThumbSizes() {
        guard let data = try? JSONEncoder().encode(thumbSizes),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(SettingsKeys.thumbSizes, json)
    }

    /// ⌘0 / 菜单「恢复默认缩略图大小」：当前页面回到设置里的默认尺寸。
    func resetThumbSizeToDefault() {
        thumbSize = defaultGridThumbSize
    }

    /// 把设置里的默认尺寸应用到所有侧边栏页面，清掉各页面单独记忆的滑杆位置。
    func applyDefaultThumbSizeToAllScopes() {
        thumbSizes.removeAll()
        thumbSize = defaultGridThumbSize
        thumbSizes[thumbSizeScopeKey(for: sidebarItem)] = thumbSize
        persistThumbSizes()
    }

    // MARK: 卡片墙（相簿 / 媒体类型 / 场景 / 更多项目 / 关键词）

    /// 卡片墙每行列数范围。
    static let cardColumnsRange: ClosedRange<Int> = 2...8

    static var defaultCardColumnsValue: Int {
        min(cardColumnsRange.upperBound,
            max(cardColumnsRange.lowerBound, AppSettings.shared.defaultCardColumns))
    }

    /// 卡片墙每行列数，按侧边栏页面分别记忆。
    @Published var cardColumns: Int = LibraryStore.defaultCardColumnsValue {
        didSet {
            let clamped = min(Self.cardColumnsRange.upperBound,
                              max(Self.cardColumnsRange.lowerBound, cardColumns))
            if clamped != cardColumns {
                cardColumns = clamped
                return
            }
            let key = cardColumnsScopeKey(for: sidebarItem)
            if cardColumnsByScope[key] != cardColumns {
                cardColumnsByScope[key] = cardColumns
                persistCardColumns()
            }
        }
    }

    private var cardColumnsByScope: [String: Int] = [:]

    func cardColumnsScopeKey(for item: SidebarItem) -> String {
        String(describing: item)
    }

    private func persistCardColumns() {
        guard let data = try? JSONEncoder().encode(cardColumnsByScope),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(SettingsKeys.cardColumns, json)
    }

    /// 当前页面是卡片墙而不是照片网格。
    var isCardWallScope: Bool {
        switch sidebarItem {
        case .allAlbums, .folder, .systemFolder, .systemAlbums,
             .mediaTypes, .systemMediaTypes, .scenes, .systemScenes,
             .moreItems, .systemMoreItems, .keywords, .systemKeywords:
            return true
        case .cloudMount:
            // 网盘的分区总览与图库的分类卡片墙一致：缩放调的是列数。
            return cloudOverviewSection != nil
        default:
            return false
        }
    }

    /// 工具栏放大 / 缩小：卡片墙改列数，照片网格改缩略图尺寸。
    func zoomStep(_ delta: Int) {
        if isCardWallScope {
            cardColumns = min(Self.cardColumnsRange.upperBound,
                              max(Self.cardColumnsRange.lowerBound, cardColumns + delta))
        } else {
            thumbSize = min(Self.thumbSizeRange.upperBound,
                            max(Self.thumbSizeRange.lowerBound,
                                thumbSize + Double(delta) * 16))
        }
    }

    /// ⌘0：当前页面回到设置里的默认密度。
    func resetZoom() {
        if isCardWallScope {
            cardColumns = Self.defaultCardColumnsValue
        } else {
            resetThumbSizeToDefault()
        }
    }

    /// 把设置里的卡片默认列数应用到所有侧边栏页面。
    func applyDefaultCardColumnsToAllScopes() {
        cardColumnsByScope.removeAll()
        cardColumns = Self.defaultCardColumnsValue
        cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] = cardColumns
        persistCardColumns()
    }

    /// 升级到「每行张数」后，等网格真实宽度已知再把当前页面对齐到默认密度。
    private var pendingDensityReconcile = false

    func reconcileDefaultDensitiesIfNeeded() {
        guard pendingDensityReconcile, gridContentWidth > 200 else { return }
        pendingDensityReconcile = false
        thumbSize = defaultGridThumbSize
        thumbSizes[thumbSizeScopeKey(for: sidebarItem)] = thumbSize
        persistThumbSizes()
        cardColumns = Self.defaultCardColumnsValue
        cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] = cardColumns
        persistCardColumns()
    }

    @Published var thumbnailAspect: ThumbnailAspect = .square {
        didSet { persistViewPreference(SettingsKeys.thumbnailAspect, thumbnailAspect.rawValue) }
    }
    /// 相簿总览（「所有相簿」与文件夹层级）的展示形式，随当前图库保存。
    @Published var albumDisplayStyle: AlbumDisplayStyle = .grid {
        didSet { persistViewPreference(SettingsKeys.albumDisplayStyle, albumDisplayStyle.rawValue) }
    }
    @Published var photoFilter: PhotoFilter = .all
    @Published var keywordFilter: String?
    /// 元数据筛选：评分下限（0 表示不限）、旗标、色标。
    @Published var ratingFilter: Int = 0
    @Published var flagFilter: PhotoFlag?
    @Published var colorLabelFilter: PhotoColorLabel?
    /// 关键词页里进入的单个关键词（卡片墙点入后的独立详情）。
    @Published var selectedKeyword: String?
    /// 「位置」页里进入的单个地点。
    @Published var selectedPlace: PlaceCluster?
    /// 「位置」页的聚合层级（省 / 市 / 区县 / 街道），随当前图库保存；默认细到街道。
    @Published var placeGranularity: PlaceGranularity = .street {
        didSet {
            guard placeGranularity != oldValue else { return }
            persistViewPreference(SettingsKeys.placeGranularity, placeGranularity.rawValue)
            selectedPlace = nil
            resetPlaceClusterCaches()
        }
    }
    @Published var isResolvingPlaces = false
    @Published var placeResolveDone = 0
    @Published var placeResolveTotal = 0
    /// 「人物」页的聚合筛选（全部 / 已命名 / 待命名 / 宠物），随当前图库保存。
    @Published var peopleFilter: PeopleGroupFilter = .all {
        didSet {
            guard peopleFilter != oldValue else { return }
            persistViewPreference(SettingsKeys.peopleFilter, peopleFilter.rawValue)
        }
    }
    /// 「人物」总览的头像形状（圆形 / 圆角方形），随当前图库保存。
    @Published var peopleDisplayStyle: PeopleDisplayStyle = .circle {
        didSet {
            guard peopleDisplayStyle != oldValue else { return }
            persistViewPreference(SettingsKeys.peopleDisplayStyle, peopleDisplayStyle.rawValue)
        }
    }
    /// 「整理工作室」的浏览维度（评分 / 旗标 / 色标 / 关键词），随当前图库保存。
    @Published var organizeDimension: OrganizeDimension = .rating {
        didSet {
            guard organizeDimension != oldValue else { return }
            persistViewPreference(SettingsKeys.organizeDimension, organizeDimension.rawValue)
        }
    }
    /// 整理工作室的分布统计：由整理页重新取数时回填，顶栏胶囊直接读取。
    @Published var organizeStudioStats = OrganizeStudioStats()
    @Published var sortKey: SortKey = .capturedAt {
        didSet { persistViewPreference(SettingsKeys.sortKey, sortKey.rawValue) }
    }
    /// 升序 / 降序（日期类默认降序，名称类默认升序）。
    @Published var sortAscending: Bool = false {
        didSet { persistViewPreference(SettingsKeys.sortAscending, sortAscending ? "1" : "0") }
    }
    @Published var searchText: String = ""
    /// 自然语言搜索扩展出的标准标签（由本地 SigLIP 文本编码器异步计算）。
    @Published var semanticSearchTags: [String] = []
    /// 搜索范围：全局（全库）或当前视图。默认全局。
    @Published var searchScope: SearchScope = .global
    var semanticSearchQuery = ""
    var semanticSearchTask: Task<Void, Never>?
    /// ⌘F 聚焦请求：自增一次即让顶栏搜索框获得焦点。
    @Published var searchFocusRequest = 0
    /// 选择状态独立成模型，避免选中项变化导致图库整体刷新。
    let selectionModel = SelectionModel()
    var selection: Set<UUID> {
        get { selectionModel.ids }
        set { selectionModel.ids = newValue }
    }
    /// 键盘导航时请求网格滚动到指定照片。
    @Published var scrollTargetID: UUID?
    /// 月总览里请求滚动到指定月份分段。
    @Published var scrollTargetSection: String?
    /// 顶栏副标题：网格当前可见区域的日期范围，随滚动动态更新。
    @Published var visibleDateSpanText = ""
    var selectionAnchorID: UUID?

    /// 查看器 / 编辑器状态独立成模型。
    let viewerModel = ViewerModel()
    var viewerID: UUID? {
        get { viewerModel.viewerID }
        set { viewerModel.viewerID = newValue }
    }
    var editorID: UUID? {
        get { viewerModel.editorID }
        set { viewerModel.editorID = newValue }
    }
    /// 从某张照片复制下来的编辑点（JSON）。
    @Published var copiedEditRecipe: String?
    var showInfoPanel: Bool {
        get { viewerModel.showInfoPanel }
        set { viewerModel.showInfoPanel = newValue }
    }
    @Published var showNewAlbumSheet = false
    @Published var showLibraryInfo = false
    @Published var showKeywordManager = false
    @Published var showShortcutHelp = false
    @Published var showSlideshow = false
    /// 智能助手面板（只读问答 + 检索建议）。
    @Published var showAIAssistant = false
    @Published var aiMessages: [AIChatMessage] = []
    @Published var aiInput = ""
    @Published var aiConfig = AIConfig()
    @Published var aiIsResponding = false
    @Published var aiError: String?
    @Published var activeMemory: PhotoMemory?
    /// 正在查看的旅行故事线。
    @Published var activeTrip: TripStory?

    /// 尚未选择图库：必须先新建或打开一个 .photoslibrary 才能进入主界面。
    @Published var needsLibrarySetup = false
    /// 图库选择器（按住 Option 启动时自动弹出）。
    @Published var showLibraryPicker = false
    /// 启动时就弹出的图库选择器：选定之前不打开任何图库，主界面先保持空白。
    @Published var libraryPickerOnLaunch = false

    @Published var showImportSheet = false
    @Published var showPhotoPicker = false
    @Published var importPanelOpenRequest = 0
    @Published var importCandidates: [ImportCandidate] = []
    @Published var importProgress: ImportProgress?
    @Published var isImporting = false
    @Published var importCancelled = false

    /// 图库保险库：备份 / 校验 / 恢复的界面状态。
    @Published var vaultProgress: VaultProgress?
    @Published var vaultReport: VaultReport?
    @Published var vaultBackupPath: String?
    @Published var vaultLastBackupDate: Date?

    @Published var showCompressionSheet = false
    @Published var compressionTargets: Set<UUID> = []
    @Published var compressionSettings = CompressionSettings()
    @Published var compressionEstimates: [UUID: CompressionEstimate] = [:]
    @Published var compressionEstimating = false

    /// 批量更改（标题 / 拍摄日期 / 地点）。
    @Published var showBatchChangeSheet = false
    @Published var batchChangeTargets: Set<UUID> = []

    /// 导出设置面板。
    @Published var showExportSheet = false
    @Published var exportOptions = ExportOptions()
    @Published var exportTargets: Set<UUID> = []
    @Published var compressionProgress: CompressionProgress?
    @Published var isCompressing = false

    /// 删除前的确认请求：界面层先展示优雅提示，用户确认后才真正删除。
    /// 移到最近删除、永久删除与清空最近删除都走这里；智能助手等已有自己确认流程的入口可直接调 `delete`。
    @Published var pendingDeletion: DeleteRequest?

    /// 断开系统图库 / 网络存储前的确认请求（只移除连接与本机缓存，不动原始数据）。
    @Published var pendingDisconnect: DisconnectRequest?

    @Published var systemLibraryPath: String?
    @Published var systemLibraryName: String?
    /// 当前打开并作为拾光系统图库的容器路径；切换图库后设置页会即时刷新。
    @Published var containerLibraryPath: String?
    /// 侧边栏「系统图库」里展示的所有已连接图库。
    @Published var systemLibraries: [SystemLibraryRef] = []
    @Published var systemPhotos: [PhotoItem] = [] {
        didSet { contentRevision &+= 1 }
    }
    /// 官方「照片」图库照片的拾光补充元数据（收藏 / 隐藏 / 查看时间 / 关键词 / 标题）。
    /// 只存在当前图库自己的 `PhotosClone.sqlite`，不写回 `Photos.sqlite`。
    var systemOverlays: [UUID: MetadataStore.AssetOverlay] = [:]
    @Published var systemAlbums: [SystemAlbumInfo] = [] {
        didSet {
            contentRevision &+= 1
            systemStructureRevision &+= 1
        }
    }
    @Published var systemFolders: [SystemFolderInfo] = [] {
        didSet {
            contentRevision &+= 1
            systemStructureRevision &+= 1
        }
    }
    /// 相簿 / 文件夹结构版本：与逐批到达的照片增量分离，
    /// 避免扫描过程中每 2000 张就重建一次上万个相簿的分桶与排序。
    var systemStructureRevision = 0
    /// 系统相簿主键索引：侧边栏封面与按 ID 查找不再线性扫全量相簿数组。
    var systemAlbumIndex: [Int64: SystemAlbumInfo] = [:]
    /// 侧边栏计数（有效 / 隐藏 / 删除 / 重复等）的合并缓存，按内容版本失效。
    var systemCountsCache: SystemSidebarCounts?
    var systemCountsCacheRevision = -1
    @Published var systemPeople: [SystemPersonInfo] = []
    @Published var selectedPerson: SystemPersonInfo?
    /// 本地图库的端侧人物聚类结果。
    @Published var localPeople: [LocalPerson] = []
    @Published var selectedLocalPersonID: UUID?
    @Published var isClusteringFaces = false
    @Published var faceClusterProgress: FaceClusterProgress?
    /// 照片 → 已命名人物的反向索引：查看器在画面上打名字时用，避免每次重绘都扫全部聚类。
    var photoPersonNamesIndex: [UUID: [PhotoPersonName]] = [:]
    var photoPersonNamesIndexKey = ""
    /// 端侧智能分析索引（场景标签 + OCR 文字），仅本地图库。
    @Published var analysisIndex: [UUID: PhotoAnalysis] = [:]
    @Published var isAnalyzingIntelligence = false
    @Published var intelligenceDone = 0
    @Published var intelligenceTotal = 0
    /// 系统图库的端侧识别结果（场景 / 图内文字）。内存即时刷新，并写入当前图库的 `system_analysis`。
    @Published var systemAnalysisIndex: [UUID: PhotoAnalysis] = [:]
    /// 系统图库的端侧特征向量（相似检索 / 体检时写入，缓存到 `system_analysis.feature`）。
    @Published var systemFeatures: [UUID: Data] = [:]
    /// 本次运行中用户是否主动开启过系统图库内容识别。
    /// 只有开启过才在新照片出现时自动续跑；打开图库不会默认扫描场景。
    /// 该状态会按系统图库路径持久化，关库 / 切库回来能接着识别。
    var systemAnalysisAutoResume = false
    /// 正在把落库的识别结果读回内存；识别任务开始前会先等它完成。
    var systemAnalysisHydration: Task<Void, Never>?
    @Published var isAnalyzingSystemContent = false
    @Published var systemAnalysisDone = 0
    @Published var systemAnalysisTotal = 0
    /// 「查找相似照片」的临时范围；导航到其它范围时清空。
    @Published var similarScope: SimilarityScope?
    /// 图库体检结果（模糊照片、相似连拍、大视频）。本地结果写这里；网盘结果在 `CloudBrowserModel.healthReport`。
    @Published var healthReport: LibraryHealthReport?
    /// 体检结果来源："system" 表示系统图库，nil 表示本地图库。
    var healthReportScopeTag: String?
    @Published var isScanningHealth = false
    /// 暂停后正在补齐相似连拍与落盘的短暂时段。
    @Published var isFinalizingHealth = false
    @Published var healthScanProgress = 0.0
    /// 智能美化扫描结果与批量应用进度；推荐结果按范围写入 `derived_reports`，系统图库 / 网盘默认另存副本到本地图库。
    @Published var beautyReport: BeautyReport?
    /// 当前美化推荐是否来自系统图库（与本地 / 网盘结果互不通用）。
    var beautyReportIsSystem = false
    @Published var isScanningBeauty = false
    @Published var beautyScanProgress = 0.0
    @Published var isApplyingBeauty = false
    @Published var beautyApplyProgress = 0.0
    @Published var showBeautyPanel = false
    @Published var isLoadingSystemLibrary = false
    /// 系统图库扫描进度（已读取的资源数）。
    @Published var systemScanCount = 0
    /// 系统图库中的项目总数。
    @Published var systemTotalAssetCount = 0
    @Published var systemLibraryError: String?

    // MARK: 影院刮削
    /// 各作用域（本地图库 / 每个网盘）的刮削结果，按视频 photoID 索引。
    @Published var cinemaIndexes: [CinemaScope: [UUID: CinemaEntry]] = [:]
    /// 当前正在查看的影院作用域。
    @Published var cinemaActiveScope: CinemaScope = .local
    /// 影院顶栏的分段（全部 / 电影 / 电视剧），与内容页共用。
    @Published var cinemaTab: CinemaTab = .all
    /// 影院的年代筛选（如 2020 表示 2020 年代），nil 表示全部。
    @Published var cinemaDecade: Int?
    /// 影院的类型筛选（剧情 / 科幻 / 悬疑……），nil 表示全部。
    @Published var cinemaGenre: String?
    /// 正在刮削的作用域，用于对应网盘的侧边栏显示进度。
    @Published var cinemaScrapeScope: CinemaScope?
    @Published var cinemaScrapeRunning = false
    @Published var cinemaScrapeDone = 0
    @Published var cinemaScrapeTotal = 0
    @Published var cinemaScrapeMessage: String?
    /// 设置面板里「测试连接」的运行状态与结果。
    @Published var cinemaConnectionTesting = false
    @Published var cinemaConnectionResult: CinemaConnectionResult?
    /// 从影院打开的视频快照：即使该网盘目录没有加载，也能直接进查看器播放。
    var cinemaPlaybackPhoto: PhotoItem?

    /// 网盘状态独立成模型；这里保留同名转发，Store 扩展方法无需改动。
    let cloudModel = CloudBrowserModel()
    var cloudMounts: [CloudMount] {
        get { cloudModel.mounts }
        set { cloudModel.mounts = newValue }
    }
    var cloudFolders: [CloudEntry] {
        get { cloudModel.folders }
        set { cloudModel.folders = newValue }
    }
    var cloudPhotos: [PhotoItem] {
        get { cloudModel.photos }
        set { cloudModel.photos = newValue }
    }
    var cloudPath: String {
        get { cloudModel.path }
        set { cloudModel.path = newValue }
    }
    var cloudTrail: [CloudCrumb] {
        get { cloudModel.trail }
        set { cloudModel.trail = newValue }
    }
    var cloudLoading: Bool {
        get { cloudModel.loading }
        set { cloudModel.loading = newValue }
    }
    var cloudError: String? {
        get { cloudModel.error }
        set { cloudModel.error = newValue }
    }
    var showCloudSheet: Bool {
        get { cloudModel.showSheet }
        set { cloudModel.showSheet = newValue }
    }
    var cloudSheetMount: CloudMount? {
        get { cloudModel.sheetMount }
        set { cloudModel.sheetMount = newValue }
    }
    var showCloudWizard: Bool {
        get { cloudModel.showWizard }
        set { cloudModel.showWizard = newValue }
    }
    var cloudWizardInitialFlow: CloudWizardFlow? {
        get { cloudModel.wizardInitialFlow }
        set { cloudModel.wizardInitialFlow = newValue }
    }
    var cloudNameRequest: CloudNameRequest? {
        get { cloudModel.nameRequest }
        set { cloudModel.nameRequest = newValue }
    }
    var cloudBusyText: String? {
        get { cloudModel.busyText }
        set { cloudModel.busyText = newValue }
    }

    @Published var toast: String?

    var toastTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var compressionTask: Task<Void, Never>?
    /// 打开相簿 / 文件夹后的缩略图预热任务，切换范围时取消。
    var thumbnailPrewarmTask: Task<Void, Never>?
    var compressionEstimateTask: Task<Void, Never>?
    var compressionCancelled = false
    var intelligenceTask: Task<Void, Never>?
    var intelligenceCancelled = false
    var systemAnalysisTask: Task<Void, Never>?
    var systemAnalysisCancelled = false
    var aiTask: Task<Void, Never>?
    /// 最近一次发给模型的候选照片顺序，用于解析工具参数里的「#3」这类编号。
    var aiLastCandidateIDs: [UUID] = []
    /// 候选照片的文件名到 id，解析模型直接写文件名的情况。
    var aiLastCandidateNames: [String: UUID] = [:]
    var healthTask: Task<Void, Never>?
    /// 体检任务标识：取消或重新开始后，旧任务不再写回进度与结果。
    var healthScanToken = UUID()
    var beautyTask: Task<Void, Never>?
    var sceneCountsCacheKey: String?
    var sceneCountsCache: [String: Int] = [:]
    /// 系统图库待识别数量：随照片窗口与已识别数量缓存，避免侧边栏悬停时反复遍历整库。
    var systemPendingAnalysisCacheKey: String?
    var systemPendingAnalysisCache = 0
    /// 场景总览（数量 + 封面）一次遍历缓存。
    var sceneSummaryCacheKey: String?
    var sceneSummaryCache = SceneSummary()
    /// 媒体类型总览（数量 + 封面）一次遍历缓存。
    var mediaTypeSummaryCacheKey: String?
    var mediaTypeSummaryCacheValue = MediaTypeSummary()
    /// 「更多项目」总览卡片封面（按入口缓存，内容版本变化时失效）。
    var moreItemsCoverToken: String?
    var moreItemsCoverCache: [SidebarItem: PhotoItem] = [:]
    var moreItemsCoverMissing: Set<SidebarItem> = []
    /// 关键词卡片墙的封面（按关键词缓存，内容版本变化时失效）。
    var keywordCoverToken: String?
    var keywordCoverCache: [String: PhotoItem] = [:]
    var keywordCoverMissing: Set<String> = []
    /// 重复项目分组一次遍历缓存（按内容版本失效）。
    var duplicateGroupsCacheKey: String?
    var duplicateGroupsCache: [DuplicateGroup] = []
    /// 查重 2.0：相似照片组与哈希扫描状态。
    @Published var similarPhotoGroups: [SimilarPhotoGroup] = []
    @Published var isScanningHashes = false
    @Published var hashScanCompleted = 0
    @Published var hashScanTotal = 0
    var hashScanTask: Task<Void, Never>?
    var hashScanToken = UUID()
    /// 系统图库重复项目分组（首次打开重复页时在后台计算，结果按内容版本缓存）。
    @Published var systemDuplicateGroupsCache: [DuplicateGroup] = []
    /// 重复分组失效计数：界面用 `.task(id:)` 监听，变化后重新触发后台计算。
    @Published var systemDuplicateGroupsToken = 0
    @Published var isLoadingSystemDuplicates = false
    var systemDuplicateGroupsCacheKey: String?
    var systemDuplicateGroupsTask: Task<Void, Never>?
    var metadataStore: MetadataStore?
    var systemPhotoIndex: [UUID: PhotoItem] = [:]
    /// 已完成扫描的系统图库路径；再次点击同一个图库时只切换页面，不重复扫描。
    var systemLibraryLoadedPath: String?
    /// 系统图库载入令牌：每次载入递增，旧扫描的结果不再写回状态与缓存。
    var systemLoadToken = 0
    var terminateObserver: NSObjectProtocol?

    var cloudDirectoryCache: [String: (folders: [CloudEntry], photos: [PhotoItem])] = [:]
    var cloudLoadToken = 0

    /// 云照片的本地收藏（"mountID|path"），只记录在拾光本地，不写回网盘。
    @Published var cloudFavorites: Set<String> = []
    /// 云照片的本地关键词（"mountID|path" → 标签数组），只记录在拾光本地，不写回网盘。
    @Published var cloudKeywords: [String: [String]] = [:]
    var cloudVisibleCacheKey: String?
    var cloudVisibleCacheValue: [PhotoItem] = []
    /// 网盘分类计数与场景计数缓存（键含目录版本与识别进度）。
    var cloudScopeCountsCacheKey: String?
    var cloudScopeCountsCache = CloudScopeCounts()
    /// 网盘「相簿」文件夹树与选中目录的子目录集合缓存。
    var cloudFolderTreeCacheKey: String?
    var cloudFolderTreeCacheValue: [CloudFolderNode] = []
    var cloudFolderDescendantCacheKey: String?
    var cloudFolderDescendantCacheValue: Set<String> = []

    var placeCache: [String: PlaceInfo] = [:]
    var placeCacheLoaded = false
    /// 本次会话里逆地理编码失败的查询格：系统会限流，失败后不再反复请求，避免空转。
    var placeResolveFailedKeys: Set<String> = []
    /// 地图页的派生数据：带定位的照片与地点聚类按内容版本缓存，
    /// 避免一次打开地图时在每次 body 求值里重扫整库。
    var geoPhotosCacheKey = -1
    var geoPhotosCacheValue: [PhotoItem] = []
    var placeClustersCacheKey = -1
    var placeClustersCacheValue: [PlaceCluster] = []
    var placeGroupsCacheKey = -1
    var placeGroupsCacheValue: [(title: String, clusters: [PlaceCluster])] = []

    /// 图库级撤销 / 重做栈（仅内存，不落盘）：只保存元数据变更的逆操作。
    var undoStack: [LibraryUndoStep] = []
    var redoStack: [LibraryUndoStep] = []
    /// 菜单标题用的最近一步操作名（随撤销 / 重做更新）。
    @Published var undoActionName: String?
    @Published var redoActionName: String?

    /// 图库内容版本号：数组变更时自增，用于缓存筛选/排序结果。
    var contentRevision = 0
    var visibleCacheKey: String?
    var visibleCacheValue: [PhotoItem] = []
    var sectionsCacheKey: String?
    var sectionsCacheValue: [PhotoSection] = []
    /// 网格滚动时按 id 查拍摄时间；随可见集合指纹缓存，避免每帧遍历全库。
    var dateLookupCacheKey: String?
    var dateLookupCache: [UUID: Date] = [:]
    /// 系统图库侧边栏子项（文件夹 + 相簿混排），按结构版本一次性分组。
    var systemChildrenCacheRevision = -1
    var systemChildrenBuckets: [Int64: [SystemSidebarEntry]] = [:]

    // MARK: - 大图库分页窗口
    //
    // 本地图库超过阈值时，筛选/排序/分段交给 SQLite，Store 只保留当前加载的窗口。
    @Published var windowPhotos: [PhotoItem] = []
    @Published var windowTotal = 0
    @Published var windowVideos = 0
    @Published var isWindowLoading = false
    /// 当前查询的第一页是否已经拿到，用来区分「正在加载」与「确实为空」。
    @Published var hasLoadedWindow = false
    /// 查看器胶片条使用当前照片附近的一小段照片，避免为翻页载入整段窗口。
    @Published var viewerStrip: [PhotoItem] = []
    /// 查看器的外部列表（地图 / 地点 / 卡片墙等非图库网格）：
    /// 非空时序号、总数与左右翻页都以它为准，而不是图库分页窗口。
    var viewerContextPhotos: [PhotoItem] = []
    var windowKeyValue = ""
    var windowQueryKey = ""
    var windowQuery: PhotoQuery?
    var windowStartOffset = 0
    /// 窗口内容变化计数，参与 `visibleStateKey` 让分段缓存失效。
    var windowRevision = 0
    var windowTask: Task<Void, Never>?
    var viewerStripKey: String?
    var viewerStripTask: Task<Void, Never>?

    // 年 / 月总览也走 SQL 分区：只保留每月/每天最多 4 张样本与真实总数。
    @Published var yearBuckets: [PhotoPeriodBucket] = []
    @Published var monthGroups: [PhotoMonthGroup] = []
    @Published var isOverviewLoading = false
    var overviewKeyValue = ""
    var overviewTask: Task<Void, Never>?
    var pendingMonthScrollYear: Int?

    static let windowPageSize = 600
    /// 超过这个数量才启用窗口化：小图库继续走内存路径，行为完全不变。
    static let windowThreshold = 5_000

    // MARK: - 系统图库索引窗口
    //
    // 系统图库超过阈值时不再把整库 `[PhotoItem]` 装进内存：
    // `SystemIndex` 提供 SQL 分页与聚合计数，这里只保留已加载的窗口。
    var systemIndex: SystemIndex?
    /// 索引指纹（路径 + 收录数）：参与分页 key，重建索引后窗口自动刷新。
    var systemIndexSignature = ""
    /// 官方「照片」图库自带的关键词（`Photos.sqlite` 的 `ZKEYWORD`），按关键词汇总资产 ID。
    /// 系统图库载入时读一次；nil 表示尚未读取。
    var systemNativeKeywordIndex: [String: [UUID]]?
    /// 上一条的反查表（资产 ID → 关键词），用于图片信息面板与关键词筛选。
    var systemNativeKeywordIDMap: [UUID: [String]] = [:]
    /// 长曝光 / 电影效果只能由 PhotoKit 智能相簿给出 ID；nil 表示尚未读取或没有照片权限。
    @Published var photoKitLongExposureIDs: Set<UUID>?
    @Published var photoKitCinematicIDs: Set<UUID>?
    var isPhotoKitMediaTypeLoaded = false
    @Published var systemIndexReady = false
    @Published var systemWindowPhotos: [PhotoItem] = []
    @Published var systemWindowTotal = 0
    @Published var systemWindowVideos = 0
    @Published var isSystemWindowLoading = false
    @Published var hasLoadedSystemWindow = false
    var systemWindowKey = ""
    var systemWindowStart = 0
    /// 时间轴窗口在整库里的起始排名（0 = 最新一张）。滚动条进入虚拟占位区时整体重定位窗口。
    @Published var systemWindowStartRank = 0
    /// 时间轴换页后要滚到视野中心的那张照片（只用于换页落地，不参与用户主动定位）。
    @Published var timelineJumpLandingID: UUID?
    var systemWindowQuery: SystemQuery?
    var systemWindowTask: Task<Void, Never>?
    /// 窗口内容变化计数，参与 `visibleStateKey` 让分段缓存失效。
    var systemWindowRevision = 0
    /// 地图 / 足迹回放用的带位置照片缓存（索引模式下取全量）。
    var systemGeoCacheKey: String?
    var systemGeoCache: [PhotoItem] = []
    /// 系统索引查询按范围和输入条件缓存：SwiftUI body 会频繁读取
    /// `systemQuery` / `pagedKey` / `visibleCount`，每次重算会让主线程持续满载。
    var systemQueryCacheSignature: String?
    var systemQueryCache: [String: SystemQuery] = [:]
    /// `SystemQuery.key` 在收藏 / 隐藏叠加很多时会拼出很长的字符串，
    /// 而 `pagedKey` 又在 SwiftUI body 里被反复读取：构建一次后按范围复用。
    var systemQueryKeyCache: [String: String] = [:]
    /// 侧边栏相簿封面：异步查询结果按相簿缓存，body 不再逐行同步查库。
    var systemAlbumCoverCache: [Int64: PhotoItem] = [:]
    var systemAlbumCoverMisses: Set<Int64> = []
    var systemAlbumCoverLoading: Set<Int64> = []

    var viewerPhotoCache: ViewerPhotoCache?
    var viewerIndexCache: ViewerIndexCache?
    /// 查看器「当前 / 总数」的兜底结果缓存：任何入口打开都要能立即给出数字。
    var viewerPositionCache: ViewerPositionCache?

    struct ViewerPhotoCache {
        let id: UUID
        let revision: Int
        let photo: PhotoItem?
    }

    /// 查看器在当前可见列表中的位置缓存，供连翻时 O(1) 定位。
    struct ViewerIndexCache {
        let key: String
        let id: UUID
        let index: Int
    }

    /// 查看器「当前 / 总数」的兜底缓存：主路径算不出序号时避免每次渲染重复扫描列表。
    struct ViewerPositionCache {
        let key: String
        let id: UUID
        let index: Int
        let total: Int
    }

    /// 待确认的删除操作：`trash` 可撤销，`permanent` / `emptyTrash` 不可撤销。
    struct DeleteRequest: Identifiable, Equatable {
        enum Kind: Equatable {
            case trash
            case permanent
            case emptyTrash
        }

        let id = UUID()
        let ids: Set<UUID>
        let kind: Kind

        var isIrreversible: Bool {
            kind != .trash
        }
    }

    /// 待确认的断开操作：系统图库连接或网络存储挂载。
    struct DisconnectRequest: Identifiable, Equatable {
        enum Target: Equatable {
            case systemLibrary(path: String, name: String)
            case cloudMount(id: UUID, name: String, kind: CloudKind)
        }

        let id = UUID()
        let target: Target
    }

    /// 是否有任何确认卡片打开（键盘与菜单要避让）。
    var hasPendingConfirmation: Bool {
        pendingDeletion != nil || pendingDisconnect != nil
    }
    var memoryCacheKey = -1
    var memoryCacheValue: [PhotoMemory] = []
    var tripCacheKey = -1
    var tripCacheValue: [TripStory] = []
    var faceClusterTask: Task<Void, Never>?
    var scannedFaceIDs: Set<UUID> = []
    var faceDataLoaded = false
    /// 人脸聚类的运行标识：重新识别时换新标识，旧任务的收尾写回会被丢弃。
    var faceClusterToken = UUID()
    /// 尚未识别的照片数（增量识别入口显示剩余量），按内容版本缓存，避免反复遍历整库。
    var facePendingCacheKey = ""
    var facePendingCacheValue = 0

    init() {
        LibraryPaths.configure()
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        needsLibrarySetup = LibraryPaths.requiresLibrarySetup
        // 与系统「照片」一致：按住 Option 启动时先弹出图库选择器。
        // NSEvent.modifierFlags 只反映“当前事件”的标志，启动早期 App 可能还没处理过
        // 任何事件而读不到；再读一次全局组合会话的按键状态兜底。
        let optionHeldAtLaunch = NSEvent.modifierFlags.contains(.option)
            || CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        let startsWithLibraryPicker = optionHeldAtLaunch
        libraryPickerOnLaunch = startsWithLibraryPicker && !needsLibrarySetup

        // 没有图库时不创建任何元数据库；只有旧版本地库残留时才读取它，便于迁入新图库。
        if !needsLibrarySetup || LibraryPaths.hasLocalLibraryData {
            if let store = try? MetadataStore(url: LibraryPaths.metadataFile) {
                metadataStore = store
                let data = store.loadLibrary()
                photos = data.photos
                albums = data.albums
                folders = data.folders
                systemLibraryPath = store.setting("system_library_path")
                // 后台枚举一次本地缩略图目录：网格滚动时不用逐格 stat。
                ThumbnailFileIndex.shared.warm(root: LibraryPaths.derivatives)
            } else {
                loadLegacyJSON()
            }
        }

        // 图库级设置（导入选项、最近删除、系统图库上限、元数据显示）随图库保存：
        // 先接上当前图库的设置表，再把旧版全局设置一次性迁入，最后灌回 AppSettings。
        attachLibrarySettingsPersistence()
        migrateLegacySettingsIntoCurrentLibraryIfNeeded()
        AppSettings.shared.reloadLibraryScopedValues()

        if !needsLibrarySetup, let path = systemLibraryPath {
            // 默认不扫描系统图库：只记住名称用于侧边栏展示，用户点开系统图库时再按需加载。
            systemLibraryName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        loadSystemLibraries()

        // QA 钩子：在没有任何本地模型的机器上验证「打开开关 → 自动下载 → 编译 → 安装」整条链路。
        // 正常启动不会触发，只有显式设置环境变量时才执行。
        if ProcessInfo.processInfo.environment["LUMA_AUTO_INSTALL_SIGLIP2"] == "1" {
            ModelInstaller.shared.install(.siglip2)
        }

        purgeExpiredTrashIfNeeded()

        loadCloudMounts()
        loadCloudFavorites()
        loadCloudKeywords()
        loadCinemaIndexes()
        migrateLegacyCinemaIndexIfNeeded()
        loadSmartAlbums()
        loadPinnedItems()
        loadAnalysisIndex()
        loadViewPreferences()
        loadAIState()

        // 当前图库就是官方「照片」图库时，主界面默认展示这个图库的照片；
        // 拾光自己的数据（导入、相簿、收藏）写在该图库第一层 database/ 里，从「拾光」分区进入。
        // 启动时弹出的图库选择器：先不打开任何图库，等用户选定后再进入。
        if !needsLibrarySetup,
           !startsWithLibraryPicker,
           let container = LibraryPaths.containerLibraryURL,
           LibraryPaths.isNativeLibrary(container) {
            systemLibraryPath = container.path
            systemLibraryName = container.deletingPathExtension().lastPathComponent
            metadataStore?.setSetting("system_library_path", container.path)
            sidebarItem = .systemLibrary
        }

        if !startsWithLibraryPicker, let container = LibraryPaths.containerLibraryURL {
            rememberLibrary(container)
        }
        // 与系统「照片」一致：按住 Option 启动时先弹出图库选择器。
        showLibraryPicker = startsWithLibraryPicker

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushMetadata()
            }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    func flushMetadata() {
        metadataStore?.flush()
    }

    // MARK: - Persistence

    func loadLegacyJSON() {
        guard let data = try? Data(contentsOf: LibraryPaths.libraryFile),
              let decoded = try? JSONDecoder().decode(LibraryData.self, from: data) else {
            return
        }
        photos = decoded.photos.filter { FileManager.default.fileExists(atPath: LibraryPaths.sourceURL(for: $0).path) }
        albums = decoded.albums
        folders = decoded.folders
    }

    func save() {
        // 元数据只能写进当前图库的 SQLite；没有 MetadataStore（没有图库）时不落盘，
        // 避免在 Application Support 里写出会被下一个打开的图库误迁入的 Library.json。
        guard let metadataStore else { return }
        LibraryPaths.prepare()
        let data = LibraryData(photos: photos, albums: albums, folders: folders)
        metadataStore.save(data)
    }

    /// 导入过程中增量写入新照片，避免每批都全量重写 assets；没有 SQLite 时退回整体保存。
    func persistImported(_ items: [PhotoItem]) {
        if let metadataStore {
            metadataStore.appendPhotos(items)
        } else {
            save()
        }
    }

    /// 视图状态（分组、排序、缩略图大小与形式）随当前图库保存，切换图库时一起切换。
    func loadViewPreferences() {
        var groupingValue: GridGrouping = .all
        var favoritesViewModeValue: FavoritesViewMode = .years
        var aspectValue: ThumbnailAspect = .square
        var albumStyleValue: AlbumDisplayStyle = .grid
        var sortValue: SortKey = .capturedAt
        var ascendingValue: Bool?
        var placeGranularityValue: PlaceGranularity = .street
        var peopleFilterValue: PeopleGroupFilter = .all
        var peopleStyleValue: PeopleDisplayStyle = .circle
        var organizeDimensionValue: OrganizeDimension = .rating
        var sizeValue = defaultGridThumbSize
        var thumbSizesValue: [String: Double] = [:]
        var cardColumnsValue = Self.defaultCardColumnsValue
        var cardColumnsMap: [String: Int] = [:]

        if let store = metadataStore {
            if let raw = store.setting(SettingsKeys.grouping),
               let value = GridGrouping(rawValue: raw) {
                groupingValue = value
            }
            if let raw = store.setting(SettingsKeys.favoritesViewMode),
               let value = FavoritesViewMode(rawValue: raw) {
                favoritesViewModeValue = value
            }
            if let raw = store.setting(SettingsKeys.thumbnailAspect),
               let value = ThumbnailAspect(rawValue: raw) {
                aspectValue = value
            }
            if let raw = store.setting(SettingsKeys.albumDisplayStyle),
               let value = AlbumDisplayStyle(rawValue: raw) {
                albumStyleValue = value
            }
            if let raw = store.setting(SettingsKeys.sortKey),
               let value = SortKey(rawValue: raw) {
                sortValue = value
            }
            if let raw = store.setting(SettingsKeys.sortAscending) {
                ascendingValue = raw == "1" || raw.lowercased() == "true"
            }
            if let raw = store.setting(SettingsKeys.placeGranularity),
               let value = PlaceGranularity(rawValue: raw) {
                placeGranularityValue = value
            }
            if let raw = store.setting(SettingsKeys.peopleFilter),
               let value = PeopleGroupFilter(rawValue: raw) {
                peopleFilterValue = value
            }
            if let raw = store.setting(SettingsKeys.peopleDisplayStyle),
               let value = PeopleDisplayStyle(rawValue: raw) {
                peopleStyleValue = value
            }
            if let raw = store.setting(SettingsKeys.organizeDimension),
               let value = OrganizeDimension(rawValue: raw) {
                organizeDimensionValue = value
            }
            if let raw = store.setting(SettingsKeys.thumbSize), let size = Double(raw) {
                sizeValue = min(Self.thumbSizeRange.upperBound,
                                max(Self.thumbSizeRange.lowerBound, size))
            }
            if let raw = store.setting(SettingsKeys.thumbSizes),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
                thumbSizesValue = decoded
            }
            if let raw = store.setting(SettingsKeys.cardColumns),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
                cardColumnsMap = decoded
            }
            // 从「按 pt 调大小」升级到「按每行张数」：每个图库清一次页面记忆，
            // 让所有页面先回到新的默认密度（图片列表 8 张、卡片墙 5 个）。
            if store.setting(SettingsKeys.gridColumnsMigration) != "1" {
                store.setSetting(SettingsKeys.gridColumnsMigration, "1")
                thumbSizesValue = [:]
                cardColumnsMap = [:]
                sizeValue = defaultGridThumbSize
                cardColumnsValue = Self.defaultCardColumnsValue
                pendingDensityReconcile = true
            }
        }

        grouping = groupingValue
        favoritesViewMode = favoritesViewModeValue
        // 切换图库时旧汇总立即失效，进入收藏页会按新图库重新载入。
        favoritesDigest = nil
        favoritesDigestSource = []
        favoritesDigestLoadedToken = ""
        selectedFavoriteBucket = nil
        thumbnailAspect = aspectValue
        albumDisplayStyle = albumStyleValue
        sortKey = sortValue
        sortAscending = ascendingValue ?? sortValue.prefersAscending
        placeGranularity = placeGranularityValue
        peopleFilter = peopleFilterValue
        peopleDisplayStyle = peopleStyleValue
        organizeDimension = organizeDimensionValue
        thumbSizes = thumbSizesValue
        cardColumnsByScope = cardColumnsMap
        // 恢复当前侧边栏页面自己的滑杆位置；没记录过则沿用图库默认尺寸。
        let currentScope = thumbSizeScopeKey(for: sidebarItem)
        thumbSize = thumbSizesValue[currentScope] ?? sizeValue
        if thumbSizes[currentScope] == nil {
            thumbSizes[currentScope] = thumbSize
        }
        cardColumns = cardColumnsMap[currentScope] ?? cardColumnsValue
        if cardColumnsByScope[currentScope] == nil {
            cardColumnsByScope[currentScope] = cardColumns
        }
    }

    /// 把当前图库的设置表接入 AppSettings；闭包动态读取 `metadataStore`，切换图库后自动指向新库。
    func attachLibrarySettingsPersistence() {
        let app = AppSettings.shared
        app.libraryReader = { [weak self] key in self?.metadataStore?.setting(key) }
        app.libraryWriter = { [weak self] key, value in self?.metadataStore?.setSetting(key, value) }
    }

    /// 旧版把图库级设置存在全局 UserDefaults：升级后一次性迁入当前图库；
    /// 之后新建的图库不再继承，使用各自的默认值。
    func migrateLegacySettingsIntoCurrentLibraryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKeys.libraryScopeMigrationDone) else { return }
        defer { defaults.set(true, forKey: SettingsKeys.libraryScopeMigrationDone) }
        guard let store = metadataStore else { return }

        let keys = [SettingsKeys.importCreateAlbums, SettingsKeys.importPreserveStructure,
                    SettingsKeys.trashRetentionDays,
                    SettingsKeys.grouping, SettingsKeys.thumbnailAspect,
                    SettingsKeys.sortKey, SettingsKeys.sortAscending, SettingsKeys.thumbSize]
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let bool = value as? Bool {
                store.setSetting(key, bool ? "1" : "0")
            } else if let number = value as? NSNumber {
                store.setSetting(key, number.stringValue)
            } else if let string = value as? String {
                store.setSetting(key, string)
            }
        }
        if let data = defaults.data(forKey: SettingsKeys.metadata),
           let json = String(data: data, encoding: .utf8) {
            store.setSetting(SettingsKeys.metadata, json)
        }
        if let favorites = defaults.stringArray(forKey: Self.cloudFavoritesDefaultsKey),
           let data = try? JSONEncoder().encode(favorites),
           let json = String(data: data, encoding: .utf8) {
            store.setSetting(Self.cloudFavoritesSettingKey, json)
        }
    }

    /// 图库级设置的落盘入口：只写当前图库，不再污染全局 UserDefaults。
    private func persistViewPreference(_ key: String, _ value: String) {
        metadataStore?.setSetting(key, value)
    }
}
