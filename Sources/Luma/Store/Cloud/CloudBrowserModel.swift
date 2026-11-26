import Observation
import Foundation
import LumaContentCore

/// 网盘浏览状态：挂载列表、当前目录、加载与弹窗状态。
/// 由 `LibraryStore` 持有并转发变更，后续可按需让网盘视图单独订阅。
@Observable
final class CloudBrowserModel {
    /// 网盘侧后台任务登记处：扫描、元数据、识别、人物、体检都走这里。
    let tasks = StoreTaskCenter()

    /// 网络存储总览的分页：总览 / 存储 / 影院 / 续播 / 管理。
    /// 与「网络资源」一致，切换入口在窗口工具栏里；选择结果跨会话保留。
    var storagesTab: CloudStoragesHubTab = CloudStoragesHubTab.persisted

    var mounts: [CloudMount] = []

    /// 每个挂载最近一次连通性检测结果：只存在内存，重启后重新检测。
    /// 总览卡片徽章与侧边栏「后台任务」共用这份状态。
    var mountHealth: [UUID: SourceHealth] = [:]

    /// 切换总览分页并记住选择：下次打开仍停在上次看的那一页。
    func setStoragesTab(_ tab: CloudStoragesHubTab) {
        guard storagesTab != tab else { return }
        storagesTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: CloudStoragesHubTab.storageKey)
    }

    var folders: [CloudEntry] = []
    var photos: [PhotoItem] = [] {
        didSet { revision &+= 1 }
    }
    /// 照片集合版本号：目录刷新、收藏切换等变化时自增，用于云网格筛选缓存失效。
    var revision = 0
    var path: String = ""
    var trail: [CloudCrumb] = []
    var loading = false
    var error: String?
    /// 当前错误需要重新授权（令牌失效 / 钥匙串拒绝访问）时置位，界面据此给出「重新登录」入口。
    var needsCloudReauth = false
    var showSheet = false
    var sheetMount: CloudMount?
    /// Cookie / 令牌失效后的原地重新登录：只替换这个挂载的凭据，不新建挂载。
    var reauthMount: CloudMount?
    var showWizard = false
    var wizardInitialFlow: CloudWizardFlow?
    /// 从「编辑接入范围」进入时携带的挂载 ID：向导直接跳到确认页并带入已有凭据。
    var wizardEditingMountID: UUID?
    var nameRequest: CloudNameRequest?
    var busyText: String?

    // MARK: 浏览范围与端侧识别

    /// 当前网盘列表的范围（全部 / 视频 / 截屏 / 场景 / 包含文字…）。
    var scope: CloudScope = .all
    /// 网盘的分区总览（媒体类型 / 更多项目 / 场景 / 相簿）；非空时右侧显示卡片墙而不是照片网格。
    var overview: CloudOverviewSection?
    /// 当前选中的文件夹相簿（nil = 整个网盘）。
    var selectedFolderPath: String?
    /// 全盘扫描状态与进度。
    var scanPhase: CloudScanPhase = .idle
    var scanFolderCount = 0
    var scanMediaCount = 0
    var scanTruncated = false
    /// 本轮扫描开始时间：状态条据此显示已用时间与预估剩余。
    var scanStartedAt: Date?
    /// 扫描开始前已有的媒体数：本次摘要用它算「已存在 / 新增」。
    var scanBaselineMediaCount = 0
    /// 全盘扫描得到的媒体清单与目录清单（与当前列表分开，切换相簿时直接复用）。
    var scanPhotos: [PhotoItem] = []
    /// 目录清单不参与逐条发布：扫描时目录可能上千个，逐批 publish 会让整棵侧边栏反复重建。
    /// 界面只订阅节流后的 `scanFolderCount` / `scanMediaCount`。
    var scanFolders: [CloudScanFolder] = []
    /// 媒体路径 → 所在目录；按文件夹相簿筛选时用。
    var scanMediaFolder: [String: String] = [:]
    /// 扫描增量去重集合：避免每批都重建整份路径集合（两万项时是 O(n²)）。
    var scanPhotoPaths: Set<String> = []
    var scanFolderPaths: Set<String> = []
    var scanMountID: UUID?
    /// 统一任务中心里的扫描任务 ID；用于进度上报与取消。
    var scanJobID: UUID?
    var pendingScanFolderCount = 0
    var lastPublishedScanMediaCount = -1
    /// 已写入 SQLite 索引的目录数量：每批只补写新增目录。
    var scanIndexPersistedFolderCount = 0
    /// 本轮扫描代次：完整扫描结束后据此清理索引里的旧行。
    var scanGeneration: Int64 = 0
    /// 本轮是否是全量 / 深度扫描（没有复用任何子树）。
    var scanIsDeep = false
    /// 网盘索引批次完成计数：聚合表重算后自增，让文件夹树重新读取。
    var cloudIndexRevision = 0
    /// 正在从 SQLite 索引恢复上次扫描结果。
    var isRestoringScan = false
    /// 恢复令牌：切换网盘 / 换库后旧结果不再写回。
    var scanLoadToken = 0
    /// 恢复索引后需要检查的新鲜度阈值（秒）：影院 / 网盘入口用它决定是否立刻做一次增量扫描。
    var pendingRefreshMaxAge: TimeInterval?
    /// 本次打开时载入的扫描快照：下一轮自动重扫尝试增量复用。
    var scanSnapshot: CloudScanSnapshot?
    var metadataDirty = false
    /// 待写回当前照片列表的元数据更新：合并成一次数组替换，避免每张图都触发整页重算。
    var pendingPhotoUpdates: [UUID: PhotoItem] = [:]
    /// 端侧识别结果：只保存在内存，切换网盘或换库时清空。
    var analysis: [UUID: PhotoAnalysis] = [:]
    var isAnalyzing = false
    var analysisProgress = 0.0
    /// 特征向量只在打开网盘时加载一次：不参与目录切换的热路径。
    var featuresLoadedMountID: UUID?
    var isLoadingCloudFeatures = false
    /// 当前识别结果属于哪个挂载；与打开中的挂载不一致时先清空再识别。
    var insightMountID: UUID?

    // MARK: 网盘 EXIF 元数据

    /// 已读取过 EXIF（或确认没有 EXIF）的照片 ID：只保存在内存，切网盘 / 换库时清空。
    /// 不参与逐条发布：扫描 200 张时每次 insert 都 publish 会让整个侧边栏重算。
    var metadataScanned: Set<UUID> = []
    var isScanningMetadata = false
    var metadataProgress = 0.0
    /// 元数据版本号：坐标 / 拍摄时间更新后让地图、位置、值得重看等派生缓存失效。
    var metadataRevision = 0

    // MARK: 网盘人物聚类（端侧，仅内存）

    var people: [LocalPerson] = []
    var isClusteringPeople = false
    var peopleProgress = 0.0
    var peopleScanned: Set<UUID> = []

    /// 网盘照片的本地查看记录（不写网盘）。
    var viewedAt: [UUID: Date] = [:]

    // MARK: 相似检索与图库体检（内存）

    /// 端侧特征向量：内容识别或相似检索时写入，只在内存里。
    var features: [UUID: Data] = [:]
    var healthReport: LibraryHealthReport?
    var isScanningHealth = false
    var healthScanProgress = 0.0
    /// 当前美化推荐是否来自网盘（用于避免面板显示另一个范围的旧结果）。
    var beautyReportIsCloud = false

    // MARK: 派生缓存

    var geoCacheKey = ""
    var geoCacheValue: [PhotoItem] = []
    var placeClusterCacheKey = ""
    var placeClusterCacheValue: [PlaceCluster] = []
    var placeGroupCacheKey = ""
    var placeGroupCacheValue: [(title: String, clusters: [PlaceCluster])] = []
    var duplicateCacheKey = ""
    var duplicateCacheValue: [DuplicateGroup] = []
}
