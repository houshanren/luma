import Combine
import Foundation

/// 窗口级瞬时 UI 状态：目前只有提示条（toast）。
///
/// 这类值变化频繁且与内容无关。放在 `LibraryStore` 里时，任何一次提示都会让
/// 92 个观察该 Store 的文件一起重算；需要提示的视图只观察这一份小模型即可。
@MainActor
final class ChromeModel: ObservableObject {
    @Published var toast: String?

    /// 提示条的自动消失任务也登记在统一任务中心。
    private let tasks = StoreTaskCenter()

    /// 展示 2.2 秒后自动消失；连续提示会重置计时。
    func showToast(_ message: String) {
        toast = message
        tasks.adopt(.toast, Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        })
    }
}
