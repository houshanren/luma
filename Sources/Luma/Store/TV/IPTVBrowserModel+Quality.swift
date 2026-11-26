import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 线路偏好与 24 小时可用率

    /// 已启用源里按归一化频道名索引的全部频道：打开频道时一次性取走，
    /// 把其它源的同名频道并成备用线路（运营商 IPTV 与公网源互为兜底）。
    func channelsByName() -> [String: [TVChannel]] {
        var index: [String: [TVChannel]] = [:]
        for playlist in playlists where playlist.isEnabled {
            guard let list = channelCache[playlist.id] else { continue }
            for channel in list {
                let key = TVChannel.normalizedName(channel.name)
                guard !key.isEmpty else { continue }
                index[key, default: []].append(channel)
            }
        }
        return index
    }

    /// 优先使用用户锁定的线路；锁定地址已不在可用线路里时自动忽略。
    /// 「可用线路」包含其它源的同名频道：探测自动换线会锁定到别的源那条能播的地址。
    func preferredStreamURL(for channel: TVChannel) -> String? {
        guard let url = preferredLines[channel.id],
              knownLines(for: channel).contains(url) else { return nil }
        return url
    }

    /// 这条频道可用的全部线路：自己的线路 + 其它源同名频道的线路。
    func knownLines(for channel: TVChannel) -> Set<String> {
        if knownLinesRevision != channelRevision { rebuildKnownLinesCache() }
        return knownLinesCache[channel.id] ?? Set(channel.streamLines)
    }

    func rebuildKnownLinesCache() {
        var byName: [String: Set<String>] = [:]
        for playlist in playlists where playlist.isEnabled {
            for item in channelCache[playlist.id] ?? [] {
                let key = TVChannel.normalizedName(item.name)
                guard !key.isEmpty else { continue }
                byName[key, default: []].formUnion(item.streamLines)
            }
        }
        var index: [String: Set<String>] = [:]
        for playlist in playlists where playlist.isEnabled {
            for item in channelCache[playlist.id] ?? [] {
                let key = TVChannel.normalizedName(item.name)
                if let urls = byName[key] { index[item.id] = urls }
            }
        }
        knownLinesCache = index
        knownLinesRevision = channelRevision
    }

    func setPreferredLine(_ url: String?, for channel: TVChannel) {
        if let url, channel.streamLines.contains(url) {
            preferredLines[channel.id] = url
        } else {
            preferredLines.removeValue(forKey: channel.id)
        }
        saveLibraryValue(preferredLines, key: Keys.preferredLines)
    }

    func recordProbePoint(channelID: String, report: TVProbeReport) {
        recordProbePoints([(channelID, report)])
    }

    /// 一批采样统一落盘：整批只发布一次 `probeHistory`、只写一次磁盘。
    /// 单个频道逐个写时，322 个频道等于把整份历史编码 322 次，正是加载期间的卡顿来源。
    func recordProbePoints(_ results: [(channelID: String, report: TVProbeReport)]) {
        guard !results.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for item in results {
            var points = probeHistory[item.channelID] ?? []
            points.append(TVProbePoint(date: item.report.updatedAt,
                                       success: item.report.isSuccess,
                                       latencyMilliseconds: item.report.ttfbMilliseconds))
            points.removeAll { $0.date < cutoff }
            if points.count > 48 { points.removeFirst(points.count - 48) }
            probeHistory[item.channelID] = points
        }
        probeHistoryDirty = true
        scheduleProbeHistoryFlush()
    }

    /// 采样结果合并后再落盘：连续几批探测只写一次磁盘，避免编码整份历史卡住主线程。
    func scheduleProbeHistoryFlush() {
        guard !tasks.isRunning(.tvProbeHistoryFlush) else { return }
        tasks.adopt(.tvProbeHistoryFlush, Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            self.tasks.finish(.tvProbeHistoryFlush)
            self.flushProbeHistoryNow()
        })
    }

    func flushProbeHistoryNow() {
        tasks.cancel(.tvProbeHistoryFlush)
        guard probeHistoryDirty else { return }
        probeHistoryDirty = false
        saveLibraryValue(probeHistory, key: Keys.probeHistory)
    }

    func probePoints(for channelID: String) -> [TVProbePoint] {
        probeHistory[channelID] ?? []
    }

    /// 24 小时内成功次数 / 总次数；没有采样时返回 nil。
    func availability(for channelID: String) -> Double? {
        let points = probePoints(for: channelID)
        guard !points.isEmpty else { return nil }
        return Double(points.filter(\.success).count) / Double(points.count)
    }

    /// 进入信号页时的低频巡检：收藏频道先探，其余只补 6 小时前的旧结果。
    func patrolStaleSignals() {
        guard enabled, !isProbingChannels else { return }
        let now = Date()
        var targets: [TVChannel] = []
        for channel in channelsForFocusedSource {
            if let report = probeReports[channel.id] {
                if now.timeIntervalSince(report.updatedAt) > 6 * 3600 {
                    targets.append(channel)
                }
            } else if favoriteIDs.contains(channel.id) {
                targets.append(channel)
            }
        }
        if targets.count > 24 { targets = Array(targets.prefix(24)) }
        for channel in targets {
            Task { await requestPreview(for: channel, force: true) }
        }
    }
}
