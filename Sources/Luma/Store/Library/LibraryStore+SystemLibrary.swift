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

    /// 侧边栏系统树拍平后的一行：文件夹与相簿按图库顺序混排，用层级控制缩进。
    /// id 在拍平时算好一次，避免 `ForEach` 每次重建 body 都为上万行重复拼字符串。
    struct SystemFlatRow: Identifiable {
        let entry: SystemSidebarEntry
        let level: Int
        let id: String
    }

    /// 把系统树按当前展开状态拍平成单层数组。
    /// 侧边栏把它直接喂给最外层 `LazyVStack`：展开几千个相簿也只创建可见行，
    /// 不会再因为嵌套懒加载容器把整棵子树一次性实例化。
    func systemFlatRows(expanded: Set<Int64>, expansionRevision: Int) -> [SystemFlatRow] {
        let key = "\(systemStructureRevision)#\(expansionRevision)"
        if key == systemFlatRowsCacheKey { return systemFlatRowsCache }
        var rows: [SystemFlatRow] = []
        func walk(_ parent: Int64?, _ level: Int) {
            for entry in systemChildren(of: parent) {
                rows.append(SystemFlatRow(entry: entry, level: level, id: entry.id))
                if case .folder(let folder) = entry, expanded.contains(folder.id) {
                    walk(folder.id, level + 1)
                }
            }
        }
        walk(nil, 0)
        systemFlatRowsCacheKey = key
        systemFlatRowsCache = rows
        return rows
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
        guard !tasks.isRunning(.systemDuplicateGroups) else { return }
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
        tasks.adopt(.systemDuplicateGroups, Task.detached(priority: .userInitiated) { [weak self, index, overlays, key] in
            let photos = index.duplicatePhotos().map { photo in
                Self.applyAssetOverlay(overlays[photo.id], to: photo)
            }
            let groups = DuplicateDetector.groups(from: photos, mergeFlagged: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tasks.finish(.systemDuplicateGroups)
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
        })
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
    static func systemSortKey(_ folder: SystemFolderInfo) -> Int64 {
        folder.sortIndex != 0 ? folder.sortIndex : folder.id
    }

    static func systemSortKey(_ album: SystemAlbumInfo) -> Int64 {
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
        localPhoto(id: id)
            ?? systemPhoto(id: id)
            ?? cloudPhoto(id: id)
    }

    /// 批量取照片：按传入顺序返回存在的项。
    ///
    /// ID 少时逐个查；ID 多（全选、整批导出、AI 批量）时复用缓存索引，
    /// 否则循环里每次 `anyPhoto(id:)` 都要扫一遍全库，变成 O(k·n)。
    func photos(forIDs ids: [UUID]) -> [PhotoItem] {
        guard !ids.isEmpty else { return [] }
        guard ids.count > Self.localPhotoIndexThreshold else {
            return ids.compactMap { anyPhoto(id: $0) }
        }
        let index = buildLocalPhotoIndex()
        return ids.compactMap { index[$0] ?? systemPhoto(id: $0) ?? cloudPhoto(id: $0) }
    }

    func photos(forIDs ids: Set<UUID>) -> [PhotoItem] {
        photos(forIDs: Array(ids))
    }

    /// 该 ID 是否属于当前系统图库（可能只在索引里，尚未加载进内存窗口）。
    func isSystemPhotoID(_ id: UUID) -> Bool {
        if systemPhotoIndex[id] != nil { return true }
        if systemOverlays[id] != nil { return true }
        return systemIndex?.photo(id: id) != nil
    }

    func presentSystemLibraryPanel() {
        let url = chooseURLs(LibraryOpenPanelRequest(
            message: "连接后可在侧边栏切换；只记录连接地址，不会改变 App 自己的图库位置。同一个图库不会重复登记。",
            prompt: "连接",
            allowsMultipleSelection: false,
            canChooseFiles: true,
            canChooseDirectories: true,
            treatsFilePackagesAsDirectories: false
        )).first
        guard let url else { return }
        // 「自己外接自己」不产生第二条连接：当前图库本身不能重复登记。
        if isContainerNativeLibraryPath(url.standardizedFileURL.path) {
            showToast("这就是当前图库本身，不需要重复连接")
            return
        }
        connectSystemLibrary(url)
    }

    /// 选择要打开 / 切换的 App 图库（会真正切换本地库位置）。
    func presentLibraryContainerPanel() {
        let url = chooseURLs(LibraryOpenPanelRequest(
            message: "选择要打开或切换的 .photoslibrary 图库",
            prompt: "打开",
            allowsMultipleSelection: false,
            canChooseFiles: true,
            canChooseDirectories: true,
            treatsFilePackagesAsDirectories: false
        )).first
        guard let url else { return }
        // 接入的图库记进当前图库自己的数据：切走之后，本图库的「图库」分区仍保留这条记录。
        if LibraryPaths.isLibraryContainer(url) {
            registerKnownLibrary(url)
        }
        activateLibrary(url)
    }

    @discardableResult
    func createLibrary(at url: URL, migratingLocalData: Bool = false) async -> Bool {
        guard LibraryPaths.createLibrary(at: url) else {
            showToast("无法创建照片图库（目标位置已存在同名项目）")
            return false
        }
        // 与切换一致：切库成功后再释放当前库，创建 / 切换失败时不留空壳。
        // 迁入旧数据可能在几十 GB 级别，切换过程把大块复制放到后台执行。
        guard await LibraryPaths.switchContainerAsync(to: url, migratingLocalData: migratingLocalData) else {
            showToast("无法创建照片图库（目标位置不可写）")
            return false
        }
        flushMetadata()
        metadataStore = nil
        // 新图库的快照目录与修订号都要重新建立。
        resetSourceContentCache()
        resetInMemoryCachesForLibrarySwitch()
        tasks.cancel(.libraryIndex)
        libraryIndexComplete = true
        metadataStore = try? MetadataStore(url: LibraryPaths.metadataFile)
        // 新图库是空白库：不继承其它图库的历史，「图库」分区里只记它自己。
        // 这份记录写在新图库自己的设置里，换库时各自独立。
        knownLibraries = [SystemLibraryRef(
            path: url.standardizedFileURL.path,
            name: url.deletingPathExtension().lastPathComponent)]
        persistKnownLibraries()
        // 新库还没有自己的主题时，把向导里选好的外观 / 强调色写进去。
        AppSettings.shared.seedThemeForCurrentLibraryIfNeeded()
        // 模块开关同理：向导里选好的模块写进新库，随后的 reloadPerLibraryState 再读回来。
        AppSettings.shared.seedModulesForCurrentLibraryIfNeeded()
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
        showNewLibrarySheet = false
        libraryPickerOnLaunch = false
        needsLibrarySetup = false
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        showToast("已创建 \(url.lastPathComponent)")
        return true
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
        systemWindowPageCache.removeAll()
        systemWindowPageCacheOrder.removeAll()
        systemNativeKeywordIndex = nil
        systemNativeKeywordIDMap = [:]
        photoKitLongExposureIDs = nil
        photoKitCinematicIDs = nil
        photoKitRAWIDs = nil
        photoKitScreenRecordingIDs = nil
        isPhotoKitMediaTypeLoaded = false
        systemIndexReady = false
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        systemGeoCacheKey = nil
        systemGeoCache = []
        viewerStripKey = nil
        viewerStrip = []
        // 识别结果只属于当前系统图库，断开或换库时一并清空并取消进行中的识别。
        tasks.cancel(.systemAnalysis)
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
        tasks.cancel(.systemWindow)
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

    /// App 内的「新建图库」：先打开创建向导（名称 / 位置 / 能力 / 库级设置），
    /// 用户确认后才真正建库，不会点一下就凭空多出一个空图库。
    func beginNewLibraryFlow() {
        showNewLibrarySheet = true
    }

    /// 换库时作废只属于上一个图库的内存缓存：缩略图 / 海报解码结果、网络影院的列表与资料。
    /// 磁盘快照、SQLite 与缓存目录都在各自图库内部，换库后由上层重新读取，不在这里删文件。
    func resetInMemoryCachesForLibrarySwitch() {
        ImageLoader.clearMemoryCaches()
        CatalogArtworkMemory.shared.removeAll()
        tvModel.clearImageCaches()
        networkCinemaModel.resetForLibrarySwitch()
    }

    /// 选位置 → 建库。返回是否真的建好，调用方据此决定要不要关掉建库向导。
    @discardableResult
    func presentNewLibraryPanel(migratingLocalData: Bool = false) async -> Bool {
        let selected = chooseSaveURL(LibrarySavePanelRequest(
            title: "新建图库",
            message: "将创建一个与官方同款的 .photoslibrary 图库包（database / originals / resources）",
            prompt: "创建",
            nameFieldStringValue: "未命名.photoslibrary",
            canCreateDirectories: true,
            isExtensionHidden: false,
            directoryURL: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        ))
        guard let selected else { return false }
        let url = selected.pathExtension.lowercased() == "photoslibrary"
            ? selected
            : selected.appendingPathExtension("photoslibrary")
        let created = await createLibrary(at: url, migratingLocalData: migratingLocalData)
        if !created {
            // 建库向导仍盖在主窗口上，Toast 会被挡住：用系统弹窗把失败原因说清楚。
            presentAlert(LibraryAlertRequest(
                title: "无法创建照片图库",
                message: FileManager.default.fileExists(atPath: url.path)
                    ? "这个位置已经有同名图库，或目标文件夹不可写。换个名称 / 位置再试。"
                    : "请确认目标文件夹可写，然后重试。",
                style: .warning
            ))
        }
        return created
    }

    /// 切换 App 自己的图库位置（会迁移/打开本地库）。
    func switchLibraryContainer(_ url: URL) {
        guard LibraryPaths.isLibraryContainer(url) else {
            showToast("请选择有效的 .photoslibrary 图库")
            return
        }

        let sameContainer = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
            == url.standardizedFileURL.path
        // 已经在用这个图库：只把界面切回它，不重放换库清理。
        // 撤销栈、回收站清理、缩略图预热都属于「换库」，重复选当前库不该丢现场。
        if sameContainer {
            showNewLibrarySheet = false
            showLibraryPicker = false
            libraryPickerOnLaunch = false
            containerLibraryPath = LibraryPaths.containerLibraryURL?.path
            needsLibrarySetup = LibraryPaths.requiresLibrarySetup
            rememberLibrary(url)
            if LibraryPaths.isNativeLibrary(url) {
                // 已加载就直接切回它的页面，未加载才扫描（不会重复重扫）。
                connectSystemLibrary(url)
            } else {
                navigate(to: .library)
            }
            return
        }

        // 先把目标图库切过去，成功后再放手当前库的数据库：
        // 切换失败（不存在 / 只读 / 无权限）时当前图库必须原样可用。
        guard LibraryPaths.switchContainer(to: url, migratingLocalData: false) else {
            showToast("无法切换照片图库：请确认这个图库可写")
            return
        }
        flushMetadata()
        metadataStore = nil
        // 快照与修订号跟着图库走。
        resetSourceContentCache()
        resetInMemoryCachesForLibrarySwitch()
        tasks.cancel(.libraryIndex)
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
        redirectCinemaSidebarItemIfNeeded()

        needsLibrarySetup = LibraryPaths.requiresLibrarySetup
        rememberLibrary(url)
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        showToast("已打开 \(url.deletingPathExtension().lastPathComponent)")

        guard LibraryPaths.isNativeLibrary(url) else {
            // 打开哪个图库就用哪个图库自己的连接、网盘与设置。
            resetCloudStateForLibrarySwitch()
            resetSystemLibraryState()
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
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        systemLibraryPath = url.path
        systemLibraryName = url.deletingPathExtension().lastPathComponent
        systemLibraryError = nil
        metadataStore?.setSetting("system_library_path", url.path)
        reloadPerLibraryState()
        // 走统一入口：官方图库会先申请照片访问授权，再开始扫描，避免扫到一半被打断。
        loadSystemLibraryIfNeeded(.systemLibrary)
        navigate(to: .systemLibrary)
    }

    /// 只记录 / 连接系统「照片」图库，绝不改变 App 自己的图库位置。
    /// - Parameter forceRefresh: 「重新读取」时传 true，忽略已加载缓存并重建索引。
    func connectSystemLibrary(_ url: URL, forceRefresh: Bool = false) {
        guard LibraryPaths.isLibraryContainer(url) else {
            showToast("请选择有效的 .photoslibrary 图库")
            return
        }
        guard LibraryPaths.isNativeLibrary(url) else {
            showToast("这不是系统「照片」图库；如需切换 App 图库，请使用「切换图库…」")
            return
        }

        let path = url.standardizedFileURL.path
        let isSelf = isContainerNativeLibraryPath(path)

        // 已经在浏览同一个系统图库：只切回该页面，不重复扫描，避免来回切换。
        if !forceRefresh,
           let current = systemLibraryPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }),
           current == path,
           let loaded = systemLibraryLoadedPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }),
           loaded == path,
           !isLoadingSystemLibrary {
            showLibraryPicker = false
            libraryPickerOnLaunch = false
            if !isSystemScope { navigate(to: .systemLibrary) }
            return
        }

        // 换的是另一个系统图库：上一个库的识别结果 / 窗口 / 计数都属于旧库，全部作废。
        if let current = systemLibraryPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }),
           current != path {
            resetSystemLibraryState()
        }

        systemLibraryPath = path
        systemLibraryName = url.deletingPathExtension().lastPathComponent
        systemLibraryError = nil
        metadataStore?.setSetting("system_library_path", path)
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        if isSelf {
            // 「自己外接自己」不算连接：当前 App 图库只保留在「图库」里，不登记成第二个条目。
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, path) }
            persistSystemLibraries(systemLibraries)
        } else {
            registerSystemLibrary(URL(fileURLWithPath: path))
        }
        if forceRefresh {
            loadSystemLibrary(at: URL(fileURLWithPath: path), informOnFailure: true, forceRefresh: true)
        } else {
            // 统一走授权 / 已加载判断：官方图库首次打开会先申请照片访问授权。
            loadSystemLibraryIfNeeded(.systemLibrary)
        }
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
        tasks.cancel(.thumbnailPrewarm)
        // 命名 / 新建相簿这类弹窗带着上一个图库的 ID，换库后必须关掉，不能让它操作新库。
        namePrompt = nil
        showNewAlbumSheet = false
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
        loadKnownLibraries()
        loadSystemManualOrderAlbums()
        // 网络电视源与顺序写在各自图库里，换库后要重新读。
        tvModel.reloadForCurrentLibrary()
        purgeExpiredTrashIfNeeded()
        // 美化推荐是派生结果，换库后必须清空，避免把上一个图库的照片带过来。
        resetBeautyState()
        // 体检结果与系统图库识别缓存同样只属于上一个图库 / 连接。
        tasks.cancel(.health)
        healthReport = nil
        healthReportScopeTag = nil
        isScanningHealth = false
        healthScanProgress = 0
        systemAnalysisIndex = [:]
        systemAnalysisAutoResume = false
        systemFeatures = [:]
        // 换库后 PhotoKit 的写入目标需要重新检测。
        systemWriteTargetState = .unknown
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

}
