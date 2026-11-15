import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

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
            loadSystemLibraryIfNeeded(sidebarItem)
        }
    }
    @Published var grouping: GridGrouping = .all {
        didSet { persistViewPreference(SettingsKeys.grouping, grouping.rawValue) }
    }
    /// 缩略图 / 卡片尺寸范围（pt）：滑杆、按钮、⌘+ / ⌘-、捏合都按这个范围夹紧。
    static let thumbSizeRange: ClosedRange<Double> = 56...360

    @Published var thumbSize: Double = 132 {
        didSet {
            let clamped = min(Self.thumbSizeRange.upperBound,
                              max(Self.thumbSizeRange.lowerBound, thumbSize))
            if clamped != thumbSize {
                thumbSize = clamped
                return
            }
            persistViewPreference(SettingsKeys.thumbSize, String(thumbSize))
        }
    }
    @Published var thumbnailAspect: ThumbnailAspect = .square {
        didSet { persistViewPreference(SettingsKeys.thumbnailAspect, thumbnailAspect.rawValue) }
    }
    @Published var photoFilter: PhotoFilter = .all
    @Published var keywordFilter: String?
    /// 「位置」页里进入的单个地点。
    @Published var selectedPlace: PlaceCluster?
    @Published var isResolvingPlaces = false
    @Published var placeResolveDone = 0
    @Published var placeResolveTotal = 0
    @Published var sortKey: SortKey = .capturedAt {
        didSet { persistViewPreference(SettingsKeys.sortKey, sortKey.rawValue) }
    }
    /// 升序 / 降序（日期类默认降序，名称类默认升序）。
    @Published var sortAscending: Bool = false {
        didSet { persistViewPreference(SettingsKeys.sortAscending, sortAscending ? "1" : "0") }
    }
    @Published var searchText: String = ""
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

    @Published var showImportSheet = false
    @Published var showPhotoPicker = false
    @Published var importPanelOpenRequest = 0
    @Published var importCandidates: [ImportCandidate] = []
    @Published var importProgress: ImportProgress?
    @Published var isImporting = false
    @Published var importCancelled = false

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
        didSet { contentRevision &+= 1 }
    }
    @Published var systemFolders: [SystemFolderInfo] = [] {
        didSet { contentRevision &+= 1 }
    }
    @Published var systemPeople: [SystemPersonInfo] = []
    @Published var selectedPerson: SystemPersonInfo?
    /// 本地图库的端侧人物聚类结果。
    @Published var localPeople: [LocalPerson] = []
    @Published var selectedLocalPersonID: UUID?
    @Published var isClusteringFaces = false
    @Published var faceClusterProgress: FaceClusterProgress?
    /// 端侧智能分析索引（场景标签 + OCR 文字），仅本地图库。
    @Published var analysisIndex: [UUID: PhotoAnalysis] = [:]
    @Published var isAnalyzingIntelligence = false
    @Published var intelligenceDone = 0
    @Published var intelligenceTotal = 0
    /// 「查找相似照片」的临时范围；导航到其它范围时清空。
    @Published var similarScope: SimilarityScope?
    /// 图库体检结果（模糊照片、相似连拍、大视频），仅本地图库。
    @Published var healthReport: LibraryHealthReport?
    @Published var isScanningHealth = false
    @Published var healthScanProgress = 0.0
    @Published var isLoadingSystemLibrary = false
    /// 系统图库扫描进度（已读取的资源数）。
    @Published var systemScanCount = 0
    /// 系统图库中的项目总数（不受加载上限截断）；大于 `systemPhotos.count` 时表示当前只加载了最近的一部分。
    @Published var systemTotalAssetCount = 0
    /// 系统图库是否因加载上限而只显示最近的一部分。
    var systemIsTruncated: Bool { systemTotalAssetCount > systemPhotos.count }
    @Published var systemLibraryError: String?

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
    var compressionEstimateTask: Task<Void, Never>?
    var compressionCancelled = false
    var intelligenceTask: Task<Void, Never>?
    var intelligenceCancelled = false
    var aiTask: Task<Void, Never>?
    /// 最近一次发给模型的候选照片顺序，用于解析工具参数里的「#3」这类编号。
    var aiLastCandidateIDs: [UUID] = []
    /// 候选照片的文件名到 id，解析模型直接写文件名的情况。
    var aiLastCandidateNames: [String: UUID] = [:]
    var healthTask: Task<Void, Never>?
    var sceneCountsCacheKey: String?
    var sceneCountsCache: [String: Int] = [:]
    var metadataStore: MetadataStore?
    var systemPhotoIndex: [UUID: PhotoItem] = [:]
    /// 已完成扫描的系统图库路径；再次点击同一个图库时只切换页面，不重复扫描。
    var systemLibraryLoadedPath: String?
    var terminateObserver: NSObjectProtocol?

    var cloudPasswords: [UUID: String] = [:]
    var cloudDirectoryCache: [String: (folders: [CloudEntry], photos: [PhotoItem])] = [:]
    var cloudLoadToken = 0

    /// 云照片的本地收藏（"mountID|path"），只记录在拾光本地，不写回网盘。
    @Published var cloudFavorites: Set<String> = []
    var cloudVisibleCacheKey: String?
    var cloudVisibleCacheValue: [PhotoItem] = []

    var placeCache: [String: PlaceInfo] = [:]
    var placeCacheLoaded = false
    var placeResolveAttempted = false

    /// 图库内容版本号：数组变更时自增，用于缓存筛选/排序结果。
    var contentRevision = 0
    var visibleCacheKey: String?
    var visibleCacheValue: [PhotoItem] = []
    var sectionsCacheKey: String?
    var sectionsCacheValue: [PhotoSection] = []
    /// 系统图库侧边栏子项（文件夹 + 相簿混排），按 contentRevision 一次性分组。
    var systemChildrenCacheRevision = -1
    var systemChildrenBuckets: [Int64: [SystemSidebarEntry]] = [:]
    /// 系统图库有效项目数（侧边栏徽标），按 contentRevision 失效。
    var systemActiveCountCacheRevision = -1
    var systemActiveCountCacheValue = 0

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

    var viewerPhotoCache: ViewerPhotoCache?
    var viewerIndexCache: ViewerIndexCache?

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
    var memoryCacheKey = -1
    var memoryCacheValue: [PhotoMemory] = []
    var tripCacheKey = -1
    var tripCacheValue: [TripStory] = []
    var faceClusterTask: Task<Void, Never>?
    var scannedFaceIDs: Set<UUID> = []
    var faceDataLoaded = false

    init() {
        LibraryPaths.configure()
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        needsLibrarySetup = LibraryPaths.requiresLibrarySetup

        // 没有图库时不创建任何元数据库；只有旧版本地库残留时才读取它，便于迁入新图库。
        if !needsLibrarySetup || LibraryPaths.hasLocalLibraryData {
            if let store = try? MetadataStore(url: LibraryPaths.metadataFile) {
                metadataStore = store
                let data = store.loadLibrary()
                photos = data.photos
                albums = data.albums
                folders = data.folders
                systemLibraryPath = store.setting("system_library_path")
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

        purgeExpiredTrashIfNeeded()

        loadCloudMounts()
        remountSMBMountsOnLaunch()
        loadCloudFavorites()
        loadSmartAlbums()
        loadPinnedItems()
        loadAnalysisIndex()
        loadViewPreferences()
        loadAIState()

        // 当前图库就是官方「照片」图库时，主界面默认展示这个图库的照片；
        // 拾光自己的数据（导入、相簿、收藏）写在该图库第一层 database/ 里，从「拾光」分区进入。
        if !needsLibrarySetup,
           let container = LibraryPaths.containerLibraryURL,
           LibraryPaths.isNativeLibrary(container) {
            systemLibraryPath = container.path
            systemLibraryName = container.deletingPathExtension().lastPathComponent
            metadataStore?.setSetting("system_library_path", container.path)
            sidebarItem = .systemLibrary
        }

        if let container = LibraryPaths.containerLibraryURL {
            rememberLibrary(container)
        }
        // 与系统「照片」一致：按住 Option 启动时先弹出图库选择器。
        showLibraryPicker = NSEvent.modifierFlags.contains(.option)

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
        var aspectValue: ThumbnailAspect = .square
        var sortValue: SortKey = .capturedAt
        var ascendingValue: Bool?
        var sizeValue = 132.0

        if let store = metadataStore {
            if let raw = store.setting(SettingsKeys.grouping),
               let value = GridGrouping(rawValue: raw) {
                groupingValue = value
            }
            if let raw = store.setting(SettingsKeys.thumbnailAspect),
               let value = ThumbnailAspect(rawValue: raw) {
                aspectValue = value
            }
            if let raw = store.setting(SettingsKeys.sortKey),
               let value = SortKey(rawValue: raw) {
                sortValue = value
            }
            if let raw = store.setting(SettingsKeys.sortAscending) {
                ascendingValue = raw == "1" || raw.lowercased() == "true"
            }
            if let raw = store.setting(SettingsKeys.thumbSize), let size = Double(raw) {
                sizeValue = min(Self.thumbSizeRange.upperBound,
                                max(Self.thumbSizeRange.lowerBound, size))
            }
        }

        grouping = groupingValue
        thumbnailAspect = aspectValue
        sortKey = sortValue
        sortAscending = ascendingValue ?? sortValue.prefersAscending
        thumbSize = sizeValue
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
                    SettingsKeys.trashRetentionDays, SettingsKeys.systemLibraryMaxAssets,
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
