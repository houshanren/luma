import Foundation

/// 命令行断言记录器：两个检查 target 共用，避免各自维护一份 `failures` 计数。
public final class CheckRecorder {
    public static let shared = CheckRecorder()

    public private(set) var failures = 0

    public init() {}

    public func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)")
        }
    }

    /// 汇总失败项并以非零码退出。
    public func finish() {
        if failures > 0 {
            print("\n\(failures) 项检查失败")
            exit(1)
        }
        print("\n全部检查通过")
    }
}

public func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    CheckRecorder.shared.expect(condition(), message)
}

public func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    expect(lhs == rhs, "\(message)（实际 \(lhs)，期望 \(rhs)）")
}

public func expectClose(_ lhs: CGFloat, _ rhs: CGFloat, accuracy: CGFloat, _ message: String) {
    expect(abs(lhs - rhs) <= accuracy, "\(message)（实际 \(lhs)，期望 \(rhs)）")
}
