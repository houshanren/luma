import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

/// 经常同框的两位人物。
struct PeoplePair: Identifiable, Hashable {
    let a: UUID
    let b: UUID
    let count: Int

    var id: String {
        a.uuidString < b.uuidString
            ? "\(a.uuidString)|\(b.uuidString)"
            : "\(b.uuidString)|\(a.uuidString)"
    }
}

/// 查看器画面上的人物名标签（只带名字，头像不参与画面标注）。
struct PhotoPersonName: Identifiable, Hashable {
    let id: String
    let name: String
}

extension LibraryStore {
    // MARK: - Places

    /// 每批处理的查询格数量。分批只是为了及时把结果刷到界面上，
    /// 解析会一直推进到没有缺失坐标为止，不再「跑一批就收工」。
    static let placeResolveBatchLimit = 40

    /// 逆地理编码的查询网格：0.01° 约 1.1 km。
    /// 之前直接用照片原始坐标（0.001°，约 110 m）当查询点，一趟旅行就能切出上千个点，
    /// 请求量远超系统限流额度；吸附到 1 km 网格后请求数通常只剩几百个，同格照片共用一次结果。
    static let placeResolveCellSize = 0.01

    static func placeResolveKey(latitude: Double, longitude: Double) -> String {
        let cell = placeResolveCellSize
        let latitudeCenter = (latitude / cell).rounded(.down) * cell + cell / 2
        let longitudeCenter = (longitude / cell).rounded(.down) * cell + cell / 2
        return String(format: "%.3f,%.3f", latitudeCenter, longitudeCenter)
    }

    /// 按当前聚合层级（省 / 市 / 区县 / 街道）聚合的地点统计。按内容版本缓存：地图页会多次读取它，
    /// 每次 body 求值都重扫整库会让大图库打开地图时明显卡顿。
    ///
    /// 已有结果时先返回旧快照、后台重算：补齐地名期间内容版本会连续变化，
    /// 每次都同步重聚类的话，地图缩放会一顿一顿的。
    var placeClusters: [PlaceCluster] {
        if isCloudScope {
            let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
            if cloudModel.placeClusterCacheKey == key { return cloudModel.placeClusterCacheValue }
            let clusters = PlaceClusterBuilder.clusters(from: cloudGeoPhotos,
                                                        granularity: placeGranularity)
            cloudModel.placeClusterCacheKey = key
            cloudModel.placeClusterCacheValue = clusters
            return clusters
        }
        let key = "\(contentRevision)|\(placeGranularity.rawValue)"
        if placeClustersCacheKey == key {
            return placeClustersCacheValue
        }
        if !placeClustersCacheValue.isEmpty {
            schedulePlaceClustersRebuild(for: key)
            return placeClustersCacheValue
        }
        let clusters = PlaceClusterBuilder.clusters(from: geoPhotos,
                                                    granularity: placeGranularity)
        placeClustersCacheKey = key
        placeClustersCacheValue = clusters
        return clusters
    }

    /// 地点聚类的缓存指纹：内容版本 / 聚合层级变化，或网盘刷新后重算。
    var placeClusterToken: String {
        if isCloudScope {
            return "cloud-\(cloudModel.revision)-\(cloudModel.metadataRevision)-\(placeGranularity.rawValue)"
        }
        return "\(contentRevision)|\(placeGranularity.rawValue)"
    }

    /// 已经算好的聚类；冷启动时为 nil，页面先显示整理进度再出卡片。
    var cachedPlaceClusters: [PlaceCluster]? {
        if isCloudScope {
            let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
            return cloudModel.placeClusterCacheKey == key ? cloudModel.placeClusterCacheValue : nil
        }
        return placeClustersCacheKey == placeClusterToken ? placeClustersCacheValue : nil
    }

    /// 异步聚类：非直连索引模式下 `photosWithLocation()` 要把整库带定位照片回表，
    /// 这一步必须在后台完成，不能落在点开「位置」后的第一帧。
    func loadPlaceClusters() async -> [PlaceCluster] {
        if isCloudScope {
            let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
            if cloudModel.placeClusterCacheKey == key { return cloudModel.placeClusterCacheValue }
            let source = cloudGeoPhotos
            let granularity = placeGranularity
            let clusters = await Task.detached(priority: .userInitiated) {
                PlaceClusterBuilder.clusters(from: source, granularity: granularity)
            }.value
            guard !Task.isCancelled else { return clusters }
            cloudModel.placeClusterCacheKey = key
            cloudModel.placeClusterCacheValue = clusters
            return clusters
        }
        let key = placeClusterToken
        if placeClustersCacheKey == key { return placeClustersCacheValue }
        let granularity = placeGranularity
        let source = await loadGeoPhotosAsync()
        let clusters = await Task.detached(priority: .userInitiated) {
            PlaceClusterBuilder.clusters(from: source, granularity: granularity)
        }.value
        guard !Task.isCancelled else { return clusters }
        placeClustersCacheKey = key
        placeClustersCacheValue = clusters
        pendingPlaceClustersKey = ""
        placeClustersRevision &+= 1
        return clusters
    }

    /// 带位置照片的后台版本：系统索引模式把整表回表放到后台并复用缓存，
    /// 本地 / 网盘仍走内存数组过滤（数量与耗时都很小）。
    private func loadGeoPhotosAsync() async -> [PhotoItem] {
        guard isSystemScope, let index = systemIndex else { return geoPhotos }
        let key = "sys-\(systemIndexSignature)"
        if systemGeoCacheKey == key { return systemGeoCache }
        let overlays = systemOverlays
        let nativeKeywords = systemNativeKeywordIDMap
        let native = isNativeContainer
        let raw = await Task.detached(priority: .userInitiated) {
            index.photosWithLocation()
        }.value
        let photos = raw.map {
            Self.applyingOverlays($0, overlays: overlays, nativeKeywords: nativeKeywords, isNative: native)
        }.filter { $0.hasLocation }
        guard !Task.isCancelled else { return photos }
        systemGeoCacheKey = key
        systemGeoCache = photos
        return photos
    }

    /// 按国家 / 地区分组（外部传入聚类时使用，避免页面 body 再读整库）。
    func placeGroups(of clusters: [PlaceCluster]) -> [(title: String, clusters: [PlaceCluster])] {
        makePlaceGroups(from: clusters)
    }

    /// 后台重聚类：同一版本只排一次，新版本会取消旧任务。
    private func schedulePlaceClustersRebuild(for key: String) {
        guard pendingPlaceClustersKey != key else { return }
        pendingPlaceClustersKey = key
        let source = geoPhotos
        let granularity = placeGranularity
        placeClustersBuildToken &+= 1
        let token = placeClustersBuildToken
        tasks.cancel(.placeClusters)
        tasks.adopt(.placeClusters, Task { [weak self] in
            let clusters = await Task.detached(priority: .userInitiated) {
                PlaceClusterBuilder.clusters(from: source, granularity: granularity)
            }.value
            guard let self, !Task.isCancelled, self.placeClustersBuildToken == token else { return }
            self.placeClustersCacheKey = key
            self.placeClustersCacheValue = clusters
            self.pendingPlaceClustersKey = ""
            // 只通知「聚类更新了」，不推进整库内容版本：否则地图又会整体重算一遍。
            self.placeClustersRevision &+= 1
        })
    }

    /// 地图标注版本：聚类结果只随这些状态变化，供地图按版本重建标注。
    var placeClusterVersion: String {
        if isCloudScope {
            return "\(cloudModel.revision)-\(cloudModel.metadataRevision)-\(placeGranularity.rawValue)"
        }
        return "\(contentRevision)-\(systemIndexSignature)-\(placeGranularity.rawValue)"
    }

    /// 地图数据是否还在后台分批补齐：直连 geo 预热、系统图库扫描、聚类重算或地点补名任一进行中。
    /// 地图页据此持续刷新图钉与「视野内」统计，不必等用户拖动地图才更新。
    var isMapDataWarmingUp: Bool {
        if isLoadingSystemLibrary || isResolvingPlaces { return true }
        if !pendingPlaceClustersKey.isEmpty { return true }
        guard let index = systemIndex, index.direct != nil else { return false }
        return index.directGeoWarmupTask != nil
    }

    /// 按国家/地区分组，中国大陆优先。
    /// 键跟随聚类缓存的实际版本：聚类在后台更新后，分组也会跟着重算。
    var placeGroups: [(title: String, clusters: [PlaceCluster])] {
        if isCloudScope {
            let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)-\(placeGranularity.rawValue)"
            if cloudModel.placeGroupCacheKey == key { return cloudModel.placeGroupCacheValue }
            let clusterKey = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
            let groups = makePlaceGroups(from: cloudModel.placeClusterCacheKey == clusterKey
                                         ? cloudModel.placeClusterCacheValue
                                         : placeClusters)
            cloudModel.placeGroupCacheKey = key
            cloudModel.placeGroupCacheValue = groups
            return groups
        }
        let key = "\(placeClustersCacheKey)|\(placeGranularity.rawValue)"
        if placeGroupsCacheKey == key { return placeGroupsCacheValue }
        let groups = makePlaceGroups(from: placeClusters)
        placeGroupsCacheKey = key
        placeGroupsCacheValue = groups
        return groups
    }

    private func makePlaceGroups(from clusters: [PlaceCluster]) -> [(title: String, clusters: [PlaceCluster])] {
        var buckets: [String: [PlaceCluster]] = [:]
        for cluster in clusters {
            buckets[cluster.group, default: []].append(cluster)
        }
        let titles = buckets.keys.sorted { lhs, rhs in
            if lhs == "中国大陆" { return true }
            if rhs == "中国大陆" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return titles.compactMap { title in
            guard let clusters = buckets[title] else { return nil }
            return (title, clusters)
        }
    }

    /// 换库 / 重扫时清掉地图派生缓存。
    func resetPlaceCaches() {
        geoPhotosCacheKey = -1
        geoPhotosCacheValue = []
        // 新图库要允许重新补齐地名。
        placeResolveFailedKeys.removeAll()
        resetPlaceClusterCaches()
    }

    /// 只让聚类与分组缓存失效：切换聚合层级、补齐地名后需要重算。
    /// 保留旧结果不清空——清空会让下一次 body 求值同步重扫整库，
    /// 补地名期间版本连续变化，那样地图缩放会持续卡顿；旧结果由后台重算替换。
    func resetPlaceClusterCaches() {
        placeClustersCacheKey = ""
        placeGroupsCacheKey = ""
        cloudModel.placeClusterCacheKey = ""
        cloudModel.placeGroupCacheKey = ""
        pendingPlaceClustersKey = ""
        placeClustersBuildToken &+= 1
        tasks.cancel(.placeClusters)
    }

    func openPlace(_ cluster: PlaceCluster) {
        selectedPlace = cluster
        selection.removeAll()
        viewerID = nil
    }

    func closePlace() {
        selectedPlace = nil
        selection.removeAll()
    }

    /// 地点摘要：到访轨迹、四季、时段、地标与同行人物。
    /// 照片排序、统计与同框人物（含直连索引查询）全部放到后台：
    /// 热门地点上千张照片时，打开卡片也不会卡住主线程；重进同一个地点直接命中缓存。
    func placeInsightAsync(for place: PlaceCluster) async -> PlaceInsight {
        let photos = place.photos.filter { $0.deletedAt == nil && !$0.isHidden }
        // 轨迹融合依赖端侧标签，分析完成后要重新生成摘要：把三种来源的分析数量纳入缓存键。
        let analysisSignature = "\(analysisIndex.count)|\(systemAnalysisIndex.count)|\(cloudModel.analysis.count)"
        let key = "\(place.id)|\(photos.count)|\(contentRevision)|\(systemIndexSignature)|\(analysisSignature)"
        if placeInsightCacheKey == key, let cached = placeInsightCacheValue { return cached }

        let isSystem = isSystemScope
        let systemPeople = isSystem ? self.systemPeople : []
        let directIndex = (isSystem && systemIndex?.direct != nil) ? systemIndex : nil
        if !isSystem { loadFaceDataIfNeeded() }
        let localPeople = isSystem ? [] : self.localPeople
        // 轨迹融合需要「照片 → 视觉标签」与「照片 → 已命名人物」两张轻量表；
        // 只取当前地点的照片，避免把整库字典带进后台任务。
        let photoIDs = Set(photos.map(\.id))
        let labelsByPhoto = analysisLabelsByPhoto(for: photoIDs)
        let peopleByPhoto = peopleNamesByPhoto(for: photoIDs)
        let insight = await Task.detached(priority: .userInitiated) {
            let companions = Self.makePlaceCompanions(photos: photos,
                                                      isSystem: isSystem,
                                                      systemPeople: systemPeople,
                                                      localPeople: localPeople,
                                                      directIndex: directIndex)
            return PlaceInsight.make(place: place,
                                     photos: photos,
                                     companions: companions,
                                     labelsByPhoto: labelsByPhoto,
                                     peopleByPhoto: peopleByPhoto)
        }.value
        placeInsightCacheKey = key
        placeInsightCacheValue = insight
        return insight
    }

    /// 当前地点照片的端侧标签快照（本地 / 系统 / 网盘三种来源统一读取）。
    private func analysisLabelsByPhoto(for ids: Set<UUID>) -> [UUID: Set<String>] {
        var result: [UUID: Set<String>] = [:]
        result.reserveCapacity(ids.count)
        for id in ids {
            if let analysis = analysisIndex[id]
                ?? systemAnalysisIndex[id]
                ?? cloudModel.analysis[id] {
                result[id] = analysis.labels
            }
        }
        return result
    }

    /// 当前地点照片的已命名人物快照；同一张照片里同一个人只记一次。
    private func peopleNamesByPhoto(for ids: Set<UUID>) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        func add(_ name: String, assetIDs: [UUID]) {
            guard !name.isEmpty else { return }
            for id in assetIDs where ids.contains(id) {
                var names = result[id] ?? []
                if !names.contains(name) { names.append(name) }
                result[id] = names
            }
        }
        if isSystemScope {
            for person in systemPeople { add(person.name, assetIDs: person.assetIDs) }
        } else if isCloudScope {
            for person in cloudPeople { add(person.name, assetIDs: person.assetIDs) }
        } else {
            for person in localPeople { add(person.name, assetIDs: person.assetIDs) }
        }
        return result
    }

    /// 地点里经常同框的人物：直连模式按照片取样统计，索引模式用现成的人物↔照片映射求交集。
    nonisolated private static func makePlaceCompanions(photos: [PhotoItem],
                                                        isSystem: Bool,
                                                        systemPeople: [SystemPersonInfo],
                                                        localPeople: [LocalPerson],
                                                        directIndex: SystemIndex?) -> [PhotoCompanion] {
        let ids = Set(photos.map(\.id))
        guard !ids.isEmpty else { return [] }
        if isSystem {
            if let directIndex {
                // 直连模式没有常驻的人物↔照片映射，按地点里的照片取样统计。
                return directIndex.directCompanions(for: photos.map(\.id), limit: 3)
            }
            return systemPeople
                .compactMap { person -> PhotoCompanion? in
                    let shared = ids.intersection(person.assetIDs).count
                    guard shared >= 2 else { return nil }
                    return PhotoCompanion(id: "system-\(person.id)",
                                          name: person.name,
                                          count: shared,
                                          coverPhotoID: person.keyAssetID ?? person.assetIDs.first,
                                          coverData: person.cropData)
                }
                .sorted { $0.count > $1.count }
                .prefix(3)
                .map { $0 }
        }
        return localPeople
            .compactMap { person -> PhotoCompanion? in
                let shared = ids.intersection(person.assetIDs).count
                guard shared >= 2 else { return nil }
                return PhotoCompanion(id: person.id.uuidString,
                                      name: person.name,
                                      count: shared,
                                      coverPhotoID: person.assetIDs.first,
                                      coverData: person.coverImageData)
            }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - People

    func openPerson(_ person: SystemPersonInfo) {
        selectedPerson = person
        selection.removeAll()
        viewerID = nil
    }

    func closePerson() {
        selectedPerson = nil
        selection.removeAll()
    }

    // MARK: - 画面人物名

    /// 这张照片里已命名的人（按当前范围：拾光 / 系统图库 / 网盘）。
    /// 结果按「人物名单」缓存，查看器重绘（缩放、悬停、翻页）不会反复扫聚类。
    func personNames(for photoID: UUID) -> [PhotoPersonName] {
        let key = photoPersonNamesKey
        if photoPersonNamesIndexKey != key {
            photoPersonNamesIndex = buildPhotoPersonNamesIndex()
            photoPersonNamesIndexKey = key
        }
        return photoPersonNamesIndex[photoID] ?? []
    }

    private var photoPersonNamesKey: String {
        if isCloudScope {
            let people = cloudPeople
            return "cloud|\(people.count)|\(people.reduce(0) { $0 + $1.assetIDs.count })|"
                + people.map(\.name).joined(separator: "\u{1}")
        }
        if isSystemScope {
            return "system|\(systemPeople.count)|\(systemPeople.reduce(0) { $0 + $1.assetIDs.count })|"
                + systemPeople.map(\.name).joined(separator: "\u{1}")
        }
        return "local|\(localPeople.count)|\(localPeople.reduce(0) { $0 + $1.assetIDs.count })|"
            + localPeople.map(\.name).joined(separator: "\u{1}")
    }

    private func buildPhotoPersonNamesIndex() -> [UUID: [PhotoPersonName]] {
        var index: [UUID: [PhotoPersonName]] = [:]
        func add(id: String, name: String, assetIDs: [UUID]) {
            guard let display = Self.displayablePersonName(name) else { return }
            let tag = PhotoPersonName(id: id, name: display)
            for assetID in assetIDs {
                var list = index[assetID, default: []]
                guard !list.contains(where: { $0.name == display }) else { continue }
                list.append(tag)
                index[assetID] = list
            }
        }
        if isCloudScope {
            for person in cloudPeople {
                add(id: "cloud-\(person.id)", name: person.name, assetIDs: person.assetIDs)
            }
        } else if isSystemScope {
            for person in systemPeople where !person.isPet {
                add(id: "system-\(person.id)", name: person.name, assetIDs: person.assetIDs)
            }
        } else {
            for person in localPeople {
                add(id: "local-\(person.id)", name: person.name, assetIDs: person.assetIDs)
            }
        }
        return index
    }

    /// 系统图库未命名的聚类叫「未命名」，本地聚类默认叫「人物 1」这类占位名；都别打到照片上。
    private static func displayablePersonName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "未命名" else { return nil }
        if trimmed.hasPrefix("人物 "), Int(trimmed.dropFirst(3)) != nil { return nil }
        return trimmed
    }

    // MARK: - 端侧人物聚类（本地图库）

    /// 懒加载已保存的人物聚类结果，避免启动时读取大量数据。
    func loadFaceDataIfNeeded() {
        guard !faceDataLoaded else { return }
        faceDataLoaded = true
        let stored = metadataStore?.loadPeople() ?? []
        // 照片被永久删除后，聚类里可能残留已不存在的关系；载入时就地清理，人物没有照片则移除。
        let known = Set(photos.map(\.id))
        let pruned = stored.compactMap { person -> LocalPerson? in
            var person = person
            person.assetIDs = person.assetIDs.filter { known.contains($0) }
            return person.assetIDs.isEmpty ? nil : person
        }
        localPeople = pruned
        if pruned != stored {
            metadataStore?.savePeople(pruned)
        }
        scannedFaceIDs = metadataStore?.loadScannedFaceIDs() ?? []
    }

    /// 还没做过人脸分析的照片数：增量识别的入口用它显示「剩余 N 张」。
    /// 按内容版本 + 已扫描数量缓存，避免侧边栏 / 工具栏重绘时反复遍历整库。
    var pendingFacePhotoCount: Int {
        let key = "\(contentRevision)|\(scannedFaceIDs.count)|\(photos.count)"
        if facePendingCacheKey != key {
            var count = 0
            for photo in photos where !photo.isVideo && photo.deletedAt == nil
                && !scannedFaceIDs.contains(photo.id) {
                count += 1
            }
            facePendingCacheValue = count
            facePendingCacheKey = key
        }
        return facePendingCacheValue
    }

    func startFaceClustering() {
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘不支持人物分析")
            return
        }
        guard !isClusteringFaces else { return }
        loadFaceDataIfNeeded()

        let pending = photos.filter {
            !$0.isVideo && $0.deletedAt == nil && !scannedFaceIDs.contains($0.id)
        }
        guard !pending.isEmpty else {
            showToast("所有照片都已完成人物分析")
            return
        }

        let token = UUID()
        faceClusterToken = token
        isClusteringFaces = true
        faceClusterProgress = FaceClusterProgress(processed: 0,
                                                  total: pending.count,
                                                  faces: 0,
                                                  people: localPeople.count)
        let libraryPath = (LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
            .standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(libraryPath), kind: .cluster, title: "人脸聚类"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelFaceClustering() }
            }
        )

        tasks.adopt(.faceCluster, Task { [weak self] in
            guard let self else { return }
            var people = self.localPeople
            var scanned = self.scannedFaceIDs
            var faces = 0
            var processed = 0

            for photo in pending {
                if Task.isCancelled { break }
                let samples = await Task.detached(priority: .utility) {
                    FaceClusterEngine.analyze(photo: photo)
                }.value
                // 期间点了「重新识别」：旧任务不再写回。
                guard self.faceClusterToken == token else {
                    self.cancelSourceJob(jobID)
                    return
                }
                for sample in samples {
                    FaceClusterEngine.assign(sample, to: &people)
                    faces += 1
                }
                scanned.insert(photo.id)
                processed += 1

                if processed % 5 == 0 || processed == pending.count {
                    let refined = FaceClusterEngine.refined(people)
                    self.faceClusterProgress = FaceClusterProgress(processed: processed,
                                                                   total: pending.count,
                                                                   faces: faces,
                                                                   people: refined.count)
                    self.updateSourceJob(jobID,
                                         completed: processed,
                                         total: pending.count,
                                         message: "已分析 \(processed) / \(pending.count) 张 · \(refined.count) 位人物")
                }
                // 定期落盘，长时间分析中途退出也不会丢结果。
                if processed % 200 == 0 {
                    let refined = FaceClusterEngine.refined(people)
                    self.localPeople = refined
                    self.scannedFaceIDs = scanned
                    self.metadataStore?.savePeople(refined)
                    self.metadataStore?.saveScannedFaceIDs(scanned)
                }
            }

            guard self.faceClusterToken == token else {
                self.cancelSourceJob(jobID)
                return
            }
            let refined = FaceClusterEngine.refined(people)
            self.localPeople = refined
            self.scannedFaceIDs = scanned
            self.metadataStore?.savePeople(refined)
            self.metadataStore?.saveScannedFaceIDs(scanned)
            self.isClusteringFaces = false
            self.faceClusterProgress = nil
            self.tasks.finish(.faceCluster)

            if Task.isCancelled {
                self.cancelSourceJob(jobID)
                self.showToast("已停止人物分析")
            } else if refined.isEmpty {
                self.finishSourceJob(jobID, message: "分析完成 · 未发现人物")
                self.showToast("分析完成，未发现可聚类的人物")
            } else {
                self.finishSourceJob(jobID, message: "分析完成 · \(refined.count) 位人物")
                self.showToast("人物分析完成，共 \(refined.count) 位")
            }
        })
    }

    /// 清空已扫描记录与聚类结果，从头重新识别当前图库的全部照片。
    /// 人物命名也在聚类结果里，会被一并清除（界面上先做二次确认）。
    func resetFaceAnalysis() {
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘不支持人物分析")
            return
        }
        loadFaceDataIfNeeded()
        // 换标识让正在跑的任务直接作废，避免它把旧结果写回来。
        faceClusterToken = UUID()
        tasks.cancel(.faceCluster)
        isClusteringFaces = false
        faceClusterProgress = nil
        scannedFaceIDs = []
        localPeople = []
        facePendingCacheKey = ""
        metadataStore?.savePeople([])
        metadataStore?.saveScannedFaceIDs([])
        startFaceClustering()
    }

    func cancelFaceClustering() {
        tasks.cancel(.faceCluster)
    }

    func closeLocalPerson() {
        selectedLocalPersonID = nil
    }

    /// 当前有可见照片的人物：照片全部移入最近删除或被隐藏后不再展示，恢复后自动回来。
    /// 过滤要扫一遍全库，按内容版本缓存：人物页每次重绘都重算会让整页明显掉帧。
    var visibleLocalPeople: [LocalPerson] {
        guard faceDataLoaded, !localPeople.isEmpty else { return localPeople }
        let key = visibleLocalPeopleCacheKeyValue
        if key == visibleLocalPeopleCacheKey { return visibleLocalPeopleCacheValue }
        let alive = Set(photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }.map(\.id))
        let result: [LocalPerson]
        if alive.isEmpty {
            result = []
        } else {
            result = localPeople.filter { person in
                person.assetIDs.contains { alive.contains($0) }
            }
        }
        visibleLocalPeopleCacheKey = key
        visibleLocalPeopleCacheValue = result
        return result
    }

    private var visibleLocalPeopleCacheKeyValue: String {
        // 照片内容版本 + 人物集合本身（含名字）：任一变化都重新过滤。
        var hasher = Hasher()
        for person in localPeople {
            hasher.combine(person.id)
            hasher.combine(person.assetIDs.count)
            hasher.combine(person.name)
        }
        return "\(contentRevision)|\(localPeople.count)|\(hasher.finalize())"
    }

    /// 永久删除照片后清理人物聚类里的引用；人物一张照片都不剩时一并移除。
    func removeAssetsFromLocalPeople(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        loadFaceDataIfNeeded()
        guard !localPeople.isEmpty else { return }

        var pruned: [LocalPerson] = []
        pruned.reserveCapacity(localPeople.count)
        var changed = false
        for person in localPeople {
            var person = person
            let remaining = person.assetIDs.filter { !ids.contains($0) }
            if remaining.count != person.assetIDs.count {
                person.assetIDs = remaining
                changed = true
            }
            guard !remaining.isEmpty else {
                changed = true
                continue
            }
            pruned.append(person)
        }
        guard changed else { return }

        localPeople = pruned
        if let selected = selectedLocalPersonID, !pruned.contains(where: { $0.id == selected }) {
            selectedLocalPersonID = nil
        }
        metadataStore?.savePeople(pruned)
    }

    func photos(for person: LocalPerson) -> [PhotoItem] {
        let ids = Set(person.assetIDs)
        return photos
            .filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 本地人物的「摘要」：年度轨迹、时段偏好、地点、同框人物与高光照片。
    /// 过滤 + 排序放到后台：大图库里逐张扫描会让点开人物时明显掉帧。
    func localPersonInsightAsync(for person: LocalPerson) async -> PersonInsight {
        let key = "local|\(person.id.uuidString)|\(person.assetIDs.count)|\(contentRevision)"
        if personInsightCacheKey == key, let cached = personInsightCacheValue { return cached }
        let photos = photos(for: person)
        let others = visibleLocalPeople.filter { $0.id != person.id }
        let mine = Set(person.assetIDs)
        let insight = await Task.detached(priority: .userInitiated) {
            Self.makeLocalPersonInsight(photos: photos, mine: mine, others: others)
        }.value
        personInsightCacheKey = key
        personInsightCacheValue = insight
        return insight
    }

    nonisolated private static func makeLocalPersonInsight(photos: [PhotoItem],
                                                           mine: Set<UUID>,
                                                           others: [LocalPerson]) -> PersonInsight {
        var insight = PersonInsight.make(photos: photos)
        insight.companions = others
            .compactMap { other -> PersonInsight.Companion? in
                let shared = mine.intersection(other.assetIDs).count
                guard shared >= 2 else { return nil }
                return PersonInsight.Companion(id: other.id.uuidString,
                                               name: other.name,
                                               count: shared,
                                               coverPhotoID: other.assetIDs.first,
                                               coverData: other.coverImageData)
            }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0 }
        return insight
    }

    /// 人物摘要只看这个人本身，不继承当前的筛选 / 搜索 / 排序。
    private func personInsightQuery(for person: SystemPersonInfo) -> SystemQuery {
        var query = buildSystemQuery(scope: .person(person.id))
        query.filter = .all
        query.sortKey = .capturedAt
        query.ascending = false
        query.startDate = nil
        query.endDate = nil
        query.onlyFavorites = false
        query.onlyVideos = false
        query.onlyPhotos = false
        query.onlyScreenshots = false
        query.onlyLivePhotos = false
        query.onlyEdited = false
        query.tokens = []
        query.overlayKeywordIDs = nil
        query.includeIDs = nil
        return query
    }

    /// 人物摘要：直连模式走 SQLite 聚合，扫描快照模式在内存里派生。
    /// 两条路径都放到后台执行，同一个人再次进入时直接命中缓存。
    func systemPersonInsightAsync(for person: SystemPersonInfo) async -> PersonInsight {
        let key = "system|\(person.id)|\(person.assetIDs.count)|\(systemIndexSignature)|\(contentRevision)"
        if personInsightCacheKey == key, let cached = personInsightCacheValue { return cached }
        let insight: PersonInsight
        if let index = systemIndex, index.direct != nil {
            let query = personInsightQuery(for: person)
            insight = await Task.detached(priority: .userInitiated) {
                index.personInsight(query)
            }.value
        } else {
            // 扫描快照模式：逐张过滤 + 同框统计同样不能放在主线程。
            let photos = systemPhotos
            let mine = Set(person.assetIDs)
            let others = systemPeople.filter { $0.id != person.id }
            insight = await Task.detached(priority: .userInitiated) {
                Self.makeSystemPersonInsight(photos: photos, mine: mine, others: others)
            }.value
        }
        personInsightCacheKey = key
        personInsightCacheValue = insight
        return insight
    }

    nonisolated private static func makeSystemPersonInsight(photos: [PhotoItem],
                                                            mine: Set<UUID>,
                                                            others: [SystemPersonInfo]) -> PersonInsight {
        var insight = PersonInsight.make(photos: photos
            .filter { mine.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt })
        insight.companions = others
            .compactMap { other -> PersonInsight.Companion? in
                let shared = mine.intersection(other.assetIDs).count
                guard shared >= 2 else { return nil }
                return PersonInsight.Companion(id: "system-\(other.id)",
                                               name: other.name,
                                               count: shared,
                                               coverPhotoID: other.keyAssetID ?? other.assetIDs.first,
                                               coverData: other.cropData)
            }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0 }
        return insight
    }

    // MARK: - 人物地图

    /// 本地人物的「地图」：只看这个人带有效定位的照片。
    func personMapPhotos(local person: LocalPerson) -> [PhotoItem] {
        photos(for: person).filter { $0.hasLocation }
    }

    /// 系统图库人物的「地图」：索引直接在 SQL 里裁掉没有定位的照片；
    /// 不走分页窗口，保证地图上是这个人的全量足迹。
    func personMapPhotos(system person: SystemPersonInfo) async -> [PhotoItem] {
        guard let index = systemIndex else {
            // 扫描快照模式：人物成员 ID 已在内存里，直接过滤。
            let ids = Set(person.assetIDs)
            return systemPhotos
                .filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.isHidden && $0.hasLocation }
                .sorted { $0.capturedAt > $1.capturedAt }
        }
        var query = personInsightQuery(for: person)
        query.onlyLocated = true
        let located = await Task.detached(priority: .userInitiated) {
            index.page(query, offset: 0, limit: 60_000)
        }.value
        return located.filter { $0.hasLocation }
    }

    /// 统计经常同框的人物对（同一张照片里同时出现）。
    /// 统计量随人物数与照片数增长，放到后台算，人物页打开时不再卡主线程。
    func peoplePairsAsync(limit: Int = 8) async -> [PeoplePair] {
        let people = visibleLocalPeople
        return await Task.detached(priority: .userInitiated) {
            Self.makePeoplePairs(people: people, limit: limit)
        }.value
    }

    nonisolated private static func makePeoplePairs(people: [LocalPerson],
                                                    limit: Int) -> [PeoplePair] {
        var assetPeople: [UUID: [UUID]] = [:]
        for person in people {
            for asset in person.assetIDs {
                assetPeople[asset, default: []].append(person.id)
            }
        }

        var counts: [String: Int] = [:]
        var lookup: [String: PeoplePair] = [:]
        for ids in assetPeople.values where ids.count >= 2 {
            let unique = Set(ids).sorted { $0.uuidString < $1.uuidString }
            guard unique.count >= 2 else { continue }
            for i in 0..<unique.count {
                for j in (i + 1)..<unique.count {
                    let pair = PeoplePair(a: unique[i], b: unique[j], count: 0)
                    lookup[pair.id] = pair
                    counts[pair.id, default: 0] += 1
                }
            }
        }

        return counts.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { entry in
                guard let pair = lookup[entry.key] else { return nil }
                return PeoplePair(a: pair.a, b: pair.b, count: entry.value)
            }
    }

    /// 两位人物同时出现的照片。
    func photos(for pair: PeoplePair) -> [PhotoItem] {
        guard let first = localPeople.first(where: { $0.id == pair.a }),
              let second = localPeople.first(where: { $0.id == pair.b }) else { return [] }
        let shared = Set(first.assetIDs).intersection(second.assetIDs)
        guard !shared.isEmpty else { return [] }
        return photos
            .filter { shared.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    func renameLocalPerson(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = localPeople.firstIndex(where: { $0.id == id }) else { return }
        localPeople[index].name = trimmed
        metadataStore?.savePeople(localPeople)
    }

    func deleteLocalPerson(_ id: UUID) {
        localPeople.removeAll { $0.id == id }
        if selectedLocalPersonID == id {
            selectedLocalPersonID = nil
        }
        metadataStore?.savePeople(localPeople)
    }

    func resetFaceClusterState() {
        tasks.cancel(.faceCluster)
        localPeople = []
        selectedLocalPersonID = nil
        faceClusterProgress = nil
        isClusteringFaces = false
        scannedFaceIDs = []
        faceDataLoaded = false
    }

    // MARK: - Duplicates

    /// 本地图库中按「文件大小 + 像素尺寸」聚合的重复组（含建议保留项与理由）。
    /// 结果按内容版本缓存，避免侧边栏与重复页反复遍历、排序整库。
    var duplicateGroups: [DuplicateGroup] {
        // 体检结果参与「整组决策」：模糊副本不参与保留竞争，所以缓存键要带上体检时间。
        let blurryIDs = Set((healthReport?.blurry ?? []).map(\.id))
        let healthStamp = healthReport.map { String(Int($0.scannedAt.timeIntervalSince1970)) } ?? "0"
        let key = "\(contentRevision)-\(healthStamp)-\(blurryIDs.count)"
        if duplicateGroupsCacheKey == key { return duplicateGroupsCache }
        var membership: [UUID: Int] = [:]
        for album in albums {
            for id in album.photoIDs {
                membership[id, default: 0] += 1
            }
        }
        let groups = DuplicateDetector.groups(from: photos,
                                              albumMembership: membership,
                                              blurryIDs: blurryIDs)
        duplicateGroupsCacheKey = key
        duplicateGroupsCache = groups
        return groups
    }

    /// 多余的副本张数（每个重复组只保留一张）。
    var duplicateCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.photos.count - 1 }
    }

    /// 合并一组重复项目：保留 `keepID`，把其余副本的收藏、关键词、标题、地点与相簿关系汇总过来，
    /// 再将这些副本移入最近删除（30 天内可恢复）。返回被移入最近删除的张数。
    @discardableResult
    func mergeDuplicateGroup(_ group: DuplicateGroup, keeping keepID: UUID) -> Int {
        let beforePhotos = photoSnapshot(Set(group.photos.map(\.id)))
        let beforeAlbums = albums
        let removed = applyDuplicateMerge(group.photos, keeping: keepID)
        guard removed > 0 else { return 0 }
        save()
        recordUndo("合并重复项目", beforePhotos: beforePhotos, beforeAlbums: beforeAlbums)
        showToast("已合并 \(removed + 1) 个项目，保留 1 个版本")
        return removed
    }

    /// 一键合并全部重复组：每组保留推荐版本，只落盘一次。返回（组数，移入最近删除的张数）。
    @discardableResult
    func mergeAllDuplicateGroups() -> (groups: Int, removed: Int) {
        guard !isReadOnlyScope else { return (0, 0) }
        let beforePhotos = photoSnapshot(Set(duplicateGroups.flatMap { $0.photos.map(\.id) }))
        let beforeAlbums = albums
        var mergedGroups = 0
        var removed = 0
        for group in duplicateGroups {
            let count = applyDuplicateMerge(group.photos, keeping: group.keepID)
            if count > 0 {
                mergedGroups += 1
                removed += count
            }
        }
        guard removed > 0 else { return (0, 0) }
        save()
        recordUndo("合并全部重复项目", beforePhotos: beforePhotos, beforeAlbums: beforeAlbums)
        showToast("已合并 \(mergedGroups) 组重复项目，\(removed) 个副本移入最近删除")
        return (mergedGroups, removed)
    }

    /// 在内存中完成合并（不落盘），供单组与批量合并共用。
    private func applyDuplicateMerge(_ members: [PhotoItem], keeping keepID: UUID) -> Int {
        guard !isReadOnlyScope,
              let keepIndex = photos.firstIndex(where: { $0.id == keepID }) else { return 0 }
        let removeIDs = Set(members.map(\.id)).subtracting([keepID])
        guard !removeIDs.isEmpty else { return 0 }

        var kept = photos[keepIndex]
        var keywords = Set(kept.keywords ?? [])
        for other in members where removeIDs.contains(other.id) {
            kept.isFavorite = kept.isFavorite || other.isFavorite
            if other.starRating > kept.starRating { kept.rating = other.rating }
            if kept.pickFlag == .none, other.pickFlag != .none { kept.flag = other.flag }
            if kept.labelColor == .none, other.labelColor != .none { kept.colorLabel = other.colorLabel }
            if kept.contentHash == nil { kept.contentHash = other.contentHash }
            if kept.perceptualHash == nil { kept.perceptualHash = other.perceptualHash }
            keywords.formUnion(other.keywords ?? [])
            if (kept.title ?? "").isEmpty, let title = other.title, !title.isEmpty {
                kept.title = title
            }
            if kept.capturedAt > other.capturedAt {
                kept.capturedAt = other.capturedAt
            }
            if let viewed = other.viewedAt, viewed > (kept.viewedAt ?? .distantPast) {
                kept.viewedAt = viewed
            }
            if kept.latitude == nil, let latitude = other.latitude, let longitude = other.longitude {
                kept.latitude = latitude
                kept.longitude = longitude
            }
            if kept.placeCountry == nil { kept.placeCountry = other.placeCountry }
            if kept.placeProvince == nil { kept.placeProvince = other.placeProvince }
            if kept.placeCity == nil { kept.placeCity = other.placeCity }
            if kept.placeDistrict == nil { kept.placeDistrict = other.placeDistrict }
            if kept.placePOI == nil { kept.placePOI = other.placePOI }
        }
        if !keywords.isEmpty {
            kept.keywords = Array(keywords).sorted()
        }
        photos[keepIndex] = kept

        let now = Date()
        for index in photos.indices where removeIDs.contains(photos[index].id) {
            photos[index].deletedAt = now
        }

        // 相簿关系汇总：保留项补进副本所在的相簿，并修正被删副本占用的封面。
        for index in albums.indices {
            let containedRemoved = albums[index].photoIDs.contains { removeIDs.contains($0) }
            albums[index].photoIDs.removeAll { removeIDs.contains($0) }
            if containedRemoved, !albums[index].photoIDs.contains(keepID) {
                albums[index].photoIDs.insert(keepID, at: 0)
            }
            if let cover = albums[index].coverPhotoID, removeIDs.contains(cover) {
                albums[index].coverPhotoID = keepID
            }
        }

        if let viewerID, removeIDs.contains(viewerID) {
            self.viewerID = nil
        }
        selection.removeAll()
        duplicateGroupsCacheKey = nil
        return removeIDs.count
    }

    /// 「位置」页首次打开时等后台地图样本就绪，避免在只取到最近几张的旧样本上做逆地理编码。
    func awaitDirectGeoIfNeeded() async {
        guard let index = systemIndex, index.direct != nil else { return }
        if let task = index.directGeoWarmupTask { await task.value }
    }

    /// 照片缺少地名时，用系统逆地理编码补齐（结果写入本地缓存）。
    /// 官方图库只补内存，不回写数据库。
    /// 解析会按网格分批推进，直到没有缺失坐标为止；中途失败（系统限流）会再补两轮。
    func resolveMissingPlacesIfNeeded() {
        if isCloudScope {
            resolveMissingCloudPlacesIfNeeded()
            return
        }
        guard !isResolvingPlaces else { return }
        // 系统图库索引模式用地图的全量带位置照片补齐地名，不遍历整库。
        let source: [PhotoItem]
        if isSystemScope {
            source = systemIndex != nil ? geoPhotos : systemPhotos
        } else {
            source = photos
        }
        let missing = source.filter {
            $0.deletedAt == nil
                && $0.hasLocation
                && $0.placeCity == nil && $0.placeDistrict == nil && $0.placeProvince == nil
        }
        guard !missing.isEmpty else { return }
        loadPlaceCacheIfNeeded()

        var grouped: [String: (latitude: Double, longitude: Double, ids: [UUID])] = [:]
        for photo in missing {
            guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
            let key = Self.placeResolveKey(latitude: latitude, longitude: longitude)
            // 本次会话已经失败的格子不再反复请求；重启应用后会重新尝试。
            guard !placeResolveFailedKeys.contains(key) else { continue }
            if var entry = grouped[key] {
                entry.ids.append(photo.id)
                grouped[key] = entry
            } else {
                grouped[key] = (latitude, longitude, [photo.id])
            }
        }
        // 同格照片越多越优先：先补大块，「其他地点」能最快缩下去。
        let entries = grouped.values.sorted { $0.ids.count > $1.ids.count }
        guard !entries.isEmpty else { return }

        let scopedToSystemLibrary = isSystemScope
        let usesDirectGeo = systemIndex?.direct != nil
        isResolvingPlaces = true
        placeResolveTotal = entries.count
        placeResolveDone = 0
        let placesPath = scopedToSystemLibrary
            ? (systemLibraryPath ?? "")
            : (LibraryPaths.containerLibraryURL ?? LibraryPaths.root).standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(placesPath),
                      kind: .places,
                      title: "补齐照片地点",
                      isCancellable: false)
        )

        Task { [weak self] in
            guard let self else { return }
            // 先建一次 id → 下标索引：逐条地理编码时再扫整库会是大图库的主要卡顿来源。
            var mediaIndices: [UUID: Int] = [:]
            var geoIndices: [UUID: Int] = [:]
            // 直连模式的地图数据在 directGeoPhotos 里，不是 systemGeoCache：
            // 之前往 systemGeoCache 写，地名永远落不进去，missing 不减就等于无限循环。
            var directGeoWorking: [PhotoItem] = []
            /// 已发布的 geo 快照索引：直连模式下把新地名同步写进去，
            /// 这样 geoPhotos 不必整体失效后重新叠加一遍元数据。
            var systemGeoIndices: [UUID: Int] = [:]
            if scopedToSystemLibrary {
                if usesDirectGeo, let directGeo = self.systemIndex?.directGeoPhotos {
                    directGeoWorking = directGeo
                    for (index, photo) in directGeo.enumerated() { geoIndices[photo.id] = index }
                    for (index, photo) in self.systemGeoCache.enumerated() {
                        systemGeoIndices[photo.id] = index
                    }
                } else if self.systemIndex != nil {
                    for (index, photo) in self.systemGeoCache.enumerated() { geoIndices[photo.id] = index }
                } else {
                    for (index, photo) in self.systemPhotos.enumerated() { mediaIndices[photo.id] = index }
                }
            } else {
                for (index, photo) in self.photos.enumerated() { mediaIndices[photo.id] = index }
            }

            var pending = entries
            var attempt = 0
            var lastPublish = Date()
            /// 界面刷新节流：重聚类与地图统计都是全库级计算，每批都跑会持续打断缩放。
            let publishInterval: TimeInterval = 1.2
            while !pending.isEmpty, attempt < 3 {
                if attempt > 0 {
                    // 系统逆地理编码会限流：失败的坐标隔几秒再补一轮，仍失败就记下来不再空转。
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                attempt += 1
                var failed: [(latitude: Double, longitude: Double, ids: [UUID])] = []
                while !pending.isEmpty {
                    let chunk = Array(pending.prefix(Self.placeResolveBatchLimit))
                    pending.removeFirst(chunk.count)
                    for entry in chunk {
                        let cacheKey = Self.placeResolveKey(latitude: entry.latitude,
                                                           longitude: entry.longitude)
                        var info: PlaceInfo?
                        if let cached = self.placeCache[cacheKey], !cached.isEmpty {
                            info = cached
                        } else {
                            info = await self.reverseGeocode(latitude: entry.latitude,
                                                             longitude: entry.longitude)
                            if info == nil { failed.append(entry) }
                        }
                        if let info {
                            if scopedToSystemLibrary {
                                if usesDirectGeo {
                                    for id in entry.ids {
                                        guard let index = geoIndices[id], index < directGeoWorking.count,
                                              directGeoWorking[index].id == id else { continue }
                                        self.applyPlace(info, to: &directGeoWorking[index])
                                        // 已发布的快照同步更新，下一次读 geoPhotos 不必整体重算。
                                        if let geoIndex = systemGeoIndices[id],
                                           geoIndex < self.systemGeoCache.count,
                                           self.systemGeoCache[geoIndex].id == id {
                                            self.applyPlace(info, to: &self.systemGeoCache[geoIndex])
                                        }
                                    }
                                } else if self.systemIndex != nil {
                                    for id in entry.ids {
                                        // 后台样本 / 地图缓存随时可能整体替换，越界或错位就跳过。
                                        guard let index = geoIndices[id], index < self.systemGeoCache.count,
                                              self.systemGeoCache[index].id == id else { continue }
                                        self.applyPlace(info, to: &self.systemGeoCache[index])
                                    }
                                } else {
                                    for id in entry.ids {
                                        guard let index = mediaIndices[id], index < self.systemPhotos.count,
                                              self.systemPhotos[index].id == id else { continue }
                                        self.applyPlace(info, to: &self.systemPhotos[index])
                                    }
                                }
                            } else {
                                for id in entry.ids {
                                    guard let index = mediaIndices[id], index < self.photos.count,
                                          self.photos[index].id == id else { continue }
                                    self.applyPlace(info, to: &self.photos[index])
                                }
                            }
                        }
                        if attempt == 1 {
                            self.placeResolveDone += 1
                            self.updateSourceJob(jobID,
                                                 completed: self.placeResolveDone,
                                                 total: entries.count,
                                                 message: "已补齐 \(self.placeResolveDone) / \(entries.count) 个地点")
                        }
                        if info == nil {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                    // 每批结束把新地名写回数据源，但界面刷新按 1.2 秒节流：
                    // 每次刷新都要重聚类 + 重算地图统计，跟着每批跑会持续打断缩放。
                    if usesDirectGeo, !directGeoWorking.isEmpty {
                        self.systemIndex?.directGeoPhotos = directGeoWorking
                    }
                    if Date().timeIntervalSince(lastPublish) >= publishInterval {
                        lastPublish = Date()
                        self.resetPlaceClusterCaches()
                        self.contentRevision &+= 1
                        self.savePlaceCache()
                    }
                }
                pending = failed
            }
            for entry in pending {
                self.placeResolveFailedKeys.insert(Self.placeResolveKey(latitude: entry.latitude,
                                                                       longitude: entry.longitude))
            }
            if !scopedToSystemLibrary {
                self.save()
            }
            // 新解析出的地名要让地点聚类重新计算，并通知界面刷新。
            self.resetPlaceClusterCaches()
            self.contentRevision &+= 1
            self.savePlaceCache()
            self.isResolvingPlaces = false
            self.finishSourceJob(jobID, message: "已补齐 \(self.placeResolveDone) 个地点")
        }
    }

    func applyPlace(_ info: PlaceInfo, to photo: inout PhotoItem) {
        photo.placeCountry = info.country
        photo.placeProvince = info.province
        photo.placeCity = info.city
        photo.placeDistrict = info.district
        photo.placePOI = info.poi
    }

    func reverseGeocode(latitude: Double, longitude: Double) async -> PlaceInfo? {
        let key = Self.placeResolveKey(latitude: latitude, longitude: longitude)
        if let cached = placeCache[key], !cached.isEmpty { return cached }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(
            location, preferredLocale: Locale(identifier: "zh_CN")
        ), let placemark = placemarks.first {
            // 具体景点优先：areasOfInterest 会给出「外滩 / 故宫 / 西湖」这类地标名，
            // thoroughfare 只是街道。没有地标时才退回街道，最后用 name 兜底。
            let landmark = placemark.areasOfInterest?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            var info = PlaceInfo(country: placemark.country,
                                 province: placemark.administrativeArea,
                                 city: placemark.locality ?? placemark.subAdministrativeArea,
                                 district: placemark.subLocality,
                                 poi: landmark ?? placemark.thoroughfare)
            // 海上 / 景区坐标常常只有 name，没有行政区字段；用它兜底，至少别退回坐标卡片。
            if info.isEmpty { info.poi = placemark.name }
            if !info.isEmpty {
                placeCache[key] = info
                return info
            }
        }
        // 系统逆地理编码在境外坐标上会直接返回空结果，这里用内置城市库补到城市级。
        if let fallback = await WorldCityIndex.shared.place(latitude: latitude,
                                                            longitude: longitude) {
            placeCache[key] = fallback
            return fallback
        }
        // 空结果不写缓存：限流或网络失败时下次还能重试。
        return nil
    }

    func loadPlaceCacheIfNeeded() {
        guard !placeCacheLoaded else { return }
        placeCacheLoaded = true
        guard let data = try? Data(contentsOf: Self.placeCacheURL),
              let decoded = try? JSONDecoder().decode([String: PlaceInfo].self, from: data) else { return }
        placeCache = decoded
    }

    func savePlaceCache() {
        guard let data = try? JSONEncoder().encode(placeCache) else { return }
        try? data.write(to: Self.placeCacheURL, options: .atomic)
    }

    static var placeCacheURL: URL {
        LibraryPaths.applicationRoot.appendingPathComponent("PlaceCache.json")
    }

    var shareURLs: [URL] {
        let ids: [UUID]
        if !selection.isEmpty {
            ids = Array(selection)
        } else if let viewerID {
            ids = [viewerID]
        } else {
            ids = []
        }
        return photos(forIDs: ids)
            .filter { !$0.isCloud }
            .prefix(10)
            .map { LibraryPaths.sourceURL(for: $0) }
    }

    var currentIsFavorite: Bool {
        if let viewerID, let photo = anyPhoto(id: viewerID) {
            return photo.isFavorite
        }
        let selected = photos(forIDs: selection)
        return !selected.isEmpty && selected.allSatisfy { $0.isFavorite }
    }

    func containsInCurrentView(_ id: UUID) -> Bool {
        visiblePhotos.contains(where: { $0.id == id })
    }
}
