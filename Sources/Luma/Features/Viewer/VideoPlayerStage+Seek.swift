import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore
import LumaCore

extension VideoPlayerStage {
    // MARK: - 跳转与流重建

    /// 云盘边下边播的已生成区间随 ffmpeg 进度增长，拖到未生成位置时用 -ss 重新起流。
    func seekPlayback(to target: Double) {
        model.requestSeek(to: target)
    }

    /// 电视回看：首播通常把 playseek 地址直接交给 AVPlayer，它只能在很窄的
    /// seekable 窗口里跳；拖到窗口外会被夹回直播边缘（看起来就是「拖不过去」）。
    /// 这里改用 ffmpeg 从目标时间重建流，之后所有跳转都由会话的 -ss 接管。
    func seekCatchupByRestarting(at target: Double) {
        guard let sourceURL, FFmpeg.isAvailable else {
            // 不能走 requestSeek：会再次命中 seekRouter 形成递归。
            model.seek(to: target)
            return
        }
        guard target.isFinite else { return }
        isPreparing = true
        waitingStage = .starting
        let wasPlaying = model.isPlaying
        let generation = loadGeneration
        let audioIndex = playbackSession.streamAudioIndex
        let clamped = max(0, target)
        Diagnostics.record("回看重建流 \(photo.originalName) → \(Int(clamped))s（ffmpeg 直连）")
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: wasPlaying,
                                               offset: max(0, clamped - 1),
                                               resumeAt: clamped,
                                               mode: .remux,
                                               audioIndex: audioIndex)
            guard generation == loadGeneration else { return }
            if !started, failureMessage == nil {
                // 起流失败也别把用户卡在等待层：退回播放器内的就近跳转。
                model.seek(to: clamped)
                if wasPlaying { model.play() }
                isPreparing = false
            }
        }
    }

    /// 拖动进度条时的预览落帧：越界范围由 model.scrubGuard 统一拦截。
    func scrubPlayback(to target: Double) {
        model.scrub(to: target)
    }

    /// 播放中切换 HDR 色调映射：按新策略在当前时间点重建一次流。
    /// 重建后 streamMode 由新会话接管，之后所有跳转 / 拖动 / 回退都沿用同一模式，
    /// 不会出现「看了一半映射画面、下一跳又回到未映射」。
    func setHDRToneMapping(_ enabled: Bool) {
        guard hdrToneMapOverride != enabled else { return }
        hdrToneMapOverride = enabled
        refreshHDRToneMapState()
        guard sourceURL != nil, hasLoadedVideo else { return }
        let target = model.currentTime
        let wasPlaying = model.wantsPlayback
        let generation = loadGeneration
        let audioIndex = playbackSession.streamAudioIndex
        store.showToast(enabled ? "已开启 HDR 色调映射（本次播放）" : "已关闭 HDR 色调映射（本次播放）")
        playbackSession.stop()
        hasLoadedVideo = false
        isPreparing = true
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: wasPlaying,
                                               offset: max(0, target - 1),
                                               resumeAt: target > 1 ? target : nil,
                                               mode: enabled ? .transcode : .remux,
                                               audioIndex: audioIndex)
            if !started, generation == loadGeneration {
                // 关掉映射后系统仍解不了（极少见）：退回原位置与播放状态。
                model.seek(to: target)
                if wasPlaying { model.play() }
            }
            isPreparing = false
        }
    }

    /// 蓝光多角度：按新视角在当前时间点重建流。
    /// `-angle` 只作用于 bluray 输入；重建后后续跳转 / 拖动沿用同一视角。
    func setAngle(_ angle: Int) {
        let target = min(max(1, angle), max(1, angleCount))
        guard target != selectedAngle else { return }
        selectedAngle = target
        ui.updateAngles(count: angleCount, selected: target)
        guard sourceURL != nil, hasLoadedVideo else { return }
        let position = model.currentTime
        let wasPlaying = model.wantsPlayback
        let generation = loadGeneration
        let mode: VideoStreamSession.Mode = playbackSession.streamSession != nil
            ? playbackSession.streamMode
            : (needsToneMapping(playbackProbe) ? .transcode : .remux)
        store.showToast("角度 \(target)/\(angleCount)")
        playbackSession.stop()
        hasLoadedVideo = false
        isPreparing = true
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: wasPlaying,
                                               offset: max(0, position - 1),
                                               resumeAt: position > 1 ? position : nil,
                                               mode: mode,
                                               audioIndex: playbackSession.streamAudioIndex)
            if !started, generation == loadGeneration {
                model.seek(to: position)
                if wasPlaying { model.play() }
            }
            isPreparing = false
        }
    }

    func switchAudio(to index: Int) {
        guard playbackSession.streamSession != nil,
              index != playbackSession.streamAudioIndex else { return }
        let target = model.currentTime
        playbackSession.previewAudioIndex(index)
        refreshAudioChoices()
        restartStreaming(at: target)
    }

    /// 把 HLS 音轨或原生 AV 音轨统一映射成菜单里的选项。
    func refreshAudioChoices() {
        // 多音轨会话：AVPlayer 给的选项顺序就是 master 里的音轨顺序，可直接换轨。
        // 菜单标题优先用探测到的语言 / 声道 / 编码；AVPlayer 对 HLS 音轨常只给出
        // "Unknown" 或 audio_N，直接展示会分不清哪条是国语、哪条是英语。
        if playbackSession.isMultiAudio, !model.audioOptions.isEmpty {
            let choices = model.audioOptions.enumerated().map { offset, option in
                let title = probeAudioTracks.indices.contains(offset)
                    ? probeAudioTracks[offset].displayName
                    : option.displayName
                return VideoPlaybackUI.AudioChoice(index: offset, title: title)
            }
            ui.updateAudio(choices: choices,
                           selected: preferredAudioPosition(in: probeAudioTracks)
                               ?? model.currentAudioIndex)
            return
        }
        if streamSession != nil {
            if !probeAudioTracks.isEmpty {
                ui.updateAudio(choices: probeAudioTracks.map {
                    VideoPlaybackUI.AudioChoice(index: $0.ordinal, title: $0.displayName)
                }, selected: preferredAudioPosition(in: probeAudioTracks)
                    .map { probeAudioTracks[$0].ordinal } ?? streamAudioIndex)
            } else {
                let count = max(0, probeAudioCount)
                ui.updateAudio(choices: (0..<count).map {
                    VideoPlaybackUI.AudioChoice(index: $0, title: "音轨 \($0 + 1)")
                }, selected: streamAudioIndex)
            }
        } else {
            let choices = model.audioOptions.enumerated().map {
                VideoPlaybackUI.AudioChoice(index: $0.offset, title: $0.element.displayName)
            }
            let selected = model.selectedAudio.flatMap { model.audioOptions.firstIndex(of: $0) } ?? 0
            ui.updateAudio(choices: choices, selected: selected)
        }
    }

    /// 默认音轨偏好：按语言 / 标题挑一条，命不中时回落到原逻辑。
    func preferredAudioPosition(in tracks: [AudioTrackInfo]) -> Int? {
        let preference = settings.videoPreferredAudio
        guard preference != "original", !tracks.isEmpty else { return nil }
        let wanted = preference == "zh"
            ? ["zh", "chi", "cmn", "cn", "yue"]
            : ["en", "eng"]
        return tracks.firstIndex { track in
            let code = (track.language ?? "").lowercased()
            if wanted.contains(where: { code.hasPrefix($0) }) { return true }
            let title = (track.title ?? "").lowercased()
            return preference == "zh"
                ? (title.contains("国") || title.contains("中") || title.contains("粤"))
                : (title.contains("english") || title.contains("英语"))
        }
    }

    func restartStreaming(at target: Double) {
        // 重建流期间又拖到了别处：只记最后一个目标，当前会话就绪后再追过去。
        // 连续拖动不能排队拉起多个 ffmpeg，也不能拿旧会话的时间轴去 seek。
        if playbackSession.isRestartingStream {
            playbackSession.queueRestart(target)
            return
        }
        guard playbackSession.streamSession != nil else {
            model.seek(to: target)
            return
        }
        isPreparing = true
        // 旧流先停住音画：新位置的分片要一会儿才好，继续播旧位置只会让人以为没跳过去。
        let wasPlaying = model.isPlaying
        model.pause()
        let generation = loadGeneration
        let mode = playbackSession.streamMode
        let audio = playbackSession.streamAudioIndex
        let seekStartedAt = Date()
        Task { @MainActor in
            let outcome = await playbackSession.restart(at: target) { next in
                // 云盘直链可能已过期：跳转前重新解析一次，避免重建流仍用旧地址。
                if photo.isCloud, let refreshed = try? await store.cloudStreamOrThrow(for: photo) {
                    sourceURL = refreshed.url
                    sourceHeaders = refreshed.headers
                }
                return makeStreamContext(generation: generation,
                                         offset: max(0, next - 1),
                                         resumeAt: next,
                                         mode: mode,
                                         audioIndex: audio,
                                         // 原来暂停着拖到未生成区间，重建完会自己播起来；
                                         // 沿用拖动前的播放意图，暂停就停在目标帧。
                                         autoplay: wasPlaying)
            }
            switch outcome {
            case .started:
                hasLoadedVideo = true
                failureMessage = nil
                canTranscode = false
            case .failed(let message, let canTranscode):
                failureMessage = message
                self.canTranscode = canTranscode
                if wasPlaying, generation == loadGeneration { model.play() }
            case .cancelled, .queued:
                break
            }
            let elapsed = Int(Date().timeIntervalSince(seekStartedAt) * 1000)
            let remote = photo.isCloud ? "网盘" : "本地"
            Diagnostics.record("拖拽起流 \(photo.originalName) \(remote) → \(Int(target))s 用时 \(elapsed)ms")
            isPreparing = false
        }
    }

    /// 云盘直链失效时重新解析；代理的下载线程会阻塞等待结果。
    func cloudRefreshClosure() -> (() -> (URL, [String: String])?)? {
        guard photo.isCloud else { return nil }
        return {
            // 在主线程阻塞等待会死锁（解析本身要回主线程）。
            guard !Thread.isMainThread else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            var result: (URL, [String: String])?
            Task { @MainActor in
                if let stream = try? await store.cloudStreamOrThrow(for: photo) {
                    result = (stream.url, stream.headers)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 20)
            return result
        }
    }

    /// 系统播放器拒绝码流（-12927 / -11828）时自动重编码一次：
    /// 沿用当前播放位置与音轨，避免用户停在错误页手动点「转换为兼容格式」。
    func autoFallbackToTranscode(after failure: PlaybackFailure) {
        let generation = loadGeneration
        let target = model.currentTime
        let audioIndex = playbackSession.streamAudioIndex
        Diagnostics.record("自动兼容转码 \(photo.originalName) at \(Int(target))s "
                           + "（\(failure.domain ?? "-") \(failure.code.map(String.init) ?? "-")）")
        isPreparing = true
        failureMessage = nil
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: true,
                                               offset: max(0, target - 1),
                                               resumeAt: target > 1 ? target : nil,
                                               mode: .transcode,
                                               audioIndex: audioIndex)
            guard generation == loadGeneration else { return }
            if !started, failureMessage == nil {
                failureMessage = "该视频的编码不受系统播放器支持，兼容转换也未能启动。"
                canTranscode = true
                isPreparing = false
            }
        }
    }

    /// 直连播放被网盘限速时的兜底：改用本地转封装，从当前位置接着播。
    /// 网盘直链只有一条 HTTP 连接，CDN 限速后缓冲只出不进；转封装走本地 Range 代理，
    /// 会按档位并发预取多个分块（流畅档 8 路 × 16MB），吞吐通常是单连接的数倍。
    func switchToStreamingForSlowSource(at target: Double) {
        guard photo.isCloud, let url = sourceURL,
              url.pathExtension.lowercased() != "m3u8",
              !playbackSession.isRestartingStream, !isPreparing else { return }
        Diagnostics.record("直连限速切转封装：\(photo.originalName) → \(Int(target))s")
        let generation = loadGeneration
        let audioIndex = playbackSession.streamAudioIndex
        isPreparing = true
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: true,
                                               offset: max(0, target - 1),
                                               resumeAt: target,
                                               mode: .remux,
                                               audioIndex: audioIndex)
            guard generation == loadGeneration else { return }
            if !started, failureMessage == nil {
                failureMessage = "网盘直连太慢，转封装也未能启动。"
                isPreparing = false
            }
        }
    }

    /// 启动转封装会话；编码不兼容时自动降级为重编码 H.264。
    /// 起流：`offset` 是 ffmpeg 的读取位置（会再对齐到关键帧），
    /// `resumeAt` 是播放器最终要落到的绝对秒数（装片后先定位再开播）。
    func startStreaming(generation: Int, autoplay: Bool, offset: Double,
                                resumeAt: Double? = nil,
                                mode initialMode: VideoStreamSession.Mode,
                                audioIndex: Int,
                                isLive: Bool = false) async -> Bool {
        guard let context = makeStreamContext(generation: generation,
                                              offset: offset,
                                              resumeAt: resumeAt,
                                              mode: initialMode,
                                              audioIndex: audioIndex,
                                              autoplay: autoplay,
                                              isLive: isLive) else { return false }
        let outcome = await playbackSession.start(context)
        switch outcome {
        case .started:
            hasLoadedVideo = true
            failureMessage = nil
            isPreparing = false
            canTranscode = false
            refreshAudioChoices()
            return true
        case .cancelled, .queued:
            return false
        case .failed(let message, let canTranscode):
            failureMessage = message
            self.canTranscode = canTranscode
            isPreparing = false
            return false
        }
    }

    /// 把播放页掌握的片源 / 探测 / 设置打包给内核；起流与降级逻辑不再留在 View 里。
    func makeStreamContext(generation: Int,
                                   offset: Double,
                                   resumeAt: Double?,
                                   mode: VideoStreamSession.Mode,
                                   audioIndex: Int,
                                   autoplay: Bool,
                                   isLive: Bool = false) -> PlaybackStreamContext? {
        guard let sourceURL else { return nil }
        let token = generation
        return PlaybackStreamContext(
            photoID: photo.id,
            title: photo.originalName,
            sourceURL: sourceURL,
            headers: sourceHeaders,
            trustSelfSigned: store.cloudMount(for: photo.cloudMountID)?.trustSelfSigned ?? false,
            isHEVC: probeIsHEVC,
            isHDR: probeIsHDR,
            color: probeColor,
            duration: probeDuration,
            size: videoSize,
            frameRate: playbackProbe.frameRate,
            isInterlaced: playbackProbe.isInterlaced,
            angle: selectedAngle,
            audioTracks: probeAudioTracks,
            audioIndex: audioIndex,
            audioDownmix: settings.audioDownmix,
            transcodeMode: settings.videoTranscodeMode,
            // HDR 屏 + 自动策略：重编码时保留 HDR，跳过色调映射（映射链 4K60 只有 <1× 实时）。
            preserveHDR: displaySupportsHDR && effectiveHDRMode != .toneMapSDR,
            burnSubtitle: ui.burnSubtitleURL,
            burnSubtitleStream: ui.burnSubtitleStream,
            cacheSignature: VideoStreamSession.lumaCacheSignature,
            refreshSource: cloudRefreshClosure(),
            autoplay: autoplay,
            loop: settings.loopVideoByDefault,
            muted: settings.muteVideoByDefault,
            offset: offset,
            resumeAt: resumeAt,
            preferredMode: mode,
            isLive: isLive,
            // 回看是 playseek 拼出来的远端 HLS 窗口：交给 ffmpeg 时直连（带请求头），
            // 不能套本机 Range 代理，否则代理只转发到 m3u8 文本，ffmpeg 直接报「Invalid data」。
            directRemoteInput: tvPlaybackChannel?.isCatchUp == true,
            generation: token,
            isCurrent: { token == loadGeneration })
    }

    /// 失败卡片：电视频道用「逐条线路原因 + 可操作按钮」，其他片源沿用原卡片。
    @ViewBuilder
    func failureView(_ message: String) -> some View {
        if let channel = store.tvPlaybackChannel(for: photo.id) {
            tvFailureCard(channel: channel, fallbackMessage: message)
        } else {
            defaultFailureView(message)
        }
    }

    /// 概念「状态 C · 失败与换线」：全部线路失败后升级为居中卡片。
    func tvFailureCard(channel: TVChannel, fallbackMessage: String) -> some View {
        let summary = store.tvLineFailureSummary(for: photo.id)
        let total = store.tvLineCount(for: photo.id)
        let reasonText = store.tvLiveRetryExhaustedMessage(for: photo.id)
            .map { summary.isEmpty ? $0 : "\($0)：\(summary)" }
            ?? (summary.isEmpty ? fallbackMessage : "\(total) 条线路都失败了：\(summary)。")
        return VStack(spacing: 12) {
            Text("这个频道暂时看不了")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.white)
            Text(reasonText)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                tvFailureButton("重试", prominent: true) {
                    failureMessage = nil
                    streamFailure = nil
                    if channel.isCatchUp {
                        Task { await startPlaybackTask() }
                    } else {
                        store.retryTVLivePlayback(for: photo.id)
                    }
                }
                tvFailureButton("换一条线路", prominent: false) {
                    _ = store.switchTVLine(for: photo.id, delta: 1)
                }
                .disabled(total < 2)
                tvFailureButton("打开信号页", prominent: false) {
                    store.closeViewer()
                    store.tvModel.setHubTab(.status)
                }
                tvFailureButton("复制流地址", prominent: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(channel.streamURL, forType: .string)
                    store.showToast("已复制流地址")
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
                }
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .padding(24)
    }

    func tvFailureButton(_ title: String,
                                 prominent: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(prominent ? Color.black.opacity(0.88) : Color.white.opacity(0.86))
                .padding(.horizontal, 12)
                .padding(.vertical, 5.5)
                .background(prominent ? TVBrand.wave : Color.white.opacity(0.12),
                            in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func defaultFailureView(_ message: String) -> some View {
        let httpStatus = model.playbackFailure?.httpStatus
        return VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.75))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if photo.isCloud,
               store.cloudMount(for: photo.cloudMountID)?.kind == .pan115,
               message.contains("403") {
                Text("115 可能触发了风控验证或直链已失效：请先在 115 网页端打开该视频完成验证，再回到拾光重试；仍失败时可在「编辑接入范围」里重新保存一次 Cookie。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 10) {
                // HTTP 4xx / 5xx 是线路本身拒绝，转码解决不了，不展示这个入口。
                if canTranscode, (httpStatus ?? 0) < 400 {
                    Button {
                        transcodeAndPlay()
                    } label: {
                        HStack(spacing: 6) {
                            if isTranscoding {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(isTranscoding ? "正在转换…" : "转换为兼容格式并播放")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTranscoding)
                }
                // 只在原文件确实在本机时才给这个入口：
                // 系统图库的 iCloud 项目在 Photos.sqlite 里有路径，但文件并不存在。
                if let sourceURL, !photo.isCloud,
                   FileManager.default.fileExists(atPath: sourceURL.path) {
                    Button("用其他播放器打开") {
                        NSWorkspace.shared.open(sourceURL)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                }
                if photo.isCloud, let mountID = photo.cloudMountID {
                    Button("打开网盘连接") {
                        store.closeViewer()
                        store.navigate(to: .cloudMount(mountID))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                    .help("在网盘连接页检查授权状态或重新登录")
                }
                // 站点直链解析失败（如 CDN 拒绝请求）时，退回原站详情页播放。
                if isCatalogPlayback,
                   let context = store.catalogPlaybackContext(for: photo.id),
                   let pageURL = URL(string: context.episode.pageURL) {
                    Button("在浏览器中播放") {
                        NSWorkspace.shared.open(pageURL)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                    .help("在默认浏览器打开该条目的原始播放页")
                }
                Button("重试") {
                    Task { await load(generation: loadGeneration) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.16), in: Capsule())
            }
        }
        .padding(26)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .padding(24)
    }

}
