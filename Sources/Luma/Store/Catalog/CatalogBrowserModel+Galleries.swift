import Foundation
import LumaContentCore

/// 图集分页与「视频 / 图集」类型筛选。
///
/// 网络资源里混着两类站点：视频站与图集站（`CatalogProviderKind.isGallerySite`）。
/// 条目本身没有媒体类型字段，一律按来源判定；榜单 / 日历 / 足迹 / 片单与统一搜索共用这一套判定。
extension CatalogBrowserModel {
    // MARK: - 类型判定

    /// 这个源是不是图集站（纯图集；综合站不算，按条目判断）。
    func isGallery(sourceID: UUID) -> Bool {
        sources.first(where: { $0.id == sourceID })?.kind.isGallerySite ?? false
    }

    /// 条目级判定：综合站按条目自己的媒体类型，纯站点仍按站点类型。
    func isGallery(sourceID: UUID, item: CatalogItem) -> Bool {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return false }
        return item.isGallery(in: source)
    }

    /// 已启用的图集站（按侧边栏顺序）：综合站也提供图集内容，一并纳入。
    var gallerySources: [CatalogSource] {
        enabledSources(in: .networkResource).filter { $0.kind.siteCategory != .video }
    }

    /// 已启用的视频站：综合站也提供视频内容，一并纳入。
    var videoSources: [CatalogSource] {
        enabledSources(in: .networkResource).filter { $0.kind.siteCategory != .gallery }
    }

    var gallerySourceIDs: Set<UUID> { Set(gallerySources.map(\.id)) }

    /// 工具栏实际展示的分页：没有接入任何图集站时，不出现「图集」入口。
    var visibleHubTabs: [CatalogHubTab] {
        guard gallerySources.isEmpty else { return CatalogHubTab.allCases }
        return CatalogHubTab.allCases.filter { $0 != .galleries }
    }

    /// 图集入口消失（删光图集站）时，把停在图集页的界面拉回资源总览，
    /// 同时清掉会筛出空列表的「只看图集」。
    func ensureHubTabAvailable() {
        guard gallerySources.isEmpty else { return }
        if hubTab == .galleries { setHubTab(.browse) }
        if mediaFilter != .all { mediaFilter = .all }
    }

    /// 当前媒体筛选是否放行这条内容。
    /// 综合站两种内容都有，两个筛选都放行，具体条目由条目级类型再区分。
    func matchesMediaFilter(sourceID: UUID) -> Bool {
        switch mediaFilter {
        case .all: return true
        case .video: return sources.first(where: { $0.id == sourceID })?.kind.siteCategory != .gallery
        case .gallery: return sources.first(where: { $0.id == sourceID })?.kind.siteCategory != .video
        }
    }

    // MARK: - 图集 feed

    /// 拉取各图集站首页，组成「混排 feed + 每个源自己的轨道」。
    /// 与榜单同样的策略：并发问源、单个失败跳过，打开图集页就能看到内容。
    func loadGalleryFeed(force: Bool = false) {
        guard !isGalleryFeedLoading else { return }
        if galleryFeedLoaded, !force { return }
        let targets = gallerySources
        guard !targets.isEmpty else {
            galleryFeed = []
            galleryBySource = [:]
            galleryFeedLoaded = true
            return
        }
        isGalleryFeedLoading = true
        Task { [weak self] in
            await CatalogRequestScope.$isBackground.withValue(true) {
                guard let self else { return }
                var rails: [UUID: [CatalogSpotlightItem]] = [:]
                var groups: [[CatalogSpotlightItem]] = []
                var nextPages: [UUID: Int] = [:]
                var exhausted: Set<UUID> = []
                for source in targets {
                    guard !Task.isCancelled else { break }
                    guard let provider = CatalogProviders.provider(for: source.kind) else { continue }
                    // 综合站的首页混着视频：图集 feed 只收图集条目。
                    guard let page = try? await provider.home(source: source, page: 1) else {
                        exhausted.insert(source.id)
                        continue
                    }
                    let galleryItems = page.items.filter { $0.isGallery(in: source) }
                    guard !galleryItems.isEmpty else {
                        // 首页拿不到图集就当作这一轮没内容，避免「继续翻」时反复重试同一个站。
                        exhausted.insert(source.id)
                        continue
                    }
                    let items = galleryItems.prefix(12).map {
                        CatalogSpotlightItem(sourceID: source.id, sourceName: source.name, item: $0)
                    }
                    rails[source.id] = Array(items)
                    groups.append(Array(items.prefix(6)))
                    if page.hasMore {
                        nextPages[source.id] = 2
                    } else {
                        exhausted.insert(source.id)
                    }
                }
                self.galleryBySource = rails
                self.galleryFeed = Self.interleave(groups, limit: 40)
                self.galleryNextPage = nextPages
                self.galleryExhaustedSources = exhausted
                self.galleryFeedExhausted = exhausted.count >= targets.count
                self.isGalleryFeedLoading = false
                self.galleryFeedLoaded = true
                self.persistGalleryFeed()
            }
        }
    }

    /// 瀑布墙滚到底 / 影院轨道滑到右端时继续翻页：每个站各取下一页，追加到 feed 与站点轨道。
    /// 全部站点都没有下一页时才停止，避免滚到底反复发请求。
    func loadMoreGalleryFeed() {
        guard !isGalleryFeedLoading, !isGalleryFeedLoadingMore, !galleryFeedExhausted else { return }
        let targets = gallerySources.filter { !galleryExhaustedSources.contains($0.id) }
        guard !targets.isEmpty else {
            galleryFeedExhausted = true
            return
        }
        isGalleryFeedLoadingMore = true
        Task { [weak self] in
            await CatalogRequestScope.$isBackground.withValue(true) {
                guard let self else { return }
                var rails: [UUID: [CatalogSpotlightItem]] = [:]
                var groups: [[CatalogSpotlightItem]] = []
                var exhausted: Set<UUID> = []
                for source in targets {
                    guard !Task.isCancelled else { break }
                    guard let provider = CatalogProviders.provider(for: source.kind) else { continue }
                    let page = self.galleryNextPage[source.id] ?? 2
                    guard let result = try? await provider.home(source: source, page: page) else {
                        exhausted.insert(source.id)
                        continue
                    }
                    let galleryItems = result.items.filter { $0.isGallery(in: source) }
                    guard !galleryItems.isEmpty else {
                        exhausted.insert(source.id)
                        continue
                    }
                    let items = galleryItems.map {
                        CatalogSpotlightItem(sourceID: source.id, sourceName: source.name, item: $0)
                    }
                    rails[source.id] = items
                    groups.append(Array(items.prefix(12)))
                    if result.hasMore {
                        self.galleryNextPage[source.id] = page + 1
                    } else {
                        exhausted.insert(source.id)
                    }
                }
                self.galleryExhaustedSources.formUnion(exhausted)
                self.appendGalleryItems(rails: rails, groups: groups)
                self.galleryFeedExhausted = self.gallerySources.allSatisfy {
                    self.galleryExhaustedSources.contains($0.id)
                }
                self.isGalleryFeedLoadingMore = false
                self.persistGalleryFeed()
            }
        }
    }

    /// 把新一页按「每站轮流」的顺序接在 feed 末尾，同时补进各自的站点轨道。
    /// 用 `CatalogSpotlightItem.id`（源 + 条目）去重，跨页重复的内容不会出现两次。
    private func appendGalleryItems(rails: [UUID: [CatalogSpotlightItem]],
                                    groups: [[CatalogSpotlightItem]]) {
        guard !rails.isEmpty else { return }
        for (sourceID, items) in rails {
            var existing = galleryBySource[sourceID] ?? []
            var known = Set(existing.map(\.id))
            for item in items where known.insert(item.id).inserted {
                existing.append(item)
            }
            galleryBySource[sourceID] = existing
        }
        var known = Set(galleryFeed.map(\.id))
        for item in Self.interleave(groups, limit: 200) where known.insert(item.id).inserted {
            galleryFeed.append(item)
        }
    }

    private func persistGalleryFeed() {
        if let data = try? JSONEncoder().encode(galleryFeed) {
            CatalogStore.set(data, forKey: Self.galleryFeedKey)
        }
        if let data = try? JSONEncoder().encode(galleryBySource) {
            CatalogStore.set(data, forKey: Self.galleryRailsKey)
        }
    }

    // MARK: - 悬停预览

    /// 悬停某套图时解析前几张原图，供卡片自动翻页预览。
    /// 解析过一次就写进 `galleryPreviewCache`，反复悬停不会反复打站点。
    func galleryPreviewImages(sourceID: UUID, itemID: String, limit: Int = 6) async -> [String] {
        guard let source = sources.first(where: { $0.id == sourceID }),
              source.kind.isGallerySite,
              let provider = CatalogProviders.provider(for: source.kind) else { return [] }
        let key = detailKey(source: source, itemID: itemID)
        if let cached = galleryPreviewCache[key] { return cached }
        let detail: CatalogDetail?
        if let existing = cachedDetails[key] {
            detail = existing
        } else {
            detail = try? await provider.detail(source: source, itemID: itemID)
            if let detail { cachedDetails[key] = detail }
        }
        guard let detail else { return [] }
        let urls = Array(detail.articleImages.prefix(limit))
        if !urls.isEmpty { galleryPreviewCache[key] = urls }
        return urls
    }

    /// 这套图集在详情里解析到的张数（还没解析过时返回 nil，卡片据此不显示数字）。
    func galleryImageCount(sourceID: UUID, itemID: String) -> Int? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        let key = detailKey(source: source, itemID: itemID)
        guard let detail = cachedDetails[key] else { return nil }
        return detail.articleImages.count
    }
}
