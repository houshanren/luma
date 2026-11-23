import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

extension LibraryStore {
    // MARK: - Network storage (WebDAV)

    /// 切换图库：网盘挂载、目录缓存与云端收藏都属于上一个图库，必须先清空再读新库，
    /// 否则旧挂载会被当成新库的连接写回它的 settings。
    func resetCloudStateForLibrarySwitch() {
        cloudLoadToken += 1
        cloudModel.scanLoadToken += 1
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.refreshLoopTask?.cancel()
        cloudModel.refreshLoopTask = nil
        cloudModel.isRestoringScan = false
        cloudMounts = []
        cloudFolders = []
        cloudPhotos = []
        cloudPath = ""
        cloudTrail = []
        cloudError = nil
        cloudBusyText = nil
        cloudSheetMount = nil
        cloudVisibleCacheKey = nil
        cloudVisibleCacheValue = []
        cloudDirectoryCache.removeAll()
        CloudCredentials.clearCache()
        cloudFavorites = []
        resetCloudAlbumScan()
        resetCloudInsight()
    }

    // MARK: - 网盘图库（自动扫描 + 文件夹相簿）

    /// 当前是否正在扫描整个网盘；工具栏与浮层据此显示进度。
    var isCloudScanning: Bool { cloudModel.scanPhase.isScanning }
    var cloudScanFolderCount: Int { cloudModel.scanFolderCount }
    var cloudSelectedFolderPath: String? { cloudModel.selectedFolderPath }
    var cloudOverviewSection: CloudOverviewSection? { cloudModel.overview }
    /// 面包屑根节点 ID（百度为 "/"，其余为 ""）。
    var cloudBreadcrumbRootID: String { cloudBreadcrumbChain.first?.id ?? "" }

    /// 根目录标识：百度用 "/"，其余用 ""。
    func cloudRootPath(for mount: CloudMount) -> String {
        mount.kind == .baidu ? "/" : ""
    }

    /// 探测一个存储是否可连通：与打开网盘走同一条 `CloudService.list`，只读根目录，
    /// 不写索引、不改当前浏览目录，因此可以在总览页对多个存储并发检测。
    func probeCloudMount(_ mount: CloudMount) async -> SourceHealth {
        let started = Date()
        do {
            _ = try await CloudService.list(mount: mount, containerID: cloudRootPath(for: mount))
            return SourceHealth(state: .healthy,
                                checkedAt: Date(),
                                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            let message = error.localizedDescription
            if let oauth = error as? CloudOAuthError, oauth.requiresReauth {
                return SourceHealth(state: .authRequired, checkedAt: Date(), message: message)
            }
            return SourceHealth(state: .offline, checkedAt: Date(), message: message)
        }
    }

    /// 连通性检测 + 任务中心登记：总览页的「检测状态」与单卡右键都走这里，
    /// 侧边栏「后台任务」能看到「健康检测 · 网盘名」的进行中状态与结果。
    func runCloudHealthCheck(_ mount: CloudMount) async -> SourceHealth {
        if let running = cloudModel.mountHealth[mount.id], running.state == .checking {
            return running
        }
        cloudModel.mountHealth[mount.id] = SourceHealth(state: .checking, checkedAt: Date())
        let job = SourceJob(sourceID: .cloud(mount.id),
                            kind: .connectivity,
                            title: "检测「\(mount.name)」",
                            isCancellable: false)
        let jobID = beginSourceJob(job)
        updateSourceJob(jobID, message: "正在连接…")
        let health = await probeCloudMount(mount)
        cloudModel.mountHealth[mount.id] = health
        switch health.state {
        case .healthy:
            let latency = health.latencyMilliseconds.map { " · \($0) ms" } ?? ""
            finishSourceJob(jobID, message: "在线" + latency)
        case .authRequired:
            failSourceJob(jobID, message: health.message ?? "需要重新授权")
        default:
            failSourceJob(jobID, message: health.message ?? "连接失败")
        }
        return health
    }

    /// 当前选中文件夹的面包屑链（第一项是整个网盘）。
    var cloudBreadcrumbChain: [CloudCrumb] {
        guard let mount = cloudMount(for: currentCloudMountID) else { return [] }
        let rootPath = cloudRootPath(for: mount)
        let crumbs = [CloudCrumb(id: rootPath, name: mount.name)]
        guard let selected = cloudModel.selectedFolderPath else { return crumbs }
        var byPath: [String: CloudScanFolder] = [:]
        for folder in cloudModel.scanFolders where byPath[folder.path] == nil {
            byPath[folder.path] = folder
        }
        var chain: [CloudScanFolder] = []
        var cursor: String? = selected
        while let path = cursor, path != rootPath, let folder = byPath[path] {
            chain.append(folder)
            cursor = folder.parentPath
        }
        return crumbs + chain.reversed().map { CloudCrumb(id: $0.path, name: $0.name) }
    }

    /// 侧边栏「相簿」的顶层文件夹（文件夹 = 相簿），带聚合数量与封面。
    ///
    /// 扫描完成后直接读 SQLite 聚合表（目录数最多一千出头，一条 JOIN 即可），
    /// 不再对两万张照片做「向上累计 + 找封面」的全量遍历；
    /// 扫描过程中只展示目录结构，数量 / 封面等扫描结束再出现。
    var cloudRootFolders: [CloudFolderNode] {
        guard let mount = cloudMount(for: currentCloudMountID) else { return [] }
        let rootPath = cloudRootPath(for: mount)
        let scanning = cloudModel.scanPhase.isScanning
        let key = [
            mount.id.uuidString,
            String(cloudModel.scanFolders.count),
            String(cloudModel.scanPhotos.count),
            String(cloudModel.cloudIndexRevision),
            scanning ? "1" : "0"
        ].joined(separator: "\u{1F}")
        if cloudFolderTreeCacheKey == key { return cloudFolderTreeCacheValue }

        let tree: [CloudFolderNode]
        if scanning {
            tree = buildScanningFolderTree(rootPath: rootPath)
        } else if let rows = metadataStore?.loadCloudIndexFolders(mountID: mount.id), !rows.isEmpty {
            tree = buildFolderTree(rows: rows, mount: mount, rootPath: rootPath)
        } else {
            tree = buildCloudFolderTree(rootPath: rootPath)
        }
        cloudFolderTreeCacheKey = key
        cloudFolderTreeCacheValue = tree
        return tree
    }

    /// 扫描期间只建目录结构：不统计照片、不选封面，避免每批扫描都做 O(n·depth) 遍历。
    private func buildScanningFolderTree(rootPath: String) -> [CloudFolderNode] {
        var childrenByParent: [String: [CloudScanFolder]] = [:]
        for folder in cloudModel.scanFolders where folder.path != rootPath {
            childrenByParent[folder.parentPath, default: []].append(folder)
        }
        func makeNode(_ folder: CloudScanFolder) -> CloudFolderNode {
            let children = (childrenByParent[folder.path] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return CloudFolderNode(path: folder.path,
                                   name: folder.name,
                                   parentPath: folder.parentPath,
                                   photoCount: 0,
                                   cover: nil,
                                   children: children.map(makeNode))
        }
        return (childrenByParent[rootPath] ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(makeNode)
    }

    /// 从 SQLite 聚合行建树：子树数量 = 自身直属数量 + 子节点数量，封面优先自身、否则取子目录。
    private func buildFolderTree(rows: [MetadataStore.CloudIndexFolderRow],
                                 mount: CloudMount,
                                 rootPath: String) -> [CloudFolderNode] {
        var childrenByParent: [String: [MetadataStore.CloudIndexFolderRow]] = [:]
        childrenByParent.reserveCapacity(rows.count)
        for row in rows where row.path != rootPath {
            childrenByParent[row.parentPath, default: []].append(row)
        }
        func makeNode(_ row: MetadataStore.CloudIndexFolderRow) -> CloudFolderNode {
            let children = (childrenByParent[row.path] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let childNodes = children.map(makeNode)
            let count = row.mediaCount + childNodes.reduce(0) { $0 + $1.photoCount }
            var cover = row.coverRecord.map { albumPhoto(record: $0, mount: mount) }
            if cover == nil {
                cover = childNodes.first(where: { $0.cover != nil })?.cover
            }
            return CloudFolderNode(path: row.path,
                                   name: row.name,
                                   parentPath: row.parentPath,
                                   photoCount: count,
                                   cover: cover,
                                   children: childNodes)
        }
        return (childrenByParent[rootPath] ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(makeNode)
    }

    private func buildCloudFolderTree(rootPath: String) -> [CloudFolderNode] {
        var childrenByParent: [String: [CloudScanFolder]] = [:]
        var parentOf: [String: String] = [:]
        for folder in cloudModel.scanFolders {
            parentOf[folder.path] = folder.parentPath
            guard folder.path != rootPath else { continue }
            childrenByParent[folder.parentPath, default: []].append(folder)
        }

        // 照片按目录向上累计，顺便取每个目录最新一张做封面。
        var counts: [String: Int] = [:]
        var covers: [String: PhotoItem] = [:]
        for photo in cloudModel.scanPhotos {
            guard let path = photo.cloudPath,
                  let folder = cloudModel.scanMediaFolder[path] else { continue }
            var cursor: String? = folder
            while let current = cursor, current != rootPath, parentOf[current] != nil {
                counts[current, default: 0] += 1
                if covers[current] == nil { covers[current] = photo }
                cursor = parentOf[current]
            }
        }

        func makeNode(_ folder: CloudScanFolder) -> CloudFolderNode {
            let children = (childrenByParent[folder.path] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return CloudFolderNode(path: folder.path,
                                   name: folder.name,
                                   parentPath: folder.parentPath,
                                   photoCount: counts[folder.path] ?? 0,
                                   cover: covers[folder.path],
                                   children: children.map(makeNode))
        }

        return (childrenByParent[rootPath] ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(makeNode)
    }

    /// 选中一个文件夹相簿；`nil` 表示回到整个网盘。
    func selectCloudFolder(path: String?) {
        // 与 `navigate(to:)` 一致：点当前相簿也把搜索 / 筛选 / 选择回正。
        clearTransientBrowsingState()
        guard cloudModel.selectedFolderPath != path else { return }
        cloudModel.selectedFolderPath = path
        cloudModel.overview = nil
        cloudModel.scope = .all
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        if let mountID = currentCloudMountID {
            presentCloudAlbumPhotos(mountID: mountID)
        }
    }

    /// 回到整个网盘的照片列表，但保持当前范围 / 总览状态（由调用方决定）。
    /// 与拾光一致：媒体类型、更多项目与分区总览都是整库口径，不受当前相簿限制。
    func showCloudRootPhotos() {
        guard cloudModel.selectedFolderPath != nil,
              let mountID = currentCloudMountID else { return }
        cloudModel.selectedFolderPath = nil
        presentCloudAlbumPhotos(mountID: mountID)
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
    }

    /// 打开挂载的网盘图库：先显示上次扫描快照，再按需在后台续扫。
    /// - Parameter refreshIfStale: 传入秒数时，索引超过该时长就立刻做一次增量扫描（影院入口用）。
    func openCloudAlbum(_ mount: CloudMount, refreshIfStale: TimeInterval? = nil) {
        cloudModel.pendingRefreshMaxAge = refreshIfStale
        if cloudModel.scanMountID != mount.id {
            cancelCloudAlbumScan()
            cloudModel.scanPhotos = []
            cloudModel.scanFolders = []
            cloudModel.scanMediaFolder = [:]
            cloudModel.scanPhotoPaths = []
            cloudModel.scanFolderPaths = []
            cloudModel.thumbnailPrefetchTask?.cancel()
            cloudModel.thumbnailPrefetchTask = nil
            cloudModel.pendingPhotoUpdates.removeAll()
            cloudModel.metadataDirty = false
            cloudModel.featuresLoadedMountID = nil
            cloudModel.isLoadingCloudFeatures = false
            cloudModel.scanSnapshot = nil
            cloudModel.selectedFolderPath = nil
            cloudModel.scanMountID = mount.id
            cloudModel.scanIndexPersistedFolderCount = 0
            cloudModel.lastPublishedScanMediaCount = -1
            cloudModel.scanLoadToken += 1
            cloudScopeCountsCache = CloudScopeCounts()
            cloudScopeCountsCacheKey = nil
        }
        cloudPath = cloudRootPath(for: mount)
        cloudTrail = [CloudCrumb(id: cloudPath, name: mount.name)]
        cloudFolders = []
        cloudError = nil
        cloudLoading = false
        cloudBusyText = nil
        cloudModel.overview = nil

        if !cloudModel.scanPhotos.isEmpty {
            cloudModel.scanMediaCount = cloudModel.scanPhotos.count
            presentCloudAlbumPhotos(mountID: mount.id)
            finishCloudAlbumOpen(mountID: mount.id)
            return
        }

        // 从 SQLite 索引恢复上次扫描结果：查询 + 映射都放到后台，避免打开网盘时卡主线程。
        cloudModel.scanLoadToken += 1
        let token = cloudModel.scanLoadToken
        let signature = Self.scopeSignature(mount)
        let store = metadataStore
        let favorites = cloudFavorites
        let keywords = cloudKeywords
        let marks = cloudMarks
        let viewedAt = cloudModel.viewedAt
        cloudModel.isRestoringScan = true
        cloudModel.scanPhase = .idle
        let restoreJobID = beginSourceJob(
            SourceJob(sourceID: .cloud(mount.id), kind: .index, title: "恢复网盘索引", isCancellable: false)
        )
        Task { [weak self] in
            guard let self else { return }
            let restored = await Task.detached(priority: .userInitiated) {
                Self.loadCloudAlbumSnapshotAndPhotos(store: store,
                                                     mount: mount,
                                                     signature: signature,
                                                     favorites: favorites,
                                                     keywords: keywords,
                                                     marks: marks,
                                                     viewedAt: viewedAt)
            }.value
            guard token == self.cloudModel.scanLoadToken,
                  self.cloudModel.scanMountID == mount.id else {
                self.cancelSourceJob(restoreJobID)
                return
            }
            self.cloudModel.isRestoringScan = false
            if let (snapshot, photos) = restored {
                self.applyCloudAlbumSnapshot(snapshot, photos: photos, mount: mount)
                self.finishSourceJob(restoreJobID,
                                     message: "已恢复 \(photos.count.formatted()) 项媒体 · \(snapshot.folderCount.formatted()) 个目录")
            } else {
                self.cloudPhotos = []
                self.cloudVisibleCacheKey = nil
                self.cloudScopeCountsCacheKey = nil
                self.cloudModel.scanPhase = .idle
                self.finishSourceJob(restoreJobID, message: "没有可恢复的索引")
            }
            self.finishCloudAlbumOpen(mountID: mount.id)
        }
    }

    /// 索引恢复完成后的入口：默认沿用 10 分钟自动重扫；影院入口要求更严格的新鲜度时立刻增量。
    private func finishCloudAlbumOpen(mountID: UUID) {
        if let maxAge = cloudModel.pendingRefreshMaxAge {
            cloudModel.pendingRefreshMaxAge = nil
            refreshCloudIndexIfNeeded(mountID: mountID, maxAge: maxAge)
        } else {
            startCloudAlbumScanIfNeeded(mountID: mountID)
        }
        startCloudIndexRefreshLoop(mountID: mountID)
    }

    /// 停留在当前网盘 / 影院时，每 3 分钟合并做一次增量扫描；离开该挂载后自动结束。
    private func startCloudIndexRefreshLoop(mountID: UUID) {
        cloudModel.refreshLoopTask?.cancel()
        cloudModel.refreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.currentCloudMountID == mountID else { return }
                self.ensureCloudIndexFresh(for: mountID, maxAge: 120)
            }
        }
    }

    /// 索引超过 `maxAge` 就做一次增量扫描；不满足时什么都不做。
    private func refreshCloudIndexIfNeeded(mountID: UUID, maxAge: TimeInterval) {
        guard cloudModel.scanMountID == mountID,
              !cloudModel.scanPhase.isScanning else { return }
        let fresh: Bool
        if case .finished(let date) = cloudModel.scanPhase {
            fresh = Date().timeIntervalSince(date) < maxAge
        } else if let state = metadataStore?.loadCloudIndexState(mountID: mountID) {
            fresh = Date().timeIntervalSince(state.updatedAt) < maxAge
        } else {
            fresh = false
        }
        if fresh { return }
        beginCloudAlbumScan(mountID: mountID)
    }

    /// 影院 / 网盘入口：保证索引在 `maxAge` 秒内是新鲜的。
    /// 没有打开过这个挂载时先异步恢复索引（后台线程），恢复完成后再按阈值增量扫描。
    func ensureCloudIndexFresh(for mountID: UUID, maxAge: TimeInterval = 60) {
        guard cloudMount(for: mountID) != nil,
              !cloudModel.scanPhase.isScanning,
              !cinemaScrapeRunning else { return }
        if cloudModel.scanMountID == mountID, !cloudModel.scanPhotos.isEmpty {
            refreshCloudIndexIfNeeded(mountID: mountID, maxAge: maxAge)
        } else if let mount = cloudMount(for: mountID) {
            openCloudAlbum(mount, refreshIfStale: maxAge)
        }
    }

    /// App 回到前台时调用：只处理当前正在看的网盘 / 网盘影院。
    func refreshCurrentCloudIndexIfNeeded() {
        switch sidebarItem {
        case .cloudMount(let id), .cloudCinema(let id):
            ensureCloudIndexFresh(for: id, maxAge: 60)
        default:
            break
        }
    }

    /// 索引读取 + 记录映射都在后台完成：两万条记录不会卡住主线程。
    private nonisolated static func loadCloudAlbumSnapshotAndPhotos(store: MetadataStore?,
                                                                    mount: CloudMount,
                                                                    signature: String,
                                                                    favorites: Set<String>,
                                                                    keywords: [String: [String]],
                                                                    marks: [String: CloudMark],
                                                                    viewedAt: [UUID: Date])
        -> (CloudScanSnapshot, [PhotoItem])? {
        guard let snapshot = loadCloudAlbumSnapshot(store: store,
                                                   mountID: mount.id,
                                                   signature: signature) else { return nil }
        let photos = snapshot.records.map {
            albumPhoto(record: $0,
                       mount: mount,
                       favorites: favorites,
                       keywords: keywords,
                       marks: marks,
                       viewedAt: viewedAt)
        }
        return (snapshot, photos)
    }

    /// 把索引 / 旧版快照恢复出来的清单灌回内存。
    private func applyCloudAlbumSnapshot(_ snapshot: CloudScanSnapshot,
                                         photos: [PhotoItem],
                                         mount: CloudMount) {
        cloudModel.scanSnapshot = snapshot
        cloudModel.scanPhotos = photos
        cloudModel.scanFolders = snapshot.folders ?? []
        var mediaFolders: [String: String] = [:]
        mediaFolders.reserveCapacity(snapshot.records.count)
        for record in snapshot.records {
            if let folder = record.folderPath { mediaFolders[record.path] = folder }
        }
        cloudModel.scanMediaFolder = mediaFolders
        cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
        cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
        cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
        cloudModel.scanFolderCount = snapshot.folderCount
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        cloudModel.scanTruncated = snapshot.truncated
        cloudModel.scanPhase = .finished(snapshot.savedAt)
        presentCloudAlbumPhotos(mountID: mount.id)
        migrateLegacyCloudSnapshotIfNeeded(snapshot, mount: mount)
    }

    /// 旧版把整份扫描结果放在 `derived_reports` 的 JSON 里：第一次打开时顺手迁进索引表，
    /// 之后就走 SQLite 聚合查询，不再解析大 JSON。
    private func migrateLegacyCloudSnapshotIfNeeded(_ snapshot: CloudScanSnapshot, mount: CloudMount) {
        guard let store = metadataStore,
              store.loadCloudIndexState(mountID: mount.id) == nil,
              !snapshot.records.isEmpty else { return }
        var folders = snapshot.folders ?? []
        if folders.isEmpty {
            folders = [CloudScanFolder(path: cloudRootPath(for: mount), name: mount.name, parentPath: "")]
        }
        store.saveCloudIndexBatch(mountID: mount.id,
                                  generation: 0,
                                  folders: folders,
                                  assets: snapshot.records)
        if snapshot.complete == true {
            store.setSetting(Self.cloudDeepScanSettingKey(mount.id),
                             String(snapshot.savedAt.timeIntervalSince1970))
        }
        store.finalizeCloudIndex(mountID: mount.id,
                                 state: MetadataStore.CloudIndexState(
                                    folderCount: snapshot.folderCount,
                                    mediaCount: snapshot.records.count,
                                    truncated: snapshot.truncated,
                                    complete: snapshot.complete ?? false,
                                    pathVersion: Self.cloudSnapshotPathVersion,
                                    scopeSignature: Self.scopeSignature(mount),
                                    updatedAt: snapshot.savedAt)) { [weak self] in
            guard let self else { return }
            self.cloudModel.cloudIndexRevision += 1
            self.cloudFolderTreeCacheKey = nil
        }
    }

    /// 快照超过 10 分钟才自动重扫：反复点同一个网盘不会一直拉目录。
    private static let cloudAlbumRescanInterval: TimeInterval = 10 * 60

    func startCloudAlbumScanIfNeeded(mountID: UUID) {
        guard currentCloudMountID == mountID else { return }
        switch cloudModel.scanPhase {
        case .scanning:
            return
        case .cancelled, .failed:
            // 用户主动停止 / 上次失败时不自动重启，等他点「重新扫描」。
            return
        case .finished(let date):
            guard Date().timeIntervalSince(date) >= Self.cloudAlbumRescanInterval else { return }
        case .idle:
            break
        }
        beginCloudAlbumScan(mountID: mountID)
    }

    /// 重新扫描整个挂载（手动刷新 / 首次进入）。
    /// - Parameter forceFull: 手动刷新时强制全量，确保能看到文件内容级别的变化；自动重扫允许增量。
    func beginCloudAlbumScan(mountID: UUID, forceFull: Bool = false) {
        guard let mount = cloudMount(for: mountID) else { return }
        cancelCloudAlbumScan()
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.scanMountID = mountID
        if let oldJob = cloudModel.scanJobID {
            cancelSourceJob(oldJob)
        }
        let scanJob = SourceJob(sourceID: .cloud(mountID), kind: .scan, title: "扫描 \(mount.name)")
        cloudModel.scanJobID = beginSourceJob(scanJob, cancel: { [weak self] in
            Task { @MainActor in
                // 只有这个任务仍是当前扫描时才停：重启扫描时旧任务的取消不应打断新扫描。
                guard let self, self.cloudModel.scanJobID == scanJob.id else { return }
                self.stopCloudAlbumScan()
            }
        })
        cloudModel.scanPhase = .scanning
        cloudModel.scanTruncated = false
        cloudModel.isRestoringScan = false

        // 增量：上一轮完整、未触顶、24 小时内，且目录修改时间可用。
        // 只跳过父目录列表里 mtime 未变的子树；任何不确定都会正常扫描。
        var plan: CloudScanner.IncrementalPlan?
        var planFromSQL = false
        if !forceFull, let store = metadataStore,
           let made = Self.makeIncrementalPlan(store: store, mountID: mountID, mount: mount) {
            plan = made
            planFromSQL = true
        } else if !forceFull,
                  let snapshot = cloudModel.scanSnapshot,
                  let made = Self.makeIncrementalPlan(snapshot) {
            plan = made
        }
        // 扫描代次：全量扫描结束后据此删掉索引里本轮没见到的旧行；
        // 增量扫描先把已有行全部标记为本轮，避免未回调的子树被误删。
        let generation = metadataStore?.beginCloudIndexScan(mountID: mountID,
                                                            keepExisting: plan != nil) ?? 0
        cloudModel.scanGeneration = generation
        cloudModel.scanIsDeep = plan == nil

        if plan != nil, planFromSQL, let store = metadataStore {
            let rows = store.loadCloudIndexFolders(mountID: mountID)
            if !rows.isEmpty {
                cloudModel.scanFolders = rows.map {
                    CloudScanFolder(path: $0.path,
                                    name: $0.name,
                                    parentPath: $0.parentPath,
                                    modifiedAt: $0.modifiedAt)
                }
                cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
                cloudModel.scanFolderCount = cloudModel.scanFolders.count
                cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
            }
        } else if plan != nil, let snapshot = cloudModel.scanSnapshot {
            cloudModel.scanFolders = snapshot.folders ?? []
            cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
            var mediaFolders = cloudModel.scanMediaFolder
            for record in snapshot.records {
                if let folder = record.folderPath { mediaFolders[record.path] = folder }
            }
            cloudModel.scanMediaFolder = mediaFolders
            cloudModel.scanFolderCount = cloudModel.scanFolders.count
            cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
        } else {
            let rootFolder = CloudScanFolder(path: cloudRootPath(for: mount),
                                             name: mount.name,
                                             parentPath: "")
            cloudModel.scanFolders = [rootFolder]
            cloudModel.scanFolderPaths = [rootFolder.path]
            cloudModel.scanMediaFolder = [:]
            cloudModel.scanFolderCount = 0
            cloudModel.scanIndexPersistedFolderCount = 1
            // 根目录先落库：即使扫描中途退出，下次也能从索引里恢复出目录层级。
            metadataStore?.saveCloudIndexBatch(mountID: mountID,
                                               generation: generation,
                                               folders: [rootFolder],
                                               assets: [])
        }
        if cloudModel.scanPhotoPaths.isEmpty, !cloudModel.scanPhotos.isEmpty {
            cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
        }
        // 增量扫描只回调变化的子树：内存清单为空时先从索引补齐，避免复用子树「凭空消失」。
        if plan != nil, cloudModel.scanPhotos.isEmpty, let store = metadataStore {
            let records = store.loadCloudIndexAssets(mountID: mountID)
            if !records.isEmpty {
                cloudModel.scanPhotos = records.map { albumPhoto(record: $0, mount: mount) }
                var mediaFolders = cloudModel.scanMediaFolder
                for record in records {
                    if let folder = record.folderPath { mediaFolders[record.path] = folder }
                }
                cloudModel.scanMediaFolder = mediaFolders
                cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
            }
        }
        cloudModel.scanSnapshot = nil
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        cloudModel.selectedFolderPath = nil
        cloudError = nil
        cloudModel.needsCloudReauth = false
        cloudModel.pendingScanFolderCount = cloudModel.scanFolderCount
        cloudModel.lastPublishedScanMediaCount = -1
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
        presentCloudAlbumPhotos(mountID: mountID)

        cloudModel.scanTask = Task { [weak self] in
            guard let self else { return }
            let result = await CloudScanner.scan(mount: mount, incremental: plan) { batch, folderCount, mediaCount in
                self.ingestCloudAlbumBatch(batch,
                                           mount: mount,
                                           folderCount: folderCount,
                                           mediaCount: mediaCount)
            }
            guard !Task.isCancelled else { return }
            self.finishCloudAlbumScan(result: result, mountID: mountID)
        }
    }

    /// 把上一轮完整扫描（SQLite 索引）转换成增量扫描计划；不满足条件时返回 nil（走全量）。
    private static func makeIncrementalPlan(store: MetadataStore,
                                            mountID: UUID,
                                            mount: CloudMount) -> CloudScanner.IncrementalPlan? {
        guard let state = store.loadCloudIndexState(mountID: mountID),
              state.complete, !state.truncated,
              Date().timeIntervalSince(state.updatedAt) < 24 * 3600,
              state.scopeSignature == scopeSignature(mount) else { return nil }
        // 目录 mtime 只能发现「新增 / 删除 / 改名」；已存在文件被同名替换时目录 mtime 不变。
        // 因此定期强制一次深度扫描（SMB 1 小时、其它网盘 6 小时），兜底文件内容更新。
        let deepAge: TimeInterval = mount.kind == .smb ? 3600 : 6 * 3600
        guard let deepRaw = store.setting(cloudDeepScanSettingKey(mountID)),
              let deepAt = Double(deepRaw),
              Date().timeIntervalSince1970 - deepAt < deepAge else { return nil }
        let folders = store.loadCloudIndexFolders(mountID: mountID)
        guard !folders.isEmpty, folders.contains(where: { $0.modifiedAt != nil }) else { return nil }
        var byPath: [String: CloudScanFolder] = [:]
        var children: [String: [String]] = [:]
        byPath.reserveCapacity(folders.count)
        for row in folders {
            byPath[row.path] = CloudScanFolder(path: row.path,
                                               name: row.name,
                                               parentPath: row.parentPath,
                                               modifiedAt: row.modifiedAt)
            children[row.parentPath, default: []].append(row.path)
        }
        var media: [String: [String]] = [:]
        for record in store.loadCloudIndexAssets(mountID: mountID) {
            guard let folder = record.folderPath else { continue }
            media[folder, default: []].append(record.path)
        }
        return CloudScanner.IncrementalPlan(foldersByPath: byPath,
                                            childrenByParent: children,
                                            mediaByFolder: media)
    }

    /// 旧版 JSON 快照的增量计划（仅用于迁移过渡）。
    private static func makeIncrementalPlan(_ snapshot: CloudScanSnapshot) -> CloudScanner.IncrementalPlan? {
        guard snapshot.complete == true,
              !snapshot.truncated,
              Date().timeIntervalSince(snapshot.savedAt) < 24 * 3600,
              let folders = snapshot.folders, !folders.isEmpty,
              folders.contains(where: { $0.modifiedAt != nil }) else { return nil }
        var byPath: [String: CloudScanFolder] = [:]
        var children: [String: [String]] = [:]
        byPath.reserveCapacity(folders.count)
        for folder in folders {
            byPath[folder.path] = folder
            children[folder.parentPath, default: []].append(folder.path)
        }
        var media: [String: [String]] = [:]
        for record in snapshot.records {
            guard let folder = record.folderPath else { continue }
            media[folder, default: []].append(record.path)
        }
        return CloudScanner.IncrementalPlan(foldersByPath: byPath,
                                            childrenByParent: children,
                                            mediaByFolder: media)
    }

    func cancelCloudAlbumScan() {
        cloudModel.scanTask?.cancel()
        cloudModel.scanTask = nil
        if let jobID = cloudModel.scanJobID {
            cancelSourceJob(jobID)
            cloudModel.scanJobID = nil
        }
    }

    /// 更新接入范围与排除目录；返回 true 表示有变化（需要重扫）。nil 表示该项保持不变。
    @discardableResult
    func updateCloudMountAccess(_ mountID: UUID,
                                scopes: [CloudScopeRoot]?,
                                excludes: [CloudScopeRoot]? = nil) -> Bool {
        guard let index = cloudMounts.firstIndex(where: { $0.id == mountID }) else { return false }
        var mount = cloudMounts[index]
        var changed = false
        if let scopes, mount.scopeRoots != scopes {
            mount.scopeRoots = scopes
            changed = true
        }
        if let excludes, mount.excludedRoots != excludes {
            mount.excludedRoots = excludes
            changed = true
        }
        guard changed else { return false }
        cloudMounts[index] = mount
        saveCloudMounts()
        clearCloudScanForScopeChange(mountID: mountID)
        return true
    }

    /// 接入范围变化后，旧目录树、快照与缓存都不再适用，必须从头扫一遍。
    private func clearCloudScanForScopeChange(mountID: UUID) {
        cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(mountID.uuidString) }
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
        // 接入范围变了：旧索引整体作废，下一次扫描重新建表（即使当前打开的不是这个挂载）。
        metadataStore?.purgeCloudIndex(mountID: mountID)
        metadataStore?.setSetting(Self.cloudDeepScanSettingKey(mountID), nil)
        guard cloudModel.scanMountID == mountID else { return }
        cancelCloudAlbumScan()
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.scanPhotos = []
        cloudModel.scanFolders = []
        cloudModel.scanMediaFolder = [:]
        cloudModel.scanPhotoPaths = []
        cloudModel.scanFolderPaths = []
        cloudModel.scanSnapshot = nil
        cloudModel.scanFolderCount = 0
        cloudModel.scanMediaCount = 0
        cloudModel.pendingScanFolderCount = 0
        cloudModel.lastPublishedScanMediaCount = -1
        cloudModel.scanIndexPersistedFolderCount = 0
        cloudModel.scanGeneration = 0
        cloudModel.scanPhase = .idle
        cloudModel.selectedFolderPath = nil
        cloudPhotos = []
    }

    /// 用户手动停止扫描：保留已发现的媒体，并落一份部分状态供下次打开直接显示。
    func stopCloudAlbumScan() {
        cancelCloudAlbumScan()
        guard cloudModel.scanPhase.isScanning else { return }
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.scanPhase = .cancelled
        cloudModel.scanFolderCount = cloudModel.pendingScanFolderCount
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        if let mountID = cloudModel.scanMountID {
            saveCloudAlbumSnapshot(mountID: mountID)
        }
    }

    private func ingestCloudAlbumBatch(_ batch: CloudScanner.Batch,
                                       mount: CloudMount,
                                       folderCount: Int,
                                       mediaCount: Int) {
        guard cloudModel.scanMountID == mount.id,
              cloudModel.scanPhase.isScanning else { return }
        cloudModel.pendingScanFolderCount = folderCount
        let updatedFolders = registerCloudFolders(batch.folders, container: batch.container, mount: mount)
        for entry in batch.media {
            cloudModel.scanMediaFolder[entry.path] = batch.container
        }
        guard !batch.media.isEmpty else {
            persistCloudIndexBatch(mount: mount,
                                   folders: updatedFolders,
                                   assets: [])
            return
        }

        // 增量去重：只用本批与累积集合比较，避免每批都重建整份 scanPhotos 的路径集合。
        var added: [PhotoItem] = []
        for entry in batch.media where cloudModel.scanPhotoPaths.insert(entry.path).inserted {
            added.append(makeCloudPhoto(mount: mount, entry: entry))
        }
        guard !added.isEmpty else {
            persistCloudIndexBatch(mount: mount, folders: updatedFolders, assets: [])
            return
        }
        cloudModel.scanPhotos.append(contentsOf: added)
        persistCloudIndexBatch(mount: mount, folders: updatedFolders, assets: added)
        // 扫描期间不再逐目录 publish：合并成 0.6 秒一次，侧边栏与网格只重算一次。
        scheduleCloudScanProgressPublish(mountID: mount.id)
    }

    /// 把本批新增 / 更新的目录与媒体写入 SQLite 索引（后台串行队列，不阻塞扫描）。
    private func persistCloudIndexBatch(mount: CloudMount,
                                        folders: [CloudScanFolder],
                                        assets: [PhotoItem]) {
        guard let store = metadataStore else { return }
        let start = min(cloudModel.scanIndexPersistedFolderCount, cloudModel.scanFolders.count)
        let appended = start < cloudModel.scanFolders.count
            ? Array(cloudModel.scanFolders[start...])
            : []
        cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
        let allFolders = appended + folders
        let records = assets.compactMap {
            Self.albumRecord(photo: $0, mediaFolders: cloudModel.scanMediaFolder)
        }
        guard !allFolders.isEmpty || !records.isEmpty else { return }
        store.saveCloudIndexBatch(mountID: mount.id,
                                  generation: cloudModel.scanGeneration,
                                  folders: allFolders,
                                  assets: records)
    }

    /// 记录扫描到的目录（父目录缺失时按路径补出来，SMB 的扁平结果也能建树）。
    /// - Returns: 本批需要回写索引的目录（新建 + mtime / 名称变化的），供增量扫描下一轮复用。
    @discardableResult
    private func registerCloudFolders(_ folders: [CloudEntry],
                                      container: String,
                                      mount: CloudMount) -> [CloudScanFolder] {
        ensureCloudFolder(path: container, parent: nil, name: nil, mount: mount)
        var indexByPath: [String: Int] = [:]
        indexByPath.reserveCapacity(cloudModel.scanFolders.count)
        for (offset, folder) in cloudModel.scanFolders.enumerated() {
            indexByPath[folder.path] = offset
        }
        var changed: [CloudScanFolder] = []
        for entry in folders {
            if let offset = indexByPath[entry.path] {
                // 已存在的目录也要刷新 mtime：否则下一轮增量会一直把它当成"有变化"重复扫描。
                var updated = cloudModel.scanFolders[offset]
                var dirty = false
                if let modified = entry.modifiedAt, updated.modifiedAt != modified {
                    updated.modifiedAt = modified
                    dirty = true
                }
                if updated.name != entry.name {
                    updated.name = entry.name
                    dirty = true
                }
                if dirty {
                    cloudModel.scanFolders[offset] = updated
                    changed.append(updated)
                }
            } else if cloudModel.scanFolderPaths.insert(entry.path).inserted {
                let folder = CloudScanFolder(path: entry.path,
                                             name: entry.name,
                                             parentPath: container,
                                             modifiedAt: entry.modifiedAt)
                indexByPath[entry.path] = cloudModel.scanFolders.count
                cloudModel.scanFolders.append(folder)
                changed.append(folder)
            }
        }
        cloudFolderTreeCacheKey = nil
        return changed
    }

    private func ensureCloudFolder(path: String,
                                   parent: String?,
                                   name: String?,
                                   mount: CloudMount) {
        let rootPath = cloudRootPath(for: mount)
        if cloudModel.scanFolderPaths.contains(path) { return }
        if path == rootPath {
            cloudModel.scanFolders.append(CloudScanFolder(path: path,
                                                          name: mount.name,
                                                          parentPath: ""))
            cloudModel.scanFolderPaths.insert(path)
            return
        }
        let resolvedParent = parent ?? CloudScanner.parentPath(of: path)
        if resolvedParent != rootPath, resolvedParent != path {
            ensureCloudFolder(path: resolvedParent, parent: nil, name: nil, mount: mount)
        }
        guard cloudModel.scanFolderPaths.insert(path).inserted else { return }
        let fallbackName = path.split(separator: "/").last.map(String.init) ?? "文件夹"
        cloudModel.scanFolders.append(CloudScanFolder(path: path,
                                                      name: name ?? fallbackName,
                                                      parentPath: resolvedParent))
    }

    private func finishCloudAlbumScan(result: CloudScanner.Result, mountID: UUID) {
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        // 完整扫完（未触顶、没有目录读取失败）才按扫描结果剔除网盘上已删除的项目。
        if !result.truncated, result.failedFolders == 0, result.folderCount > 0 {
            let seen = result.mediaPaths
            let removed = cloudModel.scanPhotos.compactMap { photo -> String? in
                guard let path = photo.cloudPath, !seen.contains(path) else { return nil }
                return path
            }
            if !removed.isEmpty {
                metadataStore?.deleteCloudIndexAssets(mountID: mountID, paths: removed)
            }
            cloudModel.scanPhotos.removeAll { !seen.contains($0.cloudPath ?? "") }
        }
        // 增量扫描发现某些子树已从远端消失：把目录树与路径 → 目录映射一起清掉。
        if !result.removedFolderPaths.isEmpty {
            let removed = result.removedFolderPaths
            metadataStore?.deleteCloudIndexFolders(mountID: mountID, paths: Array(removed))
            cloudModel.scanFolders.removeAll { folder in
                removed.contains(folder.path)
                    || removed.contains(where: { folder.path.hasPrefix($0 + "/") })
            }
            cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
            cloudModel.scanMediaFolder = cloudModel.scanMediaFolder.filter { _, folder in
                !removed.contains(folder)
                    && !removed.contains(where: { folder.hasPrefix($0 + "/") })
            }
        }
        cloudModel.scanFolderCount = result.folderCount
        cloudModel.pendingScanFolderCount = result.folderCount
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        cloudModel.scanTruncated = result.truncated
        cloudModel.scanPhase = .finished(Date())
        if let jobID = cloudModel.scanJobID {
            if let error = result.firstErrorDescription, result.mediaCount == 0 {
                failSourceJob(jobID, message: error)
            } else {
                finishSourceJob(jobID,
                                message: "扫描完成 · \(result.folderCount) 个目录 · \(cloudModel.scanPhotos.count) 项媒体")
            }
            cloudModel.scanJobID = nil
        }
        cloudModel.scanTask = nil
        cloudModel.scanSnapshot = nil
        // 扫描期间不再每批全量排序；结束时排一次，快照顺序稳定，省下每批 O(n log n)。
        cloudModel.scanPhotos.sort { $0.capturedAt > $1.capturedAt }
        cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
        presentCloudAlbumPhotos(mountID: mountID)
        // 一条都没扫到且有目录报错（常见于授权失效 / 钥匙串拒绝）：把原因显示在相册页顶部。
        if cloudModel.scanPhotos.isEmpty, let message = result.firstErrorDescription {
            cloudError = message
            cloudModel.needsCloudReauth = result.sawAuthError
            if result.sawAuthError { CloudCredentials.invalidate(for: mountID) }
        } else {
            cloudModel.needsCloudReauth = false
        }
        let complete = !result.truncated
            && result.failedFolders == 0
            && result.folderCount > 0
        // 完整扫完才清理索引旧行：中断 / 触顶的扫描保留上次目录，避免界面突然变空。
        if complete, cloudModel.scanGeneration != 0 {
            metadataStore?.pruneCloudIndex(mountID: mountID,
                                           generation: cloudModel.scanGeneration)
        }
        saveCloudAlbumSnapshot(mountID: mountID, complete: complete)
        // EXIF 与刮削都让路：先让网格与侧边栏稳定，再在空闲时补读元数据。
        // 刮削只由用户进入影院 / 显式点击触发，避免扫描结束后同时抢占网络与 CPU。
        cloudModel.metadataScanDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.scanCloudMetadataIfNeeded()
        }
        if result.truncated {
            showToast("已扫描 \(result.folderCount) 个文件夹，达到扫描上限；可在「相簿」里查看已扫描的目录")
        }
    }

    /// 把扫描清单（按当前选中的文件夹相簿筛选）贴到网格。
    private func presentCloudAlbumPhotos(mountID: UUID) {
        guard currentCloudMountID == mountID else { return }
        cloudPhotos = cloudPhotosForSelection()
        cloudModel.lastPublishedScanMediaCount = cloudModel.scanPhotos.count
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
    }

    /// 合并扫描进度：每 0.6 秒最多发布一次，避免每个目录都触发整页重算。
    private func scheduleCloudScanProgressPublish(mountID: UUID) {
        guard cloudModel.scanPublishTask == nil else { return }
        cloudModel.scanPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cloudModel.scanPublishTask = nil
            guard self.cloudModel.scanMountID == mountID,
                  self.cloudModel.scanPhase.isScanning else { return }
            self.publishCloudScanProgress(mountID: mountID)
        }
    }

    private func publishCloudScanProgress(mountID: UUID) {
        guard cloudModel.scanMountID == mountID else { return }
        let mediaCount = cloudModel.scanPhotos.count
        let folderCount = cloudModel.pendingScanFolderCount
        guard mediaCount != cloudModel.lastPublishedScanMediaCount
                || folderCount != cloudModel.scanFolderCount else { return }
        cloudModel.lastPublishedScanMediaCount = mediaCount
        cloudModel.scanFolderCount = folderCount
        cloudModel.scanMediaCount = mediaCount
        if let jobID = cloudModel.scanJobID {
            updateSourceJob(jobID,
                            completed: folderCount,
                            message: "已扫描 \(folderCount) 个目录 · \(mediaCount) 项媒体")
        }
        cloudPhotos = cloudPhotosForSelection()
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
        cloudFolderDescendantCacheKey = nil
    }

    private func cloudPhotosForSelection() -> [PhotoItem] {
        guard let selected = cloudModel.selectedFolderPath else { return cloudModel.scanPhotos }
        let paths = cloudDescendantFolderPaths(of: selected)
        return cloudModel.scanPhotos.filter { photo in
            guard let path = photo.cloudPath,
                  let folder = cloudModel.scanMediaFolder[path] else { return false }
            return paths.contains(folder)
        }
    }

    /// 选中目录及其所有子目录。
    private func cloudDescendantFolderPaths(of path: String) -> Set<String> {
        let key = "\(cloudModel.revision)|\(path)|\(cloudModel.scanFolders.count)"
        if cloudFolderDescendantCacheKey == key { return cloudFolderDescendantCacheValue }
        var childrenByParent: [String: [String]] = [:]
        for folder in cloudModel.scanFolders {
            childrenByParent[folder.parentPath, default: []].append(folder.path)
        }
        var result: Set<String> = [path]
        var queue = [path]
        while let next = queue.popLast() {
            for child in childrenByParent[next] ?? [] where result.insert(child).inserted {
                queue.append(child)
            }
        }
        cloudFolderDescendantCacheKey = key
        cloudFolderDescendantCacheValue = result
        return result
    }

    // MARK: 全盘扫描快照

    private nonisolated static let cloudAlbumSnapshotKind = "album-scan"

    private func loadCloudAlbumSnapshot(mountID: UUID) -> CloudScanSnapshot? {
        Self.loadCloudAlbumSnapshot(store: metadataStore,
                                    mountID: mountID,
                                    signature: Self.scopeSignature(cloudMount(for: mountID)))
    }

    /// 从 SQLite 索引恢复扫描结果；索引为空时回退旧版 JSON 快照（仅迁移用）。
    private nonisolated static func loadCloudAlbumSnapshot(store: MetadataStore?,
                                                           mountID: UUID,
                                                           signature: String) -> CloudScanSnapshot? {
        guard let store else { return nil }
        if let state = store.loadCloudIndexState(mountID: mountID),
           state.mediaCount > 0,
           state.pathVersion >= cloudSnapshotPathVersion,
           state.scopeSignature == signature {
            let records = store.loadCloudIndexAssets(mountID: mountID)
            guard !records.isEmpty else { return nil }
            let folders = store.loadCloudIndexFolders(mountID: mountID).map {
                CloudScanFolder(path: $0.path,
                                name: $0.name,
                                parentPath: $0.parentPath,
                                modifiedAt: $0.modifiedAt)
            }
            return CloudScanSnapshot(savedAt: state.updatedAt,
                                     folderCount: state.folderCount,
                                     truncated: state.truncated,
                                     records: records,
                                     folders: folders,
                                     complete: state.complete,
                                     pathVersion: state.pathVersion,
                                     scopeSignature: state.scopeSignature)
        }
        // 旧版 path：整份 JSON 写在一个 derived_reports 行里。
        let key = DerivedReportKey.cloud(mountID, "", cloudAlbumSnapshotKind)
        guard let cached = store.loadDerivedReport(key: key),
              let snapshot = try? JSONDecoder().decode(CloudScanSnapshot.self, from: cached.payload),
              (snapshot.pathVersion ?? 1) >= cloudSnapshotPathVersion,
              (snapshot.scopeSignature ?? "") == signature else { return nil }
        return snapshot
    }

    /// 接入范围签名：包含目录与排除目录排序后拼接，用于判断快照是否还属于当前选择。
    private static func scopeSignature(_ mount: CloudMount?) -> String {
        guard let mount else { return "" }
        let includes = mount.scopeRoots.map(\.path).sorted().joined(separator: ",")
        let excludes = mount.excludedRoots.map(\.path).sorted().joined(separator: ",")
        if includes.isEmpty, excludes.isEmpty { return "" }
        return "in:\(includes)|out:\(excludes)"
    }

    /// 上一次「深度扫描」的时间（秒）：增量扫描不更新它，只有全量扫描成功后才刷新。
    private static func cloudDeepScanSettingKey(_ mountID: UUID) -> String {
        "cloud_deep_scan|\(mountID.uuidString)"
    }

    /// 网盘条目路径的语义版本：递增会让旧快照失效并触发一次全量重扫。
    /// 2：修复 WebDAV 子目录里的文件被记成裸文件名（导致播放 404）。
    /// 3：阿里云盘路径改为「盘ID|文件ID」，覆盖默认盘 / 资源库 / 备份盘。
    private nonisolated static let cloudSnapshotPathVersion = 3

    /// 扫描结束 / 手动停止：聚合计数与状态落库。扫描期间媒体与目录已按批写入，
    /// 这里只重算一次「目录 → 直属数量 / 封面」，不再编码整份 JSON。
    private func saveCloudAlbumSnapshot(mountID: UUID, complete: Bool = false) {
        guard let store = metadataStore else { return }
        if complete, cloudModel.scanIsDeep {
            store.setSetting(Self.cloudDeepScanSettingKey(mountID),
                             String(Date().timeIntervalSince1970))
        }
        let state = MetadataStore.CloudIndexState(folderCount: cloudModel.scanFolderCount,
                                                  mediaCount: cloudModel.scanPhotos.count,
                                                  truncated: cloudModel.scanTruncated,
                                                  complete: complete,
                                                  pathVersion: Self.cloudSnapshotPathVersion,
                                                  scopeSignature: Self.scopeSignature(cloudMount(for: mountID)),
                                                  updatedAt: Date())
        store.finalizeCloudIndex(mountID: mountID, state: state) { [weak self] in
            guard let self, self.cloudModel.scanMountID == mountID else { return }
            self.cloudModel.cloudIndexRevision += 1
            self.cloudFolderTreeCacheKey = nil
        }
        // 内存里的旧快照只用于旧版增量路径；SQLite 状态已经更新。
        cloudModel.scanSnapshot = nil
    }

    /// 影院刮削需要读取扫描快照与快照里的媒体条目（文件内私有实现，这里开一个内部入口）。
    func cloudAlbumSnapshot(mountID: UUID) -> CloudScanSnapshot? {
        loadCloudAlbumSnapshot(mountID: mountID)
    }

    // MARK: 总览用的轻量索引概况

    /// 每个挂载的索引状态：目录数 / 媒体数 / 是否完整 / 最近扫描时间。
    /// 只查状态行，不加载索引里的媒体清单，网盘总览的「索引」页可以放心一次读完。
    func cloudIndexStates() -> [UUID: MetadataStore.CloudIndexState] {
        guard let store = metadataStore else { return [:] }
        var result: [UUID: MetadataStore.CloudIndexState] = [:]
        for mount in cloudMounts {
            if let state = store.loadCloudIndexState(mountID: mount.id) {
                result[mount.id] = state
            }
        }
        return result
    }

    /// 上一次「深度扫描」的时间：增量扫描不会刷新它，只有完整重扫成功后才更新。
    func cloudDeepScanDate(_ mountID: UUID) -> Date? {
        guard let raw = metadataStore?.setting(Self.cloudDeepScanSettingKey(mountID)),
              let seconds = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func cloudAlbumPhoto(record: CloudScanRecord, mount: CloudMount) -> PhotoItem {
        albumPhoto(record: record, mount: mount)
    }

    private nonisolated static func albumRecord(photo: PhotoItem,
                                                mediaFolders: [String: String]) -> CloudScanRecord? {
        guard let path = photo.cloudPath else { return nil }
        return CloudScanRecord(path: path,
                               name: photo.originalName,
                               size: photo.fileSize,
                               // 远端修改时间（「最近保存」用），不要拿 EXIF 拍摄时间覆盖它。
                               modifiedAt: photo.addedAt,
                               width: photo.pixelWidth,
                               height: photo.pixelHeight,
                               duration: photo.duration,
                               remoteID: photo.cloudRemoteID,
                               thumbnailURL: photo.cloudThumbnailURL,
                               isVideo: photo.isVideo,
                               folderPath: mediaFolders[path],
                               codec: photo.videoCodec,
                               capturedAt: photo.capturedAt,
                               addedAt: photo.addedAt)
    }

    private func albumPhoto(record: CloudScanRecord, mount: CloudMount) -> PhotoItem {
        Self.albumPhoto(record: record,
                        mount: mount,
                        favorites: cloudFavorites,
                        keywords: cloudKeywords,
                        marks: cloudMarks,
                        viewedAt: cloudModel.viewedAt)
    }

    /// 纯函数版本：索引恢复时在后台线程批量映射，避免两万条记录阻塞主线程。
    nonisolated static func albumPhoto(record: CloudScanRecord,
                                       mount: CloudMount,
                                       favorites: Set<String>,
                                       keywords: [String: [String]],
                                       marks: [String: CloudMark],
                                       viewedAt: [UUID: Date]) -> PhotoItem {
        var entry = CloudEntry(path: record.path,
                               name: record.name,
                               isDirectory: false,
                               size: record.size,
                               modifiedAt: record.modifiedAt ?? record.addedAt,
                               contentType: record.isVideo ? "video/mp4" : nil)
        entry.thumbnailURL = record.thumbnailURL
        entry.remoteID = record.remoteID
        entry.pixelWidth = record.width
        entry.pixelHeight = record.height
        entry.duration = record.duration
        entry.codecName = record.codec
        var photo = makeCloudPhoto(mount: mount,
                                   entry: entry,
                                   favorites: favorites,
                                   keywords: keywords,
                                   marks: marks,
                                   viewedAt: viewedAt)
        if let captured = record.capturedAt ?? record.modifiedAt {
            photo.capturedAt = captured
        }
        if let added = record.addedAt ?? record.modifiedAt {
            photo.addedAt = added
        }
        return photo
    }

    /// 换库 / 断开挂载时清掉扫描任务与清单。
    func resetCloudAlbumScan() {
        cancelCloudAlbumScan()
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.refreshLoopTask?.cancel()
        cloudModel.refreshLoopTask = nil
        cloudModel.scanLoadToken += 1
        cloudModel.isRestoringScan = false
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        cloudModel.metadataFlushTask?.cancel()
        cloudModel.metadataFlushTask = nil
        cloudModel.metadataDirty = false
        cloudModel.pendingPhotoUpdates.removeAll()
        cloudModel.featuresLoadedMountID = nil
        cloudModel.isLoadingCloudFeatures = false
        cloudModel.scanPhase = .idle
        cloudModel.scanFolderCount = 0
        cloudModel.scanMediaCount = 0
        cloudModel.pendingScanFolderCount = 0
        cloudModel.lastPublishedScanMediaCount = -1
        cloudModel.scanIndexPersistedFolderCount = 0
        cloudModel.scanGeneration = 0
        cloudModel.scanTruncated = false
        cloudModel.scanPhotos = []
        cloudModel.scanFolders = []
        cloudModel.scanMediaFolder = [:]
        cloudModel.scanPhotoPaths = []
        cloudModel.scanFolderPaths = []
        cloudModel.selectedFolderPath = nil
        cloudModel.scanMountID = nil
        cloudModel.scanSnapshot = nil
        cloudFolderTreeCacheKey = nil
        cloudFolderDescendantCacheKey = nil
    }

    func loadCloudMounts() {
        guard let json = metadataStore?.setting("cloud_mounts"),
              let data = json.data(using: .utf8),
              let mounts = try? JSONDecoder().decode([CloudMount].self, from: data) else { return }
        cloudMounts = mounts
    }

    func saveCloudMounts() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(cloudMounts),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting("cloud_mounts", json)
    }

    /// 调整网盘在侧边栏里的顺序：注册表按 `cloudMounts` 的顺序生成，
    /// 排序结果同样作用于网盘总览与影院入口。
    func moveCloudMount(_ id: UUID, by offset: Int) {
        guard let index = cloudMounts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard cloudMounts.indices.contains(target) else { return }
        cloudMounts.swapAt(index, target)
        saveCloudMounts()
    }

    /// 网盘密码由 `CloudCredentials` 在进程内缓存：目录滚动不会反复读钥匙串，
    /// 只有第一次连接或认证失败后才重新读取。
    func cloudPassword(for mountID: UUID) -> String {
        CloudCredentials.password(for: mountID)
    }

    /// 认证失败说明钥匙串里的密码可能已经过期：丢掉内存缓存，下次点击重新读取。
    func invalidateCloudPasswordIfNeeded(_ error: Error, mountID: UUID) {
        if let webdav = error as? WebDAVError, case .unauthorized = webdav {
            CloudCredentials.invalidate(for: mountID)
            return
        }
        if error is SMBError {
            let message = error.localizedDescription
            if message.contains("认证") || message.contains("密码") {
                CloudCredentials.invalidate(for: mountID)
            }
        }
    }

    func cloudMount(for id: UUID?) -> CloudMount? {
        guard let id else { return nil }
        return cloudMounts.first(where: { $0.id == id })
    }

    func presentCloudSheet(_ mount: CloudMount?) {
        cloudSheetMount = mount
        showCloudSheet = true
    }

    func presentCloudWizard(flow: CloudWizardFlow? = nil) {
        cloudSheetMount = nil
        showCloudSheet = false
        cloudWizardInitialFlow = flow
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            showCloudWizard = true
        }
    }

    /// 编辑已有挂载的接入范围：直接打开确认页，凭据从钥匙串带入。
    func presentCloudWizard(editing mount: CloudMount) {
        cloudWizardEditingMountID = mount.id
        presentCloudWizard(flow: mount.kind.wizardFlow)
    }

    func probeAList(address: String) async -> (ok: Bool, message: String) {
        await AListProbe.check(address: address)
    }

    func dismissCloudSheet() {
        showCloudSheet = false
        cloudSheetMount = nil
    }

    func testCloudConnection(address: String, username: String,
                             password: String,
                             trustSelfSigned: Bool = false) async -> (ok: Bool, message: String) {
        if CloudKind.detect(from: address) == .smb {
            return await SMBClient.test(address: address, username: username, password: password)
        }
        guard let client = WebDAVClient(baseURLString: address,
                                        username: username,
                                        password: password,
                                        allowsSelfSignedCertificate: trustSelfSigned) else {
            return (false, "服务器地址无效，请填写 http(s)://主机:端口/路径")
        }
        do {
            let entries = try await client.list(path: "")
            let folders = entries.filter { $0.isDirectory }.count
            let media = entries.filter { !$0.isDirectory && $0.isMedia }.count
            return (true, "连接成功：\(folders) 个文件夹、\(media) 个媒体文件")
        } catch {
            let description = error.localizedDescription
            let isTrustError = description.contains("SSL") || description.contains("TLS")
                || description.contains("certificate") || description.contains("证书")
            if isTrustError {
                return (false, "连接失败：\(description)。HTTPS 地址若使用自签名证书，请勾选「信任自签名证书」。")
            }
            return (false, "连接失败：\(description)")
        }
    }

    @discardableResult
    func saveCloudMount(existing: CloudMount?, name: String, address: String,
                        username: String, password: String,
                        kind requestedKind: CloudKind = .webdav,
                        trustSelfSigned: Bool = false,
                        scopes: [CloudScopeRoot]? = nil,
                        excludes: [CloudScopeRoot]? = nil) -> String? {
        let kind = existing?.kind ?? CloudKind.detect(from: address) ?? requestedKind
        let normalized: String
        let host: String?
        switch kind {
        case .smb:
            guard let value = SMBClient.normalizedAddress(address) else {
                return "SMB 地址无效，请填写 smb://主机/共享名，例如 smb://192.168.1.10/photo"
            }
            normalized = value
            host = URLComponents(string: value)?.host
        default:
            guard let base = WebDAVClient.normalizedBaseURL(address) else {
                return "服务器地址无效，请填写 http(s)://主机:端口/路径"
            }
            normalized = base.absoluteString
            host = base.host
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = kind == .smb
            ? (SMBClient.displayName(address) ?? "SMB 共享")
            : (host ?? "网络存储")
        let finalName = trimmedName.isEmpty ? fallbackName : trimmedName

        if var mount = existing, let index = cloudMounts.firstIndex(where: { $0.id == mount.id }) {
            let previousAddress = mount.baseURL
            mount.name = finalName
            mount.baseURL = normalized
            mount.username = username
            mount.trustSelfSigned = trustSelfSigned
            cloudMounts[index] = mount
            if !password.isEmpty {
                CloudCredentials.setPassword(password, for: mount.id)
            }
            if mount.kind == .smb, previousAddress != normalized {
                SMBClient.unmount(address: previousAddress)
                // 换了共享 / 目录后旧范围不再适用；向导显式传入的范围除外。
                if scopes == nil { mount.scopeRoots = [] }
                if excludes == nil { mount.excludedRoots = [] }
            }
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(mount.id.uuidString) }
            saveCloudMounts()
            updateCloudMountAccess(mount.id, scopes: scopes, excludes: excludes)
            if case .cloudMount(let current) = sidebarItem, current == mount.id {
                beginCloudAlbumScan(mountID: mount.id)
            }
            showToast("已更新「\(finalName)」")
            return nil
        }

        let mount = CloudMount(kind: kind, name: finalName,
                               baseURL: normalized, username: username,
                               scanAll: kind == .smb,
                               trustSelfSigned: kind == .webdav && trustSelfSigned,
                               scopeRoots: scopes ?? [],
                               excludedRoots: excludes ?? [])
        cloudMounts.append(mount)
        CloudCredentials.setPassword(password, for: mount.id)
        saveCloudMounts()
        showToast("已添加「\(finalName)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    /// 只改侧边栏里的显示名称，不动地址、凭据与缓存。
    func renameCloudMount(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = cloudMounts.firstIndex(where: { $0.id == id }) else { return }
        guard cloudMounts[index].name != trimmed else { return }
        cloudMounts[index].name = trimmed
        saveCloudMounts()
        showToast("已重命名为「\(trimmed)」")
    }

    func removeCloudMount(_ id: UUID) {
        if let mount = cloudMounts.first(where: { $0.id == id }), mount.kind == .smb {
            SMBClient.unmount(address: mount.baseURL)
        }
        cloudMounts.removeAll { $0.id == id }
        CloudCredentials.delete(for: id)
        CloudOAuthStore.deleteToken(mountID: id)
        if cloudModel.insightMountID == id { resetCloudInsight() }
        if cloudModel.scanMountID == id { resetCloudAlbumScan() }
        // 清掉该挂载的本地收藏记录，避免残留键越积越多。
        let favoritePrefix = "\(id.uuidString)|"
        if cloudFavorites.contains(where: { $0.hasPrefix(favoritePrefix) }) {
            cloudFavorites = cloudFavorites.filter { !$0.hasPrefix(favoritePrefix) }
            persistCloudFavorites()
        }
        cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(id.uuidString) }
        // 清掉该挂载的持久化缓存：EXIF / 识别 / 特征 / 人物 / 派生报告 / 扫描索引。
        metadataStore?.purgeCloudAssets(mountID: id)
        metadataStore?.purgeCloudPeople(mountID: id)
        metadataStore?.purgeCloudIndex(mountID: id)
        metadataStore?.setSetting(Self.cloudDeepScanSettingKey(id), nil)
        metadataStore?.removeDerivedReports(prefix: DerivedReportKey.cloudMountPrefix(id))
        try? FileManager.default.removeItem(at: LibraryPaths.cloudThumbs.appendingPathComponent(id.uuidString,
                                                                                            isDirectory: true))
        if case .cloudMount(let current) = sidebarItem, current == id {
            navigate(to: .library)
        }
        saveCloudMounts()
        showToast("已断开网络存储")
    }

    func openCloudMount(_ id: UUID) {
        guard let mount = cloudMounts.first(where: { $0.id == id }) else { return }
        prepareCloudInsight(for: id)
        cloudModel.overview = nil
        openCloudAlbum(mount)
    }


    func refreshCloudDirectory() {
        guard let id = currentCloudMountID else { return }
        // 手动刷新走全量：文件内容变化不一定改变父目录 mtime，只有全量能发现。
        beginCloudAlbumScan(mountID: id, forceFull: true)
    }

    func cloudGoUp() {
        guard let selected = cloudModel.selectedFolderPath,
              let folder = cloudModel.scanFolders.first(where: { $0.path == selected }) else { return }
        let rootPath = cloudMount(for: currentCloudMountID).map { cloudRootPath(for: $0) } ?? ""
        selectCloudFolder(path: folder.parentPath == rootPath ? nil : folder.parentPath)
    }

    func loadCloudDirectory(mountID: UUID, path: String, force: Bool = false) {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return }
        cloudPath = path
        cloudError = nil
        cloudLoadToken += 1
        let token = cloudLoadToken
        similarScope = nil
        cloudModel.healthReport = nil

        let cacheKey = "\(mountID.uuidString)|\(path)"
        if !force, let cached = cloudDirectoryCache[cacheKey] {
            cloudFolders = cached.folders
            cloudPhotos = hydrateCloudCache(photos: cached.photos, mountID: mountID)
            cloudDirectoryCache[cacheKey] = (cached.folders, cloudPhotos)
            cloudLoading = false
            restoreCloudDerivedReports(mountID: mountID, path: path)
            scanCloudMetadataIfNeeded()
            return
        }

        cloudLoading = true
        cloudBusyText = nil
        cloudFolders = []
        cloudPhotos = []

        Task {
            do {
                let entries = try await CloudService.list(mount: mount, containerID: path)
                guard token == self.cloudLoadToken else { return }

                let folders = entries
                    .filter { $0.isDirectory }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                var photos = entries
                    .filter { !$0.isDirectory && $0.isMedia }
                    .map { self.makeCloudPhoto(mount: mount, entry: $0) }
                // 回填上次落库的 EXIF / 识别 / 特征 / 查看记录，再按拍摄时间排序。
                photos = self.hydrateCloudCache(photos: photos, mountID: mount.id)
                photos.sort { $0.capturedAt > $1.capturedAt }

                self.cloudFolders = folders
                self.cloudPhotos = photos
                self.cloudDirectoryCache[cacheKey] = (folders, photos)
                self.cloudLoading = false
                self.cloudError = nil
                self.cloudModel.needsCloudReauth = false
                self.restoreCloudDerivedReports(mountID: mount.id, path: path)
                self.scanCloudMetadataIfNeeded()

                if mount.kind == .webdav || mount.kind == .smb,
                   let index = self.cloudMounts.firstIndex(where: { $0.id == mountID }),
                   self.cloudMounts[index].lastPath != path {
                    self.cloudMounts[index].lastPath = path
                    self.saveCloudMounts()
                }
            } catch {
                guard token == self.cloudLoadToken else { return }
                self.cloudLoading = false
                self.cloudError = error.localizedDescription
                self.invalidateCloudPasswordIfNeeded(error, mountID: mount.id)
                if let oauth = error as? CloudOAuthError, oauth.requiresReauth {
                    self.cloudModel.needsCloudReauth = true
                }
                self.showToast(error.localizedDescription)
            }
        }
    }

    /// 递归扫描 SMB 共享，把所有媒体汇总成一个列表（不受当前文件夹限制）。
    func loadCloudTree(mountID: UUID, rootPath: String, force: Bool = false) {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return }
        cloudPath = rootPath
        cloudError = nil
        cloudLoadToken += 1
        let token = cloudLoadToken
        similarScope = nil
        cloudModel.healthReport = nil

        let cacheKey = "\(mountID.uuidString)|tree|\(rootPath)"
        if !force, let cached = cloudDirectoryCache[cacheKey] {
            cloudFolders = []
            cloudPhotos = hydrateCloudCache(photos: cached.photos, mountID: mountID)
            cloudDirectoryCache[cacheKey] = ([], cloudPhotos)
            cloudLoading = false
            cloudBusyText = nil
            restoreCloudDerivedReports(mountID: mountID, path: rootPath)
            scanCloudMetadataIfNeeded()
            return
        }

        cloudLoading = true
        cloudFolders = []
        cloudPhotos = []
        cloudBusyText = "正在扫描整个共享…"

        Task {
            do {
                let entries = try await CloudService.scanTree(mount: mount, path: rootPath).media
                guard token == self.cloudLoadToken else { return }
                var photos = entries.map { self.makeCloudPhoto(mount: mount, entry: $0) }
                photos = self.hydrateCloudCache(photos: photos, mountID: mount.id)
                photos.sort { $0.capturedAt > $1.capturedAt }
                self.cloudFolders = []
                self.cloudPhotos = photos
                self.cloudDirectoryCache[cacheKey] = ([], photos)
                self.cloudBusyText = nil
                self.cloudLoading = false
                self.cloudError = nil
                self.cloudModel.needsCloudReauth = false
                self.restoreCloudDerivedReports(mountID: mount.id, path: rootPath)
                self.scanCloudMetadataIfNeeded()
            } catch {
                guard token == self.cloudLoadToken else { return }
                self.cloudBusyText = nil
                self.cloudLoading = false
                self.cloudError = error.localizedDescription
                self.invalidateCloudPasswordIfNeeded(error, mountID: mount.id)
                if let oauth = error as? CloudOAuthError, oauth.requiresReauth {
                    self.cloudModel.needsCloudReauth = true
                }
                self.showToast(error.localizedDescription)
            }
        }
    }

    func makeCloudPhoto(mount: CloudMount, entry: CloudEntry) -> PhotoItem {
        Self.makeCloudPhoto(mount: mount,
                            entry: entry,
                            favorites: cloudFavorites,
                            keywords: cloudKeywords,
                            marks: cloudMarks,
                            viewedAt: cloudModel.viewedAt)
    }

    /// 纯函数版本：打开网盘时可在后台线程批量映射两万条索引记录，不阻塞主线程。
    nonisolated static func makeCloudPhoto(mount: CloudMount,
                                           entry: CloudEntry,
                                           favorites: Set<String>,
                                           keywords: [String: [String]],
                                           marks: [String: CloudMark],
                                           viewedAt: [UUID: Date]) -> PhotoItem {
        var item = PhotoItem(
            id: CloudIdentity.id(mountID: mount.id, path: entry.path),
            filename: entry.name,
            editedFilename: nil,
            originalName: entry.name,
            capturedAt: entry.modifiedAt ?? Date.distantPast,
            pixelWidth: entry.pixelWidth ?? 0,
            pixelHeight: entry.pixelHeight ?? 0,
            fileSize: entry.size,
            kind: entry.isVideo ? .video : .photo
        )
        item.source = .cloud
        item.cloudMountID = mount.id
        item.cloudPath = entry.path
        item.cloudRemoteID = entry.remoteID
        item.cloudThumbnailURL = entry.thumbnailURL
        item.cloudRestricted = entry.isRestricted ? true : nil
        item.videoCodec = entry.codecName
        item.duration = entry.duration
        // 「最近保存」按网盘文件的修改时间判断；EXIF 之后会改写拍摄时间，这里保留一份落盘时间。
        item.addedAt = entry.modifiedAt ?? Date.distantPast
        let keywordKey = cloudFavoriteKey(mountID: mount.id, path: entry.path)
        item.isFavorite = favorites.contains(keywordKey)
        if let tags = keywords[keywordKey], !tags.isEmpty {
            item.keywords = tags
        }
        if let mark = marks[keywordKey] {
            item.rating = mark.rating
            item.flag = mark.flag
            item.colorLabel = mark.colorLabel
        }
        item.viewedAt = viewedAt[item.id]
        return item
    }

    // MARK: - 云照片的本地收藏（不写回网盘）

    nonisolated static func cloudFavoriteKey(mountID: UUID, path: String) -> String {
        "\(mountID.uuidString)|\(path)"
    }

    func loadCloudFavorites() {
        guard let json = metadataStore?.setting(Self.cloudFavoritesSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            cloudFavorites = []
            return
        }
        cloudFavorites = Set(list)
    }

    /// 收藏 / 取消收藏云照片：仅更新本地记录与当前列表，不修改 NAS 或网盘上的文件。
    func setCloudFavorite(_ favorite: Bool, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var list = cloudPhotos
        var changed = false
        for index in list.indices where ids.contains(list[index].id) {
            guard let mountID = list[index].cloudMountID,
                  let path = list[index].cloudPath else { continue }
            let key = Self.cloudFavoriteKey(mountID: mountID, path: path)
            if favorite {
                if cloudFavorites.insert(key).inserted { changed = true }
            } else if cloudFavorites.remove(key) != nil {
                changed = true
            }
            list[index].isFavorite = favorite
        }
        guard changed else { return }
        cloudPhotos = list
        for photo in list where ids.contains(photo.id) {
            updateCachedCloudPhoto(photo)
        }
        persistCloudFavorites()
        cloudVisibleCacheKey = nil
        showToast(favorite ? "已收藏（仅本机记录）" : "已取消收藏")
    }

    func persistCloudFavorites() {
        guard let data = try? JSONEncoder().encode(Array(cloudFavorites)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.cloudFavoritesSettingKey, json)
    }

    /// 旧版网盘收藏存在全局 UserDefaults，仅用于一次性迁入当前图库。
    static let cloudFavoritesDefaultsKey = "cloud.favorites.v1"
    /// 当前图库自己的网盘收藏（写在该图库的 SQLite settings 表）。
    static let cloudFavoritesSettingKey = "cloud_favorites"

    // MARK: - 云照片的本地关键词（不写回网盘）

    func loadCloudKeywords() {
        guard let json = metadataStore?.setting(Self.cloudKeywordsSettingKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            cloudKeywords = [:]
            return
        }
        cloudKeywords = map
    }

    func persistCloudKeywords() {
        guard let data = try? JSONEncoder().encode(cloudKeywords),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.cloudKeywordsSettingKey, json)
    }

    /// 给一批云照片增删关键词：只更新本地记录与当前列表，不修改 NAS 或网盘上的文件。
    func updateCloudKeywords(_ ids: Set<UUID>,
                             mutate: (inout [String]) -> Bool) {
        guard !ids.isEmpty else { return }
        var changed = false
        var list = cloudPhotos
        for index in list.indices where ids.contains(list[index].id) {
            guard let mountID = list[index].cloudMountID,
                  let path = list[index].cloudPath else { continue }
            let key = Self.cloudFavoriteKey(mountID: mountID, path: path)
            var tags = cloudKeywords[key] ?? []
            guard mutate(&tags) else { continue }
            changed = true
            if tags.isEmpty {
                cloudKeywords.removeValue(forKey: key)
                list[index].keywords = nil
            } else {
                cloudKeywords[key] = tags
                list[index].keywords = tags
            }
        }
        guard changed else { return }
        cloudPhotos = list
        for photo in list where ids.contains(photo.id) {
            updateCachedCloudPhoto(photo)
        }
        persistCloudKeywords()
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
        cloudModel.metadataRevision += 1
    }

    /// 当前图库自己的网盘关键词（写在该图库的 SQLite settings 表）。
    static let cloudKeywordsSettingKey = "cloud_keywords"

    // MARK: - 云照片的本地评分 / 旗标 / 色标（不写回网盘）

    func loadCloudMarks() {
        guard let json = metadataStore?.setting(Self.cloudMarksSettingKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: CloudMark].self, from: data) else {
            cloudMarks = [:]
            return
        }
        cloudMarks = map
    }

    func persistCloudMarks() {
        guard let data = try? JSONEncoder().encode(cloudMarks),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.cloudMarksSettingKey, json)
    }

    /// 给一批云照片改评分 / 旗标 / 色标：只更新本地记录与当前列表，不修改网盘上的文件。
    func updateCloudMarks(_ ids: Set<UUID>, mutate: (inout CloudMark) -> Bool) {
        guard !ids.isEmpty else { return }
        var changed = false
        var list = cloudPhotos
        for index in list.indices where ids.contains(list[index].id) {
            guard let mountID = list[index].cloudMountID,
                  let path = list[index].cloudPath else { continue }
            let key = Self.cloudFavoriteKey(mountID: mountID, path: path)
            var mark = cloudMarks[key] ?? CloudMark()
            guard mutate(&mark) else { continue }
            changed = true
            if mark.isEmpty {
                cloudMarks.removeValue(forKey: key)
            } else {
                cloudMarks[key] = mark
            }
            list[index].rating = mark.rating
            list[index].flag = mark.flag
            list[index].colorLabel = mark.colorLabel
        }
        guard changed else { return }
        cloudPhotos = list
        for photo in list where ids.contains(photo.id) {
            updateCachedCloudPhoto(photo)
        }
        persistCloudMarks()
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
        cloudModel.metadataRevision += 1
    }

    /// 当前图库自己的网盘评分 / 旗标 / 色标（写在该图库的 SQLite settings 表）。
    static let cloudMarksSettingKey = "cloud_marks"

    func applyCloudPixelSize(photoID: UUID, size: CGSize) {
        guard let index = cloudPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        let width = Int(size.width)
        let height = Int(size.height)
        guard cloudPhotos[index].pixelWidth != width || cloudPhotos[index].pixelHeight != height else { return }
        var photo = cloudPhotos[index]
        photo.pixelWidth = width
        photo.pixelHeight = height
        enqueueCloudPhotoUpdate(photo)
    }

    /// 缩略图尺寸 / EXIF 等"非结构性"更新先入队，0.4 秒内合并成一次列表写入。
    /// 直接改 `cloudPhotos` 会触发 @Published，让整页网格、月份分桶与范围计数每张图都重算。
    func enqueueCloudPhotoUpdate(_ photo: PhotoItem) {
        cloudModel.pendingPhotoUpdates[photo.id] = photo
        updateCachedCloudPhoto(photo)
        cloudModel.metadataDirty = true
        // 批量 EXIF 扫描由扫描循环自己按批刷新，避免每张照片都排一次 0.4 秒任务。
        if !cloudModel.isScanningMetadata {
            markCloudMetadataChanged()
        }
    }

    /// 标记派生缓存需要失效，并安排一次合并刷新。
    func markCloudMetadataChanged() {
        cloudModel.metadataDirty = true
        guard cloudModel.metadataFlushTask == nil else { return }
        cloudModel.metadataFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.cloudModel.metadataFlushTask = nil
            self.flushCloudMetadata()
        }
    }

    /// 把排队中的元数据更新一次性写回列表：只触发一次发布与一次缓存失效。
    func flushCloudMetadata() {
        let pending = cloudModel.pendingPhotoUpdates
        cloudModel.pendingPhotoUpdates.removeAll(keepingCapacity: true)
        if !pending.isEmpty {
            var list = cloudPhotos
            var indexByID: [UUID: Int] = [:]
            indexByID.reserveCapacity(list.count)
            for (offset, photo) in list.enumerated() { indexByID[photo.id] = offset }
            var changed = false
            for (id, photo) in pending {
                guard let offset = indexByID[id] else { continue }
                list[offset] = photo
                changed = true
            }
            if changed { cloudPhotos = list }
        }
        guard cloudModel.metadataDirty else { return }
        cloudModel.metadataDirty = false
        cloudModel.metadataRevision += 1
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
        cloudFolderTreeCacheKey = nil
    }

    /// 预取云缩略图：只处理尚未命中内存 / 磁盘缓存的头部若干张。
    /// 单任务顺序执行，给屏幕上正在请求的格子留出网络与并发额度。
    /// 视频（尤其 WebDAV / SMB 需要 ffmpeg 抽帧）只少量预取，避免扫描结束后一次性拖垮 CPU。
    /// 返回的任务可由视图的 `.task` 取消（离开网盘 / 切换目录时停止）。
    @discardableResult
    func prefetchCloudThumbnails(for photos: [PhotoItem], limit: Int = 60) -> Task<Void, Never>? {
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        guard !photos.isEmpty, limit > 0 else { return nil }
        var targets: [PhotoItem] = []
        targets.reserveCapacity(limit)
        var videoBudget = 6
        for photo in photos.prefix(limit) {
            guard photo.isCloud else { continue }
            if photo.isVideo {
                guard videoBudget > 0 else { continue }
                // 需要 ffmpeg 抽帧的视频不预取：等滚动到可见时再按需生成。
                if let mount = cloudMount(for: photo.cloudMountID),
                   mount.kind == .webdav || mount.kind == .smb {
                    continue
                }
                videoBudget -= 1
            }
            if ImageLoader.cachedCloudThumbnail(for: photo) != nil { continue }
            if let mountID = photo.cloudMountID, let path = photo.cloudPath,
               ThumbnailFileIndex.shared.exists(path: CloudPaths.thumbnailURL(mountID: mountID,
                                                                             path: path).path) {
                continue
            }
            targets.append(photo)
        }
        guard !targets.isEmpty else { return nil }
        let task = Task { [weak self] in
            for photo in targets {
                if Task.isCancelled { return }
                _ = await self?.cloudThumbnail(for: photo)
                await Task.yield()
            }
        }
        cloudModel.thumbnailPrefetchTask = task
        return task
    }

    func applyCloudDuration(photoID: UUID, duration: Double) {
        guard let index = cloudPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        guard cloudPhotos[index].duration != duration else { return }
        cloudPhotos[index].duration = duration
        updateCachedCloudPhoto(cloudPhotos[index])
    }

    func updateCachedCloudPhoto(_ photo: PhotoItem) {
        for key in cloudDirectoryCache.keys {
            guard var entry = cloudDirectoryCache[key],
                  let index = entry.photos.firstIndex(where: { $0.id == photo.id }) else { continue }
            entry.photos[index] = photo
            cloudDirectoryCache[key] = entry
        }
    }

    /// 云缩略图快速层：只读内存与磁盘，绝不发起网络请求。
    /// 目标图生成时已经顺手写了一份 192px 小图，滚动到这里时可以立即出图。
    func cloudQuickThumbnail(for photo: PhotoItem, maxPixel: CGFloat) async -> NSImage? {
        if let cached = ImageLoader.cachedCloudThumbnail(for: photo) { return cached }
        if let cached = ImageLoader.cachedGridImage(for: photo, maxPixel: maxPixel) { return cached }
        guard let mountID = photo.cloudMountID, let path = photo.cloudPath else { return nil }
        let url = CloudPaths.quickThumbnailURL(mountID: mountID, path: path)
        guard ThumbnailFileIndex.shared.exists(path: url.path) else { return nil }
        let image = await Task.detached(priority: .utility) {
            ImageLoader.decodeThumbnailFile(at: url, maxPixel: maxPixel)
        }.value
        if let image {
            ImageLoader.storeGridThumbnail(image, for: photo, maxPixel: maxPixel)
        }
        return image
    }

    /// 按需加载：优先使用服务端缩略图；WebDAV 走 EXIF 区间探测，避免整目录原图下行。
    func cloudThumbnail(for photo: PhotoItem) async -> NSImage? {
        if let cached = ImageLoader.cachedCloudThumbnail(for: photo) {
            return cached
        }
        if let remote = photo.cloudThumbnailURL, !remote.isEmpty {
            // 夸克 / 115 的缩略图地址可能在 CDN 后面，仍带上 Cookie / Referer 更稳妥。
            var headers: [String: String] = [:]
            if let mount = cloudMount(for: photo.cloudMountID) {
                if mount.kind == .quark {
                    headers = QuarkDrive.headers(cookie: cloudPassword(for: mount.id))
                } else if mount.kind == .pan115 {
                    headers = Pan115Drive.thumbnailHeaders(cookie: cloudPassword(for: mount.id))
                }
            }
            if let image = await CloudImageFetcher.thumbnail(for: photo,
                                                             urlString: remote,
                                                             headers: headers) {
                ImageLoader.cacheCloudThumbnail(image, for: photo)
                return image
            }
        }
        guard let mount = cloudMount(for: photo.cloudMountID) else { return nil }
        // 阿里 / 百度 / 夸克没有服务端缩略图：视频用 ffmpeg 读直链抽一帧，避免网格一直空白。
        if mount.kind != .webdav, mount.kind != .smb {
            guard photo.isVideo,
                  let stream = try? await cloudStreamOrThrow(for: photo) else { return nil }
            let fallback = await CloudThumbnailLoader.shared.remotePoster(
                for: photo, stream: stream, trustSelfSigned: mount.trustSelfSigned)
            if let size = fallback.size, size.width > 0, size.height > 0 {
                applyCloudPixelSize(photoID: photo.id, size: size)
            }
            if let duration = fallback.duration, duration > 0 {
                applyCloudDuration(photoID: photo.id, duration: duration)
            }
            guard let image = fallback.image else { return nil }
            ImageLoader.cacheCloudThumbnail(image, for: photo)
            return image
        }
        let result = await CloudThumbnailLoader.shared.thumbnail(for: photo,
                                                                 mount: mount,
                                                                 password: cloudPassword(for: mount.id))
        if let size = result.size, size.width > 0, size.height > 0 {
            applyCloudPixelSize(photoID: photo.id, size: size)
        }
        if let duration = result.duration, duration > 0 {
            applyCloudDuration(photoID: photo.id, duration: duration)
        }
        guard let image = result.image else { return nil }
        ImageLoader.cacheCloudThumbnail(image, for: photo)
        return image
    }

    /// 云端动图：下载完整文件后保留全部帧播放。
    /// 只对动图调用，并限制体积，避免为了播放误拉超大文件。
    func cloudAnimatedImage(for photo: PhotoItem) async -> NSImage? {
        guard photo.playsAnimation, photo.isCloud else { return nil }
        guard photo.fileSize > 0, photo.fileSize <= 80 * 1024 * 1024 else { return nil }
        guard let mount = cloudMount(for: photo.cloudMountID),
              let path = photo.cloudPath else { return nil }

        if mount.kind == .smb, let client = SMBClient(mount: mount, password: cloudPassword(for: mount.id)) {
            _ = try? await client.ensureMounted()
            guard let url = client.fileURL(path: path) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return NSImage(data: data)
            }.value
        }

        if mount.kind == .webdav, let client = CloudService.webdavClient(mount) {
            guard let data = try? await client.data(path: path) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                NSImage(data: data)
            }.value
        }

        guard let resource = await cloudStream(for: photo) else { return nil }
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 60)
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            NSImage(data: data)
        }.value
    }

    func cloudDisplayImage(for photo: PhotoItem) async -> NSImage? {
        guard let mount = cloudMount(for: photo.cloudMountID) else {
            Diagnostics.record("云端原图缺少挂载 \(photo.originalName) "
                               + "mount=\(photo.cloudMountID?.uuidString ?? "-")")
            return nil
        }
        if let cached = ImageLoader.cachedCloudFullImage(for: photo) {
            return cached
        }
        if mount.kind == .smb, let client = SMBClient(mount: mount,
                                                       password: cloudPassword(for: mount.id)) {
            _ = try? await client.ensureMounted()
            guard let url = client.fileURL(path: photo.cloudPath ?? "") else { return nil }
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.fullImage(from: url, maxPixel: 6000)
            }.value
            if let loaded { ImageLoader.cacheCloudFullImage(loaded, for: photo) }
            return loaded
        }
        if mount.kind == .webdav, let client = CloudService.webdavClient(mount) {
            return await ImageLoader.cloudFullImage(for: photo, client: client)
        }
        guard let resource = await cloudStream(for: photo),
              let image = await CloudImageFetcher.fullImage(photo: photo, resource: resource) else {
            Diagnostics.record("云端原图获取失败 [\(mount.kind.rawValue)] \(photo.cloudPath ?? "-")")
            return nil
        }
        ImageLoader.cacheCloudFullImage(image, for: photo)
        return image
    }

    func cloudStream(for photo: PhotoItem) async -> CloudStreamResource? {
        try? await cloudStreamOrThrow(for: photo)
    }

    /// 与 `cloudStream` 相同，但保留失败原因：播放器需要把「授权失效 / 缺少文件 ID / 直链获取失败」
    /// 之类的具体错误展示出来，而不是统一显示「无法定位视频文件」。
    func cloudStreamOrThrow(for photo: PhotoItem) async throws -> CloudStreamResource {
        guard let mount = cloudMount(for: photo.cloudMountID) else {
            throw CloudOAuthError.api("找不到对应的网盘连接，请在侧边栏重新连接")
        }
        do {
            return try await CloudService.stream(mount: mount, photo: photo)
        } catch {
            Diagnostics.record("云端直链获取失败 [\(mount.kind.rawValue)] \(photo.cloudPath ?? "-")：\(error.localizedDescription)")
            throw error
        }
    }

    func downloadCloudItem(_ photo: PhotoItem, to url: URL) async throws {
        guard let mount = cloudMount(for: photo.cloudMountID) else {
            throw CloudOAuthError.api("挂载不存在")
        }
        if mount.kind == .smb,
           let client = SMBClient(mount: mount, password: cloudPassword(for: mount.id)),
           let path = photo.cloudPath {
            _ = try await client.ensureMounted()
            guard let source = client.fileURL(path: path) else {
                throw CloudOAuthError.api("SMB 挂载点不可用，请检查共享是否已连接")
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: url)
            try fm.copyItem(at: source, to: url)
            return
        }
        if mount.kind == .webdav,
           let client = CloudService.webdavClient(mount),
           let path = photo.cloudPath {
            try await client.download(path: path, to: url)
            return
        }
        let resource = try await CloudService.stream(mount: mount, photo: photo)
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 120)
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudOAuthError.api("下载失败")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.moveItem(at: temp, to: url)
    }

    // MARK: - 云端写操作

    /// 授权完成后注册一个官方网盘挂载点。
    @discardableResult
    func registerOAuthMount(kind: CloudKind, name: String,
                            driveID: String?, token: CloudToken,
                            scopes: [CloudScopeRoot]? = nil,
                            excludes: [CloudScopeRoot]? = nil) -> String? {
        guard kind.usesOAuth else { return "不支持的接入方式" }
        if let existing = cloudMounts.first(where: { $0.kind == kind && $0.remoteDriveID == driveID }) {
            CloudOAuthStore.saveToken(token, mountID: existing.id)
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(existing.id.uuidString) }
            updateCloudMountAccess(existing.id, scopes: scopes, excludes: excludes)
            navigate(to: .cloudMount(existing.id))
            showToast("已更新「\(existing.name)」的授权")
            return nil
        }
        let mount = CloudMount(kind: kind, name: name, remoteDriveID: driveID,
                               scopeRoots: scopes ?? [],
                               excludedRoots: excludes ?? [])
        CloudOAuthStore.saveToken(token, mountID: mount.id)
        cloudMounts.append(mount)
        saveCloudMounts()
        showToast("已连接「\(name)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    func cloudClient(for mountID: UUID) -> WebDAVClient? {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return nil }
        return WebDAVClient(baseURLString: mount.baseURL,
                            username: mount.username,
                            password: cloudPassword(for: mount.id),
                            allowsSelfSignedCertificate: mount.trustSelfSigned)
    }

    func requestCloudRename(_ photoID: UUID) {
        guard isCurrentCloudWritable else { return }
        guard let photo = anyPhoto(id: photoID), photo.isCloud else { return }
        cloudNameRequest = CloudNameRequest(mode: .rename(photoID: photoID, current: photo.originalName))
    }

    func requestCloudNewFolder() {
        guard isCurrentCloudWritable else { return }
        cloudNameRequest = CloudNameRequest(mode: .newFolder)
    }

    func commitCloudName(_ request: CloudNameRequest, text: String) {
        guard isCurrentCloudWritable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.replacingOccurrences(of: "/", with: "_")
        guard !name.isEmpty else { return }
        guard case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        cloudNameRequest = nil

        switch request.mode {
        case .newFolder:
            let target = cloudPath.isEmpty ? name : cloudPath + "/" + name
            Task {
                do {
                    try await client.createFolder(path: target)
                    showToast("已新建文件夹「\(name)」")
                    refreshCloudDirectory()
                } catch {
                    showToast("新建失败：\(error.localizedDescription)")
                }
            }
        case .rename(let photoID, _):
            guard let photo = anyPhoto(id: photoID), let oldPath = photo.cloudPath else { return }
            var components = oldPath.split(separator: "/").map(String.init)
            components.removeLast()
            let oldExtension = (photo.originalName as NSString).pathExtension
            let typedExtension = (name as NSString).pathExtension
            let finalName: String
            if !oldExtension.isEmpty,
               typedExtension.lowercased() != oldExtension.lowercased() {
                finalName = name + "." + oldExtension
            } else {
                finalName = name
            }
            let newPath = (components + [finalName]).joined(separator: "/")
            guard newPath != oldPath else { return }
            Task {
                do {
                    try await client.move(from: oldPath, to: newPath)
                    selection.removeAll()
                    if viewerID == photoID {
                        viewerID = nil
                    }
                    showToast("已重命名为「\(finalName)」")
                    refreshCloudDirectory()
                } catch {
                    showToast("重命名失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func confirmDeleteCloud(_ ids: Set<UUID>) {
        guard isCurrentCloudWritable else {
            if case .cloudMount(let id) = sidebarItem, cloudMount(for: id)?.kind == .smb {
                showToast("SMB 共享为只读，删除请到 NAS 上操作")
            } else {
                showToast("官方网盘接入当前为只读，删除请到网盘 App")
            }
            return
        }
        let items = ids.compactMap { anyPhoto(id: $0) }.filter { $0.isCloud }
        guard !items.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = items.count == 1
            ? "从云端删除「\(items[0].originalName)」？"
            : "从云端删除 \(items.count) 项？"
        alert.informativeText = "文件会直接从 WebDAV 服务器删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        Task {
            var failed = 0
            for item in items {
                guard let path = item.cloudPath else { continue }
                do {
                    try await client.delete(path: path)
                    // 删除成功后再清本地缩略图缓存（磁盘 + 内存），避免残留文件与残影。
                    try? FileManager.default.removeItem(
                        at: CloudPaths.thumbnailURL(mountID: item.cloudMountID ?? mountID, path: path))
                    ImageLoader.invalidate(photo: item)
                } catch {
                    failed += 1
                }
            }
            if let viewerID, ids.contains(viewerID) {
                self.viewerID = nil
            }
            selection.removeAll()
            refreshCloudDirectory()
            showToast(failed == 0
                      ? "已从云端删除 \(items.count) 项"
                      : "已删除 \(items.count - failed) 项，\(failed) 项失败")
        }
    }

    func presentCloudUploadPanel() {
        guard isCurrentCloudWritable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "上传"
        panel.message = "选择要上传到当前云端目录的照片或视频"
        if panel.runModal() == .OK {
            uploadToCloud(panel.urls)
        }
    }

    func uploadToCloud(_ urls: [URL]) {
        guard isCurrentCloudWritable else { return }
        guard !urls.isEmpty, case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        let basePath = cloudPath
        Task {
            var uploaded = 0
            var failed = 0
            for (index, url) in urls.enumerated() {
                cloudBusyText = "上传 \(index + 1)/\(urls.count)"
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let target = basePath.isEmpty
                    ? url.lastPathComponent
                    : basePath + "/" + url.lastPathComponent
                do {
                    try await client.upload(path: target, from: url)
                    uploaded += 1
                } catch {
                    failed += 1
                }
            }
            cloudBusyText = nil
            refreshCloudDirectory()
            showToast(failed == 0
                      ? "已上传 \(uploaded) 项"
                      : "已上传 \(uploaded) 项，\(failed) 项失败")
        }
    }
}
