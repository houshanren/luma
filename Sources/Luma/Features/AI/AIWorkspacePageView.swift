import SwiftUI

/// 助手工作台：左侧菜单里的独立一页，整幅对话。
/// 与并排 / 叠放 / 浮窗共用同一段会话；关闭或 ⌘J 回到进入前的页面，选择与搜索不丢。
struct AIWorkspacePageView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        AIAssistantView(presentation: .workspace,
                        onClose: { store.hideAISurface() },
                        onExpand: { store.expandAISurface() },
                        onCollapse: { store.dockAISurface() },
                        fillContainer: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
