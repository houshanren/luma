import Foundation
import LumaDomain

/// 一次工具调用的本地执行结果。
package struct AIToolExecution {
    package let json: String
    package let summary: String?
    package let photoIDs: [UUID]
    package init(
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
package struct AIToolProvider {
    package let name: String
    package let definitions: [AIRequestTool]
    private let handler: (AIToolCall, [String: Any]) async -> AIToolExecution

    package init(
        name: String,
        definitions: [AIRequestTool],
        execute: @escaping (AIToolCall, [String: Any]) async -> AIToolExecution
    ) {
        self.name = name
        self.definitions = definitions
        self.handler = execute
    }

    package func handles(_ name: String) -> Bool {
        definitions.contains { $0.name == name }
    }

    package func execute(_ call: AIToolCall, args: [String: Any]) async -> AIToolExecution {
        await handler(call, args)
    }
}

/// 工具注册表：按注册顺序询问 provider，未命中返回 nil 交给兜底 switch。
@MainActor
package final class AIToolRegistry {
    private var providers: [AIToolProvider]

    package init(providers: [AIToolProvider] = []) {
        self.providers = providers
    }

    package var definitions: [AIRequestTool] {
        providers.flatMap(\.definitions)
    }

    package func register(_ provider: AIToolProvider) {
        providers.append(provider)
    }

    package func execute(_ call: AIToolCall, args: [String: Any]) async -> AIToolExecution? {
        for provider in providers where provider.handles(call.name) {
            return await provider.execute(call, args: args)
        }
        return nil
    }
}
