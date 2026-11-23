import Foundation

/// 源后台任务的种类：扫描、索引、刮削、EPG、台标、同步、分析、健康检查，
/// 以及图库本地的导入 / 压缩 / 备份 / 导出 / 下载 / 聚类 / 去重 / 美化 / 地点解析 / 元数据 / 助手。
public enum SourceJobKind: String, Codable, CaseIterable, Hashable, Sendable {
    case scan
    case index
    case scrape
    case epg
    case artwork
    case sync
    case analyze
    case healthCheck
    /// 一次性的连通性检测（网盘 / 站点根目录探测），与耗时的「健康检测」扫描区分开。
    case connectivity
    case ingest
    case compress
    case backup
    case export
    case download
    case cluster
    case dedupe
    case beauty
    case places
    case metadata
    case assistant

    public var title: String {
        switch self {
        case .scan: return "扫描"
        case .index: return "索引"
        case .scrape: return "刮削"
        case .epg: return "节目单"
        case .artwork: return "台标"
        case .sync: return "同步"
        case .analyze: return "分析"
        case .healthCheck: return "健康检测"
        case .connectivity: return "连接检测"
        case .ingest: return "导入"
        case .compress: return "压缩"
        case .backup: return "备份"
        case .export: return "导出"
        case .download: return "下载"
        case .cluster: return "聚类"
        case .dedupe: return "去重"
        case .beauty: return "美化"
        case .places: return "地点"
        case .metadata: return "元数据"
        case .assistant: return "助手"
        }
    }
}

/// 一个可取消的后台任务描述。
public struct SourceJob: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var sourceID: SourceID
    public var kind: SourceJobKind
    public var title: String
    public var isCancellable: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(),
                sourceID: SourceID,
                kind: SourceJobKind,
                title: String,
                isCancellable: Bool = true,
                createdAt: Date = Date()) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.title = title
        self.isCancellable = isCancellable
        self.createdAt = createdAt
    }
}

public enum SourceJobPhase: String, Codable, Hashable, Sendable {
    case pending
    case running
    case finished
    case failed
    case cancelled
}

/// 任务进度：由 Provider 主动上报，侧边栏与状态条只读它。
public struct JobProgress: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID { jobID }
    public var jobID: UUID
    public var sourceID: SourceID
    public var kind: SourceJobKind
    public var completed: Int
    public var total: Int?
    public var phase: SourceJobPhase
    public var message: String?
    public var updatedAt: Date
    /// 没有明确总数、只能按阶段上报 0–1 进度时使用（例如 EXIF 批量扫描、保险库校验）。
    public var fractionValue: Double?
    /// 是否支持取消：不支持的任务不显示取消按钮，避免点了没反应。
    public var isCancellable: Bool

    public init(jobID: UUID,
                sourceID: SourceID,
                kind: SourceJobKind,
                completed: Int = 0,
                total: Int? = nil,
                phase: SourceJobPhase = .pending,
                message: String? = nil,
                updatedAt: Date = Date(),
                fractionValue: Double? = nil,
                isCancellable: Bool = true) {
        self.jobID = jobID
        self.sourceID = sourceID
        self.kind = kind
        self.completed = completed
        self.total = total
        self.phase = phase
        self.message = message
        self.updatedAt = updatedAt
        self.fractionValue = fractionValue
        self.isCancellable = isCancellable
    }

    public var fraction: Double? {
        if let fractionValue { return min(1, max(0, fractionValue)) }
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// 任务中心：只负责登记、进度与取消回调，不接管 Provider 的 Task 实现。
/// 这样云盘扫描、影院刮削、电视 EPG、图库同步可以共用一套“可取消 + 可观测”协议。
/// Provider 在自己的串行队列或 MainActor 上调用；内部用锁保护，允许后台线程上报进度。
public final class SourceJobCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: JobProgress] = [:]
    private var cancelHandlers: [UUID: () -> Void] = [:]

    public init() {}

    public var progress: [UUID: JobProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    public func begin(_ job: SourceJob, cancel: (() -> Void)? = nil) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        storage[job.id] = JobProgress(jobID: job.id,
                                      sourceID: job.sourceID,
                                      kind: job.kind,
                                      phase: .running,
                                      isCancellable: job.isCancellable)
        if let cancel { cancelHandlers[job.id] = cancel }
        return job.id
    }

    public func update(_ id: UUID,
                       completed: Int? = nil,
                       total: Int? = nil,
                       message: String? = nil,
                       fraction: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard var item = storage[id] else { return }
        if let completed { item.completed = completed }
        if let total { item.total = total }
        if let message { item.message = message }
        if let fraction { item.fractionValue = fraction }
        item.updatedAt = Date()
        storage[id] = item
    }

    public func finish(_ id: UUID, message: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard var item = storage[id] else { return }
        item.phase = .finished
        item.completed = item.total ?? item.completed
        item.message = message
        item.updatedAt = Date()
        storage[id] = item
        cancelHandlers[id] = nil
        pruneFinishedLocked()
    }

    public func fail(_ id: UUID, message: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard var item = storage[id] else { return }
        item.phase = .failed
        item.message = message
        item.updatedAt = Date()
        storage[id] = item
        cancelHandlers[id] = nil
        pruneFinishedLocked()
    }

    /// 已完成 / 失败 / 取消的任务只保留最近 100 条：
    /// 现在连模型下载、特征加载这类高频任务也上报，不裁剪会让内存无限增长。
    private func pruneFinishedLocked() {
        let finished = storage.values.filter { $0.phase != .running && $0.phase != .pending }
        guard finished.count > 100 else { return }
        let excess = finished.sorted { $0.updatedAt < $1.updatedAt }.prefix(finished.count - 100)
        for item in excess { storage[item.jobID] = nil }
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        let handler = cancelHandlers[id]
        cancelHandlers[id] = nil
        if var item = storage[id] {
            item.phase = .cancelled
            item.updatedAt = Date()
            storage[id] = item
            pruneFinishedLocked()
        }
        lock.unlock()
        handler?()
    }

    public func cancelAll(sourceID: SourceID) {
        let ids = progress.values.filter { $0.sourceID == sourceID }.map(\.jobID)
        for id in ids { cancel(id) }
    }

    public func activeJobs(sourceID: SourceID) -> [JobProgress] {
        progress.values
            .filter { $0.sourceID == sourceID && $0.phase == .running }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func clearFinished(sourceID: SourceID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        storage = storage.filter { _, item in
            if let sourceID, item.sourceID != sourceID { return true }
            return item.phase == .running || item.phase == .pending
        }
    }

    /// 清空某一类已结束任务（例如总览页的连接检测记录），进行中的不动。
    public func clearFinished(kind: SourceJobKind) {
        lock.lock()
        defer { lock.unlock() }
        storage = storage.filter { _, item in
            if item.kind == kind { return item.phase == .running || item.phase == .pending }
            return true
        }
    }
}
