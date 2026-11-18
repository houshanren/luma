import Foundation

/// 检索范围：拾光本地库 / 系统「照片」图库 / 网络存储。
enum RetrievalScope: String {
    case local
    case system
    case cloud

    var title: String {
        switch self {
        case .local: return "拾光图库"
        case .system: return "系统图库"
        case .cloud: return "网络存储"
        }
    }
}

/// 一条检索结果。分数只用于排序，不对外展示。
struct RetrievalHit: Identifiable, Hashable {
    let id: UUID
    let score: Double
    let lexicalScore: Double
    let semanticScore: Double
    let title: String
    let snippet: String
    let capturedAt: Date
}

/// 一次检索的完整结果，附带统计信息用于回答里的「依据」说明。
struct RetrievalOutcome {
    var hits: [RetrievalHit] = []
    var tokens: [String] = []
    var scope: RetrievalScope = .local
    var indexTotal: Int = 0
    var usedVector: Bool = false
}

/// 标签治理里的一条建议。
enum TagIssueKind: String, CaseIterable {
    case duplicate
    case nearDuplicate
    case unmapped

    var title: String {
        switch self {
        case .duplicate: return "重复标签"
        case .nearDuplicate: return "相似标签"
        case .unmapped: return "可归入标准标签"
        }
    }

    var detail: String {
        switch self {
        case .duplicate: return "大小写、空格或全半角不同，实际是同一个词"
        case .nearDuplicate: return "拼写只差一个字符，多半是手误"
        case .unmapped: return "端侧标签目录里有同名标准词，统一后语义检索更准"
        }
    }
}

enum TagFix: Hashable {
    case merge(from: String, to: String)
    case rename(from: String, to: String)
    case delete(String)
}

struct TagIssue: Identifiable, Hashable {
    let id: String
    let kind: TagIssueKind
    let tags: [String]
    let count: Int
    let fix: TagFix
}
