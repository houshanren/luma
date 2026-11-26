import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaContentCore

/// 只读图库不加拖拽：避免出现"能拖但拖不动"的假入口。
struct SidebarAlbumDragModifier: ViewModifier {
    let enabled: Bool
    let provider: () -> NSItemProvider

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag(provider)
        } else {
            content
        }
    }
}
