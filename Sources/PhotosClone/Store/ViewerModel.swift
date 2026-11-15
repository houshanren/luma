import Foundation

/// 查看器 / 编辑器状态：与图库内容状态分离，翻页和打开编辑不会触发图库整体刷新。
final class ViewerModel: ObservableObject {
    @Published var viewerID: UUID?
    @Published var editorID: UUID?
    @Published var showInfoPanel = false
}
