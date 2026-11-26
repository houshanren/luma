import Foundation

/// 图库保险库清单：记录 originals / database / renders 的相对路径、大小与 SHA-256。
/// 清单写在备份目录根部，恢复时只依赖清单，不读取任何第三方索引。
package struct VaultManifest: Codable {
    package var version: Int = 1
    package var libraryName: String
    package var createdAt: Date
    package var entries: [VaultEntry]

    package var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    package init(
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

package struct VaultEntry: Codable, Identifiable, Hashable {
    /// 相对图库根目录的路径，例如 `originals/a/<uuid>.heic`。
    package var path: String
    package var size: Int64
    package var sha256: String

    package var id: String { path }
    package init(
        path: String,
        size: Int64,
        sha256: String
    ) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

package enum VaultIssueKind: String, Codable {
    case missing
    case modified
    case extra

    package var title: String {
        switch self {
        case .missing: return "缺失"
        case .modified: return "损坏"
        case .extra: return "多余"
        }
    }
}

package struct VaultIssue: Identifiable, Hashable {
    package let id: String
    package let kind: VaultIssueKind
    package let path: String
    package let detail: String

    package init(kind: VaultIssueKind, path: String, detail: String) {
        self.id = "\(kind.rawValue)|\(path)"
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

package struct VaultReport {
    package let createdAt: Date
    package let manifestCreatedAt: Date
    package let checked: Int
    package let issues: [VaultIssue]

    package var missingCount: Int { issues.filter { $0.kind == .missing }.count }
    package var modifiedCount: Int { issues.filter { $0.kind == .modified }.count }
    package var extraCount: Int { issues.filter { $0.kind == .extra }.count }
    package var isHealthy: Bool { issues.isEmpty }
    package init(
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

package struct VaultProgress {
    package enum Phase: String {
        case scanning = "扫描"
        case backingUp = "备份"
        case verifying = "校验"
        case restoring = "恢复"
    }

    package var phase: Phase
    package var completed: Int
    package var total: Int
    package var bytes: Int64
    package var message: String

    package var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
    package init(
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
