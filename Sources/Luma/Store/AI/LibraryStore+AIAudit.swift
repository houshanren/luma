import Foundation

/// 审计日志：每次工具调用按行追加到 `overlay/ai/audit.jsonl`。
/// 只记「谁在什么任务里调用了什么、参数摘要、结果与风险」，不记录图片内容与 API Key。
extension LibraryStore {
    /// 审计文件跟着当前图库走，和记忆、成果物、连接器配置放在一起。
    var aiAuditLogURL: URL {
        LibraryPaths.overlayRoot
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    func recordAIAudit(_ call: AIToolCall, args: [String: Any], result: AIToolExecution) {
        let risk = AILibraryTools.risk(for: call.name, arguments: args)
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "task": aiCurrentTaskID?.uuidString ?? "",
            "tool": call.name,
            "risk": risk.rawValue,
            "ok": !result.json.contains("\"ok\":false"),
            "summary": String((result.summary ?? "").prefix(240)),
            "args": aiAuditArgumentDigest(args)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }
        let url = aiAuditLogURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// 参数里可能带长数组或图片 data URL，审计只保留可读摘要。
    private func aiAuditArgumentDigest(_ args: [String: Any]) -> String {
        var parts: [String] = []
        for key in args.keys.sorted() {
            guard let value = args[key] else { continue }
            let text: String
            switch value {
            case let string as String:
                text = String(string.prefix(80))
            case let array as [Any]:
                text = "[\(array.count) 项]"
            case let dict as [String: Any]:
                text = "{\(dict.count) 字段}"
            default:
                text = String(describing: value)
            }
            parts.append("\(key)=\(text)")
        }
        return String(parts.joined(separator: ", ").prefix(320))
    }
}
