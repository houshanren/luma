import Foundation

/// 「接管」：AI 跑长任务时，用户随时可以把方向盘拿回来。
/// 不粗暴打断正在执行的工具，而是在两个工具之间暂停；
/// 处理完自己的事可以「继续执行」，也可以「结束任务」。
extension LibraryStore {
    /// 用户点了「接管」：等当前工具跑完再暂停，避免写操作做到一半。
    func requestAITakeover() {
        guard aiIsResponding, !aiTakeoverPaused else { return }
        aiTakeoverRequested = true
        aiActivity = "已请求接管，等当前步骤结束"
    }

    /// 接管后交还给 AI：从下一个工具继续跑。
    func resumeAITaskFromTakeover() {
        guard aiTakeoverPaused || aiTakeoverRequested else { return }
        aiTakeoverRequested = false
        aiTakeoverPaused = false
        aiActivity = "继续执行"
        aiTakeoverContinuation?.resume(returning: true)
        aiTakeoverContinuation = nil
    }

    /// 接管后结束任务：AI 停止，已完成的步骤仍可撤销。
    func endAITaskFromTakeover() {
        guard aiTakeoverPaused || aiTakeoverRequested else { return }
        aiTakeoverRequested = false
        aiTakeoverPaused = false
        aiActivity = "已结束本次任务"
        aiTakeoverContinuation?.resume(returning: false)
        aiTakeoverContinuation = nil
    }

    /// 在工具之间调用：需要接管就挂起，返回 false 表示用户选择结束任务。
    func awaitAITakeoverIfNeeded() async -> Bool {
        guard aiTakeoverRequested else { return true }
        aiTakeoverPaused = true
        aiActivity = "已接管，AI 已暂停"
        let resume = await withCheckedContinuation { continuation in
            aiTakeoverContinuation = continuation
        }
        aiTakeoverPaused = false
        aiTakeoverRequested = false
        return resume
    }

    /// 停止 / 切换图库 / 新对话时，把等待中的接管控件一起收尾。
    func cancelAITakeover() {
        aiTakeoverRequested = false
        aiTakeoverPaused = false
        if aiTakeoverContinuation != nil {
            aiTakeoverContinuation?.resume(returning: false)
            aiTakeoverContinuation = nil
        }
    }
}
