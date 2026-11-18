import Foundation

/// 系统「照片」图库的相簿 / 收藏 / 隐藏写回（PhotoKit）。
/// 只在官方库作为当前图库、且校验确认打开的就是系统照片库时执行；额外连接的系统图库保持只读。
extension LibraryStore {
    var canWriteSystemLibrary: Bool {
        isSystemScope && isNativeContainer
    }

    var canManageSystemAlbums: Bool {
        canWriteSystemLibrary
    }

    /// 写回前统一校验：权限 + 「当前打开的就是系统照片库」。
    func prepareSystemLibraryWrite() async -> Bool {
        guard canWriteSystemLibrary else {
            showToast("只有官方「照片」图库作为当前图库时才能写回")
            return false
        }
        guard await PhotoKitBridge.ensureAuthorized() else {
            showToast("需要相册读写权限，请在系统设置中允许拾光访问照片")
            return false
        }
        let samples = systemWriteSampleIDs
        guard !samples.isEmpty else {
            showToast("当前图库没有可用于校验的照片")
            return false
        }
        guard PhotoKitBridge.targetsSystemLibrary(sampleAssetIDs: samples) else {
            showToast("当前打开的不是系统「照片」图库，无法写回；请在「照片」中打开该图库后重试")
            return false
        }
        return true
    }

    /// 校验「是不是同一个库」用的样本照片。
    private var systemWriteSampleIDs: [UUID] {
        let pool = systemPhotos.isEmpty ? systemWindowPhotos : systemPhotos
        var ids = Array(pool.lazy.filter { !$0.isVideo }.prefix(3).map(\.id))
        if ids.isEmpty {
            ids = Array(systemAlbums.flatMap(\.assetIDs).prefix(3))
        }
        return ids
    }

    /// Photos.sqlite 的 ZUUID → PhotoKit 相簿标识（由 `PhotoKitBridge` 解析 localIdentifier）。
    func systemAlbumIdentifier(_ albumID: Int64) -> String? {
        if let uuid = systemAlbum(id: albumID)?.uuid, !uuid.isEmpty {
            return uuid
        }
        // 旧快照缓存可能没有 uuid：直接回查 Photos.sqlite（只读）。
        guard let path = systemLibraryPath else { return nil }
        let databasePath = URL(fileURLWithPath: path)
            .appendingPathComponent("database/Photos.sqlite").path
        guard let db = try? SQLiteDatabase(path: databasePath, readonly: true) else { return nil }
        let row = (try? db.query("SELECT ZUUID FROM ZGENERICALBUM WHERE Z_PK = ?", [albumID]))?.first
        guard let uuid = row?["ZUUID"]?.string, !uuid.isEmpty else { return nil }
        return uuid
    }

    // MARK: - 相簿增删改

    func createSystemAlbum(named name: String) {
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                _ = try await PhotoKitBridge.createAlbum(title: name)
                showToast("已在「照片」中新建相簿「\(name)」，正在刷新…")
                reloadSystemLibrary()
            } catch {
                showToast("新建相簿失败：\(error.localizedDescription)")
            }
        }
    }

    func renameSystemAlbum(_ id: Int64, to name: String) {
        guard let identifier = systemAlbumIdentifier(id) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.renameAlbum(albumID: identifier, title: name)
                updateSystemAlbum(id, name: name)
                showToast("已把相簿重命名为「\(name)」")
            } catch {
                showToast("重命名失败：\(error.localizedDescription)")
            }
        }
    }

    func deleteSystemAlbum(_ id: Int64) {
        guard let identifier = systemAlbumIdentifier(id) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.deleteAlbums(albumIDs: [identifier])
                systemAlbums.removeAll { $0.id == id }
                removePinned(systemAlbumIDs: [id])
                systemAlbumIndex[id] = nil
                systemStructureRevision &+= 1
                systemCountsCache = nil
                systemCountsCacheRevision = -1
                contentRevision &+= 1
                if case .systemAlbum(let current) = sidebarItem, current == id {
                    navigate(to: .systemAlbums)
                }
                showToast("已从「照片」删除相簿（照片本身不受影响）")
            } catch {
                showToast("删除相簿失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 相簿内照片

    func addSystemPhotos(_ ids: Set<UUID>, toSystemAlbum albumID: Int64) {
        guard !ids.isEmpty, let album = systemAlbum(id: albumID) else { return }
        guard let identifier = systemAlbumIdentifier(albumID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.addAssets(targets, toAlbum: identifier)
                var merged = album.assetIDs
                for id in targets where !merged.contains(id) { merged.append(id) }
                updateSystemAlbum(albumID, assetIDs: merged)
                showToast("已把 \(targets.count) 张加入「\(album.name)」")
            } catch {
                showToast("加入相簿失败：\(error.localizedDescription)")
            }
        }
    }

    func removeSystemPhotos(_ ids: Set<UUID>, fromSystemAlbum albumID: Int64) {
        guard !ids.isEmpty, let album = systemAlbum(id: albumID) else { return }
        guard let identifier = systemAlbumIdentifier(albumID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.removeAssets(targets, fromAlbum: identifier)
                updateSystemAlbum(albumID, assetIDs: album.assetIDs.filter { !ids.contains($0) })
                showToast("已把 \(targets.count) 张移出「\(album.name)」")
            } catch {
                showToast("移出相簿失败：\(error.localizedDescription)")
            }
        }
    }

    /// 相簿内手动排序：移到最前 / 最后。
    func moveSystemPhotos(_ ids: Set<UUID>, inSystemAlbum albumID: Int64, toTop: Bool) {
        guard !ids.isEmpty, let album = systemAlbum(id: albumID) else { return }
        guard let identifier = systemAlbumIdentifier(albumID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.moveAssets(targets, inAlbum: identifier, toTop: toTop)
                var order = album.assetIDs
                let moving = order.filter { ids.contains($0) }
                order.removeAll { ids.contains($0) }
                if toTop {
                    order.insert(contentsOf: moving, at: 0)
                } else {
                    order.append(contentsOf: moving)
                }
                updateSystemAlbum(albumID, assetIDs: order)
                showToast(toTop ? "已把 \(targets.count) 张移到最前" : "已把 \(targets.count) 张移到最后")
            } catch {
                showToast("调整顺序失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 内存同步

    private func updateSystemAlbum(_ id: Int64,
                                   name: String? = nil,
                                   assetIDs: [UUID]? = nil) {
        guard let index = systemAlbums.firstIndex(where: { $0.id == id }) else { return }
        let old = systemAlbums[index]
        let updated = SystemAlbumInfo(id: old.id,
                                      name: name ?? old.name,
                                      parentFolder: old.parentFolder,
                                      assetIDs: assetIDs ?? old.assetIDs,
                                      sortIndex: old.sortIndex,
                                      uuid: old.uuid,
                                      customSortKey: old.customSortKey,
                                      customSortAscending: old.customSortAscending)
        systemAlbums[index] = updated
        systemAlbumIndex[id] = updated
        systemStructureRevision &+= 1
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        contentRevision &+= 1
    }
}
