import Foundation

extension LibraryStore {
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

    func listCinemaScopesTool() -> AIToolExecution {
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

    func cinemaTreeTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let folderQuery = AILibraryTools.string(args["folder"])
        let onlyUnmatched = AILibraryTools.bool(args["only_unmatched"], fallback: false)
        let limit = min(5000, max(1, AILibraryTools.integer(args["limit"], fallback: 500)))
        // depth > 1 时连子目录一起展开：整部剧的各个季可以一次读全。
        let depth = min(8, max(1, AILibraryTools.integer(args["depth"], fallback: 1)))
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
            .prefix(300)
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

        var scopedPhotos: [(photo: PhotoItem, folderPath: String)] = []
        if let current {
            aiCollectCinemaPhotos(in: current, depth: depth, into: &scopedPhotos)
        } else {
            // 顶层调用时把没有目录归属的散片也列出来，避免根目录视频被漏掉。
            scopedPhotos = candidates.filter { $0.folderPath == nil }.map { ($0.photo, "") }
            if depth > 1 {
                // 不指定 folder 时也能一次读全：从每个顶层目录往下展开。
                for folder in children {
                    aiCollectCinemaPhotos(in: folder, depth: depth - 1, into: &scopedPhotos)
                }
            }
        }
        let sortedPhotos = scopedPhotos.sorted { lhs, rhs in
            if lhs.folderPath != rhs.folderPath {
                return lhs.folderPath.localizedStandardCompare(rhs.folderPath) == .orderedAscending
            }
            return lhs.photo.displayFilename.localizedStandardCompare(rhs.photo.displayFilename)
                == .orderedAscending
        }

        var videoItems: [[String: Any]] = []
        var truncated = false
        for item in sortedPhotos {
            let photo = item.photo
            let entry = entries[photo.id]
            if onlyUnmatched, entry?.matched == true { continue }
            guard videoItems.count < limit else {
                truncated = true
                break
            }
            var info = aiCinemaVideoInfo(photo: photo,
                                         entry: entry,
                                         candidate: candidateByID[photo.id])
            if depth > 1, !item.folderPath.isEmpty { info["folder_path"] = item.folderPath }
            videoItems.append(info)
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
        if truncated {
            payload["truncated"] = true
            payload["returned"] = videoItems.count
        }
        return success(payload,
                       summary: current.map {
                           "查看「\($0.name)」：返回 \(videoItems.count) 个视频"
                               + (depth > 1 ? "（含 \(depth) 层子目录）" : "")
                       } ?? "查看影院目录：\(children.count) 个文件夹",
                       photoIDs: [])
    }

    /// 把目录（含 depth 层子目录）里的直属视频拍平，供一次批量读取。
    private func aiCollectCinemaPhotos(in folder: CinemaFolder,
                                       depth: Int,
                                       into result: inout [(photo: PhotoItem, folderPath: String)]) {
        let path = folder.hint ?? folder.path
        for photo in folder.photos { result.append((photo, path)) }
        guard depth > 1 else { return }
        for child in folder.children {
            aiCollectCinemaPhotos(in: child, depth: depth - 1, into: &result)
        }
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

    func searchCinemaCandidatesTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let query = AILibraryTools.string(args["query"]) else {
            return failure("缺少 query")
        }
        let isTV = AILibraryTools.bool(args["is_tv"], fallback: false)
        let rawYear = AILibraryTools.integer(args["year"], fallback: 0)
        let year: Int? = rawYear > 0 ? rawYear : nil
        let limit = min(20, max(1, AILibraryTools.integer(args["limit"], fallback: 8)))

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

    func applyCinemaMatchTool(_ args: [String: Any]) -> AIToolExecution {
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

    func listCinemaItemsTool(_ args: [String: Any]) -> AIToolExecution {
        let scope = aiCinemaScope
        let allEntries = Array(cinemaEntries(for: scope).values)
        let folderQuery = AILibraryTools.string(args["folder"])
        let onlyUnmatched = AILibraryTools.bool(args["only_unmatched"], fallback: false)
        let limit = min(5000, max(1, AILibraryTools.integer(args["limit"], fallback: 300)))

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
            if folderItems.count >= 300 { break }
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

    func scrapeCinemaTool(_ args: [String: Any]) -> AIToolExecution {
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

    func matchCinemaTool(_ args: [String: Any]) async -> AIToolExecution {
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
        let limit = min(1000, max(1, AILibraryTools.integer(args["limit"], fallback: 100)))

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
}
