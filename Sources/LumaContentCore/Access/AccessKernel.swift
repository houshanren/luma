import Foundation

// MARK: - 接入渠道

/// 拾光里所有「接入」入口的统一分类：图库、网络云盘、网络影院、网络资源、网络电视。
///
/// 各模块的入口视图、校验报告与任务归属都按这一层对齐，
/// 之后新增接入类型时只需扩展枚举，不必再各自维护一套命名。
public enum AccessChannel: String, CaseIterable, Sendable {
    case library
    case cloud
    case cinema
    case resource
    case television

    public var title: String {
        switch self {
        case .library: return "图库"
        case .cloud: return "网络云盘"
        case .cinema: return "网络影院"
        case .resource: return "网络资源"
        case .television: return "网络电视"
        }
    }
}

// MARK: - 校验结果

/// 单条校验的级别。级别越高越严重，`failed` 会阻止该条源入库。
public enum ValidationLevel: Int, Comparable, Sendable {
    case ok = 0
    case warning = 1
    case failed = 2

    public static func < (lhs: ValidationLevel, rhs: ValidationLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 是否阻止入库。警告只提示，不拦截。
    public var blocksImport: Bool { self == .failed }
}

/// 接入校验中的一项：一段可读文案 + 级别 + 可选的诊断细节。
public struct ValidationCheck: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var level: ValidationLevel
    /// 折叠在文案后面的补充说明，例如接口返回的错误或请求地址。
    public var detail: String?

    public init(id: UUID = UUID(),
                text: String,
                level: ValidationLevel,
                detail: String? = nil) {
        self.id = id
        self.text = text
        self.level = level
        self.detail = detail
    }
}

/// 一次接入校验的完整结果。原有各模块的 `Check[]`、`(ok, message)`、健康状态
/// 都可以收敛到这一层，再由 UI 决定展示多少细节。
public struct ValidationReport: Equatable, Sendable {
    public private(set) var checks: [ValidationCheck]

    public init(_ checks: [ValidationCheck] = []) {
        self.checks = checks
    }

    /// 整体级别取最严重的一项；没有校验项时视为通过。
    public var overall: ValidationLevel {
        checks.map(\.level).max() ?? .ok
    }

    /// 是否阻止入库。
    public var blocksImport: Bool { overall.blocksImport }

    /// 需要用户注意的项（警告与失败）。
    public var issues: [ValidationCheck] {
        checks.filter { $0.level != .ok }
    }

    public var warnings: [ValidationCheck] {
        checks.filter { $0.level == .warning }
    }

    /// 第一条阻塞项优先，其次第一条警告；用于单行状态展示。
    public var summary: String? {
        (checks.first { $0.level == .failed } ?? checks.first { $0.level == .warning })?.text
    }

    public mutating func append(_ check: ValidationCheck) {
        checks.append(check)
    }

    public mutating func append(_ text: String,
                                level: ValidationLevel,
                                detail: String? = nil) {
        checks.append(ValidationCheck(text: text, level: level, detail: detail))
    }
}
