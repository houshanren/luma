import SwiftUI
import AppKit

/// 网格与列表共用的照片右键菜单。
///
/// 菜单里的每一项都是 `LibraryStore` 的业务动作，所以实现留在 App 侧；
/// 网格组件通过 `PhotoGridHost.contextMenu` 回调挂载，不直接依赖 Store。
struct PhotoContextMenu: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var selectionModel: SelectionModel
    let photo: PhotoItem
    /// 右键目标：点击的项目在选区里时是整选区，否则只有这一项（由 `PhotoCell` 计算）。
    let actionIDs: Set<UUID>

    /// 导出 / 旋转 / 打印等仍以「选区」为入参的方法，先同步一次选区。
    private func selectTargets() {
        selectionModel.ids = actionIDs
    }

    var body: some View {
        Group {
            stackItems
            menuItems
        }
    }

    /// 堆叠组：展开 / 收起整组（堆叠关闭时 `stackCount` 恒为 1，这里自动隐藏）。
    @ViewBuilder
    private var stackItems: some View {
        let count = store.stackCount(for: photo.id)
        if count > 1 {
            Button(store.isStackExpanded(photo.id)
                   ? "收起堆叠（\(count) 张）"
                   : "展开堆叠（\(count) 张）") {
                withAnimation(.snappy(duration: 0.22)) {
                    store.toggleStackExpansion(photo.id)
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        // 菜单文案按整选区状态显示，多选时不会出现「收藏」却实际批量取消的错觉。
        let flags = store.selectionCommonFlags(actionIDs)
        if photo.isSystem {
            Button("打开") {
                store.openViewer(photo.id)
            }
            if !photo.isVideo {
                Button("查找相似照片") {
                    store.findSimilarPhotos(to: photo.id)
                }
            }
            // 当前图库就是官方「照片」图库时，拾光可以补充元数据（只写拾光数据库）。
            if store.canEditNativeOverlay {
                Button(flags.allFavorite ? "取消收藏" : "收藏") {
                    store.toggleFavorite(ids: actionIDs)
                }
                Button(flags.allHidden ? "取消隐藏" : "隐藏") {
                    store.setHidden(actionIDs, hidden: !flags.allHidden)
                }
                Button("添加关键词…") {
                    selectTargets()
                    store.showKeywordManager = true
                }
                if store.canEditMetadataWorkflow {
                    PhotoMetadataMenu(photo: photo, actionIDs: actionIDs)
                }
            }
            // 官方库作为当前图库时，相簿的增删改与照片归入都通过 PhotoKit 写回「照片」。
            if store.canManageSystemAlbums {
                if !store.systemAlbums.isEmpty || !store.systemFolders.isEmpty {
                    // 与侧边栏同一棵树、同一顺序：文件夹展开成子菜单，相簿按图库原始顺序排列。
                    Menu("加入相簿") {
                        SystemAlbumMenuItems(parent: nil, ids: actionIDs)
                    }
                }
                if case .systemAlbum(let albumID) = store.sidebarItem {
                    Divider()
                    Button("移出此相簿") {
                        store.removeSystemPhotos(actionIDs, fromSystemAlbum: albumID)
                    }
                    Button("移到最前") {
                        store.moveSystemPhotos(actionIDs, inSystemAlbum: albumID, toTop: true)
                    }
                    Button("移到最后") {
                        store.moveSystemPhotos(actionIDs, inSystemAlbum: albumID, toTop: false)
                    }
                    if !store.systemAlbums.isEmpty || !store.systemFolders.isEmpty {
                        Menu("移动到相簿") {
                            SystemAlbumMenuItems(parent: nil, ids: actionIDs, movingFrom: albumID)
                        }
                    }
                }
                Divider()
                if !photo.isVideo {
                    Button("编辑…") {
                        store.openEditor(photo.id)
                    }
                }
                Button("修改拍摄信息…") {
                    store.presentSystemMetadataEditor(actionIDs)
                }
                Button("新建相簿并加入所选…") {
                    store.presentNewSystemAlbumWithPhotos(actionIDs)
                }
                Button("移到「照片」的最近删除", role: .destructive) {
                    store.confirmDelete(actionIDs)
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    selectTargets()
                    store.presentBatchExport()
                }
            } else {
                Button("导出…") {
                    store.export(photo.id)
                }
            }
            Button("在访达中显示") {
                store.revealInFinder(ids: actionIDs)
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Divider()
            Button("导入到我的图库") {
                selectTargets()
                store.importSystemSelectionToLibrary()
            }
        } else if photo.isCloud {
            Button("打开") {
                store.openViewer(photo.id)
            }
            if !photo.isVideo {
                Button("查找相似照片") {
                    store.findSimilarPhotos(to: photo.id)
                }
            }
            Button(flags.allFavorite ? "取消收藏" : "收藏") {
                store.toggleFavorite(ids: actionIDs)
            }
            if photo.isVideo {
                Divider()
                cinemaMenu
            }
            Button("添加关键词…") {
                selectTargets()
                store.showKeywordManager = true
            }
            if store.isCurrentCloudWritable {
                Button("重命名…") {
                    store.requestCloudRename(photo.id)
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    selectTargets()
                    store.presentBatchExport()
                }
            } else {
                Button("导出…") {
                    store.export(photo.id)
                }
            }
            Button("幻灯片播放") {
                selectTargets()
                store.presentSlideshow()
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Button("打印…") {
                selectTargets()
                store.printCommand()
            }
            if store.isCurrentCloudSMB {
                Button("在访达中显示") {
                    store.revealInFinder(photo.id)
                }
            }
            Divider()
            Button("复制文件地址") {
                Task {
                    guard let url = await store.cloudStream(for: photo)?.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if store.isCurrentCloudWritable {
                Divider()
                Button("从云端删除…", role: .destructive) {
                    store.confirmDeleteCloud(actionIDs)
                }
            }
        } else if photo.isDeleted {
            Button("恢复") {
                store.restore(actionIDs)
            }
            Button("永久删除…", role: .destructive) {
                store.confirmPermanentDelete(actionIDs)
            }
        } else {
            Button("打开") {
                store.openViewer(photo.id)
            }
            if !photo.isVideo {
                Button("查找相似照片") {
                    store.findSimilarPhotos(to: photo.id)
                }
            }
            Button(flags.allFavorite ? "取消收藏" : "收藏") {
                store.toggleFavorite(ids: actionIDs)
            }
            if photo.isVideo {
                Divider()
                cinemaMenu
            }
            Menu("添加到相簿") {
                // 与侧边栏一致：文件夹 → 子文件夹 → 相簿，名称按本地排序。
                LocalAlbumMenuItems(parentFolderID: nil, ids: actionIDs)
                if store.albums.isEmpty, store.folders.isEmpty {
                    Text("暂无相簿")
                } else {
                    Divider()
                }
                Button("新建相簿…") {
                    store.showNewAlbumSheet = true
                }
            }
            if let albumID = store.currentAlbumID {
                if store.currentAlbumCoverID == photo.id {
                    Button("恢复自动封面") {
                        store.setAlbumCover(nil, for: albumID)
                    }
                } else {
                    Button("设为相册封面") {
                        store.setAlbumCover(photo.id, for: albumID)
                    }
                }
            }
            Button(flags.allHidden ? "取消隐藏" : "隐藏") {
                store.setHidden(actionIDs, hidden: !flags.allHidden)
            }
            Button("添加关键词…") {
                selectTargets()
                store.showKeywordManager = true
            }
            if store.canEditMetadataWorkflow {
                PhotoMetadataMenu(photo: photo, actionIDs: actionIDs)
            }
            if !photo.isVideo {
                Button("压缩…") {
                    store.presentCompression(for: actionIDs)
                }
                if PhotoCompressor.hasBackup(for: photo) {
                    Button("还原压缩前的原图") {
                        store.revertCompression(photo.id)
                    }
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    selectTargets()
                    store.presentBatchExport()
                }
            }
            if !photo.isReadOnly {
                Button("批量更改…") {
                    selectTargets()
                    store.presentBatchChange()
                }
            }
            Divider()
            if !photo.isVideo {
                Button("编辑…") {
                    store.openEditor(photo.id)
                }
                if photo.hasEdits {
                    Button("复制编辑点") {
                        store.copyEdits(photo.id)
                    }
                }
                if store.copiedEditRecipe != nil {
                    Button("粘贴编辑点") {
                        store.pasteEdits(photo.id)
                    }
                }
                Menu("旋转") {
                    Button("向右旋转") {
                        selectTargets()
                        store.rotateCommand(clockwise: true)
                    }
                    Button("向左旋转") {
                        selectTargets()
                        store.rotateCommand(clockwise: false)
                    }
                }
            }
            Button("复制照片") {
                selectTargets()
                store.duplicateCommand()
            }
            Button("打印…") {
                selectTargets()
                store.printCommand()
            }
            Button("幻灯片播放") {
                selectTargets()
                store.presentSlideshow()
            }
            if actionIDs.count == 1 {
                Button("导出…") {
                    store.export(photo.id)
                }
            }
            Button("在访达中显示") {
                store.revealInFinder(ids: actionIDs)
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                store.confirmDelete(actionIDs)
            }
        }
    }

    /// 相簿 / 网格里的影院操作：手动匹配、刮削、收藏与加入清单。
    @ViewBuilder
    private var cinemaMenu: some View {
        let targets = store.photos(forIDs: actionIDs).filter { $0.isVideo }
        if !targets.isEmpty {
            let entries = targets.compactMap { store.cinemaEntry(for: $0) }
            let allFavorite = targets.allSatisfy { store.cinemaUserState(for: $0.id).favorite }
            Menu("影院") {
                Button(targets.count == 1 ? "手动匹配…" : "手动匹配所选…（\(targets.count)）") {
                    store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: targets)
                }
                Button(entries.isEmpty ? "刮削所选（\(targets.count)）"
                                       : "重新刮削所选（\(targets.count)）") {
                    Task { await store.scrapeCinemaPhotos(targets) }
                }
                Divider()
                Button(allFavorite ? "取消影院收藏" : "加入影院收藏") {
                    store.setCinemaFavorite(!allFavorite, ids: Set(targets.map(\.id)))
                }
                if store.cinemaLists.isEmpty {
                    Text("还没有影院清单")
                } else {
                    Menu("加入影院清单") {
                        ForEach(store.cinemaLists) { list in
                            Button(list.name) {
                                for photo in targets {
                                    store.addToCinemaList(list.id, entryID: photo.id)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("在影院中查看") {
                    if let mountID = photo.cloudMountID {
                        store.navigate(to: .cloudCinema(mountID))
                    } else {
                        store.navigate(to: .cinema)
                    }
                }
            }
        }
    }
}

/// 评分 / 旗标 / 色标的右键子菜单。系统图库作为当前图库时写入拾光叠加数据。
struct PhotoMetadataMenu: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: PhotoItem
    let actionIDs: Set<UUID>

    var body: some View {
        Menu("评分") {
            Button {
                store.setRating(0, ids: actionIDs)
            } label: {
                if photo.starRating == 0 {
                    Label("无评分", systemImage: "checkmark")
                } else {
                    Text("无评分")
                }
            }
            Divider()
            ForEach(1...5, id: \.self) { value in
                Button {
                    store.setRating(value, ids: actionIDs)
                } label: {
                    if photo.starRating == value {
                        Label("\(value) 星", systemImage: "checkmark")
                    } else {
                        Label("\(value) 星", systemImage: "star.fill")
                    }
                }
            }
        }

        Menu("旗标") {
            ForEach(PhotoFlag.allCases) { flag in
                Button {
                    store.setFlag(flag, ids: actionIDs)
                } label: {
                    if photo.pickFlag == flag {
                        Label(flag.title, systemImage: "checkmark")
                    } else {
                        Label(flag.title, systemImage: flag.icon)
                    }
                }
            }
        }

        Menu("色标") {
            ForEach(PhotoColorLabel.allCases) { label in
                Button {
                    store.setColorLabel(label, ids: actionIDs)
                } label: {
                    if photo.labelColor == label {
                        Label(label.title, systemImage: "checkmark")
                    } else {
                        Label(label.title, systemImage: "circle.fill")
                            .foregroundStyle(label.color)
                    }
                }
            }
        }
    }
}

// MARK: - 「加入相簿」的层级菜单

/// 系统图库的「加入相簿」子菜单：与侧边栏同一棵树、同一排序（文件夹与相簿按图库原始顺序混排）。
/// 空文件夹不展示，避免菜单里出现点不进去的分支。
private struct SystemAlbumMenuItems: View {
    @EnvironmentObject private var store: LibraryStore

    let parent: Int64?
    let ids: Set<UUID>
    /// 非空时表示「移动到相簿」：从该相簿移出再加到所选相簿。
    var movingFrom: Int64? = nil

    var body: some View {
        let entries = store.systemChildren(of: parent).filter { entry in
            guard case .folder(let folder) = entry else { return true }
            return !store.systemChildren(of: folder.id).isEmpty
        }
        if entries.isEmpty {
            Text("没有可用的相簿").disabled(true)
        } else {
            ForEach(entries) { entry in
                switch entry {
                case .folder(let folder):
                    Menu {
                        SystemAlbumMenuItems(parent: folder.id, ids: ids, movingFrom: movingFrom)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                case .album(let album):
                    if let source = movingFrom {
                        Button(album.name) {
                            store.moveSystemPhotos(ids, fromSystemAlbum: source, toSystemAlbum: album.id)
                        }
                        .disabled(album.id == source)
                    } else {
                        Button(album.name) {
                            store.addSystemPhotos(ids, toSystemAlbum: album.id)
                        }
                    }
                }
            }
        }
    }
}

/// 本地图库的「添加到相簿」子菜单：文件夹先于相簿，名称按本地排序，与侧边栏一致。
private struct LocalAlbumMenuItems: View {
    @EnvironmentObject private var store: LibraryStore

    let parentFolderID: UUID?
    let ids: Set<UUID>

    var body: some View {
        let folders = store.childFolders(of: parentFolderID)
        let albums = store.albums(in: parentFolderID)
        ForEach(folders) { folder in
            Menu {
                LocalAlbumMenuItems(parentFolderID: folder.id, ids: ids)
            } label: {
                Label(folder.name, systemImage: "folder")
            }
        }
        ForEach(albums) { album in
            Button(album.name) {
                store.addToAlbum(album.id, photoIDs: ids)
            }
        }
        if folders.isEmpty, albums.isEmpty {
            Text("这个文件夹里还没有相簿").disabled(true)
        }
    }
}
