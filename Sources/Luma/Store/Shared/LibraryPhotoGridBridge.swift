import Combine
import SwiftUI
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
    private var cancellables: Set<AnyCancellable> = []

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

        Publishers.Merge3(
            store.objectWillChange.map { _ in () },
            settings.objectWillChange.map { _ in () },
            selection.objectWillChange.map { _ in () }
        )
        // objectWillChange 在值变更「之前」发出；挪到下一轮 RunLoop 再读，拿到的才是新值。
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)

        refresh()
    }

    private func refresh() {
        host.thumbSize = store.thumbSize
        host.smallCoverRadius = settings.smallCoverRadius
        host.accentColor = settings.accentColor
        host.metadata = settings.metadata
        host.hoverAnimation = settings.motion.hover
        host.layoutAnimation = settings.motion.layout
        host.photoOpenMode = settings.photoOpenMode
        host.selectedIDs = selection.ids
        host.objectWillChange.send()
    }
}
