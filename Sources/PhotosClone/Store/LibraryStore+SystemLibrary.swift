import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

/// 系统图库侧边栏计数：一次遍历算完，供徽标与「更多项目」的显示条件共用。
struct SystemSidebarCounts {
    var active = 0
    var hidden = 0
    var trash = 0
    var duplicate = 0
    var recentlySaved = 0
    var imports = 0
    var portrait = 0
    var screenshots = 0
    var totalBytes: Int64 = 0
    var earliest: Date?
    var latest: Date?
}

/// 系统图库「精选集」的汇总快照：数量 + 每类最多 4 张样本。
struct SystemCollectionSnapshot {
    var counts: [String: Int] = [:]
    var samples: [String: [PhotoItem]] = [:]
}

extension LibraryStore {
    // MARK: - System library

    func systemRootFolders() -> [SystemFolderInfo] {
        systemChildFolders(of: nil)
    }

    func systemChildFolders(of parent: Int64?) -> [SystemFolderInfo] {
        systemFolders.filter { $0.parent == parent }
            .sorted { Self.systemSortKey($0) < Self.systemSortKey($1) }
    }

    func systemAlbums(in parent: Int64?) -> [SystemAlbumInfo] {
        systemAlbums.filter { $0.parentFolder == parent }
            .sorted { Self.systemSortKey($0) < Self.systemSortKey($1) }
    }

    /// 文件夹与相簿按图库原始顺序（Photos.sqlite 的 Z_PK）混排，与官方「照片」侧边栏一致。
    /// 大图库有上万个相簿，按父节点一次性分组并缓存；只随相簿结构变化失效，
    /// 扫描时逐批到达的照片不会反复触发重建。
    func systemChildren(of parent: Int64?) -> [SystemSidebarEntry] {
        if systemChildrenCacheRevision != systemStructureRevision {
            var buckets: [Int64: [SystemSidebarEntry]] = [:]
            for folder in systemFolders {
                buckets[folder.parent ?? -1, default: []].append(.folder(folder))
            }
            for album in systemAlbums {
                buckets[album.parentFolder ?? -1, default: []].append(.album(album))
            }
            for key in buckets.keys {
                buckets[key]?.sort { $0.sortIndex < $1.sortIndex }
            }
            systemChildrenBuckets = buckets
            systemChildrenCacheRevision = systemStructureRevision
        }
        return systemChildrenBuckets[parent ?? -1] ?? []
    }

    /// 侧边栏徽标用的有效项目数（不含已删除与隐藏），按内容版本缓存。
    var systemActivePhotoCount: Int {
        systemSidebarCounts.active
    }

    /// 精选集卡片（后台版）：7 个分类各取 4 张样本，稀有分类会扫描一段日期索引，
    /// 放到后台执行，避免首次打开精选集卡住主线程。
    func systemCollectionSnapshotAsync() async -> SystemCollectionSnapshot {
        guard let index = systemIndex else { return systemCollectionSnapshot() }
        let scopes: [(String, SystemQueryScope)] = [
            ("favorites", .favorites), ("videos", .videos), ("selfies", .selfies),
            ("panoramas", .panoramas), ("screenshots", .screenshots),
            ("recentlySaved", .recentlySaved), ("edited", .edited)
        ]
        var queries: [(String, SystemQuery)] = []
        for (key, scope) in scopes {
            var query = buildSystemQuery(scope: scope)
            query.filter = .all
            query.tokens = []
            query.overlayKeywordIDs = nil
            query.includeIDs = nil
            queries.append((key, query))
        }
        let pairs = await Task.detached(priority: .userInitiated) {
            queries.map { (key, query) in
                (key, index.summary(query).total, index.page(query, offset: 0, limit: 4))
            }
        }.value
        var result = SystemCollectionSnapshot()
        for (key, count, photos) in pairs {
            result.counts[key] = count
            result.samples[key] = photos.map { applySystemOverlay($0) }
        }
        return result
    }

    /// 系统图库「精选集」：索引模式按分类各取 4 张样本，不遍历整库。
    func systemCollectionSnapshot() -> SystemCollectionSnapshot {
        var result = SystemCollectionSnapshot()
        if let index = systemIndex {
            let scopes: [(String, SystemQueryScope)] = [
                ("favorites", .favorites), ("videos", .videos), ("selfies", .selfies),
                ("panoramas", .panoramas), ("screenshots", .screenshots),
                ("recentlySaved", .recentlySaved), ("edited", .edited)
            ]
            for (key, scope) in scopes {
                var query = buildSystemQuery(scope: scope)
                query.filter = .all
                query.tokens = []
                query.overlayKeywordIDs = nil
                query.includeIDs = nil
                result.counts[key] = index.summary(query).total
                result.samples[key] = index.page(query, offset: 0, limit: 4).map { applySystemOverlay($0) }
            }
            return result
        }
        for photo in systemPhotos {
            guard photo.deletedAt == nil, !photo.isHidden else { continue }
            func add(_ key: String) {
                result.counts[key, default: 0] += 1
                if (result.samples[key]?.count ?? 0) < 4 {
                    result.samples[key, default: []].append(photo)
                }
            }
            if photo.isFavorite { add("favorites") }
            if photo.isVideo { add("videos") }
            if !photo.isVideo, photo.kind == .selfie { add("selfies") }
            if photo.kind == .panorama { add("panoramas") }
            if photo.kind == .screenshot { add("screenshots") }
            if photo.addedAt >= Self.recentlySavedCutoff { add("recentlySaved") }
            if !photo.isVideo, photo.editedAt != nil || photo.hasEdits { add("edited") }
        }
        return result
    }

    /// 系统图库侧边栏计数：一次遍历算完所有徽标，避免每个计数各扫一遍 20 万张照片。
    var systemSidebarCounts: SystemSidebarCounts {
        if systemCountsCacheRevision == contentRevision, let cached = systemCountsCache {
            return cached
        }
        // 索引模式：一次 SQL 聚合，不遍历整库。
        if let index = systemIndex {
            let raw = index.counts(overrides: buildSystemQuery(scope: .all))
            var counts = SystemSidebarCounts()
            counts.active = raw.active
            counts.hidden = raw.hidden
            counts.trash = raw.trash
            counts.duplicate = raw.duplicate
            counts.recentlySaved = raw.recentlySaved
            counts.imports = raw.imports
            counts.portrait = raw.portrait
            counts.screenshots = raw.screenshots
            counts.totalBytes = raw.totalBytes
            counts.earliest = raw.earliest
            counts.latest = raw.latest
            systemCountsCache = counts
            systemCountsCacheRevision = contentRevision
            return counts
        }
        var counts = SystemSidebarCounts()
        let cutoff = Self.recentlySavedCutoff
        for photo in systemPhotos {
            guard photo.deletedAt == nil else {
                counts.trash += 1
                continue
            }
            counts.totalBytes += photo.fileSize
            counts.earliest = min(counts.earliest ?? photo.capturedAt, photo.capturedAt)
            counts.latest = max(counts.latest ?? photo.capturedAt, photo.capturedAt)
            if photo.isHidden {
                counts.hidden += 1
                continue
            }
            counts.active += 1
            if photo.isDuplicateItem { counts.duplicate += 1 }
            if photo.addedAt >= cutoff { counts.recentlySaved += 1 }
            if photo.isDeviceImport { counts.imports += 1 }
            if photo.isPortraitCapture { counts.portrait += 1 }
            if photo.kind == .screenshot { counts.screenshots += 1 }
        }
        systemCountsCache = counts
        systemCountsCacheRevision = contentRevision
        return counts
    }

    // MARK: - 系统图库重复项目

    /// 系统图库的重复组（由后台算好）。打开重复页时先调用
    /// `loadSystemDuplicateGroupsIfNeeded()`，计算结果到达前返回上一次的缓存。
    var systemDuplicateGroups: [DuplicateGroup] { systemDuplicateGroupsCache }

    /// 缓存失效：清空版本号并通知界面在后台重算。
    func invalidateSystemDuplicateGroups() {
        systemDuplicateGroupsCacheKey = nil
        systemDuplicateGroupsToken &+= 1
    }

    /// 后台计算系统图库重复分组：三万多条重复标记的查询、解码与归组都不占用主线程，
    /// 界面先显示进度，完成后一次性刷新。结果按内容版本缓存，重复打开直接复用。
    func loadSystemDuplicateGroupsIfNeeded() {
        guard systemDuplicateGroupsTask == nil else { return }
        let key = "\(contentRevision)"
        if systemDuplicateGroupsCacheKey == key { return }
        guard let index = systemIndex else {
            // 小库只有内存快照，直接在调用线程算完。
            let source = systemPhotos.map { applySystemOverlay($0) }
            systemDuplicateGroupsCache = DuplicateDetector.groups(from: source, mergeFlagged: true)
            systemDuplicateGroupsCacheKey = key
            return
        }
        let revision = contentRevision
        let overlays = isNativeContainer ? systemOverlays : [:]
        isLoadingSystemDuplicates = true
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(systemLibraryPath ?? LibraryPaths.root.standardizedFileURL.path),
                      kind: .index,
                      title: "计算重复分组",
                      isCancellable: false)
        )
        systemDuplicateGroupsTask = Task.detached(priority: .userInitiated) { [weak self, index, overlays, key] in
            let photos = index.duplicatePhotos().map { photo in
                Self.applyAssetOverlay(overlays[photo.id], to: photo)
            }
            let groups = DuplicateDetector.groups(from: photos, mergeFlagged: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.systemDuplicateGroupsTask = nil
                self.isLoadingSystemDuplicates = false
                self.finishSourceJob(jobID, message: "重复分组已更新")
                guard self.contentRevision == revision else {
                    // 计算期间图库内容变了：丢弃结果，按最新内容重算。
                    self.loadSystemDuplicateGroupsIfNeeded()
                    return
                }
                self.systemDuplicateGroupsCacheKey = key
                self.systemDuplicateGroupsCache = groups
            }
        }
    }

    /// 官方图库只读：拾光的「合并」是隐藏其余副本（写补充元数据，可撤销），不删除 Apple 的照片。
    @discardableResult
    func hideSystemDuplicateCopies(_ group: DuplicateGroup, keeping keepID: UUID) -> Int {
        guard canEditNativeOverlay else { return 0 }
        let ids = Set(group.photos.map(\.id)).subtracting([keepID])
        guard !ids.isEmpty else { return 0 }
        setSystemHidden(true, ids: ids)
        invalidateSystemDuplicateGroups()
        showToast("已隐藏 \(ids.count) 个副本，可在「已隐藏」中恢复")
        return ids.count
    }

    /// 隐藏全部重复组里的多余副本，每组保留推荐版本。
    @discardableResult
    func hideAllSystemDuplicateCopies() -> (groups: Int, hidden: Int) {
        guard canEditNativeOverlay else { return (0, 0) }
        var groupCount = 0
        var hidden = 0
        for group in systemDuplicateGroups {
            let ids = Set(group.photos.map(\.id)).subtracting([group.keepID])
            guard !ids.isEmpty else { continue }
            setSystemHidden(true, ids: ids)
            groupCount += 1
            hidden += ids.count
        }
        guard hidden > 0 else { return (0, 0) }
        invalidateSystemDuplicateGroups()
        showToast("已隐藏 \(groupCount) 组重复项目中的 \(hidden) 个副本")
        return (groupCount, hidden)
    }

    /// 把重复组的保留版本拷贝一份到拾光，官方图库本身保持只读。
    func importSystemDuplicateKeep(_ group: DuplicateGroup) {
        importSystemPhotos([group.pick.photo], albumName: "重复项目")
    }

    /// 把单张系统图库照片拷贝到拾光（只读来源的导出出口）。
    func importSystemPhotoToLibrary(_ photo: PhotoItem) {
        guard photo.isSystem else { return }
        importSystemPhotos([photo], albumName: nil)
    }

    /// 原始顺序缺失（旧缓存或异常数据）时退回主键，保证排序稳定。
    private static func systemSortKey(_ folder: SystemFolderInfo) -> Int64 {
        folder.sortIndex != 0 ? folder.sortIndex : folder.id
    }

    private static func systemSortKey(_ album: SystemAlbumInfo) -> Int64 {
        album.sortIndex != 0 ? album.sortIndex : album.id
    }

    func systemPhoto(id: UUID) -> PhotoItem? {
        if let item = systemPhotoIndex[id] { return item }
        // 窗口里刚出现过的照片走内存，避免 body 求值时同步查 Photos.sqlite。
        if let recent = systemRecentPhotos[id] { return recent }
        guard let index = systemIndex else { return nil }
        return index.photo(id: id).map { applySystemOverlay($0) }
    }

    /// 把已加载窗口里的照片记进内存（有上限），供 body 里的高频读取使用。
    func rememberSystemPhotos(_ photos: [PhotoItem]) {
        guard !photos.isEmpty else { return }
        if systemRecentPhotos.count + photos.count > 4_000 {
            systemRecentPhotos.removeAll(keepingCapacity: true)
        }
        for item in photos { systemRecentPhotos[item.id] = item }
    }

    func anyPhoto(id: UUID) -> PhotoItem? {
        photos.first(where: { $0.id == id })
            ?? systemPhoto(id: id)
            ?? cloudPhotos.first(where: { $0.id == id })
    }

    /// 该 ID 是否属于当前系统图库（可能只在索引里，尚未加载进内存窗口）。
    func isSystemPhotoID(_ id: UUID) -> Bool {
        if systemPhotoIndex[id] != nil { return true }
        if systemOverlays[id] != nil { return true }
        return systemIndex?.photo(id: id) != nil
    }

    func presentSystemLibraryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "连接"
        panel.message = "拾光一次只连接一个系统图库，选择新的会替换当前连接；只记录连接地址，不会改变 App 自己的图库位置"
        if panel.runModal() == .OK, let url = panel.url {
            connectSystemLibrary(url)
        }
    }

    /// 选择要打开 / 切换的 App 图库（会真正切换本地库位置）。
    func presentLibraryContainerPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择要打开或切换的 .photoslibrary 图库"
        if panel.runModal() == .OK, let url = panel.url {
            activateLibrary(url)
        }
    }

    func createLibrary(at url: URL, migratingLocalData: Bool = false) {
        guard LibraryPaths.createLibrary(at: url) else {
            showToast("无法创建照片图库（目标位置已存在同名项目）")
            return
        }
        flushMetadata()
        metadataStore = nil
        guard LibraryPaths.switchContainer(to: url, migratingLocalData: migratingLocalData) else {
            showToast("无法创建照片图库")
            return
        }
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        libraryIndexComplete = true
        metadataStore = try? MetadataStore(url: LibraryPaths.metadataFile)
        resetFaceClusterState()
        let data = metadataStore?.loadLibrary() ?? LibraryData()
        photos = data.photos
        albums = data.albums
        folders = data.folders
        loadSmartAlbums()
        loadPinnedItems()
        loadAnalysisIndex()
        similarScope = nil
        abortHealthScan()
        healthReport = nil
        selection.removeAll()
        viewerID = nil
        editorID = nil
        // 新图库从零开始：网络资源也读这个新库自己的配置（通常是空的）。
        finishCatalogPlayback()
        catalogModel.loadForCurrentLibrary()
        // 新图库是全新的：上一个图库的连接、网盘与库级设置都不能带进来。
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        reloadPerLibraryState()
        navigate(to: .library)
        rememberLibrary(url)
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        needsLibrarySetup = false
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        showToast("已创建 \(url.lastPathComponent)")
    }

    func resetSystemLibraryState() {
        systemLibraryPath = nil
        systemLibraryName = nil
        systemPhotos = []
        systemAlbums = []
        systemFolders = []
        systemPeople = []
        systemPhotoIndex = [:]
        systemAlbumIndex = [:]
        systemOverlays = [:]
        systemTotalAssetCount = 0
        systemLibraryError = nil
        systemLibraryLoadedPath = nil
        systemIndex = nil
        systemIndexSignature = ""
        systemNativeKeywordIndex = nil
        systemNativeKeywordIDMap = [:]
        photoKitLongExposureIDs = nil
        photoKitCinematicIDs = nil
        isPhotoKitMediaTypeLoaded = false
        systemIndexReady = false
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        systemGeoCacheKey = nil
        systemGeoCache = []
        viewerStripKey = nil
        viewerStrip = []
        // 识别结果只属于当前系统图库，断开或换库时一并清空并取消进行中的识别。
        systemAnalysisTask?.cancel()
        systemAnalysisTask = nil
        systemAnalysisCancelled = false
        systemAnalysisAutoResume = false
        systemAnalysisIndex = [:]
        isAnalyzingSystemContent = false
        systemAnalysisDone = 0
        systemAnalysisTotal = 0
        systemFeatures = [:]
        healthReport = nil
        healthReportScopeTag = nil
        similarScope = nil
        clearSystemWindow()
    }

    /// 清空系统图库的分页窗口（换库、重建索引、切换系统图库时调用）。
    func clearSystemWindow() {
        systemWindowTask?.cancel()
        systemWindowTask = nil
        systemWindowPhotos = []
        systemRecentPhotos.removeAll(keepingCapacity: false)
        systemWindowTotal = 0
        systemWindowVideos = 0
        systemWindowKey = ""
        systemWindowStart = 0
        systemWindowQuery = nil
        hasLoadedSystemWindow = false
        isSystemWindowLoading = false
        systemWindowRevision &+= 1
    }

    func presentNewLibraryPanel(migratingLocalData: Bool = false) {
        let panel = NSSavePanel()
        panel.title = "新建照片图库"
        panel.message = "将创建一个与官方同款的 .photoslibrary 图库包（database / originals / resources）"
        panel.prompt = "创建"
        panel.nameFieldStringValue = "未命名.photoslibrary"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let url = selected.pathExtension.lowercased() == "photoslibrary"
            ? selected
            : selected.appendingPathExtension("photoslibrary")
        createLibrary(at: url, migratingLocalData: migratingLocalData)
    }

    /// 切换 App 自己的图库位置（会迁移/打开本地库）。
    func switchLibraryContainer(_ url: URL) {
        guard LibraryPaths.isLibraryContainer(url) else {
            showToast("请选择有效的 .photoslibrary 图库")
            return
        }

        let sameContainer = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
            == url.standardizedFileURL.path
        if !sameContainer {
            flushMetadata()
            metadataStore = nil
            // 打开哪个图库就以哪个图库为准：不把当前图库的内容迁进去，
            // 新库第一次打开时就是它自己的内容（原生库的拾光数据同样写在该库第一层 database/）。
            guard LibraryPaths.switchContainer(to: url, migratingLocalData: false) else {
                showToast("无法切换照片图库")
                return
            }
            libraryIndexTask?.cancel()
            libraryIndexTask = nil
            libraryIndexComplete = true
            metadataStore = try? MetadataStore(url: LibraryPaths.metadataFile)
            resetFaceClusterState()
            let data = metadataStore?.loadLibrary() ?? LibraryData()
            photos = data.photos
            albums = data.albums
            folders = data.folders
            loadSmartAlbums()
            loadPinnedItems()
            loadAnalysisIndex()
            similarScope = nil
            abortHealthScan()
            healthReport = nil
            selection.removeAll()
            viewerID = nil
            editorID = nil
            // 网络资源跟着图库走：换库后重新读取新图库自己的源、片单与日历。
            finishCatalogPlayback()
            catalogModel.loadForCurrentLibrary()
            let name = url.deletingPathExtension().lastPathComponent
            showToast("已打开 \(name)")
        }

        needsLibrarySetup = LibraryPaths.requiresLibrarySetup
        rememberLibrary(url)
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path

        guard LibraryPaths.isNativeLibrary(url) else {
            // 打开哪个图库就用哪个图库自己的连接、网盘与设置。
            if !sameContainer {
                resetCloudStateForLibrarySwitch()
                resetSystemLibraryState()
            }
            // 「系统图库」这一分区跟着图库走：恢复该图库自己记住的连接（可能没有）。
            systemLibraryPath = metadataStore?.setting("system_library_path")
            if let path = systemLibraryPath {
                systemLibraryName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            }
            reloadPerLibraryState()
            navigate(to: .library)
            return
        }

        // 当前图库就是官方「照片」图库：它直接作为主侧边栏展示，不再登记成「连接的系统图库」。
        if !sameContainer {
            resetCloudStateForLibrarySwitch()
            resetSystemLibraryState()
        }
        systemLibraryPath = url.path
        systemLibraryName = url.deletingPathExtension().lastPathComponent
        systemLibraryError = nil
        metadataStore?.setSetting("system_library_path", url.path)
        reloadPerLibraryState()
        // 先启动加载再切换侧边栏，避免 sidebarItem 变更时重复触发一次扫描。
        loadSystemLibrary(at: url, informOnFailure: true)
        navigate(to: .systemLibrary)
    }

    /// 只记录 / 连接系统「照片」图库，绝不改变 App 自己的图库位置。
    func connectSystemLibrary(_ url: URL) {
        guard LibraryPaths.isLibraryContainer(url) else {
            showToast("请选择有效的 .photoslibrary 图库")
            return
        }
        guard LibraryPaths.isNativeLibrary(url) else {
            showToast("这不是系统「照片」图库；如需切换 App 图库，请使用「切换图库…」")
            return
        }

        // 已经在浏览同一个系统图库：只切回该页面，不重复扫描，避免来回切换。
        if systemLibraryPath == url.path,
           systemLibraryLoadedPath == url.path,
           !isLoadingSystemLibrary {
            showLibraryPicker = false
            libraryPickerOnLaunch = false
            if !isSystemScope { navigate(to: .systemLibrary) }
            return
        }

        systemLibraryPath = url.path
        systemLibraryName = url.deletingPathExtension().lastPathComponent
        systemLibraryError = nil
        metadataStore?.setSetting("system_library_path", url.path)
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        registerSystemLibrary(url)
        loadSystemLibrary(at: url, informOnFailure: true)
        navigate(to: .systemLibrary)
    }

    func openContainerInPhotos() {
        guard LibraryPaths.containerLibraryURL != nil else {
            showToast("请先连接一个照片图库")
            return
        }
        LibraryPaths.openContainerInPhotos()
    }

    var containerLibraryName: String? {
        LibraryPaths.containerLibraryURL?.lastPathComponent
    }

    var storageLocationDescription: String? {
        guard LibraryPaths.containerLibraryURL != nil else { return nil }
        return LibraryPaths.root.path
    }

    var hasContainerLibrary: Bool {
        LibraryPaths.containerLibraryURL != nil
    }

    /// 切换 / 新建图库后，把「只属于当前图库」的数据与设置整体换一遍：
    /// 图库级设置、视图状态、系统图库连接、网盘挂载与收藏、最近删除清理。
    func reloadPerLibraryState() {
        // 换库时停止上一个图库的缩略图预热，避免把缓存写进新库。
        thumbnailPrewarmTask?.cancel()
        thumbnailPrewarmTask = nil
        AppSettings.shared.reloadLibraryScopedValues()
        loadViewPreferences()
        loadCloudFavorites()
        loadCloudKeywords()
        loadCloudMarks()
        loadCloudMounts()
        cinemaIndexes = [:]
        loadCinemaIndexes()
        migrateLegacyCinemaIndexIfNeeded()
        loadAIState()
        loadSystemLibraries()
        purgeExpiredTrashIfNeeded()
        // 美化推荐是派生结果，换库后必须清空，避免把上一个图库的照片带过来。
        resetBeautyState()
        // 体检结果与系统图库识别缓存同样只属于上一个图库 / 连接。
        healthTask?.cancel()
        healthTask = nil
        healthReport = nil
        healthReportScopeTag = nil
        isScanningHealth = false
        healthScanProgress = 0
        systemAnalysisIndex = [:]
        systemAnalysisAutoResume = false
        systemFeatures = [:]
        // 地图页的定位照片 / 地点聚类同样只属于上一个图库。
        resetPlaceCaches()
        // 撤销栈只对记录它的图库有效，换库时一并清空。
        resetUndoHistory()
        // 查重哈希与相似组只属于上一个图库。
        resetHashState()
        vaultProgress = nil
        vaultReport = nil
        vaultBackupPath = nil
        vaultLastBackupDate = nil
        // 删除确认卡片里的 ID 属于上一个图库，换库时必须丢弃。
        resetConfirmationState()
    }

    // MARK: - 图库选择器

    static let recentLibrariesKey = "settings.recentLibraries"

    func presentLibraryPicker() {
        showLibraryPicker = true
    }

    /// 记录用过的图库，供选择器列表使用。
    func rememberLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > 10 { paths.removeLast(paths.count - 10) }
        UserDefaults.standard.set(paths, forKey: Self.recentLibrariesKey)
    }

    // MARK: - 系统图库列表

    /// 旧版把连接列表存在全局 UserDefaults，仅用于一次性迁入当前图库。
    private static let legacySystemLibrariesKey = "settings.systemLibraries"
    /// 每个图库自己的系统图库连接列表（写在该图库的 SQLite settings 表）。
    private static let systemLibrariesSettingKey = "system_libraries"

    /// 读取**当前图库**自己的系统图库连接列表；同一时间只有一个处于连接/展开状态。
    func loadSystemLibraries() {
        var list: [SystemLibraryRef] = []
        if let json = metadataStore?.setting(Self.systemLibrariesSettingKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SystemLibraryRef].self, from: data) {
            list = decoded
        } else if metadataStore != nil,
                  let data = UserDefaults.standard.data(forKey: Self.legacySystemLibrariesKey),
                  let decoded = try? JSONDecoder().decode([SystemLibraryRef].self, from: data) {
            // 旧版的全局列表只迁入当前图库一次，之后每个图库各管各的。
            list = decoded
            UserDefaults.standard.removeObject(forKey: Self.legacySystemLibrariesKey)
        }
        // 列表可保存多个图库，去重后最多保留 10 个。
        var seen: Set<String> = []
        list = list.filter { seen.insert($0.path).inserted }
        if list.count > 10 { list.removeLast(list.count - 10) }
        // 当前图库本身是官方「照片」图库时，它的内容是主侧边栏，不登记成额外连接。
        let currentContainer = LibraryPaths.containerLibraryURL
        let nativeSelfPath = currentContainer.flatMap {
            LibraryPaths.isNativeLibrary($0) ? $0.standardizedFileURL.path : nil
        }
        if let nativeSelfPath {
            list.removeAll { $0.path == nativeSelfPath }
        }
        if let path = systemLibraryPath,
           path != nativeSelfPath,
           !list.contains(where: { $0.path == path }) {
            list.insert(SystemLibraryRef(path: path,
                                         name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                        at: 0)
        }
        systemLibraries = list
        persistSystemLibraries(list)
    }

    func persistSystemLibraries(_ list: [SystemLibraryRef]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.systemLibrariesSettingKey, json)
    }

    /// 登记系统图库：列表可保存多个，连接新图库时追加或更新，切换只改变当前连接。
    func registerSystemLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        let name = url.deletingPathExtension().lastPathComponent
        var list = systemLibraries
        if let index = list.firstIndex(where: { $0.path == path }) {
            list[index] = SystemLibraryRef(path: path, name: name)
        } else {
            list.insert(SystemLibraryRef(path: path, name: name), at: 0)
        }
        if list.count > 10 { list.removeLast(list.count - 10) }
        systemLibraries = list
        persistSystemLibraries(list)
    }

    /// 断开某个系统图库；若断开的正是当前库，则退回「图库」。
    func removeSystemLibrary(_ path: String) {
        if systemLibraryPath == path {
            if isSystemScope {
                navigate(to: .library)
            }
            resetSystemLibraryState()
            metadataStore?.setSetting("system_library_path", nil)
        }
        var list = systemLibraries
        list.removeAll { $0.path == path }
        systemLibraries = list
        persistSystemLibraries(list)
    }

    /// 点击侧边栏里的系统图库：已加载过就只切回页面，不重复扫描。
    func activateSystemLibrary(_ ref: SystemLibraryRef) {
        guard FileManager.default.fileExists(atPath: ref.path) else {
            showToast("找不到「\(ref.name)」，可能已被移动或删除")
            removeSystemLibrary(ref.path)
            return
        }
        if systemLibraryPath == ref.path,
           systemLibraryLoadedPath == ref.path,
           !isLoadingSystemLibrary {
            if !isSystemScope { navigate(to: .systemLibrary) }
            return
        }
        connectSystemLibrary(URL(fileURLWithPath: ref.path))
    }

    /// 在系统「照片」中打开指定的系统图库。
    func openSystemLibraryInPhotos(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 选择器里列出的图库：当前图库、最近打开过的、以及「图片」文件夹里的 .photoslibrary。
    func knownLibraryEntries() -> [LibraryEntry] {
        var urls: [URL] = []
        if let current = LibraryPaths.containerLibraryURL {
            urls.append(current)
        }
        for path in UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? [] {
            urls.append(URL(fileURLWithPath: path))
        }
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first,
           let items = try? FileManager.default.contentsOfDirectory(at: pictures,
                                                                   includingPropertiesForKeys: nil) {
            urls.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "photoslibrary" })
        }

        var seen = Set<String>()
        var entries: [LibraryEntry] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            entries.append(LibraryEntry(id: path,
                                        url: url,
                                        name: url.deletingPathExtension().lastPathComponent,
                                        modifiedAt: modified,
                                        isNative: LibraryPaths.isNativeLibrary(url),
                                        isCurrent: LibraryPaths.containerLibraryURL?.standardizedFileURL.path == path))
        }

        entries.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        }
        return entries
    }

    /// 打开任意 .photoslibrary（含官方「照片」图库）：都以这个图库为准切换，
    /// 展示它自己的内容，之后的导入、编辑与设置都写入它自己的数据库。
    func activateLibrary(_ url: URL) {
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        switchLibraryContainer(url)
    }

    // MARK: - 官方图库照片的补充元数据

    /// 当前是否允许给官方「照片」图库的照片写拾光的补充元数据。
    var canEditNativeOverlay: Bool { isNativeContainer }

    private func updateSystemPhoto(_ id: UUID, mutate: (inout PhotoItem) -> Void) {
        systemRecentPhotos[id] = nil
        if let index = systemPhotos.firstIndex(where: { $0.id == id }) {
            mutate(&systemPhotos[index])
            systemPhotoIndex[id] = systemPhotos[index]
            return
        }
        // 索引模式：同步更新已加载窗口 / 胶片条，避免整页刷新。
        if let position = systemWindowPhotos.firstIndex(where: { $0.id == id }) {
            mutate(&systemWindowPhotos[position])
            systemPhotoIndex[id] = systemWindowPhotos[position]
        }
        if let position = viewerStrip.firstIndex(where: { $0.id == id }) {
            mutate(&viewerStrip[position])
        }
        if var item = systemPhotoIndex[id] ?? systemPhoto(id: id) {
            mutate(&item)
            systemPhotoIndex[id] = item
        }
        systemWindowRevision &+= 1
        // 收藏 / 隐藏覆盖会改变索引查询与侧边栏计数，必须让缓存失效。
        contentRevision &+= 1
    }

    private func saveSystemOverlay(_ id: UUID, mutate: (inout MetadataStore.AssetOverlay) -> Void) {
        guard let store = metadataStore else { return }
        // 覆盖元数据变了：窗口缓存里的旧对象要作废，下次读取才会带上新的收藏 / 隐藏状态。
        systemRecentPhotos[id] = nil
        var overlay = systemOverlays[id] ?? MetadataStore.AssetOverlay()
        mutate(&overlay)
        systemOverlays[id] = overlay
        // 收藏 / 隐藏 / 关键词都会参与索引查询条件，缓存必须失效。
        systemQueryCacheSignature = nil
        systemFavoritesRevision &+= 1
        store.saveOverlay(id, overlay)
    }

    /// 收藏 / 取消收藏官方图库里的照片。
    /// 官方库作为当前图库时经 PhotoKit 写回「照片」；否则只写拾光数据库（`Photos.sqlite` 保持只读）。
    func setSystemFavorite(_ favorite: Bool, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        let writeBack = canWriteSystemLibrary
        for id in ids {
            updateSystemPhoto(id) { $0.isFavorite = favorite }
            if !writeBack {
                saveSystemOverlay(id) { $0.isFavorite = favorite }
            }
        }
        guard writeBack else { return }
        Task {
            guard await prepareSystemLibraryWrite() else {
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = favorite } }
                return
            }
            do {
                try await PhotoKitBridge.setFavorite(favorite, assetIDs: Array(ids))
                // 写回成功后清掉拾光覆盖值，以「照片」为准。
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = nil } }
            } catch {
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = favorite } }
                self.showToast("写回「照片」失败，已只记录在拾光：\(error.localizedDescription)")
            }
        }
    }

    /// 隐藏 / 取消隐藏：官方库作为当前图库时经 PhotoKit 写回「照片」。
    func setSystemHidden(_ hidden: Bool, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        // 隐藏会改变重复组的成员，让重复页在后台重新分组。
        invalidateSystemDuplicateGroups()
        let writeBack = canWriteSystemLibrary
        for id in ids {
            updateSystemPhoto(id) { $0.isHidden = hidden }
            if !writeBack {
                saveSystemOverlay(id) { $0.isHidden = hidden }
            }
        }
        guard writeBack else { return }
        Task {
            guard await prepareSystemLibraryWrite() else {
                for id in ids { self.saveSystemOverlay(id) { $0.isHidden = hidden } }
                return
            }
            do {
                try await PhotoKitBridge.setHidden(hidden, assetIDs: Array(ids))
                for id in ids { self.saveSystemOverlay(id) { $0.isHidden = nil } }
            } catch {
                for id in ids { self.saveSystemOverlay(id) { $0.isHidden = hidden } }
                self.showToast("写回「照片」失败，已只记录在拾光：\(error.localizedDescription)")
            }
        }
    }

    func setSystemKeywords(_ keywords: [String], ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        let value = keywords.isEmpty ? nil : keywords
        for id in ids {
            updateSystemPhoto(id) { $0.keywords = value }
            saveSystemOverlay(id) { $0.keywords = value }
        }
    }

    /// 系统图库的评分 / 旗标 / 色标只写拾光叠加数据，不修改 `Photos.sqlite`。
    func setSystemRating(_ rating: Int, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        let value = min(5, max(0, rating))
        for id in ids {
            updateSystemPhoto(id) { $0.rating = value }
            saveSystemOverlay(id) { $0.rating = value }
        }
    }

    func setSystemFlag(_ flag: PhotoFlag, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        for id in ids {
            updateSystemPhoto(id) { $0.flag = flag }
            saveSystemOverlay(id) { $0.flag = flag }
        }
    }

    func setSystemColorLabel(_ label: PhotoColorLabel, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        for id in ids {
            updateSystemPhoto(id) { $0.colorLabel = label }
            saveSystemOverlay(id) { $0.colorLabel = label }
        }
    }

    /// 记录查看：官方图库照片的查看时间同样只写拾光数据库。
    func recordSystemView(_ id: UUID) {
        guard canEditNativeOverlay, let item = systemPhoto(id: id) else { return }
        let now = Date()
        if let last = item.viewedAt, now.timeIntervalSince(last) < 3600 { return }
        // 「看过」只影响「值得重看」，不参与查询条件，也不显示在网格上。
        // 不能走 updateSystemPhoto / saveSystemOverlay：它们会推进 contentRevision、
        // 清空查询缓存并重建收藏汇总，大图库（几万张）开图那一刻整个窗口都要重算。
        if var cached = systemPhotoIndex[id] {
            cached.viewedAt = now
            systemPhotoIndex[id] = cached
        }
        guard let store = metadataStore else { return }
        var overlay = systemOverlays[id] ?? MetadataStore.AssetOverlay()
        overlay.viewedAt = now
        systemOverlays[id] = overlay
        store.saveOverlay(id, overlay)
    }

    /// 首次进入系统图库相关页面时才扫描 Photos.sqlite，避免启动即加载。
    func loadSystemLibraryIfNeeded(_ item: SidebarItem) {
        guard item.isSystemScope,
              systemPhotos.isEmpty,
              systemIndex == nil,
              systemLibraryError == nil,
              !isLoadingSystemLibrary,
              let path = systemLibraryPath else { return }
        let url = URL(fileURLWithPath: path)
        // 官方「照片」图库首次打开：先弹系统的照片访问授权，用户选择后再开始读取，
        // 避免扫描进行到一半才被授权框打断。
        if isNativeContainer, PhotoKitBridge.isAuthorizationUndetermined {
            isLoadingSystemLibrary = true
            systemScanCount = 0
            systemLibraryError = nil
            Task { [weak self] in
                _ = await PhotoKitBridge.ensureAuthorized()
                guard let self else { return }
                self.isLoadingSystemLibrary = false
                self.loadSystemLibrary(at: url, informOnFailure: true)
            }
            return
        }
        loadSystemLibrary(at: url, informOnFailure: true)
    }

    func loadSystemLibrary(at url: URL, informOnFailure: Bool = true, forceRefresh: Bool = false) {
        // 打开系统图库默认展示「所有照片」全量网格，并按图库原始顺序（拍摄日期从新到旧）排列。
        if grouping != .all { grouping = .all }
        if sortKey != .capturedAt || sortAscending {
            sortKey = .capturedAt
            sortAscending = false
        }
        // 当前图库就是官方图库时，先从它自己的 PhotosClone.sqlite 读回拾光的补充元数据。
        if isNativeContainer {
            systemOverlays = metadataStore?.loadOverlays() ?? [:]
        }
        isLoadingSystemLibrary = true
        systemScanCount = 0
        systemLibraryError = nil
        systemLibraryLoadedPath = nil
        // 先清空，随后用索引、缓存或按批次增量展示。
        systemPhotos = []
        systemPhotoIndex = [:]
        systemAlbums = []
        systemFolders = []
        systemAlbumIndex = [:]
        systemAlbumCoverCache.removeAll()
        systemAlbumCoverMisses.removeAll()
        systemAlbumCoverLoading.removeAll()
        // PhotoKit 缩略图缓存只对当前图库有效：换库后资产标识与预取队列都要清空。
        PhotoKitThumbnailProvider.shared.reset()
        systemPeople = []
        systemTotalAssetCount = 0
        systemIndex = nil
        systemIndexSignature = ""
        // 关键词属于这个图库，换库 / 重扫时一并重新读取。
        systemNativeKeywordIndex = nil
        systemNativeKeywordIDMap = [:]
        systemIndexReady = false
        clearSystemWindow()
        selection.removeAll()
        viewerID = nil

        // 每次载入递增令牌：重扫时旧的扫描结果与缓存写入都要作废。
        systemLoadToken &+= 1
        let token = systemLoadToken
        // 十万级图库的索引构建可能要跑一阵：登记为后台任务，切走页面也能看到进度。
        let loadJobID = beginSourceJob(
            SourceJob(sourceID: .library(url.path), kind: .index, title: "载入系统图库", isCancellable: false)
        )

        if forceRefresh, let file = LibraryPaths.systemIndexFile(for: url) {
            try? FileManager.default.removeItem(at: file)
        }

        Task {
            defer {
                if token == systemLoadToken {
                    finishSourceJob(loadJobID, message: "系统图库已载入")
                } else {
                    cancelSourceJob(loadJobID)
                }
            }
            // 0. 相簿 / 文件夹 / 人物都只是元数据：先从 Photos.sqlite 读出并展示，
            //    不必等照片扫描 / 索引构建完成（十万项图库这一步只读几张元数据表）。
            let albumsTask = Task.detached(priority: .userInitiated) {
                SystemIndex.albumMetadata(libraryURL: url)
            }
            let peopleTask = Task.detached(priority: .userInitiated) {
                SystemIndex.peopleMetadata(libraryURL: url)
            }
            // 官方图库自带的关键词同样只是一张小表，和相簿 / 人物一起先读出来。
            let keywordTask = Task.detached(priority: .userInitiated) {
                SystemIndex.nativeKeywordMap(libraryURL: url)
            }
            let early = await albumsTask.value
            let earlyPeople = await peopleTask.value
            guard token == systemLoadToken else { return }
            if !early.albums.isEmpty || !early.folders.isEmpty {
                systemAlbums = early.albums
                systemFolders = early.folders
                systemAlbumIndex = Dictionary(uniqueKeysWithValues: early.albums.map { ($0.id, $0) })
                systemStructureRevision &+= 1
            }
            if !earlyPeople.isEmpty { systemPeople = earlyPeople }
            let earlyKeywords = await keywordTask.value
            guard token == systemLoadToken else { return }
            systemNativeKeywordIndex = earlyKeywords.byKeyword
            systemNativeKeywordIDMap = earlyKeywords.byAsset

            // 0. 直连模式：不复制整库，直接对 Photos.sqlite 分页查询。
            let directIndex = await Task.detached(priority: .userInitiated) {
                SystemIndex.openDirect(libraryURL: url)
            }.value
            guard token == systemLoadToken else { return }
            if let directIndex {
                directIndex.onDirectCountsReady = { [weak self] in
                    guard let self else { return }
                    self.systemCountsCache = nil
                    self.systemCountsCacheRevision = -1
                    self.mediaTypeSummaryCacheKey = nil
                    // 后台补好的地图 / 位置数据需要让 geoPhotos 重新取一次。
                    self.systemGeoCacheKey = nil
                    self.contentRevision &+= 1
                    // contentRevision 不是 @Published：手动通知一次，地图 / 地点页才会用上新数据。
                    self.objectWillChange.send()
                }
                await applySystemIndex(directIndex, at: url)
                isLoadingSystemLibrary = false
                systemScanCount = 0
                return
            }

            // 1. 已有匹配的索引：直接按窗口浏览，无需扫描整库。
            let opened = await Task.detached(priority: .userInitiated) {
                SystemIndex.openIfFresh(libraryURL: url)
            }.value
            guard token == systemLoadToken else { return }
            if let opened {
                await applySystemIndex(opened, at: url)
                isLoadingSystemLibrary = false
                systemScanCount = 0
                resumeSystemAnalysisIfNeeded()
                return
            }

            // 2. 大图库或已有旧索引：从 Photos.sqlite 重建索引（毫秒级分页，常驻内存只有一个窗口）。
            let total = await Task.detached(priority: .userInitiated) {
                SystemIndex.assetCount(libraryURL: url) ?? 0
            }.value
            guard token == systemLoadToken else { return }
            let indexExists = LibraryPaths.systemIndexFile(for: url)
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if total > SystemIndex.largeLibraryThreshold || indexExists {
                // 建索引期间同样逐批显示：百万级图库不必等索引写完才出图，
                // 索引就绪后再切换成 SQL 窗口浏览（内存只保留一个窗口）。
                let (stream, continuation) = Self.makeSystemBatchStream()
                let buildTask = Task.detached(priority: .userInitiated) { () -> Result<SystemIndex, Error> in
                    defer { continuation.finish() }
                    do {
                        let index = try SystemIndex.prepare(
                            libraryURL: url,
                            progress: { count in
                                Task { @MainActor [weak self] in
                                    guard let self, self.systemLoadToken == token else { return }
                                    self.systemScanCount = count
                                    self.updateSourceJob(loadJobID,
                                                         message: "已载入 \(count.formatted()) 项")
                                }
                            },
                            onBatch: { batch in continuation.yield(batch) })
                        return .success(index)
                    } catch {
                        return .failure(error)
                    }
                }
                await drainSystemBatches(stream, token: token, displayLimit: Self.systemStreamDisplayLimit)
                let result = await buildTask.value
                guard token == systemLoadToken else { return }
                if case .success(let index) = result {
                    await applySystemIndex(index, at: url)
                    isLoadingSystemLibrary = false
                    systemScanCount = 0
                    resumeSystemAnalysisIfNeeded()
                    return
                }
                // 索引不可用（磁盘不可写 / 图库正在写入）：回退到内存快照，功能不缺失。
                // 先清掉建索引期间先显示的半份数据，避免下面重新扫描时重复追加。
                systemPhotos = []
                systemPhotoIndex = [:]
            }

            // 3. 小图库或索引不可用：沿用内存快照与扫描缓存。
            // 先读扫描缓存：命中就立刻出图，只有图库确有变化时才在后台重扫。
            let cached = await Task.detached(priority: .userInitiated) {
                SystemLibraryCache.load(for: url)
            }.value

            guard token == systemLoadToken else { return }

            if let cached {
                applySystemSnapshot(cached.snapshot, at: url)
                if cached.isFresh, !forceRefresh {
                    isLoadingSystemLibrary = false
                    systemScanCount = 0
                    resumeSystemAnalysisIfNeeded()
                    return
                }
            }

            // 没有缓存时边扫边显示；有缓存时保持现有内容，扫描结束后整体替换。
            let streamBatches = cached == nil
            var continuation: AsyncStream<[PhotoItem]>.Continuation?
            var stream: AsyncStream<[PhotoItem]>?
            if streamBatches {
                let pair = Self.makeSystemBatchStream()
                stream = pair.0
                continuation = pair.1
            }

            // 扫描与索引构建放在后台。
            let batchContinuation = continuation
            let scanTask = Task.detached(priority: .userInitiated) { [weak self] () -> Result<SystemLoadPayload, Error> in
                defer { batchContinuation?.finish() }
                do {
                    let snapshot = try SystemPhotosLibrary.scan(
                        libraryURL: url,
                        progress: { count in
                            Task { @MainActor in
                                guard let self, self.systemLoadToken == token else { return }
                                self.systemScanCount = count
                                self.updateSourceJob(loadJobID,
                                                     message: "已载入 \(count.formatted()) 项")
                            }
                        },
                        onBatch: streamBatches ? { batch in batchContinuation?.yield(batch) } : nil
                    )
                    return .success(SystemLoadPayload(snapshot: snapshot))
                } catch {
                    return .failure(error)
                }
            }

            // 边扫描边显示：每批到达就追加，用户可以立刻开始浏览。
            if let stream {
                await drainSystemBatches(stream, token: token)
            }

            let result = await scanTask.value
            guard token == systemLoadToken else { return }
            switch result {
            case .success(let payload):
                applySystemSnapshot(payload.snapshot, at: url)
                SystemLibraryCache.save(payload.snapshot, for: url)
            case .failure(let error):
                systemLibraryError = error.localizedDescription
                if cached == nil {
                    systemPhotos = []
                    systemAlbums = []
                    systemFolders = []
                    systemPeople = []
                    systemPhotoIndex = [:]
                    systemAlbumIndex = [:]
                }
                if informOnFailure {
                    showToast(error.localizedDescription)
                }
            }
            isLoadingSystemLibrary = false
            systemScanCount = 0
            // 扫描结束后按最终内容重算重复分组。
            invalidateSystemDuplicateGroups()
            // 新照片进入系统图库后，继续增量识别（仅在已经开启过识别时）。
            resumeSystemAnalysisIfNeeded()
        }
    }

    /// 建索引期间「先显示」的缓冲上限：只保留开头这一段供用户浏览，
    /// 索引就绪后会整体替换成 SQL 窗口，不把整个图库常驻内存。
    static let systemStreamDisplayLimit = 40_000

    /// 扫描 / 建索引的批次通道：后台逐批投递，主线程按 2000 张或 0.3 秒合并刷新。
    static func makeSystemBatchStream()
        -> (AsyncStream<[PhotoItem]>, AsyncStream<[PhotoItem]>.Continuation) {
        var continuation: AsyncStream<[PhotoItem]>.Continuation!
        let stream = AsyncStream<[PhotoItem]>(bufferingPolicy: .bufferingNewest(8)) { continuation = $0 }
        return (stream, continuation)
    }

    @MainActor
    private func drainSystemBatches(_ stream: AsyncStream<[PhotoItem]>,
                                    token: Int,
                                    displayLimit: Int? = nil) async {
        var pending: [PhotoItem] = []
        pending.reserveCapacity(2_000)
        var appended = 0
        var lastFlush = Date()
        func flush() {
            guard !pending.isEmpty, token == systemLoadToken else {
                pending.removeAll(keepingCapacity: true)
                return
            }
            if displayLimit.map({ appended < $0 }) ?? true {
                systemPhotos.append(contentsOf: pending)
                for item in pending {
                    systemPhotoIndex[item.id] = item
                }
                appended += pending.count
            }
            pending.removeAll(keepingCapacity: true)
        }
        for await batch in stream {
            guard token == systemLoadToken else { break }
            pending.append(contentsOf: batch.map { applySystemOverlay($0) })
            if pending.count >= 2_000 || Date().timeIntervalSince(lastFlush) > 0.3 {
                flush()
                lastFlush = Date()
            }
        }
        flush()
    }

    /// 应用系统图库索引：内存只保留相簿 / 文件夹 / 人物这些轻量元数据，照片按窗口查询。
    /// 相簿 / 文件夹 / 人物在直连模式下每次访问都会查一次 `Photos.sqlite`，
    /// 统一放到后台线程读取，避免打开图库时主线程被上万条元数据查询堵住。
    func applySystemIndex(_ index: SystemIndex, at url: URL) async {
        let metadata = await Task.detached(priority: .userInitiated) {
            () -> (albums: [SystemAlbumInfo], folders: [SystemFolderInfo], people: [SystemPersonInfo]) in
            // 相簿项目数一次聚合读入缓存，侧边栏逐行判断「空相簿」时不再查库。
            index.warmDirectAlbumCounts()
            return (index.albums, index.folders, index.people)
        }.value
        systemIndex = index
        systemIndexSignature = "\(url.path)#\(index.total)#\(index.trueTotal)"
        systemLibraryName = index.name
        systemPhotos = []
        systemPhotoIndex = [:]
        // 直连模式下 albums / folders / people 每次访问都会查一次 Photos.sqlite，
        // 这里只取一遍再复用，避免启动时把上万个相簿查两次。
        let albums = metadata.albums
        let folders = metadata.folders
        systemAlbums = albums
        systemFolders = folders
        systemPeople = metadata.people
        systemAlbumIndex = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        systemTotalAssetCount = index.trueTotal
        systemLibraryError = nil
        systemLibraryLoadedPath = url.path
        systemIndexReady = true
        // 缩略图目录先登记到索引：外接库里每个格子的存在性判断都变成内存查询。
        // 官方 derivative 目录可能有上百万个文件，只预热一小段时间；本机缩略图缓存给足预算。
        ThumbnailFileIndex.shared.warm(root: LibraryPaths.systemDerivatives(libraryURL: url))
        ThumbnailFileIndex.shared.warm(root: url.appendingPathComponent("scopes/cloudsharing",
                                                                       isDirectory: true))
        ThumbnailFileIndex.shared.warm(root: LibraryPaths.systemThumbs, timeBudget: 3)
        invalidateSystemDuplicateGroups()
        systemGeoCacheKey = nil
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        mediaTypeSummaryCacheKey = nil
        systemStructureRevision &+= 1
        contentRevision &+= 1
        clearSystemWindow()
        hydrateSystemCacheIfNeeded()
        loadPhotoKitMediaTypesIfNeeded()
    }

    /// 长曝光 / 电影效果只能通过 PhotoKit 智能相簿取 ID；仅对当前官方图库有效。
    func loadPhotoKitMediaTypesIfNeeded() {
        guard isNativeContainer, !isPhotoKitMediaTypeLoaded else { return }
        isPhotoKitMediaTypeLoaded = true
        Task { [weak self] in
            let ids = await PhotoKitBridge.specialMediaTypeAssetIDs()
            guard let self else { return }
            guard let ids else {
                // 没有照片权限：保留入口但结果为空，下次进入时再请求。
                self.isPhotoKitMediaTypeLoaded = false
                return
            }
            self.photoKitLongExposureIDs = ids.longExposure
            self.photoKitCinematicIDs = ids.cinematic
            self.mediaTypeSummaryCacheKey = nil
            self.contentRevision &+= 1
        }
    }

    /// 应用一份系统图库快照（缓存或扫描结果）。
    func applySystemSnapshot(_ snapshot: SystemLibrarySnapshot, at url: URL) {
        systemLibraryName = snapshot.name
        systemPhotos = snapshot.photos.map { applySystemOverlay($0) }
        systemAlbums = snapshot.albums
        systemFolders = snapshot.folders
        systemPeople = snapshot.people
        systemPhotoIndex = Dictionary(uniqueKeysWithValues: systemPhotos.map { ($0.id, $0) })
        systemAlbumIndex = Dictionary(uniqueKeysWithValues: snapshot.albums.map { ($0.id, $0) })
        systemTotalAssetCount = snapshot.totalAssetCount ?? snapshot.photos.count
        systemLibraryError = nil
        systemLibraryLoadedPath = url.path
        invalidateSystemDuplicateGroups()
        hydrateSystemCacheIfNeeded()
    }

    /// 把拾光的补充元数据叠加到官方「照片」图库的照片上（收藏 / 隐藏 / 关键词 / 标题 / 查看时间）。
    /// 只影响拾光自己的展示，不修改 `Photos.sqlite`。
    func applySystemOverlay(_ photo: PhotoItem) -> PhotoItem {
        Self.applyingOverlays(photo,
                              overlays: systemOverlays,
                              nativeKeywords: systemNativeKeywordIDMap,
                              isNative: isNativeContainer)
    }

    /// 叠加规则的批量 / 后台版本：overlay 与官方关键词由调用方先快照，
    /// 批量汇总（如个人收藏）时不必回主线程逐条读取 Store 状态。
    nonisolated static func applyingOverlays(_ photo: PhotoItem,
                                             overlays: [UUID: MetadataStore.AssetOverlay],
                                             nativeKeywords: [UUID: [String]],
                                             isNative: Bool) -> PhotoItem {
        var item = photo
        if isNative, let overlay = overlays[photo.id] {
            item = applyAssetOverlay(overlay, to: item)
        }
        // 官方图库自带的关键词与拾光补充关键词合并展示，信息面板 / 搜索都能看到。
        if let native = nativeKeywords[photo.id], !native.isEmpty {
            var merged = item.keywords ?? []
            for tag in native where !merged.contains(tag) { merged.append(tag) }
            item.keywords = merged
        }
        return item
    }

    /// 读回官方图库自带的关键词（每次载入图库读一次；`Photos.sqlite` 只读，不会写回）。
    @discardableResult
    func ensureSystemNativeKeywordsLoaded() -> [String: [UUID]] {
        if let cached = systemNativeKeywordIndex { return cached }
        guard let path = systemLibraryPath else { return [:] }
        let map = SystemIndex.nativeKeywordMap(libraryURL: URL(fileURLWithPath: path))
        systemNativeKeywordIndex = map.byKeyword
        systemNativeKeywordIDMap = map.byAsset
        return map.byKeyword
    }

    /// 该关键词是否来自官方图库：只读，无法从 `Photos.sqlite` 删除。
    func isNativeSystemKeyword(_ name: String) -> Bool {
        isSystemScope && ensureSystemNativeKeywordsLoaded()[name] != nil
    }

    /// 叠加规则的纯函数版本：后台分组时直接使用，不依赖主线程状态。
    nonisolated static func applyAssetOverlay(_ overlay: MetadataStore.AssetOverlay?,
                                              to photo: PhotoItem) -> PhotoItem {
        guard let overlay else { return photo }
        var item = photo
        if let favorite = overlay.isFavorite { item.isFavorite = favorite }
        if let hidden = overlay.isHidden { item.isHidden = hidden }
        if let keywords = overlay.keywords { item.keywords = keywords }
        if let title = overlay.title { item.title = title }
        if let viewed = overlay.viewedAt { item.viewedAt = viewed }
        if let rating = overlay.rating { item.rating = rating }
        if let flag = overlay.flag { item.flag = flag }
        if let colorLabel = overlay.colorLabel { item.colorLabel = colorLabel }
        return item
    }

    struct SystemLoadPayload {
        let snapshot: SystemLibrarySnapshot
    }

    func reloadSystemLibrary() {
        guard let path = systemLibraryPath else { return }
        loadSystemLibrary(at: URL(fileURLWithPath: path), informOnFailure: true, forceRefresh: true)
    }

    func disconnectSystemLibrary() {
        guard let path = systemLibraryPath else { return }
        removeSystemLibrary(path)
    }

    func revealSystemLibraryInFinder() {
        guard let path = systemLibraryPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var systemLibraryTotalBytes: Int64 {
        systemSidebarCounts.totalBytes
    }

    var systemTrashCount: Int {
        systemSidebarCounts.trash
    }

    static var recentlySavedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    /// 「最近查看」按系统「照片」的 30 天窗口统计。
    static var recentlyViewedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    var systemPortraitCount: Int {
        systemSidebarCounts.portrait
    }

    var systemDuplicateCount: Int {
        systemSidebarCounts.duplicate
    }

    var systemScreenshotCount: Int {
        systemSidebarCounts.screenshots
    }

    var systemRecentlySavedCount: Int {
        systemSidebarCounts.recentlySaved
    }

    var systemImportCount: Int {
        systemSidebarCounts.imports
    }

    var systemHiddenCount: Int {
        systemSidebarCounts.hidden
    }

    func systemAlbumNamesContaining(_ id: UUID) -> [String] {
        if let index = systemIndex { return index.albumNames(containing: id) }
        return systemAlbums.filter { $0.assetIDs.contains(id) }.map { $0.name }
    }

    /// 侧边栏相簿封面：索引模式按需查询第一张，不加载整个相簿。
    func systemAlbumFirstPhoto(_ albumID: Int64) -> PhotoItem? {
        if let index = systemIndex {
            return index.firstAlbumPhoto(albumID).map { applySystemOverlay($0) }
        }
        guard let album = systemAlbum(id: albumID),
              let first = album.assetIDs.first else { return nil }
        return systemPhoto(id: first)
    }

    /// 侧边栏相簿封面的异步版本：查询放到后台，视图 body 只调用它、不再同步查库。
    /// 结果按相簿缓存，滚动离开再回来不会重复读 `Photos.sqlite`。
    func systemAlbumCover(_ albumID: Int64) async -> PhotoItem? {
        if let cached = systemAlbumCoverCache[albumID] { return cached }
        if systemAlbumCoverMisses.contains(albumID) { return nil }
        // 同一个相簿同时被多处请求时只查一次，其余请求等结果。
        if systemAlbumCoverLoading.contains(albumID) {
            while systemAlbumCoverLoading.contains(albumID) {
                if Task.isCancelled { return nil }
                try? await Task.sleep(nanoseconds: 20_000_000)
                if let cached = systemAlbumCoverCache[albumID] { return cached }
                if systemAlbumCoverMisses.contains(albumID) { return nil }
            }
            return systemAlbumCoverCache[albumID]
        }
        systemAlbumCoverLoading.insert(albumID)
        defer { systemAlbumCoverLoading.remove(albumID) }
        let index = systemIndex
        let raw: PhotoItem?
        if let index {
            raw = await Task.detached(priority: .utility) {
                index.firstAlbumPhoto(albumID)
            }.value
        } else {
            // 扫描 / 建索引期间还没有索引：内存快照查找本身是 O(1)，直接同步取。
            raw = systemAlbumFirstPhoto(albumID)
        }
        guard let raw else {
            systemAlbumCoverMisses.insert(albumID)
            return nil
        }
        let photo = applySystemOverlay(raw)
        systemAlbumCoverCache[albumID] = photo
        return photo
    }

    /// 相簿封面（可多张）：索引模式按官方顺序取前若干张，跳过已删除与隐藏项目。
    func systemAlbumPreviewPhotos(_ albumID: Int64, limit: Int) -> [PhotoItem] {
        guard limit > 0 else { return [] }
        if let index = systemIndex {
            return index.albumPreviewPhotos(albumID, limit: limit).map { applySystemOverlay($0) }
        }
        var result: [PhotoItem] = []
        for id in systemAlbum(id: albumID)?.assetIDs ?? [] where result.count < limit {
            if let photo = systemPhoto(id: id), photo.deletedAt == nil, !photo.isHidden {
                result.append(photo)
            }
        }
        return result
    }

    /// 相簿封面的异步版本：相簿墙可能有上万个相簿，body 里逐张同步查 `Photos.sqlite`
    /// 会让打开文件夹直接卡住。命中索引缓存时立刻返回，否则在后台取。
    func systemAlbumPreviewPhotosAsync(_ albumID: Int64, limit: Int) async -> [PhotoItem] {
        guard limit > 0 else { return [] }
        guard let index = systemIndex else {
            return systemAlbumPreviewPhotos(albumID, limit: limit)
        }
        if let cached = index.cachedAlbumPreviewPhotos(albumID, limit: limit) {
            return cached.map { applySystemOverlay($0) }
        }
        let raw = await Task.detached(priority: .utility) {
            index.albumPreviewPhotos(albumID, limit: limit)
        }.value
        return raw.map { applySystemOverlay($0) }
    }

    /// 官方导入会话（按导入时间从新到旧）；本地库没有这套记录。
    var systemImportSessions: [SystemImportSession] {
        systemIndex?.importSessions ?? []
    }

    /// 导入会话的封面（官方索引里批内第一张）。
    func systemImportSessionCover(_ sessionID: Int64) -> PhotoItem? {
        guard let photo = systemIndex?.importSessionCover(sessionID) else { return nil }
        return applySystemOverlay(photo)
    }

    /// 导入批次的拍摄跨度与视频数量。
    func systemImportSessionSummary(_ sessionID: Int64) -> SystemImportSessionSummary? {
        systemIndex?.importSessionSummary(sessionID)
    }

    /// 相簿项目数：索引模式直接读索引，避免依赖内存里的空 assetIDs。
    func systemAlbumPhotoCount(_ albumID: Int64) -> Int {
        if let index = systemIndex { return index.albumAssetCount(albumID) }
        return systemAlbum(id: albumID)?.assetIDs.count ?? 0
    }

    /// 侧边栏相簿是否为空。
    func systemAlbumIsEmpty(_ albumID: Int64) -> Bool {
        if let index = systemIndex { return index.albumAssetCount(albumID) == 0 }
        // 扫描 / 建索引期间相簿成员还没读完：不显示「空相簿」标记，避免误判。
        if isLoadingSystemLibrary { return false }
        return systemAlbum(id: albumID)?.assetIDs.isEmpty ?? true
    }

    /// 按主键取相簿：优先走索引，索引尚未建立时退回线性查找。
    func systemAlbum(id: Int64) -> SystemAlbumInfo? {
        if let album = systemAlbumIndex[id] { return album }
        return systemAlbums.first(where: { $0.id == id })
    }

    var systemLibraryDateRange: String? {
        let counts = systemSidebarCounts
        guard let minDate = counts.earliest, let maxDate = counts.latest else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return "\(formatter.string(from: minDate)) – \(formatter.string(from: maxDate))"
    }

    func importSystemSelectionToLibrary() {
        let targets = selection.compactMap { systemPhoto(id: $0) }
        guard !targets.isEmpty else { return }
        importSystemPhotos(targets, albumName: nil)
    }

    func importSystemAlbumToLibrary(_ albumID: Int64) {
        let targets: [PhotoItem]
        if let index = systemIndex {
            targets = index.photos(ids: index.albumAssetIDs(albumID)).map { applySystemOverlay($0) }
        } else {
            guard let album = systemAlbums.first(where: { $0.id == albumID }) else { return }
            targets = album.assetIDs.compactMap { systemPhoto(id: $0) }
        }
        let albumName = systemAlbums.first(where: { $0.id == albumID })?.name
        guard !targets.isEmpty else {
            showToast("该相簿里没有可拷贝的项目")
            return
        }
        importSystemPhotos(targets, albumName: albumName)
    }

    /// 递归收集系统文件夹（含子文件夹与其相簿）里的所有项目 ID。
    func systemFolderAssetIDs(_ folderID: Int64) -> [UUID] {
        if let index = systemIndex { return index.folderAssetIDs(folderID) }
        var ids: [UUID] = []
        for album in systemAlbums where album.parentFolder == folderID {
            ids.append(contentsOf: album.assetIDs)
        }
        for child in systemFolders where child.parent == folderID {
            ids.append(contentsOf: systemFolderAssetIDs(child.id))
        }
        return ids
    }

    /// 只取前 `limit` 个项目 ID：打开文件夹时预热缩略图，避免为预热遍历整棵子树。
    func systemFolderPreviewAssetIDs(_ folderID: Int64, limit: Int) -> [UUID] {
        if let index = systemIndex { return index.folderPreviewAssetIDs(folderID, limit: limit) }
        var ids: [UUID] = []
        ids.reserveCapacity(limit)
        func walk(_ id: Int64) {
            guard ids.count < limit else { return }
            for album in systemAlbums where album.parentFolder == id {
                ids.append(contentsOf: album.assetIDs.prefix(limit - ids.count))
                if ids.count >= limit { return }
            }
            for child in systemFolders where child.parent == id {
                walk(child.id)
                if ids.count >= limit { return }
            }
        }
        walk(folderID)
        return ids
    }

    /// 重新读取官方「照片」的人物 / 宠物列表。
    /// 识别本身由 macOS「照片」在端侧完成，拾光只刷新读到的结果。
    func refreshSystemPeople() {
        guard let index = systemIndex else {
            showToast("系统图库尚未就绪，请稍后重试")
            return
        }
        systemPeople = index.people
        showToast(systemPeople.isEmpty
                  ? "官方图库里还没有识别出人物"
                  : "已刷新 \(systemPeople.count.formatted()) 位人物 / 宠物")
    }

    func importSystemFolderToLibrary(_ folderID: Int64) {
        guard let folder = systemFolders.first(where: { $0.id == folderID }) else { return }
        let ids = systemFolderAssetIDs(folderID)
        let targets: [PhotoItem]
        if let index = systemIndex {
            targets = index.photos(ids: ids).map { applySystemOverlay($0) }
        } else {
            targets = ids.compactMap { systemPhoto(id: $0) }
        }
        guard !targets.isEmpty else {
            showToast("该文件夹里没有可拷贝的项目")
            return
        }
        importSystemPhotos(targets, albumName: folder.name)
    }

    /// 当前系统图库范围（相簿 / 文件夹）能否整体拷贝到拾光。
    var canImportCurrentSystemScope: Bool {
        switch sidebarItem {
        case .systemAlbum, .systemFolder: return true
        default: return false
        }
    }

    var currentSystemScopeImportTitle: String {
        switch sidebarItem {
        case .systemAlbum(let id):
            return "拷贝「\(systemAlbums.first(where: { $0.id == id })?.name ?? "相簿")」到拾光"
        case .systemFolder(let id):
            return "拷贝「\(systemFolders.first(where: { $0.id == id })?.name ?? "文件夹")」到拾光"
        default:
            return "拷贝到拾光"
        }
    }

    func importCurrentSystemScopeToLibrary() {
        switch sidebarItem {
        case .systemAlbum(let id):
            importSystemAlbumToLibrary(id)
        case .systemFolder(let id):
            importSystemFolderToLibrary(id)
        default:
            break
        }
    }

    func importSystemPhotos(_ targets: [PhotoItem], albumName: String?) {
        // 已经在拾光里的项目（同名同大小）不重复拷贝。
        let existing = Set(photos.map { "\($0.originalName)|\($0.fileSize)" })
        let pending = targets.filter { !existing.contains("\($0.originalName)|\($0.fileSize)") }
        let skipped = targets.count - pending.count
        guard !pending.isEmpty else {
            showToast(skipped > 0 ? "这些项目已经在拾光里了" : "没有可拷贝的项目")
            return
        }
        showToast("正在拷贝 \(pending.count) 项到拾光…")
        Task {
            var imported: [PhotoItem] = []
            let batchID = UUID()
            for target in pending {
                guard let path = target.systemOriginalPath else { continue }
                let item = await Task.detached(priority: .userInitiated) {
                    try? ImportService.importFile(URL(fileURLWithPath: path))
                }.value
                if var item {
                    item.importBatchID = batchID
                    imported.append(item)
                }
            }
            photos.append(contentsOf: imported)
            if let albumName, !imported.isEmpty {
                if let index = albums.firstIndex(where: { $0.name == albumName }) {
                    albums[index].photoIDs.append(contentsOf: imported.map { $0.id })
                } else {
                    var album = Album(name: albumName)
                    album.photoIDs = imported.map { $0.id }
                    albums.append(album)
                }
            }
            save()
            selection.removeAll()
            var message = "已拷贝 \(imported.count) 项到拾光"
            if skipped > 0 { message += "，跳过 \(skipped) 项重复项目" }
            showToast(message)
        }
    }
}
