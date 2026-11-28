import Foundation

/// 视频页的数据编排：只从 Store 派生，视图不持有任何照片数组。
/// 首次进入先用分页窗口画一屏，同时在后台把整库视频元数据聚合一次；
/// 之后统计、筛选与分组都在完整列表上完成，不再出现「只统计已载入」的说法。
@MainActor
extension LibraryStore {
    /// 顶栏统计胶囊：段数 + 总时长；汇总过程中明确提示，而不是暴露分页细节。
    var videoHubStatsText: String {
        let data = videoHubData
        if videoHubFilter.isActive {
            return "\(data.videos.count.formatted()) 段 · \(videoHubDurationText(data.totalDuration))"
        }
        if isVideoHubLoading, videoHubFullVideos.isEmpty {
            let total = max(visibleCount, data.videos.count)
            return "\(total.formatted()) 段 · 正在汇总…"
        }
        let total = max(visibleCount, data.videos.count)
        return "\(total.formatted()) 段 · \(videoHubDurationText(data.totalDuration))"
    }

    /// 缓存指纹变化时才重算：完整列表、筛选条件、人物数据任一变化都会触发。
    func refreshVideoHubIfNeeded(force: Bool = false) {
        let fullToken = videoHubFullTokenKey
        let token = videoHubCacheTokenKey
        guard force || token != videoHubCacheToken else { return }
        videoHubCacheToken = token

        if videoHubFullToken == fullToken {
            // 完整列表没变（只是筛选项 / 人物数据变化）：后台重新派生一版。
            scheduleVideoHubRebuild(from: videoHubFullVideos)
        } else {
            // 先用当前分页窗口画一屏，避免整页空白；完整聚合在后台继续。
            videoHubData = Self.makeVideoHubData(from: quickVideoSnapshot(),
                                                 filter: videoHubFilter,
                                                 people: videoHubPeopleEntries())
            hasVideoHubSnapshot = true
            startFullVideoHubLoad(token: fullToken)
        }
    }

    private var videoHubCacheTokenKey: String {
        [
            videoHubFullTokenKey,
            videoHubFilter.summary,
            String(videoHubFullVideos.count),
            String(localPeople.count),
            String(systemPeople.count)
        ].joined(separator: "\u{1F}")
    }

    private var videoHubFullTokenKey: String {
        [systemIndexSignature,
         String(contentRevision),
         String(isSystemScope),
         sidebarItem.videoHubScopeKey].joined(separator: "\u{1F}")
    }

    private func quickVideoSnapshot() -> [PhotoItem] {
        visiblePhotos
            .filter { $0.isVideo && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 人物分组的数据源：先在主线程拍好快照，分组本身在后台算。
    private func videoHubPeopleEntries() -> [VideoHubPersonEntry] {
        if isSystemScope {
            return systemPeople.map {
                VideoHubPersonEntry(name: $0.isUnnamed ? "未命名人物" : $0.name,
                                    assetIDs: $0.assetIDs)
            }
        }
        return visibleLocalPeople.map {
            VideoHubPersonEntry(name: $0.isUnnamed ? "未命名人物" : $0.name,
                                assetIDs: $0.assetIDs)
        }
    }

    /// 完整列表没变、只有筛选 / 人物变化：后台派生，只让最后一次结果落地。
    private func scheduleVideoHubRebuild(from all: [PhotoItem]) {
        let filter = videoHubFilter
        let people = videoHubPeopleEntries()
        videoHubRebuildToken &+= 1
        let token = videoHubRebuildToken
        tasks.cancel(.videoHubRebuild)
        tasks.adopt(.videoHubRebuild, Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                Self.makeVideoHubData(from: all, filter: filter, people: people)
            }.value
            guard let self, !Task.isCancelled, self.videoHubRebuildToken == token else { return }
            self.videoHubData = data
            self.hasVideoHubSnapshot = true
        })
    }

    /// 后台读取整库视频：本地库直接取内存，系统图库按索引分页直到取完。
    /// 过滤、排序、叠加元数据与分组全部在后台完成，主线程只负责落地结果。
    private func startFullVideoHubLoad(token: String) {
        guard videoHubLoadingToken != token else { return }
        videoHubLoadingToken = token
        tasks.cancel(.videoHubLoad)
        isVideoHubLoading = true

        let filter = videoHubFilter
        let people = videoHubPeopleEntries()

        if !isNativeContainer {
            let source = photos
            tasks.adopt(.videoHubLoad, Task { [weak self] in
                let built = await Task.detached(priority: .userInitiated) {
                    () -> (videos: [PhotoItem], data: VideoHubData) in
                    let videos = source
                        .filter { $0.isVideo && $0.deletedAt == nil && !$0.isHidden }
                        .sorted { $0.capturedAt > $1.capturedAt }
                    return (videos,
                            Self.makeVideoHubData(from: videos, filter: filter, people: people))
                }.value
                guard let self, !Task.isCancelled else { return }
                self.videoHubFullVideos = built.videos
                self.videoHubFullToken = token
                self.videoHubLoadingToken = ""
                self.isVideoHubLoading = false
                self.videoHubData = built.data
                self.hasVideoHubSnapshot = true
            })
            return
        }

        guard let index = systemIndex else {
            // 索引还没就绪：窗口数据先用着，等索引签名变化后再重试。
            isVideoHubLoading = false
            videoHubLoadingToken = ""
            return
        }

        var query = buildSystemQuery(scope: .videos)
        // 视频页有自己的筛选，不继承其它页面的照片筛选 / 搜索。
        query.filter = .all
        query.sortKey = .capturedAt
        query.ascending = false
        query.manualOrder = false
        query.startDate = nil
        query.endDate = nil
        query.onlyFavorites = false
        query.onlyVideos = false
        query.onlyPhotos = false
        query.onlyScreenshots = false
        query.onlyLivePhotos = false
        query.onlyEdited = false
        query.onlyLocated = false
        query.tokens = []
        query.tokenPlaceIDs = nil
        query.overlayKeywordIDs = nil
        query.includeIDs = nil
        query.savedCutoff = nil
        query.viewedCutoff = nil

        // 叠加元数据需要的快照：后台线程不再回主线程逐条读 Store。
        let overlays = systemOverlays
        let nativeKeywords = systemNativeKeywordIDMap
        let isNative = isNativeContainer
        let pageSize = 600

        tasks.adopt(.videoHubLoad, Task { [weak self] in
            // 先把首屏窗口让出来：整库扫描和窗口查询共用同一个串行 SQLite 连接，
            // 扫描先跑会让「点进视频」白等（最多让 800ms，窗口异常时照常开扫）。
            var waited = 0
            while self?.isPagedWindowFresh == false, waited < 800, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                waited += 40
            }
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .utility) {
                () -> (videos: [PhotoItem], data: VideoHubData) in
                var items: [PhotoItem] = []
                var offset = 0
                while true {
                    let page = index.page(query, offset: offset, limit: pageSize)
                    if page.isEmpty { break }
                    items.append(contentsOf: page)
                    offset += page.count
                    if page.count < pageSize { break }
                    if items.count >= 100_000 { break }
                    await Task.yield()
                }
                let all = items
                    .map {
                        LibraryStore.applyingOverlays($0,
                                                      overlays: overlays,
                                                      nativeKeywords: nativeKeywords,
                                                      isNative: isNative)
                    }
                    .filter { $0.isVideo && $0.deletedAt == nil && !$0.isHidden }
                    .sorted { $0.capturedAt > $1.capturedAt }
                return (all,
                        Self.makeVideoHubData(from: all, filter: filter, people: people))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.videoHubFullVideos = built.videos
            self.videoHubFullToken = token
            self.videoHubLoadingToken = ""
            self.isVideoHubLoading = false
            self.videoHubData = built.data
            self.hasVideoHubSnapshot = true
        })
    }

    /// 纯计算：筛选、分组与统计一次完成。可在后台线程调用。
    nonisolated private static func makeVideoHubData(from all: [PhotoItem],
                                                     filter: VideoHubFilter,
                                                     people: [VideoHubPersonEntry]) -> VideoHubData {
        let calendar = Calendar.current
        var availableYears = Set<Int>()
        availableYears.reserveCapacity(min(all.count, 64))
        var filtered: [PhotoItem] = []
        filtered.reserveCapacity(all.count)
        for photo in all {
            let year = calendar.component(.year, from: photo.capturedAt)
            availableYears.insert(year)
            if let wanted = filter.year, wanted != year { continue }
            if let duration = filter.duration, !duration.contains(photo.duration) { continue }
            filtered.append(photo)
        }

        var next = VideoHubData()
        next.availableYears = availableYears.sorted(by: >)
        next.videos = filtered
        next.recent = Array(filtered.sorted { $0.addedAt > $1.addedAt }.prefix(8))
        next.long = Array(filtered.lazy.filter { ($0.duration ?? 0) >= 180 }.prefix(8))
        next.situations = Array(filtered.lazy.filter(videoHubIsSituation).prefix(8))
        next.years = makeVideoYearGroups(filtered)
        next.durations = makeVideoDurationGroups(filtered)
        next.places = makeVideoPlaceGroups(filtered)
        next.people = makeVideoPeopleGroups(filtered, people: people)
        next.days = makeVideoDayGroups(filtered)

        var total: Double = 0
        var samples = 0
        for photo in filtered {
            guard let duration = photo.duration, duration > 0 else { continue }
            total += duration
            samples += 1
        }
        next.totalDuration = total
        next.durationSamples = samples
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        next.recentCount = filtered.lazy.filter { $0.addedAt >= cutoff }.count
        next.longest = filtered.max { ($0.duration ?? 0) < ($1.duration ?? 0) }
        return next
    }

    nonisolated private static func makeVideoYearGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: videos) {
            calendar.component(.year, from: $0.capturedAt)
        }
        return grouped.keys.sorted(by: >).map { year in
            let items = (grouped[year] ?? []).sorted { $0.capturedAt > $1.capturedAt }
            return VideoGroup(id: "year-\(year)",
                              title: "\(year)",
                              detail: videoHubTotalDurationText(items),
                              videos: items)
        }
    }

    nonisolated private static func makeVideoDurationGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
        VideoDurationBand.allCases.compactMap { band in
            let items = videos.filter { band.contains($0.duration) }
            guard !items.isEmpty else { return nil }
            return VideoGroup(id: "duration-\(band.rawValue)",
                              title: band.title,
                              detail: band.detail,
                              videos: items)
        }
    }

    nonisolated private static func makeVideoPlaceGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
        let grouped = Dictionary(grouping: videos) { videoHubPlaceName($0) ?? "未标注地点" }
        return grouped.map { key, items in
            VideoGroup(id: "place-\(key)",
                       title: key,
                       detail: videoHubTotalDurationText(items),
                       videos: items.sorted { $0.capturedAt > $1.capturedAt })
        }
        .sorted { lhs, rhs in
            if lhs.title == "未标注地点" { return false }
            if rhs.title == "未标注地点" { return true }
            return lhs.videos.count > rhs.videos.count
        }
    }

    nonisolated private static func makeVideoPeopleGroups(_ videos: [PhotoItem],
                                                          people: [VideoHubPersonEntry]) -> [VideoGroup] {
        guard !videos.isEmpty, !people.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        var groups: [VideoGroup] = []
        for (index, entry) in people.enumerated() {
            let items = entry.assetIDs.compactMap { byID[$0] }
                .sorted { $0.capturedAt > $1.capturedAt }
            guard !items.isEmpty else { continue }
            groups.append(VideoGroup(id: "person-\(index)-\(entry.name)",
                                     title: entry.name,
                                     detail: videoHubTotalDurationText(items),
                                     videos: items))
        }
        return groups.sorted { $0.videos.count > $1.videos.count }
    }
}

/// 视频页人物分组的数据源：姓名 + 该人物包含的照片 ID。
struct VideoHubPersonEntry {
    let name: String
    let assetIDs: [UUID]
}

private extension SidebarItem {
    /// 视频页的缓存身份：本地视频与系统视频各自独立。
    var videoHubScopeKey: String {
        switch self {
        case .systemVideos: return "systemVideos"
        default: return "videos"
        }
    }
}
