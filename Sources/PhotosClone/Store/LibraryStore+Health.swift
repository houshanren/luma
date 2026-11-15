import Foundation
import SwiftUI

/// 体检阈值：与 UI 状态无关，放在文件级便于在后台任务里直接使用。
enum LibraryHealthTuning {
    /// 超过这个大小视为「过大视频」。
    static let largeVideoBytes: Int64 = 300 * 1024 * 1024
    /// 相似连拍分组的余弦相似度门槛（特征向量已归一化，点积即相似度）。
    static let similarGroupThreshold: Float = 0.90
    /// 同一组的拍摄时间差上限（秒），避免把同场景不同时段的照片归为一组。
    static let similarGroupWindow: TimeInterval = 600
    /// 「值得重看」：拍摄距今至少这么久，且最近查看距今至少一年（或从未查看）。
    static let revisitCaptureAge: TimeInterval = 2 * 365 * 24 * 3600
    static let revisitViewAge: TimeInterval = 365 * 24 * 3600
}

/// 图库体检：模糊照片、相似连拍备选、过大视频，以及「值得重看」范围。仅作用于本地图库。
extension LibraryStore {
    var canScanHealth: Bool {
        !isSystemScope && !isCloudScope && !needsLibrarySetup
    }

    // MARK: - 扫描

    /// 扫描本地图库：逐张计算清晰度，并用已分析的特征向量归并相似连拍。
    func scanLibraryHealth() {
        guard canScanHealth, let store = metadataStore else {
            showToast("图库体检仅支持拾光本地图库")
            return
        }
        guard !isScanningHealth else { return }
        let targets = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        guard !targets.isEmpty else {
            showToast("图库里还没有可检查的项目")
            return
        }

        isScanningHealth = true
        healthScanProgress = 0
        let photosByName = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let photosOnly = targets.filter { !$0.isVideo }

        healthTask = Task { [weak self] in
            guard let self else { return }
            var scores: [(UUID, Double)] = []
            scores.reserveCapacity(photosOnly.count)

            // 清晰度：按小块并发，避免为每张照片创建独立任务。
            let chunkSize = 16
            var index = 0
            while index < photosOnly.count {
                if Task.isCancelled { break }
                let end = min(index + chunkSize, photosOnly.count)
                let slice = Array(photosOnly[index..<end])
                let part = await Task.detached(priority: .utility) {
                    slice.compactMap { photo in
                        PhotoQuality.sharpness(for: photo).map { (photo.id, $0) }
                    }
                }.value
                scores.append(contentsOf: part)
                index = end
                self.healthScanProgress = Double(index) / Double(max(1, photosOnly.count))
            }
            if Task.isCancelled {
                self.isScanningHealth = false
                self.healthScanProgress = 0
                self.healthTask = nil
                return
            }

            // 相似连拍：用归一化特征向量做近邻归并，每组只保留最佳一张。
            let features = store.allFeatures()
            let groups = await Task.detached(priority: .utility) {
                Self.buildSimilarGroups(features: features,
                                        photos: photosByName,
                                        scores: Dictionary(uniqueKeysWithValues: scores))
            }.value

            let report = LibraryHealthReport(
                blurry: scores
                    .filter { $0.1 < PhotoQuality.blurryThreshold }
                    .compactMap { entry in
                        photosByName[entry.0].map { LibraryHealthReport.Finding(photo: $0, score: entry.1) }
                    }
                    .sorted { $0.score < $1.score },
                similarGroups: groups,
                largeVideos: targets
                    .filter { $0.isVideo && $0.fileSize >= LibraryHealthTuning.largeVideoBytes }
                    .sorted { $0.fileSize > $1.fileSize },
                scannedAt: Date(),
                scannedCount: photosOnly.count
            )

            self.healthReport = report
            self.isScanningHealth = false
            self.healthScanProgress = 0
            self.healthTask = nil
            let duplicates = report.similarDuplicatePhotos.count
            let blurry = report.blurry.count
            self.showToast("体检完成：\(blurry) 张可能模糊，\(duplicates) 张相似备选")
        }
    }

    func cancelHealthScan() {
        healthTask?.cancel()
        healthTask = nil
        isScanningHealth = false
        healthScanProgress = 0
    }

    /// 纯计算：把特征向量按「与已有组代表的相似度 ≥ 门槛且拍摄时间相近」归组。
    nonisolated private static func buildSimilarGroups(
        features: [(id: UUID, feature: Data)],
        photos: [UUID: PhotoItem],
        scores: [UUID: Double]
    ) -> [LibraryHealthReport.SimilarGroup] {
        var members: [[UUID]] = []
        var vectors: [[Float]] = []
        var scoresByGroup: [Float] = []

        for entry in features {
            guard let photo = photos[entry.id], !photo.isVideo else { continue }
            let vector = entry.feature.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard !vector.isEmpty else { continue }

            var bestIndex = -1
            var bestScore: Float = 0
            for (groupIndex, representative) in vectors.enumerated() {
                guard representative.count == vector.count else { continue }
                var dot: Float = 0
                for i in 0..<vector.count { dot += vector[i] * representative[i] }
                guard dot >= LibraryHealthTuning.similarGroupThreshold else { continue }
                // 只有拍摄时间接近才视为同一组连拍。
                guard let anchor = photos[members[groupIndex][0]],
                      abs(anchor.capturedAt.timeIntervalSince(photo.capturedAt)) <= LibraryHealthTuning.similarGroupWindow else {
                    continue
                }
                if dot > bestScore {
                    bestScore = dot
                    bestIndex = groupIndex
                }
            }

            if bestIndex >= 0 {
                members[bestIndex].append(entry.id)
                scoresByGroup[bestIndex] += bestScore
            } else {
                members.append([entry.id])
                vectors.append(vector)
                scoresByGroup.append(0)
            }
        }

        var result: [LibraryHealthReport.SimilarGroup] = []
        for (groupIndex, ids) in members.enumerated() where ids.count > 1 {
            let groupPhotos = ids.compactMap { photos[$0] }
            guard groupPhotos.count > 1 else { continue }
            // 保留清晰度最高的一张；同分时优先像素更高、文件更大。
            let best = groupPhotos.max { lhs, rhs in
                let left = scores[lhs.id] ?? 0
                let right = scores[rhs.id] ?? 0
                if left == right {
                    let leftPixels = lhs.pixelWidth * lhs.pixelHeight
                    let rightPixels = rhs.pixelWidth * rhs.pixelHeight
                    if leftPixels == rightPixels { return lhs.fileSize < rhs.fileSize }
                    return leftPixels < rightPixels
                }
                return left < right
            } ?? groupPhotos[0]
            let duplicates = groupPhotos
                .filter { $0.id != best.id }
                .sorted { (scores[$0.id] ?? 0) < (scores[$1.id] ?? 0) }
            let similarity = Double(scoresByGroup[groupIndex]) / Double(max(1, ids.count - 1))
            result.append(LibraryHealthReport.SimilarGroup(best: best,
                                                           duplicates: duplicates,
                                                           similarity: similarity))
        }
        return result.sorted { $0.duplicates.count > $1.duplicates.count }
    }

    // MARK: - 体检范围

    /// 模糊照片（按可能程度从高到低）。
    var blurryPhotos: [PhotoItem] {
        guard let report = healthReport else { return [] }
        let live = Dictionary(uniqueKeysWithValues: photos.lazy
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .map { ($0.id, $0) })
        return report.blurry.compactMap { live[$0.photo.id] }
    }

    /// 相似连拍里被判定为备选的照片。
    var similarDuplicatePhotos: [PhotoItem] {
        guard let report = healthReport else { return [] }
        let live = Dictionary(uniqueKeysWithValues: photos.lazy
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .map { ($0.id, $0) })
        return report.similarDuplicatePhotos.compactMap { live[$0.id] }
    }

    /// 体积过大的视频。
    var largeVideoPhotos: [PhotoItem] {
        guard let report = healthReport else { return [] }
        let live = Dictionary(uniqueKeysWithValues: photos.lazy
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .map { ($0.id, $0) })
        return report.largeVideos.compactMap { live[$0.id] }
    }

    /// 值得重看：至少两年没拍到的旧照片，且一年以上（或从未）没有打开过。
    var revisitPhotos: [PhotoItem] {
        let now = Date()
        let captureCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge)
        let viewCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitViewAge)
        return photos.filter { photo in
            guard photo.deletedAt == nil, !photo.isHidden, !photo.isCloud, !photo.isSystem else { return false }
            guard photo.capturedAt < captureCutoff else { return false }
            guard let viewedAt = photo.viewedAt else { return true }
            return viewedAt < viewCutoff
        }
    }

    /// 记录一次查看，供「值得重看」判断新鲜度；只更新单行并跳过一小时内重复写入。
    func recordView(_ id: UUID) {
        // 官方「照片」图库：查看记录写进拾光数据库，不写 Photos.sqlite。
        if canEditNativeOverlay, systemPhotoIndex[id] != nil {
            recordSystemView(id)
            return
        }
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        guard !photos[index].isCloud, !photos[index].isSystem else { return }
        let now = Date()
        if let last = photos[index].viewedAt, now.timeIntervalSince(last) < 3600 { return }
        photos[index].viewedAt = now
        metadataStore?.setViewedAt(id, date: now)
    }
}
