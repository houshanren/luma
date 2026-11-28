import Foundation

/// 一次助手任务的轻量记录：关闭界面后仍能在任务中心看到「刚跑了什么」。
/// 只保存在内存里；跨重启的任务队列不在这一版范围内。
struct AITaskRecord: Identifiable, Equatable {
    enum Status: String {
        case running
        case finished
        case failed
        case cancelled

        var title: String {
            switch self {
            case .running: return "运行中"
            case .finished: return "已完成"
            case .failed: return "失败"
            case .cancelled: return "已停止"
            }
        }

        var symbol: String {
            switch self {
            case .running: return "circle.dotted"
            case .finished: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.circle.fill"
            case .cancelled: return "stop.circle"
            }
        }
    }

    let id: UUID
    let title: String
    let startedAt: Date
    var finishedAt: Date?
    var status: Status
    var toolSteps: Int
    var isBackground: Bool
    var errorText: String?

    // MARK: - 验收埋点（2.2 验收指标）

    /// 模型名，用于按模型对比成本。
    var model: String = ""
    /// 首个文本片段到达的时间（毫秒），用于验收「首字延迟 < 1.5s」。
    var firstTokenMs: Int?
    /// 本任务弹出过的审批卡次数，用于验收「审批疲劳 ≤ 1.2 次 / 任务」。
    var approvalCount: Int = 0
    /// 端点返回的 token 用量；端点不返回时保持 0。
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    /// 本任务实际撤销过的快照条数，用于验收「撤销成功率」。
    var undoEntries: Int = 0

    init(id: UUID,
         title: String,
         startedAt: Date,
         status: Status = .running,
         toolSteps: Int = 0,
         isBackground: Bool = false,
         errorText: String? = nil,
         model: String = "") {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.status = status
        self.toolSteps = toolSteps
        self.isBackground = isBackground
        self.errorText = errorText
        self.model = model
    }

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    var totalTokens: Int { promptTokens + completionTokens }

    /// 训练 / 验收用的稳定行格式：一次任务一行 JSON。
    var metricsRow: [String: Any] {
        var row: [String: Any] = [
            "task": id.uuidString,
            "at": ISO8601DateFormatter().string(from: startedAt),
            "model": model,
            "status": status.rawValue,
            "background": isBackground,
            "toolSteps": toolSteps,
            "approvals": approvalCount,
            "undoEntries": undoEntries,
            "promptTokens": promptTokens,
            "completionTokens": completionTokens
        ]
        if let duration { row["durationMs"] = Int(duration * 1000) }
        if let firstTokenMs { row["firstTokenMs"] = firstTokenMs }
        if let errorText { row["error"] = String(errorText.prefix(200)) }
        return row
    }
}

/// 任务中心的验收聚合：只统计已结束的任务，避免运行中拉低成功率。
struct AITaskMetricsSummary {
    var total = 0
    var finished = 0
    var failed = 0
    var cancelled = 0
    var medianFirstTokenMs: Int?
    var averageApprovals: Double?
    var averageTokens: Double?

    init(records: [AITaskRecord]) {
        let done = records.filter { $0.status != .running }
        total = done.count
        finished = done.filter { $0.status == .finished }.count
        failed = done.filter { $0.status == .failed }.count
        cancelled = done.filter { $0.status == .cancelled }.count
        let latencies = done.compactMap(\.firstTokenMs).sorted()
        if !latencies.isEmpty {
            medianFirstTokenMs = latencies[latencies.count / 2]
        }
        if !done.isEmpty {
            averageApprovals = Double(done.reduce(0) { $0 + $1.approvalCount }) / Double(done.count)
            let tokenRows = done.filter { $0.totalTokens > 0 }
            if !tokenRows.isEmpty {
                averageTokens = Double(tokenRows.reduce(0) { $0 + $1.totalTokens }) / Double(tokenRows.count)
            }
        }
    }

    var successRate: Double? {
        guard total > 0 else { return nil }
        return Double(finished) / Double(total)
    }
}

/// 助手主动追问：模型在动手前发现信息不足时，用一张小卡问清楚。
struct AIQuestionRequest: Identifiable, Equatable {
    let id = UUID()
    var question: String
    var options: [String]
}
