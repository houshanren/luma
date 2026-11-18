import Foundation

struct AskAnswer {
    let text: String
    let hits: [RetrievalHit]
    let usedModel: Bool
    let scope: RetrievalScope
}

/// 「问一问」：先本地检索，再把命中的元数据交给模型总结；没有模型时给出可用的本地结果摘要。
@MainActor
enum AskService {
    private static let systemPrompt = """
    你是「拾光」图库的全库检索助手。只能依据用户消息里给出的检索结果回答，不要编造照片、数量或细节。
    用简体中文回答：先给一句结论，再列 3–8 条依据；引用照片时使用 #编号，不要输出文件路径。
    如果检索结果不足以回答，直接说明没有找到，并给出一个更具体的查询建议。
    """

    static func ask(question: String, store: LibraryStore) async -> AskAnswer {
        let outcome = RetrievalService.shared.retrieve(text: question, store: store, limit: 24)
        guard canUseModel(store: store) else {
            return AskAnswer(text: extractive(question: question, outcome: outcome),
                             hits: outcome.hits,
                             usedModel: false,
                             scope: outcome.scope)
        }
        do {
            let text = try await requestModel(question: question, outcome: outcome, store: store)
            return AskAnswer(text: text, hits: outcome.hits, usedModel: true, scope: outcome.scope)
        } catch {
            let fallback = extractive(question: question, outcome: outcome)
            return AskAnswer(text: fallback + "\n\n（模型请求失败：\(error.localizedDescription)）",
                             hits: outcome.hits,
                             usedModel: false,
                             scope: outcome.scope)
        }
    }

    private static func canUseModel(store: LibraryStore) -> Bool {
        guard store.aiConfigurationReady else { return false }
        return !store.aiConfig.provider.requiresAPIKey || store.aiHasAPIKey
    }

    private static func requestModel(question: String,
                                     outcome: RetrievalOutcome,
                                     store: LibraryStore) async throws -> String {
        var lines: [String] = []
        lines.append("【检索范围】\(outcome.scope.title) · 索引 \(outcome.indexTotal) 条 · 命中 \(outcome.hits.count) 条")
        if !outcome.tokens.isEmpty {
            lines.append("【解析出的检索词】\(outcome.tokens.joined(separator: " / "))")
        }
        for (index, hit) in outcome.hits.enumerated() {
            var line = "#\(index + 1) id=\(hit.id.uuidString)"
            line += " 日期=\(DateText.dayFormatter.string(from: hit.capturedAt))"
            if !hit.title.isEmpty { line += " 标题=\(hit.title)" }
            if !hit.snippet.isEmpty { line += " 摘要=\(hit.snippet)" }
            lines.append(line)
        }
        lines.append("【问题】\(question)")

        let messages = [
            AIRequestMessage(role: "system", text: systemPrompt),
            AIRequestMessage(role: "user", text: lines.joined(separator: "\n"))
        ]
        let completion = try await AIProviderClient.complete(config: store.aiConfig,
                                                            apiKey: store.aiAPIKey,
                                                            messages: messages)
        let content = completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AIError.badResponse }
        return content
    }

    private static func extractive(question: String, outcome: RetrievalOutcome) -> String {
        guard !outcome.hits.isEmpty else {
            return "在当前范围内没有找到与「\(question)」相关的照片。可以换一种说法，或先在侧边栏 › 场景 › 分析照片内容。"
        }
        var lines = ["在当前范围找到 \(outcome.hits.count) 张相关照片："]
        for (index, hit) in outcome.hits.prefix(8).enumerated() {
            var line = "#\(index + 1) \(DateText.dayFormatter.string(from: hit.capturedAt)) \(hit.title)"
            if !hit.snippet.isEmpty { line += " · \(hit.snippet)" }
            lines.append(line)
        }
        lines.append("（未配置模型，以上为本地检索结果；在设置 › 助手中接入本地运行时或云端模型后可生成总结。）")
        return lines.joined(separator: "\n")
    }
}
