import Foundation

/// 网络存储的分类浏览：媒体类型、场景与图内文字。
///
/// 网盘照片没有可读的 EXIF，也没有 `Photos.sqlite`：类型按文件名/扩展名推断，
/// 场景与文字由本机 Vision 在缩略图上识别，结果只保留在内存（切网盘即清空），
/// 不写图库数据库、不上传任何内容。
extension LibraryStore {
    /// 当前打开中的网盘挂载 ID。
    var currentCloudMountID: UUID? {
        if case .cloudMount(let id) = sidebarItem { return id }
        return nil
    }

    var cloudScope: CloudScope { cloudModel.scope }

    func setCloudScope(_ scope: CloudScope) {
        guard cloudModel.scope != scope else { return }
        if scope.requiresAnalysis, cloudModel.analysis.isEmpty {
            showToast("先点「识别内容」，完成后即可按场景或文字浏览")
        }
        cloudModel.scope = scope
        cloudVisibleCacheKey = nil
    }

    /// 单张云照片是否属于某个范围。
    func cloudPhoto(_ photo: PhotoItem, matches scope: CloudScope) -> Bool {
        switch scope {
        case .all: return true
        case .videos: return photo.isVideo
        case .photos: return !photo.isVideo
        case .screenshots: return CloudMediaNaming.looksLikeScreenshot(photo.originalName)
        case .animated: return photo.isAnimatedFile
        case .raws: return photo.isRAWFile
        case .favorites: return photo.isFavorite
        case .text: return !(cloudModel.analysis[photo.id]?.text.isEmpty ?? true)
        case .scene(let id):
            guard let category = SceneCatalog.category(id: id),
                  let analysis = cloudModel.analysis[photo.id] else { return false }
            return !category.labels.isDisjoint(with: analysis.labels)
        }
    }

    /// 当前网盘列表的分类计数（一次遍历，按目录版本 + 识别进度缓存）。
    var cloudScopeCounts: CloudScopeCounts {
        let key = "\(cloudModel.revision)-\(cloudModel.analysis.count)"
        if key == cloudScopeCountsCacheKey { return cloudScopeCountsCache }
        var counts = CloudScopeCounts()
        for photo in cloudPhotos where !photo.isHidden {
            if photo.isVideo {
                counts.videos += 1
            } else {
                counts.photos += 1
            }
            if CloudMediaNaming.looksLikeScreenshot(photo.originalName) { counts.screenshots += 1 }
            if photo.isAnimatedFile { counts.animated += 1 }
            if photo.isRAWFile { counts.raws += 1 }
            if photo.isFavorite { counts.favorites += 1 }
            guard let analysis = cloudModel.analysis[photo.id] else { continue }
            if !analysis.text.isEmpty { counts.text += 1 }
            for category in SceneCatalog.categories
            where !category.labels.isDisjoint(with: analysis.labels) {
                counts.scenes[category.id, default: 0] += 1
            }
        }
        cloudScopeCountsCacheKey = key
        cloudScopeCountsCache = counts
        return counts
    }

    /// 当前范围内仍待识别的照片数（视频不参与）。
    var cloudPendingAnalysisCount: Int {
        cloudPhotos.lazy.filter {
            !$0.isVideo && self.cloudModel.analysis[$0.id] == nil
        }.count
    }

    var cloudAnalyzedCount: Int { cloudModel.analysis.count }

    /// 逐张识别当前网盘列表的照片（场景 + 图内文字），每次最多 120 张，避免一次触发大规模网络读取。
    func analyzeCloudContent() {
        guard isCloudScope else {
            showToast("请先打开一个网络存储")
            return
        }
        guard !cloudModel.isAnalyzing else { return }
        let targets = cloudPhotos
            .filter { !$0.isVideo && self.cloudModel.analysis[$0.id] == nil }
            .prefix(120)
        guard !targets.isEmpty else {
            showToast(cloudPhotos.isEmpty ? "当前文件夹没有可识别的照片" : "当前列表已完成内容识别")
            return
        }

        cloudModel.insightMountID = currentCloudMountID
        cloudModel.isAnalyzing = true
        cloudModel.analysisProgress = 0
        let total = Double(targets.count)
        cloudModel.analysisTask = Task { [weak self] in
            guard let self else { return }
            var done = 0
            for photo in targets {
                if Task.isCancelled { break }
                if let image = await self.cloudThumbnail(for: photo),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let result = await Task.detached(priority: .utility) {
                        PhotoIntelligence.analyze(cgImage: cgImage)
                    }.value
                    if let result {
                        let labels = Set(result.labels.split(separator: " ").map(String.init))
                        self.cloudModel.analysis[photo.id] = PhotoAnalysis(
                            labels: labels,
                            text: result.text,
                            searchBlob: (result.labels + " " + result.text).lowercased()
                        )
                        // 只有按场景/文字浏览时列表才会变化，避免识别过程中反复重排整个网格。
                        if self.cloudModel.scope.requiresAnalysis {
                            self.cloudVisibleCacheKey = nil
                        }
                        self.cloudScopeCountsCacheKey = nil
                    }
                }
                done += 1
                self.cloudModel.analysisProgress = Double(done) / total
            }
            let analysed = self.cloudModel.analysis.count
            self.cloudModel.isAnalyzing = false
            self.cloudModel.analysisProgress = 0
            self.cloudModel.analysisTask = nil
            self.cloudScopeCountsCacheKey = nil
            self.cloudVisibleCacheKey = nil
            if Task.isCancelled {
                self.showToast("已停止识别，当前已识别 \(analysed) 张")
            } else {
                self.showToast("内容识别完成，共识别 \(analysed) 张")
            }
        }
    }

    func cancelCloudContentAnalysis() {
        cloudModel.analysisTask?.cancel()
    }

    /// 切换网盘或换库时清空识别结果与范围（识别结果只在内存，属于当前挂载）。
    func resetCloudInsight() {
        cloudModel.analysisTask?.cancel()
        cloudModel.analysisTask = nil
        cloudModel.isAnalyzing = false
        cloudModel.analysisProgress = 0
        cloudModel.analysis = [:]
        cloudModel.scope = .all
        cloudModel.insightMountID = nil
        cloudScopeCountsCacheKey = nil
        cloudScopeCountsCache = CloudScopeCounts()
        cloudVisibleCacheKey = nil
    }

    /// 打开某个网盘前调用：只有挂载变化时才清空，避免在同一网盘内换目录丢结果。
    func prepareCloudInsight(for mountID: UUID) {
        guard let current = cloudModel.insightMountID else {
            cloudModel.insightMountID = mountID
            return
        }
        guard current != mountID else { return }
        resetCloudInsight()
        cloudModel.insightMountID = mountID
    }
}
