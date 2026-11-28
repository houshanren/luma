import Foundation
import SwiftUI
import PlaybackCore
import LumaContentCore
import LumaCore

/// 网络电视播放：把频道接成查看器里的一个虚拟视频。
/// 直播不看续播、不写进度；关闭查看器即释放上下文。
extension LibraryStore {
    /// 打开频道时把当前列表里的所有频道一起装进查看器：
    /// 顶栏序号变成「当前 / 总数」，← / → 与工具栏的上一台 / 下一台直接换台。
    func openTVChannel(_ channel: TVChannel) {
        finishTVPlayback()
        tvModel.recordRecent(channel)
        let list = tvModel.visibleChannels.isEmpty ? [channel] : tvModel.visibleChannels
        var photos: [PhotoItem] = []
        var channels: [UUID: TVChannel] = [:]
        let siblingIndex = tvModel.channelsByName()
        for item in list {
            var resolved = item
            // 把其它源里的同名频道并成备用线路：运营商 IPTV 的地址常只在该网络可用，
            // 主线路超时后要能自动顺延到公网源，而不是整个频道报「无可用资源」。
            let siblings = (siblingIndex[TVChannel.normalizedName(resolved.name)] ?? [])
                .filter { $0.id != resolved.id }

            // 汇总这个台的全部线路，并记住每条线路属于哪个接入平台：
            // 播放器的「线路」菜单据此按平台分组，平台 1 有 3 条、平台 2 有 2 条时会全部列出。
            var catalog: [TVLineInfo] = []
            var seenURLs = Set<String>()
            func register(_ url: String,
                          headers: [String: String],
                          isHLS: Bool,
                          sourceID: UUID,
                          sourceName: String,
                          channelName: String,
                          index: Int,
                          count: Int) {
                guard seenURLs.insert(url).inserted else { return }
                catalog.append(TVLineInfo(url: url,
                                          sourceID: sourceID,
                                          sourceName: sourceName,
                                          channelName: channelName,
                                          lineIndex: index + 1,
                                          lineCount: count))
                tvLineMetadata[url] = TVLineMetadata(headers: headers, isHLS: isHLS)
            }

            let ownSource = tvModel.playlistName(for: item.playlistID)
            for (index, url) in item.streamLines.enumerated() {
                register(url,
                         headers: item.headers,
                         isHLS: index == 0 ? item.isHLS : TVLineMetadata.inferredHLS(for: url),
                         sourceID: item.playlistID,
                         sourceName: ownSource,
                         channelName: item.name,
                         index: index,
                         count: item.streamLines.count)
            }
            for sibling in siblings {
                let sourceName = tvModel.playlistName(for: sibling.playlistID)
                for (index, url) in sibling.streamLines.enumerated() {
                    register(url,
                             headers: sibling.headers,
                             isHLS: index == 0 ? sibling.isHLS : TVLineMetadata.inferredHLS(for: url),
                             sourceID: sibling.playlistID,
                             sourceName: sourceName,
                             channelName: sibling.name,
                             index: index,
                             count: sibling.streamLines.count)
                }
            }

            // 用户在信号详情里锁定的默认线路优先（探测自动换线可能锁到别的源）：
            // 换线时连请求头与协议一起换，否则会拿错 UA 去请求。
            if let preferred = tvModel.preferredStreamURL(for: item) {
                resolved.streamURL = preferred
                if let meta = tvLineMetadata[preferred] {
                    resolved.headers = meta.headers
                    resolved.isHLS = meta.isHLS
                }
            }
            resolved.alternateStreamURLs = catalog.map(\.url).filter { $0 != resolved.streamURL }
            resolved.lineCount = catalog.count
            var photo = PhotoItem(filename: "tv-\(resolved.id).m3u8",
                                  originalName: resolved.name,
                                  capturedAt: Date(),
                                  pixelWidth: 1920,
                                  pixelHeight: 1080,
                                  fileSize: 0,
                                  kind: .video)
            photo.title = resolved.name
            photo.source = .cloud
            photo.cloudPath = resolved.streamURL
            photos.append(photo)
            channels[photo.id] = resolved
            tvLineCatalogs[photo.id] = catalog
        }
        guard let target = photos.first(where: { channels[$0.id]?.id == channel.id }) ?? photos.first else {
            return
        }
        tvPlaybackPhotos = photos
        tvPlaybackChannels = channels
        for photoID in channels.keys { resetTVLiveRetry(for: photoID) }
        openViewer(target.id, context: photos)
    }

    func tvPlaybackPhoto(for id: UUID) -> PhotoItem? {
        tvPlaybackPhotos.first(where: { $0.id == id })
    }

    /// 频道带 / 数字键换台：沿用当前播放器里的频道上下文，不再重建列表。
    func switchTVChannel(_ channel: TVChannel) {
        guard let target = tvPlaybackChannels.first(where: { $0.value.id == channel.id }) else {
            openTVChannel(channel)
            return
        }
        tvModel.recordRecent(channel)
        resetTVLiveRetry(for: target.key)
        viewerIndexCache = nil
        viewerPositionCache = nil
        withAnimation(AppSettings.shared.motion.overlay) {
            viewerID = target.key
        }
        selection = [target.key]
        recordView(target.key)
    }

    func tvPlaybackChannel(for id: UUID) -> TVChannel? {
        tvPlaybackChannels[id]
    }

    func finishTVPlayback() {
        tvPlaybackPhotos = []
        tvPlaybackChannels = [:]
        tvCatchupPhotoIDs = []
        tvLiveRetryStates = [:]
        tvLineFailureNotes = [:]
        tvLineMetadata = [:]
        tvLineCatalogs = [:]
    }

    // MARK: - 线路切换

    /// 当前线路在「全部平台线路」里的位置：按打开时的稳定顺序，
    /// 换线后读数仍是「3/5」，不会因为当前线路被提到最前而永远显示 1/5。
    func tvLineIndex(for photoID: UUID) -> Int {
        guard let channel = tvPlaybackChannels[photoID] else { return 0 }
        if let index = tvLineCatalog(for: photoID).firstIndex(where: { $0.url == channel.streamURL }) {
            return index
        }
        return channel.streamLines.firstIndex(of: channel.streamURL) ?? 0
    }

    func tvLineCount(for photoID: UUID) -> Int {
        let catalogCount = tvLineCatalog(for: photoID).count
        return catalogCount > 0 ? catalogCount : (tvPlaybackChannels[photoID]?.streamLines.count ?? 1)
    }

    /// 这个台可切换的全部线路：带平台归属，按打开时的顺序稳定排列。
    func tvLineCatalog(for photoID: UUID) -> [TVLineInfo] {
        tvLineCatalogs[photoID] ?? []
    }

    /// 按接入平台分组的线路：播放器「线路」菜单直接渲染它。
    func tvLineGroups(for photoID: UUID) -> [TVLineGroup] {
        var positions: [UUID: Int] = [:]
        var groups: [TVLineGroup] = []
        for line in tvLineCatalog(for: photoID) {
            if let position = positions[line.sourceID] {
                groups[position].lines.append(line)
            } else {
                positions[line.sourceID] = groups.count
                groups.append(TVLineGroup(sourceID: line.sourceID,
                                          sourceName: line.sourceName,
                                          lines: [line]))
            }
        }
        return groups
    }

    /// 菜单与提示里的线路名：「我的 IPTV · 线路 2」。
    func tvLineLabel(for photoID: UUID, url: String) -> String {
        guard let line = tvLineCatalog(for: photoID).first(where: { $0.url == url }) else {
            return "线路"
        }
        return line.lineCount > 1 ? "\(line.sourceName) · 线路 \(line.lineIndex)" : line.sourceName
    }

    /// ← / → 或 OSD 线路按钮：在候选线路间循环。
    @discardableResult
    func switchTVLine(for photoID: UUID, delta: Int) -> Bool {
        guard let channel = tvPlaybackChannels[photoID] else { return false }
        let lines = channel.streamLines
        guard lines.count > 1 else {
            showToast("这个频道只有一条线路")
            return false
        }
        let catalog = tvLineCatalog(for: photoID)
        let order = catalog.isEmpty ? lines : catalog.map(\.url)
        let current = tvLineIndex(for: photoID)
        let next = (current + delta + order.count) % order.count
        let url = order[next]
        resetTVLiveRetry(for: photoID, startURL: url)
        applyTVLine(url: url, for: photoID)
        showToast("已切换到 \(tvLineLabel(for: photoID, url: url))")
        return true
    }

    /// OSD / 工具栏线路面板：直接点选某一条线路（可能来自别的接入平台）。
    @discardableResult
    func selectTVLine(url: String, for photoID: UUID) -> Bool {
        guard let channel = tvPlaybackChannels[photoID],
              channel.streamLines.contains(url),
              url != channel.streamURL else {
            Diagnostics.record("换线忽略 \(tvPlaybackChannels[photoID]?.name ?? "-")："
                               + "目标线路不在当前频道线路里，或已经是当前线路")
            return false
        }
        resetTVLiveRetry(for: photoID, startURL: url)
        applyTVLine(url: url, for: photoID)
        showToast("已切换到 \(tvLineLabel(for: photoID, url: url))")
        return true
    }

    /// 失败卡片的手动重试：从当前线路重新计算完整三轮，并用新 token 重新装片。
    func retryTVLivePlayback(for photoID: UUID) {
        guard let channel = tvPlaybackChannels[photoID], !channel.isCatchUp else { return }
        resetTVLiveRetry(for: photoID)
        applyTVLine(url: channel.streamURL, for: photoID)
    }

    /// 只有当前装片真正就绪才记住线路；旧装片迟到的就绪事件会被 token 和 URL 拒绝。
    func rememberTVLiveLine(for photoID: UUID, token: Int, url: String) {
        guard let channel = tvPlaybackChannels[photoID], !channel.isCatchUp,
              channel.streamURL == url,
              tvLineTokens[photoID, default: 0] == token,
              tvLiveRetryStates[photoID]?.currentURL == url,
              tvModel.preferredLines[channel.id] != url else { return }
        tvModel.setPreferredLine(url, for: channel)
        Diagnostics.record("电视记住可用线路 \(channel.name) → \(tvLineLabel(for: photoID, url: url))")
    }

    func tvLiveRetryExhaustedMessage(for photoID: UUID) -> String? {
        guard let state = tvLiveRetryStates[photoID],
              state.currentURL == nil, state.failureCount > 0 else { return nil }
        return state.lines.count > 1
            ? "全部线路已尝试 \(state.maxRounds) 轮，仍无法播放"
            : "当前线路已尝试 \(state.maxRounds) 次，仍无法播放"
    }

    /// 只接受当前直播装片的失败；三轮包含首次尝试，单线路也会重新装片三次。
    @discardableResult
    func advanceTVLineAfterFailure(for photoID: UUID, token: Int, url: String,
                                   reason: String? = nil) -> TVLiveLineRetryFailure {
        guard let channel = tvPlaybackChannels[photoID], !channel.isCatchUp,
              channel.streamURL == url,
              tvLineTokens[photoID, default: 0] == token,
              var state = tvLiveRetryStates[photoID],
              state.currentURL == url else { return .ignored }
        let result = state.recordFailure(token: "\(photoID.uuidString)-\(token)")
        guard result != .ignored else { return .ignored }
        tvLiveRetryStates[photoID] = state
        var notes = tvLineFailureNotes[photoID] ?? [:]
        notes[url] = reason ?? "无响应"
        tvLineFailureNotes[photoID] = notes
        switch result {
        case .next(let next):
            applyTVLine(url: next, for: photoID)
            if next == url {
                showToast("\(tvLineLabel(for: photoID, url: url)) 失败，正在重试")
            } else {
                showToast("\(tvLineLabel(for: photoID, url: url)) 失败，已切换到 "
                          + tvLineLabel(for: photoID, url: next))
            }
        case .exhausted:
            Diagnostics.record("电视线路三轮失败 \(channel.name)：\(tvLineFailureSummary(for: photoID))")
            showToast(tvLiveRetryExhaustedMessage(for: photoID) ?? "这个频道暂时无法播放")
        case .ignored:
            break
        }
        return result
    }

    private func resetTVLiveRetry(for photoID: UUID, startURL: String? = nil) {
        guard let channel = tvPlaybackChannels[photoID], !channel.isCatchUp else {
            tvLiveRetryStates.removeValue(forKey: photoID)
            return
        }
        let catalog = tvLineCatalog(for: photoID)
        let order = catalog.isEmpty ? channel.streamLines : catalog.map(\.url)
        tvLiveRetryStates[photoID] = TVLiveLineRetryState(lines: order,
                                                          startURL: startURL ?? channel.streamURL)
        tvLineFailureNotes[photoID] = [:]
    }

    /// 失败卡片用：把已记下的失败原因拼成「我的 IPTV · 线路 1 超时、APTV · 线路 2 返回 403」。
    func tvLineFailureSummary(for photoID: UUID) -> String {
        guard let notes = tvLineFailureNotes[photoID], !notes.isEmpty else { return "" }
        let order = tvLineCatalog(for: photoID).map(\.url)
        let known = order.filter { notes[$0] != nil }
        let unknown = notes.keys.filter { !order.contains($0) }.sorted()
        return (known + unknown).map {
            "\(tvLineLabel(for: photoID, url: $0)) \(notes[$0] ?? "无响应")"
        }.joined(separator: "、")
    }

    private func applyTVLine(url: String, for photoID: UUID) {
        guard var channel = tvPlaybackChannels[photoID],
              channel.streamLines.contains(url) else { return }
        channel.streamURL = url
        // 不同线路的协议与请求头可能不同：切到 HTTP-FLV 线路时必须把 isHLS 关掉，
        // 否则播放器会继续按 HLS 交给 AVPlayer，换线后依然播不出来。
        if let meta = tvLineMetadata[url] {
            channel.headers = meta.headers
            channel.isHLS = meta.isHLS
        } else {
            channel.isHLS = TVLineMetadata.inferredHLS(for: url)
        }
        tvPlaybackChannels[photoID] = channel
        if let photoIndex = tvPlaybackPhotos.firstIndex(where: { $0.id == photoID }) {
            tvPlaybackPhotos[photoIndex].cloudPath = url
        }
        // 代次自增 → VideoPlayerStage 的 loadKey 变化，重新装片。
        tvLineTokens[photoID, default: 0] += 1
        Diagnostics.record("电视换线 \(channel.name) → \(tvLineLabel(for: photoID, url: url))")
    }

    /// 从节目单 / 回看页打开一档过去的节目。
    /// 回看走单条点播上下文，不把频道列表装进播放器，避免误触换台。
    func openTVCatchup(_ channel: TVChannel, program: TVEPGProgram) {
        guard let template = channel.catchUpSource,
              let url = TVCatchupURL.build(template: template,
                                           program: program,
                                           channel: channel) else {
            return
        }
        finishTVPlayback()

        var catchupChannel = channel
        catchupChannel.streamURL = url.absoluteString
        catchupChannel.isCatchUp = true
        // catchup-source 基本都是 HLS（playseek 模板），地址里不一定带 .m3u8。
        // 不标成 HLS 会被当成直播 FLV 走转封装滑动窗口：回看没有真实时长，
        // 分片很快被挤掉，播放器就会不断重连、跳着播。
        let target = url.absoluteString.lowercased()
        catchupChannel.isHLS = !(target.contains(".flv") || target.contains(".mp4")
                                 || target.contains(".ts"))
        // 回看地址是单独拼出来的，直播线路在这里没有意义：
        // 留着会让「线路 N/M」菜单和失败顺延把回看切回直播地址。
        catchupChannel.alternateStreamURLs = []
        catchupChannel.lineCount = 1

        var photo = PhotoItem(filename: "tv-catchup-\(program.id).m3u8",
                              originalName: program.title,
                              capturedAt: program.start,
                              pixelWidth: 1920,
                              pixelHeight: 1080,
                              fileSize: 0,
                              kind: .video)
        photo.title = program.title
        photo.source = .cloud
        photo.cloudPath = url.absoluteString
        // 节目单时长：播放器还没解析出真实片长时，回看进度条用它兜底，
        // 否则顶栏读数会一直停在 `00:00`，进度条也画不出比例。
        if program.duration > 1 { photo.duration = program.duration }

        tvPlaybackPhotos = [photo]
        tvPlaybackChannels = [photo.id: catchupChannel]
        tvCatchupPhotoIDs = [photo.id]
        openViewer(photo.id, context: [photo])
    }

    /// 直播流：请求头随频道一起带进播放器。
    /// 不少 IPTV 线路是 `live.php?id=…` 这类无扩展名地址，实际返回 HLS；
    /// 只按扩展名判定会把它交给 ffmpeg，报「Invalid data」。这里先探一次内容再决定播放器。
    func resolveTVStream(for photoID: UUID) async -> ResolvedStream? {
        guard var channel = tvPlaybackChannel(for: photoID),
              URL(string: channel.streamURL) != nil else { return nil }
        // 直播首播：候选线路的镜像质量差别很大（本机实测凤凰中文：225.9 的 m3u8 返回 502、
        // 它的 FLV 也几乎不响应，而 227.97 的 FLV 正常）。按列表顺序 / 上次锁定的线路固定播，
        // 就会一直卡在一台坏主机上。这里每次起播前并发抓一次首字节：
        // HLS 优先（能原生秒开），没有可用的 HLS 再比 FLV；选中的线路记成偏好。
        if !channel.isCatchUp,
           let fastest = await fastestTVLiveLine(for: channel),
           fastest != channel.streamURL {
            channel.streamURL = fastest
            if let meta = tvLineMetadata[fastest] {
                channel.headers = meta.headers
                channel.isHLS = meta.isHLS
            } else {
                channel.isHLS = TVLineMetadata.inferredHLS(for: fastest)
            }
            tvPlaybackChannels[photoID] = channel
            if let index = tvPlaybackPhotos.firstIndex(where: { $0.id == photoID }) {
                tvPlaybackPhotos[index].cloudPath = fastest
            }
            resetTVLiveRetry(for: photoID)
            tvModel.setPreferredLine(fastest, for: channel)
            Diagnostics.record("电视最快线路 \(channel.name) → \(tvLineLabel(for: photoID, url: fastest))")
        }
        guard let url = URL(string: channel.streamURL) else { return nil }
        var isHLS = channel.isHLS
        if !isHLS, await Self.probeIsHLS(url: url, headers: channel.headers) {
            isHLS = true
            tvPlaybackChannels[photoID]?.isHLS = true
            tvLineMetadata[channel.streamURL] = TVLineMetadata(headers: channel.headers, isHLS: true)
        }
        return ResolvedStream(url: url,
                              headers: channel.headers,
                              isHLS: isHLS,
                              mode: tvCatchupPhotoIDs.contains(photoID) ? .vod : .live)
    }

    /// 在候选线路里挑最好的一条：HLS 优先（AVPlayer 原生播放，起播最快），
    /// 没有可用的 HLS 再退到响应最快的 FLV / TS（要 ffmpeg 转封装，慢但能播）。
    /// 两边都没有响应时返回 nil，沿用当前线路。
    private func fastestTVLiveLine(for channel: TVChannel) async -> String? {
        let lines = Array(channel.streamLines.prefix(5))
        guard lines.count > 1 else { return nil }
        var hlsBest: (url: String, ms: Int)?
        var otherBest: (url: String, ms: Int)?
        await withTaskGroup(of: (String, Bool, Int?).self) { group in
            for url in lines {
                let isHLS = tvLineMetadata[url]?.isHLS ?? TVLineMetadata.inferredHLS(for: url)
                let headers = channel.headers
                group.addTask { (url, isHLS, await Self.tvLineLatency(url: url, headers: headers)) }
            }
            for await (url, isHLS, ms) in group {
                guard let ms else { continue }
                if isHLS {
                    if hlsBest == nil || ms < hlsBest!.ms { hlsBest = (url, ms) }
                    // 已经够快就不等其它镜像：再快也就差几十毫秒，用户感知不到。
                    if ms <= 400 { break }
                } else if otherBest == nil || ms < otherBest!.ms {
                    otherBest = (url, ms)
                }
            }
            group.cancelAll()
        }
        return hlsBest?.url ?? otherBest?.url
    }

    /// 抓一次线路首字节的耗时。
    ///
    /// HLS 必须拿到 `#EXTM3U` 才算可用（避免把 502 / 403 页面当线路）；
    /// FLV / TS 只要连上并返回了数据即可（魔术字里没有可依赖的文本，
    /// 但要排除 HTML 错误页）。0.8 秒内没响应就当不可用。
    private nonisolated static func tvLineLatency(url: String, headers: [String: String]) async -> Int? {
        guard let target = URL(string: url) else { return nil }
        let expectsHLS = TVLineMetadata.inferredHLS(for: url)
        var request = URLRequest(url: target)
        request.timeoutInterval = 0.8
        // 直播播放列表禁止缓存：否则第二次测速会直接命中本地缓存，测出「0 毫秒」的假象。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let started = Date()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode) else { return nil }
            var collected = Data()
            var iterator = bytes.makeAsyncIterator()
            while let byte = try await iterator.next() {
                collected.append(byte)
                if collected.count >= 64 { break }
            }
            guard !collected.isEmpty else { return nil }
            let head = String(decoding: collected, as: UTF8.self)
            if expectsHLS || head.contains("#EXTM3U") {
                guard head.contains("#EXTM3U") else { return nil }
            } else {
                // FLV / TS：HTML 说明拿到的是错误页，不是流。
                let lower = head.lowercased()
                guard !lower.contains("<html"), !lower.contains("<!doctype") else { return nil }
            }
            return Int(Date().timeIntervalSince(started) * 1000)
        } catch {
            return nil
        }
    }

    /// 用一次小范围 GET 判断地址是否返回 HLS 播放列表：先看 Content-Type，再看首行 `#EXTM3U`。
    private static func probeIsHLS(url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        if let type = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           type.contains("mpegurl") {
            return true
        }
        return String(decoding: data.prefix(4096), as: UTF8.self).contains("#EXTM3U")
    }
}
