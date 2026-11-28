import Foundation

/// 智能助手支持的提供商：统一走 OpenAI 兼容的 chat/completions 协议。
package enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case deepseek
    case kimi
    case glm
    case qwen
    case doubao
    case openAI
    case openRouter
    case anthropic
    case gemini
    case xai
    case groq
    case mistral
    case siliconFlow
    case hunyuan
    case spark
    case stepFun
    case local
    case custom

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .glm: return "GLM（智谱）"
        case .qwen: return "通义千问"
        case .doubao: return "豆包（火山方舟）"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .anthropic: return "Claude（Anthropic）"
        case .gemini: return "Gemini（Google）"
        case .xai: return "Grok（xAI）"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .siliconFlow: return "硅基流动"
        case .hunyuan: return "腾讯混元"
        case .spark: return "讯飞星火"
        case .stepFun: return "阶跃星辰"
        case .local: return "本地模型"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    package var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .xai: return "https://api.x.ai/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .siliconFlow: return "https://api.siliconflow.cn/v1"
        case .hunyuan: return "https://api.hunyuan.cloud.tencent.com/v1"
        case .spark: return "https://spark-api-open.xf-yun.com/v1"
        case .stepFun: return "https://api.stepfun.com/v1"
        // Ollama 的 OpenAI 兼容端点；LM Studio 默认在 1234 端口。
        case .local: return "http://127.0.0.1:11434/v1"
        case .custom: return ""
        }
    }

    package var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .kimi: return "moonshot-v1-8k"
        case .glm: return "glm-4-flash"
        case .qwen: return "qwen-plus"
        // 火山方舟使用推理接入点 ID（ep-...），必须由用户自己填写。
        case .doubao: return ""
        case .openAI: return "gpt-4o-mini"
        case .openRouter: return "openai/gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-6"
        case .gemini: return "gemini-2.5-flash"
        case .xai: return "grok-4"
        case .groq: return "llama-3.3-70b-versatile"
        case .mistral: return "mistral-large-latest"
        case .siliconFlow: return "deepseek-ai/DeepSeek-V3"
        case .hunyuan: return "hunyuan-turbos-latest"
        case .spark: return "generalv3.5"
        case .stepFun: return "step-2-16k"
        // 本地运行时的模型名由「检测本机运行时」扫描得到。
        case .local: return ""
        case .custom: return ""
        }
    }

    /// 常用模型，用户也可以在设置里直接填写其他模型名。
    package var models: [String] {
        switch self {
        case .deepseek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .kimi:
            return ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k", "kimi-k2-0905-preview"]
        case .glm:
            return ["glm-4-flash", "glm-4-plus", "glm-4v-flash", "glm-4v-plus"]
        case .qwen:
            return ["qwen-plus", "qwen-max", "qwen-turbo", "qwen-vl-plus", "qwen-vl-max"]
        case .doubao, .custom, .local:
            return []
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1",
                    "o4-mini", "o3-mini", "o3", "gpt-5-mini", "gpt-5"]
        case .openRouter:
            return ["openai/gpt-4o-mini", "openai/o4-mini", "openai/gpt-5-mini",
                    "anthropic/claude-sonnet-4", "google/gemini-2.5-flash",
                    "deepseek/deepseek-chat-v3-0324"]
        case .anthropic:
            return ["claude-sonnet-4-6", "claude-opus-5-5", "claude-haiku-4-5",
                    "claude-3-5-haiku-latest"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .xai:
            return ["grok-4", "grok-3", "grok-3-mini"]
        case .groq:
            return ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "qwen/qwen3-32b"]
        case .mistral:
            return ["mistral-large-latest", "mistral-small-latest", "pixtral-large-latest"]
        case .siliconFlow:
            return ["deepseek-ai/DeepSeek-V3", "Qwen/Qwen2.5-72B-Instruct",
                    "Qwen/Qwen2.5-VL-72B-Instruct"]
        case .hunyuan:
            return ["hunyuan-turbos-latest", "hunyuan-t1-latest", "hunyuan-vision-latest"]
        case .spark:
            return ["generalv3.5", "4.0Ultra", "lite"]
        case .stepFun:
            return ["step-2-16k", "step-1-8k", "step-1v-8k"]
        }
    }

    /// 是否使用视觉输入需要用户自行选择模型；这里只用于设置页提示。
    package var supportsVisionHint: String? {
        switch self {
        case .glm: return "视觉模型：glm-4v-flash / glm-4v-plus"
        case .qwen: return "视觉模型：qwen-vl-plus / qwen-vl-max"
        case .openAI: return "视觉模型：gpt-4o-mini / gpt-4o / gpt-5"
        case .openRouter: return "是否支持图片取决于所选模型"
        case .anthropic: return "Claude Sonnet / Opus / Haiku 均支持图片理解"
        case .gemini: return "Gemini 2.5 全系支持图片理解"
        case .xai: return "视觉模型：grok-4"
        case .mistral: return "视觉模型：pixtral-large-latest"
        case .siliconFlow: return "视觉模型：Qwen/Qwen2.5-VL-72B-Instruct"
        case .hunyuan: return "视觉模型：hunyuan-vision-latest"
        case .stepFun: return "视觉模型：step-1v-8k"
        case .local: return "本地模型是否支持图片取决于模型本身（如 llava、qwen2-vl）。"
        case .deepseek, .kimi, .doubao, .groq, .spark, .custom: return nil
        }
    }

    /// 本地运行时不需要 API Key。
    package var requiresAPIKey: Bool { self != .local }

    /// Keychain 里的账号名；API Key 只存钥匙串，绝不进入图库或 UserDefaults。
    package var keychainAccount: String { "provider.\(rawValue)" }
}

/// 写操作审批策略：决定 AI 修改本地数据前是否弹窗。
package enum AIApprovalMode: String, Codable, CaseIterable, Identifiable {
    /// 每次写操作都确认（默认，最安全）。
    case always
    /// 只有删除 / 压缩 / 批量刮削等高风险操作才确认。
    case smart
    /// 全部自动执行，不再弹窗。
    case automatic

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .always: return "每次确认"
        case .smart: return "仅高风险"
        case .automatic: return "自动应用"
        }
    }

    package var detail: String {
        switch self {
        case .always: return "每个写操作都弹窗确认"
        case .smart: return "删除、压缩、批量刮削等才确认，其余直接执行"
        case .automatic: return "不再弹窗，所有写操作直接执行"
        }
    }

    package var symbol: String {
        switch self {
        case .always: return "hand.raised.fill"
        case .smart: return "checkmark.shield.fill"
        case .automatic: return "bolt.badge.automatic.fill"
        }
    }
}

/// 助手会话模式：决定回答深度、工具轮数与上下文规模。
package enum AIMode: String, Codable, CaseIterable, Identifiable {
    /// 快速：少工具、短回答，适合简单问答与单个操作。
    case fast
    /// 标准：按需调用工具，兼顾速度与完整度。
    case balanced
    /// 深度：多轮批量读取与执行，适合整库整理与复杂分析。
    case deep

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .fast: return "快速"
        case .balanced: return "标准"
        case .deep: return "深度"
        }
    }

    package var symbol: String {
        switch self {
        case .fast: return "bolt.fill"
        case .balanced: return "circle.grid.2x2.fill"
        case .deep: return "brain.head.profile"
        }
    }

    package var detail: String {
        switch self {
        case .fast: return "少调工具、直接给结论，最快出结果"
        case .balanced: return "按需检索与执行，速度与完整度平衡"
        case .deep: return "批量读取、多轮核对，适合整库整理"
        }
    }
}

/// 随图库保存的智能助手配置（不含 API Key）。
package struct AIConfig: Codable, Equatable {
    package var provider: AIProvider = .deepseek
    package var model: String = AIProvider.deepseek.defaultModel
    package var baseURL: String = AIProvider.deepseek.defaultBaseURL
    /// 是否允许把选中/候选照片压缩后发送给模型；默认关闭，只发本地 Vision 标签与 OCR。
    package var includeImages = false
    /// 单次请求最多发送的图片数量。
    package var maxImages = 4
    package var maxTokens = 1200
    /// 每次请求附带的最近对话轮数（用户 + 助手各一条算一轮）。
    package var historyRounds = 6
    /// 单次任务允许的最大工具调用轮数：批量整理影院时越大越少来回。
    package var maxToolRounds = 80
    /// 本次会话模式：快速 / 标准 / 深度。
    package var mode: AIMode = .balanced
    /// 写操作审批策略：每次确认 / 仅高风险 / 自动应用。
    package var approval: AIApprovalMode = .always
    /// 当前角色：自动 / 馆员 / 策展 / 影院管理员。
    package var agentRole: AIAgentRole = .auto
    /// 自动角色下，是否允许把只读子任务委派给专门角色。
    package var delegateToSubAgents = true
    /// 诊断用：关掉路由后把全部工具暴露给模型，用来跑「全量 vs 路由」的成本基线。
    package var toolRoutingEnabled = true

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? .deepseek
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? provider.defaultModel
        baseURL = (try? container.decodeIfPresent(String.self, forKey: .baseURL)) ?? provider.defaultBaseURL
        includeImages = (try? container.decodeIfPresent(Bool.self, forKey: .includeImages)) ?? false
        maxImages = (try? container.decodeIfPresent(Int.self, forKey: .maxImages)) ?? 4
        maxTokens = (try? container.decodeIfPresent(Int.self, forKey: .maxTokens)) ?? 1200
        historyRounds = (try? container.decodeIfPresent(Int.self, forKey: .historyRounds)) ?? 6
        maxToolRounds = (try? container.decodeIfPresent(Int.self, forKey: .maxToolRounds)) ?? 80
        mode = (try? container.decodeIfPresent(AIMode.self, forKey: .mode)) ?? .balanced
        approval = (try? container.decodeIfPresent(AIApprovalMode.self, forKey: .approval)) ?? .always
        agentRole = (try? container.decodeIfPresent(AIAgentRole.self, forKey: .agentRole)) ?? .auto
        delegateToSubAgents = (try? container.decodeIfPresent(Bool.self, forKey: .delegateToSubAgents)) ?? true
        toolRoutingEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .toolRoutingEnabled)) ?? true
        maxImages = min(6, max(1, maxImages))
        maxTokens = min(8000, max(256, maxTokens))
        historyRounds = min(40, max(1, historyRounds))
        maxToolRounds = min(300, max(10, maxToolRounds))
    }
    package init() {}

}

/// 一条对话消息；只持久化文字与照片引用，不保存图片数据。
package struct AIChatMessage: Codable, Identifiable {
    package enum Role: String, Codable {
        case user
        case assistant
        /// 本地执行完工具后的操作回执，不来自模型。
        case action
    }

    package var id = UUID()
    package var role: Role
    package var text: String
    package var createdAt = Date()
    /// 助手引用到的照片，仅保留仍存在于当前图库中的 ID。
    package var photoIDs: [UUID] = []
    /// 助手建议的检索条件。
    package var suggestion: AISearchSuggestion?
    package var isError = false
    /// 本次回复耗时（秒）：助手消息页脚展示用。
    package var elapsed: TimeInterval?
    /// 本次回复执行了多少轮工具。
    package var toolSteps: Int?
    /// 多步任务的计划卡；只在计划消息上出现。
    package var plan: AIPlan?
    /// 本次任务产出的成果物：相簿、清单、报告、回忆影片。
    package var artifacts: [AIArtifact] = []
    /// 结构化错误码；错误卡据此给出重试 / 设置入口。
    package var errorCode: AIErrorCode?
    /// 任务 ID：撤销、审计与执行轨迹按任务归组。
    package var taskID: UUID?
    /// 影院 / 资源 / 网络影院 / 电视的结果卡：回答里直接能看、能点开。
    package var previews: [AIResultPreview] = []
    /// 模型返回的思考摘要（部分端点提供 reasoning）：默认折叠展示。
    package var reasoning: String?
    /// 本轮请求的输入 token（端点返回 usage 时才有）。
    package var promptTokens: Int?
    /// 本轮回复的输出 token。
    package var completionTokens: Int?

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        role = (try? container.decodeIfPresent(Role.self, forKey: .role)) ?? .assistant
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        photoIDs = (try? container.decodeIfPresent([UUID].self, forKey: .photoIDs)) ?? []
        suggestion = try? container.decodeIfPresent(AISearchSuggestion.self, forKey: .suggestion)
        isError = (try? container.decodeIfPresent(Bool.self, forKey: .isError)) ?? false
        elapsed = try? container.decodeIfPresent(TimeInterval.self, forKey: .elapsed)
        toolSteps = try? container.decodeIfPresent(Int.self, forKey: .toolSteps)
        plan = try? container.decodeIfPresent(AIPlan.self, forKey: .plan)
        artifacts = (try? container.decodeIfPresent([AIArtifact].self, forKey: .artifacts)) ?? []
        errorCode = try? container.decodeIfPresent(AIErrorCode.self, forKey: .errorCode)
        taskID = try? container.decodeIfPresent(UUID.self, forKey: .taskID)
        previews = (try? container.decodeIfPresent([AIResultPreview].self, forKey: .previews)) ?? []
        reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        promptTokens = try? container.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try? container.decodeIfPresent(Int.self, forKey: .completionTokens)
    }
    package init(role: Role,
         text: String,
         photoIDs: [UUID] = [],
         suggestion: AISearchSuggestion? = nil,
         isError: Bool = false,
         elapsed: TimeInterval? = nil,
         toolSteps: Int? = nil,
         plan: AIPlan? = nil,
         artifacts: [AIArtifact] = [],
         errorCode: AIErrorCode? = nil,
         taskID: UUID? = nil,
         previews: [AIResultPreview] = [],
         reasoning: String? = nil,
         promptTokens: Int? = nil,
         completionTokens: Int? = nil) {
        self.role = role
        self.text = text
        self.photoIDs = photoIDs
        self.suggestion = suggestion
        self.isError = isError
        self.elapsed = elapsed
        self.toolSteps = toolSteps
        self.plan = plan
        self.artifacts = artifacts
        self.errorCode = errorCode
        self.taskID = taskID
        self.previews = previews
        self.reasoning = reasoning
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

}

/// 助手在回答末尾附加的检索建议。
package struct AISearchSuggestion: Codable, Equatable {
    package var keywords: String?
    package var filter: String?
    package var photoIDs: [String]?
    package init(
        keywords: String? = nil,
        filter: String? = nil,
        photoIDs: [String]? = nil
    ) {
        self.keywords = keywords
        self.filter = filter
        self.photoIDs = photoIDs
    }
}

/// 提供给模型的工具定义（OpenAI tools / function calling）。
package struct AIRequestTool {
    package var name: String
    package var description: String
    /// JSON Schema 形式的参数描述。
    package var parameters: [String: Any]
    package init(
        name: String,
        description: String,
        parameters: [String: Any]
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// 模型返回的一次工具调用。
package struct AIToolCall: Identifiable {
    package var id: String
    package var name: String
    /// 参数是 JSON 字符串（部分兼容实现会直接给对象，客户端已统一转成字符串）。
    package var arguments: String
    package init(
        id: String,
        name: String,
        arguments: String
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 一次模型回复：文本 + 可选工具调用。
package struct AICompletion {
    package var content: String
    package var toolCalls: [AIToolCall]
    /// 部分端点返回的思考摘要（reasoning_content）。
    package var reasoning: String?
    /// 端点返回的 token 用量；不返回时为 nil。
    package var promptTokens: Int?
    package var completionTokens: Int?
    package init(
        content: String,
        toolCalls: [AIToolCall],
        reasoning: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

package enum AIError: LocalizedError {
    case missingKey
    case invalidBaseURL
    case unauthorized
    case rateLimited
    case server(String)
    case badResponse
    case cancelled

    package var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有填写 API Key，请在设置 › 助手中填写"
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

    /// 错误卡使用的结构化错误码。
    package var code: AIErrorCode {
        switch self {
        case .missingKey: return .missingKey
        case .invalidBaseURL: return .invalidBaseURL
        case .unauthorized: return .unauthorized
        case .rateLimited: return .rateLimited
        case .badResponse: return .badResponse
        case .cancelled: return .cancelled
        case .server(let message):
            return message.contains("网络请求失败") ? .network : .server
        }
    }
}
