import Foundation
import LumaDomain

/// 发给模型的一条消息：
/// - role = user / system：text 为正文，images 为 data URL；
/// - role = assistant：text 为正文，toolCalls 非空时附带工具调用；
/// - role = tool：text 为工具结果，toolCallID 对应被调用的工具。
package struct AIRequestMessage {
    package var role: String
    package var text: String
    package var images: [String] = []
    package var toolCalls: [AIToolCall]?
    package var toolCallID: String?
    package init(
        role: String,
        text: String,
        images: [String] = [],
        toolCalls: [AIToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// 一次模型请求：与具体协议无关。
/// OpenAI 兼容接口、本机运行时、后续 MCP 托管模型都实现 `AIChatProvider`。
package struct AIChatRequest {
    package var config: AIConfig
    package var apiKey: String
    package var messages: [AIRequestMessage]
    package var tools: [AIRequestTool] = []
    package init(
        config: AIConfig,
        apiKey: String,
        messages: [AIRequestMessage],
        tools: [AIRequestTool] = []
    ) {
        self.config = config
        self.apiKey = apiKey
        self.messages = messages
        self.tools = tools
    }
}

/// 流式事件：文本增量、思考摘要增量、完整工具调用、最终结果。
package enum AIStreamEvent {
    case text(String)
    /// 思考摘要增量（reasoning_content）：界面折叠展示，不进入正式回答。
    case reasoning(String)
    case toolCall(AIToolCall)
    case finished(AICompletion)
}

/// 模型后端的最小契约：完成一次对话（可带工具调用）。
package protocol AIChatProvider {
    var descriptor: AIChatProviderDescriptor { get }
    func complete(_ request: AIChatRequest) async throws -> AICompletion
    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
}

package extension AIChatProvider {
    /// 默认实现：不支持流式的后端一次性返回，再依次补发事件。
    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let completion = try await complete(request)
                    if !completion.content.isEmpty {
                        continuation.yield(.text(completion.content))
                    }
                    for call in completion.toolCalls {
                        continuation.yield(.toolCall(call))
                    }
                    continuation.yield(.finished(completion))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
