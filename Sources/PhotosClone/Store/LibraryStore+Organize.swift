import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Navigation

    func navigate(to item: SidebarItem) {
        sidebarItem = item
        selection.removeAll()
        viewerID = nil
        searchText = ""
        photoFilter = .all
        keywordFilter = nil
        selectedPlace = nil
        selectedPerson = nil
        similarScope = nil
        if case .cloudMount(let id) = item {
            openCloudMount(id)
        }
    }

    func clearFilter() {
        photoFilter = .all
        keywordFilter = nil
    }

    // MARK: - Keywords

    var keywordOptions: [KeywordOption] {
        var counts: [String: Int] = [:]
        // 官方「照片」图库：关键词同样来自拾光的补充元数据。
        let source = canEditNativeOverlay ? systemPhotos : photos
        for photo in source where photo.deletedAt == nil {
            for tag in photo.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts.map { KeywordOption(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addKeyword(_ keyword: String, to ids: Set<UUID>) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ids.isEmpty else { return }
        // 官方「照片」图库：关键词写进拾光数据库（Photos.sqlite 只读）。
        if canEditNativeOverlay {
            let systemIDs = ids.filter { systemPhotoIndex[$0] != nil }
            if !systemIDs.isEmpty {
                for id in systemIDs {
                    var list = systemPhotoIndex[id]?.keywords ?? []
                    if !list.contains(trimmed) { list.append(trimmed) }
                    setSystemKeywords(list, ids: [id])
                }
                showToast("已添加关键词「\(trimmed)」")
                return
            }
        }
        var changed = false
        for index in photos.indices where ids.contains(photos[index].id) {
            var list = photos[index].keywords ?? []
            if !list.contains(trimmed) {
                list.append(trimmed)
                photos[index].keywords = list
                changed = true
            }
        }
        if changed {
            save()
            showToast("已添加关键词「\(trimmed)」")
        }
    }

    func removeKeyword(_ keyword: String, from ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if canEditNativeOverlay {
            let systemIDs = ids.filter { systemPhotoIndex[$0] != nil }
            if !systemIDs.isEmpty {
                for id in systemIDs {
                    var list = systemPhotoIndex[id]?.keywords ?? []
                    list.removeAll { $0 == keyword }
                    setSystemKeywords(list, ids: [id])
                }
                return
            }
        }
        for index in photos.indices where ids.contains(photos[index].id) {
            guard var list = photos[index].keywords else { continue }
            list.removeAll { $0 == keyword }
            photos[index].keywords = list.isEmpty ? nil : list
        }
        save()
    }

    func deleteKeyword(_ keyword: String) {
        if canEditNativeOverlay {
            for item in systemPhotos where item.tags.contains(keyword) {
                var list = item.keywords ?? []
                list.removeAll { $0 == keyword }
                setSystemKeywords(list, ids: [item.id])
            }
        }
        for index in photos.indices {
            guard var list = photos[index].keywords else { continue }
            list.removeAll { $0 == keyword }
            photos[index].keywords = list.isEmpty ? nil : list
        }
        if keywordFilter == keyword {
            keywordFilter = nil
        }
        save()
        showToast("已删除关键词「\(keyword)」")
    }

    // MARK: - Albums & folders

    func rootFolders() -> [AlbumFolder] {
        folders.filter { $0.parentID == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func childFolders(of parentID: UUID?) -> [AlbumFolder] {
        folders.filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func albums(in folderID: UUID?) -> [Album] {
        albums.filter { $0.folderID == folderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 包含自身的文件夹子树。
    func folderSubtreeIDs(_ id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var queue: [UUID] = [id]
        while let current = queue.popLast() {
            for child in folders where child.parentID == current && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    func systemFolderSubtreeIDs(_ id: Int64) -> Set<Int64> {
        var result: Set<Int64> = [id]
        var queue: [Int64] = [id]
        while let current = queue.popLast() {
            for child in systemFolders where child.parent == current && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    var rootAlbums: [Album] {
        albums(in: nil)
    }

    func folderPath(_ folderID: UUID?) -> String {
        guard let folderID, let folder = folders.first(where: { $0.id == folderID }) else { return "" }
        let parent = folderPath(folder.parentID)
        return parent.isEmpty ? folder.name : parent + " / " + folder.name
    }

    var folderOptions: [FolderOption] {
        folders.map { FolderOption(id: $0.id, path: folderPath($0.id)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - 固定项目（系统项 / 相簿 / 文件夹）

    static let pinnedItemsKey = "pinned_sidebar_v2"

    /// 首次打开图库时默认固定在「固定」分区的系统项目。
    static let defaultPinnedSystemKeys = [
        "favorites", "recentlySaved", "map", "videos", "screenshots", "people", "trash"
    ]

    /// 从当前图库读取固定项，并过滤掉已被删除的相簿与文件夹。
    func loadPinnedItems() {
        let hasNew = metadataStore?.setting(Self.pinnedItemsKey) != nil
        // 兼容旧版本只保存了相簿 / 文件夹的固定列表。
        let raw = metadataStore?.setting(Self.pinnedItemsKey) ?? metadataStore?.setting("pinned_sidebar")
        guard let raw,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PinnedSidebarItem].self, from: data) else {
            pinnedItems = Self.defaultPinnedSystemKeys.map { .system($0) }
            return
        }
        let albumIDs = Set(albums.map(\.id))
        let folderIDs = Set(folders.map(\.id))
        var list = decoded.filter { item in
            switch item {
            case .system: return true
            case .album(let id): return albumIDs.contains(id)
            case .folder(let id): return folderIDs.contains(id)
            }
        }
        if !hasNew {
            // 旧数据没有系统项：把默认项补在最前面。
            list = Self.defaultPinnedSystemKeys.map { .system($0) } + list
            pinnedItems = list
            savePinnedItems()
            return
        }
        pinnedItems = list
    }

    func savePinnedItems() {
        guard let data = try? JSONEncoder().encode(pinnedItems),
              let raw = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.pinnedItemsKey, raw)
    }

    func isPinned(_ item: PinnedSidebarItem) -> Bool {
        pinnedItems.contains(item)
    }

    /// 固定 / 取消固定一个相簿或文件夹。
    func togglePin(_ item: PinnedSidebarItem) {
        if let index = pinnedItems.firstIndex(of: item) {
            pinnedItems.remove(at: index)
        } else {
            pinnedItems.append(item)
        }
        savePinnedItems()
    }

    var pinnedAlbums: [Album] {
        pinnedItems.compactMap { item in
            guard case .album(let id) = item else { return nil }
            return albums.first { $0.id == id }
        }
    }

    var pinnedFolders: [AlbumFolder] {
        pinnedItems.compactMap { item in
            guard case .folder(let id) = item else { return nil }
            return folders.first { $0.id == id }
        }
    }

    func createAlbum(named name: String, folderID: UUID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let album = Album(name: trimmed, folderID: folderID)
        albums.append(album)
        sidebarItem = .album(album.id)
        save()
    }

    func renameAlbum(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index].name = trimmed
        save()
    }

    /// 删除相簿 / 文件夹时同步取消固定。
    func removePinned(albumIDs: Set<UUID> = [], folderIDs: Set<UUID> = []) {
        guard !albumIDs.isEmpty || !folderIDs.isEmpty else { return }
        let before = pinnedItems.count
        pinnedItems.removeAll { item in
            switch item {
            case .system: return false
            case .album(let id): return albumIDs.contains(id)
            case .folder(let id): return folderIDs.contains(id)
            }
        }
        if pinnedItems.count != before {
            savePinnedItems()
        }
    }

    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
        removePinned(albumIDs: [id])
        if case .album(let current) = sidebarItem, current == id {
            sidebarItem = .allAlbums
        }
        save()
    }

    @discardableResult
    func createFolder(named name: String, parentID: UUID? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = AlbumFolder(name: trimmed, parentID: parentID)
        folders.append(folder)
        save()
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        save()
    }

    func deleteFolder(_ id: UUID) {
        var folderIDs: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for folder in folders where folder.parentID != nil && folderIDs.contains(folder.parentID!) {
                if !folderIDs.contains(folder.id) {
                    folderIDs.insert(folder.id)
                    changed = true
                }
            }
        }
        let removedAlbumIDs = Set(albums.filter { $0.folderID != nil && folderIDs.contains($0.folderID!) }.map { $0.id })
        albums.removeAll { removedAlbumIDs.contains($0.id) }
        folders.removeAll { folderIDs.contains($0.id) }
        removePinned(albumIDs: removedAlbumIDs, folderIDs: folderIDs)
        if case .album(let current) = sidebarItem, removedAlbumIDs.contains(current) {
            sidebarItem = .allAlbums
        }
        save()
        showToast("已删除文件夹与其中的相簿")
    }

    func moveAlbum(_ id: UUID, toFolder folderID: UUID?) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index].folderID = folderID
        save()
        showToast(folderID == nil ? "已移到相簿顶层" : "已移到「\(folderPath(folderID))」")
    }

    func addToAlbum(_ albumID: UUID, photoIDs: Set<UUID>) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }), !photoIDs.isEmpty else { return }
        let existing = Set(albums[index].photoIDs)
        let additions = photoIDs.subtracting(existing)
        // 按图库中的顺序追加，保证新加入项目的位置稳定，便于后续拖拽排序。
        let ordered = photos.map(\.id).filter { additions.contains($0) }
        albums[index].photoIDs.append(contentsOf: ordered)
        save()
        showToast("已添加到「\(albums[index].name)」")
    }

    /// 当前所在的可重排相簿（系统相簿只读，不参与）。
    var currentAlbumID: UUID? {
        guard case .album(let id) = sidebarItem, !isReadOnlyScope else { return nil }
        return id
    }

    /// 当前相簿用户指定的封面（未指定则为 nil）。
    var currentAlbumCoverID: UUID? {
        guard let albumID = currentAlbumID else { return nil }
        return albums.first(where: { $0.id == albumID })?.coverPhotoID
    }

    /// 指定相簿封面（照片或视频均可）；传 nil 恢复自动拼图封面。
    func setAlbumCover(_ photoID: UUID?, for albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        if let photoID, !albums[index].photoIDs.contains(photoID) { return }
        guard albums[index].coverPhotoID != photoID else { return }
        albums[index].coverPhotoID = photoID
        save()
        showToast(photoID == nil ? "已恢复自动封面" : "已设为相簿封面")
    }

    var canReorderCurrentAlbum: Bool {
        currentAlbumID != nil
    }

    /// 相簿内拖拽排序：把 moving 中的项目移动到 targetID 前/后。
    func moveAlbumPhotos(albumID: UUID, moving: Set<UUID>, targetID: UUID, after: Bool) {
        guard !moving.isEmpty, !moving.contains(targetID),
              let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        var order = albums[index].photoIDs
        let movingIDs = order.filter { moving.contains($0) }
        guard !movingIDs.isEmpty, order.contains(targetID) else { return }

        order.removeAll { moving.contains($0) }
        guard let targetIndex = order.firstIndex(of: targetID) else { return }
        let insertIndex = after ? targetIndex + 1 : targetIndex
        order.insert(contentsOf: movingIDs, at: min(insertIndex, order.count))
        guard order != albums[index].photoIDs else { return }
        albums[index].photoIDs = order
        save()
    }

    func removeFromCurrentAlbum(_ ids: Set<UUID>) {
        guard case .album(let albumID) = sidebarItem,
              let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].photoIDs.removeAll { ids.contains($0) }
        // 被移除的项目如果正被用作封面，回落到自动封面。
        if let cover = albums[index].coverPhotoID, ids.contains(cover) {
            albums[index].coverPhotoID = nil
        }
        selection.removeAll()
        save()
    }

    func albumsContaining(_ id: UUID) -> [Album] {
        albums.filter { $0.photoIDs.contains(id) }
    }

    // MARK: - 智能相簿

    static let smartAlbumsSettingKey = "smart_albums"

    func loadSmartAlbums() {
        guard let raw = metadataStore?.setting(Self.smartAlbumsSettingKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SmartAlbum].self, from: data) else {
            smartAlbums = []
            return
        }
        smartAlbums = decoded
    }

    func persistSmartAlbums() {
        guard let encoded = try? JSONEncoder().encode(smartAlbums),
              let text = String(data: encoded, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.smartAlbumsSettingKey, text)
    }

    func presentSmartAlbumEditor(_ album: SmartAlbum? = nil) {
        if let album {
            editingSmartAlbum = album
        } else {
            var draft = SmartAlbum(name: "新建智能相簿")
            draft.rules = [SmartRule(field: .favorite, value: "是")]
            editingSmartAlbum = draft
        }
    }

    func saveSmartAlbum(_ album: SmartAlbum) {
        if let index = smartAlbums.firstIndex(where: { $0.id == album.id }) {
            smartAlbums[index] = album
        } else {
            smartAlbums.append(album)
        }
        persistSmartAlbums()
        editingSmartAlbum = nil
        navigate(to: .smartAlbum(album.id))
        showToast("已保存智能相簿「\(album.name)」")
    }

    func deleteSmartAlbum(_ id: UUID) {
        smartAlbums.removeAll { $0.id == id }
        persistSmartAlbums()
        if case .smartAlbum(let current) = sidebarItem, current == id {
            sidebarItem = .library
        }
        showToast("已删除智能相簿")
    }

    func smartAlbumCount(_ album: SmartAlbum) -> Int {
        let live = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        return live.reduce(into: 0) { result, photo in
            if album.matches(photo, analysis: self.analysisIndex[photo.id]) { result += 1 }
        }
    }

    // MARK: - 批量更改

    func presentBatchChange() {
        let ids = commandTargetIDs
        guard !ids.isEmpty else {
            showToast("请先选择要更改的项目")
            return
        }
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘为只读，不支持批量更改")
            return
        }
        batchChangeTargets = ids
        showBatchChangeSheet = true
    }

    /// 传入 nil 表示不修改对应字段。
    func applyBatchChange(title: String?, date: Date?, place: String?) {
        guard !batchChangeTargets.isEmpty else { return }
        var touched = 0
        for index in photos.indices where batchChangeTargets.contains(photos[index].id) {
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                photos[index].title = trimmed.isEmpty ? nil : trimmed
            }
            if let date {
                photos[index].capturedAt = date
            }
            if let place {
                let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
                photos[index].placeCity = trimmed.isEmpty ? nil : trimmed
                photos[index].placePOI = trimmed.isEmpty ? nil : trimmed
            }
            touched += 1
        }
        save()
        showToast("已更改 \(touched) 项")
        showBatchChangeSheet = false
        batchChangeTargets = []
    }

    var albumsSorted: [Album] {
        albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
