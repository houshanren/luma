import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Queries

    var sidebarTitle: String {
        if let similarScope { return "与「\(similarScope.title)」相似" }
        switch sidebarItem {
        case .library: return "图库"
        case .collections: return "精选集"
        case .favorites: return "个人收藏"
        case .recentlySaved: return "最近保存"
        case .duplicates: return "重复项目"
        case .map: return "地图"
        case .places: return "位置"
        case .people: return "人物"
        case .videos: return "视频"
        case .screenshots: return "截屏"
        case .hidden: return "已隐藏"
        case .allAlbums: return "所有相簿"
        case .mediaTypes: return "媒体类型"
        case .scenes: return "场景"
        case .moreItems: return "更多项目"
        case .album(let id): return albums.first(where: { $0.id == id })?.name ?? "相簿"
        case .smartAlbum(let id): return smartAlbums.first(where: { $0.id == id })?.name ?? "智能相簿"
        case .folder(let id): return folders.first(where: { $0.id == id })?.name ?? "文件夹"
        case .selfies: return "自拍"
        case .panoramas: return "全景照片"
        case .livePhotos: return "实况照片"
        case .animated: return "动图"
        case .raws: return "RAW"
        case .recentlyEdited: return "最近编辑"
        case .imports: return "导入项目"
        case .ocrTexts: return "包含文字"
        case .scene(let id): return SceneCatalog.category(id: id)?.title ?? "场景"
        case .health: return "图库体检"
        case .blurry: return "可能模糊"
        case .similarDuplicates: return "相似备选"
        case .largeVideos: return "过大视频"
        case .revisit: return "值得重看"
        case .trash: return "最近删除"
        case .systemLibrary: return systemLibraryName ?? "系统照片图库"
        case .systemCollections: return "精选集"
        case .systemAlbums: return "相簿"
        case .systemMediaTypes: return "媒体类型"
        case .systemMoreItems: return "更多项目"
        case .systemLibraries: return "系统图库"
        case .cloudStorages: return "网络存储"
        case .systemAlbum(let id): return systemAlbums.first(where: { $0.id == id })?.name ?? "系统相簿"
        case .systemFolder(let id): return systemFolders.first(where: { $0.id == id })?.name ?? "系统文件夹"
        case .systemFavorites: return "个人收藏"
        case .systemVideos: return "视频"
        case .systemScreenshots: return "截屏"
        case .systemHidden: return "已隐藏"
        case .systemTrash: return "最近删除"
        case .systemPortraits: return "人像"
        case .systemSelfies: return "自拍"
        case .systemLivePhotos: return "实况照片"
        case .systemPanoramas: return "全景照片"
        case .systemSlowMotion: return "慢动作"
        case .systemScreenRecordings: return "录屏"
        case .systemAnimated: return "动图"
        case .systemRAW: return "RAW"
        case .systemEdited: return "最近编辑"
        case .systemRecentlyViewed: return "最近查看"
        case .systemDuplicates: return "重复项目"
        case .systemHandwriting: return "手写"
        case .systemIllustrations: return "插图"
        case .systemRecentlySaved: return "最近保存"
        case .systemImports: return "导入项目"
        case .systemMap: return "地图"
        case .systemPlaces: return "位置"
        case .systemPeople: return "人物与宠物"
        case .cloudMount(let id): return cloudMounts.first(where: { $0.id == id })?.name ?? "网络存储"
        }
    }

    var isSystemScope: Bool {
        sidebarItem.isSystemScope
    }

    /// 当前范围的上一级（用于工具栏「返回」与相簿链路）：没有上一级时返回 nil。
    var navigationParent: (item: SidebarItem, title: String)? {
        switch sidebarItem {
        case .album(let id):
            guard let album = albums.first(where: { $0.id == id }) else { return nil }
            if let folderID = album.folderID,
               let folder = folders.first(where: { $0.id == folderID }) {
                return (.folder(folderID), folder.name)
            }
            return (.allAlbums, "所有相簿")
        case .folder(let id):
            guard let folder = folders.first(where: { $0.id == id }) else { return nil }
            if let parentID = folder.parentID,
               let parent = folders.first(where: { $0.id == parentID }) {
                return (.folder(parentID), parent.name)
            }
            return (.allAlbums, "所有相簿")
        case .smartAlbum:
            return (.allAlbums, "所有相簿")
        case .systemAlbum(let id):
            guard let album = systemAlbum(id: id) else { return nil }
            if let parentID = album.parentFolder,
               let parent = systemFolders.first(where: { $0.id == parentID }) {
                return (.systemFolder(parentID), parent.name)
            }
            return (.systemLibrary, systemLibraryName ?? "所有项目")
        case .systemFolder(let id):
            guard let folder = systemFolders.first(where: { $0.id == id }) else { return nil }
            if let parentID = folder.parent,
               let parent = systemFolders.first(where: { $0.id == parentID }) {
                return (.systemFolder(parentID), parent.name)
            }
            return (.systemLibrary, systemLibraryName ?? "所有项目")
        case .allAlbums, .mediaTypes, .scenes, .moreItems:
            return (.library, "图库")
        case .systemAlbums, .systemMediaTypes, .systemMoreItems:
            return (.systemLibrary, systemLibraryName ?? "所有项目")
        default:
            return nil
        }
    }

    /// 回到当前相簿 / 文件夹的上一级。
    func navigateUp() {
        guard let parent = navigationParent else { return }
        navigate(to: parent.item)
    }

    /// 当前图库就是官方「照片」图库：拾光作为它的增强层，主界面直接展示这个库自己的照片，
    /// 拾光自己的元数据（设置、相簿、分析）写在同一个库的 `database/PhotosClone.sqlite` 里。
    var isNativeContainer: Bool {
        guard let url = LibraryPaths.containerLibraryURL else { return false }
        return LibraryPaths.isNativeLibrary(url)
    }

    var isCloudScope: Bool {
        if case .cloudMount = sidebarItem { return true }
        return false
    }

    /// 当前是否是照片网格页面（用于菜单项的可用状态）。
    var isGridScopeForCommands: Bool {
        switch sidebarItem {
        case .collections, .map, .places, .systemMap, .systemPlaces, .systemPeople,
             .allAlbums, .folder, .systemFolder, .people, .cloudMount, .duplicates,
             .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes,
             .systemCollections, .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages,
             .systemDuplicates:
            return false
        default:
            return true
        }
    }

    var isReadOnlyScope: Bool { isSystemScope || isCloudScope }

    /// 只有「图库」这一层需要年/月时间轴总览，相簿与文件夹保持普通网格。
    var isTimelineScope: Bool {
        sidebarItem == .library || sidebarItem == .systemLibrary
    }

    var isCurrentCloudWritable: Bool {
        guard case .cloudMount(let id) = sidebarItem,
              let mount = cloudMounts.first(where: { $0.id == id }) else { return false }
        return mount.kind.supportsWrite
    }

    /// 当前 SMB 挂载是否以「整个共享」方式递归扫描。
    var isCurrentCloudScanAll: Bool {
        guard case .cloudMount(let id) = sidebarItem,
              let mount = cloudMounts.first(where: { $0.id == id }) else { return false }
        return mount.kind == .smb && mount.scanAll
    }

    /// 当前挂载是否为 SMB：系统已把它挂成 /Volumes 下的本地文件系统，可复用系统应用与访达。
    var isCurrentCloudSMB: Bool {
        guard case .cloudMount(let id) = sidebarItem,
              let mount = cloudMounts.first(where: { $0.id == id }) else { return false }
        return mount.kind == .smb
    }

    /// 媒体类型总览：数量与封面一次遍历算完（本地 / 系统图库共用）。
    var mediaTypeSummary: MediaTypeSummary {
        let key = "\(contentRevision)-\(isSystemScope)"
        if mediaTypeSummaryCacheKey == key { return mediaTypeSummaryCacheValue }
        var summary = MediaTypeSummary()
        let source = isSystemScope ? systemPhotos : photos
        for photo in source {
            guard photo.deletedAt == nil, !photo.isHidden else { continue }
            for type in MediaTypeKey.allCases where type.matches(photo) {
                summary.counts[type, default: 0] += 1
                if summary.covers[type] == nil {
                    summary.covers[type] = photo
                }
            }
        }
        mediaTypeSummaryCacheKey = key
        mediaTypeSummaryCacheValue = summary
        return summary
    }

    func photos(for item: SidebarItem) -> [PhotoItem] {
        let live = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        switch item {
        case .library, .collections, .allAlbums, .people, .imports:
            return live
        case .ocrTexts:
            return live.filter { !(analysisIndex[$0.id]?.text.isEmpty ?? true) }
        case .scene(let id):
            return photosMatchingScene(id)
        case .health:
            return live
        case .blurry:
            return blurryPhotos
        case .similarDuplicates:
            return similarDuplicatePhotos
        case .largeVideos:
            return largeVideoPhotos
        case .revisit:
            return revisitPhotos
        case .systemLibrary:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden }
        case .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes,
             .systemCollections, .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages:
            // 总览页只展示分类卡片，不返回照片。
            return []
        case .systemFavorites:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isFavorite }
        case .systemVideos:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isVideo }
        case .systemScreenshots:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.kind == .screenshot }
        case .systemHidden:
            return systemPhotos.filter { $0.deletedAt == nil && $0.isHidden }
        case .systemTrash:
            return systemPhotos.filter { $0.deletedAt != nil }
        case .systemPortraits:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isPortraitCapture }
        case .systemSelfies:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && !$0.isVideo && $0.kind == .selfie
            }
        case .systemLivePhotos:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isLivePhoto }
        case .systemPanoramas:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.kind == .panorama }
        case .systemSlowMotion:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isSlowMotion }
        case .systemScreenRecordings:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isScreenRecording }
        case .systemAnimated:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && ($0.isAnimated || $0.isAnimatedFile)
            }
        case .systemRAW:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isRAWFile }
        case .systemEdited:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && !$0.isVideo && ($0.editedAt != nil || $0.hasEdits)
            }
        case .systemRecentlyViewed:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden
                    && ($0.viewedAt ?? .distantPast) >= Self.recentlyViewedCutoff
            }
        case .systemDuplicates:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isDuplicateItem }
        case .systemHandwriting, .systemIllustrations:
            return []
        case .systemRecentlySaved:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && $0.addedAt >= Self.recentlySavedCutoff
            }
        case .systemImports:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isDeviceImport }
        case .systemMap:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && $0.hasLocation
            }
        case .systemPlaces:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && $0.hasLocation
            }
        case .systemPeople:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden }
        case .cloudMount:
            return cloudVisiblePhotos
        case .systemAlbum(let id):
            guard let album = systemAlbums.first(where: { $0.id == id }) else { return [] }
            let ids = Set(album.assetIDs)
            return systemPhotos.filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
        case .systemFolder(let id):
            let folderIDs = systemFolderSubtreeIDs(id)
            let albumIDs = Set(systemAlbums.filter {
                $0.parentFolder.map { folderIDs.contains($0) } ?? false
            }.map { $0.id })
            let assetIDs = Set(systemAlbums.filter { albumIDs.contains($0.id) }.flatMap { $0.assetIDs })
            return systemPhotos.filter {
                assetIDs.contains($0.id) && $0.deletedAt == nil && !$0.isHidden
            }
        case .favorites:
            return live.filter { $0.isFavorite }
        case .recentlySaved:
            let limit = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            return live.filter { $0.addedAt >= limit }
        case .duplicates:
            return duplicateGroups.flatMap(\.photos)
        case .map:
            return live.filter { $0.hasLocation }
        case .places:
            return live.filter { $0.hasLocation }
        case .videos:
            return live.filter { $0.isVideo }
        case .screenshots:
            return live.filter { $0.kind == .screenshot }
        case .selfies:
            return live.filter { $0.kind == .selfie }
        case .panoramas:
            return live.filter { $0.kind == .panorama }
        case .livePhotos:
            return live.filter { $0.isLivePhoto }
        case .animated:
            return live.filter { $0.isAnimatedFile || $0.isAnimated }
        case .raws:
            return live.filter { $0.isRAWFile }
        case .recentlyEdited:
            return live.filter { $0.hasEdits || $0.editedAt != nil }
        case .hidden:
            return photos.filter { $0.deletedAt == nil && $0.isHidden }
        case .album(let id):
            guard let album = albums.first(where: { $0.id == id }) else { return [] }
            // 相簿内按用户拖拽顺序展示，而不是全局拍摄时间顺序。
            let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            return album.photoIDs.compactMap { byID[$0] }
        case .smartAlbum(let id):
            guard let album = smartAlbums.first(where: { $0.id == id }) else { return [] }
            return live.filter { album.matches($0, analysis: self.analysisIndex[$0.id]) }
        case .folder(let id):
            let folderIDs = folderSubtreeIDs(id)
            let photoIDs = Set(albums.filter {
                $0.folderID.map { folderIDs.contains($0) } ?? false
            }.flatMap { $0.photoIDs })
            return live.filter { photoIDs.contains($0.id) }
        case .trash:
            return photos.filter { $0.deletedAt != nil }
        }
    }

    var basePhotos: [PhotoItem] {
        photos(for: sidebarItem)
    }

    func matchesFilter(_ photo: PhotoItem, albumPhotoIDs: Set<UUID>) -> Bool {
        switch photoFilter {
        case .all: return true
        case .favorites: return photo.isFavorite
        case .edited: return photo.hasEdits
        case .photos: return !photo.isVideo
        case .videos: return photo.isVideo
        case .screenshots:
            // 网盘没有可读的相机元数据，截屏只能按文件名判断。
            if photo.isCloud { return CloudMediaNaming.looksLikeScreenshot(photo.originalName) }
            return photo.kind == .screenshot
        case .mine: return photo.make != nil || photo.model != nil
        case .notInAlbum: return !albumPhotoIDs.contains(photo.id)
        }
    }

    /// 解析后的搜索条件：支持场景词、时间词（去年 / 5月 / 2024年）、类型限定与人物名。
    var currentSearchQuery: SearchQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchQuery() }
        var query = SearchQueryParser.parse(trimmed)
        guard !query.tokens.isEmpty, !localPeople.isEmpty else { return query }
        // 标签词里出现人物名时，改为按「这个人出现在照片里」筛选。
        var matchedPeople: Set<UUID> = []
        query.tokens.removeAll { token in
            guard let person = localPeople.first(where: {
                $0.name.lowercased() == token && !$0.assetIDs.isEmpty
            }) else { return false }
            matchedPeople.insert(person.id)
            return true
        }
        query.personIDs = matchedPeople
        return query
    }

    func matchesSearch(_ photo: PhotoItem, query: SearchQuery,
                       peopleByID: [UUID: LocalPerson] = [:]) -> Bool {
        guard !query.isEmpty else { return true }

        if let start = query.startDate, photo.capturedAt < start { return false }
        if let end = query.endDate, photo.capturedAt >= end { return false }
        if query.onlyFavorites, !photo.isFavorite { return false }
        if query.onlyVideos, !photo.isVideo { return false }
        if query.onlyPhotos, photo.isVideo { return false }
        if query.onlyScreenshots {
            let isScreenshot = photo.isCloud
                ? CloudMediaNaming.looksLikeScreenshot(photo.originalName)
                : photo.kind == .screenshot
            if !isScreenshot { return false }
        }
        if query.onlyLivePhotos, !photo.isLivePhoto { return false }
        if query.onlyEdited, !photo.hasEdits { return false }

        if !query.personIDs.isEmpty {
            for personID in query.personIDs {
                guard let person = peopleByID[personID],
                      person.assetIDs.contains(photo.id) else { return false }
            }
        }

        guard !query.tokens.isEmpty else { return true }

        var parts = [
            photo.originalName,
            photo.displayTitle,
            photo.displayFilename,
            (photo.displayFilename as NSString).pathExtension,
            photo.make ?? "",
            photo.model ?? "",
            photo.lens ?? "",
            photo.iso ?? "",
            photo.placeCountry ?? "",
            photo.placeProvince ?? "",
            photo.placeCity ?? "",
            photo.placeDistrict ?? "",
            photo.placePOI ?? "",
            (photo.keywords ?? []).joined(separator: " "),
            Self.kindTitle(photo.kind),
            DateText.fullFormatter.string(from: photo.capturedAt),
            DateText.dayFormatter.string(from: photo.capturedAt),
            DateText.yearFormatter.string(from: photo.capturedAt),
            formatFileSize(photo.fileSize)
        ]
        // 端侧分析结果：场景标签 + OCR 文字。网盘照片的识别结果只在内存里。
        let analysis = analysisIndex[photo.id] ?? (photo.isCloud ? cloudModel.analysis[photo.id] : nil)
        if let analysis, !analysis.searchBlob.isEmpty {
            parts.append(analysis.searchBlob)
        }
        let haystack = parts.joined(separator: " ").lowercased()
        return query.tokens.allSatisfy { token in
            if haystack.contains(token) { return true }
            // 中文口语查询扩展成 Vision 英文场景标签（如「海边」→ beach / seashore）。
            return SceneCatalog.searchLabels(for: token).contains { haystack.contains($0) }
        }
    }

    /// 网络存储网格：套用范围、筛选、搜索与排序；目录结果规模有限，直接在内存处理并缓存。
    var cloudVisiblePhotos: [PhotoItem] {
        let key = [
            String(cloudModel.revision),
            String(describing: cloudModel.scope),
            String(cloudModel.analysis.count),
            searchText,
            photoFilter.rawValue,
            sortKey.rawValue,
            String(sortAscending)
        ].joined(separator: "\u{1F}")
        if cloudVisibleCacheKey == key { return cloudVisibleCacheValue }
        var items = cloudPhotos.filter { !$0.isHidden }
        if cloudModel.scope != .all {
            let scope = cloudModel.scope
            items = items.filter { cloudPhoto($0, matches: scope) }
        }
        if photoFilter != .all {
            items = items.filter { matchesFilter($0, albumPhotoIDs: []) }
        }
        let query = currentSearchQuery
        if !query.isEmpty {
            let peopleByID = Dictionary(uniqueKeysWithValues: localPeople.map { ($0.id, $0) })
            items = items.filter { matchesSearch($0, query: query, peopleByID: peopleByID) }
        }
        let sorted = sortedByCurrentKey(items)
        cloudVisibleCacheKey = key
        cloudVisibleCacheValue = sorted
        return sorted
    }

    /// 影响 `visiblePhotos` 的状态指纹；筛选、排序、搜索等变化都会换 key。
    var visibleStateKey: String {
        [
            String(contentRevision),
            String(windowRevision),
            String(describing: sidebarItem),
            searchText,
            String(analysisIndex.count),
            photoFilter.rawValue,
            keywordFilter ?? "",
            selectedPlace?.id ?? "",
            selectedPerson.map { String($0.id) } ?? "",
            sortKey.rawValue,
            String(sortAscending),
            String(cloudModel.revision),
            String(describing: cloudModel.scope),
            String(cloudModel.analysis.count),
            String(isLoadingSystemLibrary),
            // 端侧分析会改变搜索/场景/OCR 的命中结果，必须参与缓存失效（避免分析过程中反复重算全库）。
            String((searchText.isEmpty && !isAnalysisScope) ? 0 : analysisIndex.count),
            similarScope?.sourceID.uuidString ?? "",
            String(similarScope?.ids.count ?? 0)
        ].joined(separator: "\u{1F}")
    }

    var visiblePhotos: [PhotoItem] {
        // 大图库：筛选/排序在 SQLite 完成，这里只返回已加载的窗口。
        if isPagedScope { return windowPhotos }
        // 大图库（数十万项）筛选 + 排序开销很大，这里按关键状态缓存结果。
        let key = visibleStateKey
        if visibleCacheKey == key { return visibleCacheValue }
        let value = computeVisiblePhotos()
        visibleCacheKey = key
        visibleCacheValue = value
        return value
    }

    func computeVisiblePhotos() -> [PhotoItem] {
        // 网络存储的筛选、搜索与排序已经在 `cloudVisiblePhotos` 中完成。
        if isCloudScope { return basePhotos }
        var items = basePhotos
        if photoFilter != .all {
            let albumPhotoIDs: Set<UUID>
            if isSystemScope {
                albumPhotoIDs = Set(systemAlbums.flatMap { $0.assetIDs })
            } else {
                albumPhotoIDs = Set(albums.flatMap { $0.photoIDs })
            }
            items = items.filter { matchesFilter($0, albumPhotoIDs: albumPhotoIDs) }
        }
        if let selectedPlace {
            items = items.filter { PlaceClusterBuilder.key(for: $0).id == selectedPlace.id }
        }
        if let selectedPerson {
            let ids = Set(selectedPerson.assetIDs)
            items = items.filter { ids.contains($0.id) }
        }
        if let keywordFilter, !keywordFilter.isEmpty {
            items = items.filter { $0.tags.contains(keywordFilter) }
        }
        if let similarScope {
            items = items.filter { similarScope.ids.contains($0.id) }
        }
        let query = currentSearchQuery
        if !query.isEmpty {
            let peopleByID = Dictionary(uniqueKeysWithValues: localPeople.map { ($0.id, $0) })
            items = items.filter { matchesSearch($0, query: query, peopleByID: peopleByID) }
        }
        switch sidebarItem {
        case .recentlySaved, .systemRecentlySaved, .systemImports:
            return items.sorted { $0.addedAt > $1.addedAt }
        case .trash, .systemTrash:
            return items.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .systemAlbum(let id):
            // 官方相簿在 Photos.sqlite 的关联表里保存了自己的显示顺序（拍摄日期 / 添加日期 / 手动拖拽）。
            // 默认沿用该顺序（与系统「照片」一致）；用户在排序菜单里换成其它字段时按用户选择排序。
            guard sortKey == .capturedAt, let album = systemAlbum(id: id) else {
                return sortedByCurrentKey(items)
            }
            let positions = Dictionary(uniqueKeysWithValues:
                album.assetIDs.enumerated().map { ($0.element, $0.offset) })
            return items.sorted {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }
        default:
            // 扫描过程中先按数据库顺序展示，结束后再统一排序，避免反复排序超大数组。
            if isLoadingSystemLibrary, isSystemScope {
                return items
            }
            // 相簿使用用户拖拽排序，不再按全局排序字段重排。
            if case .album = sidebarItem {
                return items
            }
            return sortedByCurrentKey(items)
        }
    }

    /// 切换排序字段：同时按该字段的默认方向调整升/降序。
    func applySort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key.prefersAscending
        }
    }

    func sortedByCurrentKey(_ items: [PhotoItem]) -> [PhotoItem] {
        let ascending = sortAscending
        func compareStrings(_ lhs: String, _ rhs: String) -> Bool {
            let result = lhs.localizedStandardCompare(rhs)
            guard result != .orderedSame else { return false }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        switch sortKey {
        case .capturedAt:
            return items.sorted { ascending ? $0.capturedAt < $1.capturedAt : $0.capturedAt > $1.capturedAt }
        case .addedAt:
            return items.sorted { ascending ? $0.addedAt < $1.addedAt : $0.addedAt > $1.addedAt }
        case .title:
            return items.sorted { compareStrings($0.displayTitle, $1.displayTitle) }
        case .filename:
            return items.sorted { compareStrings($0.displayFilename, $1.displayFilename) }
        case .fileSize:
            return items.sorted { ascending ? $0.fileSize < $1.fileSize : $0.fileSize > $1.fileSize }
        case .kind:
            return items.sorted { compareStrings(Self.kindTitle($0.kind), Self.kindTitle($1.kind)) }
        case .camera:
            return items.sorted { compareStrings($0.model ?? $0.make ?? "", $1.model ?? $1.make ?? "") }
        case .place:
            return items.sorted {
                compareStrings(PlaceClusterBuilder.key(for: $0).title,
                               PlaceClusterBuilder.key(for: $1).title)
            }
        case .duration:
            return items.sorted { ascending ? ($0.duration ?? 0) < ($1.duration ?? 0)
                                           : ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }

    static func kindTitle(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: return "照片"
        case .video: return "视频"
        case .screenshot: return "截屏"
        case .panorama: return "全景"
        case .selfie: return "自拍"
        }
    }

    var sections: [PhotoSection] {
        // 分段需要遍历全部可见项，按指纹缓存，避免翻页/选中时反复分组。
        let key = visibleStateKey + "\u{1E}" + grouping.rawValue
        if sectionsCacheKey == key { return sectionsCacheValue }
        let value = computeSections()
        sectionsCacheKey = key
        sectionsCacheValue = value
        return value
    }

    func computeSections() -> [PhotoSection] {
        let items = visiblePhotos
        guard !items.isEmpty else { return [] }
        // 「导入项目」按导入批次分段。
        if sidebarItem == .imports {
            return importSections(from: items)
        }
        // 只有图库才按年/月分段；相簿、文件夹、智能项目一律单段普通网格。
        if grouping == .all || !isTimelineScope {
            return [PhotoSection(id: "all", title: nil, photos: items)]
        }
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        for item in items {
            let components = calendar.dateComponents([.year, .month, .day], from: item.capturedAt)
            let key: String
            switch grouping {
            case .years:
                key = "\(components.year ?? 0)"
            case .months:
                key = "\(components.year ?? 0)-\(components.month ?? 0)"
            case .all:
                key = "all"
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
        }
        let sectionDates = buckets.mapValues { $0.first?.capturedAt ?? .distantPast }
        let newestFirst = sortKey == .capturedAt ? !sortAscending : true
        let sortedKeys = order.sorted { lhs, rhs in
            let left = sectionDates[lhs] ?? .distantPast
            let right = sectionDates[rhs] ?? .distantPast
            return newestFirst ? left > right : left < right
        }
        return sortedKeys.map { key in
            let bucket = buckets[key] ?? []
            let title: String
            switch grouping {
            case .years:
                title = DateText.yearFormatter.string(from: bucket.first?.capturedAt ?? Date())
            case .months:
                title = DateText.monthFormatter.string(from: bucket.first?.capturedAt ?? Date())
            case .all:
                title = ""
            }
            return PhotoSection(id: key, title: title, photos: bucket)
        }
    }

    /// 「导入项目」分段：同一批导入共用一个批次 ID；旧照片按添加日期归组。
    func importSections(from items: [PhotoItem]) -> [PhotoSection] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        var dates: [String: Date] = [:]
        for item in items {
            let key: String
            if let batch = item.importBatchID {
                key = "batch-\(batch.uuidString)"
            } else {
                let parts = calendar.dateComponents([.year, .month, .day], from: item.addedAt)
                key = String(format: "day-%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
            dates[key] = min(dates[key] ?? item.addedAt, item.addedAt)
        }
        return order
            .sorted { (dates[$0] ?? .distantPast) > (dates[$1] ?? .distantPast) }
            .map { key in
                let stamp = dates[key] ?? Date()
                return PhotoSection(id: key,
                                    title: "导入于 " + Self.importTitleFormatter.string(from: stamp),
                                    photos: buckets[key] ?? [])
            }
    }

    static let importTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    // MARK: - 时间轴总览

    /// 年总览点击某年：切到月总览，并定位到该年的第一个月。
    func openMonths(of year: Int) {
        grouping = .months
        // 大图库：月份数据来自 SQL 分区，优先用已加载的月份分段定位。
        if usesSQLOverview {
            if let group = monthGroups.first(where: { $0.id.hasPrefix("\(year)-") }) {
                scrollTargetSection = group.id
            } else {
                pendingMonthScrollYear = year
                reloadOverviewIfNeeded()
            }
            return
        }
        let calendar = Calendar.current
        guard let first = visiblePhotos.first(where: {
            calendar.component(.year, from: $0.capturedAt) == year
        }) else { return }
        let parts = calendar.dateComponents([.year, .month], from: first.capturedAt)
        scrollTargetSection = "\(parts.year ?? year)-\(parts.month ?? 1)"
    }

    /// 月总览点击某天：回到所有照片并定位到那天的第一张。
    func openAllPhotos(at photoID: UUID) {
        grouping = .all
        scrollTargetID = photoID
        // 大图库需要先把窗口移到目标照片附近，再交给网格滚动。
        if isPagedScope { reloadVisibleWindowIfNeeded() }
    }

    func photo(id: UUID) -> PhotoItem? {
        photos.first(where: { $0.id == id })
    }

    var viewerPhoto: PhotoItem? {
        guard let viewerID else { return nil }
        // 查看器 body 会多次读取当前照片，缓存一次避免重复线性查找。
        if let cache = viewerPhotoCache, cache.id == viewerID, cache.revision == contentRevision {
            return cache.photo
        }
        let value = anyPhoto(id: viewerID)
        // 网盘照片列表变动不经过 contentRevision，不做缓存。
        if value?.isCloud != true {
            viewerPhotoCache = ViewerPhotoCache(id: viewerID, revision: contentRevision, photo: value)
        }
        return value
    }

    /// 自动生成的回忆（本地图库）。
    var memories: [PhotoMemory] {
        if memoryCacheKey == contentRevision { return memoryCacheValue }
        let value = MemoryBuilder.build(from: photos)
        memoryCacheKey = contentRevision
        memoryCacheValue = value
        return value
    }

    /// 按时间与地点自动识别的旅行。
    var trips: [TripStory] {
        if tripCacheKey == contentRevision { return tripCacheValue }
        let value = TripBuilder.build(from: photos)
        tripCacheKey = contentRevision
        tripCacheValue = value
        return value
    }

    /// 把一次旅行直接转成电影风格的回忆影片。
    func playTripMemory(_ trip: TripStory) {
        activeTrip = nil
        let photos = trip.photos.filter { !$0.isVideo }
        guard !photos.isEmpty else {
            showToast("这次旅行没有可播放的照片")
            return
        }
        activeMemory = PhotoMemory(id: "memory-" + trip.id,
                                   title: trip.title,
                                   subtitle: trip.subtitle,
                                   kind: .place,
                                   photos: photos,
                                   style: .cinematic)
    }

    var totalLibraryCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }.count
    }

    var videoCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden && $0.isVideo }.count
    }

    var hiddenCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && $0.isHidden }.count
    }

    var trashCount: Int {
        photos.lazy.filter { $0.deletedAt != nil }.count
    }

    var libraryTotalBytes: Int64 {
        photos.reduce(Int64(0)) { $0 + ($1.deletedAt == nil ? $1.fileSize : 0) }
    }

    var libraryDateRange: String? {
        var minDate: Date?
        var maxDate: Date?
        for photo in photos where photo.deletedAt == nil {
            if let current = minDate {
                if photo.capturedAt < current { minDate = photo.capturedAt }
            } else {
                minDate = photo.capturedAt
            }
            if let current = maxDate {
                if photo.capturedAt > current { maxDate = photo.capturedAt }
            } else {
                maxDate = photo.capturedAt
            }
        }
        guard let minDate, let maxDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return "\(formatter.string(from: minDate)) – \(formatter.string(from: maxDate))"
    }

    var geoPhotos: [PhotoItem] {
        let source = isSystemScope
            ? systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden }
            : photos.filter { $0.deletedAt == nil && !$0.isHidden }
        return source.filter { $0.hasLocation }
    }
}
