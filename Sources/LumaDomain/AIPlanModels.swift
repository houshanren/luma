import Foundation

/// AI 写操作的风险等级。决定审批方式与是否默认自动执行。
package enum AIRiskLevel: String, Codable, CaseIterable, Identifiable {
    /// 只读：检索、读取详情、查看节目单。
    case read
    /// 可逆写：评分、旗标、色标、关键词、标题、相簿加入 / 移出。
    case reversible
    /// 破坏性 / 批量：删除、压缩原文件、批量刮削、清空进度。
    case destructive
    /// 外部副作用：请求站点、下载、打开外链、播放。
    case external

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .read: return "只读"
        case .reversible: return "可逆"
        case .destructive: return "高风险"
        case .external: return "外部"
        }
    }

    package var symbol: String {
        switch self {
        case .read: return "eye"
        case .reversible: return "arrow.uturn.backward"
        case .destructive: return "exclamationmark.triangle"
        case .external: return "arrow.up.right.square"
        }
    }

    package var isWrite: Bool { self != .read }
}

/// 计划里的一步：用户先看做什么、影响什么、风险多大。
package struct AIPlanStep: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var title: String
    package var detail: String
    package var tool: String?
    package var risk: AIRiskLevel

    package init(title: String,
                 detail: String = "",
                 tool: String? = nil,
                 risk: AIRiskLevel = .read) {
        self.title = title
        self.detail = detail
        self.tool = tool
        self.risk = risk
    }
}

package enum AIPlanStatus: String, Codable {
    case pending
    case approved
    case cancelled
}

/// 多步任务的计划卡。
package struct AIPlan: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var summary: String
    package var steps: [AIPlanStep]
    package var status: AIPlanStatus = .pending
    package var createdAt = Date()

    package init(summary: String,
                 steps: [AIPlanStep],
                 status: AIPlanStatus = .pending) {
        self.summary = summary
        self.steps = steps
        self.status = status
    }

    package var writeStepCount: Int { steps.filter(\.risk.isWrite).count }
    package var highestRisk: AIRiskLevel {
        steps.map(\.risk).max { lhs, rhs in
            Self.rank(lhs) < Self.rank(rhs)
        } ?? .read
    }

    private static func rank(_ risk: AIRiskLevel) -> Int {
        switch risk {
        case .read: return 0
        case .reversible: return 1
        case .external: return 2
        case .destructive: return 3
        }
    }
}

/// 对话产出的可保存对象：相簿、片单、清理清单、报告、回忆影片。
package enum AIArtifactKind: String, Codable {
    case album
    case playlist
    case cleanupList
    case report
    case memoryMovie
    case cinemaReport
    case unknown

    package var title: String {
        switch self {
        case .album: return "相簿"
        case .playlist: return "片单"
        case .cleanupList: return "清理清单"
        case .report: return "报告"
        case .memoryMovie: return "回忆影片"
        case .cinemaReport: return "影院报告"
        case .unknown: return "成果"
        }
    }

    package var symbol: String {
        switch self {
        case .album: return "rectangle.stack.badge.plus"
        case .playlist: return "music.note.list"
        case .cleanupList: return "trash.slash"
        case .report: return "doc.text.magnifyingglass"
        case .memoryMovie: return "film.stack"
        case .cinemaReport: return "popcorn"
        case .unknown: return "shippingbox"
        }
    }
}

package struct AIArtifact: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var kind: AIArtifactKind
    package var title: String
    package var detail: String
    package var count: Int
    package var photoIDs: [UUID]
    package var albumID: UUID?
    package var createdAt = Date()

    package init(kind: AIArtifactKind,
                 title: String,
                 detail: String = "",
                 count: Int = 0,
                 photoIDs: [UUID] = [],
                 albumID: UUID? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.count = count
        self.photoIDs = photoIDs
        self.albumID = albumID
    }
}

/// 跨对话保留的长期偏好。按图库保存，只作为「偏好」注入，不覆盖当前指令。
package struct AIMemoryNote: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var text: String
    package var isEnabled = true
    package var createdAt = Date()
    package var updatedAt = Date()

    package init(text: String, isEnabled: Bool = true) {
        self.text = text
        self.isEnabled = isEnabled
    }
}

/// 上下文胶囊：让用户看见模型这次到底带了什么。
package enum AIContextKind: String, Codable, CaseIterable, Identifiable {
    case range
    case selection
    case search
    case cinema
    case viewer
    case clipboard
    case mention

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .range: return "当前范围"
        case .selection: return "选中"
        case .search: return "搜索"
        case .cinema: return "影院"
        case .viewer: return "查看器"
        case .clipboard: return "剪贴板"
        case .mention: return "指认"
        }
    }

    package var symbol: String {
        switch self {
        case .range: return "square.stack.3d.up"
        case .selection: return "cursorarrow.rays"
        case .search: return "magnifyingglass"
        case .cinema: return "film.stack"
        case .viewer: return "photo"
        case .clipboard: return "doc.on.clipboard"
        case .mention: return "at"
        }
    }
}

package struct AIContextCapsule: Identifiable, Equatable {
    package var id: String { kind.rawValue }
    package var kind: AIContextKind
    package var title: String
    package var detail: String
    package var isEnabled: Bool

    package init(kind: AIContextKind,
                 title: String,
                 detail: String = "",
                 isEnabled: Bool = true) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isEnabled = isEnabled
    }
}

package enum AIToolStepStatus: String, Codable {
    case running
    case done
    case failed
}

/// 执行时间线的一步：运行中实时追加，结束后保留。
package struct AIToolStep: Identifiable, Equatable {
    package var id = UUID()
    package var title: String
    package var detail: String
    package var status: AIToolStepStatus
    package var startedAt = Date()
    package var duration: TimeInterval?

    package init(title: String,
                 detail: String = "",
                 status: AIToolStepStatus = .running) {
        self.title = title
        self.detail = detail
        self.status = status
    }
}

package enum AIErrorCode: String, Codable {
    case missingKey
    case invalidBaseURL
    case unauthorized
    case rateLimited
    case network
    case server
    case badResponse
    case toolFailed
    case permission
    case cancelled
    case unknown

    package var title: String {
        switch self {
        case .missingKey: return "缺少 API Key"
        case .invalidBaseURL: return "接口地址无效"
        case .unauthorized: return "凭据无效"
        case .rateLimited: return "请求过于频繁"
        case .network: return "网络不可用"
        case .server: return "服务端错误"
        case .badResponse: return "返回无法解析"
        case .toolFailed: return "工具执行失败"
        case .permission: return "没有权限"
        case .cancelled: return "已停止"
        case .unknown: return "未知错误"
        }
    }
}

package struct AIApprovalItem: Identifiable, Equatable {
    package var id: String
    package var title: String
    package var detail: String
    package var risk: AIRiskLevel

    package init(id: String,
                 title: String,
                 detail: String = "",
                 risk: AIRiskLevel) {
        self.id = id
        self.title = title
        self.detail = detail
        self.risk = risk
    }
}

package struct AIApprovalRequest: Identifiable, Equatable {
    package var id = UUID()
    package var title: String
    package var summary: String
    package var items: [AIApprovalItem]
    package var allowsTaskScope: Bool
    /// 本轮涉及的工具名；「始终允许」只记住其中可记忆的部分。
    package var toolNames: [String]
    /// 可被「始终允许」记住的工具：可逆写，不含外部连接器与高风险操作。
    package var memorableToolNames: [String]

    package init(title: String,
                 summary: String = "",
                 items: [AIApprovalItem],
                 allowsTaskScope: Bool = true,
                 toolNames: [String] = [],
                 memorableToolNames: [String] = []) {
        self.title = title
        self.summary = summary
        self.items = items
        self.allowsTaskScope = allowsTaskScope
        self.toolNames = toolNames
        self.memorableToolNames = memorableToolNames
    }

    package var highestRisk: AIRiskLevel {
        items.map(\.risk).max { lhs, rhs in
            Self.rank(lhs) < Self.rank(rhs)
        } ?? .read
    }

    private static func rank(_ risk: AIRiskLevel) -> Int {
        switch risk {
        case .read: return 0
        case .reversible: return 1
        case .external: return 2
        case .destructive: return 3
        }
    }
}

package enum AIApprovalDecision: String {
    case allowOnce
    case allowTask
    /// 记住本轮可记忆的工具，之后同类写操作不再确认。
    case allowAlways
    case deny
}

/// 对话里渲染的模块内容卡。照片走缩略图条，其余四个模块走这里。
package enum AIResultDomain: String, Codable, CaseIterable {
    case photo
    case cinema
    case catalog
    case networkCinema
    case tv

    package var title: String {
        switch self {
        case .photo: return "图库"
        case .cinema: return "影院"
        case .catalog: return "网络资源"
        case .networkCinema: return "网络影院"
        case .tv: return "网络电视"
        }
    }

    package var symbol: String {
        switch self {
        case .photo: return "photo.stack"
        case .cinema: return "popcorn"
        case .catalog: return "antenna.radiowaves.left.and.right"
        case .networkCinema: return "play.rectangle.on.rectangle"
        case .tv: return "tv"
        }
    }

    /// 影片海报是竖版，频道与资源是横版。
    package var isPortrait: Bool { self == .cinema || self == .networkCinema }
}

/// 助手角色：单一入口下的人格与工具边界。
/// `.auto` 放开全部；其余角色只看自己领域的工具，避免跨模块误操作。
package enum AIAgentRole: String, Codable, CaseIterable, Identifiable {
    case auto
    case librarian
    case curator
    case cinemaManager

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .auto: return "自动"
        case .librarian: return "馆员"
        case .curator: return "策展"
        case .cinemaManager: return "影院管理员"
        }
    }

    package var symbol: String {
        switch self {
        case .auto: return "sparkles"
        case .librarian: return "books.vertical"
        case .curator: return "paintpalette"
        case .cinemaManager: return "popcorn"
        }
    }

    package var summary: String {
        switch self {
        case .auto: return "自动判断领域，可把只读子任务委派给专门角色"
        case .librarian: return "检索、归类、相簿与元数据"
        case .curator: return "主题、故事线与回忆影片"
        case .cinemaManager: return "影片识别、刮削、片单与进度"
        }
    }

    package var systemAddition: String {
        switch self {
        case .auto:
            return "你可以根据问题自动切换领域，也可以在跨模块任务里把只读子任务委派给专门角色。"
        case .librarian:
            return "你是图库馆员：擅长检索、归类、相簿、评分与元数据。只使用图库相关工具，"
                + "不要越界操作影院、网络资源或电视。"
        case .curator:
            return "你是策展人：擅长从照片里发现主题、组织故事线与回忆影片。先给结构再动手，"
                + "不要为了凑数而修改照片元数据。"
        case .cinemaManager:
            return "你是影院管理员：擅长识别影片、匹配元数据、整理片单与播放进度。"
                + "批量刮削与写回前先说明影响范围。"
        }
    }

    /// 当前角色是否允许调用某个工具。
    package func allows(toolName name: String) -> Bool {
        if name == "delegate_agent" { return true }
        // 外部连接器只在「自动」角色下出现，避免专门角色被第三方工具带偏。
        if name.hasPrefix("mcp__") { return self == .auto }
        switch self {
        case .auto:
            return true
        case .librarian, .curator:
            return !Self.isMediaTool(name)
        case .cinemaManager:
            return Self.isMediaTool(name) || Self.coreToolNames.contains(name)
        }
    }

    package static func isMediaTool(_ name: String) -> Bool {
        name.contains("cinema") || name.contains("catalog")
            || name.hasPrefix("tv_") || name.contains("_tv_")
            || name.hasPrefix("favorite_tv")
    }

    package static let coreToolNames: Set<String> = [
        "search_photos", "unified_search", "get_photo_info", "navigate",
        "select_photos", "open_photo", "open_search_result"
    ]
}

/// 工具结果里可展示的一条内容：标题、副标题、海报、点击目标。
package struct AIResultPreview: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var domain: AIResultDomain
    package var title: String
    package var subtitle: String
    package var imageURL: String?
    package var photoID: UUID?
    package var targetID: String?

    package init(domain: AIResultDomain,
                 title: String,
                 subtitle: String = "",
                 imageURL: String? = nil,
                 photoID: UUID? = nil,
                 targetID: String? = nil) {
        self.domain = domain
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.photoID = photoID
        self.targetID = targetID
    }
}
