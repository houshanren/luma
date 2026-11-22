import Foundation

/// 源后台任务的种类：扫描、索引、刮削、EPG、台标、同步、分析、健康检查。
public enum SourceJobKind: String, Codable, CaseIterable, Hashable, Sendable {
    case scan
    case index
    case scrape
    case epg
    case artwork
    case sync
    case analyze
    case healthCheck
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

    public init(jobID: UUID,
                sourceID: SourceID,
                kind: SourceJobKind,
                completed: Int = 0,
                total: Int? = nil,
                phase: SourceJobPhase = .pending,
                message: String? = nil,
                updatedAt: Date = Date()) {
        self.jobID = jobID
        self.sourceID = sourceID
        self.kind = kind
        self.completed = completed
        self.total = total
        self.phase = phase
        self.message = message
        self.updatedAt = updatedAt
    }

    public var fraction: Double? {
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
                                      phase: .running)
        if let cancel { cancelHandlers[job.id] = cancel }
        return job.id
    }

    public func update(_ id: UUID,
                       completed: Int? = nil,
                       total: Int? = nil,
                       message: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard var item = storage[id] else { return }
        if let completed { item.completed = completed }
        if let total { item.total = total }
        if let message { item.message = message }
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
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        let handler = cancelHandlers[id]
        cancelHandlers[id] = nil
        if var item = storage[id] {
            item.phase = .cancelled
            item.updatedAt = Date()
            storage[id] = item
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
}
