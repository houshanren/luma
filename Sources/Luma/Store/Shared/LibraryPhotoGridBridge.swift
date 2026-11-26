import SwiftUI
import Observation
import LumaUI

/// 把 `LibraryStore` / `AppSettings` / `SelectionModel` 接到 LumaUI 的网格组件上。
///
/// 组件只认 `PhotoGridHost` 这一份数据与闭包；这里负责在三个源变化后刷新一次值拷贝，
/// 并广播 `objectWillChange`。缩略图档位、`GridLayout` 列数与 Lazy 容器都不变，
/// 因此不改变原有的布局与取图路径。
@MainActor
final class LibraryPhotoGridBridge: ObservableObject {
    let host = PhotoGridHost()

    private let store: LibraryStore
    private let settings: AppSettings
    private let selection: SelectionModel
    /// 上一次广播的网格参数快照：相同就不必再通知单元格重算。
    private var lastSnapshot: Snapshot?

    init(store: LibraryStore, settings: AppSettings, selection: SelectionModel) {
        self.store = store
        self.settings = settings
        self.selection = selection

        host.stackBadges = { [weak store] in
            guard let store else { return [:] }
            return store.stackBadges().mapValues {
                PhotoStackBadge(count: $0.count, isBurst: $0.isBurst)
            }
        }
        host.isStackExpanded = { [weak store] in store?.isStackExpanded($0) ?? false }
        host.stackCount = { [weak store] in store?.stackCount(for: $0) ?? 1 }
        host.toggleStackExpansion = { [weak store] in store?.toggleStackExpansion($0) }
        host.handleTap = { [weak store] in store?.handleTap($0) }
        host.setSelectionAnchor = { [weak store] in store?.selectionAnchorID = $0 }
        host.setSelectedIDs = { [weak selection] in selection?.ids = $0 }
        host.clearSelection = { [weak store] in store?.clearSelection() }
        host.openPhoto = { [weak store] id, mode in store?.openPhoto(id, by: mode) }
        host.openViewer = { [weak store] id, context in store?.openViewer(id, context: context) }
        host.handleCellDrop = { [weak store] providers, targetID, after in
            guard let store else { return false }
            // 系统相簿：拖拽改顺序，经 PhotoKit 写回「照片」。
            if let systemAlbumID = store.currentSystemAlbumID {
                PhotoDrag.loadIDs(from: providers) { ids in
                    guard !ids.isEmpty, !ids.contains(targetID) else { return }
                    Task { @MainActor in
                        store.moveSystemPhotos(Set(ids),
                                               inSystemAlbum: systemAlbumID,
                                               before: targetID,
                                               after: after)
                    }
                }
                return true
            }
            guard let albumID = store.currentAlbumID else { return false }
            PhotoDrag.loadIDs(from: providers) { ids in
                guard let draggedID = ids.first, draggedID != targetID else { return }
                Task { @MainActor in
                    store.moveAlbumPhotos(albumID: albumID,
                                          moving: Set(ids),
                                          targetID: targetID,
                                          after: after)
                }
            }
            return true
        }
        host.contextMenu = { photo, ids in
            AnyView(PhotoContextMenu(photo: photo, actionIDs: ids))
        }

        // Store / 设置 / 选择模型都已是 @Observable：用 Observation 追踪真正参与网格的参数，
        // 不再「任何属性变化都转发一次」。每次变化后重新挂上追踪。
        trackObservableState()
        refresh()
    }

    private func trackObservableState() {
        withObservationTracking {
            _ = store.thumbSize
            _ = store.stackRevision
            _ = selection.ids
            _ = settings.smallCoverRadius
            _ = settings.accentColor
            _ = settings.metadata
            _ = settings.photoOpenMode
            _ = settings.motion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.trackObservableState()
            }
        }
    }

    private func refresh() {
        // 只有真正影响网格渲染的值变了才广播：Store 里还有几百个与网格无关的
        // @Published（toast / 面板开关 / 浏览记录…），无条件转发会让每个可见单元格
        // 都跟着重算一遍。堆叠与动效没有 Equatable，用各自的 token 参与比较。
        let snapshot = Snapshot(thumbSize: store.thumbSize,
                                smallCoverRadius: settings.smallCoverRadius,
                                accentColor: settings.accentColor,
                                metadata: settings.metadata,
                                photoOpenMode: settings.photoOpenMode,
                                selectedIDs: selection.ids,
                                stackRevision: store.stackRevision,
                                motion: settings.motion.rawValue)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        host.thumbSize = snapshot.thumbSize
        host.smallCoverRadius = snapshot.smallCoverRadius
        host.accentColor = snapshot.accentColor
        host.metadata = snapshot.metadata
        host.hoverAnimation = settings.motion.hover
        host.layoutAnimation = settings.motion.layout
        host.photoOpenMode = snapshot.photoOpenMode
        host.selectedIDs = snapshot.selectedIDs
        host.objectWillChange.send()
    }

    /// 参与「是否需要刷新」比较的快照。
    private struct Snapshot: Equatable {
        let thumbSize: Double
        let smallCoverRadius: CGFloat
        let accentColor: Color
        let metadata: MetadataOptions
        let photoOpenMode: PhotoOpenMode
        let selectedIDs: Set<UUID>
        let stackRevision: Int
        let motion: String
    }
}
