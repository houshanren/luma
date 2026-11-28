import Foundation
import LumaDomain

/// 第三批 AI 辅助：整理型任务。
/// - 关键词归一化：合并同义词 / 错别字，清理「IMG_1234」这类垃圾词；
/// - 地点补全：从 OCR 线索推断城市与地点，确认后写回；
/// - 电视「今晚看什么」：按节目单与追剧订阅挑 3 档并给理由；
/// - 影院系列归组：同系列电影收进合集、同剧不同季合并成一张卡。
extension LibraryStore {
    // MARK: - 关键词归一化

    /// 只把现有关键词发给模型做归并，不发送照片。
    func generateKeywordMerges() async {
        let options = keywordOptions.sorted { $0.count > $1.count }.prefix(120)
        guard !options.isEmpty else {
            showToast("当前范围还没有关键词")
            return
        }
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginKeywordMerge() else { return }
        center.showKeywordMergeSheet = true

        let factList = options.map { "\($0.name)（\($0.count)）" }.joined(separator: "\n")
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是照片关键词整理助手。找出需要合并的关键词组：
                - 同义词、繁体 / 简体、英文与中文、错别字；
                - 无意义的垃圾词（如 IMG_1234、未命名、Screenshot）；
                - 只合并确实指的是同一件事的词，不要合并相关但不同的词（如「海边」与「沙滩」）。
                canonical 用最常用、最自然的中文词；垃圾词的 canonical 留空字符串。
                每组的 variants 必须原样来自给定列表，不要把 canonical 自己放进 variants。
                只输出一行 JSON：{"merges":[{"canonical":"海边","variants":["海邊","seaside"]}]}。
                """,
                user: factList,
                maxTokens: 800,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let raw = object["merges"] as? [[String: Any]] else {
                throw AIError.badResponse
            }
            let existing = Set(options.map(\.name))
            var merges: [AIAssistCenter.KeywordMergeSuggestion] = []
            for item in raw {
                let canonical = (item["canonical"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let variants = (item["variants"] as? [String] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { existing.contains($0) && $0 != canonical }
                guard !variants.isEmpty else { continue }
                merges.append(AIAssistCenter.KeywordMergeSuggestion(
                    canonical: canonical,
                    variants: Array(Set(variants)).sorted()
                ))
            }
            guard !merges.isEmpty else { throw AIError.badResponse }
            center.finishKeywordMerge(.success(merges))
            Diagnostics.record("AI 辅助：关键词归一化 \(merges.count) 组", level: .standard)
        } catch {
            center.finishKeywordMerge(.failure(error))
        }
    }

    /// 一次性合并：canonical 为空表示删除这些垃圾词。
    func applyKeywordMerges(_ merges: [AIAssistCenter.KeywordMergeSuggestion]) {
        guard !merges.isEmpty else { return }
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘为只读，不能整理关键词")
            return
        }
        let normalized = Set(merges.flatMap(\.variants))
        let affected = Set(photos.filter { photo in
            !normalized.isDisjoint(with: Set(photo.keywords ?? []))
        }.map(\.id))
        guard !affected.isEmpty else {
            showToast("这些关键词已经不在图库里了")
            return
        }
        let beforePhotos = photoSnapshot(affected)
        var merged = 0
        for index in photos.indices where affected.contains(photos[index].id) {
            guard var list = photos[index].keywords, !list.isEmpty else { continue }
            var changed = false
            for merge in merges {
                let hit = list.filter { merge.variants.contains($0) }
                guard !hit.isEmpty else { continue }
                list.removeAll { merge.variants.contains($0) }
                if !merge.canonical.isEmpty, !list.contains(merge.canonical) {
                    list.append(merge.canonical)
                }
                merged += hit.count
                changed = true
            }
            if changed { photos[index].keywords = list.isEmpty ? nil : list }
        }
        guard merged > 0 else { return }
        save()
        recordUndo("AI 整理关键词", beforePhotos: beforePhotos)
        AIAssistCenter.shared.showKeywordMergeSheet = false
        showToast("已整理 \(merges.count) 组、替换 \(merged) 个关键词")
    }

    // MARK: - 地点补全

    /// 只挑「没有定位但 OCR 有字」的照片，从票根 / 路牌 / 店名推断地点。
    func generatePlaceSuggestions() async {
        let targets = Array(photos
            .filter { photo in
                photo.deletedAt == nil
                    && !photo.hasLocation
                    && !(analysisIndex[photo.id]?.text.isEmpty ?? true)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(8))
        guard !targets.isEmpty else {
            showToast("没有找到可用于推断地点的照片")
            return
        }
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginPlaceSuggestions() else { return }
        center.showPlaceSheet = true

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        let lines = targets.enumerated().map { index, photo -> String in
            let ocr = String((analysisIndex[photo.id]?.text ?? "").prefix(120))
            return "\(index + 1). 日期=\(formatter.string(from: photo.capturedAt))｜OCR=\(ocr)"
        }
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是照片地点推断助手。只根据 OCR 里的票根、路牌、店名、地址推断城市与具体地点。
                没有把握的照片直接跳过，不要猜。city 写城市名（如「杭州市」），poi 写具体地点（如「西湖」），
                两者都不确定就跳过这张。
                只输出一行 JSON：{"items":[{"index":1,"city":"杭州市","poi":"西湖"}]}。
                """,
                user: lines.joined(separator: "\n"),
                maxTokens: 500,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let items = object["items"] as? [[String: Any]] else {
                throw AIError.badResponse
            }
            var suggestions: [AIAssistCenter.PlaceSuggestion] = []
            for item in items {
                guard let index = item["index"] as? Int,
                      index >= 1, index <= targets.count else { continue }
                let city = (item["city"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let poi = (item["poi"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !city.isEmpty || !poi.isEmpty else { continue }
                suggestions.append(AIAssistCenter.PlaceSuggestion(
                    id: targets[index - 1].id,
                    city: String(city.prefix(20)),
                    poi: String(poi.prefix(30))
                ))
            }
            guard !suggestions.isEmpty else { throw AIError.badResponse }
            center.finishPlaceSuggestions(.success(suggestions))
            Diagnostics.record("AI 辅助：地点建议 \(suggestions.count) 张", level: .standard)
        } catch {
            center.finishPlaceSuggestions(.failure(error))
        }
    }

    func applyPlaceSuggestions(_ suggestions: [AIAssistCenter.PlaceSuggestion]) {
        guard !suggestions.isEmpty else { return }
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘为只读，不能写入地点")
            return
        }
        let ids = Set(suggestions.map(\.id))
        let beforePhotos = photoSnapshot(ids)
        var touched = 0
        for index in photos.indices where ids.contains(photos[index].id) {
            guard let suggestion = suggestions.first(where: { $0.id == photos[index].id }) else { continue }
            if !suggestion.city.isEmpty { photos[index].placeCity = suggestion.city }
            if !suggestion.poi.isEmpty { photos[index].placePOI = suggestion.poi }
            touched += 1
        }
        guard touched > 0 else { return }
        save()
        recordUndo("AI 补全地点", beforePhotos: beforePhotos)
        AIAssistCenter.shared.showPlaceSheet = false
        showToast("已补全 \(touched) 张照片的地点")
    }

    // MARK: - 电视「今晚看什么」

    /// candidates 由夜航页按当前节目单拼好（标题｜频道｜时间｜类型），这里只负责挑与解释。
    func generateTVTonightPicks(candidates: [String], followed: [String]) async {
        guard !candidates.isEmpty else {
            showToast("今晚节目单还是空的")
            return
        }
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginTonightPicks() else { return }
        let facts = """
        追剧中的节目：\(followed.isEmpty ? "无" : followed.prefix(8).joined(separator: "、"))
        今晚候选：
        \(candidates.prefix(30).joined(separator: "\n"))
        """
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是电视节目推荐助手。从候选里挑 3 档今晚值得看的节目，优先追剧中的节目，
                其次新闻 / 体育 / 纪录片等有明确内容的节目；避开重播与购物节目。
                每条按「时间｜频道｜节目名｜一句不超过 20 字的理由」输出，不要编造候选里没有的节目。
                只输出一行 JSON：{"picks":["20:00｜CCTV-1｜新闻联播｜…","…","…"]}。
                """,
                user: facts,
                maxTokens: 500,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let picks = object["picks"] as? [String] else {
                throw AIError.badResponse
            }
            let cleaned = picks
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(3)
            guard !cleaned.isEmpty else { throw AIError.badResponse }
            center.finishTonightPicks(.success(Array(cleaned)))
        } catch {
            center.finishTonightPicks(.failure(error))
        }
    }

    // MARK: - 影院系列归组

    /// 两件事一起做：同系列电影写入本地合集；未识别剧集把不同季的标题并回同一个剧名。
    /// 只改元数据，不动文件；重新刮削或下次手动匹配仍以片源信息为准。
    func aiGroupCinemaSeries() async {
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        guard !cinemaScrapeRunning else {
            showToast("正在刮削，等这一轮结束再试")
            return
        }
        let scope = cinemaActiveScope
        let all = cinemaEntries(for: scope)

        // 电影：只取已识别、还没有 TMDB 合集信息的，按版本去重。
        var moviesByVersion: [String: CinemaEntry] = [:]
        for entry in all.values where entry.matched && entry.kind == .movie {
            let key = cinemaVersionKey(for: entry)
            if let existing = moviesByVersion[key], !cinemaIsBetterVersion(entry, existing) { continue }
            moviesByVersion[key] = entry
        }
        let movies = moviesByVersion.values
            .filter { ($0.collectionName ?? "").isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(80)
            .map { $0 }

        // 剧集：未识别的卡片标题，用于合并同剧不同季。
        let seriesTitles = buildCinemaSeries(for: scope, matched: false)
            .map(\.title)
            .prefix(40)
            .map { $0 }

        guard movies.count >= 2 || seriesTitles.count >= 2 else {
            showToast("当前影院没有可归组的条目")
            return
        }

        let center = AIAssistCenter.shared
        guard center.beginCinemaGrouping() else { return }
        center.updateCinemaGrouping("读取片名…")

        var movieLines: [String] = []
        for (index, entry) in movies.enumerated() {
            let year = entry.year.map { "（\($0)）" } ?? ""
            movieLines.append("\(index + 1). \(entry.title)\(year)")
        }
        let seriesLines = seriesTitles.enumerated().map { "\($0.offset + 1). \($0.element)" }
        let facts = """
        电影：
        \(movieLines.isEmpty ? "无" : movieLines.joined(separator: "\n"))

        未识别剧集：
        \(seriesLines.isEmpty ? "无" : seriesLines.joined(separator: "\n"))
        """

        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是影视资料整理助手，做两件事：
                1) 找出属于同一系列的电影（如漫威、哈利波特、指环王），至少 2 部才成组；
                   name 用通行中文合集名（不超过 16 字），summary 用一句话介绍（不超过 60 字），
                   members 用电影序号；不属于任何系列的电影不要出现。
                2) 找出同一部剧的不同季（只差「第二季 / Season 2 / 第2部」这类后缀），
                   canonical 写不带季数的剧名，variants 原样抄未识别剧集列表里的标题。
                不要编造列表里没有的片名。
                只输出一行 JSON：{"collections":[{"name":"…","summary":"…","members":[1,2]}],"series":[{"canonical":"…","variants":["…"]}]}。
                """,
                user: facts,
                maxTokens: 1000,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text) else {
                throw AIError.badResponse
            }
            center.updateCinemaGrouping("写回合集…")

            var updated = cinemaIndexes[scope] ?? [:]
            var collectionCount = 0
            var collectionSummaries: [Int: String] = [:]
            let rawCollections = object["collections"] as? [[String: Any]] ?? []
            for item in rawCollections {
                let name = (item["name"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = (item["summary"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let members = item["members"] as? [Int] ?? []
                guard !name.isEmpty, members.count >= 2 else { continue }
                let collectionID = Self.aiCollectionID(for: name)
                var wrote = 0
                for member in members {
                    guard member >= 1, member <= movies.count else { continue }
                    let id = movies[member - 1].id
                    guard var entry = updated[id] else { continue }
                    guard (entry.collectionName ?? "").isEmpty else { continue }
                    entry.collectionID = collectionID
                    entry.collectionName = String(name.prefix(20))
                    updated[id] = entry
                    wrote += 1
                }
                if wrote >= 2 {
                    collectionCount += 1
                    if !summary.isEmpty {
                        collectionSummaries[collectionID] = String(summary.prefix(80))
                    }
                }
            }

            var mergedSeries = 0
            let rawSeries = object["series"] as? [[String: Any]] ?? []
            for item in rawSeries {
                let canonical = (item["canonical"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let variants = Set(item["variants"] as? [String] ?? [])
                guard !canonical.isEmpty, !variants.isEmpty else { continue }
                for (id, var entry) in updated
                where entry.kind == .tv && !entry.matched && variants.contains(entry.title) {
                    guard entry.title != canonical else { continue }
                    entry.title = String(canonical.prefix(30))
                    updated[id] = entry
                    mergedSeries += 1
                }
            }

            guard collectionCount > 0 || mergedSeries > 0 else {
                center.finishCinemaGrouping("AI 归组：没有找到确定的系列")
                showToast("AI 归组：没有找到确定的系列")
                return
            }

            for (collectionID, summary) in collectionSummaries {
                metadataStore?.setSetting(Self.cinemaCollectionSummaryKey(collectionID), summary)
            }
            cinemaIndexes[scope] = updated
            persistCinemaIndex(for: scope)

            var parts: [String] = []
            if collectionCount > 0 { parts.append("新建 \(collectionCount) 个合集") }
            if mergedSeries > 0 { parts.append("合并 \(mergedSeries) 集同剧") }
            let summary = "AI 归组完成：" + parts.joined(separator: "，")
            center.finishCinemaGrouping(summary)
            showToast(summary)
            Diagnostics.record("AI 辅助：\(summary)", level: .standard)
        } catch {
            center.finishCinemaGrouping(nil)
            showToast("AI 归组失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// 本地合集简介：合集详情页在没有 TMDB 资料时用这句补上。
    func cinemaCollectionSummary(collectionID: Int) -> String? {
        guard collectionID < 0 else { return nil }
        let value = metadataStore?.setting(Self.cinemaCollectionSummaryKey(collectionID))
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func cinemaCollectionSummaryKey(_ id: Int) -> String {
        "cinema_ai_collection_\(abs(id))"
    }

    /// 用合集名生成稳定的本地负数 ID，避开 TMDB 的正数 ID。
    private static func aiCollectionID(for name: String) -> Int {
        var hash = 5381
        for scalar in name.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return -((hash & 0x7FFF_FFFF) + 1)
    }
}
