import Foundation
import LumaDomain

/// 一次工具调用的本地执行结果。
public struct AIToolExecution {
    public let json: String
    public let summary: String?
    public let photoIDs: [UUID]
    public init(
        json: String,
        summary: String?,
        photoIDs: [UUID]
    ) {
        self.json = json
        self.summary = summary
        self.photoIDs = photoIDs
    }
}

/// 一组按源能力注册的 AI 工具：定义与执行都收在 provider 里。
/// 新增电视 / 在线影院 / MCP / 技能时只注册 provider，不再往中央 switch 里加 case。
/// 「是否处理某个工具」由定义列表推导，避免定义、白名单与执行再次各写一份名字。
@MainActor
public struct AIToolProvider {
    public let name: String
    public let definitions: [AIRequestTool]
    private let handler: (AIToolCall, [String: Any]) async -> AIToolExecution

    public init(
        name: String,
        definitions: [AIRequestTool],
        execute: @escaping (AIToolCall, [String: Any]) async -> AIToolExecution
    ) {
        self.name = name
        self.definitions = definitions
        self.handler = execute
    }

    public func handles(_ name: String) -> Bool {
        definitions.contains { $0.name == name }
    }

    public func execute(_ call: AIToolCall, args: [String: Any]) async -> AIToolExecution {
        await handler(call, args)
    }
}

/// 工具注册表：按注册顺序询问 provider，未命中返回 nil 交给兜底 switch。
@MainActor
public final class AIToolRegistry {
    private var providers: [AIToolProvider]

    public init(providers: [AIToolProvider] = []) {
        self.providers = providers
    }

    public var definitions: [AIRequestTool] {
        providers.flatMap(\.definitions)
    }

    public func register(_ provider: AIToolProvider) {
        providers.append(provider)
    }

    public func execute(_ call: AIToolCall, args: [String: Any]) async -> AIToolExecution? {
        for provider in providers where provider.handles(call.name) {
            return await provider.execute(call, args: args)
        }
        return nil
    }
}
