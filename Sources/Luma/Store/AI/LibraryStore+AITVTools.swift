import Foundation

/// 「今晚节目」的聚合结果：日报与 tv_tonight 共用。
struct TVTonightResult {
    var rows: [[String: Any]] = []
    var missing: [String] = []
    var epgReady = false
    var date = Date()
}

// MARK: - 执行

extension LibraryStore {
    func listTVSourcesTool() -> AIToolExecution {
        let items = tvModel.playlists.map { playlist -> [String: Any] in
            var item: [String: Any] = [
                "id": playlist.id.uuidString,
                "name": playlist.name,
                "region": playlist.region.title,
                "enabled": playlist.isEnabled,
                "focused": tvModel.focusedPlaylistID == playlist.id
            ]
            if let count = playlist.lastChannelCount { item["channels"] = count }
            if let latency = playlist.lastLatencyMilliseconds { item["latency_ms"] = latency }
            if let error = playlist.lastError, !error.isEmpty { item["error"] = error }
            return item
        }
        return success(["enabled": tvModel.enabled,
                        "count": items.count,
                        "sources": items],
                       summary: "电视源 \(items.count) 个",
                       photoIDs: [])
    }

    func listTVChannelsTool(_ args: [String: Any]) async -> AIToolExecution {
        guard await tvEnsureChannelsLoaded() else {
            return failure("电视源正在加载或没有可用频道；可在「网络电视 · 源库」检查电视源是否启用")
        }
        let query = (AILibraryTools.string(args["query"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let limit = min(2000, max(1, AILibraryTools.integer(args["limit"], fallback: 200)))
        var source: TVPlaylist?
        if let raw = AILibraryTools.string(args["source"]) {
            guard let resolved = tvResolveSource(raw) else {
                return failure("没有找到电视源「\(raw)」，可先调用 list_tv_sources")
            }
            source = resolved
        }
        let group = AILibraryTools.string(args["group"])?.lowercased()
        let items: [[String: Any]] = tvModel.channels
            .filter { channel in
                if let source, channel.playlistID != source.id { return false }
                if let group, !group.isEmpty,
                   !channel.group.lowercased().contains(group) { return false }
                guard !query.isEmpty else { return true }
                return channel.name.lowercased().contains(query)
                    || channel.group.lowercased().contains(query)
                    || (channel.province ?? "").lowercased().contains(query)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(limit)
            .map { tvChannelPayload($0) }
        return success(["count": items.count,
                        "source": source?.name ?? "全部频道",
                        "channels": items],
                       summary: "频道 \(items.count) 个",
                       photoIDs: [])
    }

    func getTVGuideTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let raw = AILibraryTools.string(args["channel"]) else {
            return failure("请提供频道名称或 id")
        }
        guard await tvEnsureChannelsLoaded() else {
            return failure("电视源正在加载或没有可用频道；可先调用 list_tv_channels")
        }
        guard let channel = tvResolveChannel(raw, sourceRaw: AILibraryTools.string(args["source"])) else {
            return failure("没有找到频道「\(raw)」，可先调用 list_tv_channels")
        }
        let offset = min(3, max(-3, AILibraryTools.integer(args["day_offset"], fallback: 0)))
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let programs = await tvPrograms(on: date, for: channel)
        let limit = min(200, max(1, AILibraryTools.integer(args["limit"], fallback: 60)))
        let items: [[String: Any]] = programs.prefix(limit).map { program in
            var item: [String: Any] = [
                "title": program.title,
                "start": Self.tvTimeFormatter.string(from: program.start),
                "end": Self.tvTimeFormatter.string(from: program.end),
                "live": program.isLive
            ]
            if let subtitle = program.subtitle, !subtitle.isEmpty { item["subtitle"] = subtitle }
            if let overview = program.overview, !overview.isEmpty {
                item["overview"] = String(overview.prefix(200))
            }
            if channel.catchUpSource != nil { item["catch_up"] = true }
            return item
        }
        var payload: [String: Any] = [
            "channel": channel.name,
            "source": tvModel.playlistName(for: channel.playlistID),
            "date": Self.tvDayFormatter.string(from: date),
            "count": items.count,
            "programs": items
        ]
        if tvModel.isLoadingEPG { payload["epg_loading"] = true }
        if let updated = tvModel.epgUpdatedAt {
            payload["epg_updated"] = Self.tvTimeFormatter.string(from: updated)
        }
        return success(payload,
                       summary: programs.isEmpty
                            ? "「\(channel.name)」这天还没有节目单"
                            : "「\(channel.name)」\(items.count) 档节目",
                       photoIDs: [])
    }

    func tvTonightTool(_ args: [String: Any]) async -> AIToolExecution {
        guard await tvEnsureChannelsLoaded() else {
            return failure("电视源正在加载或没有可用频道；可在「网络电视 · 源库」检查电视源是否启用")
        }
        let names = AILibraryTools.stringArray(args["channels"])
        let dayOffset = min(3, max(0, AILibraryTools.integer(args["day_offset"], fallback: 0)))
        let limit = min(20, max(1, AILibraryTools.integer(args["limit"], fallback: 4)))
        let result = await tvTonightRows(channelNames: names,
                                         dayOffset: dayOffset,
                                         limitPerChannel: limit,
                                         waitForEPG: true)
        var payload: [String: Any] = [
            "date": Self.tvDayFormatter.string(from: result.date),
            "epg_ready": result.epgReady,
            "channels": result.rows
        ]
        if !result.missing.isEmpty { payload["missing"] = result.missing }
        guard !result.rows.isEmpty else {
            return success(payload,
                           summary: result.epgReady
                                ? "这些频道今晚暂无节目"
                                : "节目单还没加载，可稍后重试或先在电视页打开一次",
                           photoIDs: [])
        }
        return success(payload,
                       summary: "\(result.rows.count) 个频道的节目",
                       photoIDs: [])
    }

    /// 聚合若干频道从当前时刻起的节目。`waitForEPG=false` 只读已下载的节目单，供日报使用。
    func tvTonightRows(channelNames: [String],
                       dayOffset: Int,
                       limitPerChannel: Int,
                       waitForEPG: Bool) async -> TVTonightResult {
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        tvModel.loadEPGIfNeeded()

        var channels: [TVChannel] = []
        var missing: [String] = []
        if channelNames.isEmpty {
            let favorites = tvModel.channels.filter { tvModel.favoriteIDs.contains($0.id) }
            if favorites.isEmpty {
                channels = Array(tvModel.channels
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .prefix(6))
            } else {
                channels = Array(favorites.prefix(6))
            }
        } else {
            for raw in channelNames {
                if let channel = tvResolveChannel(raw, sourceRaw: nil) {
                    channels.append(channel)
                } else {
                    missing.append(raw)
                }
            }
            channels = Array(channels.prefix(8))
        }

        var rows: [[String: Any]] = []
        let now = Date()
        for channel in channels {
            if Task.isCancelled { break }
            let programs = waitForEPG
                ? await tvPrograms(on: date, for: channel)
                : tvModel.programs(on: date, for: channel)
            let upcoming = programs
                .filter { dayOffset > 0 || $0.end >= now }
                .sorted { $0.start < $1.start }
            if upcoming.isEmpty {
                // 节目单完全没加载时，后面的频道也不必逐个等待下载。
                if waitForEPG, programs.isEmpty { break }
                continue
            }
            var row: [String: Any] = [
                "channel": channel.name,
                "source": tvModel.playlistName(for: channel.playlistID),
                "favorite": tvModel.favoriteIDs.contains(channel.id),
                "programs": upcoming.prefix(limitPerChannel).map { program -> [String: Any] in
                    var item: [String: Any] = [
                        "title": program.title,
                        "start": Self.tvTimeFormatter.string(from: program.start),
                        "end": Self.tvTimeFormatter.string(from: program.end),
                        "live": program.isLive
                    ]
                    if let subtitle = program.subtitle, !subtitle.isEmpty {
                        item["subtitle"] = subtitle
                    }
                    return item
                }
            ]
            if channel.catchUpSource != nil { row["catch_up"] = true }
            rows.append(row)
        }

        return TVTonightResult(rows: rows,
                               missing: missing,
                               epgReady: tvModel.epgUpdatedAt != nil,
                               date: date)
    }

    func playTVChannelTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let raw = AILibraryTools.string(args["channel"]) else {
            return failure("请提供频道名称或 id")
        }
        guard await tvEnsureChannelsLoaded() else {
            return failure("电视源正在加载或没有可用频道；可先调用 list_tv_channels")
        }
        guard let channel = tvResolveChannel(raw, sourceRaw: AILibraryTools.string(args["source"])) else {
            return failure("没有找到频道「\(raw)」，可先调用 list_tv_channels")
        }
        guard AILibraryTools.bool(args["catch_up"], fallback: false) else {
            openTVChannel(channel)
            return success(["channel": channel.name,
                            "source": tvModel.playlistName(for: channel.playlistID),
                            "mode": "live"],
                           summary: "播放直播「\(channel.name)」",
                           photoIDs: [])
        }

        let offset = min(3, max(-3, AILibraryTools.integer(args["day_offset"], fallback: 0)))
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let programs = await tvPrograms(on: date, for: channel)
        guard !programs.isEmpty else {
            return failure("「\(channel.name)」这天还没有节目单，可先调用 get_tv_guide 确认")
        }
        let wanted = (AILibraryTools.string(args["program"]) ?? "").lowercased()
        guard let program = programs.first(where: {
            wanted.isEmpty || $0.title.lowercased().contains(wanted)
        }) else {
            let names = programs.prefix(5).map(\.title).joined(separator: "、")
            return failure("没有找到节目「\(wanted)」，这天的节目有：\(names)")
        }
        guard channel.catchUpSource != nil else {
            return failure("「\(channel.name)」这个源不支持回看，只能播放直播")
        }
        openTVCatchup(channel, program: program)
        return success(["channel": channel.name,
                        "program": program.title,
                        "start": Self.tvTimeFormatter.string(from: program.start),
                        "mode": "catchup"],
                       summary: "回看「\(channel.name)」· \(program.title)",
                       photoIDs: [])
    }

    func favoriteTVChannelTool(_ args: [String: Any]) -> AIToolExecution {
        guard tvEnsureChannelsAvailable() else {
            return failure("电视源还没有加载出频道；可先在「网络电视」打开一次")
        }
        let favorite = AILibraryTools.bool(args["favorite"], fallback: true)
        let raws = AILibraryTools.stringArray(args["targets"])
        guard !raws.isEmpty else { return failure("请提供频道名称或 id") }
        let sourceRaw = AILibraryTools.string(args["source"])
        var resolved: [TVChannel] = []
        var missing: [String] = []
        for raw in raws {
            if let channel = tvResolveChannel(raw, sourceRaw: sourceRaw) {
                resolved.append(channel)
            } else {
                missing.append(raw)
            }
        }
        guard !resolved.isEmpty else {
            return failure("没有找到这些频道：\(missing.prefix(3).joined(separator: "、"))")
        }
        var changed = 0
        for channel in resolved {
            let isFavorite = tvModel.favoriteIDs.contains(channel.id)
            if isFavorite != favorite {
                tvModel.toggleFavorite(channel)
                changed += 1
            }
        }
        var payload: [String: Any] = ["favorite": favorite, "count": changed]
        if !missing.isEmpty { payload["missing"] = missing }
        return success(payload,
                       summary: "\(favorite ? "收藏" : "取消收藏") \(changed) 个频道",
                       photoIDs: [])
    }

    func navigateTVTool(_ args: [String: Any]) -> AIToolExecution {
        tvModel.setEnabled(true)
        if let raw = AILibraryTools.string(args["source"]) {
            guard let playlist = tvResolveSource(raw) else {
                return failure("没有找到电视源「\(raw)」，可先调用 list_tv_sources")
            }
            sourceHub.activate(.television(playlist.id))
        } else {
            tvModel.focusAllSources()
            navigate(to: .iptv)
        }
        if let raw = AILibraryTools.string(args["tab"]) {
            tvModel.setHubTab(TVHubTab(rawValue: raw) ?? .channels)
        } else {
            tvModel.setHubTab(.channels)
        }
        if let group = AILibraryTools.string(args["group"]), !group.isEmpty {
            if let id = tvModel.focusedPlaylistID {
                tvModel.focusGroup(group, in: id)
            } else {
                tvModel.groupFilter = group
            }
        }
        if let search = AILibraryTools.string(args["search"]) {
            tvModel.searchText = search
        }
        if args["day_offset"] != nil {
            tvModel.guideDayOffset = min(3, max(-3, AILibraryTools.integer(args["day_offset"],
                                                                          fallback: 0)))
        }
        tvModel.refreshIfNeeded()
        return success(["tab": tvModel.hubTab.title,
                        "source": tvModel.focusedPlaylistID.map { tvModel.playlistName(for: $0) }
                            ?? "全部频道",
                        "count": tvModel.visibleChannels.count],
                       summary: "已打开网络电视 · \(tvModel.hubTab.title)",
                       photoIDs: [])
    }

    // MARK: - 辅助

    /// 首次调用时电视源可能还没加载：给后台拉取一点时间，失败再提示用户。
    private func tvEnsureChannelsLoaded(timeout: TimeInterval = 6) async -> Bool {
        tvModel.setEnabled(true)
        tvModel.refreshIfNeeded()
        if tvEnsureChannelsAvailable() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if tvEnsureChannelsAvailable() { return true }
        }
        return tvEnsureChannelsAvailable()
    }

    private func tvEnsureChannelsAvailable() -> Bool {
        if !tvModel.channels.isEmpty { return true }
        tvModel.refreshIfNeeded()
        return !tvModel.channels.isEmpty
    }

    private func tvPrograms(on date: Date, for channel: TVChannel) async -> [TVEPGProgram] {
        tvModel.loadEPGIfNeeded()
        var programs = tvModel.programs(on: date, for: channel)
        guard programs.isEmpty else { return programs }
        // 节目单是异步下载：短等一会儿，仍为空就按「暂无节目单」返回。
        for _ in 0..<16 {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
            programs = tvModel.programs(on: date, for: channel)
            if !programs.isEmpty { break }
        }
        return programs
    }

    private func tvResolveSource(_ raw: String) -> TVPlaylist? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "all" || text == "全部" || text == "全部频道" { return nil }
        if let id = UUID(uuidString: text) {
            return tvModel.playlists.first { $0.id == id }
        }
        if let exact = tvModel.playlists.first(where: {
            $0.name.caseInsensitiveCompare(text) == .orderedSame
        }) {
            return exact
        }
        return tvModel.playlists.first {
            $0.name.lowercased().contains(text.lowercased())
        }
    }

    private func tvResolveChannel(_ raw: String, sourceRaw: String?) -> TVChannel? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var pool = tvModel.channels
        if let sourceRaw, let playlist = tvResolveSource(sourceRaw) {
            pool = pool.filter { $0.playlistID == playlist.id }
        }
        if let exact = pool.first(where: { $0.id == text }) { return exact }
        if let exact = pool.first(where: {
            $0.name.caseInsensitiveCompare(text) == .orderedSame
        }) {
            return exact
        }
        let normalized = TVChannel.normalizedName(text)
        if let match = pool.first(where: { TVChannel.normalizedName($0.name) == normalized }) {
            return match
        }
        let lower = text.lowercased()
        return pool.first {
            $0.name.lowercased().contains(lower) || $0.group.lowercased().contains(lower)
        }
    }

    private func tvChannelPayload(_ channel: TVChannel) -> [String: Any] {
        var item: [String: Any] = [
            "id": channel.id,
            "name": channel.name,
            "group": channel.group,
            "source_id": channel.playlistID.uuidString,
            "source": tvModel.playlistName(for: channel.playlistID),
            "region": channel.region.title,
            "lines": channel.lineCount,
            "catchup_days": channel.effectiveCatchUpDays,
            "favorite": tvModel.favoriteIDs.contains(channel.id)
        ]
        if let quality = channel.qualityLabel, !quality.isEmpty { item["quality"] = quality }
        if let province = channel.province, !province.isEmpty { item["province"] = province }
        return item
    }

    private static let tvTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let tvDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
