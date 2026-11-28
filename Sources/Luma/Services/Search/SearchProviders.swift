import Foundation
import LumaContentCore

/// 五个来源的检索器：只负责「把关键词变成 SearchSection」，
/// 不关心界面、不关心当前页面，因此全局搜索或模块内搜索都能复用。
@MainActor
enum SearchProviders {
    static func makeAll(store: LibraryStore,
                        catalog: CatalogBrowserModel,
                        tv: IPTVBrowserModel) -> [any SearchProviding] {
        [
            LibrarySearchProvider(store: store),
            CloudSearchProvider(store: store),
            CinemaSearchProvider(store: store),
            NetworkCinemaSearchProvider(catalog: catalog),
            TelevisionSearchProvider(tv: tv),
            CatalogSearchProvider(catalog: catalog),
            AtlasSearchProvider()
        ]
    }
}

// MARK: - 图库

@MainActor
private final class LibrarySearchProvider: SearchProviding {
    let source: SearchSourceKind = .library
    private weak var store: LibraryStore?

    init(store: LibraryStore) { self.store = store }

    func search(query: String, limit: Int) async -> SearchSection {
        await search(query: query, limit: limit, onPartial: { _ in })
    }

    /// 图库检索按「分类」增量返回：相簿 / 文件夹 / 人物 / 场景 / 位置先算先发，
    /// 图片视频先发准确数量、再补一页命中行；百万级图库不再等全量扫描后才出结果。
    func search(query: String,
                limit: Int,
                onPartial: @escaping @MainActor (SearchSection) -> Void) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !keyword.isEmpty else { return empty }

        let targets = LibrarySearchCrossLibrary.targets(store: store)
        let currentTarget = targets.first(where: \.isCurrent)
        let storeServesLibrary = store.isSystemScope || !store.isNativeContainer

        var hits: [SearchHit] = []
        var kindCounts: [SearchHitKind: Int] = [:]
        var total = 0

        func publish() {
            guard !Task.isCancelled else { return }
            onPartial(SearchSection(source: source, hits: hits, total: total, kindCounts: kindCounts))
        }
        func tagCurrent(_ mapped: [MappedHit]) -> [SearchHit] {
            guard let currentTarget else { return mapped.map(\.hit) }
            return mapped.map { entry in
                var hit = entry.hit
                hit.origin = hit.origin ?? currentTarget.name
                hit.libraryPath = currentTarget.path
                return hit
            }
        }
        func merge(_ mapped: [MappedHit], kind: SearchHitKind, updatesCount: Bool = true) {
            let tagged = tagCurrent(mapped)
            if updatesCount { kindCounts[kind] = tagged.count }
            // 按固定优先级插到对应分组的位置：谁先返回都不会打乱最终顺序
            // （人物 → 位置 → 文件夹 → 相簿 → 视频 → 图片 → 场景）。
            let priority = Self.kindOrder(of: kind)
            if let index = hits.firstIndex(where: { Self.kindOrder(of: $0.kind) > priority }) {
                hits.insert(contentsOf: tagged, at: index)
            } else {
                hits += tagged
            }
            total = kindCounts.values.reduce(0, +)
            publish()
        }

        if storeServesLibrary {
            // 图片 / 视频最慢（百万级图库要扫索引）：先并发跑起来，
            // 人物 / 场景 / 位置 / 文件夹 / 相簿这些元数据查完一个就先上屏一个。
            let mediaTask = Task {
                await self.mediaPayload(store: store, keyword: keyword) { videos, photos in
                    // 数量分批发：视频先、图片后，各自独立刷新。
                    kindCounts[.video] = videos
                    total = kindCounts.values.reduce(0, +)
                    publish()
                    kindCounts[.photo] = photos
                    total = kindCounts.values.reduce(0, +)
                    publish()
                }
            }

            // 场景要逐条比对识别结果，放到后台算；它排在最后，不挡其它类别先上屏。
            let sceneTask = Task {
                _ = await store.loadSceneSummary()
                return self.sceneHits(store: store, keyword: keyword)
            }

            merge(personHits(store: store, keyword: keyword), kind: .person)
            merge(placeHits(store: store, keyword: keyword), kind: .place)
            merge(folderHits(store: store, keyword: keyword), kind: .folder)
            merge(await albumHits(store: store, keyword: keyword), kind: .album)

            // 命中行按类型分开返回：视频先、图片后；数量已由上面的汇总给出，不再覆盖。
            let media = await withTaskCancellationHandler {
                await mediaTask.value
            } onCancel: {
                mediaTask.cancel()
            }
            merge(media.videoHits, kind: .video, updatesCount: false)
            merge(media.photoHits, kind: .photo, updatesCount: false)

            let scene = await withTaskCancellationHandler {
                await sceneTask.value
            } onCancel: {
                sceneTask.cancel()
            }
            merge(scene, kind: .scene)
        }

        // 其它已接入的图库（以及不在图库页面时的当前图库）：并发只读直连。
        let others = targets.filter { !$0.isCurrent || !storeServesLibrary }
        if !others.isEmpty {
            var extras: [(index: Int, hits: [SearchHit])] = []
            await withTaskGroup(of: (Int, [SearchHit]).self) { group in
                for (index, target) in others.enumerated() {
                    group.addTask {
                        // 命中多少返回多少，不做条数截断。
                        let hits = LibrarySearchCrossLibrary.search(target: target,
                                                                    keyword: keyword)
                        return (index, hits)
                    }
                }
                for await (index, extra) in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    guard !extra.isEmpty else { continue }
                    extras.append((index, extra))
                }
            }
            for entry in extras.sorted(by: { $0.index < $1.index }) {
                hits += entry.hits
                for hit in entry.hits { kindCounts[hit.kind, default: 0] += 1 }
            }
            total = kindCounts.values.reduce(0, +)
            publish()
        }

        return currentSection(hits: hits, total: total, kindCounts: kindCounts)
    }

    private func currentSection(hits: [SearchHit], total: Int,
                                kindCounts: [SearchHitKind: Int]) -> SearchSection {
        SearchSection(source: source, hits: hits, total: total, kindCounts: kindCounts)
    }

    private var empty: SearchSection {
        SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
    }

    /// 等系统图库的分页窗口装填完成（最多 2.5 秒），避免把「还没查完」当成 0 命中。
    private func waitForSystemWindow(store: LibraryStore) async {
        guard store.isSystemPagedScope, !store.hasLoadedSystemWindow else { return }
        let deadline = Date().addingTimeInterval(2.5)
        while !store.hasLoadedSystemWindow, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// 本地图库（无索引）的图片视频命中：来自当前可见集合。
    private func mediaItems(store: LibraryStore, keyword: String) -> [PhotoItem] {
        // 全局 / 模块内搜索时 store 已经按关键词算好全库结果；窗口内搜索只过滤当前可见集合。
        let isWholeLibrary = store.searchScope != .currentView
            && store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == keyword
        if isWholeLibrary { return store.visiblePhotos }
        return store.visiblePhotos.filter { matches($0, keyword: keyword) }
    }

    /// 把一批照片转成命中：图片在前、视频在后。
    private func mediaHits(items: [PhotoItem])
        -> (hits: [SearchHit], imageTotal: Int, videoTotal: Int) {
        let images = items.filter { !$0.isVideo }
        let videos = items.filter { $0.isVideo }
        func hit(_ photo: PhotoItem, kind: SearchHitKind) -> SearchHit {
            SearchHit(id: "library|\(kind.rawValue)|\(photo.id.uuidString)",
                      source: .library,
                      kind: kind,
                      title: photo.title ?? photo.originalName,
                      subtitle: subtitle(for: photo),
                      badge: kind == .video ? "视频" : nil,
                      visual: .photo(photo),
                      payload: .photo(photo.id))
        }
        let hits = images.map { hit($0, kind: .photo) } + videos.map { hit($0, kind: .video) }
        return (hits, images.count, videos.count)
    }

    private func matches(_ photo: PhotoItem, keyword: String) -> Bool {
        if SearchFuzzyText.matchesAny([photo.originalName, photo.title], keyword: keyword) {
            return true
        }
        if let keywords = photo.keywords,
           keywords.contains(where: { SearchFuzzyText.matches($0, keyword: keyword) }) {
            return true
        }
        return SearchFuzzyText.matchesAny([photo.placeCity, photo.placeProvince, photo.placePOI],
                                          keyword: keyword)
    }

    private func subtitle(for photo: PhotoItem) -> String {
        var parts: [String] = []
        if let city = photo.placeCity, !city.isEmpty { parts.append(city) }
        parts.append(DateText.dayFormatter.string(from: photo.capturedAt))
        return parts.joined(separator: " · ")
    }

    private struct MappedHit {
        var hit: SearchHit
    }

    /// 图片 / 视频的独立查询结果：两类各自成批返回。
    private struct MediaPayload {
        var videoHits: [MappedHit] = []
        var photoHits: [MappedHit] = []
    }

    /// 结果列表的固定顺序：人物 → 位置 → 文件夹 → 相簿 → 视频 → 图片 → 场景。
    private static let kindOrderList: [SearchHitKind] = [.person, .place, .folder,
                                                         .album, .video, .photo, .scene]

    private static func kindOrder(of kind: SearchHitKind) -> Int {
        kindOrderList.firstIndex(of: kind) ?? kindOrderList.count
    }

    /// 图片 / 视频独立查询：汇总只扫一次，同时给出两类数量；
    /// 命中行按类型各查一页，视频先返回、图片后返回，两类互不阻塞。
    private func mediaPayload(store: LibraryStore, keyword: String,
                              onCounts: @MainActor (Int, Int) -> Void) async -> MediaPayload {
        await waitForSystemWindow(store: store)
        guard !Task.isCancelled else { return MediaPayload() }

        guard let index = store.systemIndex else {
            let items = mediaItems(store: store, keyword: keyword)
            let split = mediaHits(items: Array(items.prefix(600)))
            await onCounts(split.videoTotal, split.imageTotal)
            return MediaPayload(videoHits: split.hits.filter { $0.kind == .video }.map(MappedHit.init),
                                photoHits: split.hits.filter { $0.kind == .photo }.map(MappedHit.init))
        }

        var query = store.buildSystemQuery(scope: .all, searchTextOverride: keyword)
        query.sortKey = .capturedAt
        query.ascending = false
        var videoQuery = query
        videoQuery.onlyVideos = true
        var photoQuery = query
        photoQuery.onlyPhotos = true

        let limit = 300
        // 视频 / 图片各查一页：两个类型互不等待，谁先查完先上屏。
        let videosTask = Task.detached(priority: .userInitiated) {
            index.page(videoQuery, offset: 0, limit: limit)
        }
        let photosTask = Task.detached(priority: .userInitiated) {
            index.page(photoQuery, offset: 0, limit: limit)
        }
        let summary = await Task.detached(priority: .userInitiated) {
            index.summary(query)
        }.value
        guard !Task.isCancelled else { return MediaPayload() }
        await onCounts(summary.videos, max(0, summary.total - summary.videos))

        let videoItems = (await videosTask.value).map { store.applySystemOverlay($0) }
        let photoItems = (await photosTask.value).map { store.applySystemOverlay($0) }
        return MediaPayload(videoHits: mediaHits(items: videoItems).hits.map(MappedHit.init),
                            photoHits: mediaHits(items: photoItems).hits.map(MappedHit.init))
    }

    private func albumHits(store: LibraryStore, keyword: String) async -> [MappedHit] {
        if store.isSystemScope {
            var result: [MappedHit] = []
            let matched = store.systemAlbums.filter {
                SearchFuzzyText.matches($0.name, keyword: keyword)
            }
            // 只给前 40 个相簿取封面：命中几百个时逐个查 Photos.sqlite 会把首屏拖到几秒。
            for (index, album) in matched.enumerated() {
                let cover = index < 40
                    ? await store.systemAlbumPreviewPhotosAsync(album.id, limit: 1).first
                    : nil
                result.append(MappedHit(hit: SearchHit(id: "library|system-album|\(album.id)",
                                                       source: .library,
                                                       kind: .album,
                                                       title: album.name,
                                                       subtitle: "相簿 · \(store.systemAlbumPhotoCount(album.id)) 张",
                                                       badge: nil,
                                                       visual: .albumCover(cover, .album),
                                                       payload: .systemAlbum(album.id))))
                if Task.isCancelled { break }
            }
            return result
        }
        return store.albums
            .filter { SearchFuzzyText.matches($0.name, keyword: keyword) }
            .map { album in
                let cover = (album.coverPhotoID ?? album.photoIDs.first)
                    .flatMap { store.anyPhoto(id: $0) }
                return MappedHit(hit: SearchHit(id: "library|album|\(album.id.uuidString)",
                                                source: .library,
                                                kind: .album,
                                                title: album.name,
                                                subtitle: "相簿 · \(album.photoIDs.count) 张",
                                                badge: nil,
                                                visual: .albumCover(cover, .album),
                                                payload: .localAlbum(album.id)))
            }
    }

    private func folderHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        if store.isSystemScope {
            return store.systemFolders
                .filter { SearchFuzzyText.matches($0.name, keyword: keyword) }
                .enumerated()
                .map { index, folder in
                    // 只给前 40 个文件夹取缩略图：命中很多时逐个查索引会拖慢首屏。
                    let cover = index < 40
                        ? systemFolderCover(store: store, folderID: folder.id)
                        : nil
                    return MappedHit(hit: SearchHit(id: "library|system-folder|\(folder.id)",
                                                    source: .library,
                                                    kind: .folder,
                                                    title: folder.name,
                                                    subtitle: "文件夹",
                                                    badge: nil,
                                                    visual: .albumCover(cover, .folder),
                                                    payload: .systemFolder(folder.id)))
                }
        }
        return store.folders
            .filter { SearchFuzzyText.matches($0.name, keyword: keyword) }
            .enumerated()
            .map { index, folder in
                let cover = index < 40
                    ? localFolderCover(store: store, folderID: folder.id)
                    : nil
                return MappedHit(hit: SearchHit(id: "library|folder|\(folder.id.uuidString)",
                                                source: .library,
                                                kind: .folder,
                                                title: folder.name,
                                                subtitle: "文件夹",
                                                badge: nil,
                                                visual: .albumCover(cover, .folder),
                                                payload: .localFolder(folder.id)))
            }
    }

    /// 文件夹缩略图：取子树里第一个可见项目，找不到就退回占位图。
    private func systemFolderCover(store: LibraryStore, folderID: Int64) -> PhotoItem? {
        guard let id = store.systemFolderPreviewAssetIDs(folderID, limit: 1).first else {
            return nil
        }
        if let photo = store.systemIndex?.photo(id: id) {
            return store.applySystemOverlay(photo)
        }
        return store.systemPhoto(id: id)
    }

    /// 本地文件夹：用子相簿封面或首张照片兜底，深度有限，避免大目录反复遍历。
    private func localFolderCover(store: LibraryStore, folderID: UUID) -> PhotoItem? {
        var pending: [UUID] = [folderID]
        var visited = Set<UUID>()
        var budget = 64
        while let id = pending.first, budget > 0 {
            pending.removeFirst()
            budget -= 1
            guard visited.insert(id).inserted else { continue }
            if let album = store.albums.first(where: { $0.folderID == id }) {
                if let coverID = album.coverPhotoID, let photo = store.anyPhoto(id: coverID) {
                    return photo
                }
                if let firstID = album.photoIDs.first, let photo = store.anyPhoto(id: firstID) {
                    return photo
                }
            }
            pending.append(contentsOf: store.folders.filter { $0.parentID == id }.map(\.id))
        }
        return nil
    }

    private func personHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        if store.isSystemScope {
            return store.systemPeople
                .filter { !$0.isUnnamed && SearchFuzzyText.matches($0.name, keyword: keyword) }
                .map { person in
                    let count = person.assetIDs.isEmpty ? person.faceCount : person.assetIDs.count
                    return MappedHit(hit: SearchHit(id: "library|system-person|\(person.id)",
                                                    source: .library,
                                                    kind: .person,
                                                    title: person.name,
                                                    subtitle: "人物 · \(count) 张",
                                                    badge: nil,
                                                    visual: .avatar(person.cropData, isPet: person.isPet),
                                                    payload: .systemPerson(person)))
                }
        }
        return store.localPeople
            .filter { !$0.isUnnamed && SearchFuzzyText.matches($0.name, keyword: keyword) }
            .map { person in
                MappedHit(hit: SearchHit(id: "library|person|\(person.id.uuidString)",
                                         source: .library,
                                         kind: .person,
                                         title: person.name,
                                         subtitle: "人物 · \(person.assetIDs.count) 张",
                                         badge: nil,
                                         visual: .avatar(person.coverImageData, isPet: false),
                                         payload: .localPerson(person.id)))
            }
    }

    /// 场景分类：按分类标题与识别标签匹配，搜「猫」也能找到「动物」「宠物」这类场景。
    private func sceneHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        let counts = store.sceneCounts
        guard !counts.isEmpty else { return [] }
        return SceneCatalog.categories.compactMap { category in
            let count = counts[category.id] ?? 0
            guard count > 0 else { return nil }
            let matchesTitle = SearchFuzzyText.matches(category.title, keyword: keyword)
            let matchesTag = category.tags.contains {
                SearchFuzzyText.matches($0, keyword: keyword)
            }
            guard matchesTitle || matchesTag else { return nil }
            return MappedHit(hit: SearchHit(id: "library|scene|\(category.id)",
                                            source: .library,
                                            kind: .scene,
                                            title: category.title,
                                            subtitle: "场景 · \(count) 张",
                                            badge: nil,
                                            visual: .scene,
                                            payload: .scene(category.id)))
        }
    }

    private func placeHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        // 位置不能因为「还没打开过地图」就永远 0：这里按需算一次聚类，结果本身有缓存。
        return store.placeClusters
            .filter { cluster in
                SearchFuzzyText.matchesAny([cluster.title, cluster.subtitle, cluster.group],
                                           keyword: keyword)
            }
            .map { cluster in
                MappedHit(hit: SearchHit(id: "library|place|\(cluster.id)",
                                         source: .library,
                                         kind: .place,
                                         title: cluster.title,
                                         subtitle: cluster.subtitle ?? cluster.group,
                                         badge: nil,
                                         visual: .place,
                                         payload: .place(cluster)))
            }
    }
}

// MARK: - 网盘

@MainActor
private final class CloudSearchProvider: SearchProviding {
    let source: SearchSourceKind = .cloud
    private weak var store: LibraryStore?

    init(store: LibraryStore) { self.store = store }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, AppModules.isEnabled(AppModule.cloud),
              let metadata = store.metadataStore, keyword.count >= 2 else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        async let assetTask = Task.detached(priority: .userInitiated) {
            metadata.searchCloudIndexAssets(keyword: keyword, limit: 0)
        }.value
        async let folderTask = Task.detached(priority: .userInitiated) {
            metadata.searchCloudIndexFolders(keyword: keyword, limit: 0)
        }.value
        let (assets, folders) = await (assetTask, folderTask)
        guard !Task.isCancelled else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        var hits: [SearchHit] = []
        var photoCount = 0
        var videoCount = 0
        for item in assets {
            guard let mount = store.cloudMount(for: item.mountID) else { continue }
            let record = item.record
            let subtitle = record.folderPath.map { "\(mount.name) · \($0)" } ?? mount.name
            if record.isVideo { videoCount += 1 } else { photoCount += 1 }
            hits.append(SearchHit(id: "cloud|file|\(item.mountID.uuidString)|\(record.path)",
                                  source: source,
                                  kind: record.isVideo ? .cloudVideo : .cloudPhoto,
                                  title: record.name,
                                  subtitle: subtitle,
                                  badge: record.isVideo ? "视频" : "图片",
                                  visual: .cloudFile(isVideo: record.isVideo),
                                  payload: .cloudFile(mountID: item.mountID,
                                                      folderPath: record.folderPath,
                                                      path: record.path),
                                  origin: mount.name,
                                  category: record.folderPath.map { ($0 as NSString).lastPathComponent }))
        }
        for item in folders {
            guard let mount = store.cloudMount(for: item.mountID) else { continue }
            hits.append(SearchHit(id: "cloud|folder|\(item.mountID.uuidString)|\(item.path)",
                                  source: source,
                                  kind: .cloudFolder,
                                  title: item.name,
                                  subtitle: "\(mount.name) · \(item.mediaCount) 个文件",
                                  badge: nil,
                                  visual: .cloudFolder,
                                  payload: .cloudFolder(mountID: item.mountID,
                                                        path: item.path),
                                  origin: mount.name))
        }
        return SearchSection(source: source,
                             hits: hits,
                             total: hits.count,
                             kindCounts: [.cloudPhoto: photoCount,
                                          .cloudVideo: videoCount,
                                          .cloudFolder: folders.count])
    }
}

// MARK: - 影院

@MainActor
private final class CinemaSearchProvider: SearchProviding {
    let source: SearchSourceKind = .cinema
    private weak var store: LibraryStore?

    init(store: LibraryStore) { self.store = store }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        var hits: [SearchHit] = []
        var movies = 0
        var series = 0

        for (scope, entries) in store.cinemaIndexes {
            let scopeKey = Self.scopeKey(scope)
            let scopeName = Self.scopeName(scope, store: store)
            var grouped: [String: [CinemaEntry]] = [:]
            for entry in entries.values {
                let haystack = [entry.title,
                                entry.originalTitle ?? "",
                                entry.folderHint ?? ""].joined(separator: " ")
                guard haystack.localizedCaseInsensitiveContains(keyword) else { continue }
                let key = entry.kind == .tv ? "tv|\(entry.title)" : "movie|\(entry.id.uuidString)"
                grouped[key, default: []].append(entry)
            }
            for (key, list) in grouped {
                guard let first = list.min(by: {
                    ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
                }) else { continue }
                if first.kind == .movie { movies += 1 } else { series += 1 }

                var subtitle: [String] = [scopeName]
                if let year = first.year { subtitle.append(String(year)) }
                if first.kind == .tv, list.count > 1 { subtitle.append("\(list.count) 集") }
                if !first.matched { subtitle.append("未刮削") }

                hits.append(SearchHit(id: "cinema|\(scopeKey)|\(key)",
                                      source: source,
                                      kind: first.kind == .movie ? .movie : .series,
                                      title: first.title,
                                      subtitle: subtitle.joined(separator: " · "),
                                      badge: first.kind.title,
                                      visual: .cinemaPoster(first.posterURL, first.kind),
                                      payload: .cinema(scopeKey: scopeKey,
                                                       queueTitle: first.title,
                                                       entry: first),
                                      origin: scopeName))
            }
        }

        hits.sort {
            ($0.title.localizedStandardCompare($1.title) == .orderedAscending)
        }
        return SearchSection(source: source,
                             hits: hits,
                             total: hits.count,
                             kindCounts: [.movie: movies, .series: series])
    }

    private static func scopeKey(_ scope: CinemaScope) -> String {
        switch scope {
        case .local: return "local"
        case .mount(let id): return "mount-\(id.uuidString)"
        }
    }

    private static func scopeName(_ scope: CinemaScope, store: LibraryStore) -> String {
        switch scope {
        case .local: return "本地影院"
        case .mount(let id):
            return "\(store.cloudMount(for: id)?.name ?? "网盘") 影院"
        }
    }
}

// MARK: - 电视

@MainActor
private final class TelevisionSearchProvider: SearchProviding {
    let source: SearchSourceKind = .television
    private weak var tv: IPTVBrowserModel?

    init(tv: IPTVBrowserModel) { self.tv = tv }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tv, tv.enabled, AppModules.isEnabled(AppModule.television), !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        // 检索词归一：「上海电视台」「上海频道」都按「上海」找，避免把台名后缀当成必须命中的字样。
        let tokens = TVSearchQuery.tokens(keyword)
        // 节目单可能还没从磁盘垫进内存：先等它加载完再检索，否则节目结果一定是空的。
        await tv.ensureEPGFromCache()
        // 磁盘里也没有节目单：顺带排一次网络更新，节目结果下一轮搜索才能命中。
        // 上一次更新失败时不再自动重试，避免每敲一个字就重新下载一遍。
        if tv.epgPrograms.isEmpty, tv.epgError == nil {
            tv.loadEPGIfNeeded()
        }

        /// 命中优先级：频道名 > 分组 > 省份归属 > 源名称。
        /// 省份归属让「上海」也能找到东方卫视、哈哈炫动这类不带省名的本地台。
        func matchRank(_ channel: TVChannel) -> Int? {
            if tokens.contains(where: { channel.name.localizedCaseInsensitiveContains($0) }) {
                return 0
            }
            if TVSearchQuery.matchesChannelIdentity(channel, tokens: tokens) {
                return 1
            }
            let playlist = tv.playlistName(for: channel.playlistID)
            if tokens.contains(where: { playlist.localizedCaseInsensitiveContains($0) }) {
                return 2
            }
            return nil
        }

        let matched = tv.channels.compactMap { channel -> (channel: TVChannel, rank: Int)? in
            guard let rank = matchRank(channel) else { return nil }
            return (channel, rank)
        }
        let sorted = matched.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            let leftOK = tv.probeState(for: left.channel.id) == .available
            let rightOK = tv.probeState(for: right.channel.id) == .available
            if leftOK != rightOK { return leftOK }
            return left.channel.name.localizedStandardCompare(right.channel.name) == .orderedAscending
        }
        // 节目单同样参与检索：一档节目占一条结果，点开按直播 / 回看处理。
        // 不做条数截断：频道与节目都返回全部命中。
        var programEntries = tv.searchPrograms(keyword: keyword, limit: 0)
        var seenPrograms = Set(programEntries.map { "\($0.channel.id)|\($0.program.id)" })
        // 台名命中时顺带带上这台的节目单：节目名里通常没有台名，
        // 只按节目名搜的话，「东方卫视」永远看不到它今天播什么。
        // 每台取正在播 + 接下来两档，已经按节目名命中的不重复。
        let now = Date()
        for entry in sorted where entry.rank <= 1 {
            let upcoming = tv.programs(for: entry.channel)
                .filter { $0.end > now }
                .prefix(3)
            for program in upcoming {
                let signature = "\(entry.channel.id)|\(program.id)"
                guard seenPrograms.insert(signature).inserted else { continue }
                programEntries.append((channel: entry.channel, program: program))
            }
            if programEntries.count >= 60 { break }
        }
        let channelHits = sorted.map { entry -> SearchHit in
            let channel = entry.channel
            var subtitle = [tv.playlistName(for: channel.playlistID), channel.group]
            if let quality = channel.qualityLabel, !quality.isEmpty { subtitle.append(quality) }
            return SearchHit(id: "tv|\(channel.id)",
                             source: source,
                             kind: .channel,
                             title: channel.name,
                             subtitle: subtitle.joined(separator: " · "),
                             badge: channel.qualityLabel,
                             visual: .channelLogo(channel.logoURL),
                             payload: .channel(channel),
                             origin: tv.playlistName(for: channel.playlistID),
                             category: channel.group)
        }
        let programHits = programEntries.map { entry -> SearchHit in
            let channel = entry.channel
            let program = entry.program
            let subtitle = "\(channel.name) · \(Self.programDayLabel(program.start)) "
                + Self.programTimeRange(program)
            return SearchHit(id: "tvp|\(channel.id)|\(program.id)",
                             source: source,
                             kind: .program,
                             title: program.title,
                             subtitle: subtitle,
                             badge: Self.programBadge(program, channel: channel),
                             visual: .channelLogo(channel.logoURL),
                             payload: .program(channel: channel, program: program),
                             origin: tv.playlistName(for: channel.playlistID),
                             category: channel.group)
        }
        var kindCounts: [SearchHitKind: Int] = [.channel: matched.count]
        if !programEntries.isEmpty { kindCounts[.program] = programEntries.count }
        return SearchSection(source: source,
                             hits: channelHits + programHits,
                             total: matched.count + programEntries.count,
                             kindCounts: kindCounts)
    }

    private static func programTimeRange(_ program: TVEPGProgram) -> String {
        let start = program.start.formatted(date: .omitted, time: .shortened)
        let end = program.end.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    /// 今天 / 明天 / 昨天，其余用「几月几日」：节目单跨好几天，只给时间会分不清哪天。
    private static func programDayLabel(_ date: Date) -> String {
        DateText.relativeDayOffset(date) ?? date.formatted(.dateTime.month(.defaultDigits).day())
    }

    private static func programBadge(_ program: TVEPGProgram,
                                     channel: TVChannel) -> String? {
        let now = Date()
        if program.start <= now && program.end > now { return "正在播" }
        if program.start > now { return "待播" }
        return (channel.catchUpSource ?? "").isEmpty ? nil : "可回看"
    }
}

// MARK: - 网络影院

/// 网络影院：只检索启用的网络影视源（苹果CMS / FoFo / 爱看片片 / 爱壹帆），
/// 结果单独成区，点开直达网络影院的详情页。
@MainActor
private final class NetworkCinemaSearchProvider: SearchProviding {
    let source: SearchSourceKind = .networkCinema
    private weak var catalog: CatalogBrowserModel?

    init(catalog: CatalogBrowserModel) { self.catalog = catalog }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, AppModules.isEnabled(AppModule.cinema), !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        let sources = catalog.enabledCinemaSources
        guard !sources.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        // 所有影视源并发检索：单个源超时 / 报错直接跳过，不影响其它源。
        var collected: [(index: Int, source: CatalogSource, items: [CatalogItem])] = []
        await withTaskGroup(of: (Int, [CatalogItem]).self) { group in
            for (index, catalogSource) in sources.enumerated() {
                group.addTask {
                    let items = await CatalogSearchSupport.search(catalogSource, keyword: keyword)
                    return (index, items)
                }
            }
            for await (index, items) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                guard !items.isEmpty else { continue }
                collected.append((index, sources[index], items))
            }
        }

        var hits: [SearchHit] = []
        var total = 0
        var movies = 0
        var series = 0
        for entry in collected.sorted(by: { $0.index < $1.index }) {
            let catalogSource = entry.source
            total += entry.items.count
            for item in entry.items {
                let isTV = NetworkCinemaModel.guessIsTV(item)
                if isTV { series += 1 } else { movies += 1 }
                let subtitle = item.remark.isEmpty
                    ? catalogSource.name
                    : "\(catalogSource.name) · \(item.remark)"
                hits.append(SearchHit(id: "networkCinema|\(catalogSource.id.uuidString)|\(item.id)",
                                      source: source,
                                      kind: isTV ? .series : .movie,
                                      title: item.title,
                                      subtitle: subtitle,
                                      badge: nil,
                                      visual: .catalogCover(sourceID: catalogSource.id,
                                                            url: item.coverURL),
                                      payload: .networkCinemaItem(sourceID: catalogSource.id,
                                                                  item: item,
                                                                  isTV: isTV),
                                      origin: catalogSource.name))
            }
        }
        var kindCounts: [SearchHitKind: Int] = [:]
        if movies > 0 { kindCounts[.movie] = movies }
        if series > 0 { kindCounts[.series] = series }
        return SearchSection(source: source,
                             hits: hits,
                             total: total,
                             kindCounts: kindCounts)
    }
}

// MARK: - 网络资源

@MainActor
private final class CatalogSearchProvider: SearchProviding {
    let source: SearchSourceKind = .catalog
    private weak var catalog: CatalogBrowserModel?

    init(catalog: CatalogBrowserModel) { self.catalog = catalog }

    func search(query: String, limit: Int) async -> SearchSection {
        await search(query: query, limit: limit, onPartial: { _ in })
    }

    /// 资源分区内部按站点增量发布：每完成一个站点就把「已到达的站点」重新拼成一个分区，
    /// 结果页据此逐站上屏、计数实时变化，而不是等所有站点跑完一次性出现。
    func search(query: String,
                limit: Int,
                onPartial: @escaping @MainActor (SearchSection) -> Void) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, AppModules.isEnabled(AppModule.catalog),
              !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        var groups: [UUID: CatalogGlobalResult] = [:]
        let final = await catalog.searchUnified(keyword: keyword,
                                                updatesUI: false,
                                                includeLocal: true) { group in
            groups[group.sourceID] = group
            onPartial(Self.makeSection(groups: groups, catalog: catalog))
        }
        guard !Task.isCancelled else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        let finalGroups = Dictionary(uniqueKeysWithValues: final.map { ($0.sourceID, $0) })
        return Self.makeSection(groups: finalGroups, catalog: catalog)
    }

    /// 把「已到达的站点分组」按侧边栏来源顺序拼成统一搜索分区。
    private static func makeSection(groups: [UUID: CatalogGlobalResult],
                                    catalog: CatalogBrowserModel) -> SearchSection {
        let order = Dictionary(uniqueKeysWithValues:
            catalog.enabledResourceSources.enumerated().map { ($1.id, $0) })
        let ordered = groups.values.sorted {
            (order[$0.sourceID] ?? Int.max) < (order[$1.sourceID] ?? Int.max)
        }
        var hits: [SearchHit] = []
        var total = 0
        var kindCounts: [SearchHitKind: Int] = [:]
        for group in ordered {
            // 图集与视频在结果里分成两种类型：筛选条、徽标与打开方式都据此区分。
            // 综合站必须按条目判断，同一站点里可能两种都有。
            let source = catalog.sources.first(where: { $0.id == group.sourceID })
            for item in group.items {
                let isGallery = source.map { item.isGallery(in: $0) } ?? false
                let kind: SearchHitKind = isGallery ? .catalogGallery : .catalogVideo
                total += 1
                kindCounts[kind, default: 0] += 1
                let subtitle = item.remark.isEmpty
                    ? group.sourceName
                    : "\(group.sourceName) · \(item.remark)"
                hits.append(SearchHit(id: "catalog|\(group.sourceID.uuidString)|\(item.id)",
                                      source: .catalog,
                                      kind: kind,
                                      title: item.title,
                                      subtitle: subtitle,
                                      badge: isGallery ? "图集" : nil,
                                      visual: .catalogCover(sourceID: group.sourceID,
                                                            url: item.coverURL),
                                      payload: .catalogItem(sourceID: group.sourceID,
                                                            item: item),
                                      origin: group.sourceName,
                                      category: item.categoryID.flatMap {
                                          catalog.category(withID: $0)?.title
                                      }))
            }
        }
        return SearchSection(source: .catalog, hits: hits, total: total, kindCounts: kindCounts)
    }
}

// MARK: - 拾光星图

/// 星图：只检索内置资料库（catalog.sqlite）里的人物与作品。
/// 与「网络资源」的来源互不依赖；模块开关关闭后整段结果消失。
@MainActor
private final class AtlasSearchProvider: SearchProviding {
    let source: SearchSourceKind = .atlas

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AtlasCatalogPaths.isLoaded, keyword.count >= 2 else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        let atlas = AtlasStore.shared
        async let peopleTask = atlas.searchPeople(keyword, limit: 10)
        async let worksTask = atlas.searchWorks(keyword, limit: 10)
        let people = await peopleTask
        let works = await worksTask
        guard !Task.isCancelled else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        let personHits = people.map { person in
            SearchHit(id: "atlas|person|\(person.id)",
                      source: source,
                      kind: .atlasPerson,
                      title: person.name,
                      subtitle: "\(person.regionTitle) · \(person.workCount) 部作品",
                      badge: "人物",
                      visual: .atlasPerson(id: person.id, name: person.name),
                      payload: .atlasPerson(person.id),
                      origin: "拾光星图")
        }
        let workHits = works.map { work in
            var subtitle = work.dvdID
            if let date = work.releaseDate { subtitle += " · \(AtlasLook.shortDate(date))" }
            return SearchHit(id: "atlas|work|\(work.id)",
                             source: source,
                             kind: .atlasWork,
                             title: work.displayTitle,
                             subtitle: subtitle,
                             badge: "作品",
                             visual: .atlasCover(url: work.coverURL ?? work.thumbURL),
                             payload: .atlasWork(work.id),
                             origin: "拾光星图")
        }
        var kindCounts: [SearchHitKind: Int] = [:]
        if !personHits.isEmpty { kindCounts[.atlasPerson] = personHits.count }
        if !workHits.isEmpty { kindCounts[.atlasWork] = workHits.count }
        return SearchSection(source: source,
                             hits: personHits + workHits,
                             total: personHits.count + workHits.count,
                             kindCounts: kindCounts)
    }
}
