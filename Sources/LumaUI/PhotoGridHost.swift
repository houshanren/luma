import SwiftUI
import Observation
import LumaDomain

/// 网格组件与宿主之间的唯一交互面。
///
/// 组件层（`PhotoCell` / 各类网格 / 框选）只读这里的展示参数并回调这里的动作，
/// 不直接持有 `LibraryStore`、`AppSettings` 或 `SelectionModel`。
/// 具体实现由组合根在启动时填好并注入给视图树。这里用 `@Observable`：
/// 视图按实际读到的属性建立依赖，堆叠数据变化时由桥接重新赋值对应闭包触发刷新，
/// 不再让一次广播把所有网格消费者一起重算。
@MainActor
@Observable
package final class PhotoGridHost {
    // MARK: 展示参数

    /// 网格目标单元格边长（跟随工具栏缩放）。
    package var thumbSize: Double = 160
    /// 小封面圆角。
    package var smallCoverRadius: CGFloat = 6
    /// 强调色（悬停描边、光晕）。
    package var accentColor: Color = .accentColor
    /// 缩略图信息浮层开关。
    package var metadata = MetadataOptions()
    /// 悬停动效。
    package var hoverAnimation: Animation?
    /// 布局 / 切换动效。
    package var layoutAnimation: Animation?
    /// 双击打开方式。
    package var photoOpenMode: PhotoOpenMode = .viewer

    // MARK: 选中

    package var selectedIDs: Set<UUID> = []

    // MARK: 堆叠

    package var stackBadges: () -> [UUID: PhotoStackBadge] = { [:] }
    package var isStackExpanded: (UUID) -> Bool = { _ in false }
    package var stackCount: (UUID) -> Int = { _ in 1 }
    package var toggleStackExpansion: (UUID) -> Void = { _ in }

    // MARK: 交互

    package var handleTap: (UUID) -> Void = { _ in }
    package var setSelectionAnchor: (UUID) -> Void = { _ in }
    package var setSelectedIDs: (Set<UUID>) -> Void = { _ in }
    package var clearSelection: () -> Void = {}
    package var openPhoto: (UUID, PhotoOpenMode) -> Void = { _, _ in }
    package var openViewer: (UUID, [PhotoItem]) -> Void = { _, _ in }
    /// 拖拽落在某个格子上：返回是否已处理（相簿 / 系统相簿内排序）。
    package var handleCellDrop: ([NSItemProvider], UUID, Bool) -> Bool = { _, _, _ in false }
    /// 照片右键菜单（菜单实现留在 App 侧，组件只负责挂载）。
    package var contextMenu: (PhotoItem, Set<UUID>) -> AnyView = { _, _ in
        AnyView(EmptyView())
    }

    package init() {}
}
