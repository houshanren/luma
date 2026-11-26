import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 实时画面探测

    func probeState(for channelID: String) -> TVProbeState {
        probeStates[channelID] ?? .idle
    }

    func probeReport(for channelID: String) -> TVProbeReport? {
        probeReports[channelID]
    }

    /// 信号页「探测全部」：把当前源的所有频道按并发上限串进统一任务中心。
    func probeFocusedSourceChannels() {
        for channel in channelsForFocusedSource {
            Task { await requestPreview(for: channel, force: true) }
        }
    }

    /// 卡片出现时调用：缓存未过期就直接标记可用，否则排队抓一帧。
    /// `force` 为信号页的「重新探测」：忽略缓存，覆盖旧截帧与参数。
    func requestPreview(for channel: TVChannel, force: Bool = false) async {
        let id = channel.id
        if force {
            probeStates[id] = .idle
        } else {
            switch probeState(for: id) {
            case .available, .probing, .unavailable:
                return
            case .idle:
                break
            }
            if probeQueue.contains(where: { $0.id == id }) { return }
            if await TVPreviewCache.shared.isFresh(id) {
                probeStates[id] = .available
                return
            }
        }
        if probeQueue.contains(where: { $0.id == id }) { return }
        probeQueue.append(channel)
        probeJobTotal += 1
        startProbeJobIfNeeded(for: channel)
        if let jobID = probeJobID {
            jobCenter?.update(jobID,
                              completed: probeJobCompleted,
                              total: probeJobTotal,
                              message: probeMessage)
        }
        onJobChange?()
        startProbeWorker()
    }

    func retryPreview(for channel: TVChannel) {
        probeStates[channel.id] = .idle
        Task { await requestPreview(for: channel) }
    }

    /// 离开频道页时停掉排队；正在抓的会在下一次进入时重新尝试。
    /// 任务条里按「已完成」收尾，避免留下一直转圈的后台任务。
    func cancelProbes() {
        stopProbeWork()
        finishProbeJob()
    }

    func stopProbeWork() {
        probeQueue.removeAll()
        tasks.cancel(.tvProbe)
        isProbingChannels = false
        for (id, state) in probeStates where state == .probing {
            probeStates[id] = .idle
        }
    }

    /// 第一次有频道排队时登记任务；同一轮探测共用一个任务，进度累加。
    func startProbeJobIfNeeded(for channel: TVChannel) {
        guard probeJobID == nil, let jobCenter else { return }
        let job = SourceJob(sourceID: .television(channel.playlistID),
                            kind: .probe,
                            title: "画面探测")
        probeJobID = jobCenter.begin(job, cancel: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stopProbeWork()
                self.finishProbeJob(cancelled: true)
            }
        })
        onJobChange?()
    }

    func finishProbeJob(cancelled: Bool = false) {
        if let id = probeJobID {
            probeJobID = nil
            // 用户从任务条取消时，任务中心已把状态置为「已取消」，这里只停抓帧；
            // 正常收尾（离开页面 / 队列跑完）才写入完成状态与摘要。
            if !cancelled, jobCenter?.progress[id]?.phase == .running {
                jobCenter?.finish(id, message: probeSummary)
            }
        }
        probeJobTotal = 0
        probeJobCompleted = 0
        probeJobAvailable = 0
        probeJobUnavailable = 0
        // 收尾时把还没落盘的采样补写一次，避免节流窗口内退出页面丢数据。
        flushProbeHistoryNow()
        onJobChange?()
    }

    var probeMessage: String {
        var parts = ["已标注 \(probeJobCompleted) / \(probeJobTotal)"]
        if probeJobAvailable > 0 { parts.append("正常 \(probeJobAvailable)") }
        if probeJobUnavailable > 0 { parts.append("异常 \(probeJobUnavailable)") }
        return parts.joined(separator: " · ")
    }

    var probeSummary: String {
        var parts = ["已标注 \(probeJobCompleted) 个频道"]
        if probeJobAvailable > 0 { parts.append("信号正常 \(probeJobAvailable)") }
        if probeJobUnavailable > 0 { parts.append("信号异常 \(probeJobUnavailable)") }
        return parts.joined(separator: " · ")
    }

    /// 一次画面探测的结果：连同实际出画面的那条线路，供自动换线使用。
    struct ProbeOutcome {
        var report: TVProbeReport
        var lineURL: String?
    }

    /// 探测候选线路：当前线路 → 本频道备用线路 → 其它源的同名频道。
    /// 只探前几条：全都不通的频道已经没得换，探太多只会拖慢整页。
    func probeCandidates(for channel: TVChannel,
                                 siblings: [String: [TVChannel]]) -> [(url: String, headers: [String: String])] {
        var candidates: [(url: String, headers: [String: String])] = []
        var seen = Set<String>()
        for url in channel.streamLines where seen.insert(url).inserted {
            candidates.append((url, channel.headers))
        }
        for sibling in siblings[TVChannel.normalizedName(channel.name)] ?? [] where sibling.id != channel.id {
            guard seen.insert(sibling.streamURL).inserted else { continue }
            candidates.append((sibling.streamURL, sibling.headers))
        }
        // 已锁定的线路排最前；它的请求头必须来自实际所属的源，所以不能提前塞进自己的线路里。
        if let preferred = preferredLines[channel.id],
           let index = candidates.firstIndex(where: { $0.url == preferred }), index > 0 {
            let item = candidates.remove(at: index)
            candidates.insert(item, at: 0)
        }
        return Array(candidates.prefix(4))
    }

    /// 逐条试线路：第一条能出画面就停。后续线路缩短超时，
    /// 避免一个坏源把整轮探测拖成几分钟。
    nonisolated static func probeLines(_ candidates: [(url: String, headers: [String: String])]) async -> ProbeOutcome {
        var lastReport = TVProbeReport()
        for (index, candidate) in candidates.enumerated() {
            guard let url = URL(string: candidate.url) else { continue }
            let report = await TVPreviewProbe.report(url: url,
                                                      headers: candidate.headers,
                                                      timeout: index == 0 ? 12 : 5)
            if report.isSuccess {
                return ProbeOutcome(report: report, lineURL: candidate.url)
            }
            lastReport = report
        }
        if candidates.count > 1 {
            lastReport.error = "\(candidates.count) 条线路均无法播放"
        } else if candidates.isEmpty {
            lastReport.error = "地址无效"
        }
        return ProbeOutcome(report: lastReport, lineURL: nil)
    }

    /// 探测把频道换到能播的线路后，把这条线路锁定为默认：
    /// 点击卡片直接用可用线路起播，不再先撞一次坏源。
    func promoteProbeLines(_ pairs: [(url: String, channel: TVChannel)]) {
        guard !pairs.isEmpty else { return }
        var changed = false
        for (url, channel) in pairs where preferredLines[channel.id] != url {
            preferredLines[channel.id] = url
            changed = true
        }
        if changed { saveLibraryValue(preferredLines, key: Keys.preferredLines) }
    }

    func startProbeWorker() {
        guard !tasks.isRunning(.tvProbe) else { return }
        isProbingChannels = true
        tasks.adopt(.tvProbe, Task { [weak self] in
            while let self, !Task.isCancelled {
                guard !self.probeQueue.isEmpty else { break }
                let count = min(self.probeConcurrency, self.probeQueue.count)
                let batch = Array(self.probeQueue.prefix(count))
                self.probeQueue.removeFirst(count)
                // 一批只发布一次「探测中」：以前每个频道各写一次 state，
                // 整页（侧边栏 + 频道墙 + 顶栏）都会被重新求值一次，滚动就会卡。
                var probing = self.probeStates
                for channel in batch {
                    probing[channel.id] = .probing
                }
                self.probeStates = probing
                // 同名频道的线路索引整批复用：跨源兜底要能查到别的源里同一台。
                let siblingIndex = self.channelsByName()
                let plans = batch.map { channel in
                    (channel, self.probeCandidates(for: channel, siblings: siblingIndex))
                }
                await withTaskGroup(of: (String, ProbeOutcome).self) { group in
                    for (channel, candidates) in plans {
                        group.addTask {
                            (channel.id, await Self.probeLines(candidates))
                        }
                    }
                    // 结果先攒在本地，整批结束时一次性写回：
                    // 状态 / 报告 / 历史各发布一次，任务条也只更新一次。
                    var states = self.probeStates
                    var reports = self.probeReports
                    var results: [(channelID: String, report: TVProbeReport)] = []
                    var promotions: [(url: String, channel: TVChannel)] = []
                    var available = 0
                    var unavailable = 0
                    for await (id, outcome) in group {
                        // 离开频道页后仍可能收到一批迟到的抓帧结果：直接丢弃。
                        if Task.isCancelled { continue }
                        reports[id] = outcome.report
                        results.append((id, outcome.report))
                        if let image = outcome.report.image {
                            await TVPreviewCache.shared.store(image, id: id)
                            states[id] = .available
                            available += 1
                            if let line = outcome.lineURL,
                               let channel = plans.first(where: { $0.0.id == id })?.0,
                               line != channel.streamURL {
                                promotions.append((line, channel))
                            }
                        } else {
                            states[id] = .unavailable
                            unavailable += 1
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.probeReports = reports
                    self.probeStates = states
                    self.promoteProbeLines(promotions)
                    self.recordProbePoints(results)
                    self.probeJobAvailable += available
                    self.probeJobUnavailable += unavailable
                    self.probeJobCompleted += batch.count
                    if let jobID = self.probeJobID {
                        self.jobCenter?.update(jobID,
                                               completed: self.probeJobCompleted,
                                               total: self.probeJobTotal,
                                               message: self.probeMessage)
                    }
                    self.onJobChange?()
                }
            }
            guard let self else { return }
            self.tasks.finish(.tvProbe)
            self.isProbingChannels = false
            self.finishProbeJob()
        })
    }

    /// 「重试失效」：把所有判定失效的频道放回队列重新探测。
    /// 网络 / 代理恢复后不用重启应用，也不用清缓存。
    func retryUnavailableChannels() {
        for channel in channels where probeStates[channel.id] == .unavailable {
            retryPreview(for: channel)
        }
    }

    /// 清空台标与实时画面两类缓存。
    func clearImageCaches() {
        probeStates = [:]
        probeReports = [:]
        stopProbeWork()
        finishProbeJob()
        Task {
            await TVLogoCache.shared.clearAll()
            await TVPreviewCache.shared.clearAll()
        }
    }

    // MARK: - 缓存维护

    /// 清空频道缓存（电视源保留）：下次进入源时重新拉取播放列表。
    func clearChannelCache() {
        database.deleteAllChannels()
        channelCache.removeAll()
        channels = []
        resetEPGCaches()
    }

    /// 清空探测结果：可用性、延迟与截帧记录都归零，不影响频道本身。
    func clearProbeCache() {
        stopProbeWork()
        probeStates = [:]
        probeReports = [:]
    }

    /// 清空节目单缓存：内存派生数据与磁盘快照一起去掉，下次进入节目单重新拉取。
    func clearEPGCache() {
        resetEPGCaches()
        epgPrograms = [:]
        epgChannelNames = [:]
        epgError = nil
        epgUpdatedAt = nil
        TVEPGService.clearDiskCache()
    }
}
