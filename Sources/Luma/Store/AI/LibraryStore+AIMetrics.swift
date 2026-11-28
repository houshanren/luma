import Foundation

/// 2.2 验收埋点：每个任务结束时追加一行 JSON 到 `ai/metrics.jsonl`。
/// 只写数值与状态，不写对话正文、照片名或路径；用于算成功率、首字延迟、审批次数与 token 成本。
extension LibraryStore {
    var aiMetricsLogURL: URL {
        LibraryPaths.overlayRoot
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("metrics.jsonl")
    }

    /// 任务结束时调用一次；失败不打扰用户，只影响验收数据完整性。
    func recordAITaskMetrics(_ record: AITaskRecord) {
        guard let data = try? JSONSerialization.data(withJSONObject: record.metricsRow, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = aiMetricsLogURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard let payload = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }

    /// 首个文本片段到达时打点，只记第一次。
    func markAIFirstToken() {
        guard let taskID = aiCurrentTaskID,
              let index = aiTaskRecords.firstIndex(where: { $0.id == taskID }),
              aiTaskRecords[index].firstTokenMs == nil else { return }
        let ms = Int(Date().timeIntervalSince(aiTaskRecords[index].startedAt) * 1000)
        aiTaskRecords[index].firstTokenMs = max(0, ms)
    }

    /// 每弹出一张审批卡计数一次。
    func noteAIApprovalPrompt() {
        guard let taskID = aiCurrentTaskID,
              let index = aiTaskRecords.firstIndex(where: { $0.id == taskID }) else { return }
        aiTaskRecords[index].approvalCount += 1
    }

    /// 撤销完成后回填实际回滚的快照条数。
    func noteAIUndo(taskID: UUID, entries: Int) {
        guard let index = aiTaskRecords.firstIndex(where: { $0.id == taskID }) else { return }
        aiTaskRecords[index].undoEntries += entries
    }

    /// 任务中心与文档共用的一份聚合。
    var aiTaskMetricsSummary: AITaskMetricsSummary {
        AITaskMetricsSummary(records: aiTaskRecords)
    }

    /// 全量工具数，用于展示「本轮暴露 N / M」。
    var aiToolDefinitionCount: Int { AILibraryTools.definitions.count }

    /// 「单任务成本」的确定性部分：本轮暴露的工具 schema 体积相对全量的比例。
    /// 不含模型随机性，换模型也成立，用来证明路由确实在省 prompt。
    var aiToolSchemaSaving: Double? {
        let all = AILibraryTools.definitions
        guard !all.isEmpty, aiLastToolCount > 0 else { return nil }
        let full = Double(all.count)
        return max(0, min(1, 1 - Double(aiLastToolCount) / full))
    }
}
