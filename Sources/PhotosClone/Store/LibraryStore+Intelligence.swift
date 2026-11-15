import Foundation
import SwiftUI

/// 端侧智能分析：场景标签、OCR 文字与相似照片检索。仅作用于拾光本地图库。
extension LibraryStore {
    // MARK: - 分析索引

    /// 打开图库后把已分析结果读入内存（只含标签与文字，不含特征向量）。
    func loadAnalysisIndex() {
        guard !isSystemScope, !isCloudScope, let store = metadataStore else {
            analysisIndex = [:]
            return
        }
        let rows = store.loadAnalysisIndex()
        var index: [UUID: PhotoAnalysis] = [:]
        index.reserveCapacity(rows.count)
        for row in rows {
            let labels = Set(row.labels.split(separator: " ").map { $0.lowercased() })
            index[row.id] = PhotoAnalysis(labels: labels,
                                          text: row.text,
                                          searchBlob: (row.labels + " " + row.text).lowercased())
        }
        analysisIndex = index
        sceneCountsCacheKey = nil
    }

    var canAnalyzeIntelligence: Bool {
        !isSystemScope && !isCloudScope && !needsLibrarySetup && metadataStore != nil
    }

    var analyzedCount: Int { analysisIndex.count }

    /// 当前范围是否依赖端侧分析结果（场景 / 图内文字）。
    var isAnalysisScope: Bool {
        switch sidebarItem {
        case .scene, .ocrTexts: return true
        default: return false
        }
    }

    /// 输入搜索词时按需载入人物名单，让「人名 + 场景」的查询可以组合。
    func prepareSemanticSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loadFaceDataIfNeeded()
    }

    /// 端侧分析出的场景中文名，用于信息面板的「智能标签」。
    func sceneTitles(for photoID: UUID) -> [String] {
        guard let analysis = analysisIndex[photoID] else { return [] }
        return SceneCatalog.categories
            .filter { !$0.labels.isDisjoint(with: analysis.labels) }
            .map(\.title)
    }

    func ocrText(for photoID: UUID) -> String? {
        guard let text = analysisIndex[photoID]?.text, !text.isEmpty else { return nil }
        return text
    }

    /// 只分析当前这一张照片（例如在信息面板里点「分析此照片」）。
    func analyzeSinglePhoto(_ photoID: UUID) {
        guard canAnalyzeIntelligence, let store = metadataStore else {
            showToast("智能分析仅支持拾光本地图库")
            return
        }
        guard let photo = photos.first(where: { $0.id == photoID }), !photo.isVideo else {
            showToast("智能分析仅支持拾光本地图库中的照片")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let analyzed = await Task.detached(priority: .utility) {
                PhotoIntelligence.analyze(photo)
            }.value
            guard let result = analyzed else {
                self.showToast("无法分析这张照片")
                return
            }
            let labels = Set(result.labels.split(separator: " ").map(String.init))
            self.analysisIndex[photoID] = PhotoAnalysis(
                labels: labels,
                text: result.text,
                searchBlob: (result.labels + " " + result.text).lowercased()
            )
            store.saveAnalysis([(photoID, result.labels, result.text, result.feature)])
            self.sceneCountsCacheKey = nil
        }
    }

    var pendingAnalysisCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && !$0.isVideo && self.analysisIndex[$0.id] == nil }.count
    }

    /// 逐张分析本地照片：场景分类 + OCR 文字 + 特征向量，结果分批写入图库数据库。
    func analyzeIntelligence() {
        guard canAnalyzeIntelligence, let store = metadataStore else {
            showToast("智能分析仅支持拾光本地图库")
            return
        }
        guard !isAnalyzingIntelligence else { return }
        let targets = photos.filter { $0.deletedAt == nil && !$0.isVideo && self.analysisIndex[$0.id] == nil }
        guard !targets.isEmpty else {
            showToast("所有照片都已完成内容分析")
            return
        }

        isAnalyzingIntelligence = true
        intelligenceCancelled = false
        intelligenceDone = 0
        intelligenceTotal = targets.count
        sceneCountsCacheKey = nil

        intelligenceTask = Task { [weak self] in
            guard let self else { return }
            var buffer: [(id: UUID, labels: String, text: String, feature: Data?)] = []
            buffer.reserveCapacity(16)
            for (index, photo) in targets.enumerated() {
                if self.intelligenceCancelled || Task.isCancelled { break }
                let result = await Task.detached(priority: .utility) {
                    PhotoIntelligence.analyze(photo)
                }.value
                if let result {
                    let labels = Set(result.labels.split(separator: " ").map(String.init))
                    self.analysisIndex[photo.id] = PhotoAnalysis(
                        labels: labels,
                        text: result.text,
                        searchBlob: (result.labels + " " + result.text).lowercased()
                    )
                    buffer.append((photo.id, result.labels, result.text, result.feature))
                    if buffer.count >= 16 {
                        store.saveAnalysis(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                self.intelligenceDone = index + 1
                if index % 8 == 0 { self.sceneCountsCacheKey = nil }
            }
            if !buffer.isEmpty { store.saveAnalysis(buffer) }

            self.sceneCountsCacheKey = nil
            self.isAnalyzingIntelligence = false
            self.intelligenceTask = nil
            let analysed = self.intelligenceDone
            self.intelligenceTotal = 0
            self.intelligenceDone = 0
            if self.intelligenceCancelled {
                self.intelligenceCancelled = false
                self.showToast("已停止内容分析，已分析 \(analysed) 张")
            } else {
                self.showToast("内容分析完成，共分析 \(analysed) 张")
            }
        }
    }

    func cancelIntelligenceAnalysis() {
        intelligenceCancelled = true
        intelligenceTask?.cancel()
    }

    // MARK: - 场景统计

    /// 各场景的照片数；随照片内容与分析结果变化自动重算。
    var sceneCounts: [String: Int] {
        let key = "\(contentRevision)-\(analysisIndex.count)"
        if key == sceneCountsCacheKey { return sceneCountsCache }
        var counts: [String: Int] = [:]
        if !analysisIndex.isEmpty {
            for photo in photos where photo.deletedAt == nil && !photo.isHidden {
                guard let analysis = analysisIndex[photo.id] else { continue }
                for category in SceneCatalog.categories
                where !category.labels.isDisjoint(with: analysis.labels) {
                    counts[category.id, default: 0] += 1
                }
            }
        }
        sceneCountsCacheKey = key
        sceneCountsCache = counts
        return counts
    }

    var hasAnyScene: Bool { sceneCounts.values.contains { $0 > 0 } }

    var ocrPhotoCount: Int {
        guard !analysisIndex.isEmpty else { return 0 }
        return photos.lazy.filter {
            $0.deletedAt == nil && !$0.isHidden && !(self.analysisIndex[$0.id]?.text.isEmpty ?? true)
        }.count
    }

    func photosMatchingScene(_ id: String) -> [PhotoItem] {
        guard let category = SceneCatalog.category(id: id) else { return [] }
        return photos.filter { photo in
            guard photo.deletedAt == nil, !photo.isHidden,
                  let analysis = self.analysisIndex[photo.id] else { return false }
            return !category.labels.isDisjoint(with: analysis.labels)
        }
    }

    /// 把已识别的场景生成为智能相簿，之后新照片分析完成会自动落入对应相簿。
    func createSceneSmartAlbums() {
        guard canAnalyzeIntelligence else {
            showToast("智能分析仅支持拾光本地图库")
            return
        }
        let counts = sceneCounts
        var created = 0
        for category in SceneCatalog.categories where (counts[category.id] ?? 0) > 0 {
            if smartAlbums.contains(where: { $0.name == category.title }) { continue }
            var album = SmartAlbum()
            album.name = category.title
            album.matchAll = true
            album.rules = [SmartRule(field: .scene, value: category.title)]
            smartAlbums.append(album)
            created += 1
        }
        guard created > 0 else {
            showToast(analyzedCount > 0 ? "场景智能相簿已是最新" : "请先分析照片内容")
            return
        }
        persistSmartAlbums()
        showToast("已生成 \(created) 个场景智能相簿")
    }

    // MARK: - 相似照片

    func findSimilarPhotos(to id: UUID) {
        guard !isReadOnlyScope, let store = metadataStore else {
            showToast("相似检索仅支持拾光本地图库")
            return
        }
        guard let photo = photos.first(where: { $0.id == id }) else { return }
        guard !photo.isVideo else {
            showToast("暂不支持视频相似检索")
            return
        }
        guard analysisIndex[id] != nil else {
            showToast("请先在侧边栏「场景」里分析照片内容")
            return
        }
        showToast("正在查找相似照片…")
        let title = photo.displayTitle
        Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) { () -> [UUID] in
                guard let feature = store.feature(for: id) else { return [] }
                return store.similarPhotos(to: feature, excluding: id)
            }.value
            guard let self else { return }
            guard !ids.isEmpty else {
                self.showToast("没有找到足够相似的照片")
                return
            }
            self.navigate(to: .library)
            self.similarScope = SimilarityScope(sourceID: id, title: title, ids: Set(ids))
            self.showToast("找到 \(ids.count) 张相似照片")
        }
    }

    func clearSimilarScope() {
        similarScope = nil
    }
}
