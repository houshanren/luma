import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore
import LumaCore

extension VideoPlayerStage {
    // MARK: 载入

    /// 本地 / SMB 起播点真实帧：比缩略图清晰得多，拿到即替换等待层底图。
    /// 云端与网络源不做远端抽帧（要额外下行、收益低），交给信息层。
    /// 图库本机视频起播几乎瞬时，按设计不取首帧、不显示等待层。
    func loadLocalPosterFrame() {
        posterFrameTask?.cancel()
        posterFrameTask = nil
        guard !isLocalVideo else { return }
        let url = LibraryPaths.sourceURL(for: photo)
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let targetID = photo.id
        let seconds = max(0, playbackSession.resumePosition ?? 0)
        posterFrameTask = Task { @MainActor in
            let frame = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 2560, height: 2560)
                // SMB 上放宽容差，取附近的帧即可，别为了精确时间点多读几段。
                generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
                return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                  actualTime: nil)
            }.value
            guard !Task.isCancelled, photo.id == targetID, let frame else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                loadingFrame = NSImage(cgImage: frame,
                                       size: NSSize(width: frame.width, height: frame.height))
            }
        }
    }

    func load(generation: Int) async {
        FullScreenDiagnostics.log("video load start \(photo.originalName) generation=\(generation)")
        // 不在这里恢复刷新率：连播同一帧率的剧集时，先恢复再匹配会让屏幕黑闪两次。
        // 新片的匹配在首帧出来后由 applyDisplayRate 负责，退出播放时 onDisappear 统一恢复。
        isPreparing = true
        waitingStage = tvLiveChannel != nil ? .connecting : .resolving
        cachedSourcePending = false
        failureMessage = nil
        streamFailure = nil
        canTranscode = false
        isTranscoding = false
        didAutoTranscodeFallback = false
        assetOptions = [:]
        sourceHeaders = [:]
        hasLoadedVideo = false
        cloudResourceLoader?.invalidate()
        cloudResourceLoader = nil
        playbackSession.stop()
        playbackSession.beginItem(photo.id, hooks: store)
        // 当前查看器仍以点播为主；电视直播接入后按 PlaybackTarget 设置 .live。
        playbackSession.playbackMode = .vod

        let autoplay = settings.autoPlayVideo
        // 续播 / 片头由内核钩子统一提供（影院进度、目录起播秒数）。
        let resumeOffset = playbackSession.resumePosition

        // 上一集快看完时预热好的下一集：首段已生成，直接接管，省掉解析直链与探测。
        if !ui.isBurningSubtitle,
           let warm = store.takePrewarmedCinemaStream(for: photo.id) {
            sourceURL = warm.sourceURL
            sourceHeaders = warm.headers
            assetOptions = [CloudPlayback.headerFieldsKey: warm.headers]
            playbackSession.adopt(warm.session)
            var probe = VideoProbe()
            probe.hasVideoTrack = true
            probe.isPlayable = true
            probe.duration = max(photo.duration ?? 0, warm.duration)
            if warm.videoSize.width > 0, warm.videoSize.height > 0 {
                probe.size = warm.videoSize
            } else if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                probe.size = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
            // 预热时已探测过：接管后不再重探，音轨菜单也能直接显示语言 / 声道。
            probe.audioTracks = warm.audioTracks
            probe.audioTrackCount = warm.audioTracks.count
            videoSize = probe.size
            probeDuration = probe.duration
            probeIsHEVC = warm.isHEVC
            probeIsHDR = false
            probeColor = VideoColorInfo()
            probeAudioCount = warm.audioTracks.count
            probeAudioTracks = warm.audioTracks
            applyPlaybackProbe(probe)
            waitingStage = .starting
            model.load(url: warm.playlistURL, probe: probe, autoplay: autoplay,
                       loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                       startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                       playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
            hasLoadedVideo = true
            isPreparing = false
            failureMessage = nil
            canTranscode = false
            // 预热时生成被暂停过：真正开播后必须恢复，否则不会再有新分片。
            playbackSession.setGenerationActive(true)
            refreshAudioChoices()
            ui.loadSiblingIfAvailable(sourceURL: sourceURL)
            return
        }

        // 已有完整 HLS 缓存：不解析直链、不探测远端，直接用缓存起播。
        // 只对云端 / 网络资源生效：本地文件本来就不落缓存。
        if !ui.isBurningSubtitle,
           photo.isCloud || store.catalogPlaybackContext(for: photo.id) != nil,
           VideoStreamSession.hasCompleteCache(environment: .luma,
                                                photoID: photo.id,
                                                cacheSignature: VideoStreamSession.lumaCacheSignature,
                                                requiresSDR: cacheRequiresSDR,
                                                supportsLibplacebo: VideoSupport.supportsLibplacebo),
           await playFromCompleteCache(generation: generation,
                                       autoplay: autoplay,
                                       resumeOffset: resumeOffset) {
            return
        }

        let source = await resolveSource()
        guard generation == loadGeneration, !Task.isCancelled else { return }
        waitingStage = tvLiveChannel != nil ? .connecting : .probing
        var failedProbe: VideoProbe?

        // 电视直播的非 HLS 源（http-flv / http-ts）：系统播放器不支持，
        // 直接交给 ffmpeg 转封装成滑动窗口 HLS，跳过 AVFoundation 探测与缓存查找。
        if let source, playbackMode == .live, !source.isHLS, FFmpeg.isAvailable {
            sourceURL = source.url
            sourceHeaders = source.headers
            assetOptions = [CloudPlayback.headerFieldsKey: source.headers]
            failureMessage = nil
            isPreparing = true
            playbackSession.playbackMode = .live
            // 直播没有完整时长：进度条不参与，尺寸用列表元数据兜底。
            probeDuration = 0
            if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
            waitingStage = .starting
            if await startStreaming(generation: generation, autoplay: autoplay,
                                    offset: 0, resumeAt: nil, mode: .remux,
                                    audioIndex: 0, isLive: true) {
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
            } else if generation == loadGeneration, !Task.isCancelled,
                      let channel = tvPlaybackChannel, !channel.isCatchUp {
                // ffmpeg 边下边播失败不会走 AVPlayer 的失败回调，这里手动顺延到备用线路，
                // 否则会一直停在当前这条坏线上，只能手点「换一条线路」。
                let host = URL(string: channel.streamURL)?.host ?? "-"
                Diagnostics.record("电视边下边播失败 \(channel.name) \(host)")
                attemptTVLineFallback(reason: "无法播放（\(host)）", generation: generation)
            }
            return
        }

        // 百度直链：URL 没有扩展名、AVPlayer 跳转后不会继续带 UA；
        // WebDAV：必须带 Basic 认证头，AVPlayer 直连不会发送；
        // 两者都由资源加载器代取，探测与播放都拿到明确的 Content-Type。
        var playbackAsset: AVAsset?
        var playbackURL = source?.url
        // 官方转码的 HLS 播放列表：AVPlayer 原生支持，不能交给 ffmpeg 按字节读取。
        if let source, source.isHLS {
            sourceURL = source.url
            sourceHeaders = source.headers
            assetOptions = [CloudPlayback.headerFieldsKey: source.headers]
            var probe = VideoProbe()
            probe.hasVideoTrack = true
            probe.isPlayable = true
            probe.duration = photo.duration ?? 0
            if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                probe.size = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
            videoSize = probe.size
            waitingStage = .starting
            model.load(url: source.url, options: assetOptions, probe: probe, autoplay: autoplay,
                       loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                       startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer,
                       startsImmediately: playbackMode == .live)
            playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
            hasLoadedVideo = true
            isPreparing = false
            probeDuration = probe.duration
            probeIsHEVC = false
            probeIsHDR = false
            probeColor = VideoColorInfo()
            probeAudioCount = 0
            probeAudioTracks = []
            applyPlaybackProbe(probe)
            ui.loadSiblingIfAvailable(sourceURL: sourceURL)
            return
        }
        if let source {
            sourceURL = source.url
            sourceHeaders = source.headers
            assetOptions = [CloudPlayback.headerFieldsKey: source.headers]
            let mount = photo.isCloud ? store.cloudMount(for: photo.cloudMountID) : nil
            let needsProxy = mount.map { $0.kind == .baidu || $0.kind == .webdav } ?? false
            if needsProxy,
               let made = CloudAssetResourceLoader.makeAsset(
                   upstreamURL: source.url,
                   headers: source.headers,
                   trustSelfSigned: mount?.trustSelfSigned ?? false,
                   pathExtension: (photo.originalName as NSString).pathExtension) {
                cloudResourceLoader = made.loader
                playbackAsset = made.asset
                playbackURL = made.asset.url
            }
        }

        // 原图路径存在才探测：iCloud / 共享相簿项目在 Photos.sqlite 里有路径，本机却没有文件。
        let canUseLocal = playbackURL.map { photo.isCloud || FileManager.default.fileExists(atPath: $0.path) } ?? false
        // 烧录字幕必须经过 ffmpeg 重编码，跳过系统原生直接播放。
        if let playbackURL, canUseLocal, !ui.isBurningSubtitle {
            // 复用同一份 AVAsset 做探测与播放：SMB / 外置盘少开一次文件，轨道信息也直接复用。
            let asset = playbackAsset ?? AVURLAsset(url: playbackURL, options: assetOptions)
            // 资源加载器代取的地址 ffprobe 读不了，只有普通地址才做 ffprobe 兜底。
            waitingStage = .probing
            let probe = await VideoSupport.probe(asset: asset,
                                                 fallbackURL: playbackAsset == nil ? playbackURL : nil,
                                                 options: assetOptions)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // 本地文件一律直连：iPhone 拍的 4K60 HDR 在 QuickTime 里都能直接播，
            // 没必要先跑一遍 ffmpeg（隔行 / 4K 高帧率 / 自动 HDR 映射都不再拦）。
            // 系统真解不了的码流由播放器失败回调兜底转码一次，不会黑屏卡住。
            // 例外：用户在设置里强制「HDR 转 SDR」时按他的要求映射。
            let localDirect = !photo.isCloud && canUseLocal
            let directOK = localDirect
                ? (probe.isVideoDecodable || (probe.isPlayable && !probe.isInterlaced))
                : (probe.isPlayable && !probe.isInterlaced
                   && !probe.requiresRecodeForHighFrameRate4K)
            let toneMapRequired = needsToneMapping(probe)
                && (!localDirect || effectiveHDRMode == .toneMapSDR)
            if probe.hasVideoTrack, directOK, !toneMapRequired {
                videoSize = probe.size
                model.load(asset: asset, probe: probe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                           playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = probe.duration
                probeIsHEVC = probe.isHEVC
                probeIsHDR = probe.isHDR
                probeColor = probe.color
                probeAudioCount = probe.audioTrackCount
                probeAudioTracks = probe.audioTracks
                applyPlaybackProbe(probe)
                applyDisplayRate(probe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                notifyIfDolbyVisionUnsupported(probe)
                return
            }
            failedProbe = probe
            // 跳过系统原生直解的原因有多种：HDR / 隔行 / 4K 高帧率。日志如实区分，
            // 别把 4K60 也写成「HDR 片源」，否则排查时会被误导。
            if probe.hasVideoTrack, probe.isPlayable {
                let reasons = [
                    needsToneMapping(probe) ? "色调映射" : nil,
                    probe.isInterlaced ? "去隔行" : nil,
                    probe.requiresRecodeForHighFrameRate4K ? "4K 高帧率" : nil
                ].compactMap { $0 }
                Diagnostics.record("片源跳过直连（\(reasons.isEmpty ? "转码" : reasons.joined(separator: "+"))）："
                                   + "\(photo.originalName) "
                                   + "dv=\(probe.isDolbyVision) "
                                   + "profile=\(probe.color.dvProfile.map(String.init) ?? "-") "
                                   + "fps=\(Int(probe.frameRate)) "
                                   + "策略=\(effectiveHDRMode.rawValue) "
                                   + "override=\(hdrToneMapOverride.map { $0 ? "on" : "off" } ?? "nil") "
                                   + displayHDRDiagnostics)
            } else if photo.isCloud {
                Diagnostics.record("云端视频探测失败 \(photo.originalName)：track=\(probe.hasVideoTrack) "
                                   + "playable=\(probe.isPlayable) codec=\(probe.codec ?? "-") "
                                   + "host=\(playbackURL.host ?? "-")")
            }
        } else if !photo.isSystem {
            if let streamFailure, photo.isCloud {
                failureMessage = "无法获取网盘播放地址：\(streamFailure)"
            } else if let streamFailure {
                failureMessage = "无法定位视频文件：\(streamFailure)"
            } else {
                failureMessage = "无法定位视频文件"
            }
            isPreparing = false
            return
        }
        // 翻页后旧任务可能刚从 await 恢复：不再往播放器里装上一个视频。
        guard generation == loadGeneration, !Task.isCancelled else { return }

        if !ui.isBurningSubtitle,
           let cached = cachedTranscodeURL(), FileManager.default.fileExists(atPath: cached.path) {
            let cachedProbe = await VideoSupport.probe(url: cached)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if cachedProbe.hasVideoTrack, cachedProbe.isPlayable {
                sourceURL = cached
                videoSize = cachedProbe.size
                waitingStage = .starting
                model.load(url: cached, probe: cachedProbe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                           playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = cachedProbe.duration
                probeIsHEVC = cachedProbe.isHEVC
                probeIsHDR = cachedProbe.isHDR
                probeColor = cachedProbe.color
                probeAudioCount = cachedProbe.audioTrackCount
                probeAudioTracks = cachedProbe.audioTracks
                applyPlaybackProbe(cachedProbe)
                applyDisplayRate(cachedProbe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                return
            }
        }

        // 系统「照片」图库：只有本机拿不到可用原图时才交给 PhotoKit 代取。
        // 外接 / 非当前系统图库里的项目 PhotoKit 查不到，但原文件往往就在本机，
        // 不能因为查不到就判失败——这类视频直接走下面的 ffmpeg 转封装 / 色调映射。
        if photo.isSystem, !canUseLocal {
            let resolved = await store.systemVideoAsset(for: photo)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            switch resolved {
            case .ready(let asset, let url):
                waitingStage = .probing
                let probe = await VideoSupport.probe(asset: asset)
                guard generation == loadGeneration, !Task.isCancelled else { return }
                if probe.hasVideoTrack, probe.isPlayable {
                    sourceURL = url
                    videoSize = probe.size
                    model.load(asset: asset, probe: probe, autoplay: autoplay,
                               loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                               startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                               playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
                    hasLoadedVideo = true
                    isPreparing = false
                    probeDuration = probe.duration
                    probeIsHEVC = probe.isHEVC
                    probeIsHDR = probe.isHDR
                    probeColor = probe.color
                    probeAudioCount = probe.audioTrackCount
                    probeAudioTracks = probe.audioTracks
                    applyPlaybackProbe(probe)
                    applyDisplayRate(probe.frameRate)
                    refreshAudioChoices()
                    ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                    return
                }
                failedProbe = probe
            case .unauthorized, .notFound, .unavailable:
                // 失败原因如实转述：只有 PhotoKit 明确说「在云端」才提示 iCloud。
                failureMessage = Self.systemVideoFailureMessage(resolved)
                Diagnostics.record("系统视频取不到 \(photo.originalName)："
                                   + Self.systemVideoFailureDiagnostics(resolved))
                isPreparing = false
                return
            }
        }

        // 系统不支持的容器（MKV / AVI…）：ffmpeg 边下载边封装成 fMP4 HLS，
        // 第一段分片就绪即可播放，不必等整部文件下载 / 转换完。
        let formatName = Self.formatDescription(name: photo.originalName, codec: failedProbe?.codec)
        if let failedProbe {
            probeDuration = failedProbe.duration > 0 ? failedProbe.duration : (photo.duration ?? 0)
            // MKV 这类容器 AVFoundation 探测不到编码，用网盘列表里的元数据补齐，
            // 否则 HEVC 转封装不会写 hvc1 标签，AVPlayer 会直接拒绝播放。
            probeIsHEVC = failedProbe.isHEVC || photo.videoCodec?.lowercased() == "hevc"
            probeIsHDR = failedProbe.isHDR
            probeColor = failedProbe.color
            notifyIfDolbyVisionUnsupported(failedProbe)
            probeAudioCount = failedProbe.audioTrackCount
            probeAudioTracks = failedProbe.audioTracks
            applyPlaybackProbe(failedProbe)
            if failedProbe.size.width > 0, failedProbe.size.height > 0 {
                videoSize = failedProbe.size
            } else if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
        }
        // 烧录字幕跳过了系统原生探测：用列表元数据补齐时长 / 尺寸，转码流才有正确的进度条。
        if ui.isBurningSubtitle {
            if probeDuration <= 0 { probeDuration = photo.duration ?? 0 }
            if videoSize == .zero, photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
        }
        if sourceURL != nil, FFmpeg.isAvailable {
            // 不弹「正在准备」告警卡片：直接进入播放界面转圈，首段就绪后自动开播。
            failureMessage = nil
            isPreparing = true
            // 续播直接从目标位置起流，省掉「先播片头再重建流」的一跳。
            let startOffset = resumeOffset ?? 0
            // HDR / 杜比视界按设置色调映射；隔行源必须重编码去隔行；其余走无损转封装。
            // 视频轨被系统判定不可解码时也只能重编码：只换容器救不回来，直连更是黑屏有声音。
            let streamProbe = failedProbe ?? playbackProbe
            if !streamProbe.isVideoDecodable, streamProbe.hasVideoTrack {
                Diagnostics.record("视频轨系统无法解码，改走重编码：\(photo.originalName) "
                                   + "codec=\(streamProbe.codec ?? "-") "
                                   + "\(Int(streamProbe.size.width))x\(Int(streamProbe.size.height)) "
                                   + "fps=\(Int(streamProbe.frameRate))")
            }
            let highFrameRate4K = streamProbe.requiresRecodeForHighFrameRate4K
            if highFrameRate4K {
                Diagnostics.record("4K 高帧率 HEVC 直接重编码：\(photo.originalName) "
                                   + "codec=\(streamProbe.codec ?? "-") "
                                   + "\(Int(streamProbe.size.width))x\(Int(streamProbe.size.height)) "
                                   + "fps=\(Int(streamProbe.frameRate))")
            }
            let streamMode: VideoStreamSession.Mode =
                (needsToneMapping(streamProbe) || streamProbe.isInterlaced
                 || !streamProbe.isVideoDecodable || highFrameRate4K) ? .transcode : .remux
            waitingStage = .starting
            if await startStreaming(generation: generation, autoplay: autoplay,
                                    offset: startOffset,
                                    resumeAt: startOffset > 0 ? startOffset : nil,
                                    mode: streamMode, audioIndex: 0) {
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                return
            }
            return
        }

        isPreparing = false
        if photo.isCloud {
            failureMessage = "该云端视频（\(formatName)）系统无法直接播放。"
                + "安装 ffmpeg（brew install ffmpeg）后可转换为兼容格式。"
        } else {
            failureMessage = "系统无法解码该视频（\(formatName)）。安装 ffmpeg 后可自动转换为兼容格式。"
        }
    }

    /// 完整缓存命中：用片源元数据直接起本地 HLS，远端直链放到后台补。
    /// 缓存里已经是完整时间轴，续播也直接从缓存起播，不再等 ffmpeg 从中间重建。
    func playFromCompleteCache(generation: Int,
                                       autoplay: Bool,
                                       resumeOffset: Double?) async -> Bool {
        sourceURL = cachedPlaybackSource()
        sourceHeaders = [:]
        assetOptions = [:]
        var probe = VideoProbe()
        probe.hasVideoTrack = true
        probe.isPlayable = true
        probe.duration = photo.duration ?? 0
        if photo.pixelWidth > 0, photo.pixelHeight > 0 {
            probe.size = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
        }
        videoSize = probe.size
        probeDuration = probe.duration
        probeIsHEVC = photo.videoCodec?.lowercased() == "hevc"
        // 多音轨 / HDR 缓存无法从远端重新探测：用缓存清单恢复音轨结构与色彩标记。
        let manifest = VideoStreamSession.cachedManifest(
            environment: .luma,
            photoID: photo.id,
            cacheSignature: VideoStreamSession.lumaCacheSignature)
        probeIsHDR = manifest?.isHDR ?? false
        probeColor = VideoColorInfo(isHDR: manifest?.isHDR ?? false,
                                    isDolbyVision: manifest?.isDolbyVision ?? false)
        let cachedTracks = manifest?.audioTracks ?? []
        probe.audioTracks = cachedTracks
        probe.audioTrackCount = cachedTracks.count
        probeAudioCount = cachedTracks.count
        probeAudioTracks = cachedTracks
        applyPlaybackProbe(probe)
        refreshAudioChoices()

        let start = max(0, resumeOffset ?? 0)
        cachedSourcePending = true
        waitingStage = .starting
        let started = await startStreaming(generation: generation,
                                           autoplay: autoplay,
                                           offset: start,
                                           resumeAt: start > 0 ? start : nil,
                                           mode: .remux,
                                           audioIndex: 0)
        guard started else {
            cachedSourcePending = false
            return false
        }

        // 内嵌字幕 / 未缓存区间的预览帧仍要用原始直链，后台补齐即可，不挡起播。
        Task { @MainActor in
            let resolved = await resolveSource()
            guard generation == loadGeneration else { return }
            cachedSourcePending = false
            guard let resolved else { return }
            sourceURL = resolved.url
            sourceHeaders = resolved.headers
            assetOptions = [CloudPlayback.headerFieldsKey: resolved.headers]
            registerScrubPreviewFallback()
            ui.loadSiblingIfAvailable(sourceURL: resolved.url)
            await loadTechnicalProbe(generation: generation)
        }
        return true
    }

    /// 缓存命中时给起流上下文一个非本地文件地址：缓存目录只按 photoID 命名，
    /// 不需要真实直链；但不能用 file://，否则会被当成「本地源」而不复用缓存。
    func cachedPlaybackSource() -> URL {
        if let context = store.catalogPlaybackContext(for: photo.id),
           let url = URL(string: context.episode.pageURL) {
            return url
        }
        if let path = photo.cloudPath, let url = URL(string: path) {
            return url
        }
        return URL(string: "luma-cache://cache")!
    }

    /// MKV / AVI 这类容器 AVFoundation 根本不解析，探测拿不到编码，直接说明容器更准确。
    static func formatDescription(name: String, codec: String?) -> String {
        let unsupported: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "rmvb", "rm",
                                        "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv",
                                        "divx", "mxf", "asf"]
        let ext = (name as NSString).pathExtension.lowercased()
        if unsupported.contains(ext) { return "\(ext.uppercased()) 容器" }
        return codec ?? "未知编码"
    }

    /// 系统图库视频取不到时的提示：只有 PhotoKit 明确说「在云端」才提 iCloud，
    /// 其余情况如实说明（无权限 / 找不到 / 暂时读取失败），不再把任何失败都归因到 iCloud。
    static func systemVideoFailureMessage(_ result: PhotoKitBridge.SystemVideoAsset) -> String {
        switch result {
        case .ready:
            return ""
        case .unauthorized:
            return "没有照片图库的读取权限，请在「系统设置 › 隐私与安全性 › 照片」里允许拾光访问后重试。"
        case .notFound:
            // 这条分支只在「本机没有原文件」时才会走到：PhotoKit 也查不到，说明当前浏览的不是
            // 「照片」正在使用的图库（外接 / 旧图库），或项目已删除。
            return "系统「照片」里找不到这个视频（当前图库不是「照片」正在使用的图库，或视频已被删除），本机也没有它的原文件。"
        case .unavailable(_, let isInCloud):
            return isInCloud
                ? "无法从系统「照片」图库读取该视频，可能仍在 iCloud 或共享相簿中下载。"
                : "系统「照片」暂时无法读取该视频，请稍后重试。"
        }
    }

    static func systemVideoFailureDiagnostics(_ result: PhotoKitBridge.SystemVideoAsset) -> String {
        switch result {
        case .ready:
            return "ready"
        case .unauthorized:
            return "unauthorized"
        case .notFound:
            return "notFound"
        case .unavailable(let error, let isInCloud):
            return "unavailable isInCloud=\(isInCloud) error=\(error ?? "-")"
        }
    }

    func resolveSource() async -> (url: URL, headers: [String: String], isHLS: Bool)? {
        do {
            let session = try await store.preparePlaybackSession(for: photo)
            playbackMode = session.mode
            playbackCapabilities = session.capabilities
            return (session.stream.url, session.stream.headers, session.stream.isHLS)
        } catch {
            streamFailure = error.localizedDescription
            return nil
        }
    }

    func cachedTranscodeURL() -> URL? {
        LibraryPaths.transcodes.appendingPathComponent(photo.id.uuidString + ".mp4", isDirectory: false)
    }

    func transcodeAndPlay() {
        guard !isTranscoding, let sourceURL else { return }
        isTranscoding = true
        waitingStage = .starting
        let generation = loadGeneration
        let isCloud = photo.isCloud
        let headers = sourceHeaders
        Task { @MainActor in
            do {
                guard let destination = cachedTranscodeURL() else { return }
                if isCloud {
                    // MKV 等容器连探测都过不了，ffmpeg 直接从远端读取再封装成 MP4。
                    try await VideoSupport.transcodeRemote(
                        source: sourceURL,
                        headers: headers,
                        trustSelfSigned: store.cloudMount(for: photo.cloudMountID)?.trustSelfSigned ?? false,
                        toneMapHDR: probeIsHDR,
                        isDolbyVision: probeColor.isDolbyVision,
                        destination: destination)
                } else {
                    try await VideoSupport.transcode(source: sourceURL, destination: destination,
                                                     toneMapHDR: probeIsHDR,
                                                     isDolbyVision: probeColor.isDolbyVision,
                                                     sourceSize: videoSize,
                                                     frameRate: playbackProbe.frameRate,
                                                     color: probeColor)
                }
                let probe = await VideoSupport.probe(url: destination)
                // 转换期间已经翻到别的照片：不要再把结果塞进播放器。
                guard generation == loadGeneration else { return }
                guard probe.hasVideoTrack, probe.isPlayable else {
                    isTranscoding = false
                    failureMessage = "转换后的文件仍无法播放，请确认 ffmpeg 组件完整。"
                    return
                }
                videoSize = probe.size
                probeDuration = probe.duration
                applyDisplayRate(probe.frameRate)
                model.load(url: destination, probe: probe, autoplay: true,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           forwardBufferDuration: startupForwardBuffer)
                hasLoadedVideo = true
                failureMessage = nil
                canTranscode = false
                isTranscoding = false
                VideoCache.luma.trimIfNeeded()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                store.showToast("已转换为兼容格式并开始播放")
            } catch {
                guard generation == loadGeneration else { return }
                isTranscoding = false
                failureMessage = "转换失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleFullScreen() {
        // 优先用播放器自己所在的窗口：弹出面板 / 子窗口抢到 key 时也不会切错窗口。
        let target = playerWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        FullScreenDiagnostics.log("toggleFullScreen window=\(String(describing: target)) isFullScreen=\(target?.styleMask.contains(.fullScreen) ?? false)")
        target?.toggleFullScreen(nil)
    }
}
