import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

extension LibraryStore {
    // MARK: - 外接盘变化

    /// 监听卷卸载：正在浏览的外接图库被拔掉时自动退回「图库」，
    /// 连接记录保留（重新插上还能点回来），并清掉官方库判断的缓存。
    func observeVolumeRemoval() {
        guard volumeRemovalObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        volumeRemovalObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification,
                                                         object: nil,
                                                         queue: .main) { [weak self] _ in
            LibraryPaths.invalidateNativeCache()
            Task { @MainActor in self?.handleVolumeRemoval() }
        })
    }

    /// 卷卸载后的降级：不要把界面停在一个已经不存在的图库上。
    func handleVolumeRemoval() {
        if let path = systemLibraryPath, !FileManager.default.fileExists(atPath: path) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            showToast("「\(name)」所在的磁盘已断开，已切回图库")
            if isSystemScope { navigate(to: .library) }
            resetSystemLibraryState()
            metadataStore?.setSetting("system_library_path", nil)
        }
        if let container = LibraryPaths.containerLibraryURL,
           !LibraryPaths.isLibraryContainer(container) {
            showToast("当前图库所在的外置盘已断开，请重新连接后再继续操作")
        }
    }

    /// 点击侧边栏里的系统图库：已加载过就只切回页面，不重复扫描。
    func activateSystemLibrary(_ ref: SystemLibraryRef) {
        guard FileManager.default.fileExists(atPath: ref.path) else {
            // 外置盘没插时不能把连接记录删掉，否则重新插上就找不回来了。
            showToast("找不到「\(ref.name)」，可能已被移动、删除，或外置盘未连接")
            return
        }
        // 旧数据里可能把「自己」登记成了一条连接：切回自己并清掉那条重复记录。
        if isContainerNativeLibraryPath(ref.path) {
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, ref.path) }
            persistSystemLibraries(systemLibraries)
            connectSystemLibrary(URL(fileURLWithPath: ref.path))
            return
        }
        connectSystemLibrary(URL(fileURLWithPath: ref.path))
    }

    /// 在系统「照片」中打开指定的系统图库。
    func openSystemLibraryInPhotos(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 选择器里列出的图库：当前图库、所有打开过的图库（含外置盘上的）、最近打开过的，
    /// 以及「图片」文件夹里的 .photoslibrary。与侧边栏的「全部图库」共用同一份记录。
    func knownLibraryEntries() -> [LibraryEntry] {
        var urls: [URL] = []
        if let current = LibraryPaths.containerLibraryURL {
            urls.append(current)
        }
        urls.append(contentsOf: knownLibraries.map { URL(fileURLWithPath: $0.path) })
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
                                        isCurrent: LibraryPaths.containerLibraryURL?.standardizedFileURL.path == path,
                                        isDefault: isExplicitDefaultLibrary(path)))
        }

        entries.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        }
        return entries
    }

    /// 打开任意 .photoslibrary（含官方「照片」图库）：都以这个图库为准切换，
    /// 展示它自己的内容，之后的导入、编辑与设置都写入它自己的数据库。
    func activateLibrary(_ url: URL) {
        // 失效的图库（目录被移动 / 删除，或外置盘没插）绝不能进入切换流程：
        // 切换失败会把界面留在半截状态，看起来像图库和侧边栏一起消失了。
        guard LibraryPaths.isLibraryContainer(url) else {
            let name = url.deletingPathExtension().lastPathComponent
            showToast(name.isEmpty
                      ? "找不到这个图库，可能已被移动或删除"
                      : "找不到「\(name)」，可能已被移动、删除，或外置盘未连接")
            return
        }
        // 选择器窗口的关闭放在 switchLibraryContainer 成功之后：
        // 切换失败（只读 / 无权限）时保留选择器，用户可以直接换一个库再试。
        switchLibraryContainer(url)
    }

    // MARK: - 官方图库照片的补充元数据

    /// 当前是否允许给官方「照片」图库的照片写拾光的补充元数据。
    var canEditNativeOverlay: Bool { isNativeContainer }

    /// 原生导入完成后写拾光侧的第二份元数据：系统侧由 PhotoKit 写，这里只补标题。
    func recordSystemImportOverlay(assetID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveSystemOverlay(assetID) { overlay in
            if (overlay.title ?? "").isEmpty { overlay.title = trimmed }
        }
    }

    func updateSystemPhoto(_ id: UUID, mutate: (inout PhotoItem) -> Void) {
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

    func saveSystemOverlay(_ id: UUID, mutate: (inout AssetOverlay) -> Void) {
        guard let store = metadataStore else { return }
        // 覆盖元数据变了：窗口缓存里的旧对象要作废，下次读取才会带上新的收藏 / 隐藏状态。
        systemRecentPhotos[id] = nil
        var overlay = systemOverlays[id] ?? AssetOverlay()
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
        guard writeBack else {
            // 挂载的其它照片图库完全只读：收藏只记录在拾光，不碰原库。
            showToast(favorite ? "已收藏（仅记录在拾光：此图库只读）" : "已取消收藏（仅记录在拾光）")
            return
        }
        runSystemStructureWrite { [self] in
            guard await prepareSystemLibraryWrite() else {
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = favorite } }
                return
            }
            do {
                try await PhotoKitBridge.setFavorite(favorite, assetIDs: Array(ids))
                // 写回成功后清掉拾光覆盖值，以「照片」为准。
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = nil } }
                self.systemFavoritesRevision &+= 1
                self.showToast(favorite ? "已加入收藏，并同步到「照片」" : "已取消收藏，并同步到「照片」")
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
        runSystemStructureWrite { [self] in
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
        var overlay = systemOverlays[id] ?? AssetOverlay()
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
        // 同一个库已经加载好（或正在加载）：只切页面，不重扫。
        // 「重新读取」传 forceRefresh 才会重建索引。
        if !forceRefresh {
            if isLoadingSystemLibrary { return }
            if systemIndex != nil,
               let loaded = systemLibraryLoadedPath,
               isSameSystemLibraryPath(loaded, url.path) {
                return
            }
        }
        // 打开系统图库默认展示「所有照片」全量网格，并按图库原始顺序（拍摄日期从新到旧）排列。
        if grouping != .all { grouping = .all }
        if sortKey != .capturedAt || sortAscending {
            sortKey = .capturedAt
            sortAscending = false
        }
        // 当前图库就是官方图库时，先从它自己的 Luma.sqlite 读回拾光的补充元数据。
        // 浏览外接图库时不能把 App 自己图库的收藏 / 评分 / 关键词套过去。
        if isNativeContainer, systemLibraryPath == nil || isBrowsingContainerSystemLibrary {
            systemOverlays = metadataStore?.loadOverlays() ?? [:]
        } else {
            systemOverlays = [:]
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
        systemWindowPageCache.removeAll()
        systemWindowPageCacheOrder.removeAll()
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
    func drainSystemBatches(_ stream: AsyncStream<[PhotoItem]>,
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
        // 全文搜索索引：后台低优先级建立，成功后搜索从「全表 LIKE 两分钟」变成「0.3 秒」。
        startSystemSearchIndexWarmup(index)
        // 载入完成后再判定一次：挂载的其它照片图库在这里被标成只读。
        refreshSystemWriteTargetState()
        // 跨图库搜索点开的条目：目标系统图库的索引到这一刻才真正可用。
        consumePendingLibraryOpenIfReady()
    }

    /// 后台建立系统图库的全文搜索索引，并把进度同步到界面。
    ///
    /// 索引未就绪时搜索会退回全表 `LIKE '%词%'`（137 万行要两分钟），
    /// 所以这里在打开图库时就低优先级开始建，建完再通知网格刷新（此前搜索显示 0 条）。
    func startSystemSearchIndexWarmup(_ index: SystemIndex) {
        searchIndexWarmupTask?.cancel()
        searchIndexWarmupTask = nil
        guard let search = index.searchIndex else {
            isBuildingSystemSearchIndex = false
            systemSearchIndexProgress = nil
            return
        }
        if search.isReady {
            isBuildingSystemSearchIndex = false
            systemSearchIndexProgress = nil
            return
        }
        isBuildingSystemSearchIndex = true
        systemSearchIndexProgress = search.buildProgress
        index.startSearchIndexWarmup()
        searchIndexWarmupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if search.isReady {
                    self.isBuildingSystemSearchIndex = false
                    self.systemSearchIndexProgress = nil
                    // 索引就绪：之前在建立期间搜索显示为空，这里让带搜索词的分页重取一次。
                    self.systemSearchIndexRevision &+= 1
                    return
                }
                self.isBuildingSystemSearchIndex = search.isBuilding
                self.systemSearchIndexProgress = search.isBuilding ? search.buildProgress : nil
            }
        }
    }

    /// 系统图库当前搜索是否因索引未就绪而暂时无法给出结果。
    /// 界面据此显示「正在建立搜索索引」而不是「没有找到照片」。
    var isSystemSearchIndexPending: Bool {
        isBuildingSystemSearchIndex
            && isSystemScope
            && !(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// 长曝光 / 电影效果只能通过 PhotoKit 智能相簿取 ID；仅对当前官方图库有效。
    /// 这里绝不申请权限：浏览网络资源、网络电视等页面也会走到导航收尾，
    /// 授权只由用户主动打开系统图库时申请。
    func loadPhotoKitMediaTypesIfNeeded() {
        guard isNativeContainer,
              PhotoKitBridge.hasReadWritePermission,
              !isPhotoKitMediaTypeLoaded else { return }
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
            self.photoKitRAWIDs = ids.raw
            self.photoKitScreenRecordingIDs = ids.screenRecording
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
        refreshSystemWriteTargetState()
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
                                             overlays: [UUID: AssetOverlay],
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
    nonisolated static func applyAssetOverlay(_ overlay: AssetOverlay?,
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

    /// 批量相簿封面：相簿墙一次取当前层全部相簿（含文件夹子树）的封面。
    /// 196 本相簿逐个查询实测要好几秒，这里每 400 本一批、边取边回传。
    func systemAlbumPreviewPhotosBatch(_ albumIDs: [Int64], limit: Int,
                                       onPartial: (([Int64: [PhotoItem]]) -> Void)? = nil) async
        -> [Int64: [PhotoItem]] {
        guard limit > 0, !albumIDs.isEmpty else { return [:] }
        var result: [Int64: [PhotoItem]] = [:]
        var missing: [Int64] = []
        if let index = systemIndex {
            for id in albumIDs {
                if let cached = index.cachedAlbumPreviewPhotos(id, limit: limit) {
                    result[id] = cached.map { applySystemOverlay($0) }
                } else {
                    missing.append(id)
                }
            }
        } else {
            missing = albumIDs
        }
        guard let index = systemIndex else {
            // 索引还没就绪：走内存快照路径（数量很小）。
            for id in missing {
                result[id] = systemAlbumPreviewPhotos(id, limit: limit)
            }
            if !result.isEmpty { onPartial?(result) }
            return result
        }
        guard !missing.isEmpty else { return result }
        let overlays = systemOverlays
        let nativeKeywords = systemNativeKeywordIDMap
        let native = isNativeContainer
        var start = 0
        while start < missing.count {
            let end = min(start + 400, missing.count)
            let chunk = Array(missing[start..<end])
            let part = await Task.detached(priority: .userInitiated) {
                index.albumPreviewPhotosBatch(chunk, limit: limit)
            }.value
            guard !Task.isCancelled else { return result }
            var chunkResult: [Int64: [PhotoItem]] = [:]
            for (id, photos) in part {
                chunkResult[id] = photos.map {
                    Self.applyingOverlays($0, overlays: overlays, nativeKeywords: nativeKeywords, isNative: native)
                }
            }
            result.merge(chunkResult) { _, new in new }
            onPartial?(chunkResult)
            start = end
        }
        return result
    }

    /// 一组文件夹各自子树里的相簿 ID（一次构建父子表，避免逐个文件夹重复递归）。
    func systemAlbumIDsByFolder(_ folderIDs: [Int64]) -> [Int64: [Int64]] {
        guard !folderIDs.isEmpty else { return [:] }
        var childrenByParent: [Int64: [Int64]] = [:]
        for folder in systemFolders {
            guard let parent = folder.parent else { continue }
            childrenByParent[parent, default: []].append(folder.id)
        }
        var albumsByFolder: [Int64: [Int64]] = [:]
        for album in systemAlbums {
            guard let parent = album.parentFolder else { continue }
            albumsByFolder[parent, default: []].append(album.id)
        }
        var result: [Int64: [Int64]] = [:]
        for folderID in folderIDs {
            var seen: Set<Int64> = [folderID]
            var queue: [Int64] = [folderID]
            var albums: [Int64] = []
            while let current = queue.popLast() {
                albums.append(contentsOf: albumsByFolder[current] ?? [])
                for child in childrenByParent[current] ?? [] where seen.insert(child).inserted {
                    queue.append(child)
                }
            }
            result[folderID] = albums
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
    /// 结果按结构版本缓存：侧边栏滚动时每个可见行都会问一次，不能每帧都查库。
    func systemAlbumPhotoCount(_ albumID: Int64) -> Int {
        if systemAlbumCountCacheRevision != systemStructureRevision {
            systemAlbumCountCache.removeAll(keepingCapacity: true)
            systemAlbumCountCacheRevision = systemStructureRevision
        }
        if let cached = systemAlbumCountCache[albumID] { return cached }
        let count: Int
        if let index = systemIndex {
            count = index.albumAssetCount(albumID)
        } else {
            count = systemAlbum(id: albumID)?.assetIDs.count ?? 0
        }
        systemAlbumCountCache[albumID] = count
        return count
    }

    /// 侧边栏相簿是否为空。
    func systemAlbumIsEmpty(_ albumID: Int64) -> Bool {
        // 扫描 / 建索引期间相簿成员还没读完：不显示「空相簿」标记，避免误判。
        if systemIndex == nil, isLoadingSystemLibrary { return false }
        return systemAlbumPhotoCount(albumID) == 0
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
                // 统一走 IngestService 的本地文件入口，不再直接调 ImportService。
                let service = ingestService
                let item = await Task.detached(priority: .userInitiated) {
                    try? service.importLocalFile(URL(fileURLWithPath: path))
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
