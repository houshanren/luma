import Foundation
import LumaDomain
import LumaCore

/// 数据层的日志出口：`LumaPersistence` 不依赖 App 的 `Diagnostics`，
/// 由组合根在启动时把 `Diagnostics.record` 注入进来；未注入时静默丢弃。
public enum PersistenceLog {
    public static var sink: ((String) -> Void)?

    public static func record(_ message: String) {
        sink?(message)
    }
}
