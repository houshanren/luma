import Foundation

/// Store / Services 层所有长耗时任务的统一登记处。
///
/// 之前每个模型各自散着 `var xxxTask: Task<Void, Never>?`：字段本身没有错，
/// 但「谁还在跑」「退出时怎么一次清干净」只能靠人肉逐个对照，漏一个就是后台任务泄漏。
/// 这里只做两件事：
/// 1. 同一槽位只保留一个任务，重新登记时先取消旧的（等价于原来「先 cancel 再赋值」）；
/// 2. 提供 `cancelAll()`，退出 / 换库时能一次收干净。
///
/// 任务的创建仍留在调用点，`Task { }` 继续继承调用方的 Actor 上下文，
/// 因此拆字段不会改变任何并发语义。
final class StoreTaskCenter {
    /// 全部槽位集中在这里：新增后台任务必须同时在这里登记，避免又散回各模型。
    enum Slot: Hashable {
        // 图库
        case libraryImport
        case compression
        case compressionEstimate
        case thumbnailPrewarm
        case intelligence
        case systemAnalysis
        case systemAnalysisHydration
        case ai
        case health
        case beauty
        case hashScan
        case systemDuplicateGroups
        case window
        case viewerStrip
        case overview
        /// 年 / 月总览的预取（另一侧分组），完成后只进缓存、不打断当前页面。
        case overviewPrefetch
        /// 直连模式月总览里某个月的逐天分组（键 = 查询 + 月份），各月独立加载。
        case monthDays(String)
        /// 启动首屏窗口快照的异步编码与落盘。
        case windowSnapshot
        case systemWindow
        case faceCluster
        case libraryIndex
        case favoritesDigest
        case videoHubLoad
        /// 视频页筛选项变化后的重新派生：与整库加载分开，避免互相取消。
        case videoHubRebuild
        /// 地点聚类的后台重算：地名补齐期间内容版本连续变化，不能同步重聚类。
        case placeClusters
        case semanticSearch
        case cinemaScrape
        case cinemaPrewarm
        /// 影院详情里每个条目各自的「已标记」提示任务。
        case cinemaToast(UUID)
        /// 系统图库结构写（新建 / 重命名 / 删除相簿与文件夹）：每次一个独立槽位，
        /// 并发发起时各自跑完，但都登记在这里，换库 / 退出能一起取消。
        case systemStructureWrite(UUID)

        // 网盘
        case cloudScan
        case cloudScanPublish
        case cloudMetadataScanDelay
        case cloudRefreshLoop
        case cloudThumbnailPrefetch
        case cloudMetadataFlush
        case cloudAnalysis
        case cloudMetadata
        case cloudPeople
        case cloudHealth

        // 网络资源（影院）
        case networkCinemaReload
        case networkCinemaSearch
        case networkCinemaSourceSearch
        case networkCinemaLoadMore

        // 资源目录
        case catalogHealth
        case catalogGlobalSearch
        case catalogPage
        case catalogCalendar
        case catalogThumb

        // 电视
        case tvLoad
        case tvCheck
        case tvProbe
        case tvEPG
        case tvEPGHydrate
        case tvProbeHistoryFlush

        // 查看器 / 搜索 / 窗口提示
        case viewerTVSleep
        case search
        case toast
        /// 视图偏好的延迟落盘（缩放滑杆 / 捏合连续变化时只在停手后写一次）。
        case viewPreference
    }

    private var tasks: [Slot: Task<Void, Never>] = [:]

    /// 登记任务：同一槽位的旧任务先取消。传 nil 等价于 `finish`。
    func adopt(_ slot: Slot, _ task: Task<Void, Never>?) {
        tasks[slot]?.cancel()
        tasks[slot] = task
    }

    /// 登记任务但不取消同槽位的旧任务：用于允许并发、必须各自完成的结构写。
    func attach(_ slot: Slot, _ task: Task<Void, Never>) {
        tasks[slot] = task
    }

    func task(_ slot: Slot) -> Task<Void, Never>? {
        tasks[slot]
    }

    /// 槽位上是否有仍在运行的任务（已取消但还没退出的不算）。
    func isRunning(_ slot: Slot) -> Bool {
        guard let task = tasks[slot] else { return false }
        return !task.isCancelled
    }

    /// 任务自己结束时注销登记；与原来的 `xxxTask = nil` 语义一致。
    func finish(_ slot: Slot) {
        tasks[slot] = nil
    }

    /// 取消并注销。
    func cancel(_ slot: Slot) {
        tasks[slot]?.cancel()
        tasks[slot] = nil
    }

    /// 一次取消全部登记的任务（退出、换库等场景）。
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
