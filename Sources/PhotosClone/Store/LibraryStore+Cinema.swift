import Foundation
import AppKit
import Combine

/// 下一集预热好的边下边播流：首段已生成、ffmpeg 处于挂起状态。
/// 切换过去时直接复用播放列表，省掉解析直链、ffprobe 与首段等待。
struct CinemaPrewarmedStream {
    let photoID: UUID
    let playlistURL: URL
    let sourceURL: URL
    let headers: [String: String]
    /// 条目里记录的时长：网盘元数据不一定带 duration，接管时用它撑起进度条。
    let duration: Double
    /// 预热前探测到的画面尺寸 / 编码：接管时直接复用，不再重新探测。
    let videoSize: CGSize
    let isHEVC: Bool
    /// 探测到的音轨结构：接管后菜单能显示语言 / 声道，也用于对上多音轨缓存。
    let audioTracks: [AudioTrackInfo]
    let session: VideoStreamSession
    let createdAt: Date
}

/// 自动归组的合集：同一个 TMDB belongs_to_collection。
struct CinemaCollectionGroup: Identifiable {
    let id: Int
    let name: String
    let entries: [CinemaEntry]
}

/// 海报墙的字母索引：每个首字母指向第一条内容，点击滚过去。
struct CinemaLetterEntry: Identifiable {
    let letter: String
    let target: String
    var id: String { letter }
}

/// 海报墙统计：规格分布与已看数量。
struct CinemaAggregateStats {
    var matched = 0
    var uhd = 0
    var hd = 0
    var sd = 0
    var watched = 0
}

/// 影院派生数据快照：一次遍历产出所有列表，页面里反复读取不再重复聚合。
struct CinemaAggregate {
    var allEntries: [CinemaEntry] = []
    var entries: [CinemaEntry] = []
    var unmatched: [CinemaEntry] = []
    var movies: [CinemaEntry] = []
    var series: [CinemaSeries] = []
    var unmatchedSeries: [CinemaSeries] = []
    var unmatchedMovies: [CinemaEntry] = []
    var collections: [CinemaCollectionGroup] = []
    var letters: [CinemaLetterEntry] = []
    /// 版本键 → 同版本文件数：卡片上的「N 版本」不再逐张全量扫描索引。
    var versionCounts: [String: Int] = [:]
    var stats = CinemaAggregateStats()
    var favoriteCount = 0
    var recentCount = 0
    var highRatedCount = 0
    var wallItemCount = 0
}

// MARK: - 影院刮削与播放

extension LibraryStore {
    /// 本地图库的刮削结果沿用旧 key，网盘各自一份。
    static let cinemaIndexSettingKey = "cinema_index"
    /// 影院续播记录：与刮削索引分开存，避免清空索引时连带丢掉观看进度。
    static let cinemaProgressSettingKey = "cinema_progress"
    /// 影院用户状态与自定义清单。
    static let cinemaUserStateSettingKey = "cinema_user_state"
    static let cinemaListsSettingKey = "cinema_lists"
    /// 刮削 / 维护任务记录。
    static let cinemaTasksSettingKey = "cinema_tasks"
    /// 剧集级跳过片头 / 片尾设置。
    static let cinemaIntroSettingKey = "cinema_intro_marks"
    static let cinemaEpisodeIntroSettingKey = "cinema_intro_episode_marks"
    /// 通知中心归档（今天 / 本周，保留 30 天）。
    static let cinemaNotificationsSettingKey = "cinema_notifications"

    static func cinemaSettingKey(for scope: CinemaScope) -> String {
        switch scope {
        case .local:
            return cinemaIndexSettingKey
        case .mount(let id):
            return "cinema_index_\(id.uuidString)"
        }
    }

    /// 已忽略的视频清单：按作用域单独保存，不混进刮削索引。
    static func cinemaIgnoredSettingKey(for scope: CinemaScope) -> String {
        switch scope {
        case .local:
            return "cinema_ignored_local"
        case .mount(let id):
            return "cinema_ignored_\(id.uuidString)"
        }
    }

    // MARK: 读写

    /// 当前查看作用域的条目（已排除手动忽略的视频）。
    var cinemaEntries: [UUID: CinemaEntry] {
        cinemaEntries(for: cinemaActiveScope)
    }

    func cinemaEntries(for scope: CinemaScope) -> [UUID: CinemaEntry] {
        guard let entries = cinemaIndexes[scope] else { return [:] }
        let ignored = cinemaIgnoredIDs[scope] ?? []
        guard !ignored.isEmpty else { return entries }
        return entries.filter { !ignored.contains($0.key) }
    }

    func cinemaMatchedCount(for scope: CinemaScope) -> Int {
        (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
    }

    /// 启动时把本地与每个网盘的结果都读进内存，网格缩略图随时能拿到海报。
    func loadCinemaIndexes() {
        guard let metadataStore else { return }
        var loaded: [CinemaScope: [UUID: CinemaEntry]] = [:]
        let scopes: [CinemaScope] = [.local] + cloudMounts.map { .mount($0.id) }
        for scope in scopes {
            let key = Self.cinemaSettingKey(for: scope)
            guard let json = metadataStore.setting(key),
                  let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([CinemaEntry].self, from: data) else { continue }
            loaded[scope] = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
        cinemaIndexes = loaded
        var ignored: [CinemaScope: Set<UUID>] = [:]
        for scope in scopes {
            guard let json = metadataStore.setting(Self.cinemaIgnoredSettingKey(for: scope)),
                  let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([UUID].self, from: data) else { continue }
            ignored[scope] = Set(ids)
        }
        cinemaIgnoredIDs = ignored
        loadCinemaProgress()
        loadCinemaUserState()
        loadCinemaTasks()
        loadCinemaIntroMarks()
        loadCinemaNotifications()
    }

    // MARK: 跳过片头 / 片尾

    func loadCinemaIntroMarks() {
        guard let metadataStore else { return }
        if let json = metadataStore.setting(Self.cinemaIntroSettingKey),
           let data = json.data(using: .utf8),
           let marks = try? JSONDecoder().decode([String: CinemaIntroMark].self, from: data) {
            cinemaIntroMarks = marks
        }
        if let json = metadataStore.setting(Self.cinemaEpisodeIntroSettingKey),
           let data = json.data(using: .utf8),
           let marks = try? JSONDecoder().decode([String: CinemaIntroMark].self, from: data) {
            cinemaEpisodeIntroMarks = marks
        }
    }

    func cinemaIntroMark(forSeriesKey key: String) -> CinemaIntroMark {
        cinemaIntroMarks[key] ?? CinemaIntroMark()
    }

    /// 单集设置优先；没有单独设置时沿用整部剧的默认值。
    func cinemaIntroMark(for entry: CinemaEntry) -> CinemaIntroMark {
        cinemaEpisodeIntroMarks[entry.id.uuidString]
            ?? cinemaIntroMark(forSeriesKey: cinemaSeriesKey(for: entry))
    }

    func hasCinemaEpisodeIntroMark(for entry: CinemaEntry) -> Bool {
        cinemaEpisodeIntroMarks[entry.id.uuidString] != nil
    }

    func setCinemaIntroMark(_ mark: CinemaIntroMark, forSeriesKey key: String) {
        if mark.isEnabled {
            cinemaIntroMarks[key] = mark
        } else {
            cinemaIntroMarks.removeValue(forKey: key)
        }
        persistCinemaIntroMarks()
    }

    func setCinemaIntroMark(_ mark: CinemaIntroMark, for entry: CinemaEntry) {
        if mark.isEnabled {
            cinemaEpisodeIntroMarks[entry.id.uuidString] = mark
        } else {
            cinemaEpisodeIntroMarks.removeValue(forKey: entry.id.uuidString)
        }
        persistCinemaIntroMarks()
    }

    /// 清除本集覆盖，回落到整部剧的默认设置。
    func clearCinemaEpisodeIntroMark(for entry: CinemaEntry) {
        guard cinemaEpisodeIntroMarks.removeValue(forKey: entry.id.uuidString) != nil else { return }
        persistCinemaIntroMarks()
    }

    private func persistCinemaIntroMarks() {
        guard let metadataStore else { return }
        if let data = try? JSONEncoder().encode(cinemaIntroMarks),
           let json = String(data: data, encoding: .utf8) {
            metadataStore.setSetting(Self.cinemaIntroSettingKey, json)
        }
        if let data = try? JSONEncoder().encode(cinemaEpisodeIntroMarks),
           let json = String(data: data, encoding: .utf8) {
            metadataStore.setSetting(Self.cinemaEpisodeIntroSettingKey, json)
        }
    }

    /// 播放器需要和详情页用同一个 key 找到这部剧的跳过设置。
    func cinemaSeriesKey(for entry: CinemaEntry) -> String {
        seriesKey(entry)
    }

    // MARK: 续播记录

    func loadCinemaProgress() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaProgressSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaProgressRecord].self, from: data) else { return }
        let loaded = Dictionary(uniqueKeysWithValues: list.map { ($0.photoID, $0) })
        // 旧版本起流点换算错误会把时间轴放大 1000 倍：丢掉这类脏记录，避免「继续观看」
        // 显示已看完、点续播直接落到片尾。
        let cleaned = loaded.filter { _, record in
            record.isTrustworthy(realDuration: cinemaEntryDuration(for: record.photoID))
        }
        cinemaProgress = cleaned
        if cleaned.count != loaded.count { persistCinemaProgress() }
    }

    /// 条目元数据里的片源时长，用于校验续播记录是否合理。
    func cinemaEntryDuration(for photoID: UUID) -> Double? {
        for entries in cinemaIndexes.values {
            if let duration = entries[photoID]?.file.duration, duration > 0 { return duration }
        }
        return nil
    }

    func persistCinemaProgress() {
        guard let metadataStore else { return }
        // 只保留最近 500 条，避免长期使用后无限增长。
        if cinemaProgress.count > 500 {
            let kept = cinemaProgress.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(500)
            cinemaProgress = Dictionary(uniqueKeysWithValues: kept.map { ($0.photoID, $0) })
        }
        guard let data = try? JSONEncoder().encode(Array(cinemaProgress.values)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaProgressSettingKey, json)
    }

    /// 当前作用域内可以继续观看的记录：未看完、有实际进度，按最近观看排序。
    func cinemaContinueRecords(for scope: CinemaScope) -> [CinemaProgressRecord] {
        let mountID: UUID?
        if case .mount(let id) = scope {
            mountID = id
        } else {
            mountID = nil
        }
        return cinemaProgress.values
            .filter {
                $0.mountID == mountID
                    && !$0.isFinished
                    && $0.position > 3
                    && $0.duration > 0
                    && !(cinemaIndexes[scope]?[$0.photoID].map { cinemaIsRestricted($0) } ?? false)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func cinemaContinueRecord(for scope: CinemaScope) -> CinemaProgressRecord? {
        cinemaContinueRecords(for: scope).first
    }

    // MARK: 收藏 / 想看 / 评分 / 清单

    func loadCinemaUserState() {
        guard let metadataStore else { return }
        if let json = metadataStore.setting(Self.cinemaUserStateSettingKey),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([CinemaUserState].self, from: data) {
            cinemaUserStates = Dictionary(uniqueKeysWithValues: list.map { ($0.photoID, $0) })
        }
        if let json = metadataStore.setting(Self.cinemaListsSettingKey),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([CinemaListRecord].self, from: data) {
            cinemaLists = list
        }
        if let id = cinemaActiveListID, !cinemaLists.contains(where: { $0.id == id }) {
            cinemaActiveListID = nil
        }
    }

    func persistCinemaUserState() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(Array(cinemaUserStates.values)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaUserStateSettingKey, json)
    }

    func persistCinemaLists() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(cinemaLists),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaListsSettingKey, json)
    }

    func cinemaUserState(for id: UUID) -> CinemaUserState {
        cinemaUserStates[id] ?? CinemaUserState(photoID: id)
    }

    func toggleCinemaFavorite(_ id: UUID) {
        var state = cinemaUserState(for: id)
        state.favorite.toggle()
        state.updatedAt = Date()
        cinemaUserStates[id] = state
        persistCinemaUserState()
        let title = cinemaEntry(for: id)?.title
        postCinemaToast(.success,
                        title: state.favorite ? "已加入收藏" : "已取消收藏",
                        detail: title,
                        actionTitle: "撤销") { [weak self] in
            self?.toggleCinemaFavorite(id)
        }
    }

    func toggleCinemaWatchlist(_ id: UUID) {
        var state = cinemaUserState(for: id)
        state.watchlist.toggle()
        state.updatedAt = Date()
        cinemaUserStates[id] = state
        persistCinemaUserState()
        postCinemaToast(.success,
                        title: state.watchlist ? "已加入想看" : "已移出想看",
                        detail: cinemaEntry(for: id)?.title,
                        actionTitle: "撤销") { [weak self] in
            self?.toggleCinemaWatchlist(id)
        }
    }

    func setCinemaRating(_ rating: Int?, for id: UUID) {
        var state = cinemaUserState(for: id)
        state.rating = rating.map { min(5, max(1, $0)) }
        state.updatedAt = Date()
        cinemaUserStates[id] = state
        persistCinemaUserState()
    }

    @discardableResult
    func createCinemaList(named name: String) -> CinemaListRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CinemaListRecord(name: trimmed.isEmpty ? "未命名清单" : trimmed)
        cinemaLists.append(record)
        persistCinemaLists()
        return record
    }

    func deleteCinemaList(_ id: UUID) {
        cinemaLists.removeAll { $0.id == id }
        if cinemaActiveListID == id { cinemaActiveListID = nil }
        persistCinemaLists()
    }

    func addToCinemaList(_ listID: UUID, entryID: UUID) {
        guard let index = cinemaLists.firstIndex(where: { $0.id == listID }) else { return }
        if !cinemaLists[index].itemIDs.contains(entryID) {
            cinemaLists[index].itemIDs.append(entryID)
            persistCinemaLists()
            showToast("已加入「\(cinemaLists[index].name)」")
        }
    }

    func removeFromCinemaList(_ listID: UUID, entryID: UUID) {
        guard let index = cinemaLists.firstIndex(where: { $0.id == listID }) else { return }
        cinemaLists[index].itemIDs.removeAll { $0 == entryID }
        persistCinemaLists()
    }

    func cinemaList(_ id: UUID?) -> CinemaListRecord? {
        guard let id else { return nil }
        return cinemaLists.first { $0.id == id }
    }

    func cinemaListsContaining(_ entryID: UUID) -> [CinemaListRecord] {
        cinemaLists.filter { $0.itemIDs.contains(entryID) }
    }

    /// 清空观看记录：继续观看、观看历史与详情进度一并消失，不删影片。
    func clearCinemaProgress() {
        cinemaProgress = [:]
        persistCinemaProgress()
        showToast("已清除观看记录")
    }

    /// 清空自定义清单：只删清单引用，不删影片与收藏状态。
    func clearCinemaLists() {
        cinemaLists = []
        cinemaActiveListID = nil
        persistCinemaLists()
        showToast("已清除自定义清单")
    }

    func saveCinemaProgress(position: Double,
                                    duration: Double,
                                    entry: CinemaEntry) {
        let subtitle = entry.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        cinemaProgress[entry.id] = CinemaProgressRecord(
            photoID: entry.id,
            mountID: entry.file.cloudMountID,
            title: entry.title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            artworkURL: entry.gridArtworkURL,
            position: position,
            duration: duration,
            updatedAt: Date()
        )
        persistCinemaProgress()
    }

    /// 关闭查看器或切换到其他视频前落盘。
    func finishCinemaPlayback() {
        if let entry = cinemaPlaybackEntry, viewerID == entry.file.photoID {
            let current = viewerModel.videoPlayer.currentTime
            let duration = viewerModel.videoPlayer.duration
            if duration > 0, current > 3 {
                saveCinemaProgress(position: current, duration: duration, entry: entry)
            }
        }
        cinemaPlaybackEntry = nil
        viewerModel.videoPlaybackUI.subtitleQuery = nil
    }

    // MARK: 下一集预热

    /// 快看完时预热下一集：只预生成首段，ffmpeg 随后挂起。
    /// 切集时直接复用播放列表，跳过解析直链、探测与首段等待。
    func prewarmCinemaNextEpisode(after entry: CinemaEntry) {
        guard entry.kind == .tv,
              let next = cinemaNextEpisode(after: entry) else { return }
        // 原生容器直接播就很快，没必要绕 ffmpeg。
        let ext = (next.file.filename as NSString).pathExtension.lowercased()
        guard !["mp4", "mov", "m4v", "m4a"].contains(ext) else { return }
        if cinemaPrewarmedStream?.photoID == next.id { return }
        // 同一个目标已经试过（成功或失败）：进度回调频率很高，不能每次都重来。
        if cinemaPrewarmTarget == next.id { return }

        cinemaPrewarmTask?.cancel()
        discardPrewarmedCinemaStream()
        cinemaPrewarmTarget = next.id
        let photo = anyPhoto(id: next.file.photoID) ?? next.file.photoItem
        let trailer = next.subtitle
        cinemaPrewarmTask = Task { [weak self] in
            guard let self else { return }
            let source: URL
            var headers: [String: String] = [:]
            if photo.isCloud {
                guard let stream = try? await self.cloudStreamOrThrow(for: photo) else { return }
                source = stream.url
                headers = stream.headers
            } else {
                source = LibraryPaths.sourceURL(for: photo)
                guard FileManager.default.fileExists(atPath: source.path) else { return }
            }
            guard !Task.isCancelled else { return }

            // 预热前探测一次：既要拿到音轨结构去对上多音轨缓存，也要识别
            // HDR / 杜比视界 / 隔行源——它们的真实播放路径是转码或色调映射，
            // 预先转出的 SDR remux 会颜色发灰 / 有梳齿，宁可不预热。
            var options: [String: Any] = [:]
            if !headers.isEmpty { options[CloudPlayback.headerFieldsKey] = headers }
            let probe = await VideoSupport.probe(url: source, options: options)
            guard !Task.isCancelled else { return }
            guard probe.hasVideoTrack || probe.duration > 0 else {
                Diagnostics.record("预热跳过 \(trailer)：探测不到流信息")
                return
            }
            if probe.isHDR || probe.isDolbyVision || probe.color.isHDR || probe.isInterlaced {
                Diagnostics.record("预热跳过 \(trailer)：HDR / 隔行源需要按播放策略转码")
                return
            }

            let filename = next.file.filename.lowercased()
            let isHEVC = probe.isHEVC
                || next.file.videoCodec?.lowercased() == "hevc"
                || filename.contains("hevc") || filename.contains("x265")
            let size = probe.size.width > 0 && probe.size.height > 0
                ? probe.size
                : CGSize(width: next.file.pixelWidth, height: next.file.pixelHeight)
            // 带上完整音轨结构：预热会话才能和已有多音轨缓存对上，切集直接命中。
            let audioTracks = probe.audioTracks
            let session = VideoStreamSession(
                environment: .luma,
                photoID: next.id,
                source: source,
                headers: headers,
                trustSelfSigned: self.cloudMount(for: next.file.cloudMountID)?.trustSelfSigned ?? false,
                mode: .remux,
                startOffset: 0,
                isHEVC: isHEVC,
                isHDR: false,
                color: probe.color,
                sourceSize: size,
                frameRate: probe.frameRate,
                audioIndex: 0,
                audioChannels: audioTracks.first?.channels ?? 2,
                audioCodec: audioTracks.first?.codec,
                audioTracks: audioTracks,
                audioDownmix: AppSettings.shared.audioDownmix,
                cacheSignature: VideoStreamSession.lumaCacheSignature,
                // 预热会话不写长期缓存；命中现有缓存时只借用播放列表。
                allowsCachePersistence: false,
                refreshSource: self.cinemaCloudRefreshClosure(for: photo))
            do {
                let playlist = try await Task.detached(priority: .utility) {
                    try await session.start()
                }.value
                guard !Task.isCancelled else {
                    session.stop()
                    return
                }
                // 用户已经切到这一集时，正常播放会话已经接手；预热流直接丢掉，
                // 不能再挂回去，否则同一集会同时跑两个 ffmpeg。
                if self.cinemaPlaybackEntry?.file.photoID == next.id {
                    session.stop()
                    return
                }
                // 首段就绪后挂起，避免预热把整集都转成临时分片。
                session.setGenerationActive(false)
                self.cinemaPrewarmedStream = CinemaPrewarmedStream(photoID: next.id,
                                                                  playlistURL: playlist,
                                                                  sourceURL: source,
                                                                  headers: headers,
                                                                  duration: next.file.duration ?? 0,
                                                                  videoSize: size,
                                                                  isHEVC: isHEVC,
                                                                  audioTracks: audioTracks,
                                                                  session: session,
                                                                  createdAt: Date())
                Diagnostics.record("预热下一集 \(trailer) 首段就绪")
            } catch {
                session.stop()
                Diagnostics.record("预热下一集失败 \(trailer)：\(error.localizedDescription)")
            }
        }
    }

    /// 切集时取走预热流；超过 20 分钟视为直链可能过期，直接丢弃。
    func takePrewarmedCinemaStream(for photoID: UUID) -> CinemaPrewarmedStream? {
        guard let warm = cinemaPrewarmedStream, warm.photoID == photoID else { return nil }
        cinemaPrewarmedStream = nil
        cinemaPrewarmTask = nil
        cinemaPrewarmTarget = nil
        guard Date().timeIntervalSince(warm.createdAt) < 20 * 60 else {
            warm.session.stop()
            return nil
        }
        return warm
    }

    func discardPrewarmedCinemaStream() {
        cinemaPrewarmTask?.cancel()
        cinemaPrewarmTask = nil
        cinemaPrewarmTarget = nil
        guard let warm = cinemaPrewarmedStream else { return }
        cinemaPrewarmedStream = nil
        warm.session.stop()
    }

    private func cinemaNextEpisode(after entry: CinemaEntry) -> CinemaEntry? {
        let key = cinemaSeriesKey(for: entry)
        let current = (entry.season ?? 0, entry.episode ?? 0)
        var candidates: [CinemaEntry] = []
        for index in cinemaIndexes.values {
            candidates += index.values.filter { $0.kind == .tv && cinemaSeriesKey(for: $0) == key }
        }
        let ordered = candidates.sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
        var seen = Set<String>()
        for candidate in ordered {
            let position = (candidate.season ?? 0, candidate.episode ?? 0)
            guard position > current else { continue }
            let marker = "\(position.0)-\(position.1)"
            if seen.insert(marker).inserted { return candidate }
        }
        return nil
    }

    /// 预热流运行在后台，直链过期时需要重新解析（与播放页同一套逻辑）。
    private func cinemaCloudRefreshClosure(for photo: PhotoItem) -> (() -> (URL, [String: String])?)? {
        guard photo.isCloud else { return nil }
        return { [weak self] in
            guard let self, !Thread.isMainThread else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            var result: (URL, [String: String])?
            Task { @MainActor in
                if let stream = try? await self.cloudStreamOrThrow(for: photo) {
                    result = (stream.url, stream.headers)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 20)
            return result
        }
    }

    /// 旧版本把所有网盘的条目混在一个 key 里：按 `cloudMountID` 拆回各自作用域。
    func migrateLegacyCinemaIndexIfNeeded() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaIndexSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaEntry].self, from: data),
              list.contains(where: { $0.file.cloudMountID != nil }) else { return }

        var split: [CinemaScope: [UUID: CinemaEntry]] = [:]
        for entry in list {
            let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
            split[scope, default: [:]][entry.id] = entry
        }
        for (scope, entries) in split {
            // 已经有新数据的网盘不覆盖。
            if scope != .local, let existing = cinemaIndexes[scope], !existing.isEmpty { continue }
            cinemaIndexes[scope] = entries
            persistCinemaIndex(for: scope)
        }
    }

    func persistCinemaIndex(for scope: CinemaScope) {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(Array((cinemaIndexes[scope] ?? [:]).values)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaSettingKey(for: scope), json)
    }

    func clearCinemaIndex(for scope: CinemaScope) {
        cinemaIndexes[scope] = [:]
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        cinemaScrapeMessage = "已清除这个影院的刮削结果"
    }

    /// 清空影院筛选（不改作用域，也不清数据）。
    func resetCinemaFilters() {
        cinemaDecades = []
        cinemaGenres = []
        cinemaResolutions = []
        cinemaWatchFilters = []
        cinemaSpecFilters = []
        cinemaSmartHighRated = false
        cinemaSmartRecent = false
        cinemaFavoritesOnly = false
        cinemaActiveListID = nil
    }

    func activateCinemaScope(_ scope: CinemaScope) {
        if cinemaActiveScope != scope {
            cinemaScrapeMessage = nil
            // 换了影院就回到「全部年代 / 全部类型」，避免筛选条件在另一个库里把人筛空。
            cinemaDecades = []
            cinemaGenres = []
            cinemaResolutions = []
            cinemaWatchFilters = []
            cinemaSpecFilters = []
            cinemaSmartHighRated = false
            cinemaSmartRecent = false
            cinemaFavoritesOnly = false
            cinemaActiveListID = nil
        }
        cinemaActiveScope = scope
        // 进入某个网盘影院时顺手校验索引新鲜度：超过 60 秒就做一次增量扫描，
        // 新加入的视频会先进入索引，刮削与「未识别」列表读到的就是最新清单。
        if case .mount(let mountID) = scope {
            ensureCloudIndexFresh(for: mountID)
        }
    }

    // MARK: 观看状态

    /// 单条的观看状态：没有进度=未看；有进度未到 95%=进行中；到 95%=已看完。
    func cinemaWatchState(for entry: CinemaEntry) -> CinemaWatchFilter {
        guard let record = cinemaProgress[entry.id], record.fraction > 0.01 else {
            return .unwatched
        }
        return record.isFinished ? .finished : .inProgress
    }

    /// 剧集取聚合状态：全部看完=已看完；任意进度或部分看完=进行中；否则未看。
    func cinemaWatchState(for series: CinemaSeries) -> CinemaWatchFilter {
        let states = series.episodes.map { cinemaWatchState(for: $0) }
        guard !states.isEmpty else { return .unwatched }
        if states.allSatisfy({ $0 == .finished }) { return .finished }
        if states.contains(where: { $0 != .unwatched }) { return .inProgress }
        return .unwatched
    }

    func cinemaEntry(for id: UUID) -> CinemaEntry? {
        cinemaEntries[id]
    }

    // MARK: 筛选

    /// 影院筛选的单一判定：年代 / 类型 / 分辨率 / 观看状态可多选，组内 OR、组间 AND。
    func cinemaPassesFilters(_ entry: CinemaEntry) -> Bool {
        guard entry.matched else { return false }
        if cinemaIsRestricted(entry) { return false }
        if !cinemaDecades.isEmpty,
           !(entry.decade.map { cinemaDecades.contains($0) } ?? false) { return false }
        if !cinemaGenres.isEmpty,
           Set(entry.genres ?? []).isDisjoint(with: cinemaGenres) { return false }
        if !cinemaResolutions.isEmpty,
           !cinemaResolutions.contains(where: { $0.matches(entry.file) }) { return false }
        if !cinemaSpecFilters.isEmpty,
           !cinemaSpecFilters.contains(where: { $0.matches(entry.file) }) { return false }
        if !cinemaWatchFilters.isEmpty,
           !cinemaWatchFilters.contains(cinemaWatchState(for: entry)) { return false }
        if cinemaSmartHighRated, (entry.rating ?? 0) < 8 { return false }
        if cinemaSmartRecent, entry.file.capturedAt < Date().addingTimeInterval(-30 * 86400) {
            return false
        }
        if cinemaFavoritesOnly, !cinemaUserState(for: entry.id).favorite { return false }
        if let list = cinemaList(cinemaActiveListID), !list.itemIDs.contains(entry.id) {
            return false
        }
        return true
    }

    func cinemaPassesFilters(_ series: CinemaSeries) -> Bool {
        if !series.episodes.contains(where: { !cinemaIsRestricted($0) }) { return false }
        if !cinemaDecades.isEmpty,
           !series.episodes.contains(where: { $0.decade.map { cinemaDecades.contains($0) } ?? false }) {
            return false
        }
        if !cinemaGenres.isEmpty,
           !series.episodes.contains(where: { !Set($0.genres ?? []).isDisjoint(with: cinemaGenres) }) {
            return false
        }
        if !cinemaResolutions.isEmpty,
           !series.episodes.contains(where: { episode in
               cinemaResolutions.contains { $0.matches(episode.file) }
           }) {
            return false
        }
        if !cinemaSpecFilters.isEmpty,
           !series.episodes.contains(where: { episode in
               cinemaSpecFilters.contains { $0.matches(episode.file) }
           }) {
            return false
        }
        if !cinemaWatchFilters.isEmpty,
           !cinemaWatchFilters.contains(cinemaWatchState(for: series)) { return false }
        if cinemaSmartHighRated, (series.rating ?? 0) < 8 { return false }
        if cinemaSmartRecent {
            let latest = series.episodes.map(\.file.capturedAt).max() ?? .distantPast
            if latest < Date().addingTimeInterval(-30 * 86400) { return false }
        }
        if cinemaFavoritesOnly,
           !series.episodes.contains(where: { cinemaUserState(for: $0.id).favorite }) {
            return false
        }
        if let list = cinemaList(cinemaActiveListID),
           !series.episodes.contains(where: { list.itemIDs.contains($0.id) }) {
            return false
        }
        return true
    }

    var cinemaScrapeProgress: Double {
        guard cinemaScrapeTotal > 0 else { return 0 }
        return min(1, Double(cinemaScrapeDone) / Double(cinemaScrapeTotal))
    }

    /// 网格里的视频优先显示刮削背景图：按视频所属网盘取对应作用域的条目。
    func cinemaGridArtwork(for photo: PhotoItem) -> String? {
        guard photo.isVideo else { return nil }
        if let mountID = photo.cloudMountID {
            return cinemaIndexes[.mount(mountID)]?[photo.id]?.gridArtworkURL
        }
        return cinemaIndexes[.local]?[photo.id]?.gridArtworkURL
    }

    // MARK: 聚合

    var cinemaMatchedEntries: [CinemaEntry] {
        cinemaEntries.values
            .filter { $0.matched }
            .sorted { $0.file.capturedAt > $1.file.capturedAt }
    }

    var cinemaMovies: [CinemaEntry] {
        cinemaMatchedEntries.filter { $0.kind == .movie }
    }

    var cinemaTVEpisodes: [CinemaEntry] {
        cinemaMatchedEntries.filter { $0.kind == .tv }
    }

    /// 当前作用域的剧集聚合：同一部剧的多集合成一张卡片。
    var cinemaSeries: [CinemaSeries] {
        cinemaSeries(for: cinemaActiveScope)
    }

    func cinemaSeries(for scope: CinemaScope, matched: Bool = true) -> [CinemaSeries] {
        let episodes = (cinemaIndexes[scope] ?? [:]).values
            .filter { $0.kind == .tv && $0.matched == matched }
        var groups: [String: [CinemaEntry]] = [:]
        for entry in episodes {
            groups[seriesKey(entry), default: []].append(entry)
        }
        return groups.compactMap { key, items in
            // 同一集的多版本只留画质最好的一条；版本选择在详情页完成。
            var bestByEpisode: [String: CinemaEntry] = [:]
            for entry in items {
                let episodeKey = "\(entry.season ?? 0)-\(entry.episode ?? 0)"
                if let existing = bestByEpisode[episodeKey],
                   !cinemaIsBetterVersion(entry, existing) {
                    continue
                }
                bestByEpisode[episodeKey] = entry
            }
            let sorted = bestByEpisode.values.sorted { lhs, rhs in
                if lhs.season != rhs.season { return (lhs.season ?? 0) < (rhs.season ?? 0) }
                if lhs.episode != rhs.episode { return (lhs.episode ?? 0) < (rhs.episode ?? 0) }
                return lhs.file.capturedAt < rhs.file.capturedAt
            }
            guard !sorted.isEmpty else { return nil }
            // 海报 / 简介取信息最全的一集。
            let sample = sorted.first(where: { $0.backdropURL != nil })
                ?? sorted.first(where: { $0.posterURL != nil })
                ?? sorted[0]
            return CinemaSeries(id: key,
                                title: sample.title,
                                year: sample.year,
                                overview: sample.overview,
                                rating: sample.rating,
                                posterURL: sample.posterURL,
                                backdropURL: sample.backdropURL,
                                episodes: sorted)
        }
        .sorted { lhs, rhs in
            (lhs.latestEpisode?.file.capturedAt ?? .distantPast)
                > (rhs.latestEpisode?.file.capturedAt ?? .distantPast)
        }
    }

    // MARK: 聚合缓存

    /// 页面用的一次性聚合结果：签名不变时直接复用上次结果。
    /// 参考图库 `cachedSystemQuery`：数据版本 + 筛选 + 排序拼成签名，变化才重算。
    func cinemaAggregate(for scope: CinemaScope) -> CinemaAggregate {
        let signature = cinemaAggregateSignature(for: scope)
        if signature == cinemaAggregateCacheKey, let cached = cinemaAggregateCacheValue {
            return cached
        }
        let value = buildCinemaAggregate(for: scope)
        cinemaAggregateCacheKey = signature
        cinemaAggregateCacheValue = value
        return value
    }

    private func cinemaAggregateSignature(for scope: CinemaScope) -> String {
        [
            Self.cinemaScopeKey(scope),
            String(cinemaDataRevision),
            cinemaSort.rawValue,
            cinemaDecades.sorted().map(String.init).joined(separator: ","),
            cinemaGenres.sorted().joined(separator: ","),
            cinemaResolutions.map(\.rawValue).sorted().joined(separator: ","),
            cinemaSpecFilters.map(\.rawValue).sorted().joined(separator: ","),
            cinemaWatchFilters.map(\.rawValue).sorted().joined(separator: ","),
            cinemaSmartHighRated ? "1" : "0",
            cinemaSmartRecent ? "1" : "0",
            cinemaFavoritesOnly ? "1" : "0",
            cinemaActiveListID?.uuidString ?? "-",
            cinemaParentalLocked ? "1" : "0",
            String(AppSettings.shared.cinemaParentalLevel.rawValue),
            // 「最近 30 天」按天滚动：跨天后签名变化，缓存自然刷新。
            String(Int(Date().timeIntervalSince1970 / 86_400))
        ].joined(separator: "|")
    }

    private func buildCinemaAggregate(for scope: CinemaScope) -> CinemaAggregate {
        var result = CinemaAggregate()
        result.allEntries = cinemaEntries(for: scope).values
            .sorted { $0.file.capturedAt > $1.file.capturedAt }
        result.entries = result.allEntries.filter { cinemaPassesFilters($0) }
        result.unmatched = result.allEntries.filter { !$0.matched }

        // 电影按版本去重：同一部片只留画质最好的一条；版本选择在详情页。
        var bestMovies: [String: CinemaEntry] = [:]
        for entry in result.entries where entry.kind == .movie {
            let key = cinemaVersionKey(for: entry)
            if let existing = bestMovies[key], !cinemaIsBetterVersion(entry, existing) { continue }
            bestMovies[key] = entry
        }
        result.movies = sortedCinemaEntries(Array(bestMovies.values))
        result.series = sortedCinemaSeries(cinemaSeries(for: scope).filter { cinemaPassesFilters($0) })
        result.unmatchedSeries = cinemaSeries(for: scope, matched: false)
        result.unmatchedMovies = result.unmatched.filter { $0.kind == .movie }
        result.collections = cinemaCollections(from: result.entries)
        result.letters = cinemaLetters(movies: result.movies, series: result.series)
        result.wallItemCount = result.movies.count + result.series.count
        result.stats = cinemaStats(entries: result.entries)

        // 版本数一次算完：卡片渲染时直接查表。
        var versionCounts: [String: Int] = [:]
        for entry in (cinemaIndexes[scope] ?? [:]).values {
            versionCounts[cinemaVersionKey(for: entry), default: 0] += 1
        }
        result.versionCounts = versionCounts

        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for entry in result.allEntries {
            if cinemaUserState(for: entry.id).favorite { result.favoriteCount += 1 }
            if entry.file.capturedAt >= cutoff { result.recentCount += 1 }
            if (entry.rating ?? 0) >= 8 { result.highRatedCount += 1 }
        }
        return result
    }

    private func cinemaStats(entries: [CinemaEntry]) -> CinemaAggregateStats {
        var stats = CinemaAggregateStats()
        for entry in entries {
            stats.matched += 1
            let width = entry.file.pixelWidth
            if width >= 3000 {
                stats.uhd += 1
            } else if width >= 1800 {
                stats.hd += 1
            } else if width > 0 {
                stats.sd += 1
            }
            if cinemaProgress[entry.id]?.isFinished == true { stats.watched += 1 }
        }
        return stats
    }

    private func cinemaCollections(from entries: [CinemaEntry]) -> [CinemaCollectionGroup] {
        var groups: [Int: [CinemaEntry]] = [:]
        for entry in entries where entry.kind == .movie {
            guard let id = entry.collectionID else { continue }
            groups[id, default: []].append(entry)
        }
        return groups.compactMap { id, list in
            var best: [String: CinemaEntry] = [:]
            for entry in list {
                let key = cinemaVersionKey(for: entry)
                if let existing = best[key], !cinemaIsBetterVersion(entry, existing) { continue }
                best[key] = entry
            }
            let unique = Array(best.values)
            guard unique.count >= 2 else { return nil }
            return CinemaCollectionGroup(
                id: id,
                name: list.first?.collectionName ?? "合集",
                entries: unique.sorted {
                    if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func cinemaLetters(movies: [CinemaEntry], series: [CinemaSeries]) -> [CinemaLetterEntry] {
        var seen = Set<String>()
        var list: [CinemaLetterEntry] = []
        for entry in movies {
            let letter = cinemaLetter(entry.title)
            guard seen.insert(letter).inserted else { continue }
            list.append(CinemaLetterEntry(letter: letter, target: entry.id.uuidString))
        }
        for item in series {
            let letter = cinemaLetter(item.title)
            guard seen.insert(letter).inserted else { continue }
            list.append(CinemaLetterEntry(letter: letter, target: "series-\(item.id)"))
        }
        return list.sorted { $0.letter.localizedStandardCompare($1.letter) == .orderedAscending }
    }

    /// 每部作品取首字符作为索引字母；中文片名直接用首字。
    private func cinemaLetter(_ title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let upper = String(first).uppercased()
        if upper.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) != nil { return upper }
        if first.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) { return String(first) }
        return "#"
    }

    private func sortedCinemaEntries(_ list: [CinemaEntry]) -> [CinemaEntry] {
        switch cinemaSort {
        case .recent:
            return list.sorted { $0.file.capturedAt > $1.file.capturedAt }
        case .rating:
            return list.sorted { lhs, rhs in
                let left = lhs.rating ?? 0
                let right = rhs.rating ?? 0
                if left == right {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        case .year:
            return list.sorted { lhs, rhs in
                let left = lhs.year ?? 0
                let right = rhs.year ?? 0
                if left == right {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        case .title:
            return list.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .duration:
            return list.sorted {
                ($0.file.duration ?? 0) > ($1.file.duration ?? 0)
            }
        }
    }

    private func sortedCinemaSeries(_ list: [CinemaSeries]) -> [CinemaSeries] {
        switch cinemaSort {
        case .recent:
            return list.sorted { latestDate($0) > latestDate($1) }
        case .rating:
            return list.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .year:
            return list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .title:
            return list.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .duration:
            return list.sorted { totalDuration($0) > totalDuration($1) }
        }
    }

    private func latestDate(_ series: CinemaSeries) -> Date {
        series.episodes.map(\.file.capturedAt).max() ?? .distantPast
    }

    private func totalDuration(_ series: CinemaSeries) -> Double {
        series.episodes.reduce(0) { $0 + ($1.file.duration ?? 0) }
    }

    private func seriesKey(_ entry: CinemaEntry) -> String {
        if let providerID = entry.tmdbID {
            // TMDB 键保持原样，避免老库的片头设置与观看状态失效；
            // 其它源的数字 ID 可能和 TMDB 撞号，必须带上前缀分开。
            if entry.provider == .tmdb { return "tv-\(providerID)" }
            return "tv-\(entry.provider?.rawValue ?? "other")-\(providerID)"
        }
        let normalized = entry.title.lowercased().filter { $0.isLetter || $0.isNumber }
        // 未识别时年份只是从文件名猜的：同一部剧有的集能猜到、有的猜不到，
        // 一旦把年份放进 key 就会被拆成好几张卡，所以未识别只按剧名分桶。
        guard entry.matched, let year = entry.year else { return "tv-\(normalized)" }
        return "tv-\(normalized)-\(year)"
    }

    // MARK: 多版本

    /// 同 tmdbID + 剧集号的多个文件共用一个版本键；未识别条目按 photoID 各自独立。
    func cinemaVersionKey(for entry: CinemaEntry) -> String {
        guard let tmdbID = entry.tmdbID else { return entry.id.uuidString }
        return "\(tmdbID)|\(entry.kind.rawValue)|\(entry.season ?? 0)|\(entry.episode ?? 0)"
    }

    /// 画质优先：分辨率更高的版本排前面；同分辨率比文件大小。
    func cinemaIsBetterVersion(_ lhs: CinemaEntry, _ rhs: CinemaEntry) -> Bool {
        if lhs.file.pixelWidth != rhs.file.pixelWidth {
            return lhs.file.pixelWidth > rhs.file.pixelWidth
        }
        return lhs.file.fileSize > rhs.file.fileSize
    }

    func cinemaVersions(for entry: CinemaEntry) -> [CinemaEntry] {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let key = cinemaVersionKey(for: entry)
        return (cinemaIndexes[scope] ?? [:]).values
            .filter { cinemaVersionKey(for: $0) == key }
            .sorted { cinemaIsBetterVersion($0, $1) }
    }

    func cinemaVersionCount(for entry: CinemaEntry) -> Int {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let key = cinemaVersionKey(for: entry)
        return (cinemaIndexes[scope] ?? [:]).values.reduce(0) {
            $0 + (cinemaVersionKey(for: $1) == key ? 1 : 0)
        }
    }

    /// 可刮削的视频：本地图库只取本地；网盘取这个链接的扫描清单，并带上所在目录链。
    func cinemaCandidates(for scope: CinemaScope) -> [CinemaCandidate] {
        var byID: [UUID: CinemaCandidate] = [:]

        func merge(_ photo: PhotoItem, hint: String?, folderPath: String?) {
            guard CinemaScraper.isCandidate(photo) else { return }
            // 手动忽略的视频以后都不再刮削。
            if cinemaIgnoredIDs[scope]?.contains(photo.id) == true { return }
            if let existing = byID[photo.id] {
                // 已经有目录线索的不要被后来的「无线索」覆盖。
                let resolvedHint = existing.folderHint ?? hint
                let resolvedPath = existing.folderPath ?? folderPath
                if resolvedHint != existing.folderHint || resolvedPath != existing.folderPath {
                    byID[photo.id] = CinemaCandidate(photo: photo,
                                                     folderHint: resolvedHint,
                                                     folderPath: resolvedPath)
                }
            } else {
                byID[photo.id] = CinemaCandidate(photo: photo,
                                                 folderHint: hint,
                                                 folderPath: folderPath)
            }
        }

        switch scope {
        case .local:
            for photo in photos { merge(photo, hint: nil, folderPath: nil) }
        case .mount(let mountID):
            guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { break }
            let rootPath = cloudRootPath(for: mount)

            /// 根目录本身不当作文件夹，它的直属视频统一落在「根目录」节点里。
            func directory(_ path: String?) -> String? {
                guard let path, !path.isEmpty, path != rootPath else { return nil }
                return path
            }

            // 目录名 → 父目录，用来还原「剧名 / 季」链条。
            var names: [String: String] = [:]
            var parents: [String: String] = [:]
            let snapshot = cloudAlbumSnapshot(mountID: mountID)
            if let folders = snapshot?.folders {
                for folder in folders {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }
            if cloudModel.scanMountID == mountID {
                for folder in cloudModel.scanFolders {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }

            if cloudModel.scanMountID == mountID {
                for photo in cloudModel.scanPhotos {
                    let folder = directory(photo.cloudPath.flatMap { cloudModel.scanMediaFolder[$0] })
                    merge(photo,
                          hint: folderChain(folder, names: names, parents: parents),
                          folderPath: folder)
                }
            }

            // 上次扫描的快照：即使当前没有打开这个网盘，也能拿到完整清单与目录名。
            if let snapshot {
                for record in snapshot.records where record.isVideo {
                    let photo = cloudAlbumPhoto(record: record, mount: mount)
                    let folder = directory(record.folderPath)
                    merge(photo,
                          hint: folderChain(folder, names: names, parents: parents),
                          folderPath: folder)
                }
            }

            for photo in cloudPhotos where photo.cloudMountID == mountID {
                let folder = directory(photo.cloudPath.flatMap { cloudModel.scanMediaFolder[$0] })
                merge(photo,
                      hint: folderChain(folder, names: names, parents: parents),
                      folderPath: folder)
            }
        }
        return Array(byID.values)
    }

    // MARK: 目录 NFO

    // MARK: 本地目录监听 / 片头尾自动识别

    /// 只监听本机真实目录：云盘没有文件系统事件，仍由扫描 / 刷新目录触发。
    func startLocalCinemaWatcher() {
        guard localCinemaWatcher == nil else { return }
        let paths = [LibraryPaths.originals.path]
        localCinemaWatcher = LocalCinemaWatcher(paths: paths) { [weak self] in
            Task { @MainActor in
                await self?.handleLocalCinemaDirectoryChange()
            }
        }
    }

    /// 目录有变化：重新读一次图库清单，必要时自动刮削本地影院的新视频。
    private func handleLocalCinemaDirectoryChange() async {
        if let data = metadataStore?.loadLibrary() {
            photos = data.photos
        }
        contentRevision &+= 1
        guard AppSettings.shared.cinemaAutoScrape else { return }
        startCinemaScrape(for: .local)
    }

    /// 片头尾识别结果：`online` 为 true 表示来自 TheIntroDB 社区库。
    struct CinemaIntroDetection {
        var mark: CinemaIntroMark
        var online: Bool
    }

    /// 片头尾识别：先查在线库（网盘片源也能识别），没有再退回本地静音检测。
    func detectCinemaIntro(for series: CinemaSeries) async -> CinemaIntroDetection? {
        if let mark = await onlineCinemaIntroMark(for: series) {
            return CinemaIntroDetection(mark: mark, online: true)
        }
        guard let episode = series.episodes.first(where: { $0.file.cloudMountID == nil }),
              let photo = anyPhoto(id: episode.file.photoID) else { return nil }
        let url = LibraryPaths.originalURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let mark = await CinemaIntroDetector.detect(url: url,
                                                          duration: episode.file.duration ?? 0) else {
            return nil
        }
        return CinemaIntroDetection(mark: mark, online: false)
    }

    /// 单集识别：用于详情页「本集」范围；在线优先，本地静音检测兜底。
    func detectCinemaIntro(for entry: CinemaEntry) async -> CinemaIntroDetection? {
        if let mark = await onlineCinemaIntroMark(for: entry) {
            return CinemaIntroDetection(mark: mark, online: true)
        }
        guard entry.file.cloudMountID == nil,
              let photo = anyPhoto(id: entry.file.photoID) else { return nil }
        let url = LibraryPaths.originalURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let mark = await CinemaIntroDetector.detect(url: url,
                                                          duration: entry.file.duration ?? 0) else {
            return nil
        }
        return CinemaIntroDetection(mark: mark, online: false)
    }

    /// 起播后补一次「本集」在线片头：如果这一集和整部剧的默认值不同，
    /// 拿到结果时还没过片头就直接跳到正确位置，并写成单集覆盖。
    func refineCinemaIntroOnPlayback(for entry: CinemaEntry) async {
        guard entry.kind == .tv,
              entry.provider == .tmdb,
              !hasCinemaEpisodeIntroMark(for: entry),
              !cinemaEpisodeIntroTried.contains(entry.id.uuidString) else { return }
        cinemaEpisodeIntroTried.insert(entry.id.uuidString)
        guard let mark = await onlineCinemaIntroMark(for: entry), mark.isEnabled else { return }
        // 期间可能已经翻到别的视频：结果仍然缓存下来，但不要动当前播放位置。
        setCinemaIntroMark(mark, for: entry)
        guard cinemaPlaybackEntry?.id == entry.id,
              !viewerModel.playbackSession.resumeApplied,
              mark.introSeconds > 0 else { return }
        let current = viewerModel.videoPlayer.currentTime
        guard current > 1,
              current < 60,
              current < Double(mark.introSeconds) - 2 else { return }
        viewerModel.playbackSession.requestIntroSkip(seconds: Double(mark.introSeconds))
    }

    private func onlineCinemaIntroMark(for entry: CinemaEntry) async -> CinemaIntroMark? {
        guard entry.kind == .tv,
              entry.provider == .tmdb,
              let tmdbID = entry.tmdbID,
              let season = entry.season,
              let episode = entry.episode else { return nil }
        return await onlineCinemaIntroMark(tmdbID: tmdbID,
                                           season: season,
                                           episode: episode,
                                           duration: entry.file.duration ?? 0)
    }

    /// 详情页打开时补一次在线片头：已有设置或已经查过的不再请求。
    func ensureCinemaIntroMark(for series: CinemaSeries) async {
        guard !cinemaIntroMark(forSeriesKey: series.id).isEnabled,
              !cinemaIntroAutoTried.contains(series.id) else { return }
        cinemaIntroAutoTried.insert(series.id)
        guard let mark = await onlineCinemaIntroMark(for: series),
              !cinemaIntroMark(forSeriesKey: series.id).isEnabled else { return }
        setCinemaIntroMark(mark, forSeriesKey: series.id)
    }

    /// 刮削完成后兜底：给这个影院里所有还没设置的剧集补在线片头片尾。
    func autoFillCinemaIntros(for scope: CinemaScope) async {
        let entries = (cinemaIndexes[scope] ?? [:]).values.filter {
            $0.kind == .tv && $0.tmdbID != nil && $0.provider == .tmdb
        }
        guard !entries.isEmpty else { return }
        var groups: [String: [CinemaEntry]] = [:]
        for entry in entries {
            groups[cinemaSeriesKey(for: entry), default: []].append(entry)
        }
        for (key, list) in groups {
            if Task.isCancelled { return }
            guard !cinemaIntroMark(forSeriesKey: key).isEnabled,
                  !cinemaIntroAutoTried.contains(key) else { continue }
            cinemaIntroAutoTried.insert(key)
            let first = list.min {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
            guard let first, let tmdbID = first.tmdbID else { continue }
            guard let mark = await onlineCinemaIntroMark(tmdbID: tmdbID,
                                                         season: first.season ?? 1,
                                                         episode: first.episode ?? 1,
                                                         duration: first.file.duration ?? 0),
                  !cinemaIntroMark(forSeriesKey: key).isEnabled else { continue }
            setCinemaIntroMark(mark, forSeriesKey: key)
            await Task.yield()
        }
    }

    private func onlineCinemaIntroMark(for series: CinemaSeries) async -> CinemaIntroMark? {
        let first = series.episodes
            .filter { $0.kind == .tv && $0.provider == .tmdb }
            .min { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        guard let first, let tmdbID = first.tmdbID else { return nil }
        return await onlineCinemaIntroMark(tmdbID: tmdbID,
                                           season: first.season ?? 1,
                                           episode: first.episode ?? 1,
                                           duration: first.file.duration ?? 0)
    }

    private func onlineCinemaIntroMark(tmdbID: Int,
                                       season: Int,
                                       episode: Int,
                                       duration: Double) async -> CinemaIntroMark? {
        guard let tmdb = tmdbClient() else { return nil }
        return await CinemaIntroOnline.mark(tmdb: tmdb,
                                            tmdbID: tmdbID,
                                            season: season,
                                            episode: episode,
                                            duration: duration)
    }

    /// 从当前刮削源里挑出配置了 Key 的 TMDB 客户端（在线片头库需要它换 IMDb ID）。
    private func tmdbClient() -> TMDBClient? {
        for source in metadataSources() {
            if let client = source as? TMDBClient { return client }
        }
        return nil
    }

    /// 刮削前先看目录里的 .nfo：命中就直接用 NFO 的标题 / 年份 / 季集，不再请求网络。
    /// 本地目录读文件；网盘先列一次目录（按文件缓存），再用统一下载链路读小文件。
    private func cinemaNFOEntry(for candidate: CinemaCandidate,
                                scope: CinemaScope) async -> CinemaEntry? {
        guard let nfo = await cinemaNFO(for: candidate, scope: scope) else { return nil }
        guard let title = nfo.title, !title.isEmpty else { return nil }

        let match = CinemaMatch(
            id: nfo.tmdbID.map(String.init) ?? "nfo-\(candidate.photo.id.uuidString)",
            isTV: nfo.isTV,
            title: title,
            originalTitle: nfo.originalTitle,
            year: nfo.year,
            posterURL: nfo.posterURL?.hasPrefix("http") == true ? nfo.posterURL : nil,
            backdropURL: nfo.backdropURL?.hasPrefix("http") == true ? nfo.backdropURL : nil,
            overview: nfo.overview,
            rating: nfo.rating,
            genres: nfo.genres,
            provider: .tmdb)

        var parsed = CinemaScraper.parse(filename: candidate.photo.displayFilename,
                                         folderHint: candidate.folderHint)
        if nfo.isTV { parsed.isTV = true }
        if let season = nfo.season { parsed.season = season }
        if let episode = nfo.episode { parsed.episode = episode }
        var entry = CinemaScraper.manualEntry(photo: candidate.photo,
                                              parsed: parsed,
                                              folderHint: candidate.folderHint,
                                              match: match)
        entry.runtime = nfo.runtime
        return entry
    }

    private func cinemaNFO(for candidate: CinemaCandidate,
                           scope: CinemaScope) async -> CinemaNFO? {
        let base = (candidate.photo.originalName as NSString).deletingPathExtension.lowercased()
        let folderKey = (candidate.folderPath ?? "local") + "|" + base
        if let cached = cinemaNFOByFolder[folderKey] { return cached }
        if cinemaNFOEmptyFolders.contains(folderKey) { return nil }

        let data: Data?
        switch scope {
        case .local:
            data = localNFOData(for: candidate.photo)
        case .mount(let id):
            data = await cloudNFOData(for: candidate, mountID: id)
        }
        guard let data, let parsed = CinemaNFO.parse(data: data) else {
            cinemaNFOEmptyFolders.insert(folderKey)
            return nil
        }
        cinemaNFOByFolder[folderKey] = parsed
        return parsed
    }

    private func localNFOData(for photo: PhotoItem) -> Data? {
        let file = LibraryPaths.originalURL(for: photo)
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent.lowercased()
        let names = [base + ".nfo", "movie.nfo", "tvshow.nfo", "season.nfo"]
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), data.count < 512_000 { return data }
        }
        return nil
    }

    private func cloudNFOData(for candidate: CinemaCandidate, mountID: UUID) async -> Data? {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }),
              let folder = candidate.folderPath,
              let entries = try? await CloudService.list(mount: mount, containerID: folder) else {
            return nil
        }
        let base = (candidate.photo.originalName as NSString).deletingPathExtension.lowercased()
        let preferred = [base + ".nfo", "movie.nfo", "tvshow.nfo", "season.nfo"]
        let nfo = entries.first { !$0.isDirectory && preferred.contains($0.name.lowercased()) }
            ?? entries.first { !$0.isDirectory && $0.name.lowercased().hasSuffix(".nfo") }
        guard let nfo else { return nil }

        var photo = PhotoItem(id: UUID(),
                              filename: nfo.name,
                              editedFilename: nil,
                              originalName: nfo.name,
                              capturedAt: Date(),
                              pixelWidth: 0,
                              pixelHeight: 0,
                              fileSize: nfo.size,
                              kind: .photo)
        photo.source = .cloud
        photo.cloudMountID = mount.id
        photo.cloudPath = nfo.path
        photo.cloudRemoteID = nfo.remoteID
        photo.cloudRestricted = nfo.isRestricted
        guard let resource = try? await CloudService.stream(mount: mount, photo: photo) else { return nil }
        var request = URLRequest(url: resource.url)
        request.timeoutInterval = 20
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              data.count < 512_000 else { return nil }
        return data
    }

    /// 拼出「剧名 / Season 01」这类目录链，最多向上三级；未知目录返回 nil。
    private func folderChain(_ path: String?,
                             names: [String: String],
                             parents: [String: String],
                             limit: Int = 3) -> String? {
        guard var cursor = path, !cursor.isEmpty else { return nil }
        var parts: [String] = []
        var hops = 0
        while hops < limit {
            guard let name = names[cursor], !name.isEmpty else { break }
            parts.append(name)
            guard let parent = parents[cursor], !parent.isEmpty else { break }
            cursor = parent
            hops += 1
        }
        return parts.isEmpty ? nil : parts.reversed().joined(separator: "/")
    }

    // MARK: 文件夹

    /// 把一个影院下的视频按真实目录组织成树：首层展示顶层文件夹，点进去看下一层，
    /// 可以一直钻到某一季 / 某个电影目录；尚未刮削的视频也会出现在这里。
    func cinemaFolders(for scope: CinemaScope) -> [CinemaFolder] {
        let entries = cinemaIndexes[scope] ?? [:]
        let scopeMountID: UUID?
        switch scope {
        case .local: scopeMountID = nil
        case .mount(let mountID): scopeMountID = mountID
        }

        // 目录图谱：路径 -> 名称 / 父路径。夸克的路径是目录 ID，靠这张表还原层级。
        var names: [String: String] = [:]
        var parents: [String: String] = [:]
        var rootPath = "/local"
        var rootName = "本地图库"
        var mountName = "本地图库"
        switch scope {
        case .local:
            names[rootPath] = rootName
        case .mount(let mountID):
            guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return [] }
            rootPath = cloudRootPath(for: mount)
            rootName = "根目录"
            mountName = mount.name
            if let folders = cloudAlbumSnapshot(mountID: mountID)?.folders {
                for folder in folders where !folder.path.isEmpty {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }
            if cloudModel.scanMountID == mountID {
                for folder in cloudModel.scanFolders where !folder.path.isEmpty {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }
        }

        let rootKey = "root"
        // 每个目录节点只收直属视频，子树在构建时递归汇总。
        var meta: [String: (name: String, parent: String?, hint: String?)] = [:]
        var directPhotos: [String: [PhotoItem]] = [:]

        func ensure(_ key: String, name: String, parent: String?, hint: String?) {
            if var existing = meta[key] {
                if existing.parent == nil { existing.parent = parent }
                if existing.hint == nil { existing.hint = hint }
                meta[key] = existing
            } else {
                meta[key] = (name: name, parent: parent, hint: hint)
            }
        }

        /// 从盘根到当前目录的完整可读目录链。
        func chain(of path: String) -> String? {
            var parts: [String] = []
            var cursor: String? = path
            while let current = cursor, !current.isEmpty, current != rootPath,
                  let name = names[current], !name.isEmpty {
                parts.append(name)
                cursor = parents[current]
                if parts.count >= 16 { break }
            }
            return parts.isEmpty ? nil : parts.reversed().joined(separator: "/")
        }

        /// 补齐从盘根到该目录的所有祖先节点，保证任意深度都能逐层进入。
        @discardableResult
        func registerReal(_ path: String) -> String? {
            guard !path.isEmpty, path != rootPath, names[path] != nil else { return nil }
            var chainPaths: [String] = []
            var cursor: String? = path
            while let current = cursor, !current.isEmpty, current != rootPath,
                  names[current] != nil {
                chainPaths.append(current)
                cursor = parents[current]
                if chainPaths.count >= 24 { break }
            }
            guard !chainPaths.isEmpty else { return nil }
            var parent: String?
            for key in chainPaths.reversed() {
                ensure(key,
                       name: names[key] ?? Self.cinemaFolderName(of: key),
                       parent: parent,
                       hint: chain(of: key))
                parent = key
            }
            return path
        }

        /// 没有目录图谱（快照缺失等）时，按可读目录链合成层级。
        func registerHint(_ hint: String) -> String {
            let parts = hint.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else {
                ensure(rootKey, name: rootName, parent: nil, hint: mountName)
                return rootKey
            }
            var parent: String?
            var accumulated: [String] = []
            var last = rootKey
            for part in parts {
                accumulated.append(part)
                let key = "hint:" + accumulated.joined(separator: "/")
                ensure(key, name: part, parent: parent, hint: accumulated.joined(separator: "/"))
                parent = key
                last = key
            }
            return last
        }

        var seen: Set<UUID> = []
        for candidate in cinemaCandidates(for: scope) {
            let photo = candidate.photo
            let key: String
            if scopeMountID == nil {
                ensure(rootKey, name: rootName, parent: nil, hint: nil)
                key = rootKey
            } else if let path = candidate.folderPath, let real = registerReal(path) {
                key = real
            } else if let raw = photo.cloudPath,
                      !Self.cinemaPathLooksLikeID(raw),
                      let parentPath = Self.cinemaParentFolder(of: raw),
                      let real = registerReal(parentPath) {
                key = real
            } else if let hint = candidate.folderHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !hint.isEmpty {
                key = registerHint(hint)
            } else {
                ensure(rootKey, name: rootName, parent: nil, hint: mountName)
                key = rootKey
            }
            directPhotos[key, default: []].append(photo)
            seen.insert(photo.id)
        }

        // 已刮削但扫描清单里没有的视频也补进来，避免清空扫描结果后文件夹空掉。
        for entry in entries.values where !seen.contains(entry.id) {
            let hint = entry.folderHint?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hint, !hint.isEmpty {
                directPhotos[registerHint(hint), default: []].append(entry.file.photoItem)
            } else if let raw = entry.file.cloudPath,
                      !Self.cinemaPathLooksLikeID(raw),
                      let parentPath = Self.cinemaParentFolder(of: raw),
                      let real = registerReal(parentPath) {
                directPhotos[real, default: []].append(entry.file.photoItem)
            } else {
                ensure(rootKey, name: rootName, parent: nil, hint: mountName)
                directPhotos[rootKey, default: []].append(entry.file.photoItem)
            }
        }

        var childrenByParent: [String: [String]] = [:]
        for (key, node) in meta {
            childrenByParent[node.parent ?? "", default: []].append(key)
        }

        func sortedKeys(_ keys: [String]) -> [String] {
            keys.sorted { lhs, rhs in
                let left = meta[lhs]?.name ?? lhs
                let right = meta[rhs]?.name ?? rhs
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        }

        func build(_ key: String) -> CinemaFolder? {
            guard let node = meta[key] else { return nil }
            let photos = (directPhotos[key] ?? []).filter { photo in
                guard let entry = entries[photo.id] else { return true }
                return !cinemaIsRestricted(entry)
            }
            let children = sortedKeys(childrenByParent[key] ?? [])
                .compactMap { build($0) }
                .sorted { lhs, rhs in
                    if lhs.isMatched != rhs.isMatched { return lhs.isMatched }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard !photos.isEmpty || !children.isEmpty else { return nil }

            var subtree = photos
            for child in children { subtree.append(contentsOf: child.subtreePhotos) }
            let subtreeEntries = subtree.compactMap { entries[$0.id] }
            let matched = subtreeEntries.filter { $0.matched }
            let distinctTitles = Set(matched.map(\.title))
            // 只有整个文件夹都指向同一部影片 / 剧集时才用片名做标题；混合目录保留文件夹名。
            let dominantTitle = distinctTitles.count == 1 ? matched.first?.title : nil
            let sample = matched.first(where: { $0.posterURL != nil })
                ?? matched.first(where: { $0.backdropURL != nil })
                ?? matched.first
            return CinemaFolder(path: key,
                                name: node.name,
                                parentPath: node.parent,
                                hint: node.hint,
                                mountID: scopeMountID,
                                photos: photos,
                                entries: subtreeEntries,
                                children: children,
                                subtreePhotos: subtree,
                                matchedCount: matched.count,
                                title: dominantTitle,
                                kind: dominantTitle == nil ? nil : sample?.kind,
                                posterURL: sample?.posterURL ?? matched.compactMap(\.posterURL).first,
                                backdropURL: sample?.backdropURL ?? matched.compactMap(\.backdropURL).first,
                                year: dominantTitle == nil ? nil : sample?.year,
                                episodeCount: dominantTitle == nil ? 0 : matched.filter { $0.kind == .tv }.count)
        }

        return sortedKeys(childrenByParent[""] ?? [])
            .compactMap { build($0) }
            .sorted { lhs, rhs in
                if lhs.isMatched != rhs.isMatched { return lhs.isMatched }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// 在整棵文件夹树里按路径取一个节点（详情面板钻取时用）。
    func cinemaFolder(path: String, scope: CinemaScope) -> CinemaFolder? {
        var stack = cinemaFolders(for: scope)
        while let folder = stack.popLast() {
            if folder.path == path { return folder }
            stack.append(contentsOf: folder.children)
        }
        return nil
    }

    /// 只刮削一个文件夹：连同子目录一起识别，适合「先把这部剧的整个目录处理掉」。
    func scrapeCinemaFolder(_ folder: CinemaFolder, scope: CinemaScope) async {
        let sources = metadataSources()
        guard !sources.isEmpty else {
            showToast("没有可用的刮削源，请检查设置 › 影院")
            return
        }
        let targets = folder.subtreePhotos
        guard !targets.isEmpty else {
            showToast("这个文件夹里没有可刮削的视频")
            return
        }

        let taskID = beginCinemaTask(for: scope, total: targets.count)
        let cache = CinemaSearchCache()
        let detailsCache = CinemaDetailsCache()
        var matched = 0

        for photo in targets {
            if Task.isCancelled { break }
            let hint = cinemaIndexes[scope]?[photo.id]?.folderHint ?? folder.hint
            let outcome = await CinemaScraper.scrape(photo: photo,
                                                     folderHint: hint,
                                                     sources: sources,
                                                     cache: cache,
                                                     detailsCache: detailsCache)
            if let entry = outcome.entry {
                cinemaIndexes[scope, default: [:]][entry.id] = entry
                if entry.matched { matched += 1 }
            }
        }

        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        let scopeMatched = (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
        finishCinemaTask(taskID,
                         matched: scopeMatched,
                         succeeded: true,
                         message: "文件夹「\(folder.displayTitle)」：识别 \(matched)/\(targets.count)")
        showToast("「\(folder.displayTitle)」刮削完成：识别 \(matched)/\(targets.count)")
    }

    static func cinemaParentFolder(of path: String) -> String? {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parent = (trimmed as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/", parent != "." else { return nil }
        return parent
    }

    static func cinemaFolderName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "根目录" : name
    }

    static func cinemaFolderHint(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init).suffix(3)
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// 夸克等网盘的 `cloudPath` 实际是文件 / 目录 ID（32 位十六进制），不是可读路径。
    static func cinemaPathLooksLikeID(_ path: String) -> Bool {
        guard !path.contains("/"), path.count >= 16 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: 配置

    /// 两个源同时工作：按优先级排序，TMDB 没填 Key 时自动跳过，只剩豆瓣。
    var cinemaNeedsConfiguration: Bool {
        metadataSources().isEmpty
    }

    private func metadataSources() -> [any CinemaMetadataSource] {
        AppSettings.shared.cinemaSourceOrder.compactMap { metadataSource(for: $0) }
    }

    /// 单个源：没填 Key 的 TMDB / TVDB 返回 nil（自动跳过）。
    private func metadataSource(for provider: CinemaProvider) -> (any CinemaMetadataSource)? {
        let settings = AppSettings.shared
        switch provider {
        case .tmdb:
            let key = settings.cinemaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TMDBClient(apiKey: key,
                              apiBase: settings.cinemaAPIBase,
                              imageBase: settings.cinemaImageBase,
                              language: settings.cinemaLanguage)
        case .douban:
            return DoubanClient(apiBase: settings.cinemaDoubanBase,
                                cookie: settings.cinemaDoubanCookie)
        case .tvdb:
            let key = settings.cinemaTVDBKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TVDBClient(apiKey: key,
                              pin: settings.cinemaTVDBPin,
                              language: settings.cinemaLanguage)
        }
    }

    /// 人物页作品悬停：按需补一次 TMDB 详情（简介 / 评分 / 类型 / 片长）。
    /// 未入库的作品没有本地档案，只能靠这一步把悬停信息补丰富。
    func cinemaCreditDetails(for credit: CinemaPersonCredit) async -> CinemaDetails? {
        guard let tmdb = metadataSource(for: .tmdb) as? TMDBClient else { return nil }
        return try? await tmdb.details(id: credit.tmdbID, isTV: credit.isTV)
    }

    /// 设置页单源连通性测试：只测这一行，不影响其它源的结果。
    func testCinemaProvider(_ provider: CinemaProvider) async -> CinemaConnectionResult {
        guard let source = metadataSource(for: provider) else {
            return CinemaConnectionResult(ok: false, message: "还没填 API Key")
        }
        do {
            let results = try await source.search(query: "流浪地球", isTV: false, year: nil)
            if let first = results.first {
                let year = first.year.map { "（\($0)）" } ?? ""
                return CinemaConnectionResult(ok: true, message: "连通 · \(first.title)\(year)")
            }
            return CinemaConnectionResult(ok: true, message: "连通 · 搜索无结果")
        } catch {
            return CinemaConnectionResult(ok: false, message: error.localizedDescription)
        }
    }

    /// 设置面板里的「测试连接」：用固定片名把每个在用数据源都搜一次，验证凭据与网络。
    func testCinemaConnection() async {
        guard !cinemaConnectionTesting else { return }
        let sources = metadataSources()
        guard !sources.isEmpty else {
            cinemaConnectionResult = CinemaConnectionResult(ok: false, message: "没有可用的刮削源")
            return
        }
        cinemaConnectionTesting = true
        cinemaConnectionResult = nil

        var succeeded: [String] = []
        var failures: [String] = []
        for source in sources {
            let name = source.provider.title
            do {
                let results = try await source.search(query: "流浪地球", isTV: false, year: nil)
                if let first = results.first {
                    let year = first.year.map { "（\($0)）" } ?? ""
                    succeeded.append("\(name)：\(first.title)\(year)")
                } else {
                    succeeded.append("\(name)：可用（搜索无结果）")
                }
            } catch {
                failures.append("\(name)：\(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            cinemaConnectionResult = CinemaConnectionResult(ok: true,
                                                            message: "连接正常 · " + succeeded.joined(separator: "；"))
        } else {
            var message = failures.joined(separator: "；")
            if !succeeded.isEmpty {
                message += "（" + succeeded.map { String($0.split(separator: "：")[0]) }.joined(separator: "、") + " 正常）"
            }
            cinemaConnectionResult = CinemaConnectionResult(ok: false, message: message)
        }
        cinemaConnectionTesting = false
    }

    // MARK: 刮削

    /// 从 UI 启动刮削：任务被保存下来，用户可以在进度条上取消。
    func startCinemaScrape(for scope: CinemaScope, force: Bool = false) {
        guard !cinemaScrapeRunning else { return }
        cinemaScrapeTask?.cancel()
        cinemaScrapeTask = Task { [weak self] in
            guard let self else { return }
            await self.scrapeCinema(for: scope, force: force)
            self.cinemaScrapeTask = nil
        }
    }

    /// 取消正在进行的刮削：中断网络请求，并保留已经完成的结果。
    func cancelCinemaScrape() {
        cinemaScrapeTask?.cancel()
        cinemaScrapeTask = nil
        guard cinemaScrapeRunning else { return }
        cinemaScrapeRunning = false
        cinemaScrapeScope = nil
        cinemaScrapeMessage = "已取消刮削，已完成的结果会保留"
        showToast("已取消刮削")
    }

    /// 刮削某一个影院（本地图库或某个网盘）。`force` 为 true 时连已刮削过的也重新匹配。
    func scrapeCinema(for scope: CinemaScope, force: Bool = false) async {
        guard !cinemaScrapeRunning else { return }
        let sources = metadataSources()
        guard !sources.isEmpty else {
            cinemaScrapeMessage = "没有可用的刮削源，请检查设置 › 影院"
            return
        }

        let all = cinemaCandidates(for: scope)
        let existing = cinemaIndexes[scope] ?? [:]
        // 没识别成功的条目留在「未识别」里；再次点刮削时重试它们，而不是直接说「都已刮削」。
        let pending = force ? all : all.filter { existing[$0.photo.id]?.matched != true }
        guard !pending.isEmpty else {
            cinemaScrapeMessage = all.isEmpty
                ? "这个链接下还没有可刮削的视频清单，先在「相簿」里重新扫描网盘"
                : "这个链接的视频都已识别，没有新的可刮削"
            return
        }

        cinemaScrapeRunning = true
        cinemaScrapeScope = scope
        cinemaScrapeDone = 0
        cinemaScrapeTotal = pending.count
        cinemaScrapeMessage = nil
        let taskID = beginCinemaTask(for: scope, total: pending.count)
        showToast("开始刮削这个链接下的 \(pending.count) 个视频…")

        // 同一部剧的多集共用同名搜索结果，避免几十集重复请求；
        // 详情（合集 / 演职员 / 预告 / 分级）同样按 tmdbID 只拉一次。
        let cache = CinemaSearchCache()
        let detailsCache = CinemaDetailsCache()
        // 同一目录的 NFO 只读一次；没有 NFO 的目录也记下来，避免每集重复列目录。
        cinemaNFOByFolder = [:]
        cinemaNFOEmptyFolders = []
        var failures = 0
        var consecutiveFailures = 0
        var firstError: String?
        // 每刮到一条就全量编码一次索引，几千条时会明显卡主线程；
        // 这里按时间批量落盘，中断 / 取消 / 结束时再补一次，不丢结果。
        var lastPersistAt = Date.distantPast
        for (index, candidate) in pending.enumerated() {
            if Task.isCancelled { break }
            if let nfoEntry = await cinemaNFOEntry(for: candidate, scope: scope) {
                cinemaIndexes[scope, default: [:]][nfoEntry.id] = nfoEntry
                consecutiveFailures = 0
            } else {
                let outcome = await CinemaScraper.scrape(photo: candidate.photo,
                                                         folderHint: candidate.folderHint,
                                                         sources: sources,
                                                         cache: cache,
                                                         detailsCache: detailsCache)
                if let entry = outcome.entry {
                    cinemaIndexes[scope, default: [:]][entry.id] = entry
                }
                if let error = outcome.error {
                    failures += 1
                    consecutiveFailures += 1
                    if firstError == nil { firstError = error }
                    // 连续失败多半是断网 / 代理 / 凭据失效：立刻停下并说清楚原因，
                    // 不要每个视频再等一轮超时，也不要让界面看起来「毫无反应」。
                    if consecutiveFailures >= 2 {
                        persistCinemaIndex(for: scope)
                        cinemaScrapeRunning = false
                        cinemaScrapeScope = nil
                        cinemaScrapeMessage = "刮削中断：连续 \(consecutiveFailures) 个视频请求失败。"
                            + Self.cinemaNetworkHint(for: error)
                        finishCinemaTask(taskID,
                                         matched: (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count,
                                         succeeded: false,
                                         message: cinemaScrapeMessage ?? "刮削中断")
                        showToast("刮削中断：刮削源都无法访问")
                        postCinemaToast(.failure,
                                        title: "刮削中断 · 刮削源不可达",
                                        detail: Self.cinemaNetworkHint(for: firstError ?? "网络异常"),
                                        actionTitle: "重试") { [weak self] in
                            self?.startCinemaScrape(for: scope, force: true)
                        }
                        return
                    }
                } else {
                    consecutiveFailures = 0
                }
            }
            cinemaScrapeDone = index + 1
            // 渲染让出主线程，保持进度条与网格可响应。
            if index % 5 == 0 {
                await Task.yield()
            }
            if Date().timeIntervalSince(lastPersistAt) >= 2 {
                persistCinemaIndex(for: scope)
                lastPersistAt = Date()
            }
        }

        if Task.isCancelled {
            persistCinemaIndex(for: scope)
            cinemaScrapeRunning = false
            cinemaScrapeScope = nil
            cinemaScrapeMessage = "已取消刮削，已完成的结果会保留"
            cinemaFolderRefreshToken &+= 1
            let matched = (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
            finishCinemaTask(taskID,
                             matched: matched,
                             succeeded: false,
                             message: "已取消",
                             notify: false)
            return
        }

        persistCinemaIndex(for: scope)
        cinemaScrapeRunning = false
        cinemaScrapeScope = nil
        let scopeEntries = cinemaIndexes[scope] ?? [:]
        let matched = scopeEntries.values.filter { $0.matched }.count
        let unmatched = scopeEntries.count - matched
        var message = "刮削完成：共 \(scopeEntries.count) 个视频，识别 \(matched) 个，未识别 \(unmatched) 个"
        if failures > 0 {
            message += "；\(failures) 条失败：" + Self.cinemaNetworkHint(for: firstError ?? "网络或接口异常")
        }
        cinemaScrapeMessage = message
        cinemaFolderRefreshToken &+= 1
        // 在线片头片尾放到完成之后补，不拖慢刮削进度；已有设置 / 查过的剧集不重复请求。
        Task { await self.autoFillCinemaIntros(for: scope) }
        finishCinemaTask(taskID,
                         matched: matched,
                         succeeded: failures == 0,
                         message: message)
        postCinemaToast(failures == 0 ? .success : .failure,
                        title: failures == 0
                            ? "刮削完成 · \(matched) 部已识别"
                            : "刮削完成 · \(unmatched) 个未识别",
                        detail: "\(cinemaScopeName(scope)) · \(scopeEntries.count) 个视频",
                        actionTitle: "查看") { [weak self] in
            self?.cinemaNotificationsVisible = true
        }
    }

    /// 把常见网络错误翻译成能直接照做的提示。
    static func cinemaNetworkHint(for message: String) -> String {
        let lower = message.lowercased()
        let networkLike = ["timed out", "timeout", "超时", "offline", "internet", "connect",
                           "network", "networkconnection", "连接", "无法访问"]
        if networkLike.contains(where: { lower.contains($0) }) {
            return "当前网络无法连接刮削源（TMDB / 豆瓣），请检查代理或网络后重试。"
        }
        return "刮削源返回：\(message)"
    }

    /// 单条重新刮削（右键菜单），结果写回条目所属的影院。
    func rescrapeCinema(_ entry: CinemaEntry) async {
        let sources = metadataSources()
        guard !sources.isEmpty else {
            cinemaScrapeMessage = "没有可用的刮削源，请检查设置 › 影院"
            return
        }
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let outcome = await CinemaScraper.scrape(photo: photo,
                                                 folderHint: entry.folderHint,
                                                 sources: sources,
                                                 detailsCache: CinemaDetailsCache())
        if let error = outcome.error {
            cinemaScrapeMessage = "重新刮削失败：\(error)"
            showToast("重新刮削失败")
            return
        }
        guard let updated = outcome.entry else { return }
        cinemaIndexes[scope, default: [:]][updated.id] = updated
        persistCinemaIndex(for: scope)
        showToast(updated.matched ? "已匹配「\(updated.title)」" : "仍未找到匹配结果")
    }

    // MARK: 手动匹配

    /// 用户输入片名后的候选搜索；只读，不写回索引。
    /// `providers` 为空表示查全部可用源，`combineAll` 为 true 时不再「第一个有结果就停」。
    func cinemaSearchCandidates(query: String,
                                isTV: Bool,
                                year: Int?,
                                providers: [CinemaProvider]? = nil,
                                combineAll: Bool = false) async -> (matches: [CinemaMatch], error: String?) {
        var sources = metadataSources()
        if let providers, !providers.isEmpty {
            sources = sources.filter { providers.contains($0.provider) }
        }
        guard !sources.isEmpty else {
            let names = (providers ?? []).map(\.title).joined(separator: " / ")
            return ([], names.isEmpty
                    ? "没有可用的刮削源，请检查设置 › 影院"
                    : "\(names) 还没配置，请到设置 › 影院填写 Key")
        }
        return await CinemaScraper.searchCandidates(query: query,
                                                    isTV: isTV,
                                                    year: year,
                                                    sources: sources,
                                                    combineAllSources: combineAll)
    }

    /// 应用手动匹配：只替换这一条，不重扫全库。
    @discardableResult
    func applyCinemaMatch(_ match: CinemaMatch, to entry: CinemaEntry) -> CinemaEntry? {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let parsed = CinemaScraper.parse(filename: entry.file.filename,
                                         folderHint: entry.folderHint)
        let updated = CinemaScraper.manualEntry(photo: photo,
                                                parsed: parsed,
                                                folderHint: entry.folderHint,
                                                match: match)
        cinemaIndexes[scope, default: [:]][updated.id] = updated
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已匹配「\(updated.title)」")
        return updated
    }

    // MARK: 播放

    /// 从影院直接进入查看器；不依赖该网盘目录当前是否加载。
    func openCinema(_ entry: CinemaEntry) {
        // 切换影片前先把上一条的进度落盘，避免连续点两部片时丢掉前一部的位置。
        finishCinemaPlayback()
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        cinemaPlaybackPhoto = photo
        cinemaPlaybackEntry = entry
        // 换片瞬间播放器里还挂着上一个视频：先停掉，避免旧片的进度回调写进新条目。
        if viewerID != photo.id {
            viewerModel.videoPlayer.stop()
        }
        // 打开别的片子时丢掉不匹配的预热流，避免残留 ffmpeg；匹配的留给播放页接管。
        if cinemaPrewarmedStream?.photoID != entry.id {
            discardPrewarmedCinemaStream()
        }
        openViewer(photo.id)
        viewerModel.videoPlaybackUI.subtitleQuery = CinemaSubtitleQuery(title: entry.title,
                                                                        season: entry.season,
                                                                        episode: entry.episode)
        // 在线查这一集的真实片头；拿到时还在片头区间就跳过去（只查一次）。
        if entry.kind == .tv {
            Task { await self.refineCinemaIntroOnPlayback(for: entry) }
        }
    }

    // MARK: 忽略 / 删除

    func isCinemaIgnored(_ entry: CinemaEntry) -> Bool {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        return cinemaIgnoredIDs[scope]?.contains(entry.file.photoID) == true
    }

    /// 忽略一个视频：从影院里移除，以后刮削也不会再处理它（原文件不动）。
    func ignoreCinemaEntry(_ entry: CinemaEntry) {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        var ignored = cinemaIgnoredIDs[scope] ?? []
        ignored.insert(entry.file.photoID)
        cinemaIgnoredIDs[scope] = ignored
        persistCinemaIgnored(for: scope)
        cinemaIndexes[scope]?[entry.id] = nil
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已忽略「\(entry.title)」，以后不再刮削")
    }

    /// 剧集整部忽略：一次性把这条聚合里的全部分集标记为忽略。
    func ignoreCinemaSeries(_ series: CinemaSeries) {
        guard let scope = series.episodes.first.map({
            $0.file.cloudMountID.map { CinemaScope.mount($0) } ?? .local
        }) else { return }
        var ignored = cinemaIgnoredIDs[scope] ?? []
        for episode in series.episodes {
            ignored.insert(episode.file.photoID)
            cinemaIndexes[scope]?[episode.id] = nil
        }
        cinemaIgnoredIDs[scope] = ignored
        persistCinemaIgnored(for: scope)
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已忽略「\(series.title)」的 \(series.episodes.count) 个文件，以后不再刮削")
    }

    /// 恢复被忽略的视频：清空忽略清单，下次刮削会重新处理它们。
    func restoreCinemaIgnored(for scope: CinemaScope) {
        let count = cinemaIgnoredIDs[scope]?.count ?? 0
        guard count > 0 else { return }
        cinemaIgnoredIDs[scope] = []
        persistCinemaIgnored(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已恢复 \(count) 个视频，下次刮削会重新处理")
    }

    private func persistCinemaIgnored(for scope: CinemaScope) {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(Array(cinemaIgnoredIDs[scope] ?? [])),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaIgnoredSettingKey(for: scope), json)
    }

    /// 删除确认：真删原文件，刮削索引 / 进度 / 清单引用一并清理。
    func confirmDeleteCinemaEntries(_ entries: [CinemaEntry], title: String? = nil) {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        let cloud = entries.contains { $0.file.isCloud }
        alert.messageText = "永久删除\(title.map { "「\($0)」" } ?? "")的 \(entries.count) 个视频文件？"
        alert.informativeText = "会从\(cloud ? "网盘 / 共享" : "本机磁盘")直接删除原文件，无法恢复；"
            + "影院索引、观看记录与清单引用会一起清理。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "永久删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await deleteCinemaEntries(entries) }
    }

    /// 逐个删除原文件，成功的条目才从影院移除；失败的给出可读原因。
    func deleteCinemaEntries(_ entries: [CinemaEntry]) async {
        var removed = 0
        var failure: String?
        for entry in entries {
            if entry.file.isCloud {
                if let reason = await deleteCinemaCloudFile(entry) {
                    failure = reason
                    continue
                }
            } else if let reason = deleteCinemaLocalFile(entry) {
                failure = reason
                continue
            }
            removeCinemaEntryAssets(entry)
            removed += 1
        }
        if let failure {
            showToast("删除失败：\(failure)")
            postCinemaToast(.failure, title: "删除失败", detail: failure)
        } else if removed > 0 {
            showToast(removed == 1 ? "已永久删除" : "已永久删除 \(removed) 个文件")
        }
    }

    /// 本地文件：直接删原图，再清掉照片索引与派生数据。
    private func deleteCinemaLocalFile(_ entry: CinemaEntry) -> String? {
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let url = LibraryPaths.originalURL(for: photo)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                return "\(entry.file.filename)：\(error.localizedDescription)"
            }
        }
        purgeAssetArtifacts(photo)
        purgeAssetMetadata([photo.id])
        photos.removeAll { $0.id == photo.id }
        save()
        return nil
    }

    /// 网盘 / 共享文件：按来源类型走各自的删除通道。
    private func deleteCinemaCloudFile(_ entry: CinemaEntry) async -> String? {
        guard let mountID = entry.file.cloudMountID,
              let mount = cloudMounts.first(where: { $0.id == mountID }) else {
            return "找不到这个网盘连接，请先在侧边栏重新连接"
        }
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        do {
            try await CloudService.delete(mount: mount, photo: photo)
        } catch {
            return "\(entry.file.filename)：\(error.localizedDescription)"
        }
        if let path = photo.cloudPath {
            try? FileManager.default.removeItem(
                at: CloudPaths.thumbnailURL(mountID: mountID, path: path))
        }
        cloudPhotos.removeAll { $0.id == photo.id }
        cloudModel.scanPhotos.removeAll { $0.id == photo.id }
        if cloudModel.scanMountID == mountID {
            refreshCloudDirectory()
        }
        return nil
    }

    /// 删除成功后的索引清理：条目 / 进度 / 收藏 / 清单引用一次清干净。
    private func removeCinemaEntryAssets(_ entry: CinemaEntry) {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        cinemaIndexes[scope]?[entry.id] = nil
        persistCinemaIndex(for: scope)
        cinemaIgnoredIDs[scope]?.remove(entry.file.photoID)
        persistCinemaIgnored(for: scope)
        cinemaProgress[entry.id] = nil
        persistCinemaProgress()
        cinemaUserStates[entry.id] = nil
        persistCinemaUserState()
        cinemaLists = cinemaLists.map { list in
            var copy = list
            copy.itemIDs.removeAll { $0 == entry.id }
            return copy
        }
        persistCinemaLists()
        cinemaFolderRefreshToken &+= 1
        if viewerID == entry.file.photoID {
            closeViewer()
        }
    }

    // MARK: 详情补全（合集 / 演职员 / 预告 / 分级）

    /// 从 TMDB 拉一次详情并写回索引；豆瓣条目没有详情接口，直接跳过。
    /// 已有详情时默认不重复请求，`force` 用于详情页的「刷新」。
    @discardableResult
    func enrichCinemaEntry(_ entry: CinemaEntry, force: Bool = false) async -> CinemaEntry? {
        guard entry.matched, let tmdbID = entry.tmdbID else { return nil }
        // 只有 TMDB 条目能按这个 ID 补详情；TVDB / 豆瓣的 ID 不是 TMDB 的。
        guard entry.provider == .tmdb else { return nil }
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        guard var current = cinemaIndexes[scope]?[entry.id] else { return nil }
        let hasOverviewFacts = current.runtime != nil || current.status != nil || current.releaseDate != nil
        if !force,
           hasOverviewFacts,
           current.cast != nil {
            return current
        }
        for source in metadataSources() where source.provider == .tmdb {
            guard let details = try? await source.details(id: tmdbID, isTV: entry.kind == .tv) else {
                continue
            }
            current.collectionID = details.collectionID
            current.collectionName = details.collectionName
            if !details.cast.isEmpty { current.cast = details.cast }
            if !details.directors.isEmpty { current.directors = details.directors }
            if let value = details.certification { current.certification = value }
            if let key = details.trailerKey { current.trailerKey = key }
            if let value = details.tagline { current.tagline = value }
            if let value = details.runtime, value > 0 { current.runtime = value }
            if let value = details.status, !value.isEmpty { current.status = value }
            if let value = details.releaseDate, !value.isEmpty { current.releaseDate = value }
            if let value = details.originalLanguage, !value.isEmpty { current.originalLanguage = value }
            if !details.countries.isEmpty { current.countries = details.countries }
            if !details.companies.isEmpty { current.companies = details.companies }
            if !details.networks.isEmpty { current.networks = details.networks }
            if let value = details.seasonCount, value > 0 { current.seasonCount = value }
            if let value = details.episodeCount, value > 0 { current.episodeTotal = value }
            if let value = details.voteCount, value > 0 { current.voteCount = value }
            if let value = details.budget, value > 0 { current.budget = value }
            if let value = details.revenue, value > 0 { current.revenue = value }
            cinemaIndexes[scope, default: [:]][current.id] = current
            persistCinemaIndex(for: scope)
            return current
        }
        return nil
    }

    /// 智能助手用：按 tmdbID 取详情（季数 / 集数 / 分级等），用于挑选候选。
    func cinemaDetails(id: Int, isTV: Bool) async -> CinemaDetails? {
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            if let details = try? await tmdb.details(id: id, isTV: isTV) {
                return details
            }
        }
        return nil
    }

    /// 单集标题 / 简介 / 剧照的本地缓存：按 tmdbID + 季存进图库设置库。
    /// 打开详情先读它，12 小时内不再请求网络。
    private struct CinemaEpisodeInfoCache: Codable {
        var fetchedAt: Date
        var episodes: [Int: CinemaEpisodeInfo]
    }

    static func cinemaEpisodeInfoKey(tvID: Int, season: Int) -> String {
        "cinema_episode_infos_\(tvID)_\(season)"
    }

    /// 读缓存：返回单集信息与是否足够新。没有缓存时返回 nil。
    func cachedCinemaEpisodeInfos(tvID: Int,
                                  season: Int) -> (infos: [Int: CinemaEpisodeInfo], fresh: Bool)? {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaEpisodeInfoKey(tvID: tvID, season: season)),
              let data = json.data(using: .utf8),
              let cache = try? JSONDecoder().decode(CinemaEpisodeInfoCache.self, from: data),
              !cache.episodes.isEmpty else { return nil }
        let fresh = Date().timeIntervalSince(cache.fetchedAt) < 12 * 3600
        return (cache.episodes, fresh)
    }

    /// 剧集详情按季拉取单集标题 / 简介 / 剧照；成功后写回本地缓存。
    /// 没有 TMDB 源或请求失败返回 nil，调用方继续用缓存。
    func refreshCinemaEpisodeInfos(tvID: Int, season: Int) async -> [Int: CinemaEpisodeInfo]? {
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            guard let map = try? await tmdb.seasonDetails(tvID: tvID, season: season),
                  !map.isEmpty else { continue }
            if let metadataStore,
               let data = try? JSONEncoder().encode(CinemaEpisodeInfoCache(fetchedAt: Date(), episodes: map)),
               let json = String(data: data, encoding: .utf8) {
                metadataStore.setSetting(Self.cinemaEpisodeInfoKey(tvID: tvID, season: season), json)
            }
            return map
        }
        return nil
    }

    /// 同一合集里的其他影片：按版本键去重、按年份排序。
    func cinemaCollection(collectionID: Int) -> [CinemaEntry] {
        var best: [String: CinemaEntry] = [:]
        for entry in cinemaEntries.values where entry.matched && entry.collectionID == collectionID {
            guard !cinemaIsRestricted(entry) else { continue }
            let key = cinemaVersionKey(for: entry)
            if let existing = best[key], !cinemaIsBetterVersion(entry, existing) { continue }
            best[key] = entry
        }
        return best.values.sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    // MARK: 人物页 / 合集页

    /// 人物页「本库已有」：按演员 / 导演命中，电影去多版本、剧集按剧聚合。
    func cinemaPersonWorks(named name: String) -> [CinemaEntry] {
        let scope = cinemaActiveScope
        var best: [String: CinemaEntry] = [:]
        for entry in (cinemaIndexes[scope] ?? [:]).values where entry.matched {
            guard !cinemaIsRestricted(entry) else { continue }
            let hit = (entry.cast ?? []).contains { $0.name == name }
                || (entry.directors ?? []).contains(name)
            guard hit else { continue }
            let key = entry.kind == .tv ? seriesKey(entry) : cinemaVersionKey(for: entry)
            if let existing = best[key] {
                if entry.kind == .tv {
                    if (entry.episode ?? 0) < (existing.episode ?? 0) { best[key] = entry }
                } else if cinemaIsBetterVersion(entry, existing) {
                    best[key] = entry
                }
            } else {
                best[key] = entry
            }
        }
        return best.values.sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) > ($1.year ?? 0) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// 人物页「全部作品」里的一条如果本库有文件，直接对应到可播放条目。
    func cinemaEntry(forCredit credit: CinemaPersonCredit) -> CinemaEntry? {
        let scope = cinemaActiveScope
        let candidates = (cinemaIndexes[scope] ?? [:]).values.filter {
            $0.matched && $0.tmdbID == credit.tmdbID && $0.kind == (credit.isTV ? .tv : .movie)
        }
        guard var pick = candidates.first else { return nil }
        for entry in candidates where cinemaIsBetterVersion(entry, pick) { pick = entry }
        return pick
    }

    func cinemaPersonProfile(for member: CinemaCastMember) async -> CinemaPersonProfile? {
        guard let id = member.tmdbID else { return nil }
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            if let profile = try? await tmdb.person(id: id) { return profile }
        }
        return nil
    }

    func cinemaCollectionInfo(collectionID: Int) async -> CinemaCollectionInfo? {
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            if let info = try? await tmdb.collection(id: collectionID) { return info }
        }
        return nil
    }

    // MARK: 通知中心 / Toast

    func loadCinemaNotifications() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaNotificationsSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaNotification].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let kept = list.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
        cinemaNotifications = kept
        if kept.count != list.count { persistCinemaNotifications() }
    }

    func persistCinemaNotifications() {
        guard let metadataStore else { return }
        if cinemaNotifications.count > 200 {
            cinemaNotifications = Array(cinemaNotifications.prefix(200))
        }
        guard let data = try? JSONEncoder().encode(cinemaNotifications),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaNotificationsSettingKey, json)
    }

    var cinemaUnreadNotificationCount: Int {
        cinemaNotifications.filter { !$0.read }.count
    }

    /// 任务结果归档：同一任务 60 秒内重复写入时合并，避免刷屏。
    func recordCinemaNotification(_ kind: CinemaNotificationKind,
                                  title: String,
                                  detail: String = "",
                                  action: String? = nil,
                                  scopeKey: String? = nil) {
        if let index = cinemaNotifications.firstIndex(where: {
            $0.title == title && $0.scopeKey == scopeKey && Date().timeIntervalSince($0.date) < 60
        }) {
            cinemaNotifications[index].date = Date()
            cinemaNotifications[index].detail = detail
            cinemaNotifications[index].kind = kind
            cinemaNotifications[index].action = action
            cinemaNotifications[index].read = false
        } else {
            cinemaNotifications.insert(CinemaNotification(kind: kind,
                                                          title: title,
                                                          detail: detail,
                                                          action: action,
                                                          scopeKey: scopeKey),
                                       at: 0)
        }
        persistCinemaNotifications()
    }

    func markAllCinemaNotificationsRead() {
        for index in cinemaNotifications.indices { cinemaNotifications[index].read = true }
        persistCinemaNotifications()
    }

    func clearCinemaNotifications() {
        cinemaNotifications = []
        persistCinemaNotifications()
    }

    /// 右上角 Toast：成功 4 秒自动消失；失败与进度常驻直到手动关闭。
    func postCinemaToast(_ kind: CinemaToastKind,
                         title: String,
                         detail: String? = nil,
                         actionTitle: String? = nil,
                         action: (() -> Void)? = nil) {
        if cinemaToasts.count >= 3 {
            let victim = cinemaToasts.first { $0.kind != .failure } ?? cinemaToasts[0]
            dismissCinemaToast(victim.id)
        }
        let toast = CinemaToast(kind: kind,
                                title: title,
                                detail: detail,
                                actionTitle: actionTitle,
                                action: action)
        cinemaToasts.append(toast)
        guard kind == .success || kind == .info else { return }
        let id = toast.id
        cinemaToastTasks[id]?.cancel()
        cinemaToastTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissCinemaToast(id)
        }
    }

    func dismissCinemaToast(_ id: UUID) {
        cinemaToastTasks[id]?.cancel()
        cinemaToastTasks[id] = nil
        cinemaToasts.removeAll { $0.id == id }
    }

    // MARK: 影院内搜索

    /// 在当前影院内检索：片名 / 原名 / 文件名 / 类型 / 演员 / 导演。
    /// `includeUnmatched` 为 true 时把未识别视频的文件名也纳入结果（默认只看已入库）。
    func cinemaSearchResults(_ query: String,
                             includeUnmatched: Bool = false)
        -> (entries: [CinemaEntry], series: [CinemaSeries], people: [CinemaCastMember]) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard keyword.count >= 1 else { return ([], [], []) }
        let scope = cinemaActiveScope
        var best: [String: CinemaEntry] = [:]
        for entry in (cinemaIndexes[scope] ?? [:]).values {
            guard !cinemaIsRestricted(entry) else { continue }
            guard entry.matched || includeUnmatched else { continue }
            guard entry.matched ? cinemaMatches(entry, keyword)
                                : entry.file.filename.lowercased().contains(keyword) else { continue }
            if entry.kind == .tv { continue }
            let key = cinemaVersionKey(for: entry)
            if let existing = best[key], !cinemaIsBetterVersion(entry, existing) { continue }
            best[key] = entry
        }
        var seriesPool = cinemaSeries(for: scope)
        if includeUnmatched {
            seriesPool += cinemaSeries(for: scope, matched: false)
        }
        let shows = seriesPool.filter { item in
            guard item.episodes.contains(where: { !cinemaIsRestricted($0) }) else { return false }
            if let first = item.episodes.first, !first.matched {
                guard includeUnmatched else { return false }
                return item.episodes.contains { $0.file.filename.lowercased().contains(keyword) }
            }
            if item.title.lowercased().contains(keyword) { return true }
            if (item.overview ?? "").lowercased().contains(keyword) { return true }
            return item.episodes.contains { cinemaMatches($0, keyword) }
        }
        // 人物：从已刮削条目的演员 / 导演里按名字匹配，并按名字去重。
        var people: [CinemaCastMember] = []
        var seenNames = Set<String>()
        for entry in (cinemaIndexes[scope] ?? [:]).values where entry.matched {
            guard !cinemaIsRestricted(entry) else { continue }
            for member in entry.cast ?? [] where member.name.lowercased().contains(keyword) {
                guard seenNames.insert(member.name).inserted else { continue }
                people.append(member)
            }
            for director in entry.directors ?? [] where director.lowercased().contains(keyword) {
                guard seenNames.insert(director).inserted else { continue }
                let profile = (cinemaIndexes[scope] ?? [:]).values
                    .compactMap { $0.cast?.first { $0.name == director } }
                    .first
                people.append(CinemaCastMember(name: director,
                                               character: "导演",
                                               profileURL: profile?.profileURL,
                                               tmdbID: profile?.tmdbID))
            }
        }
        let movies = best.values.sorted { $0.file.capturedAt > $1.file.capturedAt }
        return (movies, shows, Array(people.prefix(20)))
    }

    private func cinemaMatches(_ entry: CinemaEntry, _ keyword: String) -> Bool {
        if entry.title.lowercased().contains(keyword) { return true }
        if (entry.originalTitle ?? "").lowercased().contains(keyword) { return true }
        if entry.file.filename.lowercased().contains(keyword) { return true }
        if (entry.genres ?? []).contains(where: { $0.lowercased().contains(keyword) }) { return true }
        if (entry.cast ?? []).contains(where: { $0.name.lowercased().contains(keyword) }) { return true }
        if (entry.directors ?? []).contains(where: { $0.lowercased().contains(keyword) }) { return true }
        return false
    }

    // MARK: 观看记录

    /// 当前作用域的全部观看记录（含已看完），按最近观看排序。
    func cinemaHistory(for scope: CinemaScope) -> [CinemaProgressRecord] {
        let mountID: UUID?
        switch scope {
        case .local: mountID = nil
        case .mount(let id): mountID = id
        }
        return cinemaProgress.values
            .filter { record in
                guard record.mountID == mountID else { return false }
                if let entry = cinemaIndexes[scope]?[record.photoID], cinemaIsRestricted(entry) {
                    return false
                }
                return true
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func removeCinemaProgress(_ id: UUID) {
        cinemaProgress.removeValue(forKey: id)
        persistCinemaProgress()
        showToast("已从观看记录中移除")
    }

    // MARK: 任务中心

    func loadCinemaTasks() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaTasksSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaTaskRecord].self, from: data) else { return }
        cinemaTasks = list
    }

    func persistCinemaTasks() {
        guard let metadataStore else { return }
        if cinemaTasks.count > 100 {
            cinemaTasks = Array(cinemaTasks.sorted { $0.startedAt > $1.startedAt }.prefix(100))
        }
        guard let data = try? JSONEncoder().encode(cinemaTasks),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaTasksSettingKey, json)
    }

    static func cinemaScopeKey(_ scope: CinemaScope) -> String {
        switch scope {
        case .local: return "local"
        case .mount(let id): return id.uuidString
        }
    }

    func cinemaScope(forKey key: String) -> CinemaScope? {
        if key == "local" { return .local }
        guard let id = UUID(uuidString: key) else { return nil }
        return .mount(id)
    }

    func cinemaScopeName(_ scope: CinemaScope) -> String {
        switch scope {
        case .local: return "本地图库"
        case .mount(let id): return cloudMounts.first { $0.id == id }?.name ?? "网络存储"
        }
    }

    @discardableResult
    func beginCinemaTask(for scope: CinemaScope, total: Int) -> UUID {
        let record = CinemaTaskRecord(scopeKey: Self.cinemaScopeKey(scope),
                                      scopeName: cinemaScopeName(scope),
                                      total: total)
        cinemaTasks.append(record)
        persistCinemaTasks()
        return record.id
    }

    func finishCinemaTask(_ id: UUID,
                          matched: Int,
                          succeeded: Bool,
                          message: String,
                          notify: Bool = true) {
        guard let index = cinemaTasks.firstIndex(where: { $0.id == id }) else { return }
        cinemaTasks[index].finishedAt = Date()
        cinemaTasks[index].matched = matched
        cinemaTasks[index].succeeded = succeeded
        cinemaTasks[index].message = message
        persistCinemaTasks()
        guard notify else { return }
        // 任务结果同时归档到通知中心：同一任务 1 分钟内合并，不刷屏。
        let record = cinemaTasks[index]
        recordCinemaNotification(succeeded ? .success : .failure,
                                 title: succeeded ? "刮削完成" : "刮削中断",
                                 detail: "\(record.scopeName) · \(message)",
                                 action: succeeded ? nil : "重试",
                                 scopeKey: record.scopeKey)
    }

    /// 失败任务的「重试」：重跑对应影院的刮削。
    func retryCinemaTask(_ task: CinemaTaskRecord) async {
        guard let scope = cinemaScope(forKey: task.scopeKey) else {
            showToast("来源已移除，无法重试")
            return
        }
        startCinemaScrape(for: scope, force: true)
    }

    /// 通知中心里的「重试」只带作用域键，从这里还原成影院并重跑。
    func retryCinemaScope(key: String) async {
        guard let scope = cinemaScope(forKey: key) else {
            postCinemaToast(.failure, title: "来源已移除，无法重试")
            return
        }
        startCinemaScrape(for: scope, force: true)
    }

    func clearCinemaTasks() {
        cinemaTasks = []
        persistCinemaTasks()
        showToast("已清空任务记录")
    }

    // MARK: 相簿内的影院操作

    /// 相簿 / 网格里的视频所属影院作用域。
    func cinemaScope(for photo: PhotoItem) -> CinemaScope {
        photo.cloudMountID.map { .mount($0) } ?? .local
    }

    func cinemaEntry(for photo: PhotoItem) -> CinemaEntry? {
        cinemaIndexes[cinemaScope(for: photo)]?[photo.id]
    }

    /// 相簿里直接应用手动匹配：没有刮削过的视频也能先匹配，再回影院查看。
    @discardableResult
    func applyCinemaMatch(_ match: CinemaMatch, to photo: PhotoItem) -> CinemaEntry? {
        let scope = cinemaScope(for: photo)
        let folderHint = cinemaIndexes[scope]?[photo.id]?.folderHint
        let parsed = CinemaScraper.parse(filename: photo.displayFilename, folderHint: folderHint)
        let updated = CinemaScraper.manualEntry(photo: photo,
                                                parsed: parsed,
                                                folderHint: folderHint,
                                                match: match)
        cinemaIndexes[scope, default: [:]][updated.id] = updated
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已匹配「\(updated.title)」")
        return updated
    }

    /// 批量匹配剧集：同一部剧一次写给多个视频，季与每集集号由匹配面板确认。
    /// 文件名里解析不到的季集也能用这里的映射补上，避免所有集挤成一条。
    @discardableResult
    func applyCinemaMatch(_ match: CinemaMatch,
                          to photos: [PhotoItem],
                          season: Int?,
                          episodes: [UUID: Int],
                          folderHints: [UUID: String] = [:]) -> Int {
        var scopes: Set<CinemaScope> = []
        var applied = 0
        for photo in photos {
            let scope = cinemaScope(for: photo)
            let folderHint = folderHints[photo.id] ?? cinemaIndexes[scope]?[photo.id]?.folderHint
            var parsed = CinemaScraper.parse(filename: photo.displayFilename, folderHint: folderHint)
            if match.isTV {
                if let season { parsed.season = season }
                if let episode = episodes[photo.id] {
                    parsed.episode = episode
                    parsed.episodeEnd = nil
                }
            }
            let updated = CinemaScraper.manualEntry(photo: photo,
                                                    parsed: parsed,
                                                    folderHint: folderHint,
                                                    match: match)
            cinemaIndexes[scope, default: [:]][updated.id] = updated
            scopes.insert(scope)
            applied += 1
        }
        for scope in scopes {
            persistCinemaIndex(for: scope)
        }
        cinemaFolderRefreshToken &+= 1
        if match.isTV {
            showToast("已匹配「\(match.title)」· 第 \(season ?? 1) 季 · \(applied) 集")
        } else {
            showToast("已匹配「\(match.title)」· \(applied) 个视频")
        }
        return applied
    }

    /// 相簿多选右键「刮削所选」：只处理选中的视频，结果写回各自影院。
    func scrapeCinemaPhotos(_ photos: [PhotoItem]) async {
        let sources = metadataSources()
        guard !sources.isEmpty else {
            showToast("没有可用的刮削源，请检查设置 › 影院")
            return
        }
        let videos = photos.filter { CinemaScraper.isCandidate($0) }
        guard !videos.isEmpty else {
            showToast("所选项目里没有可刮削的视频")
            return
        }

        let scopes = Set(videos.map { cinemaScope(for: $0) })
        var taskIDs: [CinemaScope: UUID] = [:]
        for scope in scopes {
            taskIDs[scope] = beginCinemaTask(for: scope, total: videos.count)
        }
        let cache = CinemaSearchCache()
        let detailsCache = CinemaDetailsCache()
        var matched = 0

        for photo in videos {
            if Task.isCancelled { break }
            let scope = cinemaScope(for: photo)
            let outcome = await CinemaScraper.scrape(photo: photo,
                                                     folderHint: cinemaIndexes[scope]?[photo.id]?.folderHint,
                                                     sources: sources,
                                                     cache: cache,
                                                     detailsCache: detailsCache)
            if let entry = outcome.entry {
                cinemaIndexes[scope, default: [:]][entry.id] = entry
                if entry.matched { matched += 1 }
            }
        }

        for scope in scopes {
            persistCinemaIndex(for: scope)
            let scopeMatched = (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
            if let taskID = taskIDs[scope] {
                finishCinemaTask(taskID,
                                 matched: scopeMatched,
                                 succeeded: true,
                                 message: "相簿内快速刮削：识别 \(matched)/\(videos.count)")
            }
        }
        cinemaFolderRefreshToken &+= 1
        showToast("影院刮削完成：识别 \(matched)/\(videos.count)")
    }

    func setCinemaFavorite(_ value: Bool, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            var state = cinemaUserState(for: id)
            guard state.favorite != value else { continue }
            state.favorite = value
            state.updatedAt = Date()
            cinemaUserStates[id] = state
        }
        persistCinemaUserState()
        showToast(value ? "已加入影院收藏" : "已取消影院收藏")
    }

    func setCinemaWatchlist(_ value: Bool, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            var state = cinemaUserState(for: id)
            guard state.watchlist != value else { continue }
            state.watchlist = value
            state.updatedAt = Date()
            cinemaUserStates[id] = state
        }
        persistCinemaUserState()
        showToast(value ? "已加入想看" : "已移出想看")
    }

    // MARK: 家长控制

    var cinemaParentalEnabled: Bool {
        AppSettings.shared.cinemaParentalLevel != .off
    }

    /// 本次会话未解锁时按分级隐藏；未识别分级的条目默认放行。
    var cinemaParentalLocked: Bool {
        cinemaParentalEnabled && !cinemaParentalUnlocked
    }

    func cinemaIsRestricted(_ entry: CinemaEntry) -> Bool {
        guard cinemaParentalLocked else { return false }
        return !AppSettings.shared.cinemaParentalLevel.allows(certification: entry.certification)
    }

    func cinemaRestrictedCount(for scope: CinemaScope) -> Int {
        guard cinemaParentalLocked else { return 0 }
        return (cinemaIndexes[scope] ?? [:]).values.filter {
            $0.matched && !AppSettings.shared.cinemaParentalLevel.allows(certification: $0.certification)
        }.count
    }

    @discardableResult
    func unlockCinemaParental(pin: String) -> Bool {
        guard CinemaKeychain.verifyPIN(pin) else { return false }
        cinemaParentalUnlocked = true
        return true
    }

    func lockCinemaParental() {
        cinemaParentalUnlocked = false
    }

    // MARK: 智能季集映射（大模型 + 工具）

    /// 把剧名、季、文件列表和用户要求交给已配置的大模型。
    /// 模型可调用三个工具：切换模式、设置偏移、提交最终映射；这里执行工具并回填结果。
    func aiPlanEpisodeMapping(_ request: CinemaAIMatchRequest) async throws -> CinemaAIMatchPlan {
        guard aiConfigurationReady else {
            throw AIError.server("请先在设置 › 助手中填写接口地址与模型")
        }
        guard aiHasAPIKey else { throw AIError.missingKey }

        let modeTool = AIRequestTool(
            name: "set_episode_mode",
            description: "切换集号来源。fileName = 优先用文件名里的数字；sequential = 按文件顺序编号。可选。",
            parameters: [
                "type": "object",
                "properties": ["mode": ["type": "string", "enum": ["fileName", "sequential"]]],
                "required": ["mode"]
            ])
        let offsetTool = AIRequestTool(
            name: "set_episode_offset",
            description: "设置集号偏移：最终集号 = 文件名数字 + offset。例如把 11 当作第 1 集时 offset = -10。可选。",
            parameters: [
                "type": "object",
                "properties": ["offset": ["type": "integer"]],
                "required": ["offset"]
            ])
        let applyTool = AIRequestTool(
            name: "apply_episode_mapping",
            description: "提交每个文件的最终集号。必须覆盖全部文件；同一内容的不同版本共用一个集号。",
            parameters: [
                "type": "object",
                "properties": [
                    "assignments": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer", "description": "文件序号，从 1 开始，对应输入列表"],
                                "episode": ["type": "integer", "description": "集号，>= 1"]
                            ],
                            "required": ["index", "episode"]
                        ]
                    ],
                    "note": ["type": "string", "description": "一句话说明你的排法"]
                ],
                "required": ["assignments"]
            ])

        let systemPrompt = """
        你是影院的季集匹配助手。用户给出一部剧的季号与文件列表，你要为每个文件决定集号。
        规则：
        1. 优先采用文件名里的集号；先剥离 4K/2160p/1080p/HDR/DV/编码/音轨/字幕/高码版等版本标记，再取数字。
        2. 同一内容的不同版本（如 13.mkv 与 13 4K.mkv）必须使用同一个集号。
        3. 缺失集号的文件按相邻集号补齐，保持连续；不要无故重排已有集号。
        4. 用户给了补充要求时优先满足（例如「11 当作第 1 集」→ offset = -10）。
        5. 只处理第 \(request.season) 季，不要输出季号。
        6. 最终必须调用 apply_episode_mapping，一次给出全部 index → episode；不要只回复解释。
        """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let filesJSON = (try? encoder.encode(request.files))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var userText = """
        剧目：\(request.title)
        年份：\(request.year.map(String.init) ?? "未知")
        季：\(request.season)
        文件数：\(request.files.count)
        """
        if let note = request.note, !note.isEmpty {
            userText += "\n补充要求：\(note)"
        }
        userText += "\n文件列表（index 从 1 开始）：\n\(filesJSON)"

        var messages: [AIRequestMessage] = [
            AIRequestMessage(role: "system", text: systemPrompt),
            AIRequestMessage(role: "user", text: userText)
        ]
        var config = aiConfig
        // 几十条映射的 JSON 会超过默认额度，给足空间。
        config.maxTokens = max(config.maxTokens, 4096)

        var mode: String?
        var offset: Int?
        var plan: CinemaAIMatchPlan?

        for _ in 0..<3 {
            let completion = try await AIProviderClient.complete(config: config,
                                                                 apiKey: aiAPIKey,
                                                                 messages: messages,
                                                                 tools: [modeTool, offsetTool, applyTool])

            if completion.toolCalls.isEmpty {
                if let parsed = Self.cinemaAIPlan(from: completion.content, mode: mode, offset: offset) {
                    plan = parsed
                    break
                }
                throw AIError.server("助手没有给出集号映射：\(completion.content.prefix(120))")
            }

            var toolResults: [AIRequestMessage] = []
            var finished = false
            for call in completion.toolCalls {
                let args = Self.cinemaAIArguments(call.arguments)
                switch call.name {
                case "set_episode_mode":
                    mode = args["mode"] as? String
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "已记录模式：\(mode ?? "未识别")",
                                                        toolCallID: call.id))
                case "set_episode_offset":
                    offset = (args["offset"] as? NSNumber)?.intValue
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "已记录偏移：\(offset.map(String.init) ?? "未识别")",
                                                        toolCallID: call.id))
                case "apply_episode_mapping":
                    let assignments = Self.cinemaAIAssignments(from: args)
                    guard !assignments.isEmpty else {
                        toolResults.append(AIRequestMessage(role: "tool",
                                                            text: "assignments 为空或格式不正确，请重新调用并覆盖全部文件",
                                                            toolCallID: call.id))
                        continue
                    }
                    plan = CinemaAIMatchPlan(assignments: assignments,
                                             mode: mode,
                                             offset: offset,
                                             note: args["note"] as? String)
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "已收到 \(assignments.count) 条映射",
                                                        toolCallID: call.id))
                    finished = true
                default:
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "未知工具：\(call.name)",
                                                        toolCallID: call.id))
                }
            }
            if finished, plan != nil { break }
            messages.append(AIRequestMessage(role: "assistant",
                                             text: completion.content,
                                             toolCalls: completion.toolCalls))
            messages.append(contentsOf: toolResults)
        }

        guard var result = plan else {
            throw AIError.server("助手没有给出可用的集号映射，请重试或换一个模型")
        }
        if result.mode == nil { result.mode = mode }
        if result.offset == nil { result.offset = offset }
        return result
    }

    private static func cinemaAIArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func cinemaAIAssignments(from object: [String: Any]) -> [Int: Int] {
        guard let list = object["assignments"] as? [[String: Any]] else { return [:] }
        var result: [Int: Int] = [:]
        for item in list {
            guard let index = (item["index"] as? NSNumber)?.intValue,
                  let episode = (item["episode"] as? NSNumber)?.intValue,
                  index >= 1, episode >= 1 else { continue }
            result[index] = episode
        }
        return result
    }

    /// 模型有时不调工具，直接在正文里回 JSON；这里兜底解析。
    private static func cinemaAIPlan(from content: String,
                                     mode: String?,
                                     offset: Int?) -> CinemaAIMatchPlan? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else { return nil }
        let object = cinemaAIArguments(String(content[start...end]))
        let assignments = cinemaAIAssignments(from: object)
        guard !assignments.isEmpty else { return nil }
        return CinemaAIMatchPlan(assignments: assignments,
                                 mode: mode,
                                 offset: offset,
                                 note: object["note"] as? String)
    }
}
