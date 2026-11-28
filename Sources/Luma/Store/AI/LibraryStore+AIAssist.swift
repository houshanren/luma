import Foundation
import LumaDomain
import LumaMemories

/// 三个一次性 AI 辅助的图库侧实现：
/// - 体检解读：把结构化体检结果交给模型写成可执行的建议；
/// - 回忆 / 旅行起名：给模板标题配一个更有画面的标题与一句旁白；
/// - 影院兜底：规则打分失败时，让模型在候选里挑一个。
///
/// 统一规则：只由用户点按钮触发、只发文本、串行执行、失败保留原结果。
extension LibraryStore {
    var aiAssistAvailability: AIAssistCenter.Availability {
        AIAssistCenter.availability(config: aiConfig, assistantBusy: aiIsResponding)
    }

    // MARK: - 体检解读

    /// 体检解读的缓存键：同一份报告（时间 + 各项数量）只调一次模型。
    func aiHealthDigestKey(_ report: LibraryHealthReport) -> String {
        [
            String(Int(report.scannedAt.timeIntervalSince1970)),
            String(report.scannedCount),
            String(report.blurry.count),
            String(report.similarGroups.count),
            String(report.similarDuplicatePhotos.count),
            String(report.largeVideos.count)
        ].joined(separator: "-")
    }

    func generateHealthAIDigest() async {
        guard healthReportMatchesCurrentScope, let report = healthReport,
              !isScanningHealth, !isFinalizingHealth else { return }
        let center = AIAssistCenter.shared
        let key = aiHealthDigestKey(report)
        if center.cachedHealthDigest(for: key) != nil { return }
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        guard center.beginHealthDigest(key: key) else { return }

        let facts = """
        模式：\(isSystemScope ? "系统图库（只读）" : "拾光图库")
        已检查：\(report.scannedCount) 张
        可能模糊：\(report.blurry.count) 张
        相似连拍：\(report.similarGroups.count) 组，其中备选 \(report.similarDuplicatePhotos.count) 张
        可腾出空间：\(formatFileSize(report.reclaimableBytes))
        过大视频：\(report.largeVideos.count) 个（单个超过 \(formatFileSize(LibraryHealthTuning.largeVideoBytes))）
        截屏：\(photos(for: .screenshots).count) 张
        待分析内容：\(pendingAnalysisCount) 项
        """
        do {
            let text = try await AIAssistCenter.shared.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是照片图库整理顾问。根据给定统计写 3 句中文：
                第 1 句一句话结论；第 2 句指出最该先处理的两件事并带上数量；第 3 句给一条注意事项。
                总字数不超过 120 字，不要列表符号、不要标题、不要编造统计里没有的项目。
                """,
                user: facts,
                maxTokens: 300,
                preferLightweight: true
            )
            center.finishHealthDigest(.success(text))
            Diagnostics.record("AI 辅助：生成体检解读", level: .standard)
        } catch {
            center.finishHealthDigest(.failure(error))
        }
    }

    // MARK: - 回忆 / 旅行起名

    /// 进入回忆 / 收藏页时调用：按图库载入已生成过的标题。
    func restoreAIStoryTitles() {
        AIAssistCenter.shared.loadStoryTitles(libraryKey: storyLibraryKey)
    }

    private var storyLibraryKey: String {
        containerLibraryPath ?? (isSystemScope ? "system" : "default")
    }

    func aiStoryTitle(for memory: PhotoMemory) -> AIAssistCenter.StoryTitle? {
        AIAssistCenter.shared.storyTitle(for: memory.id)
    }

    func aiStoryTitle(for trip: TripStory) -> AIAssistCenter.StoryTitle? {
        AIAssistCenter.shared.storyTitle(for: trip.id)
    }

    func generateAIStoryTitle(for memory: PhotoMemory) async {
        let facts = """
        类型：\(memoryKindTitle(memory.kind))
        数量：\(memory.photos.count) 张照片
        时间：\(DateText.monthDayFormatter.string(from: memory.photos.first?.capturedAt ?? Date()))
        地点：\(aiPlaceSummary(memory.photos))
        场景标签：\(aiSceneSummary(memory.photos))
        当前标题：\(memory.title)
        """
        let generated = await aiStoryTitle(id: memory.id,
                                           facts: facts,
                                           fallbackTitle: memory.title)
        if generated == nil { showToast(AIAssistCenter.shared.storyError ?? "起名失败，请重试") }
    }

    func generateAIStoryTitle(for trip: TripStory) async {
        let facts = """
        类型：一次旅行
        天数：\(trip.dayCount) 天
        地点：\(aiPlaceSummary(trip.photos))（共 \(trip.placeCount) 个地点）
        数量：\(trip.photos.count) 项
        日期：\(DateText.monthDayFormatter.string(from: trip.startDate)) 至 \(DateText.monthDayFormatter.string(from: trip.endDate))
        场景标签：\(aiSceneSummary(trip.photos))
        当前标题：\(trip.title)
        """
        let generated = await aiStoryTitle(id: trip.id, facts: facts, fallbackTitle: trip.title)
        if generated == nil { showToast(AIAssistCenter.shared.storyError ?? "起名失败，请重试") }
    }

    private func aiStoryTitle(id: String,
                              facts: String,
                              fallbackTitle: String) async -> AIAssistCenter.StoryTitle? {
        let center = AIAssistCenter.shared
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return nil
        }
        guard center.beginStoryTitle(id: id) else { return nil }
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是相册文案作者。只输出一行 JSON：{"title":"不超过 12 个汉字的标题","narration":"一到两句、60 字以内的中文旁白"}。
                不要解释、不要 markdown、不要换行。
                """,
                user: facts,
                maxTokens: 260,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let title = (object["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                throw AIError.badResponse
            }
            let narration = (object["narration"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = AIAssistCenter.StoryTitle(
                title: String(title.prefix(16)),
                narration: String(narration.prefix(120))
            )
            center.finishStoryTitle(id: id, result: .success(value))
            Diagnostics.record("AI 辅助：为「\(fallbackTitle)」起名", level: .standard)
            return value
        } catch {
            center.finishStoryTitle(id: id, result: .failure(error))
            return nil
        }
    }

    private func memoryKindTitle(_ kind: PhotoMemory.Kind) -> String {
        switch kind {
        case .month: return "按月回忆"
        case .place: return "按城市回忆"
        case .favorites: return "个人收藏合集"
        case .throwback: return "往年今日"
        }
    }

    /// 只取城市名，控制隐私与长度；没有地点时退回空串。
    func aiPlaceSummary(_ photos: [PhotoItem], limit: Int = 4) -> String {
        var seen = Set<String>()
        var names: [String] = []
        for photo in photos {
            guard let city = photo.placeCity ?? photo.placeProvince,
                  !city.isEmpty, seen.insert(city).inserted else { continue }
            names.append(city)
            if names.count >= limit { break }
        }
        return names.isEmpty ? "未知" : names.joined(separator: "、")
    }

    /// 场景标签来自端侧 Vision / SigLIP 分析，取出现最多的几个；不发送 OCR 文本。
    func aiSceneSummary(_ photos: [PhotoItem], limit: Int = 8) -> String {
        var counts: [String: Int] = [:]
        for photo in photos.prefix(40) {
            for label in analysisIndex[photo.id]?.labels ?? [] {
                counts[label, default: 0] += 1
            }
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
        return top.isEmpty ? "无" : top.joined(separator: "、")
    }

    // MARK: - 影院文件名兜底

    /// 只处理当前影院的未识别条目：规则打分没匹配上的，让模型在候选里选。
    /// 每次最多 `limit` 条，逐条搜索 + 决策；写完立即落盘，可随时中断。
    func aiResolveUnmatchedCinema(scope requestedScope: CinemaScope? = nil, limit: Int = 6) async {
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        guard !cinemaScrapeRunning else {
            showToast("正在刮削，等这一轮结束再试")
            return
        }
        let scope = requestedScope ?? cinemaActiveScope
        let entries = cinemaEntries(for: scope)
        let targets = entries.values
            .filter { !$0.matched }
            .sorted { $0.file.filename < $1.file.filename }
            .prefix(limit)
        guard !targets.isEmpty else {
            showToast("当前影院没有未识别条目")
            return
        }

        let center = AIAssistCenter.shared
        guard center.beginCinemaFallback() else { return }
        var resolved = 0
        var tried = 0

        for (index, entry) in targets.enumerated() {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = title.isEmpty ? entry.file.filename : title
            center.updateCinemaFallback("AI 兜底 \(index + 1)/\(targets.count)：\(display)")
            tried += 1

            let result = await cinemaSearchCandidates(query: display,
                                                      isTV: entry.kind == .tv,
                                                      year: entry.year)
            let candidates = Array(result.matches.prefix(6))
            guard !candidates.isEmpty else { continue }
            guard let picked = await aiPickCinemaCandidate(entry: entry,
                                                           candidates: candidates) else {
                continue
            }
            let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
            if entry.kind == .tv {
                var episodes: [UUID: Int] = [:]
                if let episode = entry.episode { episodes[photo.id] = episode }
                applyCinemaMatch(picked,
                                 to: [photo],
                                 season: entry.season,
                                 episodes: episodes)
            } else {
                applyCinemaMatch(picked, to: [photo], season: nil, episodes: [:])
            }
            resolved += 1
        }

        let summary = resolved > 0
            ? "AI 兜底完成：识别 \(resolved)/\(tried) 部"
            : "AI 兜底：这次没有把握的候选"
        center.finishCinemaFallback(summary)
        showToast(summary)
        if resolved > 0 {
            Diagnostics.record("AI 辅助：影院兜底识别 \(resolved) 部", level: .standard)
        }
    }

    /// 让模型只从候选里选一个；不确定就返回 nil，交给用户手动匹配。
    private func aiPickCinemaCandidate(entry: CinemaEntry,
                                       candidates: [CinemaMatch]) async -> CinemaMatch? {
        let lines = candidates.map { match -> String in
            var parts = ["id=\(match.id)", "片名=\(match.title)"]
            if let original = match.originalTitle, !original.isEmpty {
                parts.append("原名=\(original)")
            }
            if let year = match.year { parts.append("年份=\(year)") }
            parts.append(match.isTV ? "类型=剧集" : "类型=电影")
            if let rating = match.rating, rating > 0 { parts.append(String(format: "评分=%.1f", rating)) }
            if let overview = match.overview, !overview.isEmpty {
                parts.append("简介=\(String(overview.prefix(90)))")
            }
            return "- " + parts.joined(separator: "｜")
        }
        let user = """
        文件名：\(entry.file.filename)
        解析片名：\(entry.title)
        年份：\(entry.year.map(String.init) ?? "未知")
        类型：\(entry.kind == .tv ? "剧集" : "电影")
        候选：
        \(lines.joined(separator: "\n"))
        """
        do {
            let text = try await AIAssistCenter.shared.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是影片文件名匹配助手。只能在给定候选里选择同一部作品；同名但年份 / 类型不符的不要选。
                只输出一行 JSON：{"candidate_id":"<id>"} 或 {"candidate_id":"none"}，可加 "reason":"不超过 20 字"。
                """,
                user: user,
                maxTokens: 160
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let raw = object["candidate_id"] as? String,
                  raw != "none" else { return nil }
            return candidates.first { $0.id == raw }
        } catch {
            return nil
        }
    }
}
