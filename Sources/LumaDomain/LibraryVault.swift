import Foundation

/// 图库保险库清单：记录 originals / database / renders 的相对路径、大小与 SHA-256。
/// 清单写在备份目录根部，恢复时只依赖清单，不读取任何第三方索引。
public struct VaultManifest: Codable {
    public var version: Int = 1
    public var libraryName: String
    public var createdAt: Date
    public var entries: [VaultEntry]

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    public init(
        version: Int = 1,
        libraryName: String,
        createdAt: Date,
        entries: [VaultEntry]
    ) {
        self.version = version
        self.libraryName = libraryName
        self.createdAt = createdAt
        self.entries = entries
    }
}

public struct VaultEntry: Codable, Identifiable, Hashable {
    /// 相对图库根目录的路径，例如 `originals/a/<uuid>.heic`。
    public var path: String
    public var size: Int64
    public var sha256: String

    public var id: String { path }
    public init(
        path: String,
        size: Int64,
        sha256: String
    ) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

public enum VaultIssueKind: String, Codable {
    case missing
    case modified
    case extra

    public var title: String {
        switch self {
        case .missing: return "缺失"
        case .modified: return "损坏"
        case .extra: return "多余"
        }
    }
}

public struct VaultIssue: Identifiable, Hashable {
    public let id: String
    public let kind: VaultIssueKind
    public let path: String
    public let detail: String

    public init(kind: VaultIssueKind, path: String, detail: String) {
        self.id = "\(kind.rawValue)|\(path)"
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

public struct VaultReport {
    public let createdAt: Date
    public let manifestCreatedAt: Date
    public let checked: Int
    public let issues: [VaultIssue]

    public var missingCount: Int { issues.filter { $0.kind == .missing }.count }
    public var modifiedCount: Int { issues.filter { $0.kind == .modified }.count }
    public var extraCount: Int { issues.filter { $0.kind == .extra }.count }
    public var isHealthy: Bool { issues.isEmpty }
    public init(
        createdAt: Date,
        manifestCreatedAt: Date,
        checked: Int,
        issues: [VaultIssue]
    ) {
        self.createdAt = createdAt
        self.manifestCreatedAt = manifestCreatedAt
        self.checked = checked
        self.issues = issues
    }
}

public struct VaultProgress {
    public enum Phase: String {
        case scanning = "扫描"
        case backingUp = "备份"
        case verifying = "校验"
        case restoring = "恢复"
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int
    public var bytes: Int64
    public var message: String

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
    public init(
        phase: Phase,
        completed: Int,
        total: Int,
        bytes: Int64,
        message: String
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.bytes = bytes
        self.message = message
    }
}
