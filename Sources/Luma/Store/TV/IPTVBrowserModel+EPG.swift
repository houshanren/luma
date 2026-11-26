import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - EPG / 回看

    /// 进入节目单 / 回看页、或在播放里打开节目信息时调用。
    /// 有磁盘缓存就先用起来（不联网）；缓存过期时再把刷新排进后台任务。
    func loadEPGIfNeeded(force: Bool = false) {
        guard enabled else { return }
        if force {
            // 手动刷新：上一轮节目单任务先收尾，再重新登记一轮。
            if let epgJobID {
                jobCenter?.cancel(epgJobID)
                onJobFinished?(epgJobID)
                onJobChange?()
            }
            epgJobID = nil
            tasks.cancel(.tvEPG)
            isLoadingEPG = false
        }
        guard !isLoadingEPG else { return }
        let feeds = epgFeeds()

        // 内存里还没有节目：先把上次的磁盘缓存垫进来，界面立即可用。
        if epgPrograms.isEmpty {
            hydrateEPGFromCache()
        }

        if !force {
            if let updated = epgUpdatedAt,
               Date().timeIntervalSince(updated) < TVEPGService.cacheMaxAge,
               !epgPrograms.isEmpty {
                return
            }
            // 内存还空、但磁盘缓存还新：等 hydrate 垫上，不重复下载。
            if epgPrograms.isEmpty, isEPGCacheFresh(feeds) {
                return
            }
        }

        isLoadingEPG = true
        epgError = nil
        tasks.cancel(.tvEPG)
        // 节目单更新登记成后台任务：左下角任务条能看到逐个源的进度，也能取消。
        let jobID = jobCenter?.begin(
            SourceJob(sourceID: SourceID("tv:epg"),
                      kind: .epg,
                      title: "更新网络电视节目单"),
            cancel: { [weak self] in
                Task { @MainActor in self?.tasks.cancel(.tvEPG) }
            }
        )
        epgJobID = jobID
        onJobChange?()

        tasks.adopt(.tvEPG, Task { [weak self] in
            var merged: [String: [TVEPGProgram]] = [:]
            var names: [String: [String]] = [:]
            var errors: [String] = []
            var supplementError: String?
            var seenURLs = Set<String>()
            var done = 0
            var cancelled = false
            var failureMessage: String?
            var successMessage: String?

            // 成功 / 失败 / 取消都要收尾任务条，并写进任务记录。
            defer {
                if let self {
                    // 手动刷新会先开新一轮：旧任务收尾时不能把新任务的 ID / 载入状态清掉。
                    let isCurrent = self.epgJobID == jobID
                    if isCurrent { self.epgJobID = nil }
                    if let jobID {
                        if cancelled || Task.isCancelled {
                            self.jobCenter?.cancel(jobID)
                        } else if let failureMessage {
                            self.jobCenter?.fail(jobID, message: failureMessage)
                        } else {
                            self.jobCenter?.finish(jobID, message: successMessage)
                        }
                        self.onJobFinished?(jobID)
                    }
                    if isCurrent { self.isLoadingEPG = false }
                    self.onJobChange?()
                }
            }

            for feed in feeds {
                if Task.isCancelled {
                    cancelled = true
                    return
                }
                if let jobID {
                    self?.jobCenter?.update(jobID,
                                            completed: done,
                                            total: feeds.count,
                                            message: feed.label)
                    self?.onJobChange?()
                }
                // 多个源共用同一份 XMLTV：只拉一次。
                guard seenURLs.insert(feed.url).inserted else {
                    done += 1
                    continue
                }
                do {
                    let data = try await TVEPGService.load(urlString: feed.url)
                    Self.absorb(data, into: &merged, names: &names)
                } catch {
                    let message = (error as? SourceError)?.message ?? error.localizedDescription
                    if feed.isSupplement {
                        supplementError = message
                    } else {
                        errors.append("\(feed.label)：\(message)")
                    }
                }
                done += 1
            }
            guard let self else { return }
            if Task.isCancelled {
                cancelled = true
                return
            }
            // 合并 / 排序 / 建前缀桶都比较重，放到后台线程，避免刷新节目单时卡主线程。
            let prepared = await Task.detached(priority: .utility) { () -> (
                programs: [String: [TVEPGProgram]],
                buckets: [String: [(name: String, ids: [String])]]
            ) in
                var sorted = merged
                for key in sorted.keys {
                    sorted[key]?.sort { $0.start < $1.start }
                }
                var buckets: [String: [(name: String, ids: [String])]] = [:]
                for (name, ids) in names where name.count >= 4 {
                    buckets[String(name.prefix(2)), default: []].append((name, ids))
                }
                return (sorted, buckets)
            }.value
            if Task.isCancelled {
                cancelled = true
                return
            }
            self.epgPrograms = prepared.programs
            self.epgChannelNames = names
            self.epgUpdatedAt = Date()
            self.resetEPGCaches()
            self.epgPrefixBuckets = prepared.buckets
            // 补充源失败但主源有数据时不打扰用户；全空才把原因抛出来。
            if merged.isEmpty, let supplementError {
                errors.append("补充节目单：\(supplementError)")
            }
            self.epgError = errors.isEmpty ? nil : errors.joined(separator: "；")
            if merged.isEmpty {
                failureMessage = self.epgError ?? "没有取到节目单"
            } else {
                let programCount = merged.values.reduce(0) { $0 + $1.count }
                successMessage = "\(prepared.programs.count) 个频道 · \(programCount) 条节目"
            }
        })
    }

    /// 节目单换了一份：所有按频道 / 按天的派生缓存一起失效，前缀桶重新建。
    func resetEPGCaches() {
        epgRevision &+= 1
        epgKeyCache.removeAll()
        epgProgramCache.removeAll()
        epgSearchText.removeAll(keepingCapacity: true)
        epgDayCache.removeAll()
        channelsWithProgramsCache.removeAll()
        epgPrefixBuckets.removeAll()
    }

    /// 启用的源各自声明的 XMLTV + 内置补充节目单（去重交给调用方）。
    func epgFeeds() -> [(url: String, label: String, isSupplement: Bool)] {
        var feeds: [(url: String, label: String, isSupplement: Bool)] = []
        for playlist in playlists where playlist.isEnabled {
            let raw = (playlist.epgURLString ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            feeds.append((raw, playlist.name, false))
        }
        feeds.append((TVPlaylist.supplementEPGURLString, "公共补充节目单", true))
        return feeds
    }

    /// 磁盘缓存是否全都还新鲜：只读旁文件时间戳，不解码 JSON、不联网。
    func isEPGCacheFresh(_ feeds: [(url: String, label: String, isSupplement: Bool)]) -> Bool {
        for feed in feeds {
            guard let savedAt = TVEPGService.cachedSavedAt(urlString: feed.url),
                  Date().timeIntervalSince(savedAt) < TVEPGService.cacheMaxAge else { return false }
        }
        return true
    }

    /// 启动 / 首次进入节目单时先把磁盘缓存垫进内存：界面立刻有节目，网络刷新另行排期。
    func hydrateEPGFromCache() {
        guard enabled, epgPrograms.isEmpty, !isHydratingEPG else { return }
        let feeds = epgFeeds()
        isHydratingEPG = true
        tasks.adopt(.tvEPGHydrate, Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) { () -> (
                programs: [String: [TVEPGProgram]],
                names: [String: [String]],
                buckets: [String: [(name: String, ids: [String])]],
                savedAt: Date
            )? in
                var merged: [String: [TVEPGProgram]] = [:]
                var names: [String: [String]] = [:]
                var newest = Date.distantPast
                for feed in feeds {
                    guard let snapshot = TVEPGService.cachedSnapshot(urlString: feed.url) else { continue }
                    Self.absorb(snapshot.data, into: &merged, names: &names)
                    newest = max(newest, snapshot.savedAt)
                }
                guard !merged.isEmpty else { return nil }
                var buckets: [String: [(name: String, ids: [String])]] = [:]
                for (name, ids) in names where name.count >= 4 {
                    buckets[String(name.prefix(2)), default: []].append((name, ids))
                }
                for key in merged.keys {
                    merged[key]?.sort { $0.start < $1.start }
                }
                return (merged, names, buckets, newest)
            }.value
            guard let self else { return }
            self.isHydratingEPG = false
            guard !Task.isCancelled, let prepared else { return }
            // 网络刷新已经写入了更新的数据时，别让旧缓存覆盖。
            if let current = self.epgUpdatedAt, current >= prepared.savedAt { return }
            self.epgPrograms = prepared.programs
            self.epgChannelNames = prepared.names
            self.epgUpdatedAt = prepared.savedAt
            self.resetEPGCaches()
            self.epgPrefixBuckets = prepared.buckets
        })
    }

    /// 按需等待磁盘节目单垫进内存：全局搜索首次直接搜节目时，
    /// 不能只发起垫缓存就立刻检索，否则 `epgPrograms` 还是空的、节目结果必然为 0。
    func ensureEPGFromCache() async {
        guard enabled, epgPrograms.isEmpty else { return }
        hydrateEPGFromCache()
        await tasks.task(.tvEPGHydrate)?.value
    }

    /// 把一份 XMLTV 并进合并结果：节目按频道 id 归堆，台名索引允许多套 EPG id 并存。
    nonisolated static func absorb(_ data: TVEPGData,
                                           into merged: inout [String: [TVEPGProgram]],
                                           names: inout [String: [String]]) {
        for program in data.programs {
            merged[epgKey(program.channelID), default: []].append(program)
        }
        for (id, displayNames) in data.channelNames {
            let key = epgKey(id)
            for name in displayNames {
                let nameKey = epgNameKey(name)
                guard nameKey.count >= 2 else { continue }
                var ids = names[nameKey] ?? []
                if !ids.contains(key) { ids.append(key) }
                names[nameKey] = ids
            }
        }
    }

    func reloadEPG() {
        epgUpdatedAt = nil
        loadEPGIfNeeded(force: true)
    }

    func setEPGURL(_ raw: String?, for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].epgURLString = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persistPlaylists()
        epgUpdatedAt = nil
        loadEPGIfNeeded(force: true)
    }

    func applyEPGURL(_ raw: String?, for playlistID: UUID) {
        guard let raw, !raw.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // 已经设过 EPG（手动填写）就不再被列表头部的境外地址覆盖。
        if !(playlists[index].epgURLString ?? "").isEmpty { return }
        guard playlists[index].epgURLString != raw else { return }
        playlists[index].epgURLString = raw
        persistPlaylists()
    }

    /// 一个频道的节目：多份 EPG（主源 + 补充源）可能各用一套频道 id，
    /// 这里把命中的几套都取出来合并；先命中的来源优先，缺的简介用后面的补。
    /// 两家 EPG 对同一档节目的起止时间常差几分钟，按「时间重叠」去重，
    /// 否则时间轴上会出现两段几乎叠在一起的节目块。
    /// 结果按频道缓存，时间轴 / 传送门 / 时间环高频刷新时不再重复合并排序。
    func programs(for channel: TVChannel) -> [TVEPGProgram] {
        if let cached = epgProgramCache[channel.id] { return cached }
        let keys = epgChannelKeys(for: channel)
        var result: [TVEPGProgram] = []
        if !keys.isEmpty {
            var kept: [TVEPGProgram] = []
            for key in keys {
                for program in epgPrograms[key] ?? [] {
                    // 同一时间只能有一档节目：无论来自主源还是补充源，
                    // 只要有明显重叠就只保留先到的那一档（主源优先），
                    // 顺手补上后到来源里更完整的简介。
                    if let hit = Self.overlappingIndex(of: program, in: kept) {
                        if (kept[hit].overview ?? "").isEmpty, let overview = program.overview {
                            kept[hit].overview = overview
                        }
                        if (kept[hit].subtitle ?? "").isEmpty, let subtitle = program.subtitle {
                            kept[hit].subtitle = subtitle
                        }
                        continue
                    }
                    kept.append(program)
                }
            }
            result = kept.sorted { $0.start < $1.start }
        }
        epgProgramCache[channel.id] = result
        return result
    }

    /// 找出与 `program` 明显重叠的已有节目：重叠部分占较短那档的一半以上就算同一档。
    /// 相邻节目首尾相接（重叠 0 秒）不会误判；只有 EPG 数据把同一档拆成多段时才会命中。
    static func overlappingIndex(of program: TVEPGProgram,
                                        in list: [TVEPGProgram]) -> Int? {
        for (index, other) in list.enumerated() {
            let overlap = min(other.end, program.end)
                .timeIntervalSince(max(other.start, program.start))
            guard overlap >= 30 else { continue }
            let shortest = min(other.duration, program.duration)
            guard shortest > 0, overlap >= shortest * 0.5 else { continue }
            return index
        }
        return nil
    }

    func currentProgram(for channel: TVChannel) -> TVEPGProgram? {
        let now = Date()
        return programs(for: channel).first { $0.start <= now && $0.end > now }
    }

    func nextProgram(for channel: TVChannel) -> TVEPGProgram? {
        let now = Date()
        return programs(for: channel).first { $0.start > now }
    }

    /// 搜索节目单：按节目名 / 副标题模糊匹配，再把命中的节目挂回同一路 EPG 的频道。
    /// 一档节目经常同时出现在多个源的同名台，按「频道 + 节目名 + 开始时间」去重；
    /// 排序以「现在能看的」优先：正在播 → 即将开播 → 已播（越近越靠前）。
    /// `limit == 0` 表示不限制条数。
    func searchPrograms(keyword: String, limit: Int = 40)
        -> [(channel: TVChannel, program: TVEPGProgram)] {
        let raw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, limit >= 0, !raw.isEmpty, !epgPrograms.isEmpty else { return [] }
        let normalizedQuery = SearchFuzzyText.normalize(raw)
        guard !normalizedQuery.isEmpty else { return [] }
        // 归一化后的「节目名 + 副标题」按 EPG 版本缓存：搜索框每变一次都要扫全量节目单，
        // 不能每次都重新折叠一遍中文。
        if epgSearchTextRevision != epgRevision {
            epgSearchText.removeAll(keepingCapacity: true)
            epgSearchTextRevision = epgRevision
        }
        func isMatch(_ program: TVEPGProgram) -> Bool {
            let text: String
            if let cached = epgSearchText[program.id] {
                text = cached
            } else {
                text = SearchFuzzyText.normalize(
                    [program.title, program.subtitle ?? ""].joined(separator: " "))
                epgSearchText[program.id] = text
            }
            guard !text.isEmpty else { return false }
            if text.contains(normalizedQuery) { return true }
            // 反向包含只对至少 2 个字的节目名生效，避免短词吃掉整份节目单。
            return text.count >= 2 && normalizedQuery.contains(text)
        }
        // EPG 频道 id -> 同名的频道（不同源可能各有一路）。
        var channelIndex: [String: [TVChannel]] = [:]
        for channel in channels {
            for key in epgChannelKeys(for: channel) {
                channelIndex[key, default: []].append(channel)
            }
        }
        guard !channelIndex.isEmpty else { return [] }
        let unlimited = limit == 0
        let capacity = unlimited ? Int.max : max(limit * 4, 40)
        var seen: Set<String> = []
        var found: [(channel: TVChannel, program: TVEPGProgram)] = []
        for (key, programs) in epgPrograms {
            guard let matchedChannels = channelIndex[key] else { continue }
            for program in programs where isMatch(program) {
                for channel in matchedChannels {
                    let signature = "\(channel.id)|\(program.title)|\(Int(program.start.timeIntervalSince1970))"
                    guard seen.insert(signature).inserted else { continue }
                    found.append((channel, program))
                }
                if found.count >= capacity { break }
            }
            if found.count >= capacity { break }
        }
        let now = Date()
        func rank(_ program: TVEPGProgram) -> (Int, TimeInterval) {
            if program.start <= now && program.end > now { return (0, 0) }
            if program.start > now { return (1, program.start.timeIntervalSince(now)) }
            return (2, now.timeIntervalSince(program.end))
        }
        let sorted = found.sorted { left, right in
            let a = rank(left.program)
            let b = rank(right.program)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return left.channel.name.localizedStandardCompare(right.channel.name) == .orderedAscending
        }
        // limit == 0 表示不限制条数，不能直接 prefix(0) 把结果全裁掉。
        return unlimited ? sorted : Array(sorted.prefix(limit))
    }

    /// 某一天内某个频道的全部节目：节目单时间轴与回看双栏共用。按天缓存。
    func programs(on date: Date, for channel: TVChannel) -> [TVEPGProgram] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let key = "\(channel.id)#\(Int(start.timeIntervalSince1970))"
        if let cached = epgDayCache[key] { return cached }
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        // programs(for:) 已经按时间升序，过滤后无需再排。
        let result = programs(for: channel).filter { $0.start < end && $0.end > start }
        epgDayCache[key] = result
        return result
    }

    /// 某个日期有节目单的频道：节目单页的左侧频道栏与「可回看频道」都用它，
    /// 结果按「可见频道集合 + 日期」缓存，切换视图 / 悬停时不再重算。
    func channelsWithPrograms(on date: Date) -> [TVChannel] {
        let list = visibleChannels
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        let key = "\(visibleCacheKey)|\(day)"
        if let cached = channelsWithProgramsCache[key] { return cached }
        let result = list.filter { !programs(on: date, for: $0).isEmpty }
        if channelsWithProgramsCache.count >= 8 {
            channelsWithProgramsCache.removeAll(keepingCapacity: true)
        }
        channelsWithProgramsCache[key] = result
        return result
    }

    /// 某一天内、已经结束、且源支持回看的节目。
    func catchupPrograms(on date: Date) -> [(channel: TVChannel, program: TVEPGProgram)] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let now = Date()
        let limit = dayEnd > now ? now : dayEnd

        var result: [(TVChannel, TVEPGProgram)] = []
        for channel in visibleChannels {
            guard let source = channel.catchUpSource, !source.isEmpty else { continue }
            let earliest = now.addingTimeInterval(-Double(channel.effectiveCatchUpDays) * 86_400)
            for program in programs(for: channel)
            where program.start >= dayStart && program.start < dayEnd
                && program.end <= limit && program.start >= earliest {
                result.append((channel, program))
            }
        }
        return result
            .sorted { $0.1.start < $1.1.start }
            .map { (channel: $0.0, program: $0.1) }
    }

    var catchupChannelCount: Int {
        visibleChannels.filter {
            !($0.catchUpSource ?? "").isEmpty
        }.count
    }

    /// 频道在 EPG 里的所有可能 id，按优先级排列：tvg-id → 完全同名 → 前缀同名。
    /// 每个频道只算一次，结果缓存到下一份 EPG。
    func epgChannelKeys(for channel: TVChannel) -> [String] {
        if let cached = epgKeyCache[channel.id] { return cached }
        let keys = computeEPGChannelKeys(for: channel)
        epgKeyCache[channel.id] = keys
        return keys
    }

    func computeEPGChannelKeys(for channel: TVChannel) -> [String] {
        var keys: [String] = []
        func add(_ key: String) {
            guard epgPrograms[key] != nil, !keys.contains(key) else { return }
            keys.append(key)
        }
        if let tvgID = channel.tvgID {
            add(Self.epgKey(tvgID))
        }
        let nameKey = Self.epgNameKey(channel.name)
        guard nameKey.count >= 2 else { return keys }
        for id in epgChannelNames[nameKey] ?? [] {
            add(id)
        }
        // 没有精确同名时做一次保守的前缀匹配；至少 4 个字符，且前缀后不能紧跟数字，
        // 否则 CCTV1 会误配到 CCTV10 / CCTV11。只扫同首 2 字的桶。
        guard nameKey.count >= 4 else { return keys }
        let bucket = epgPrefixBuckets[String(nameKey.prefix(2))] ?? []
        for (name, ids) in bucket where name.count >= 4 {
            guard Self.isSafePrefix(name, of: nameKey) || Self.isSafePrefix(nameKey, of: name) else {
                continue
            }
            for id in ids { add(id) }
        }
        return keys
    }

    /// `short` 是否是 `long` 的前缀，且后面紧跟的是中文而不是字母 / 数字。
    /// 只允许「CCTV1 → CCTV1综合」这种同一台的补全；`CCTV4` 与 `CCTV4K`、
    /// `CCTV5` 与 `CCTV5PLUS` 是不同频道，不能互相吃排期。
    static func isSafePrefix(_ short: String, of long: String) -> Bool {
        guard long.count > short.count, long.hasPrefix(short) else { return false }
        let next = long[long.index(long.startIndex, offsetBy: short.count)]
        return !next.isASCII
    }

    nonisolated static func epgKey(_ raw: String) -> String {
        var base = raw.split(separator: "@").first.map(String.init) ?? raw
        // iptv-org 的 tvg-id 形如 `CCTV1.cn`：去掉两位国家 / 语言后缀，
        // 才能对上 XMLTV 里常见的 `CCTV1`。
        if let dot = base.lastIndex(of: "."), dot < base.endIndex {
            let suffix = base[base.index(after: dot)...]
            if suffix.count == 2, suffix.allSatisfy({ $0.isLetter }) {
                base = String(base[..<dot])
            }
        }
        return base.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    nonisolated static func epgNameKey(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
