import Foundation
import LumaDomain

/// 模型能力位：用于描述后端能承担的任务，而不是预先绑定某一家厂商。
/// 新增图像理解、图像生成、视频生成等能力时，只扩展这里，不在调用点写 if provider == ...。
public struct AICapability: OptionSet, Hashable, Codable {
    public let rawValue: Int

    /// 文本对话。
    public static let chat = AICapability(rawValue: 1 << 0)
    /// 支持 tools / function calling。
    public static let toolCalling = AICapability(rawValue: 1 << 1)
    /// 请求里可以携带图片。
    public static let vision = AICapability(rawValue: 1 << 2)
    /// 文本向量。
    public static let embedding = AICapability(rawValue: 1 << 3)
    /// 生成图片。
    public static let imageGeneration = AICapability(rawValue: 1 << 4)
    /// 生成视频。
    public static let videoGeneration = AICapability(rawValue: 1 << 5)
    /// 本机运行时（Ollama / LM Studio 等）。
    public static let localRuntime = AICapability(rawValue: 1 << 6)
    public init(
        rawValue: Int
    ) {
        self.rawValue = rawValue
    }
}

/// 模型后端的描述：路由与界面只依赖这份描述，不依赖具体客户端类型。
public struct AIChatProviderDescriptor {
    public var id: String
    public var title: String
    public var capabilities: AICapability
    public var isLocal: Bool
    public init(
        id: String,
        title: String,
        capabilities: AICapability,
        isLocal: Bool
    ) {
        self.id = id
        self.title = title
        self.capabilities = capabilities
        self.isLocal = isLocal
    }
}

public extension AIProvider {
    /// 当前提供商在协议层面能做什么。具体模型是否支持视觉仍由用户选择的模型决定。
    var capabilities: AICapability {
        var result: AICapability = [.chat, .toolCalling]
        if self == .local { result.insert(.localRuntime) }
        if supportsVisionHint != nil { result.insert(.vision) }
        return result
    }
}

public extension AIConfig {
    /// 本次请求实际声明的能力：只有用户开启图片理解时才带视觉。
    var requestCapabilities: AICapability {
        var result = provider.capabilities
        if !includeImages { result.remove(.vision) }
        return result
    }
}
