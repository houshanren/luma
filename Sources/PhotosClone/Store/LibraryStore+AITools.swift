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
        case "list_catalog_sources": return listCatalogSourcesTool()
        case "search_catalog": return await searchCatalogTool(args)
        case "list_catalog_following": return listCatalogFollowingTool()
        case "list_catalog_watchlist": return listCatalogWatchlistTool(args)
        case "catalog_new_today": return catalogNewTodayTool(args)
        case "browse_catalog": return browseCatalogTool(args)
        case "play_catalog_item": return playCatalogItemTool(args)
        case "set_catalog_watchlist": return setCatalogWatchlistTool(args)
        case "follow_catalog_person": return followCatalogPersonTool(args)
        case "list_cinema_items": return listCinemaItemsTool(args)
        case "list_cinema_scopes": return listCinemaScopesTool()
        case "cinema_tree": return cinemaTreeTool(args)
        case "search_cinema_candidates": return await searchCinemaCandidatesTool(args)
        case "apply_cinema_match": return applyCinemaMatchTool(args)
        case "scrape_cinema": return scrapeCinemaTool(args)
        case "match_cinema": return await matchCinemaTool(args)
        case "search_cinema_library": return searchCinemaLibraryTool(args)
        case "list_cinema_series": return listCinemaSeriesTool(args)
        case "list_cinema_activity": return listCinemaActivityTool(args)
        case "list_cinema_lists": return listCinemaListsTool(args)
        case "navigate_cinema": return navigateCinemaTool(args)
        case "play_cinema": return playCinemaTool(args)
        case "update_cinema_state": return updateCinemaStateTool(args)
        case "manage_cinema_list": return manageCinemaListTool(args)
        case "ignore_cinema": return ignoreCinemaTool(args)
        case "restore_cinema_ignored": return restoreCinemaIgnoredTool(args)
        case "refresh_cinema_metadata": return await refreshCinemaMetadataTool(args)
        case "set_cinema_intro_skip": return setCinemaIntroSkipTool(args)
        case "manage_cinema_progress": return manageCinemaProgressTool(args)
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
    /// 「一键智能整理」期间，只含影院写工具的一轮直接放行（入口即授权），其它写操作照常确认。
    func confirmAIToolActions(_ calls: [AIToolCall]) -> Bool {
        guard !calls.isEmpty else { return true }
        if aiAutoMatchCinema {
            let cinemaWrites: Set<String> = ["scrape_cinema", "match_cinema", "apply_cinema_match"]
            if calls.allSatisfy({ cinemaWrites.contains($0.name) }) { return true }
        }
        let alert = NSAlert()
        alert.messageText = "智能助手准备修改本地数据"
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

    // MARK: - 网络资源

    private func listCatalogSourcesTool() -> AIToolExecution {
        var items: [[String: Any]] = []
        for source in catalogModel.sources {
            let health = catalogModel.health[source.id] ?? .unknown
            var item: [String: Any] = [
                "source_id": source.id.uuidString,
                "name": source.name,
                "kind": source.kind.rawValue,
                "enabled": source.isEnabled,
                "health": health.title
            ]
            let categories = source.categories.prefix(12).map(\.title)
            if !categories.isEmpty { item["categories"] = Array(categories) }
            items.append(item)
        }
        return success(["count": items.count, "sources": items], summary: nil, photoIDs: [])
    }

    /// 跨源搜索：按侧边栏顺序逐源请求，结果放进 `aiCatalogCandidates`，供后续 ref 引用。
    private func searchCatalogTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let query = AILibraryTools.string(args["query"]) else {
            return failure("请提供要搜索的番号、标题或女优名")
        }
        let perSource = min(30, max(1, AILibraryTools.integer(args["limit"], fallback: 12)))
        var targets = catalogModel.enabledSources
        if let raw = AILibraryTools.string(args["source"]) {
            guard let source = aiResolveCatalogSource(raw) else {
                return failure("没有找到源「\(raw)」，可先调用 list_catalog_sources")
            }
            guard source.isEnabled else {
                return failure("源「\(source.name)」未启用，请先在资源页打开它")
            }
            targets = [source]
        }
        guard !targets.isEmpty else {
            return failure("还没有启用任何网络资源源，请先在资源页启用一个源")
        }

        aiCatalogCandidates.removeAll()
        var groups: [[String: Any]] = []
        var total = 0
        var failed = 0
        for source in targets {
            if Task.isCancelled { break }
            guard let provider = CatalogProviders.provider(for: source.kind) else {
                failed += 1
                continue
            }
            do {
                let page = try await provider.search(source: source, keyword: query, page: 1)
                let picked = Array(page.items.prefix(min(perSource, max(0, 60 - total))))
                guard !picked.isEmpty else { continue }
                var items: [[String: Any]] = []
                for item in picked {
                    total += 1
                    let ref = "#\(total)"
                    aiCatalogCandidates[ref] = (source.id, item)
                    aiCatalogCandidates["\(source.id.uuidString)|\(item.id)"] = (source.id, item)
                    items.append(["ref": ref,
                                  "source_id": source.id.uuidString,
                                  "item_id": item.id,
                                  "title": item.title,
                                  "remark": item.remark])
                }
                groups.append(["source_id": source.id.uuidString,
                               "source": source.name,
                               "items": items])
                if total >= 60 { break }
            } catch {
                failed += 1
            }
        }
        guard !groups.isEmpty else {
            if failed == targets.count {
                return failure("搜索「\(query)」失败：\(failed) 个源都没有返回结果，可能是站点不可达")
            }
            return failure("没有找到匹配「\(query)」的网络资源")
        }
        return success(["query": query, "count": total, "failed_sources": failed, "groups": groups],
                       summary: "网络资源搜索「\(query)」：\(total) 条",
                       photoIDs: [])
    }

    private func listCatalogFollowingTool() -> AIToolExecution {
        let names = Dictionary(uniqueKeysWithValues: catalogModel.sources.map { ($0.id, $0.name) })
        let people = catalogModel.followedPeople.map { person -> [String: Any] in
            [
                "name": person.name,
                "role": person.role,
                "source": names[person.sourceID] ?? "",
                "new_count": person.newCount
            ]
        }
        let categories = catalogModel.followedCategories.map { category -> [String: Any] in
            [
                "title": category.title,
                "source": category.sourceName,
                "source_id": category.sourceID.uuidString,
                "category_id": category.categoryID
            ]
        }
        return success(["people": people, "categories": categories], summary: nil, photoIDs: [])
    }

    private func listCatalogWatchlistTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(100, max(1, AILibraryTools.integer(args["limit"], fallback: 40)))
        let favorites = Array(catalogModel.allFavorites.prefix(limit))
        guard !favorites.isEmpty else {
            return success(["count": 0, "items": []], summary: "稍后看是空的", photoIDs: [])
        }
        let names = Dictionary(uniqueKeysWithValues: catalogModel.sources.map { ($0.id, $0.name) })
        aiCatalogCandidates.removeAll()
        var items: [[String: Any]] = []
        for favorite in favorites {
            let item = CatalogItem(id: favorite.itemID, title: favorite.title,
                                   coverURL: favorite.coverURL, remark: favorite.remark,
                                   categoryID: nil)
            let ref = "#\(items.count + 1)"
            aiCatalogCandidates[ref] = (favorite.sourceID, item)
            aiCatalogCandidates["\(favorite.sourceID.uuidString)|\(favorite.itemID)"] = (favorite.sourceID, item)
            items.append(["ref": ref,
                          "source_id": favorite.sourceID.uuidString,
                          "source": names[favorite.sourceID] ?? "",
                          "item_id": favorite.itemID,
                          "title": favorite.title,
                          "remark": favorite.remark,
                          "added_at": Self.aiDateFormatter.string(from: favorite.addedAt)])
        }
        return success(["count": items.count, "items": items],
                       summary: "稍后看共 \(items.count) 条",
                       photoIDs: [])
    }

    private func catalogNewTodayTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(100, max(1, AILibraryTools.integer(args["limit"], fallback: 40)))
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let today = catalogModel.calendarItems
            .filter { $0.firstSeen >= start && $0.firstSeen < end }
            .sorted { $0.firstSeen > $1.firstSeen }
        guard !today.isEmpty else {
            return success(["count": 0, "items": []], summary: "今天还没有记录到新条目", photoIDs: [])
        }
        let names = Dictionary(uniqueKeysWithValues: catalogModel.sources.map { ($0.id, $0.name) })
        aiCatalogCandidates.removeAll()
        var items: [[String: Any]] = []
        for entry in today.prefix(limit) {
            let ref = "#\(items.count + 1)"
            aiCatalogCandidates[ref] = (entry.sourceID, entry.item)
            aiCatalogCandidates["\(entry.sourceID.uuidString)|\(entry.itemID)"] = (entry.sourceID, entry.item)
            items.append(["ref": ref,
                          "source_id": entry.sourceID.uuidString,
                          "source": names[entry.sourceID] ?? "",
                          "item_id": entry.itemID,
                          "title": entry.title,
                          "remark": entry.remark,
                          "first_seen": Self.aiDateFormatter.string(from: entry.firstSeen)])
        }
        return success(["count": items.count, "items": items],
                       summary: "今天新增 \(items.count) 条网络资源",
                       photoIDs: [])
    }

    private func browseCatalogTool(_ args: [String: Any]) -> AIToolExecution {
        let source: CatalogSource
        if let raw = AILibraryTools.string(args["source"]) {
            guard let resolved = aiResolveCatalogSource(raw) else {
                return failure("没有找到源「\(raw)」，可先调用 list_catalog_sources")
            }
            source = resolved
        } else if let current = catalogModel.selectedSource ?? catalogModel.enabledSources.first {
            source = current
        } else {
            return failure("还没有启用任何网络资源源")
        }

        catalogModel.hubTab = .browse
        openCatalogSource(source.id)

        let section = AILibraryTools.string(args["section"]) ?? "home"
        var title = "首页"
        switch section {
        case "rank":
            catalogModel.openRank()
            title = "排行"
        case "favorites":
            catalogModel.openFavorites()
            title = "稍后看"
        case "category":
            guard let raw = AILibraryTools.string(args["category"]) else {
                return failure("请提供分类名称或分类 id")
            }
            guard let category = aiResolveCatalogCategory(raw) else {
                let available = catalogModel.categories.prefix(10).map(\.title).joined(separator: "、")
                return failure("在「\(source.name)」里没有找到分类「\(raw)」，可用分类：\(available)")
            }
            catalogModel.openCategory(category)
            title = category.title
        default:
            catalogModel.openHome()
        }
        return success(["source_id": source.id.uuidString, "source": source.name, "section": section],
                       summary: "已打开「\(source.name)」的\(title)",
                       photoIDs: [])
    }

    private func playCatalogItemTool(_ args: [String: Any]) -> AIToolExecution {
        guard let target = aiResolveCatalogCandidate(args) else {
            return failure("找不到要播放的条目，请先调用 search_catalog 或 catalog_new_today 获取 ref")
        }
        guard let source = catalogModel.sources.first(where: { $0.id == target.sourceID }) else {
            return failure("这个源已经不存在了")
        }
        guard source.isEnabled else {
            return failure("源「\(source.name)」未启用")
        }
        catalogModel.playRemote(sourceID: source.id, item: target.item)
        return success(["source_id": source.id.uuidString, "item_id": target.item.id],
                       summary: "开始播放《\(target.item.title)》",
                       photoIDs: [])
    }

    private func setCatalogWatchlistTool(_ args: [String: Any]) -> AIToolExecution {
        let favorite = AILibraryTools.bool(args["favorite"], fallback: true)
        var resolved: [(UUID, CatalogItem)] = []
        for raw in AILibraryTools.stringArray(args["refs"]) {
            if let hit = aiResolveCatalogCandidate(["ref": raw]) {
                resolved.append((hit.sourceID, hit.item))
            }
        }
        if let rawSource = AILibraryTools.string(args["source_id"]),
           let sourceID = UUID(uuidString: rawSource) {
            for itemID in AILibraryTools.stringArray(args["item_ids"]) {
                if let item = aiCatalogItem(sourceID: sourceID, itemID: itemID) {
                    resolved.append((sourceID, item))
                }
            }
        }
        guard !resolved.isEmpty else {
            return failure("没有可操作的条目，请先调用 search_catalog 获取 ref")
        }

        var grouped: [UUID: [CatalogItem]] = [:]
        for (sourceID, item) in resolved {
            grouped[sourceID, default: []].append(item)
        }
        var changed = 0
        for (sourceID, items) in grouped {
            guard let source = catalogModel.sources.first(where: { $0.id == sourceID }) else { continue }
            changed += items.filter {
                catalogModel.isFavorite(sourceID: sourceID, itemID: $0.id) != favorite
            }.count
            catalogModel.setFavorite(favorite, source: source, items: items)
        }
        return success(["count": changed, "favorite": favorite],
                       summary: "\(favorite ? "加入" : "移出")稍后看 \(changed) 条",
                       photoIDs: [])
    }

    private func followCatalogPersonTool(_ args: [String: Any]) -> AIToolExecution {
        guard let name = AILibraryTools.string(args["name"]) else {
            return failure("请提供要关注的人物或片商名称")
        }
        let rawRole = AILibraryTools.string(args["role"]) ?? "女优"
        let roleMap = ["actress": "女优", "studio": "片商", "model": "模特"]
        let role = roleMap[rawRole.lowercased()] ?? rawRole

        let source: CatalogSource?
        if let raw = AILibraryTools.string(args["source"]) {
            source = aiResolveCatalogSource(raw)
        } else {
            source = catalogModel.selectedSource ?? catalogModel.enabledSources.first
        }
        guard let source else {
            return failure("还没有可用的网络资源源")
        }
        if catalogModel.isFollowingPerson(name: name, role: role) {
            return success(["followed": true, "name": name, "role": role],
                           summary: "已经关注过\(role)「\(name)」",
                           photoIDs: [])
        }
        catalogModel.toggleFollowPerson(name: name, role: role, sourceID: source.id)
        return success(["followed": true, "name": name, "role": role,
                        "source_id": source.id.uuidString],
                       summary: "已关注\(role)「\(name)」",
                       photoIDs: [])
    }

    private func aiResolveCatalogSource(_ raw: String) -> CatalogSource? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = UUID(uuidString: text),
           let source = catalogModel.sources.first(where: { $0.id == id }) {
            return source
        }
        if let exact = catalogModel.sources.first(where: {
            $0.name.caseInsensitiveCompare(text) == .orderedSame
        }) {
            return exact
        }
        let lower = text.lowercased()
        if let kind = catalogModel.sources.first(where: { $0.kind.rawValue.lowercased() == lower }) {
            return kind
        }
        return catalogModel.sources.first { $0.name.localizedCaseInsensitiveContains(text) }
    }

    private func aiResolveCatalogCategory(_ raw: String) -> CatalogCategory? {
        func visit(_ list: [CatalogCategory], exact: Bool) -> CatalogCategory? {
            for category in list {
                let matched = exact
                    ? (category.id.caseInsensitiveCompare(raw) == .orderedSame
                        || category.title.caseInsensitiveCompare(raw) == .orderedSame)
                    : category.title.localizedCaseInsensitiveContains(raw)
                if matched { return category }
                if let children = category.children,
                   let hit = visit(children, exact: exact) {
                    return hit
                }
            }
            return nil
        }
        return visit(catalogModel.categories, exact: true)
            ?? visit(catalogModel.categories, exact: false)
    }

    /// 解析播放 / 稍后看的参数：优先用 ref，其次用 source_id + item_id。
    private func aiResolveCatalogCandidate(_ args: [String: Any]) -> (sourceID: UUID, item: CatalogItem)? {
        if let raw = AILibraryTools.string(args["ref"]) {
            let key = raw.hasPrefix("#") ? raw : "#\(raw)"
            if let hit = aiCatalogCandidates[key] { return hit }
        }
        guard let rawSource = AILibraryTools.string(args["source_id"]),
              let sourceID = UUID(uuidString: rawSource),
              let itemID = AILibraryTools.string(args["item_id"]) else { return nil }
        if let hit = aiCatalogCandidates["\(sourceID.uuidString)|\(itemID)"] { return hit }
        guard let item = aiCatalogItem(sourceID: sourceID, itemID: itemID) else { return nil }
        return (sourceID, item)
    }

    /// 没经过搜索时，从稍后看 / 日历 / 总榜 / 当前列表里找回条目的标题与封面。
    private func aiCatalogItem(sourceID: UUID, itemID: String) -> CatalogItem? {
        if let hit = aiCatalogCandidates["\(sourceID.uuidString)|\(itemID)"] { return hit.item }
        if let favorite = catalogModel.favorites["\(sourceID.uuidString)|\(itemID)"] {
            return CatalogItem(id: favorite.itemID, title: favorite.title,
                               coverURL: favorite.coverURL, remark: favorite.remark,
                               categoryID: nil)
        }
        if let entry = catalogModel.calendarItems.first(where: {
            $0.sourceID == sourceID && $0.itemID == itemID
        }) {
            return entry.item
        }
        if let spot = catalogModel.todaySpotlight.first(where: {
            $0.sourceID == sourceID && $0.item.id == itemID
        }) {
            return spot.item
        }
        if catalogModel.selectedSourceID == sourceID,
           let live = catalogModel.items.first(where: { $0.id == itemID }) {
            return live
        }
        for playlist in catalogModel.playlists {
            if let entry = playlist.entries.first(where: {
                $0.sourceID == sourceID && $0.itemID == itemID
            }) {
                return entry.item
            }
        }
        // 详情页会补上真实标题与封面，这里只保证 id 可用。
        return CatalogItem(id: itemID, title: itemID, coverURL: "", remark: "", categoryID: nil)
    }

    // MARK: - 影院

    /// 影院工具都作用于当前影院（本地图库或某个网盘），与影院页保持一致。
    var aiCinemaScope: CinemaScope { cinemaActiveScope }

    /// 把文件夹树拍平，便于按名称 / 路径匹配与统计。
    func aiAllCinemaFolders(in scope: CinemaScope) -> [CinemaFolder] {
        var result: [CinemaFolder] = []
        var stack = cinemaFolders(for: scope)
        while let folder = stack.popLast() {
            result.append(folder)
            stack.append(contentsOf: folder.children)
        }
        return result
    }

    func aiCinemaFolderMatches(_ folder: CinemaFolder, query: String) -> Bool {
        let text = query.lowercased()
        return folder.name.lowercased().contains(text)
            || folder.path.lowercased().contains(text)
            || (folder.hint?.lowercased().contains(text) ?? false)
    }

    func aiCinemaEntryMatches(_ entry: CinemaEntry, query: String) -> Bool {
        let text = query.lowercased()
        return entry.file.filename.lowercased().contains(text)
            || entry.title.lowercased().contains(text)
            || (entry.folderHint?.lowercased().contains(text) ?? false)
    }

    // MARK: - 影院 · 一键智能整理

    /// 解析工具传入的 scope：local / 网盘 id / 网盘名称；省略时用当前影院。
    func aiResolvedCinemaScope(_ raw: String?) -> CinemaScope? {
        guard let raw else { return cinemaActiveScope }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "active" || text == "当前影院" { return cinemaActiveScope }
        if text.lowercased() == "local" || text == "本地图库" { return .local }
        if let id = UUID(uuidString: text), cloudMounts.contains(where: { $0.id == id }) {
            return .mount(id)
        }
        if let mount = cloudMounts.first(where: { $0.name == text }) {
            return .mount(mount.id)
        }
        return nil
    }

    func aiResolveCinemaFolder(_ query: String, in scope: CinemaScope) -> CinemaFolder? {
        let folders = aiAllCinemaFolders(in: scope)
        if let exact = folders.first(where: { $0.path == query }) { return exact }
        return folders.first(where: { aiCinemaFolderMatches($0, query: query) })
    }

    private func listCinemaScopesTool() -> AIToolExecution {
        var items: [[String: Any]] = []
        func append(_ scope: CinemaScope, name: String) {
            let total = cinemaCandidates(for: scope).count
            let matched = cinemaEntries(for: scope).values.filter(\.matched).count
            items.append([
                "id": Self.cinemaScopeKey(scope),
                "name": name,
                "active": scope == cinemaActiveScope,
                "videos": total,
                "matched": matched,
                "unmatched": max(0, total - matched)
            ])
        }
        append(.local, name: "本地图库")
        for mount in cloudMounts {
            append(.mount(mount.id), name: mount.name)
        }
        return success(["active": Self.cinemaScopeKey(cinemaActiveScope), "scopes": items],
                       summary: nil,
                       photoIDs: [])
    }

    private func cinemaTreeTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let folderQuery = AILibraryTools.string(args["folder"])
        let onlyUnmatched = AILibraryTools.bool(args["only_unmatched"], fallback: false)
        let limit = min(200, max(1, AILibraryTools.integer(args["limit"], fallback: 80)))
        let entries = cinemaEntries(for: scope)
        let candidates = cinemaCandidates(for: scope)
        var candidateByID: [UUID: CinemaCandidate] = [:]
        for candidate in candidates { candidateByID[candidate.photo.id] = candidate }

        var current: CinemaFolder?
        if let folderQuery {
            guard let folder = aiResolveCinemaFolder(folderQuery, in: scope) else {
                return failure("没有找到「\(folderQuery)」文件夹；可先不传 folder 查看顶层目录")
            }
            current = folder
        }

        let children = current?.children ?? cinemaFolders(for: scope)
        let folderItems: [[String: Any]] = children
            .sorted { lhs, rhs in
                if lhs.subtreePhotos.count != rhs.subtreePhotos.count {
                    return lhs.subtreePhotos.count > rhs.subtreePhotos.count
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(60)
            .map { folder in
                var item: [String: Any] = [
                    "name": folder.name,
                    "path": folder.path,
                    "videos": folder.photos.count,
                    "subtree_videos": folder.subtreePhotos.count,
                    "matched": folder.matchedCount,
                    "unmatched": folder.unmatchedCount,
                    "children": folder.children.count
                ]
                if let hint = folder.hint, !hint.isEmpty { item["hint"] = hint }
                if let title = folder.title, !title.isEmpty { item["title"] = title }
                return item
            }

        let photos: [PhotoItem]
        if let current {
            photos = current.photos
        } else {
            // 顶层调用时把没有目录归属的散片也列出来，避免根目录视频被漏掉。
            photos = candidates.filter { $0.folderPath == nil }.map(\.photo)
        }
        let sortedPhotos = photos.sorted {
            $0.displayFilename.localizedStandardCompare($1.displayFilename) == .orderedAscending
        }

        var videoItems: [[String: Any]] = []
        var truncated = false
        for photo in sortedPhotos {
            let entry = entries[photo.id]
            if onlyUnmatched, entry?.matched == true { continue }
            guard videoItems.count < limit else {
                truncated = true
                break
            }
            videoItems.append(aiCinemaVideoInfo(photo: photo,
                                                entry: entry,
                                                candidate: candidateByID[photo.id]))
        }

        let matched = entries.values.filter(\.matched).count
        var payload: [String: Any] = [
            "scope": ["id": Self.cinemaScopeKey(scope), "name": cinemaScopeName(scope)],
            "total": candidates.count,
            "matched": matched,
            "unmatched": max(0, candidates.count - matched),
            "folders": folderItems,
            "videos": videoItems
        ]
        if let current {
            payload["folder"] = ["path": current.path,
                                 "name": current.name,
                                 "hint": current.hint ?? current.name]
        }
        if truncated { payload["truncated"] = true }
        return success(payload,
                       summary: current.map { "查看「\($0.name)」：\($0.photos.count) 个视频" }
                           ?? "查看影院目录：\(children.count) 个文件夹",
                       photoIDs: [])
    }

    private func aiCinemaVideoInfo(photo: PhotoItem,
                                   entry: CinemaEntry?,
                                   candidate: CinemaCandidate?) -> [String: Any] {
        let hint = candidate?.folderHint ?? entry?.folderHint
        let parsed = CinemaScraper.parse(filename: photo.displayFilename, folderHint: hint)
        var item: [String: Any] = [
            "id": photo.id.uuidString,
            "filename": photo.displayFilename,
            "parsed_title": parsed.title,
            "kind": parsed.isTV ? "tv" : "movie",
            "matched": entry?.matched ?? false
        ]
        if let alt = parsed.altTitle, !alt.isEmpty { item["parsed_alt_title"] = alt }
        if let year = parsed.year { item["parsed_year"] = year }
        if let season = parsed.season { item["season"] = season }
        if let episode = parsed.episode { item["episode"] = episode }
        if let end = parsed.episodeEnd { item["episode_end"] = end }
        if let hint, !hint.isEmpty { item["folder"] = hint }
        if let resolution = parsed.resolution { item["parsed_resolution"] = resolution }
        if let entry, entry.matched {
            item["match_title"] = entry.title
            if let year = entry.year { item["match_year"] = year }
            if let season = entry.season { item["match_season"] = season }
            if let episode = entry.episode { item["match_episode"] = episode }
            if let tmdb = entry.tmdbID { item["tmdb_id"] = tmdb }
        }
        if photo.pixelWidth > 0 {
            item["resolution"] = "\(photo.pixelWidth)x\(photo.pixelHeight)"
        }
        return item
    }

    private func searchCinemaCandidatesTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let query = AILibraryTools.string(args["query"]) else {
            return failure("缺少 query")
        }
        let isTV = AILibraryTools.bool(args["is_tv"], fallback: false)
        let rawYear = AILibraryTools.integer(args["year"], fallback: 0)
        let year: Int? = rawYear > 0 ? rawYear : nil
        let limit = min(10, max(1, AILibraryTools.integer(args["limit"], fallback: 5)))

        let result = await cinemaSearchCandidates(query: query, isTV: isTV, year: year)
        guard !result.matches.isEmpty else {
            return failure(result.error ?? "没有找到「\(query)」的候选；可只保留核心片名、去掉年份再试")
        }

        var items: [[String: Any]] = []
        for match in result.matches.prefix(limit) {
            aiCinemaCandidateCache[match.id] = match
            var item: [String: Any] = [
                "candidate_id": match.id,
                "provider": match.provider?.rawValue ?? "unknown",
                "title": match.title,
                "is_tv": match.isTV
            ]
            if let original = match.originalTitle, !original.isEmpty {
                item["original_title"] = original
            }
            if let year = match.year { item["year"] = year }
            if let rating = match.rating, rating > 0 { item["rating"] = rating }
            if let votes = match.voteCount, votes > 0 { item["votes"] = votes }
            if let overview = match.overview, !overview.isEmpty {
                item["overview"] = String(overview.prefix(220))
            }
            // 只给前三个 TMDB 剧集补季数 / 集数，控制请求数量。
            if match.isTV, match.provider == .tmdb, items.count < 3, let id = Int(match.id),
               let details = await cinemaDetails(id: id, isTV: true) {
                if let seasons = details.seasonCount, seasons > 0 { item["season_count"] = seasons }
                if let episodes = details.episodeCount, episodes > 0 { item["episode_count"] = episodes }
            }
            items.append(item)
        }
        if aiCinemaCandidateCache.count > 300 { aiCinemaCandidateCache.removeAll() }
        let names = items.prefix(3).compactMap { $0["title"] as? String }.joined(separator: "、")
        return success(["query": query, "is_tv": isTV, "candidates": items],
                       summary: "找到 \(items.count) 个候选：\(names)",
                       photoIDs: [])
    }

    private func applyCinemaMatchTool(_ args: [String: Any]) -> AIToolExecution {
        guard let candidateID = AILibraryTools.string(args["candidate_id"]) else {
            return failure("缺少 candidate_id；请先调用 search_cinema_candidates 拿到候选")
        }
        guard let match = aiCinemaCandidateCache[candidateID] else {
            return failure("候选 \(candidateID) 已失效；请重新调用 search_cinema_candidates")
        }
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }

        var photoByID: [UUID: PhotoItem] = [:]
        var folderHints: [UUID: String] = [:]
        for candidate in cinemaCandidates(for: scope) {
            photoByID[candidate.photo.id] = candidate.photo
            if let hint = candidate.folderHint, !hint.isEmpty {
                folderHints[candidate.photo.id] = hint
            }
        }

        var photos: [PhotoItem] = []
        var folderName: String?
        let rawIDs = AILibraryTools.stringArray(args["photo_ids"])
        if !rawIDs.isEmpty {
            var missing: [String] = []
            for raw in rawIDs {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = UUID(uuidString: text), let photo = photoByID[id] {
                    photos.append(photo)
                } else if let photo = photoByID.values.first(where: { $0.displayFilename == text }) {
                    photos.append(photo)
                } else {
                    missing.append(text)
                }
            }
            guard photos.count == rawIDs.count else {
                return failure("这些视频不在当前影院：\(missing.prefix(3).joined(separator: "、"))")
            }
        } else if let query = AILibraryTools.string(args["folder"]) {
            guard let folder = aiResolveCinemaFolder(query, in: scope) else {
                return failure("没有找到「\(query)」文件夹；可先调用 cinema_tree 查看路径")
            }
            folderName = folder.name
            photos = folder.photos
            guard !photos.isEmpty else {
                if !folder.children.isEmpty {
                    let names = folder.children.prefix(6).map(\.name).joined(separator: "、")
                    return failure("「\(folder.name)」没有直属视频，下面还有：\(names)。请用 cinema_tree 展开到季目录再应用")
                }
                return failure("「\(folder.name)」里没有视频")
            }
        } else {
            return failure("请用 folder 指定文件夹，或用 photo_ids 指定视频")
        }

        var episodes: [UUID: Int] = [:]
        for item in AILibraryTools.objectArray(args["episodes"]) {
            guard let raw = AILibraryTools.string(item["photo_id"]),
                  let id = UUID(uuidString: raw) else { continue }
            let value = AILibraryTools.integer(item["episode"], fallback: 0)
            if value > 0 { episodes[id] = value }
        }
        let rawSeason = AILibraryTools.integer(args["season"], fallback: 0)
        let season: Int? = rawSeason > 0 ? rawSeason : nil

        let applied = applyCinemaMatch(match, to: photos, season: season,
                                       episodes: episodes, folderHints: folderHints)
        guard applied > 0 else { return failure("写回失败，请稍后再试") }

        let updated = cinemaEntries(for: scope)
        var results: [[String: Any]] = []
        for photo in photos.prefix(200) {
            guard let entry = updated[photo.id] else { continue }
            var item: [String: Any] = [
                "id": photo.id.uuidString,
                "filename": entry.file.filename,
                "matched": entry.matched
            ]
            if let season = entry.season { item["season"] = season }
            if let episode = entry.episode { item["episode"] = episode }
            results.append(item)
        }

        var summary = "已匹配「\(match.title)」· \(applied) 个视频"
        if match.isTV, let season = results.compactMap({ $0["season"] as? Int }).first {
            summary = "已匹配「\(match.title)」· 第 \(season) 季 · \(applied) 集"
        }
        return success(["scope": cinemaScopeName(scope),
                        "candidate_id": candidateID,
                        "title": match.title,
                        "folder": folderName ?? "",
                        "applied": applied,
                        "videos": results],
                       summary: summary,
                       photoIDs: photos.map(\.id))
    }

    private func listCinemaItemsTool(_ args: [String: Any]) -> AIToolExecution {
        let scope = aiCinemaScope
        let allEntries = Array(cinemaEntries(for: scope).values)
        let folderQuery = AILibraryTools.string(args["folder"])
        let onlyUnmatched = AILibraryTools.bool(args["only_unmatched"], fallback: false)
        let limit = min(100, max(1, AILibraryTools.integer(args["limit"], fallback: 30)))

        var folderItems: [[String: Any]] = []
        for folder in aiAllCinemaFolders(in: scope)
            .sorted(by: { $0.subtreePhotos.count > $1.subtreePhotos.count }) {
            if let folderQuery, !aiCinemaFolderMatches(folder, query: folderQuery) { continue }
            folderItems.append([
                "name": folder.name,
                "path": folder.path,
                "videos": folder.subtreePhotos.count,
                "matched": folder.matchedCount
            ])
            if folderItems.count >= 40 { break }
        }

        var items: [[String: Any]] = []
        for entry in allEntries.sorted(by: { $0.file.capturedAt > $1.file.capturedAt }) {
            if let folderQuery, !aiCinemaEntryMatches(entry, query: folderQuery) { continue }
            if onlyUnmatched, entry.matched { continue }
            var item: [String: Any] = [
                "filename": entry.file.filename,
                "title": entry.title,
                "matched": entry.matched,
                "kind": entry.kind == .tv ? "tv" : "movie",
                "resolution": entry.file.pixelWidth > 0
                    ? "\(entry.file.pixelWidth)x\(entry.file.pixelHeight)" : ""
            ]
            if let year = entry.year { item["year"] = year }
            if let season = entry.season { item["season"] = season }
            if let episode = entry.episode { item["episode"] = episode }
            if let hint = entry.folderHint { item["folder"] = hint }
            items.append(item)
            if items.count >= limit { break }
        }

        let matched = allEntries.filter(\.matched).count
        return success(["scope": cinemaScopeName(scope),
                        "total": allEntries.count,
                        "matched": matched,
                        "unmatched": allEntries.count - matched,
                        "folders": folderItems,
                        "videos": items],
                       summary: nil,
                       photoIDs: [])
    }

    private func scrapeCinemaTool(_ args: [String: Any]) -> AIToolExecution {
        guard !cinemaScrapeRunning else {
            return failure("已有刮削任务在进行中，等它结束再试")
        }
        let scope = aiCinemaScope
        let name = cinemaScopeName(scope)
        let force = AILibraryTools.bool(args["force"], fallback: false)

        if let query = AILibraryTools.string(args["folder"]) {
            guard let folder = aiAllCinemaFolders(in: scope)
                .first(where: { aiCinemaFolderMatches($0, query: query) }) else {
                return failure("当前影院没有找到匹配「\(query)」的文件夹，可先调用 list_cinema_items")
            }
            guard !folder.subtreePhotos.isEmpty else {
                return failure("「\(folder.name)」里没有可刮削的视频")
            }
            Task { await self.scrapeCinemaFolder(folder, scope: scope) }
            return success(["started": true,
                            "scope": name,
                            "folder": folder.path,
                            "videos": folder.subtreePhotos.count],
                           summary: "开始刮削「\(folder.name)」（\(folder.subtreePhotos.count) 个视频，含子文件夹）",
                           photoIDs: [])
        }

        let total = cinemaEntries(for: scope).count
        guard total > 0 else {
            return failure("这个影院还没有视频清单，先在「相簿」里扫描网盘")
        }
        startCinemaScrape(for: scope, force: force)
        return success(["started": true, "scope": name, "videos": total],
                       summary: "开始刮削「\(name)」（\(total) 个视频）",
                       photoIDs: [])
    }

    private func matchCinemaTool(_ args: [String: Any]) async -> AIToolExecution {
        let scope = aiCinemaScope
        let allEntries = Array(cinemaEntries(for: scope).values)
        let unmatched = allEntries.filter { !$0.matched }
        guard !unmatched.isEmpty else {
            return failure("当前影院没有未识别的视频")
        }

        let target = AILibraryTools.string(args["target"])
        let queryOverride = AILibraryTools.string(args["query"])
        let isTVOverride = args["is_tv"] as? Bool
        let rawYear = AILibraryTools.integer(args["year"], fallback: 0)
        let yearOverride: Int? = rawYear > 0 ? rawYear : nil
        let limit = min(20, max(1, AILibraryTools.integer(args["limit"], fallback: 10)))

        var targets: [CinemaEntry] = []
        if let target {
            if let folder = aiAllCinemaFolders(in: scope)
                .first(where: { aiCinemaFolderMatches($0, query: target) }) {
                let ids = Set(folder.subtreePhotos.map(\.id))
                targets = unmatched.filter { ids.contains($0.id) }
            }
            if targets.isEmpty {
                targets = unmatched.filter { aiCinemaEntryMatches($0, query: target) }
            }
            guard !targets.isEmpty else {
                return failure("没有找到匹配「\(target)」的未识别视频，可先调用 list_cinema_items")
            }
        } else {
            targets = unmatched
        }
        targets.sort { $0.file.filename.localizedStandardCompare($1.file.filename) == .orderedAscending }

        var cache: [String: [CinemaMatch]] = [:]
        var applied: [String] = []
        var skipped: [String] = []

        for entry in targets.prefix(limit) {
            let query = queryOverride ?? entry.title
            let isTV = isTVOverride ?? (entry.kind == .tv)
            let year = yearOverride ?? entry.year
            let key = "\(query)|\(isTV)|\(year ?? 0)"
            let matches: [CinemaMatch]
            if let cached = cache[key] {
                matches = cached
            } else {
                let result = await cinemaSearchCandidates(query: query, isTV: isTV, year: year)
                matches = result.matches
                if matches.isEmpty, let error = result.error {
                    skipped.append("\(entry.file.filename)（\(error)）")
                    continue
                }
                if !matches.isEmpty { cache[key] = matches }
            }
            guard let best = matches.first else {
                skipped.append(entry.file.filename)
                continue
            }
            if applyCinemaMatch(best, to: entry) != nil {
                applied.append("\(entry.title) → \(best.title)")
            } else {
                skipped.append(entry.file.filename)
            }
        }

        let summary: String
        if applied.isEmpty {
            summary = "没有匹配成功：\(skipped.prefix(3).joined(separator: "、"))"
        } else {
            summary = "已匹配 \(applied.count) 条：\(applied.prefix(3).joined(separator: "、"))"
        }
        return success(["scope": cinemaScopeName(scope),
                        "attempted": min(limit, targets.count),
                        "matched": applied.count,
                        "results": applied,
                        "skipped": skipped],
                       summary: summary,
                       photoIDs: [])
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

    func success(_ payload: [String: Any],
                 summary: String?,
                 photoIDs: [UUID]) -> AIToolExecution {
        var body = payload
        body["ok"] = true
        return AIToolExecution(json: Self.aiJSONString(body) ?? "{\"ok\":true}",
                               summary: summary,
                               photoIDs: photoIDs)
    }

    func failure(_ message: String) -> AIToolExecution {
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
