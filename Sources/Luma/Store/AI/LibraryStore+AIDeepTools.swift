import Foundation

/// 深度场景工具：图库画像、旅行回顾、图库体检、影院体检、跨端续看与今日日报。
/// 这些能力不新增数据写操作，只把已有引擎（体检、旅行识别、刮削、电视节目单）组合成可直接执行的场景。
extension LibraryStore {
    // MARK: - 图库画像

    func libraryInsightsTool(_ args: [String: Any]) -> AIToolExecution {
        let top = min(30, max(1, AILibraryTools.integer(args["top"], fallback: 8)))
        let source = aiSearchSource().filter { $0.deletedAt == nil }
        guard !source.isEmpty else {
            return failure("当前范围没有可分析的项目")
        }

        let calendar = Calendar.current
        let stride = max(1, source.count / 60_000)
        let albumIDs = Set(albums.flatMap(\.photoIDs))

        var videoCount = 0
        var totalBytes: Int64 = 0
        var keyworded = 0
        var rated = 0
        var located = 0
        var inAlbum = 0
        var yearCounts: [Int: Int] = [:]
        var monthCounts: [String: Int] = [:]
        var cameraCounts: [String: Int] = [:]
        var lensCounts: [String: Int] = [:]
        var placeCounts: [String: Int] = [:]
        var sampled = 0

        for (index, photo) in source.enumerated() {
            if photo.isVideo { videoCount += 1 }
            totalBytes += photo.fileSize
            if !(photo.keywords ?? []).isEmpty { keyworded += 1 }
            if photo.starRating > 0 { rated += 1 }
            if photo.hasLocation { located += 1 }
            if albumIDs.contains(photo.id) { inAlbum += 1 }
            guard index % stride == 0 else { continue }
            sampled += 1

            let components = calendar.dateComponents([.year, .month], from: photo.capturedAt)
            if let year = components.year {
                yearCounts[year, default: 0] += 1
                if let month = components.month {
                    monthCounts[String(format: "%04d-%02d", year, month), default: 0] += 1
                }
            }
            if let model = photo.model, !model.isEmpty {
                let name = [photo.make, model]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !name.isEmpty { cameraCounts[name, default: 0] += 1 }
            }
            if let lens = photo.lens, !lens.isEmpty {
                lensCounts[lens, default: 0] += 1
            }
            let place = [photo.placeCity, photo.placeProvince, photo.placePOI, photo.placeCountry]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            if let place { placeCounts[place, default: 0] += 1 }
        }

        let total = source.count
        var payload: [String: Any] = [
            "scope": sidebarTitle,
            "total": total,
            "photos": total - videoCount,
            "videos": videoCount,
            "total_gb": (Double(totalBytes) / 1_073_741_824 * 10).rounded() / 10,
            "average_mb": total > 0 ? Int(Double(totalBytes) / Double(total) / 1_048_576) : 0,
            "sampled": sampled,
            "years": yearCounts
                .sorted { $0.key > $1.key }
                .prefix(40)
                .map { ["year": $0.key, "count": $0.value] },
            "top_months": Self.aiTopCounts(monthCounts, limit: top, keyName: "month"),
            "cameras": Self.aiTopCounts(cameraCounts, limit: top, keyName: "name"),
            "lenses": Self.aiTopCounts(lensCounts, limit: top, keyName: "name"),
            "places": Self.aiTopCounts(placeCounts, limit: top, keyName: "name"),
            "coverage": [
                "with_keywords": keyworded,
                "without_keywords": total - keyworded,
                "rated": rated,
                "unrated": total - rated,
                "with_location": located,
                "without_location": total - located,
                "in_album": inAlbum,
                "not_in_album": total - inAlbum
            ]
        ]
        if stride > 1 {
            payload["note"] = "分布按 \(sampled.formatted()) 张抽样统计，总量为精确值"
        }
        let busiestYear = yearCounts.max { $0.value < $1.value }?.key
        let summary = busiestYear.map { "当前范围 \(total.formatted()) 项，\($0) 年最多" }
            ?? "当前范围 \(total.formatted()) 项"
        return success(payload, summary: summary, photoIDs: [])
    }

    // MARK: - 旅行与回忆

    func listTripsTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(50, max(1, AILibraryTools.integer(args["limit"], fallback: 10)))
        let year = AILibraryTools.integer(args["year"], fallback: 0)
        var all = trips
        if year > 0 {
            all = all.filter { Calendar.current.component(.year, from: $0.startDate) == year }
        }
        guard !all.isEmpty else {
            return success(["count": 0, "trips": []],
                           summary: year > 0 ? "\(year) 年还没有识别到旅行" : "还没有识别到旅行（需要带 GPS 的照片）",
                           photoIDs: [])
        }
        let picked = Array(all.prefix(limit))
        let items: [[String: Any]] = picked.map { trip in
            var item: [String: Any] = [
                "id": trip.id,
                "title": trip.title,
                "subtitle": trip.subtitle,
                "start": Self.aiDateFormatter.string(from: trip.startDate),
                "end": Self.aiDateFormatter.string(from: trip.endDate),
                "days": trip.dayCount,
                "places": trip.placeCount,
                "photos": trip.photos.count,
                "videos": trip.photos.filter(\.isVideo).count
            ]
            if let cover = trip.photos.first(where: { !$0.isVideo }) {
                item["cover_id"] = cover.id.uuidString
            }
            return item
        }
        return success(["count": all.count, "trips": items],
                       summary: "识别到 \(all.count) 次旅行",
                       photoIDs: [])
    }

    func playTripMemoryTool(_ args: [String: Any]) -> AIToolExecution {
        guard let raw = AILibraryTools.string(args["trip"]) else {
            return failure("请提供旅行 id、标题关键词，或 latest")
        }
        let all = trips
        guard !all.isEmpty else {
            return failure("还没有识别到旅行；需要带 GPS 的照片，可先用 list_trips 查看")
        }
        let lower = raw.lowercased()
        let trip: TripStory?
        if lower == "latest" || raw == "最近" {
            trip = all.first
        } else if let matched = all.first(where: { $0.id == raw }) {
            trip = matched
        } else {
            trip = all.first {
                $0.title.lowercased().contains(lower) || $0.subtitle.lowercased().contains(lower)
            }
        }
        guard let trip else {
            let names = all.prefix(5).map(\.title).joined(separator: "、")
            return failure("没有找到这次旅行，可先用 list_trips 查看；最近的有：\(names)")
        }
        let photos = trip.photos.filter { !$0.isVideo }
        guard !photos.isEmpty else {
            return failure("这次旅行没有可播放的照片")
        }
        var style: MemoryStyle = .cinematic
        switch AILibraryTools.string(args["style"]) {
        case "classic": style = .classic
        case "fresh": style = .fresh
        default: break
        }
        activeMemory = PhotoMemory(id: "ai-trip-" + trip.id,
                                   title: trip.title,
                                   subtitle: trip.subtitle,
                                   kind: .place,
                                   photos: photos,
                                   style: style)
        return success(["trip": trip.title,
                        "photos": photos.count,
                        "style": style.rawValue],
                       summary: "播放回忆影片「\(trip.title)」",
                       photoIDs: [])
    }

    // MARK: - 图库体检

    func libraryHealthReportTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(50, max(1, AILibraryTools.integer(args["limit"], fallback: 10)))
        let wantScan = AILibraryTools.bool(args["scan"], fallback: false)
        if AILibraryTools.bool(args["open"], fallback: false) {
            navigate(to: .health)
        }
        if isScanningHealth {
            return success(["scanning": true,
                            "progress": (healthScanProgress * 100).rounded()],
                           summary: "图库体检进行中（\(Int(healthScanProgress * 100))%）",
                           photoIDs: [])
        }
        guard !isCloudScope, healthReportMatchesCurrentScope, let report = healthReport else {
            if wantScan, canScanHealth {
                scanLibraryHealth()
                return success(["scanning": true, "started": true],
                               summary: "已在后台开始图库体检，进度见左下角任务条",
                               photoIDs: [])
            }
            return success(["scanned": false, "can_scan": canScanHealth],
                           summary: canScanHealth
                                ? "还没有体检结果；传 scan=true 可在后台开始，或打开「图库体检」"
                                : "当前范围不支持体检，请切换到拾光本地图库或系统图库",
                           photoIDs: [])
        }

        let blurry = report.blurry.prefix(limit).map { finding -> [String: Any] in
            [
                "id": finding.photo.id.uuidString,
                "name": finding.photo.displayTitle,
                "score": (finding.score * 10).rounded() / 10,
                "size_mb": Double(finding.photo.fileSize) / 1_048_576
            ]
        }
        let similar = report.similarGroups.prefix(limit).map { group -> [String: Any] in
            [
                "best_id": group.best.id.uuidString,
                "best": group.best.displayTitle,
                "duplicates": group.duplicates.count,
                "similarity": Int((group.similarity * 100).rounded()),
                "reclaimable_mb": Int(Double(group.duplicates.reduce(Int64(0)) { $0 + $1.fileSize }) / 1_048_576)
            ]
        }
        let largeVideos = report.largeVideos.prefix(limit).map { photo -> [String: Any] in
            [
                "id": photo.id.uuidString,
                "name": photo.displayTitle,
                "size_mb": Int(Double(photo.fileSize) / 1_048_576),
                "duration": Self.aiDurationText(photo.duration)
            ]
        }
        let payload: [String: Any] = [
            "scanned_at": Self.aiDateFormatter.string(from: report.scannedAt),
            "scanned_count": report.scannedCount,
            "blurry_count": report.blurry.count,
            "similar_group_count": report.similarGroups.count,
            "similar_duplicate_count": report.similarDuplicatePhotos.count,
            "reclaimable_mb": Int(Double(report.reclaimableBytes) / 1_048_576),
            "blurry_mb": Int(Double(report.blurryBytes) / 1_048_576),
            "large_video_count": report.largeVideos.count,
            "blurry": Array(blurry),
            "similar_groups": Array(similar),
            "large_videos": Array(largeVideos)
        ]
        return success(payload,
                       summary: "\(report.blurry.count) 张可能模糊 · \(report.similarGroups.count) 组相似 · 可省 \(Int(Double(report.reclaimableBytes) / 1_048_576)) MB",
                       photoIDs: [])
    }

    // MARK: - 影院体检

    func cinemaHealthReportTool(_ args: [String: Any]) -> AIToolExecution {
        let sampleLimit = min(30, max(1, AILibraryTools.integer(args["limit"], fallback: 5)))
        var scopes: [CinemaScope] = [.local] + cloudMounts.map { .mount($0.id) }
        // 当前影院排在最前，回答与界面一致。
        if let index = scopes.firstIndex(of: cinemaActiveScope) {
            scopes.remove(at: index)
            scopes.insert(cinemaActiveScope, at: 0)
        }

        var rows: [[String: Any]] = []
        var totalVideos = 0
        var totalMatched = 0
        var totalMissingArtwork = 0
        for scope in scopes {
            let candidates = cinemaCandidates(for: scope)
            let entries = Array(cinemaEntries(for: scope).values)
            guard !candidates.isEmpty || !entries.isEmpty else { continue }
            let matched = entries.filter(\.matched)
            let matchedIDs = Set(matched.map(\.id))
            let missingArtwork = matched.filter {
                ($0.artworkURL ?? "").isEmpty
            }.count
            let unmatched = candidates.filter { !matchedIDs.contains($0.photo.id) }
            totalVideos += candidates.count
            totalMatched += matched.count
            totalMissingArtwork += missingArtwork

            var row: [String: Any] = [
                "scope": Self.cinemaScopeKey(scope),
                "name": cinemaScopeName(scope),
                "active": scope == cinemaActiveScope,
                "videos": candidates.count,
                "matched": matched.count,
                "unmatched": unmatched.count,
                "missing_artwork": missingArtwork,
                "movies": matched.filter { $0.kind == .movie }.count,
                "tv_episodes": matched.filter { $0.kind == .tv }.count,
                "tv_series": Set(matched.filter { $0.kind == .tv }
                    .map { "\($0.title)|\($0.season ?? 0)" }).count,
                "unmatched_samples": unmatched.prefix(sampleLimit).map { candidate -> [String: Any] in
                    [
                        "id": candidate.photo.id.uuidString,
                        "filename": candidate.photo.displayFilename
                    ]
                }
            ]
            if let finished = sourceJobHistory
                .filter({ $0.kind == .scrape })
                .filter({ cinemaScopeKey(forJob: $0.jobID) == Self.cinemaScopeKey(scope) })
                .max(by: { $0.updatedAt < $1.updatedAt }) {
                row["last_scrape"] = [
                    "at": Self.aiDateFormatter.string(from: finished.updatedAt),
                    "matched": finished.completed,
                    "message": finished.message ?? ""
                ]
            }
            rows.append(row)
        }

        let unread = cinemaNotifications.filter { !$0.read }.count
        let payload: [String: Any] = [
            "videos": totalVideos,
            "matched": totalMatched,
            "unmatched": max(0, totalVideos - totalMatched),
            "missing_artwork": totalMissingArtwork,
            "unread_notifications": unread,
            "scopes": rows
        ]
        return success(payload,
                       summary: "影院共 \(totalVideos.formatted()) 个视频 · 未识别 \(max(0, totalVideos - totalMatched).formatted())",
                       photoIDs: [])
    }

    // MARK: - 跨端续看

    func resumeWatchingTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(50, max(1, AILibraryTools.integer(args["limit"], fallback: 10)))
        let sorted = aiResumeEntries()
        guard !sorted.isEmpty else {
            return success(["count": 0, "items": []],
                           summary: "所有来源都没有未看完的记录",
                           photoIDs: [])
        }
        aiCatalogCandidates.removeAll()
        var items: [[String: Any]] = []
        for entry in sorted.prefix(limit) {
            var payload = entry.payload
            if let candidate = entry.candidate {
                let ref = "#\(items.count + 1)"
                aiCatalogCandidates[ref] = candidate
                aiCatalogCandidates["\(candidate.sourceID.uuidString)|\(candidate.item.id)"] = candidate
                payload["ref"] = ref
            }
            items.append(payload)
        }
        return success(["count": sorted.count, "items": items],
                       summary: "共 \(sorted.count) 条未看完，最近的是「\(items.first?["title"] as? String ?? "")」",
                       photoIDs: [])
    }

    // MARK: - 今日日报

    func todayDigestTool(_ args: [String: Any]) async -> AIToolExecution {
        let limit = min(30, max(1, AILibraryTools.integer(args["limit"], fallback: 8)))
        let includeTV = AILibraryTools.bool(args["include_tv"], fallback: true)
        let includeContinue = AILibraryTools.bool(args["include_continue"], fallback: true)

        var payload: [String: Any] = ["date": Self.aiDateFormatter.string(from: Date())]
        var summaries: [String] = []
        aiCatalogCandidates.removeAll()
        var refCounter = 0
        func register(_ sourceID: UUID, _ item: CatalogItem) -> String {
            refCounter += 1
            let ref = "#\(refCounter)"
            aiCatalogCandidates[ref] = (sourceID, item)
            aiCatalogCandidates["\(sourceID.uuidString)|\(item.id)"] = (sourceID, item)
            return ref
        }

        // 1. 网络资源今天新增
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let names = Dictionary(uniqueKeysWithValues: catalogModel.sources.map { ($0.id, $0.name) })
        let today = catalogModel.calendarItems
            .filter { catalogModel.resourceSourceIDs.contains($0.sourceID) }
            .filter { $0.firstSeen >= start && $0.firstSeen < end }
            .sorted { $0.firstSeen > $1.firstSeen }
        if !today.isEmpty {
            let items = today.prefix(limit).map { entry -> [String: Any] in
                [
                    "ref": register(entry.sourceID, entry.item),
                    "source": names[entry.sourceID] ?? "",
                    "title": entry.title,
                    "remark": entry.remark
                ]
            }
            payload["catalog_new"] = ["count": today.count, "items": Array(items)]
            summaries.append("新资源 \(today.count) 条")
        } else {
            payload["catalog_new"] = ["count": 0, "items": []]
        }

        // 2. 追更人物更新
        let following = catalogModel.followedPeople
            .filter { $0.newCount > 0 }
            .sorted { $0.newCount > $1.newCount }
        if !following.isEmpty {
            payload["following"] = following.prefix(limit).map { person -> [String: Any] in
                [
                    "name": person.name,
                    "role": person.role,
                    "source": names[person.sourceID] ?? "",
                    "new_count": person.newCount
                ]
            }
            summaries.append("\(following.count) 位关注人物有更新")
        }

        // 3. 跨端续看
        if includeContinue {
            let entries = Array(aiResumeEntries().prefix(limit))
            if !entries.isEmpty {
                let items = entries.map { entry -> [String: Any] in
                    var item = entry.payload
                    if let candidate = entry.candidate {
                        item["ref"] = register(candidate.sourceID, candidate.item)
                    }
                    return item
                }
                payload["continue"] = items
                summaries.append("\(entries.count) 条没看完")
            }
        }

        // 4. 收藏频道今晚节目（只读已加载的节目单，避免日报卡在下载上）
        if includeTV {
            let result = await tvTonightRows(channelNames: [],
                                             dayOffset: 0,
                                             limitPerChannel: 2,
                                             waitForEPG: false)
            if result.rows.isEmpty {
                payload["tv_tonight"] = [
                    "epg_ready": result.epgReady,
                    "note": result.epgReady ? "收藏频道今晚暂无节目" : "节目单还没加载，可打开电视页后重试"
                ]
            } else {
                payload["tv_tonight"] = result.rows
                summaries.append("\(result.rows.count) 个收藏频道")
            }
        }

        return success(payload,
                       summary: summaries.isEmpty ? "今天没有新的内容" : summaries.joined(separator: " · "),
                       photoIDs: [])
    }

    // MARK: - 辅助

    private struct ResumeEntry {
        let updatedAt: Date
        let payload: [String: Any]
        let candidate: (sourceID: UUID, item: CatalogItem)?
    }

    /// 汇总本地影院、网盘影院、网络影院与网络资源的续看记录，按最近观看排序。
    private func aiResumeEntries() -> [ResumeEntry] {
        var result: [ResumeEntry] = []
        var scopes: [CinemaScope] = [.local] + cloudMounts.map { .mount($0.id) }
        if let index = scopes.firstIndex(of: cinemaActiveScope) {
            scopes.remove(at: index)
            scopes.insert(cinemaActiveScope, at: 0)
        }
        for scope in scopes {
            for record in cinemaContinueRecords(for: scope) {
                var payload: [String: Any] = [
                    "kind": "cinema",
                    "scope": Self.cinemaScopeKey(scope),
                    "scope_name": cinemaScopeName(scope),
                    "target": record.photoID.uuidString,
                    "title": record.title,
                    "fraction": Int((record.fraction * 100).rounded()),
                    "remaining_min": Int((record.remainingSeconds / 60).rounded()),
                    "updated_at": Self.aiDateFormatter.string(from: record.updatedAt),
                    "play_tool": "play_cinema"
                ]
                if let subtitle = record.subtitle, !subtitle.isEmpty {
                    payload["subtitle"] = subtitle
                }
                result.append(ResumeEntry(updatedAt: record.updatedAt,
                                          payload: payload,
                                          candidate: nil))
            }
        }

        let cinemaIDs = catalogModel.cinemaSourceIDs
        let resourceIDs = catalogModel.resourceSourceIDs
        let names = Dictionary(uniqueKeysWithValues: catalogModel.sources.map { ($0.id, $0.name) })
        for record in catalogModel.allContinueWatching {
            let isCinema = cinemaIDs.contains(record.sourceID)
            let isResource = resourceIDs.contains(record.sourceID)
            guard isCinema || isResource else { continue }
            guard record.seconds > 3, record.fraction < 0.95 else { continue }
            let item = CatalogItem(id: record.itemID,
                                   title: record.title,
                                   coverURL: record.coverURL,
                                   remark: "",
                                   categoryID: nil)
            var payload: [String: Any] = [
                "kind": isCinema ? "network_cinema" : "catalog",
                "source_id": record.sourceID.uuidString,
                "source": names[record.sourceID] ?? "",
                "item_id": record.itemID,
                "title": record.title,
                "episode": record.episode,
                "fraction": Int((record.fraction * 100).rounded()),
                "updated_at": Self.aiDateFormatter.string(from: record.updatedAt),
                "play_tool": isCinema ? "play_network_cinema" : "play_catalog_item"
            ]
            if record.episode > 0 {
                payload["episode"] = record.episode
            } else {
                payload.removeValue(forKey: "episode")
            }
            result.append(ResumeEntry(updatedAt: record.updatedAt,
                                      payload: payload,
                                      candidate: (record.sourceID, item)))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 把 [名称: 次数] 排序成可直接返回给模型的数组。
    private static func aiTopCounts(_ counts: [String: Int],
                                    limit: Int,
                                    keyName: String) -> [[String: Any]] {
        counts
            .sorted { $0.value == $1.value ? $0.key > $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { [keyName: $0.key, "count": $0.value] }
    }
}
