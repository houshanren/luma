import Foundation

extension LibraryStore {
    // MARK: - 网络资源

    func listCatalogSourcesTool() -> AIToolExecution {
        var items: [[String: Any]] = []
        // 只列网络资源的网页资源站；影视源由 list_network_cinema_sources 单独提供。
        for source in catalogModel.resourceSources {
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
    func searchCatalogTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let query = AILibraryTools.string(args["query"]) else {
            return failure("请提供要搜索的番号、标题或女优名")
        }
        let perSource = min(60, max(1, AILibraryTools.integer(args["limit"], fallback: 30)))
        var targets = catalogModel.enabledResourceSources
        if let raw = AILibraryTools.string(args["source"]) {
            guard let source = aiResolveCatalogSource(raw) else {
                return failure("没有找到源「\(raw)」，可先调用 list_catalog_sources")
            }
            guard source.domain == .networkResource else {
                return failure("源「\(source.name)」是影视源，请改用网络影院的工具体系")
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
                let picked = Array(page.items.prefix(min(perSource, max(0, 200 - total))))
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
                if total >= 200 { break }
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

    func listCatalogFollowingTool() -> AIToolExecution {
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

    func listCatalogWatchlistTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(500, max(1, AILibraryTools.integer(args["limit"], fallback: 100)))
        let favorites = Array(catalogModel.resourceFavorites.prefix(limit))
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

    func catalogNewTodayTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(500, max(1, AILibraryTools.integer(args["limit"], fallback: 100)))
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let today = catalogModel.calendarItems
            .filter { catalogModel.resourceSourceIDs.contains($0.sourceID) }
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

    func browseCatalogTool(_ args: [String: Any]) -> AIToolExecution {
        let source: CatalogSource
        if let raw = AILibraryTools.string(args["source"]) {
            guard let resolved = aiResolveCatalogSource(raw) else {
                return failure("没有找到源「\(raw)」，可先调用 list_catalog_sources")
            }
            source = resolved
        } else if let current = catalogModel.selectedSource,
                  current.domain == .networkResource {
            source = current
        } else if let first = catalogModel.enabledResourceSources.first {
            source = first
        } else {
            return failure("还没有启用任何网络资源源")
        }
        guard source.domain == .networkResource else {
            return failure("源「\(source.name)」是影视源，请改用网络影院的工具体系")
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

    func playCatalogItemTool(_ args: [String: Any]) -> AIToolExecution {
        guard let target = aiResolveCatalogCandidate(args) else {
            return failure("找不到要播放的条目，请先调用 search_catalog 或 catalog_new_today 获取 ref")
        }
        guard let source = catalogModel.sources.first(where: { $0.id == target.sourceID }) else {
            return failure("这个源已经不存在了")
        }
        guard source.domain == .networkResource else {
            return failure("「\(target.item.title)」属于网络影院，请改用网络影院的播放工具")
        }
        guard source.isEnabled else {
            return failure("源「\(source.name)」未启用")
        }
        catalogModel.playRemote(sourceID: source.id, item: target.item)
        return success(["source_id": source.id.uuidString, "item_id": target.item.id],
                       summary: "开始播放《\(target.item.title)》",
                       photoIDs: [])
    }

    func setCatalogWatchlistTool(_ args: [String: Any]) -> AIToolExecution {
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
            guard let source = catalogModel.sources.first(where: { $0.id == sourceID }),
                  source.domain == .networkResource else { continue }
            changed += items.filter {
                catalogModel.isFavorite(sourceID: sourceID, itemID: $0.id) != favorite
            }.count
            catalogModel.setFavorite(favorite, source: source, items: items)
        }
        return success(["count": changed, "favorite": favorite],
                       summary: "\(favorite ? "加入" : "移出")稍后看 \(changed) 条",
                       photoIDs: [])
    }

    func followCatalogPersonTool(_ args: [String: Any]) -> AIToolExecution {
        guard let name = AILibraryTools.string(args["name"]) else {
            return failure("请提供要关注的人物或片商名称")
        }
        let rawRole = AILibraryTools.string(args["role"]) ?? "女优"
        let roleMap = ["actress": "女优", "studio": "片商", "model": "模特"]
        let role = roleMap[rawRole.lowercased()] ?? rawRole

        let source: CatalogSource?
        if let raw = AILibraryTools.string(args["source"]) {
            source = aiResolveCatalogSource(raw)
        } else if let current = catalogModel.selectedSource,
                  current.domain == .networkResource {
            source = current
        } else {
            source = catalogModel.enabledResourceSources.first
        }
        guard let source else {
            return failure("还没有可用的网络资源源")
        }
        guard source.domain == .networkResource else {
            return failure("源「\(source.name)」是影视源，不能用于网络资源的人物关注")
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

    func aiResolveCatalogSource(_ raw: String) -> CatalogSource? {
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
    func aiResolveCatalogCandidate(_ args: [String: Any]) -> (sourceID: UUID, item: CatalogItem)? {
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
}
