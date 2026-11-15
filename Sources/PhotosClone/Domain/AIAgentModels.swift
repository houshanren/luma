import Foundation

/// 智能助手支持的提供商：统一走 OpenAI 兼容的 chat/completions 协议。
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case deepseek
    case kimi
    case glm
    case qwen
    case doubao
    case openAI
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .glm: return "GLM（智谱）"
        case .qwen: return "通义千问"
        case .doubao: return "豆包（火山方舟）"
        case .openAI: return "OpenAI"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .openAI: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .kimi: return "moonshot-v1-8k"
        case .glm: return "glm-4-flash"
        case .qwen: return "qwen-plus"
        // 火山方舟使用推理接入点 ID（ep-...），必须由用户自己填写。
        case .doubao: return ""
        case .openAI: return "gpt-4o-mini"
        case .custom: return ""
        }
    }

    /// 常用模型，用户也可以在设置里直接填写其他模型名。
    var models: [String] {
        switch self {
        case .deepseek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .kimi:
            return ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"]
        case .glm:
            return ["glm-4-flash", "glm-4-plus", "glm-4v-flash", "glm-4v-plus"]
        case .qwen:
            return ["qwen-plus", "qwen-max", "qwen-turbo", "qwen-vl-plus", "qwen-vl-max"]
        case .doubao, .custom:
            return []
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]
        }
    }

    /// 是否使用视觉输入需要用户自行选择模型；这里只用于设置页提示。
    var supportsVisionHint: String? {
        switch self {
        case .glm: return "视觉模型：glm-4v-flash / glm-4v-plus"
        case .qwen: return "视觉模型：qwen-vl-plus / qwen-vl-max"
        case .openAI: return "视觉模型：gpt-4o-mini / gpt-4o"
        case .deepseek, .kimi, .doubao, .custom: return nil
        }
    }

    /// Keychain 里的账号名；API Key 只存钥匙串，绝不进入图库或 UserDefaults。
    var keychainAccount: String { "provider.\(rawValue)" }
}

/// 随图库保存的智能助手配置（不含 API Key）。
struct AIConfig: Codable, Equatable {
    var provider: AIProvider = .deepseek
    var model: String = AIProvider.deepseek.defaultModel
    var baseURL: String = AIProvider.deepseek.defaultBaseURL
    /// 是否允许把选中/候选照片压缩后发送给模型；默认关闭，只发本地 Vision 标签与 OCR。
    var includeImages = false
    /// 单次请求最多发送的图片数量。
    var maxImages = 4
    var maxTokens = 1200

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? .deepseek
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? provider.defaultModel
        baseURL = (try? container.decodeIfPresent(String.self, forKey: .baseURL)) ?? provider.defaultBaseURL
        includeImages = (try? container.decodeIfPresent(Bool.self, forKey: .includeImages)) ?? false
        maxImages = (try? container.decodeIfPresent(Int.self, forKey: .maxImages)) ?? 4
        maxTokens = (try? container.decodeIfPresent(Int.self, forKey: .maxTokens)) ?? 1200
        maxImages = min(6, max(1, maxImages))
        maxTokens = min(8000, max(256, maxTokens))
    }
}

/// 一条对话消息；只持久化文字与照片引用，不保存图片数据。
struct AIChatMessage: Codable, Identifiable {
    enum Role: String, Codable {
        case user
        case assistant
        /// 本地执行完工具后的操作回执，不来自模型。
        case action
    }

    var id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
    /// 助手引用到的照片，仅保留仍存在于当前图库中的 ID。
    var photoIDs: [UUID] = []
    /// 助手建议的检索条件。
    var suggestion: AISearchSuggestion?
    var isError = false
}

/// 助手在回答末尾附加的检索建议。
struct AISearchSuggestion: Codable, Equatable {
    var keywords: String?
    var filter: String?
    var photoIDs: [String]?
}

/// 提供给模型的工具定义（OpenAI tools / function calling）。
struct AIRequestTool {
    var name: String
    var description: String
    /// JSON Schema 形式的参数描述。
    var parameters: [String: Any]
}

/// 模型返回的一次工具调用。
struct AIToolCall: Identifiable {
    var id: String
    var name: String
    /// 参数是 JSON 字符串（部分兼容实现会直接给对象，客户端已统一转成字符串）。
    var arguments: String
}

/// 一次模型回复：文本 + 可选工具调用。
struct AICompletion {
    var content: String
    var toolCalls: [AIToolCall]
}

enum AIError: LocalizedError {
    case missingKey
    case invalidBaseURL
    case unauthorized
    case rateLimited
    case server(String)
    case badResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有填写 API Key，请在设置 › 智能助手中填写"
        case .invalidBaseURL:
            return "接口地址无效，请填写 https:// 开头的地址"
        case .unauthorized:
            return "API Key 无效或已过期"
        case .rateLimited:
            return "请求过于频繁或额度不足，请稍后再试"
        case .server(let message):
            return message
        case .badResponse:
            return "模型返回的内容无法解析"
        case .cancelled:
            return "已停止生成"
        }
    }
}
