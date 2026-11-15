import Foundation
import SwiftUI

/// 大图库的分页窗口：筛选、排序、总量都由 SQLite 完成，Store 只保留已加载的若干页。
extension LibraryStore {
    /// 时间轴范围（所有照片/媒体类型等）可下推的条件；与分组模式无关。
    var timelineQuery: PhotoQuery? {
        guard !needsLibrarySetup, metadataStore != nil,
              !isSystemScope, !isCloudScope,
              selectedPlace == nil, selectedPerson == nil,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              photos.count >= Self.windowThreshold,
              let scope = sidebarItem.photoQueryScope else { return nil }
        return PhotoQuery(scope: scope,
                          filter: photoFilter,
                          keyword: keywordFilter,
                          sortKey: sortKey,
                          ascending: sortAscending)
    }

    /// 「所有照片」网格分页：只有时间轴范围才受年/月总览影响，其它范围始终是普通网格。
    var pagedQuery: PhotoQuery? {
        if isTimelineScope {
            return grouping == .all ? timelineQuery : nil
        }
        return timelineQuery
    }

    /// 当前是否处于 SQL 分页模式。
    var isPagedScope: Bool { pagedQuery != nil }

    /// 视图用 `.task(id:)` 监听：范围、筛选、排序或内容版本变化时刷新窗口。
    var pagedKey: String {
        guard let query = pagedQuery else { return "" }
        return "\(query.key)#\(contentRevision)"
    }

    var visibleCount: Int {
        isPagedScope ? windowTotal : visiblePhotos.count
    }

    var visibleVideoCount: Int {
        isPagedScope ? windowVideos : visiblePhotos.lazy.filter { $0.isVideo }.count
    }

    var canLoadMoreVisible: Bool {
        isPagedScope && windowPhotos.count < windowTotal
    }

    /// 首次进入或查询条件变化时加载第一页；内容版本变化时保留已加载页数，避免滚动位置跳回顶部。
    func reloadVisibleWindowIfNeeded() {
        guard let query = pagedQuery else { return }
        let key = "\(query.key)#\(contentRevision)"
        if let target = scrollTargetID,
           key != windowKeyValue || !windowPhotos.contains(where: { $0.id == target }) {
            focusWindow(on: target, query: query, key: key)
            return
        }
        guard key != windowKeyValue else { return }
        let sameQuery = query.key == windowQueryKey
        if !sameQuery {
            // 范围或排序变了：先清空旧窗口，避免短暂显示上一次的结果。
            windowPhotos = []
            windowTotal = 0
            windowVideos = 0
            hasLoadedWindow = false
        }
        let limit = sameQuery ? max(Self.windowPageSize, windowPhotos.count) : Self.windowPageSize
        loadWindow(query: query, key: key, start: 0, limit: limit, replace: true)
    }

    /// 网格滚动到末尾时加载下一页。
    func loadMoreVisibleWindow() {
        guard let query = pagedQuery, !isWindowLoading, canLoadMoreVisible else { return }
        let key = windowKeyValue.isEmpty ? "\(query.key)#\(contentRevision)" : windowKeyValue
        loadWindow(query: query, key: key,
                   start: windowStartOffset + windowPhotos.count,
                   limit: Self.windowPageSize,
                   replace: false)
    }

    /// 让窗口包含指定照片（月总览定位、方向键跳转），并把网格滚动过去。
    func focusWindow(on photoID: UUID) {
        guard let query = pagedQuery else {
            scrollTargetID = photoID
            return
        }
        focusWindow(on: photoID, query: query, key: "\(query.key)#\(contentRevision)")
    }

    /// 查看器胶片条：当前照片前后各 8 张，避免依赖整段窗口。
    func refreshViewerStripIfNeeded() {
        guard isPagedScope, let id = viewerID,
              let store = metadataStore, let query = windowQuery else {
            viewerStrip = []
            viewerStripKey = nil
            return
        }
        let key = "\(query.key)#\(contentRevision)#\(id.uuidString)"
        guard key != viewerStripKey else { return }
        viewerStripKey = key
        viewerStripTask?.cancel()
        viewerStripTask = Task { [weak self] in
            let photos = await Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
                guard let index = store.index(of: id, in: query) else { return [] }
                let total = store.summary(query).total
                let start = max(0, index - 8)
                let end = min(total, index + 9)
                guard end > start else { return [] }
                return store.photos(in: query, range: start..<end)
            }.value
            guard let self, !Task.isCancelled, self.viewerStripKey == key else { return }
            self.viewerStrip = photos
        }
    }

    /// 年 / 月总览是否也可以走 SQL 分区。
    var usesSQLOverview: Bool {
        timelineQuery != nil && (grouping == .years || grouping == .months)
    }

    /// 视图用 `.task(id:)` 监听总览数据刷新。
    var overviewKey: String {
        guard usesSQLOverview, let query = timelineQuery else { return "" }
        return "\(query.key)#\(contentRevision)#\(grouping.rawValue)"
    }

    func reloadOverviewIfNeeded() {
        guard usesSQLOverview, let query = timelineQuery, let store = metadataStore else { return }
        let key = "\(query.key)#\(contentRevision)#\(grouping.rawValue)"
        guard key != overviewKeyValue else { return }
        overviewTask?.cancel()
        overviewKeyValue = key
        isOverviewLoading = true
        let grouping = self.grouping
        overviewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (buckets: [PhotoPeriodBucket], months: [PhotoMonthGroup]) in
                switch grouping {
                case .years:
                    return (store.yearBuckets(query), [])
                case .months:
                    return ([], store.monthGroups(query))
                case .all:
                    return ([], [])
                }
            }.value
            guard let self, !Task.isCancelled, self.overviewKeyValue == key else { return }
            self.isOverviewLoading = false
            if grouping == .years {
                self.yearBuckets = result.buckets
            } else {
                self.monthGroups = result.months
            }
            self.resolvePendingMonthScroll()
        }
    }

    /// 从年总览点进某年时，等月份数据到手再定位到该年第一个月。
    private func resolvePendingMonthScroll() {
        guard let year = pendingMonthScrollYear else { return }
        guard let group = monthGroups.first(where: { $0.id.hasPrefix("\(year)-") }) else { return }
        pendingMonthScrollYear = nil
        scrollTargetSection = group.id
    }

    // MARK: - 内部

    private func loadWindow(query: PhotoQuery, key: String, start: Int, limit: Int, replace: Bool) {
        guard let store = metadataStore else { return }
        windowTask?.cancel()
        windowKeyValue = key
        windowQueryKey = query.key
        windowQuery = query
        isWindowLoading = true
        windowTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PhotoQuerySummary, [PhotoItem]) in
                let summary = store.summary(query)
                let page = store.page(query, offset: start, limit: limit)
                return (summary, page)
            }.value
            guard let self, !Task.isCancelled, self.windowKeyValue == key else { return }
            self.isWindowLoading = false
            self.windowTotal = result.0.total
            self.windowVideos = result.0.videos
            self.windowStartOffset = start
            self.windowPhotos = replace ? result.1 : self.windowPhotos + result.1
            self.windowRevision &+= 1
            self.hasLoadedWindow = true
        }
    }

    private func focusWindow(on photoID: UUID, query: PhotoQuery, key: String) {
        guard let store = metadataStore else { return }
        windowTask?.cancel()
        windowKeyValue = key
        windowQueryKey = query.key
        windowQuery = query
        isWindowLoading = true
        let pageSize = Self.windowPageSize
        windowTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PhotoQuerySummary, Int, [PhotoItem]) in
                let summary = store.summary(query)
                let index = store.index(of: photoID, in: query) ?? 0
                let start = max(0, min(index - pageSize / 2, max(0, summary.total - pageSize)))
                let page = store.page(query, offset: start, limit: pageSize)
                return (summary, start, page)
            }.value
            guard let self, !Task.isCancelled, self.windowKeyValue == key else { return }
            self.isWindowLoading = false
            self.windowTotal = result.0.total
            self.windowVideos = result.0.videos
            self.windowStartOffset = result.1
            self.windowPhotos = result.2
            self.windowRevision &+= 1
            self.hasLoadedWindow = true
            self.scrollTargetID = photoID
        }
    }
}
