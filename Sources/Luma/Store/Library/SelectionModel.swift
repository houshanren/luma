import Observation
import Foundation

/// 选择状态：从图库内容状态中拆出，避免选中项变化导致所有图库视图重算。
@Observable
final class SelectionModel {
    var ids: Set<UUID> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    func clear() {
        guard !ids.isEmpty else { return }
        ids = []
    }
}
