import Foundation
import LumaContentCore

/// 统一任务中心在 `LibraryStore` 上的便捷入口。
/// 现有各模块的 Task 字段可以继续保留；先把进度与取消收口到一处，后续再逐个替换。
extension LibraryStore {
    @discardableResult
    func beginSourceJob(_ job: SourceJob, cancel: (() -> Void)? = nil) -> UUID {
        let id = sourceJobCenter.begin(job, cancel: cancel)
        sourceJobRevision &+= 1
        return id
    }

    func updateSourceJob(_ id: UUID,
                         completed: Int? = nil,
                         total: Int? = nil,
                         message: String? = nil,
                         fraction: Double? = nil) {
        sourceJobCenter.update(id, completed: completed, total: total, message: message, fraction: fraction)
        sourceJobRevision &+= 1
    }

    func finishSourceJob(_ id: UUID, message: String? = nil) {
        sourceJobCenter.finish(id, message: message)
        sourceJobRevision &+= 1
    }

    func failSourceJob(_ id: UUID, message: String? = nil) {
        sourceJobCenter.fail(id, message: message)
        sourceJobRevision &+= 1
    }

    func cancelSourceJob(_ id: UUID) {
        sourceJobCenter.cancel(id)
        sourceJobRevision &+= 1
    }

    func sourceJobs(for sourceID: SourceID) -> [JobProgress] {
        sourceJobCenter.progress.values
            .filter { $0.sourceID == sourceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeSourceJobs: [JobProgress] {
        sourceJobCenter.progress.values
            .filter { $0.phase == .running || $0.phase == .pending }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 某类已结束任务的最近记录：任务浮层用它展示「连接检测」等一次性结果。
    func recentSourceJobs(kind: SourceJobKind, limit: Int = 4) -> [JobProgress] {
        Array(sourceJobCenter.progress.values
            .filter { $0.kind == kind && $0.phase != .running && $0.phase != .pending }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit))
    }

    func clearFinishedSourceJobs(kind: SourceJobKind) {
        sourceJobCenter.clearFinished(kind: kind)
        sourceJobRevision &+= 1
    }

    /// 影院作用域 → 统一源 ID。
    func sourceID(for scope: CinemaScope) -> SourceID {
        switch scope {
        case .local:
            return .localCinema
        case .mount(let id):
            return .mountCinema(id)
        }
    }
}
