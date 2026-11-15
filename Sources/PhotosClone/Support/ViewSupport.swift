import SwiftUI

extension View {
    /// 按需挂载工具栏搜索框（「位置」页使用自己的搜索框）。
    @ViewBuilder
    func searchableIf(_ condition: Bool, text: Binding<String>, prompt: String) -> some View {
        if condition {
            searchable(text: text, placement: .toolbar, prompt: prompt)
        } else {
            self
        }
    }
}
