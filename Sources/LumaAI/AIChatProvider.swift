import Foundation
import LumaDomain

/// 发给模型的一条消息：
/// - role = user / system：text 为正文，images 为 data URL；
/// - role = assistant：text 为正文，toolCalls 非空时附带工具调用；
/// - role = tool：text 为工具结果，toolCallID 对应被调用的工具。
public struct AIRequestMessage {
    public var role: String
    public var text: String
    public var images: [String] = []
    public var toolCalls: [AIToolCall]?
    public var toolCallID: String?
    public init(
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
public struct AIChatRequest {
    public var config: AIConfig
    public var apiKey: String
    public var messages: [AIRequestMessage]
    public var tools: [AIRequestTool] = []
    public init(
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

/// 模型后端的最小契约：完成一次对话（可带工具调用）。
public protocol AIChatProvider {
    var descriptor: AIChatProviderDescriptor { get }
    func complete(_ request: AIChatRequest) async throws -> AICompletion
}
