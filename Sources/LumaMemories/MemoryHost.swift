import Foundation
import LumaContentCore

/// 回忆影片功能依赖的最小宿主能力。
/// 只暴露「任务中心 + 提示 + 关闭回忆」，视图因此不需要知道 `LibraryStore` 的存在。
@MainActor
package protocol MemoryHost: AnyObject, ObservableObject {
    /// 当前正在播放的回忆；置空即退出回忆影片。
    var activeMemory: PhotoMemory? { get set }

    /// 任务归属的图库路径，只用于统一任务条展示。
    var memoryJobPath: String { get }

    func beginSourceJob(_ job: SourceJob, cancel: (() -> Void)?) -> UUID
    func updateSourceJob(_ id: UUID,
                         completed: Int?,
                         total: Int?,
                         message: String?,
                         fraction: Double?)
    func finishSourceJob(_ id: UUID, message: String?)
    func failSourceJob(_ id: UUID, message: String?)
    func showToast(_ message: String)
}
