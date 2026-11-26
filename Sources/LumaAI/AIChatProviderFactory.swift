import Foundation
import LumaDomain

/// 模型后端工厂：把配置解析成具体 provider。
/// 以后接入本机推理、MCP 托管模型或其它协议时，只在这里增加分支。
public enum AIChatProviderFactory {
    public static func make(config: AIConfig) -> any AIChatProvider {
        OpenAICompatibleChatProvider(config: config)
    }
}
