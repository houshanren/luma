import Foundation

/// 智能助手的上下文组装：候选照片、当前范围快照与影院快照。
/// 只做「取数据 + 组装 DTO」，不发送请求、不做工具执行。
extension LibraryStore {
    /// 单次请求最多带多少张候选照片（固定上限，避免把整个图库塞进提示词）。
    nonisolated static let aiCandidateLimit = 40

    // MARK: - 上下文

    /// 选中项优先，其次当前范围的前若干张；数量固定，避免把整个图库塞进提示词。
    func aiCandidatePhotos(limit: Int) -> [PhotoItem] {
        var result: [PhotoItem] = []
        var seen: Set<UUID> = []
        for id in selection {
            guard let photo = anyPhoto(id: id) else { continue }
            guard seen.insert(photo.id).inserted else { continue }
            result.append(photo)
            if result.count >= limit { return result }
        }
        let source = isCloudScope ? cloudVisiblePhotos : visiblePhotos
        for photo in source {
            guard seen.insert(photo.id).inserted else { continue }
            result.append(photo)
            if result.count >= limit { break }
        }
        return result
    }

    func makeAILibraryContext(photos: [PhotoItem],
                              limit: Int = LibraryStore.aiCandidateLimit) -> AILibraryContext {
        let scopeCount = visibleCount
        let total: Int
        if isSystemScope {
            total = systemTotalAssetCount > 0 ? systemTotalAssetCount : systemPhotos.count
        } else if isCloudScope {
            total = cloudPhotos.count
        } else {
            total = self.photos.count
        }
        let analysis = isSystemScope || isCloudScope ? [:] : analysisIndex
        // 搜索页现场只在关键词仍然一致时注入，避免离开搜索页后把上一轮结果当成现状。
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var overview: AISearchOverview? = aiSearchOverview.flatMap {
            $0.query == trimmedSearch && !trimmedSearch.isEmpty ? $0 : nil
        }
        // 窗口内搜索不经过 SearchCenter：按当前网格命中数补一份概览。
        if overview == nil, searchScope == .currentView, !trimmedSearch.isEmpty,
           sidebarItem.photoQueryScope != nil || isCloudScope {
            overview = AISearchOverview(query: trimmedSearch,
                                        total: scopeCount,
                                        sources: [AISearchOverview.SourceLine(
                                            title: isCloudScope ? "网盘" : "图库",
                                            total: scopeCount,
                                            kinds: [])],
                                        samples: [])
        }
        var context = AIContextBuilder.make(scopeTitle: sidebarTitle,
                                            scopeCount: scopeCount,
                                            libraryTotal: total,
                                            filterTitle: photoFilter.title,
                                            searchText: searchText,
                                            selectionCount: selection.count,
                                            photos: photos,
                                            analysis: analysis,
                                            limit: limit,
                                            searchOverview: overview)
        // 影院页的照片图库可能是 0 项，但影院里有目录与视频：单独附一份影院快照。
        if isAICinemaScope {
            context.cinema = makeAICinemaSnapshot()
        }
        return context
    }

    private var isAICinemaScope: Bool {
        switch sidebarItem {
        case .cinema, .cloudCinema: return true
        default: return false
        }
    }

    /// 给助手一份克制的影院快照：目录、计数与少量样本，不把整库塞进提示词。
    private func makeAICinemaSnapshot() -> AILibraryContext.CinemaSnapshot {
        let scope = cinemaActiveScope
        let entries = Array(cinemaEntries(for: scope).values)
        // 计数以「完整视频清单」为准：从未刮削过的网盘 entries 为空，但仍需要让助手看到视频数。
        let candidates = cinemaCandidates(for: scope)
        let matchedIDs = Set(entries.filter(\.matched).map(\.id))
        let matched = candidates.filter { matchedIDs.contains($0.photo.id) }.count
        let total = max(candidates.count, entries.count)

        var allFolders: [CinemaFolder] = []
        var stack = cinemaFolders(for: scope)
        while let folder = stack.popLast() {
            allFolders.append(folder)
            stack.append(contentsOf: folder.children)
        }
        let folders = allFolders
            .sorted { $0.subtreePhotos.count > $1.subtreePhotos.count }
            .prefix(12)
            .map { folder in
                AILibraryContext.CinemaFolderLine(name: folder.name,
                                                  path: folder.path,
                                                  videos: folder.subtreePhotos.count,
                                                  matched: folder.matchedCount)
            }

        let videos: [AILibraryContext.CinemaVideoLine]
        if entries.isEmpty {
            // 还没刮削过：用文件名解析结果给模型一点样本，具体清单让它调用 cinema_tree。
            videos = candidates
                .sorted { $0.photo.displayFilename.localizedStandardCompare($1.photo.displayFilename)
                    == .orderedAscending }
                .prefix(16)
                .map { candidate in
                    let parsed = CinemaScraper.parse(filename: candidate.photo.displayFilename,
                                                     folderHint: candidate.folderHint)
                    return AILibraryContext.CinemaVideoLine(
                        filename: candidate.photo.displayFilename,
                        title: parsed.title,
                        matched: false,
                        season: parsed.season,
                        episode: parsed.episode,
                        resolution: candidate.photo.pixelWidth > 0
                            ? "\(candidate.photo.pixelWidth)×\(candidate.photo.pixelHeight)" : ""
                    )
                }
        } else {
            videos = entries
                .sorted { lhs, rhs in
                    if lhs.matched != rhs.matched { return !lhs.matched }
                    return lhs.file.capturedAt > rhs.file.capturedAt
                }
                .prefix(16)
                .map { entry in
                    AILibraryContext.CinemaVideoLine(
                        filename: entry.file.filename,
                        title: entry.title,
                        matched: entry.matched,
                        season: entry.season,
                        episode: entry.episode,
                        resolution: entry.file.pixelWidth > 0
                            ? "\(entry.file.pixelWidth)×\(entry.file.pixelHeight)" : ""
                    )
                }
        }

        return AILibraryContext.CinemaSnapshot(scopeName: cinemaScopeName(scope),
                                               total: total,
                                               matched: matched,
                                               folders: Array(folders),
                                               videos: Array(videos))
    }
}
