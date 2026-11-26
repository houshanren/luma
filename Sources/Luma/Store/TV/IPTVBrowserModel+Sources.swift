import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 开关与入口

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        database.setSetting("enabled", value ? "1" : "0")
        UserDefaults.standard.set(value, forKey: Keys.enabled)
        if value {
            refreshIfNeeded()
        } else {
            cancelLoading()
            cancelChecks()
        }
    }

    func setHubTab(_ tab: TVHubTab) {
        guard hubTab != tab else { return }
        hubTab = tab
        // 收藏 / 最近只属于频道墙，切到节目回看时不要把筛选带过去。
        if tab == .guide {
            quickFilter = nil
        }
        database.setSetting("hubTab", tab.rawValue)
        UserDefaults.standard.set(tab.rawValue, forKey: Keys.hubTab)
    }

    /// nil 表示「全部频道」；点某个源时只显示该源的频道。
    func focusPlaylist(_ id: UUID?) {
        focusedPlaylistID = id
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
        quickFilter = nil
    }

    /// 侧边栏二级分类：某个源按类型分组后的分类与频道数。
    func categoryGroups(for playlistID: UUID) -> [TVCategory] {
        guard playlist(for: playlistID)?.isEnabled == true,
              let list = channelCache[playlistID], !list.isEmpty else { return [] }
        if let cached = categoryGroupsCache[playlistID], cached.revision == channelRevision {
            return cached.groups
        }
        let grouped = Dictionary(grouping: list, by: \.group)
        let result = grouped.keys
            .sorted { TVGrouping.rank($0) < TVGrouping.rank($1) }
            .map { TVCategory(group: $0, count: grouped[$0]?.count ?? 0) }
        categoryGroupsCache[playlistID] = (channelRevision, result)
        return result
    }

    /// 聚合视图：不限定源，频道墙合并所有已启用源的频道。
    func focusAllSources() {
        focusedPlaylistID = nil
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
        quickFilter = nil
    }

    /// 侧边栏「收藏 / 最近」：跨源聚合，只按快捷筛选收窄。
    func focusQuickFilter(_ filter: TVQuickFilter) {
        focusedPlaylistID = nil
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
        quickFilter = filter
    }

    /// 不再限定源时，侧边栏与「全部频道」保持一致的聚合状态。
    var isShowingAllSources: Bool {
        focusedPlaylistID == nil
    }

    /// 从侧边栏直接打开某个源的某个分类。
    func focusGroup(_ group: String, in playlistID: UUID) {
        focusedPlaylistID = playlistID
        groupingMode = .category
        provinceFilter = nil
        countryFilter = nil
        groupFilter = group
        quickFilter = nil
    }

    func playlistName(for id: UUID) -> String {
        playlists.first(where: { $0.id == id })?.name ?? "电视源"
    }

    func playlist(for id: UUID) -> TVPlaylist? {
        playlists.first(where: { $0.id == id })
    }

    // MARK: - 源管理

    /// 导入一条 M3U：先真正拉一次，确认能解析出频道再保存。
    /// 地址可以是 http(s)，也可以是图库里的本地副本（file://）。
    func addPlaylist(name: String, urlString: String, region: TVRegion) async throws -> TVPlaylist {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file" else {
            throw SourceError.parse("请填写 http / https 开头的 M3U 地址")
        }
        let fallbackName = url.host
            ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : "自定义电视源")
        var playlist = TVPlaylist(name: trimmedName.isEmpty ? fallbackName : trimmedName,
                                  urlString: trimmedURL,
                                  region: region)
        let started = Date()
        let snapshot = try await IPTVService.load(for: playlist)
        let list = snapshot.channels
        playlist.epgURLString = snapshot.epgURLString ?? playlist.epgURLString
        playlist.lastCheckedAt = Date()
        playlist.lastLatencyMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        playlist.lastChannelCount = list.count
        playlists.append(playlist)
        channelCache[playlist.id] = list
        database.replaceChannels(list, for: playlist.id)
        persistPlaylists()
        rebuildChannels()
        return playlist
    }

    // MARK: - 配置导入导出

    /// 导出全部电视源（含 EPG 地址与地区），方便分享给其他人。
    func exportPlaylistBundle() -> Data? {
        guard !playlists.isEmpty else { return nil }
        return SourceTransferJSON.encode(.television, items: playlists)
    }

    /// 从配置文件导入电视源：播放地址相同的条目按「覆盖」处理（名称 / 地区 / 启用状态 / EPG），
    /// 地址不同才新增。导入后自动拉一次频道；EPG 有变化时强制重拉节目单。
    @discardableResult
    func importPlaylistBundle(_ data: Data) -> SourceTransferOutcome {
        switch SourceTransferJSON.decode(TVPlaylist.self, from: data, expecting: .television) {
        case .failure(let error):
            return .failure(error.message)
        case .success(let imported):
            var added: [TVPlaylist] = []
            var applied = 0
            var skipped = 0
            var epgTouched = false
            for var playlist in imported {
                let url = playlist.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else {
                    skipped += 1
                    continue
                }
                let epg = playlist.epgURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = playlists.firstIndex(where: {
                    $0.urlString.trimmingCharacters(in: .whitespacesAndNewlines) == url
                }) {
                    // 同一地址重新导入即覆盖：保留本机 id、频道缓存与最近检测结果，
                    // 名称、地区、启用状态与 EPG 以文件为准。
                    var merged = playlists[index]
                    let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { merged.name = name }
                    merged.region = playlist.region
                    merged.isEnabled = playlist.isEnabled
                    if let epg, !epg.isEmpty, merged.epgURLString != epg {
                        merged.epgURLString = epg
                        epgTouched = true
                    }
                    playlists[index] = merged
                    applied += 1
                } else {
                    // 分享文件里的 id 只对本机有效：新增时重新生成。
                    playlist.id = UUID()
                    playlist.urlString = url
                    added.append(playlist)
                    applied += 1
                    if let epg, !epg.isEmpty { epgTouched = true }
                }
            }
            guard applied > 0 else {
                return SourceTransferOutcome(added: 0, skipped: skipped)
            }
            if !added.isEmpty {
                playlists.append(contentsOf: added)
            }
            persistPlaylists()
            // 频道要联网拉：新增的源按正常刷新流程补齐频道与检测结果。
            if !added.isEmpty { refresh() }
            // 覆盖了 EPG 地址就强制重拉，否则界面上还是旧节目单。
            if epgTouched { loadEPGIfNeeded(force: true) }
            return SourceTransferOutcome(added: applied, skipped: skipped)
        }
    }

    /// 本地 M3U：先复制进图库，再按正常流程登记。
    /// 复制之后原文件被移动或删除都不影响播放；校验失败时删掉副本，不在图库里留垃圾。
    func importPlaylistFile(at fileURL: URL) async throws -> TVPlaylist {
        let fm = FileManager.default
        // 同一个文件重复导入时直接复用已有的本地副本，避免频道在墙上重复出现。
        if let incoming = try? Data(contentsOf: fileURL) {
            for playlist in playlists {
                guard let existing = URL(string: playlist.urlString), existing.isFileURL,
                      let data = try? Data(contentsOf: existing), data == incoming else { continue }
                return playlist
            }
        }

        let directory = LibraryPaths.tvPlaylistsDir
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "m3u" : fileURL.pathExtension
        var target = directory.appendingPathComponent("\(base).\(ext)")
        if fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).\(ext)")
        }
        try fm.copyItem(at: fileURL, to: target)
        do {
            return try await addPlaylist(name: base,
                                         urlString: target.absoluteString,
                                         region: .mainland)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// 批量导入：逐条拉取校验，返回成功条数与失败说明。
    /// 名称按域名自动生成，之后可在源列表里重命名；地址已存在时跳过。
    func addPlaylists(urlStrings: [String],
                      onProgress: ((Int, Int, String) -> Void)? = nil) async -> (added: Int, failures: [String]) {
        var known = Set(playlists.map { $0.urlString.trimmingCharacters(in: .whitespacesAndNewlines) })
        var added = 0
        var failures: [String] = []
        let total = urlStrings.count

        for (index, raw) in urlStrings.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let host = URL(string: trimmed)?.host ?? trimmed
            onProgress?(index + 1, total, host)
            guard known.insert(trimmed).inserted else { continue }
            do {
                _ = try await addPlaylist(name: "",
                                          urlString: trimmed,
                                          region: .mainland)
                added += 1
            } catch {
                let message = (error as? SourceError)?.message ?? error.localizedDescription
                failures.append("\(host)：\(message)")
            }
        }
        return (added, failures)
    }

    func removePlaylist(_ id: UUID) {
        guard playlist(for: id) != nil else { return }
        playlists.removeAll { $0.id == id }
        channelCache[id] = nil
        database.deleteChannels(for: id)
        if focusedPlaylistID == id { focusedPlaylistID = nil }
        persistPlaylists()
        rebuildChannels()
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = trimmed
        persistPlaylists()
    }

    func setPlaylistEnabled(_ id: UUID, enabled value: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEnabled != value else { return }
        playlists[index].isEnabled = value
        persistPlaylists()
        if value {
            refreshIfNeeded(forcePlaylist: id)
        } else {
            channelCache[id] = nil
            rebuildChannels()
        }
    }

    /// 侧边栏拖动：把 `id` 放到 `target` 之前，顺序立即写回 SQLite。
    func movePlaylist(_ id: UUID, before target: UUID) {
        guard id != target,
              let from = playlists.firstIndex(where: { $0.id == id }),
              let to = playlists.firstIndex(where: { $0.id == target }) else { return }
        let playlist = playlists.remove(at: from)
        playlists.insert(playlist, at: from < to ? to - 1 : to)
        persistPlaylists()
    }

    /// 拖到列表末尾：移到最后一位。
    func movePlaylistToEnd(_ id: UUID) {
        guard let from = playlists.firstIndex(where: { $0.id == id }),
              from != playlists.count - 1 else { return }
        let playlist = playlists.remove(at: from)
        playlists.append(playlist)
        persistPlaylists()
    }

    /// 右键菜单上移 / 下移，键盘与鼠标都能排序。
    func movePlaylist(_ id: UUID, by offset: Int) {
        guard let from = playlists.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + offset, 0), playlists.count - 1)
        guard to != from else { return }
        let playlist = playlists.remove(at: from)
        playlists.insert(playlist, at: to)
        persistPlaylists()
    }

    /// 换图库：电视源、顺序与频道缓存都只属于当前图库，重新从新库的 SQLite 读取。
    func reloadForCurrentLibrary() {
        cancelLoading()
        cancelChecks()
        cancelProbes()
        // 探测历史的落盘任务属于上一个图库：换库时直接丢弃，避免写进新库。
        tasks.cancel(.tvProbeHistoryFlush)
        probeHistoryDirty = false
        tasks.cancel(.tvEPG)
        tasks.cancel(.tvEPGHydrate)
        isHydratingEPG = false
        isLoadingEPG = false
        epgPrograms = [:]
        epgChannelNames = [:]
        epgUpdatedAt = nil
        epgError = nil
        resetEPGCaches()
        probeStates = [:]
        probeReports = [:]
        channelCache = [:]
        hasLoaded = false
        guideDayOffset = 0
        error = nil
        sourceError = nil
        failedPlaylistIDs = []

        var restored = database.loadPlaylists()
        // 以前每个图库都会被自动塞进三条内置源：升级后统一移除，之后默认不再接入任何源。
        // 只跑一次；用户自己重新加回来的源是新 id，不受影响。
        if database.setting("builtInsRetired") != "1" {
            let retired = TVPlaylist.retiredBuiltInIDs
            let removed = restored.filter { retired.contains($0.id) }
            if !removed.isEmpty {
                restored.removeAll { retired.contains($0.id) }
                for playlist in removed { database.deleteChannels(for: playlist.id) }
                database.savePlaylists(restored)
            }
            database.setSetting("builtInsRetired", "1")
        }
        // 测试源功能已下线：把之前通过「测试源」加入的三条公开列表一次性清掉。
        if database.setting("testSourcesRetired") != "1" {
            let retired = TVPlaylist.retiredTestSourceURLs
            let removed = restored.filter {
                retired.contains($0.urlString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !removed.isEmpty {
                restored.removeAll {
                    retired.contains($0.urlString.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                for playlist in removed { database.deleteChannels(for: playlist.id) }
                database.savePlaylists(restored)
            }
            database.setSetting("testSourcesRetired", "1")
        }
        playlists = restored
        refreshedAt = database.setting("refreshedAt")
            .flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        focusedPlaylistID = database.setting("focusedPlaylistID").flatMap(UUID.init(uuidString:))
        groupingMode = TVGroupingMode(rawValue: database.setting("groupingMode") ?? "") ?? .category
        provinceFilter = nil
        groupFilter = nil
        countryFilter = nil
        for playlist in playlists where playlist.isEnabled {
            let cached = database.loadChannels(for: playlist.id)
            if !cached.isEmpty { channelCache[playlist.id] = cached }
        }
        rebuildChannels()
        // 收藏 / 最近 / 预约 / 订阅 / 线路 / 探测历史跟着图库走。
        loadLibraryScopedState()
        startRecordingTicker()
        // 启动即把上次的节目单从磁盘垫进内存：打开「节目回看」不用再等网络。
        hydrateEPGFromCache()
    }
}
