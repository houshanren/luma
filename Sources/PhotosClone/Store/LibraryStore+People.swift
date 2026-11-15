import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

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

extension LibraryStore {
    // MARK: - Places

    /// 按「城市 / 区县」聚合的地点统计。
    var placeClusters: [PlaceCluster] {
        PlaceClusterBuilder.clusters(from: geoPhotos)
    }

    /// 按国家/地区分组，中国大陆优先。
    var placeGroups: [(title: String, clusters: [PlaceCluster])] {
        var buckets: [String: [PlaceCluster]] = [:]
        for cluster in placeClusters {
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

    func openPlace(_ cluster: PlaceCluster) {
        selectedPlace = cluster
        selection.removeAll()
        viewerID = nil
    }

    func closePlace() {
        selectedPlace = nil
        selection.removeAll()
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

        isClusteringFaces = true
        faceClusterProgress = FaceClusterProgress(processed: 0,
                                                  total: pending.count,
                                                  faces: 0,
                                                  people: localPeople.count)

        faceClusterTask = Task { [weak self] in
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

            let refined = FaceClusterEngine.refined(people)
            self.localPeople = refined
            self.scannedFaceIDs = scanned
            self.metadataStore?.savePeople(refined)
            self.metadataStore?.saveScannedFaceIDs(scanned)
            self.isClusteringFaces = false
            self.faceClusterProgress = nil
            self.faceClusterTask = nil

            if Task.isCancelled {
                self.showToast("已停止人物分析")
            } else if refined.isEmpty {
                self.showToast("分析完成，未发现可聚类的人物")
            } else {
                self.showToast("人物分析完成，共 \(refined.count) 位")
            }
        }
    }

    func cancelFaceClustering() {
        faceClusterTask?.cancel()
    }

    func closeLocalPerson() {
        selectedLocalPersonID = nil
    }

    /// 当前有可见照片的人物：照片全部移入最近删除或被隐藏后不再展示，恢复后自动回来。
    var visibleLocalPeople: [LocalPerson] {
        guard faceDataLoaded, !localPeople.isEmpty else { return localPeople }
        let alive = Set(photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }.map(\.id))
        guard !alive.isEmpty else { return [] }
        return localPeople.filter { person in
            person.assetIDs.contains { alive.contains($0) }
        }
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

    /// 统计经常同框的人物对（同一张照片里同时出现）。
    func peoplePairs(limit: Int = 8) -> [PeoplePair] {
        var assetPeople: [UUID: [UUID]] = [:]
        for person in visibleLocalPeople {
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
        faceClusterTask?.cancel()
        faceClusterTask = nil
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
        let key = "\(contentRevision)"
        if duplicateGroupsCacheKey == key { return duplicateGroupsCache }
        var membership: [UUID: Int] = [:]
        for album in albums {
            for id in album.photoIDs {
                membership[id, default: 0] += 1
            }
        }
        let groups = DuplicateDetector.groups(from: photos, albumMembership: membership)
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
        let removed = applyDuplicateMerge(group.photos, keeping: keepID)
        guard removed > 0 else { return 0 }
        save()
        showToast("已合并 \(removed + 1) 个项目，保留 1 个版本")
        return removed
    }

    /// 一键合并全部重复组：每组保留推荐版本，只落盘一次。返回（组数，移入最近删除的张数）。
    @discardableResult
    func mergeAllDuplicateGroups() -> (groups: Int, removed: Int) {
        guard !isReadOnlyScope else { return (0, 0) }
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

    /// 照片缺少地名时，用系统逆地理编码补齐（结果写入本地缓存）。
    /// 官方图库只补内存，不回写数据库。
    func resolveMissingPlacesIfNeeded() {
        guard !isResolvingPlaces, !placeResolveAttempted else { return }
        let source = isSystemScope ? systemPhotos : photos
        let missing = source.filter {
            $0.deletedAt == nil
                && $0.hasLocation
                && $0.placeCity == nil && $0.placeDistrict == nil && $0.placeProvince == nil
        }
        guard !missing.isEmpty else { return }
        placeResolveAttempted = true
        loadPlaceCacheIfNeeded()

        var grouped: [String: (latitude: Double, longitude: Double, ids: [UUID])] = [:]
        for photo in missing {
            guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
            let key = String(format: "%.3f,%.3f", latitude, longitude)
            if var entry = grouped[key] {
                entry.ids.append(photo.id)
                grouped[key] = entry
            } else {
                grouped[key] = (latitude, longitude, [photo.id])
            }
        }
        let entries = grouped.values.sorted { $0.ids.count > $1.ids.count }
        guard !entries.isEmpty else { return }

        let scopedToSystemLibrary = isSystemScope
        isResolvingPlaces = true
        placeResolveTotal = entries.count
        placeResolveDone = 0

        Task { [weak self] in
            guard let self else { return }
            for entry in entries {
                let cacheKey = String(format: "%.3f,%.3f", entry.latitude, entry.longitude)
                let cached = self.placeCache[cacheKey]
                let info: PlaceInfo?
                if let cached {
                    info = cached
                } else {
                    info = await self.reverseGeocode(latitude: entry.latitude,
                                                     longitude: entry.longitude)
                }
                if let info {
                    let ids = Set(entry.ids)
                    if scopedToSystemLibrary {
                        for index in self.systemPhotos.indices where ids.contains(self.systemPhotos[index].id) {
                            self.applyPlace(info, to: &self.systemPhotos[index])
                        }
                    } else {
                        for index in self.photos.indices where ids.contains(self.photos[index].id) {
                            self.applyPlace(info, to: &self.photos[index])
                        }
                    }
                }
                self.placeResolveDone += 1
                if cached == nil {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if !scopedToSystemLibrary {
                self.save()
            }
            self.savePlaceCache()
            self.isResolvingPlaces = false
            self.placeResolveAttempted = false
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
        let key = String(format: "%.3f,%.3f", latitude, longitude)
        if let cached = placeCache[key] { return cached }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(
            location, preferredLocale: Locale(identifier: "zh_CN")
        ), let placemark = placemarks.first else { return nil }
        let info = PlaceInfo(country: placemark.country,
                             province: placemark.administrativeArea,
                             city: placemark.locality ?? placemark.subAdministrativeArea,
                             district: placemark.subLocality,
                             poi: placemark.thoroughfare)
        placeCache[key] = info
        return info
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
        return ids.compactMap { anyPhoto(id: $0) }
            .filter { !$0.isCloud }
            .prefix(10)
            .map { LibraryPaths.sourceURL(for: $0) }
    }

    var currentIsFavorite: Bool {
        if let viewerID, let photo = anyPhoto(id: viewerID) {
            return photo.isFavorite
        }
        let selected = selection.compactMap { anyPhoto(id: $0) }
        return !selected.isEmpty && selected.allSatisfy { $0.isFavorite }
    }

    func containsInCurrentView(_ id: UUID) -> Bool {
        visiblePhotos.contains(where: { $0.id == id })
    }
}
