import Foundation

/// 外部 AI 能力接入的统一契约。
/// 实现方只负责把自己的能力注册成工具来源，写操作仍然经过 `AIToolRegistry` 与审批流程。
/// MCP / 技能 / 快捷指令都从这里进入，不直接改图库或播放状态。
@MainActor
protocol AIIntegration {
    /// 把自己能力转成工具 provider 注册进统一注册表。
    func registerTools(into registry: AIToolRegistry, store: LibraryStore)
    /// 附加到系统提示词的内容（技能说明、MCP 提示模板等）；默认没有。
    func systemPromptAdditions(store: LibraryStore) -> [String]
}

extension AIIntegration {
    func systemPromptAdditions(store: LibraryStore) -> [String] { [] }
}

extension LibraryStore {
    /// 注册一个外部能力来源（MCP / 技能 / 快捷指令）。
    /// 工具定义与执行随注册进入统一注册表，不新增中央 switch 分支。
    func registerAIIntegration(_ integration: any AIIntegration) {
        aiIntegrations.append(integration)
        integration.registerTools(into: aiToolRegistry, store: self)
    }
}
