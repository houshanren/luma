import Foundation
import AppKit

/// 一次工具调用的本地执行结果。
struct AIToolExecution {
    let json: String
    let summary: String?
    let photoIDs: [UUID]
}

/// 智能助手工具的执行入口：所有写操作都走 LibraryStore 现有方法并 `save()`。
extension LibraryStore {
    func executeAITool(_ call: AIToolCall) async -> AIToolExecution {
        let args = AILibraryTools.arguments(call.arguments)
        switch call.name {
        case "search_photos": return searchPhotosTool(args)
        case "list_albums": return listAlbumsTool()
        case "list_folders": return listFoldersTool()
        case "list_videos": return listVideosTool(args)
        case "navigate": return navigateTool(args)
        case "select_photos": return selectPhotosTool(args)
        case "open_photo": return openPhotoTool(args)
        case "create_albums": return createAlbumsTool(args)
        case "add_photos_to_album": return addToAlbumTool(args)
        case "remove_photos_from_album": return removeFromAlbumTool(args)
        case "rename_album": return renameAlbumTool(args)
        case "delete_album": return deleteAlbumTool(args)
        case "move_album": return moveAlbumTool(args)
        case "set_album_cover": return setAlbumCoverTool(args)
        case "create_folder": return createFolderTool(args)
        case "rename_folder": return renameFolderTool(args)
        case "delete_folder": return deleteFolderTool(args)
        case "set_favorite": return setFavoriteTool(args)
        case "set_hidden": return setHiddenTool(args)
        case "add_keywords": return addKeywordsTool(args)
        case "remove_keywords": return removeKeywordsTool(args)
        case "set_title": return setTitleTool(args)
        case "compress_photos": return await compressPhotosTool(args)
        case "beautify_photos": return await beautifyPhotosTool(args)
        case "trash_photos": return trashPhotosTool(args)
        case "restore_photos": return restorePhotosTool(args)
        default:
            return failure("不支持的工具：\(call.name)")
        }
    }

    /// 写操作执行前统一确认；一次模型回复里的多个写操作只弹一次。
    func confirmAIToolActions(_ calls: [AIToolCall]) -> Bool {
        guard !calls.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "智能助手准备修改当前图库"
        alert.informativeText = calls
            .prefix(8)
            .map { "• " + AILibraryTools.describe($0) }
            .joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 检索

    private func searchPhotosTool(_ args: [String: Any]) -> AIToolExecution {
        let query = AILibraryTools.string(args["query"]) ?? ""
        let filter = AILibraryTools.string(args["filter"]) ?? "all"
        let limit = min(80, max(1, AILibraryTools.integer(args["limit"], fallback: 20)))
        let search = query.isEmpty ? nil : SearchQueryParser.parse(query)
        let includeDeleted = sidebarItem == .trash
        let albumNames = aiAlbumNamesByPhotoID()

        var items: [[String: Any]] = []
        var ids: [UUID] = []
        for photo in aiSearchSource() {
            if !includeDeleted, photo.deletedAt != nil { continue }
            if let search, !matchesSearch(photo, query: search) { continue }
            guard aiMatchesFilter(photo, filter: filter) else { continue }
            ids.append(photo.id)
            var item: [String: Any] = [
                "id": photo.id.uuidString,
                "name": photo.originalName,
                "type": photo.isVideo ? "video" : "photo",
                "date": Self.aiDateFormatter.string(from: photo.capturedAt),
                "favorite": photo.isFavorite,
                "hidden": photo.isHidden,
                "keywords": (photo.keywords ?? []).prefix(8).joined(separator: " ")
            ]
            if photo.isVideo { item["duration"] = Self.aiDurationText(photo.duration) }
            if let names = albumNames[photo.id] { item["albums"] = Array(names.prefix(3)) }
            items.append(item)
            if items.count >= limit { break }
        }
        return success(["count": items.count,
                        "scope": sidebarTitle,
                        "photos": items],
                       summary: nil,
                       photoIDs: ids)
    }

    private func listAlbumsTool() -> AIToolExecution {
        let items = albums.map { album -> [String: Any] in
            var item: [String: Any] = [
                "id": album.id.uuidString,
                "name": album.name,
                "count": album.photoIDs.count
            ]
            if let folderID = album.folderID,
               let folder = folders.first(where: { $0.id == folderID }) {
                item["folder_id"] = folderID.uuidString
                item["folder_name"] = folder.name
            }
            if let cover = album.coverPhotoID { item["cover_id"] = cover.uuidString }
            return item
        }
        return success(["count": items.count, "albums": items], summary: nil, photoIDs: [])
    }

    private func listFoldersTool() -> AIToolExecution {
        var items: [[String: Any]] = []
        func append(_ parentID: UUID?, depth: Int) {
            for folder in folders
                .filter({ $0.parentID == parentID })
                .sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let albumCount = albums.filter { $0.folderID == folder.id }.count
                items.append([
                    "id": folder.id.uuidString,
                    "name": folder.name,
                    "parent_id": folder.parentID?.uuidString ?? "",
                    "depth": depth,
                    "album_count": albumCount
                ])
                append(folder.id, depth: depth + 1)
            }
        }
        append(nil, depth: 0)
        return success(["count": items.count, "folders": items], summary: nil, photoIDs: [])
    }

    private func listVideosTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(100, max(1, AILibraryTools.integer(args["limit"], fallback: 30)))
        let albumNames = aiAlbumNamesByPhotoID()
        var items: [[String: Any]] = []
        var ids: [UUID] = []
        let videos = aiSearchSource()
            .filter { $0.isVideo && $0.deletedAt == nil }
            .sorted { $0.capturedAt > $1.capturedAt }
        for photo in videos {
            ids.append(photo.id)
            var item: [String: Any] = [
                "id": photo.id.uuidString,
                "name": photo.originalName,
                "date": Self.aiDateFormatter.string(from: photo.capturedAt),
                "duration": Self.aiDurationText(photo.duration),
                "size_mb": Double(photo.fileSize) / 1_048_576,
                "width": photo.pixelWidth,
                "height": photo.pixelHeight,
                "favorite": photo.isFavorite,
                "hidden": photo.isHidden
            ]
            if let names = albumNames[photo.id] { item["albums"] = Array(names.prefix(3)) }
            items.append(item)
            if items.count >= limit { break }
        }
        return success(["count": items.count, "videos": items], summary: nil, photoIDs: ids)
    }

    // MARK: - 浏览

    private func navigateTool(_ args: [String: Any]) -> AIToolExecution {
        guard let target = AILibraryTools.string(args["target"]) else {
            return failure("缺少 target")
        }
        var item: SidebarItem
        switch target {
        case "library": item = .library
        case "favorites": item = .favorites
        case "videos": item = .videos
        case "screenshots": item = .screenshots
        case "hidden": item = .hidden
        case "trash": item = .trash
        case "all_albums": item = .allAlbums
        case "recently_edited": item = .recentlyEdited
        case "imports": item = .imports
        case "album":
            guard let album = resolveAlbum(args) else {
                return failure("没有找到对应相簿，可先调用 list_albums")
            }
            item = .album(album.id)
        case "folder":
            guard let folder = resolveFolder(args) else {
                return failure("没有找到对应文件夹，可先调用 list_folders")
            }
            item = .folder(folder.id)
        case "scene":
            guard let raw = AILibraryTools.string(args["scene"]) else {
                return failure("缺少 scene")
            }
            let category = SceneCatalog.category(id: raw)
                ?? SceneCatalog.categories.first {
                    $0.title.caseInsensitiveCompare(raw) == .orderedSame
                }
            guard let category else {
                let names = SceneCatalog.categories.map(\.title).joined(separator: "、")
                return failure("没有这个场景。可用场景：\(names)")
            }
            item = .scene(category.id)
        default:
            return failure("不支持的范围：\(target)")
        }

        navigate(to: item)
        if let raw = AILibraryTools.string(args["filter"]),
           let filter = PhotoFilter(rawValue: raw) {
            photoFilter = filter
        }
        if let raw = AILibraryTools.string(args["sort"]),
           let sort = SortKey(rawValue: raw) {
            sortKey = sort
        }
        if let ascending = args["ascending"] as? Bool {
            sortAscending = ascending
        }
        if let search = AILibraryTools.string(args["search"]) {
            searchText = search
            prepareSemanticSearch()
        }
        return success(["scope": sidebarTitle, "count": visibleCount],
                       summary: "已切换到「\(sidebarTitle)」",
                       photoIDs: [])
    }

    private func selectPhotosTool(_ args: [String: Any]) -> AIToolExecution {
        let ids = resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
            .filter { anyPhoto(id: $0) != nil }
        guard !ids.isEmpty else { return failure("没有找到可选中的照片") }
        selection = Set(ids)
        selectionAnchorID = ids.first
        return success(["count": ids.count],
                       summary: "选中 \(ids.count) 项",
                       photoIDs: ids)
    }

    private func openPhotoTool(_ args: [String: Any]) -> AIToolExecution {
        guard let raw = AILibraryTools.string(args["photo_id"]) else {
            return failure("缺少 photo_id")
        }
        guard let id = resolveAIPhotoIDs([raw]).first(where: { anyPhoto(id: $0) != nil }) else {
            return failure("没有找到这张照片，可先调用 search_photos")
        }
        selection = [id]
        selectionAnchorID = id
        openViewer(id)
        let name = anyPhoto(id: id)?.displayTitle ?? "项目"
        return success(["opened": id.uuidString],
                       summary: "打开「\(name)」",
                       photoIDs: [id])
    }

    // MARK: - 相簿

    private func createAlbumsTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        let specs = AILibraryTools.objectArray(args["albums"])
        guard !specs.isEmpty else { return failure("没有提供要创建的相簿") }

        var created: [[String: Any]] = []
        var summaries: [String] = []
        for spec in specs {
            guard let name = AILibraryTools.string(spec["name"]) else { continue }
            let ids = localPhotoIDs(AILibraryTools.stringArray(spec["photo_ids"]))
            let folderWanted = AILibraryTools.string(spec["folder_id"]) != nil
                || AILibraryTools.string(spec["folder_name"]) != nil
            var folderID: UUID?
            if folderWanted {
                guard let folder = resolveFolder(["folder_id": spec["folder_id"] as Any,
                                                  "folder_name": spec["folder_name"] as Any]) else {
                    return failure("没有找到文件夹「\(AILibraryTools.string(spec["folder_name"]) ?? "")」")
                }
                folderID = folder.id
            }

            if let index = albums.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let existing = Set(albums[index].photoIDs)
                let additions = ids.subtracting(existing)
                let ordered = photos.map(\.id).filter { additions.contains($0) }
                albums[index].photoIDs.append(contentsOf: ordered)
                if let folderID { albums[index].folderID = folderID }
                created.append(["name": albums[index].name, "added": ordered.count, "existing": true])
                summaries.append("更新相簿「\(albums[index].name)」+\(ordered.count) 项")
            } else {
                var album = Album(name: name)
                album.folderID = folderID
                album.photoIDs = photos.map(\.id).filter { ids.contains($0) }
                albums.append(album)
                created.append(["name": name, "added": album.photoIDs.count,
                                "id": album.id.uuidString, "existing": false])
                summaries.append("创建相簿「\(name)」\(album.photoIDs.count) 项")
            }
        }
        guard !created.isEmpty else { return failure("没有有效的相簿名称") }
        save()
        showToast("智能助手已更新 \(created.count) 个相簿")
        return success(["albums": created], summary: summaries.joined(separator: " · "), photoIDs: [])
    }

    private func addToAlbumTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let album = resolveAlbum(args) else {
            return failure("没有找到对应相簿，可先调用 list_albums")
        }
        let ids = localPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !ids.isEmpty else { return failure("没有找到可加入的有效项目") }
        let before = Set(album.photoIDs)
        addToAlbum(album.id, photoIDs: ids)
        let added = Set(album.photoIDs).subtracting(before).count
        return success(["album": album.name, "added": added],
                       summary: "加入相簿「\(album.name)」\(added) 项",
                       photoIDs: [])
    }

    private func removeFromAlbumTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let album = resolveAlbum(args),
              let index = albums.firstIndex(where: { $0.id == album.id }) else {
            return failure("没有找到对应相簿，可先调用 list_albums")
        }
        let ids = Set(resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
        guard !ids.isEmpty else { return failure("没有提供可识别的项目") }
        let before = albums[index].photoIDs.count
        albums[index].photoIDs.removeAll { ids.contains($0) }
        if let cover = albums[index].coverPhotoID, ids.contains(cover) {
            albums[index].coverPhotoID = nil
        }
        let removed = before - albums[index].photoIDs.count
        guard removed > 0 else { return failure("这些项目不在该相簿中") }
        save()
        showToast("已从相簿移出 \(removed) 项")
        return success(["album": albums[index].name, "removed": removed],
                       summary: "从相簿「\(albums[index].name)」移出 \(removed) 项",
                       photoIDs: [])
    }

    private func renameAlbumTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let album = resolveAlbum(args),
              let name = AILibraryTools.string(args["new_name"]) else {
            return failure("没有找到相簿或缺少 new_name")
        }
        renameAlbum(album.id, to: name)
        return success(["album": name], summary: "相簿改名为「\(name)」", photoIDs: [])
    }

    private func deleteAlbumTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let album = resolveAlbum(args) else {
            return failure("没有找到对应相簿，可先调用 list_albums")
        }
        deleteAlbum(album.id)
        return success(["deleted": album.name],
                       summary: "删除相簿「\(album.name)」（照片已保留）",
                       photoIDs: [])
    }

    private func moveAlbumTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let album = resolveAlbum(args) else {
            return failure("没有找到对应相簿，可先调用 list_albums")
        }
        let hasFolderArgument = AILibraryTools.string(args["folder_id"]) != nil
            || AILibraryTools.string(args["folder_name"]) != nil
        var folderID: UUID?
        if hasFolderArgument {
            guard let folder = resolveFolder(args) else {
                return failure("没有找到目标文件夹，可先调用 list_folders")
            }
            folderID = folder.id
        }
        moveAlbum(album.id, toFolder: folderID)
        let place = folderID == nil ? "顶层" : "「\(folderPath(folderID))」"
        return success(["album": album.name, "folder": place],
                       summary: "把相簿「\(album.name)」移到\(place)",
                       photoIDs: [])
    }

    private func setAlbumCoverTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let album = resolveAlbum(args),
              let raw = AILibraryTools.string(args["photo_id"]) else {
            return failure("没有找到相簿或缺少 photo_id")
        }
        guard let id = resolveAIPhotoIDs([raw]).first(where: { album.photoIDs.contains($0) }) else {
            return failure("这个项目不在该相簿中")
        }
        setAlbumCover(id, for: album.id)
        return success(["album": album.name], summary: "已更新相簿「\(album.name)」封面", photoIDs: [])
    }

    // MARK: - 文件夹

    private func createFolderTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let name = AILibraryTools.string(args["name"]) else {
            return failure("缺少文件夹名称")
        }
        var parentID: UUID?
        let hasParent = AILibraryTools.string(args["parent_id"]) != nil
            || AILibraryTools.string(args["parent_name"]) != nil
        if hasParent {
            guard let parent = resolveFolder(["folder_id": args["parent_id"] as Any,
                                              "folder_name": args["parent_name"] as Any]) else {
                return failure("没有找到父文件夹，可先调用 list_folders")
            }
            parentID = parent.id
        }
        guard let id = createFolder(named: name, parentID: parentID) else {
            return failure("文件夹名称无效")
        }
        return success(["id": id.uuidString, "name": name],
                       summary: "新建文件夹「\(name)」",
                       photoIDs: [])
    }

    private func renameFolderTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let folder = resolveFolder(args),
              let name = AILibraryTools.string(args["new_name"]) else {
            return failure("没有找到文件夹或缺少 new_name")
        }
        renameFolder(folder.id, to: name)
        return success(["folder": name], summary: "文件夹改名为「\(name)」", photoIDs: [])
    }

    private func deleteFolderTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let folder = resolveFolder(args) else {
            return failure("没有找到对应文件夹，可先调用 list_folders")
        }
        let albumCount = albums.filter { $0.folderID == folder.id }.count
        deleteFolder(folder.id)
        return success(["deleted": folder.name, "albums": albumCount],
                       summary: "删除文件夹「\(folder.name)」及其中 \(albumCount) 个相簿",
                       photoIDs: [])
    }

    // MARK: - 图片与视频

    private func setFavoriteTool(_ args: [String: Any]) -> AIToolExecution {
        guard canToggleFavorite else { return failure(aiReadOnlyMessage) }
        let favorite = AILibraryTools.bool(args["favorite"], fallback: true)
        let rawIDs = resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !rawIDs.isEmpty else { return failure("没有提供可识别的照片 id") }

        var touched = 0
        let localIDs = localPhotoIDs(rawIDs.map(\.uuidString))
        if !localIDs.isEmpty {
            var changed = false
            for index in photos.indices where localIDs.contains(photos[index].id) {
                if photos[index].isFavorite != favorite {
                    photos[index].isFavorite = favorite
                    changed = true
                }
            }
            if changed { save() }
            touched += localIDs.count
        }

        if canEditNativeOverlay {
            let systemIDs = Set(rawIDs.filter { isSystemPhotoID($0) })
            if !systemIDs.isEmpty {
                setSystemFavorite(favorite, ids: systemIDs)
                touched += systemIDs.count
            }
        }

        let cloudIDs = Set(rawIDs.filter { anyPhoto(id: $0)?.isCloud == true })
        if !cloudIDs.isEmpty {
            setCloudFavorite(favorite, for: cloudIDs)
            touched += cloudIDs.count
        }

        guard touched > 0 else { return failure("没有找到可修改的照片") }
        return success(["favorite": favorite, "count": touched],
                       summary: "\(favorite ? "收藏" : "取消收藏") \(touched) 项",
                       photoIDs: [])
    }

    private func setHiddenTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isReadOnlyScope || canEditNativeOverlay else { return failure(aiReadOnlyMessage) }
        let hidden = AILibraryTools.bool(args["hidden"], fallback: true)
        let ids = Set(resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
            .filter { anyPhoto(id: $0) != nil }
        guard !ids.isEmpty else { return failure("没有找到可修改的项目") }
        setHidden(ids, hidden: hidden)
        return success(["hidden": hidden, "count": ids.count],
                       summary: "\(hidden ? "隐藏" : "取消隐藏") \(ids.count) 项",
                       photoIDs: [])
    }

    private func addKeywordsTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isReadOnlyScope || canEditNativeOverlay else { return failure(aiReadOnlyMessage) }
        let keywords = AILibraryTools.stringArray(args["keywords"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return failure("没有提供关键词") }
        let rawIDs = resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !rawIDs.isEmpty else { return failure("没有提供可识别的照片 id") }

        var touchedIDs: Set<UUID> = []
        let localIDs = localPhotoIDs(rawIDs.map(\.uuidString))
        if !localIDs.isEmpty {
            var changed = false
            for index in photos.indices where localIDs.contains(photos[index].id) {
                var list = photos[index].keywords ?? []
                var added = false
                for keyword in keywords where !list.contains(keyword) {
                    list.append(keyword)
                    added = true
                }
                if added {
                    photos[index].keywords = list
                    changed = true
                    touchedIDs.insert(photos[index].id)
                }
            }
            if changed { save() }
        }

        if canEditNativeOverlay {
            for id in rawIDs where isSystemPhotoID(id) {
                var list = systemPhoto(id: id)?.keywords ?? []
                var added = false
                for keyword in keywords where !list.contains(keyword) {
                    list.append(keyword)
                    added = true
                }
                guard added else { continue }
                setSystemKeywords(list, ids: [id])
                touchedIDs.insert(id)
            }
        }

        guard !touchedIDs.isEmpty else { return failure("这些项目已经包含该关键词") }
        return success(["keywords": keywords, "count": touchedIDs.count],
                       summary: "为 \(touchedIDs.count) 项添加关键词：\(keywords.joined(separator: "、"))",
                       photoIDs: [])
    }

    private func removeKeywordsTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isReadOnlyScope || canEditNativeOverlay else { return failure(aiReadOnlyMessage) }
        let keywords = Set(AILibraryTools.stringArray(args["keywords"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !keywords.isEmpty else { return failure("没有提供关键词") }
        let rawIDs = resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !rawIDs.isEmpty else { return failure("没有提供可识别的照片 id") }

        var touchedIDs: Set<UUID> = []
        let localIDs = localPhotoIDs(rawIDs.map(\.uuidString))
        if !localIDs.isEmpty {
            var changed = false
            for index in photos.indices where localIDs.contains(photos[index].id) {
                guard let list = photos[index].keywords else { continue }
                let filtered = list.filter { !keywords.contains($0) }
                guard filtered.count != list.count else { continue }
                photos[index].keywords = filtered.isEmpty ? nil : filtered
                changed = true
                touchedIDs.insert(photos[index].id)
            }
            if changed { save() }
        }

        if canEditNativeOverlay {
            for id in rawIDs where isSystemPhotoID(id) {
                let list = systemPhoto(id: id)?.keywords ?? []
                let filtered = list.filter { !keywords.contains($0) }
                guard filtered.count != list.count else { continue }
                setSystemKeywords(filtered, ids: [id])
                touchedIDs.insert(id)
            }
        }

        guard !touchedIDs.isEmpty else { return failure("这些项目没有这些关键词") }
        return success(["keywords": Array(keywords), "count": touchedIDs.count],
                       summary: "从 \(touchedIDs.count) 项移除关键词：\(keywords.joined(separator: "、"))",
                       photoIDs: [])
    }

    private func setTitleTool(_ args: [String: Any]) -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard let title = args["title"] as? String else { return failure("缺少 title") }
        let ids = localPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !ids.isEmpty else { return failure("没有找到可修改的项目") }
        batchChangeTargets = ids
        applyBatchChange(title: title, date: nil, place: nil)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return success(["title": trimmed, "count": ids.count],
                       summary: trimmed.isEmpty
                            ? "已清除 \(ids.count) 项的标题"
                            : "为 \(ids.count) 项设置标题「\(trimmed)」",
                       photoIDs: [])
    }

    private func compressPhotosTool(_ args: [String: Any]) async -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard !isCompressing else { return failure("正在压缩，请稍候") }
        let ids = Set(resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
        let targets = photos
            .filter { ids.contains($0.id) && !$0.isVideo && $0.deletedAt == nil }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard !targets.isEmpty else {
            return failure("没有可压缩的照片（视频、系统图库与网盘项目不支持原地压缩）")
        }

        var settings = CompressionSettings()
        if let raw = AILibraryTools.string(args["mode"]),
           let mode = CompressionSettings.Mode(rawValue: raw) {
            settings.mode = mode
        }
        let quality = min(100, max(10, AILibraryTools.integer(args["quality"], fallback: 80)))
        settings.quality = Double(quality) / 100
        settings.maxDimension = settings.mode == .lossless
            ? 0
            : max(0, AILibraryTools.integer(args["max_dimension"], fallback: 0))
        if settings.mode == .lossy,
           let raw = AILibraryTools.string(args["format"]),
           let format = CompressionSettings.Format(rawValue: raw) {
            settings.format = format
        }
        settings.keepBackup = AILibraryTools.bool(args["keep_backup"], fallback: false)
        settings.preserveMetadata = true
        settings.onlyIfSmaller = true

        isCompressing = true
        defer { isCompressing = false }

        var compressed = 0
        var skipped = 0
        var failed = 0
        var savedBytes: Int64 = 0
        for photo in targets {
            if Task.isCancelled { break }
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try PhotoCompressor.compress(photo: photo, settings: settings) }
            }.value
            switch outcome {
            case .success(let result):
                if result.skipped {
                    skipped += 1
                } else {
                    compressed += 1
                    savedBytes += result.savedBytes
                    applyCompressionResult(photoID: photo.id, result: result)
                }
            case .failure:
                failed += 1
            }
        }
        guard compressed > 0 || skipped > 0 || failed > 0 else {
            return failure("压缩已取消")
        }
        save()

        if compressed > 0 {
            showToast("已\(settings.mode.title) \(compressed) 张，节省 \(formatFileSize(savedBytes))")
        } else if failed > 0 {
            showToast("压缩失败 \(failed) 项")
        } else {
            showToast("未产生更小的文件")
        }

        let summary: String
        if compressed > 0 {
            summary = "\(settings.mode.title) \(compressed) 张，节省 \(formatFileSize(savedBytes))"
        } else if skipped > 0 {
            summary = "\(skipped) 张无法再变小，未替换"
        } else {
            summary = "压缩失败 \(failed) 项"
        }
        return success(["compressed": compressed,
                        "skipped": skipped,
                        "failed": failed,
                        "saved_bytes": savedBytes,
                        "mode": settings.mode.rawValue,
                        "quality": quality],
                       summary: summary,
                       photoIDs: [])
    }

    private func beautifyPhotosTool(_ args: [String: Any]) async -> AIToolExecution {
        guard aiLocalWritable else { return failure(aiReadOnlyMessage) }
        guard !isApplyingBeauty else { return failure("正在美化其他照片，请稍候") }
        let ids = Set(resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
        let targets = photos
            .filter { ids.contains($0.id) && !$0.isVideo && $0.deletedAt == nil }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard !targets.isEmpty else {
            return failure("没有可美化的照片（视频、系统图库与网盘项目不支持）")
        }

        let strength = Double(min(150, max(20, AILibraryTools.integer(args["strength"], fallback: 100)))) / 100
        let result = await applyBeauty(to: targets.map(\.id), strength: strength)
        guard result.applied > 0 else { return failure(result.message) }
        return success(["applied": result.applied,
                        "skipped": result.skipped,
                        "strength": Int(strength * 100)],
                       summary: result.message,
                       photoIDs: [])
    }

    private func trashPhotosTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isReadOnlyScope else { return failure(aiReadOnlyMessage) }
        guard sidebarItem != .trash else {
            return failure("当前已在最近删除；为避免误删，智能助手不会永久删除项目")
        }
        let ids = localPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !ids.isEmpty else { return failure("没有找到可移入最近删除的项目") }
        delete(ids)
        return success(["count": ids.count],
                       summary: "把 \(ids.count) 项移入最近删除",
                       photoIDs: [])
    }

    private func restorePhotosTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isReadOnlyScope else { return failure(aiReadOnlyMessage) }
        let rawIDs = Set(resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
        guard !rawIDs.isEmpty else { return failure("没有提供可识别的项目") }
        let trashed = Set(photos.lazy.filter { $0.deletedAt != nil }.map(\.id))
        let ids = rawIDs.intersection(trashed)
        guard !ids.isEmpty else { return failure("这些项目不在最近删除中") }
        restore(ids)
        return success(["count": ids.count],
                       summary: "从最近删除恢复 \(ids.count) 项",
                       photoIDs: [])
    }

    // MARK: - 辅助

    /// 相簿 / 文件夹 / 标题 / 最近删除等写操作只允许在本地图库执行。
    private var aiLocalWritable: Bool {
        !isSystemScope && !isCloudScope && !isNativeContainer
    }

    private var aiReadOnlyMessage: String {
        if isNativeContainer {
            return "当前图库是官方「照片」图库：只能修改收藏、隐藏与关键词"
        }
        return "当前范围是只读来源，请先切换到拾光图库"
    }

    /// 检索范围：跟随当前范围（本地 / 系统图库 / 网盘）。
    private func aiSearchSource() -> [PhotoItem] {
        if isCloudScope { return cloudVisiblePhotos }
        if isSystemScope {
            // 索引模式不常驻整库：检索限定在当前窗口（已在界面上展示的内容）。
            return systemIndex != nil ? systemWindowPhotos : systemPhotos
        }
        return photos
    }

    private func aiMatchesFilter(_ photo: PhotoItem, filter: String) -> Bool {
        switch filter {
        case "photos": return !photo.isVideo
        case "videos": return photo.isVideo
        case "favorites": return photo.isFavorite
        case "screenshots": return photo.kind == .screenshot
        case "edited": return photo.hasEdits
        default: return true
        }
    }

    /// 每个照片 id 所属的相簿名称，用于搜索结果。
    private func aiAlbumNamesByPhotoID() -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for album in albums {
            for id in album.photoIDs {
                result[id, default: []].append(album.name)
            }
        }
        return result
    }

    private func resolveAlbum(_ args: [String: Any]) -> Album? {
        if let raw = AILibraryTools.string(args["album_id"]),
           let id = UUID(uuidString: raw),
           let album = albums.first(where: { $0.id == id }) {
            return album
        }
        if let name = AILibraryTools.string(args["album_name"]) {
            return albums.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return nil
    }

    private func resolveFolder(_ args: [String: Any]) -> AlbumFolder? {
        if let raw = AILibraryTools.string(args["folder_id"]),
           let id = UUID(uuidString: raw),
           let folder = folders.first(where: { $0.id == id }) {
            return folder
        }
        for key in ["folder_name", "parent_name"] {
            if let name = AILibraryTools.string(args[key]) {
                return folders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
        }
        return nil
    }

    /// 只接受当前本地图库中存在且未删除的照片 id。
    private func localPhotoIDs(_ raw: [String]) -> Set<UUID> {
        let ids = Set(resolveAIPhotoIDs(raw))
        guard !ids.isEmpty else { return [] }
        let live = Set(photos.lazy.filter { $0.deletedAt == nil }.map(\.id))
        return ids.intersection(live)
    }

    /// 兼容模型常见的三种引用方式：UUID、候选编号（#3）与唯一文件名。
    private func resolveAIPhotoIDs(_ raw: [String]) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = []
        var nameMap: [String: [UUID]]?

        func append(_ id: UUID) {
            guard seen.insert(id).inserted else { return }
            result.append(id)
        }

        for value in raw {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let id = UUID(uuidString: text) {
                append(id)
                continue
            }

            let indexText = text.hasPrefix("#") ? String(text.dropFirst()) : text
            if let index = Int(indexText), index >= 1, index <= aiLastCandidateIDs.count {
                append(aiLastCandidateIDs[index - 1])
                continue
            }

            if let id = aiLastCandidateNames[text.lowercased()] {
                append(id)
                continue
            }

            if nameMap == nil {
                var map: [String: [UUID]] = [:]
                for list in [photos, systemPhotos, systemWindowPhotos, cloudPhotos] {
                    for photo in list {
                        map[photo.originalName.lowercased(), default: []].append(photo.id)
                        map[photo.filename.lowercased(), default: []].append(photo.id)
                        map[photo.displayTitle.lowercased(), default: []].append(photo.id)
                    }
                }
                nameMap = map
            }
            if let matches = nameMap?[text.lowercased()], matches.count == 1 {
                append(matches[0])
            }
        }
        return result
    }

    private func success(_ payload: [String: Any],
                         summary: String?,
                         photoIDs: [UUID]) -> AIToolExecution {
        var body = payload
        body["ok"] = true
        return AIToolExecution(json: Self.aiJSONString(body) ?? "{\"ok\":true}",
                               summary: summary,
                               photoIDs: photoIDs)
    }

    private func failure(_ message: String) -> AIToolExecution {
        AIToolExecution(json: Self.aiJSONString(["ok": false, "error": message]) ?? "{\"ok\":false}",
                        summary: nil,
                        photoIDs: [])
    }

    private static func aiJSONString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func aiDurationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }

    private static let aiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
