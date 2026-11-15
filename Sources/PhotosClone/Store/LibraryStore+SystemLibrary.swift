import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

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

    /// 系统侧边栏计数：一次遍历算完所有徽标，避免每个计数各扫一遍 20 万张照片。
    var systemSidebarCounts: SystemSidebarCounts {
        if systemCountsCacheRevision == contentRevision, let cached = systemCountsCache {
            return cached
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

    /// 系统图库的重复组：同样按「文件大小 + 像素尺寸」聚合，结果按内容版本缓存。
    /// 只有打开重复页时才计算，避免扫描 / 侧边栏反复遍历整库。
    var systemDuplicateGroups: [DuplicateGroup] {
        // 扫描过程中照片逐批到达：先用已算好的分组，扫描结束后再按新内容重算，避免每批都遍历整库。
        if isLoadingSystemLibrary, systemDuplicateGroupsCacheKey != nil {
            return systemDuplicateGroupsCache
        }
        let key = "\(contentRevision)"
        if systemDuplicateGroupsCacheKey == key { return systemDuplicateGroupsCache }
        let groups = DuplicateDetector.groups(from: systemPhotos, mergeFlagged: true)
        systemDuplicateGroupsCacheKey = key
        systemDuplicateGroupsCache = groups
        return groups
    }

    /// 官方图库只读：拾光的「合并」是隐藏其余副本（写补充元数据，可撤销），不删除 Apple 的照片。
    @discardableResult
    func hideSystemDuplicateCopies(_ group: DuplicateGroup, keeping keepID: UUID) -> Int {
        guard canEditNativeOverlay else { return 0 }
        let ids = Set(group.photos.map(\.id)).subtracting([keepID])
        guard !ids.isEmpty else { return 0 }
        setSystemHidden(true, ids: ids)
        systemDuplicateGroupsCacheKey = nil
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
        systemDuplicateGroupsCacheKey = nil
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
        systemPhotoIndex[id]
    }

    func anyPhoto(id: UUID) -> PhotoItem? {
        photos.first(where: { $0.id == id })
            ?? systemPhotoIndex[id]
            ?? cloudPhotos.first(where: { $0.id == id })
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
        cancelHealthScan()
        healthReport = nil
        selection.removeAll()
        viewerID = nil
        editorID = nil
        // 新图库是全新的：上一个图库的连接、网盘与库级设置都不能带进来。
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        reloadPerLibraryState()
        navigate(to: .library)
        rememberLibrary(url)
        showLibraryPicker = false
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
            cancelHealthScan()
            healthReport = nil
            selection.removeAll()
            viewerID = nil
            editorID = nil
            let name = url.deletingPathExtension().lastPathComponent
            showToast("已打开 \(name)")
        }

        needsLibrarySetup = LibraryPaths.requiresLibrarySetup
        rememberLibrary(url)
        showLibraryPicker = false
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
            if !isSystemScope { navigate(to: .systemLibrary) }
            return
        }

        systemLibraryPath = url.path
        systemLibraryName = url.deletingPathExtension().lastPathComponent
        systemLibraryError = nil
        metadataStore?.setSetting("system_library_path", url.path)
        showLibraryPicker = false
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
        loadAIState()
        loadSystemLibraries()
        loadCloudMounts()
        remountSMBMountsOnLaunch()
        purgeExpiredTrashIfNeeded()
        // 美化推荐是派生结果，换库后必须清空，避免把上一个图库的照片带过来。
        resetBeautyState()
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
            systemLibraryPath = nil
            systemLibraryName = nil
            systemPhotos = []
            systemAlbums = []
            systemFolders = []
            systemPeople = []
            systemPhotoIndex = [:]
            systemAlbumIndex = [:]
            systemDuplicateGroupsCacheKey = nil
            systemDuplicateGroupsCache = []
            systemTotalAssetCount = 0
            systemLibraryError = nil
            systemLibraryLoadedPath = nil
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
        switchLibraryContainer(url)
    }

    // MARK: - 官方图库照片的补充元数据

    /// 当前是否允许给官方「照片」图库的照片写拾光的补充元数据。
    var canEditNativeOverlay: Bool { isNativeContainer }

    private func updateSystemPhoto(_ id: UUID, mutate: (inout PhotoItem) -> Void) {
        if let index = systemPhotos.firstIndex(where: { $0.id == id }) {
            mutate(&systemPhotos[index])
            systemPhotoIndex[id] = systemPhotos[index]
        } else if var item = systemPhotoIndex[id] {
            mutate(&item)
            systemPhotoIndex[id] = item
        }
    }

    private func saveSystemOverlay(_ id: UUID, mutate: (inout MetadataStore.AssetOverlay) -> Void) {
        guard let store = metadataStore else { return }
        var overlay = systemOverlays[id] ?? MetadataStore.AssetOverlay()
        mutate(&overlay)
        systemOverlays[id] = overlay
        store.saveOverlay(id, overlay)
    }

    /// 收藏 / 取消收藏官方图库里的照片：写入拾光数据库，`Photos.sqlite` 保持只读。
    func setSystemFavorite(_ favorite: Bool, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        for id in ids {
            updateSystemPhoto(id) { $0.isFavorite = favorite }
            saveSystemOverlay(id) { $0.isFavorite = favorite }
        }
    }

    func setSystemHidden(_ hidden: Bool, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        for id in ids {
            updateSystemPhoto(id) { $0.isHidden = hidden }
            saveSystemOverlay(id) { $0.isHidden = hidden }
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

    /// 记录查看：官方图库照片的查看时间同样只写拾光数据库。
    func recordSystemView(_ id: UUID) {
        guard canEditNativeOverlay, let item = systemPhotoIndex[id] else { return }
        let now = Date()
        if let last = item.viewedAt, now.timeIntervalSince(last) < 3600 { return }
        updateSystemPhoto(id) { $0.viewedAt = now }
        saveSystemOverlay(id) { $0.viewedAt = now }
    }

    /// 首次进入系统图库相关页面时才扫描 Photos.sqlite，避免启动即加载。
    func loadSystemLibraryIfNeeded(_ item: SidebarItem) {
        guard item.isSystemScope,
              systemPhotos.isEmpty,
              systemLibraryError == nil,
              !isLoadingSystemLibrary,
              let path = systemLibraryPath else { return }
        loadSystemLibrary(at: URL(fileURLWithPath: path), informOnFailure: true)
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
        // 先清空，随后用缓存或按批次增量展示。
        systemPhotos = []
        systemPhotoIndex = [:]
        systemAlbums = []
        systemFolders = []
        systemAlbumIndex = [:]
        systemTotalAssetCount = 0
        selection.removeAll()
        viewerID = nil

        // 载入上限在本次载入开始时固定；调整上限后重新载入会拿到新值。
        let limit = systemAssetLimit
        // 每次载入递增令牌：重扫时旧的扫描结果与缓存写入都要作废。
        systemLoadToken &+= 1
        let token = systemLoadToken

        Task {
            // 先读扫描缓存：命中就立刻出图，只有图库确有变化或上限变化时才在后台重扫。
            let cached = await Task.detached(priority: .userInitiated) {
                SystemLibraryCache.load(for: url, maxAssets: limit)
            }.value

            guard token == systemLoadToken else { return }

            if let cached {
                applySystemSnapshot(cached.snapshot, at: url)
                if cached.isFresh, !forceRefresh {
                    isLoadingSystemLibrary = false
                    systemScanCount = 0
                    notifyIfSystemLibraryTruncated()
                    return
                }
            }

            // 没有缓存时边扫边显示；有缓存时保持现有内容，扫描结束后整体替换。
            let streamBatches = cached == nil
            var continuation: AsyncStream<[PhotoItem]>.Continuation?
            var stream: AsyncStream<[PhotoItem]>?
            if streamBatches {
                var cont: AsyncStream<[PhotoItem]>.Continuation!
                stream = AsyncStream<[PhotoItem]>(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
                continuation = cont
            }

            // 扫描与索引构建放在后台。
            let batchContinuation = continuation
            let scanTask = Task.detached(priority: .userInitiated) { [weak self] () -> Result<SystemLoadPayload, Error> in
                defer { batchContinuation?.finish() }
                do {
                    let snapshot = try SystemPhotosLibrary.scan(
                        libraryURL: url,
                        maxAssets: limit,
                        progress: { count in
                            Task { @MainActor in
                                guard let self, self.systemLoadToken == token else { return }
                                self.systemScanCount = count
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
            // 20 万张会分成几百批，这里合并成约 2000 张一次，减少主线程重算与视图刷新次数。
            if let stream {
                var pending: [PhotoItem] = []
                pending.reserveCapacity(2_000)
                var lastFlush = Date()
                for await batch in stream {
                    guard token == systemLoadToken else { break }
                    pending.append(contentsOf: batch.map { applySystemOverlay($0) })
                    if pending.count >= 2_000 || Date().timeIntervalSince(lastFlush) > 0.3 {
                        systemPhotos.append(contentsOf: pending)
                        for item in pending {
                            systemPhotoIndex[item.id] = item
                        }
                        pending.removeAll(keepingCapacity: true)
                        lastFlush = Date()
                        #if DEBUG
                        if CommandLine.arguments.contains("--debug-system-videos") {
                            print("[stream] total=\(systemPhotos.count) videos=\(systemPhotos.lazy.filter(\.isVideo).count) scan=\(systemScanCount)")
                        }
                        #endif
                    }
                }
                if !pending.isEmpty {
                    systemPhotos.append(contentsOf: pending)
                    for item in pending {
                        systemPhotoIndex[item.id] = item
                    }
                }
            }

            let result = await scanTask.value
            guard token == systemLoadToken else { return }
            switch result {
            case .success(let payload):
                applySystemSnapshot(payload.snapshot, at: url)
                SystemLibraryCache.save(payload.snapshot, maxAssets: limit, for: url)
                notifyIfSystemLibraryTruncated()
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
            systemDuplicateGroupsCacheKey = nil
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
        systemDuplicateGroupsCacheKey = nil
    }

    /// 把拾光的补充元数据叠加到官方「照片」图库的照片上（收藏 / 隐藏 / 关键词 / 标题 / 查看时间）。
    /// 只影响拾光自己的展示，不修改 `Photos.sqlite`。
    func applySystemOverlay(_ photo: PhotoItem) -> PhotoItem {
        guard isNativeContainer, let overlay = systemOverlays[photo.id] else { return photo }
        var item = photo
        if let favorite = overlay.isFavorite { item.isFavorite = favorite }
        if let hidden = overlay.isHidden { item.isHidden = hidden }
        if let keywords = overlay.keywords { item.keywords = keywords }
        if let title = overlay.title { item.title = title }
        if let viewed = overlay.viewedAt { item.viewedAt = viewed }
        return item
    }

    /// 系统图库一次载入上限（0 表示不限制），随当前图库保存。
    var systemAssetLimit: Int {
        max(0, AppSettings.shared.systemLibraryMaxAssets)
    }

    /// 截断加载时提示实际总数。
    func notifyIfSystemLibraryTruncated() {
        guard systemIsTruncated, systemTotalAssetCount > 0 else { return }
        showToast("已载入最近 \(systemPhotos.count.formatted()) 项（共 \(systemTotalAssetCount.formatted()) 项），可在设置中调整上限")
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
        systemAlbums.filter { $0.assetIDs.contains(id) }.map { $0.name }
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
        guard let album = systemAlbums.first(where: { $0.id == albumID }) else { return }
        let targets = album.assetIDs.compactMap { systemPhoto(id: $0) }
        guard !targets.isEmpty else {
            showToast("该相簿里没有可拷贝的项目")
            return
        }
        importSystemPhotos(targets, albumName: album.name)
    }

    /// 递归收集系统文件夹（含子文件夹与其相簿）里的所有项目 ID。
    func systemFolderAssetIDs(_ folderID: Int64) -> [UUID] {
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

    func importSystemFolderToLibrary(_ folderID: Int64) {
        guard let folder = systemFolders.first(where: { $0.id == folderID }) else { return }
        let targets = systemFolderAssetIDs(folderID).compactMap { systemPhoto(id: $0) }
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
