import Observation
import AppKit
import Foundation
import LumaContentCore

/// 单个频道的实时画面探测状态。
enum TVProbeState: String {
    case idle
    case probing
    case available
    case unavailable
}

/// 追剧 / 追赛订阅：按归一化节目名记住「这一类节目」，跨频道、跨天都算命中。
struct TVSubscription: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
    let createdAt: Date
}

/// 网络电视：默认开启但一个源都不接入；由用户粘贴 M3U 地址或导入文件自行接入。
/// 源、顺序、频道缓存与开关都写进当前图库的 SQLite（`resources/tv/Television.sqlite`）；
/// 连接检测串行排队，并上报到统一任务中心。
@MainActor
@Observable
final class IPTVBrowserModel {
    enum Keys {
        static let enabled = "luma.tv.enabled"
        static let playlists = "luma.tv.playlists"
        static let refreshedAt = "luma.tv.refreshedAt"
        static let hubTab = "luma.tv.hubTab.v1"
        static let favorites = "luma.tv.favorites"
        static let recent = "luma.tv.recent"
        static let preferredLines = "luma.tv.preferredLines"
        static let probeHistory = "luma.tv.probeHistory"
        static let reminders = "luma.tv.reminders"
        static let subscriptions = "luma.tv.subscriptions"
        static let sportFollows = "luma.tv.sportFollows"
        static let recordings = "luma.tv.recordings"
    }

    /// 总开关：关闭后侧边栏仍保留入口，但不再拉流，页面显示关闭提示。
    var enabled: Bool
    var playlists: [TVPlaylist]
    var channels: [TVChannel] = [] {
        didSet {
            channelRevision &+= 1
            aggregatedCache = nil
            focusedChannelsCache = nil
            visibleCacheKey = ""
            channelNumberIndex.removeAll()
            channelNumberIndexKey = ""
            channelsWithProgramsCache.removeAll()
            knownLinesCache.removeAll()
            knownLinesRevision = -1
        }
    }
    var isLoading = false
    var isChecking = false
    var refreshedAt: Date?
    var failedPlaylistIDs: Set<UUID> = []

    var hubTab: TVHubTab
    /// 节目回看选中的日期偏移（-3…3，0 = 今天）。放在模型里，
    /// 顶部工具栏的分页胶囊可以同步显示「N 个频道有节目单 · 昨天」。
    var guideDayOffset = 0
    /// 当前焦点源：写回 SQLite，下次启动仍停在上次看的源。
    var focusedPlaylistID: UUID? {
        didSet { database.setSetting("focusedPlaylistID", focusedPlaylistID?.uuidString) }
    }
    var error: String?
    var sourceError: SourceError?
    var showWizard = false
    var searchText = ""
    var regionFilter: TVRegion?
    var groupFilter: String?
    var channelSourceFilterID: UUID?
    /// 按省份聚合时的省份筛选；与 `groupFilter` 互斥，切分组方式时清空。
    var provinceFilter: String?
    /// 按国家 / 地区聚合时的国家筛选；与另外两种分组方式互斥。
    var countryFilter: String?
    /// 频道墙分组方式，写进 SQLite，下次进入沿用。
    var groupingMode: TVGroupingMode = .category {
        didSet { database.setSetting("groupingMode", groupingMode.rawValue) }
    }

    /// 每个频道的实时画面探测状态：进入频道页后按可见卡片逐个抓帧。
    var probeStates: [String: TVProbeState] = [:]
    /// 探测得到的截帧与媒体参数：信号页用这些数字回答「为什么卡 / 哪条线最稳」。
    var probeReports: [String: TVProbeReport] = [:]
    /// 是否还有频道在排队 / 抓帧：信号页用来切换「探测全部 / 停止」。
    var isProbingChannels = false
    /// 用户为频道锁定的默认线路：key 是频道 id，value 是完整流地址。
    var preferredLines: [String: String]
    /// 24 小时探测采样：每个频道最近若干次成功 / 失败与延迟。
    var probeHistory: [String: [TVProbePoint]]

    /// 收藏与最近观看：只存频道 id，随图库保存在 UserDefaults。
    var favoriteIDs: Set<String>
    var recentIDs: [String]
    /// 频道墙快捷筛选：nil 表示全部。
    var quickFilter: TVQuickFilter?

    /// XMLTV 节目单：key 是归一化后的频道 id（去掉 @HD 等后缀）。
    var epgPrograms: [String: [TVEPGProgram]] = [:]
    /// XMLTV display-name 归一化 -> 可能的 channel id 列表（多份 EPG 可能各用一套 id）。
    var epgChannelNames: [String: [String]] = [:]
    var isLoadingEPG = false
    var epgError: String?
    var epgUpdatedAt: Date?

    /// 统一任务中心：连接检测会登记为 `.connectivity` 任务，节目单更新会登记为 `.epg` 任务。
    var jobCenter: SourceJobCenter?
    /// 电视侧后台任务登记处：加载、连接检测、测速、节目单都走这里。
    let tasks = StoreTaskCenter()
    var onJobChange: (() -> Void)?
    /// 任务结束后的归档回调：由 LibraryStore 接到 `archiveSourceJob`，写进任务记录。
    var onJobFinished: ((UUID) -> Void)?

    let database = TVDatabase.shared
    var checkQueue: [UUID] = []
    var channelCache: [UUID: [TVChannel]] = [:]
    var hasLoaded = false
    var probeQueue: [TVChannel] = []
    let probeConcurrency = 2
    /// 当前这一轮节目单下载的任务 ID：任务条与任务记录据此显示进度。
    var epgJobID: UUID?
    var isHydratingEPG = false
    /// 画面探测任务：登记到统一任务中心，左下角后台任务条能看到进度并可取消。
    var probeJobID: UUID?
    var probeJobTotal = 0
    var probeJobCompleted = 0
    var probeJobAvailable = 0
    var probeJobUnavailable = 0
    var probeHistoryDirty = false

    // MARK: - 派生数据缓存
    //
    // 节目单数据动辄上万条、频道上千个，而视图（时间轴 / 传送门 / 时间环）会在
    // 悬停、拖动时高频重算。这些缓存把「遍历 + 合并 + 排序」压到每次数据变化只做一次。
    /// `channels` 重建次数：频道派生缓存据此失效。
    var channelRevision = 0
    // 以下都是派生缓存：只在 getter 里惰性写入，绝不能参与 Observation 通知。
    // 否则 SwiftUI 求值 body / 工具栏时写缓存会触发 willSet -> GraphHost 事务，
    // 直接在 AttributeGraph 里 precondition 失败（SIGABRT）。
    // 视图的刷新依赖仍然来自被观察的源数据（channels、channelRevision、epgRevision 等）。
    @ObservationIgnored var aggregatedCache: [TVChannel]?
    @ObservationIgnored var focusedChannelsCache: (id: UUID?, revision: Int, list: [TVChannel])?
    /// 侧边栏每个源的分组：源数量 × 上千频道的分组结果按「频道 revision」缓存，
    /// 探测状态每变一次不再把所有源重新分组一遍。
    @ObservationIgnored var categoryGroupsCache: [UUID: (revision: Int, groups: [TVCategory])] = [:]
    @ObservationIgnored var visibleCacheKey = ""
    @ObservationIgnored var groupedCacheKey = ""
    @ObservationIgnored var channelNumberIndexKey = ""
    @ObservationIgnored var visibleCache: [TVChannel] = []
    @ObservationIgnored var groupedCache: [(group: String, channels: [TVChannel])] = []
    @ObservationIgnored var channelNumberIndex: [String: Int] = [:]
    /// 频道 id -> 这条频道可用的全部线路（含其它源的同名频道）：
    /// 探测自动换线与播放线路校验共用这一份索引。
    @ObservationIgnored var knownLinesCache: [String: Set<String>] = [:]
    /// 缓存对应的频道版本：本身不参与通知，刷新依赖走 `channelRevision`。
    @ObservationIgnored var knownLinesRevision = -1
    /// EPG 数据版本：节目单刷新后清空按频道 / 按天的节目缓存。
    var epgRevision = 0
    /// 频道 id -> 命中的 EPG 频道 id 列表。
    @ObservationIgnored var epgKeyCache: [String: [String]] = [:]
    /// 频道 id -> 合并后的节目。
    @ObservationIgnored var epgProgramCache: [String: [TVEPGProgram]] = [:]
    /// 节目 id -> 归一化后的「节目名 + 副标题」：搜索节目单时不再逐次折叠中文。
    @ObservationIgnored var epgSearchText: [String: String] = [:]
    /// `epgSearchText` 对应的 EPG 版本。
    @ObservationIgnored var epgSearchTextRevision = -1
    /// "频道 id#当天 0 点" -> 当天节目。
    @ObservationIgnored var epgDayCache: [String: [TVEPGProgram]] = [:]
    /// "可见频道签名#当天 0 点" -> 当天有节目的频道。
    @ObservationIgnored var channelsWithProgramsCache: [String: [TVChannel]] = [:]
    /// 台名前缀桶：按归一化台名前 2 个字符分组，前缀匹配只扫同桶的键。
    @ObservationIgnored var epgPrefixBuckets: [String: [(name: String, ids: [String])]] = [:]

    /// 已预约节目的开播时间：节目 id -> 开始时间。用于按钮状态与过期清理。
    var reminderStarts: [String: Date]
    /// 预约结果提示：由页面转成 Toast 后清空。
    var reminderNotice: String?

    /// 已订阅的节目（按归一化节目名去重），跨频道、跨天复用。
    var subscriptions: [TVSubscription] = []

    /// 关注的球队 / 联赛：夜航据此高亮与筛选，并可一键为相关赛事排提醒。
    var sportFollows: [TVSportFollow] = []
    /// 录制中心：定时等待与已完成的录制都跟着当前图库保存。
    var recordings: [TVRecording] = []
    /// 录制调度器：每 20 秒检查一次是否有到点的定时录制。
    @ObservationIgnored var recordingTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        // 总开关与分页是全局偏好，先按 UserDefaults 初始化；
        // 源列表要等 `LibraryPaths.configure()` 之后才能确定是哪个图库，
        // 由 LibraryStore 在配置完成后调用 `reloadForCurrentLibrary()` 载入。
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        // 电视源默认一个都不接入：源列表等 reloadForCurrentLibrary() 从图库库读取。
        playlists = []
        refreshedAt = defaults.object(forKey: Keys.refreshedAt) as? Date
        hubTab = TVHubTab.persisted(defaults.string(forKey: Keys.hubTab))
        focusedPlaylistID = nil
        // 收藏 / 最近 / 预约 / 订阅 / 线路 / 探测历史都属于「当前图库」，
        // 等 LibraryPaths.configure() 之后由 reloadForCurrentLibrary() 从库内 SQLite 读。
        favoriteIDs = []
        recentIDs = []
        preferredLines = [:]
        probeHistory = [:]
        reminderStarts = [:]
        subscriptions = []
        sportFollows = []
        recordings = []
    }

    deinit {
        recordingTimer?.invalidate()
    }
}
