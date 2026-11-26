import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore
import LumaCore

extension VideoPlayerStage {
    // MARK: 播放信息 / 章节

    /// I 键信息叠加：码率 / 帧率 / HDR / 音轨 / 章节，全部来自起播后补的 ffprobe。
    var playbackInfoOverlay: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("播放信息")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                Button {
                    showPlaybackInfo = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭 (I)")
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.7)

            // 四列固定顺序：视频 / 音频 / 字幕 / 播放，扫一眼就能读完。
            HStack(alignment: .top, spacing: 16) {
                infoColumn("视频") {
                    infoRow("画面", playbackResolutionText)
                    infoRow("编码", playbackCodecText)
                    infoRow("容器", playbackContainerText)
                    infoRow("码率", playbackBitrateText)
                    infoRow("帧率", playbackFrameRateText)
                    infoRow("HDR", playbackProbe.hdrLabel ?? (playbackProbe.isHDR ? "HDR" : "SDR"))
                    infoRow("色彩", playbackColorText)
                }
                infoColumn("音频") {
                    infoRow("主音轨", playbackPrimaryAudioText)
                    infoRow("编码", playbackAudioCodecText)
                    infoRow("声道", playbackAudioChannelsText)
                    infoRow("语言", playbackAudioLanguageText)
                    infoRow("轨道数", playbackAudioTrackCountText)
                    infoRow("输出", "系统默认输出")
                }
                infoColumn("字幕") {
                    infoRow("当前", playbackSubtitleCurrentText)
                    infoRow("来源", playbackSubtitleSourceText)
                    infoRow("轨道", playbackSubtitleTracksText)
                    infoRow("时间轴", playbackSubtitleOffsetText)
                    infoRow("字号", playbackSubtitleSizeText)
                    infoRow("位置", playbackSubtitlePositionText)
                }
                infoColumn("播放") {
                    infoRow("章节", playbackChapterText)
                    if angleCount > 1 {
                        infoRow("角度", "\(selectedAngle)/\(angleCount)")
                    }
                    infoRow("大小", playbackFileSizeText)
                    infoRow("已播", playbackPlayedText)
                    infoRow("实时码率", playbackLiveBitrateText)
                    infoRow("丢帧", playbackDroppedFramesText)
                    infoRow("解码", playbackDecodeText)
                }
            }

            Divider().overlay(Color.white.opacity(0.10))

            Button {
                showFullProbe.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showFullProbe ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                    Text(showFullProbe ? "收起完整探测信息" : "更多探测信息")
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                    Text("⇧⌘I")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .foregroundStyle(.white.opacity(0.62))
            }
            .buttonStyle(.plain)

            if showFullProbe {
                ScrollView {
                    Text(fullProbeText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(playbackPathText, forType: .string)
            } label: {
                HStack(spacing: 6) {
                    Text("路径")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                    Text(playbackPathText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            .help("复制路径")
        }
        .padding(14)
        .frame(width: 520)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    /// 一列信息：小标题 + 若干行，四列宽度自适应。
    func infoColumn<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(LumaBrand.amber.opacity(0.9))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 播放信息里的路径：网盘用云端路径，本地用源文件路径。
    var playbackPathText: String {
        if let path = photo.cloudPath, !path.isEmpty { return path }
        if let sourceURL { return sourceURL.path }
        return LibraryPaths.sourceURL(for: photo).path
    }

    var playbackResolutionText: String {
        let size = playbackProbe.size.width > 0 ? playbackProbe.size : videoSize
        guard size.width > 0, size.height > 0 else { return "—" }
        return "\(Int(size.width))×\(Int(size.height))"
    }

    var playbackCodecText: String {
        var parts: [String] = []
        if let codec = playbackProbe.codec ?? photo.videoCodec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if let container = playbackProbe.containerName, !container.isEmpty {
            parts.append(container)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var playbackBitrateText: String {
        let bitrate = playbackProbe.bitrate
        guard bitrate > 0 else { return "—" }
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        }
        return "\(bitrate / 1000) kbps"
    }

    var playbackFrameRateText: String {
        guard playbackProbe.frameRate > 0 else { return playbackProbe.isInterlaced ? "隔行" : "—" }
        let fps = String(format: "%.2f fps", playbackProbe.frameRate)
        return playbackProbe.isInterlaced ? fps + " · 隔行（转码去隔行）" : fps
    }

    var playbackAudioText: String {
        let tracks = playbackAudioTracks
        guard let first = tracks.first else { return "—" }
        let base = first.displayName.isEmpty ? "音轨 1" : first.displayName
        return tracks.count > 1 ? "\(base) · 共 \(tracks.count) 轨" : base
    }

    /// 音频列的细分字段：全部来自 ffprobe，缺数据时明确显示「—」。
    var playbackAudioTracks: [AudioTrackInfo] {
        playbackProbe.audioTracks.isEmpty ? probeAudioTracks : playbackProbe.audioTracks
    }

    var playbackPrimaryAudioText: String {
        guard let first = playbackAudioTracks.first else { return "—" }
        return first.displayName.isEmpty ? "音轨 1" : first.displayName
    }

    var playbackAudioCodecText: String {
        guard let codec = playbackAudioTracks.first?.codec, !codec.isEmpty else { return "—" }
        return codec.uppercased()
    }

    var playbackAudioChannelsText: String {
        guard let channels = playbackAudioTracks.first?.channels, channels > 0 else { return "—" }
        switch channels {
        case 1: return "单声道"
        case 2: return "立体声"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) 声道"
        }
    }

    var playbackAudioLanguageText: String {
        guard let language = playbackAudioTracks.first?.language,
              !language.isEmpty, language.lowercased() != "und" else { return "—" }
        return language.uppercased()
    }

    var playbackAudioTrackCountText: String {
        "\(playbackAudioTracks.count) 条"
    }

    var playbackContainerText: String {
        guard let container = playbackProbe.containerName, !container.isEmpty else { return "—" }
        return container
    }

    /// 色彩：原色域 / 传输函数 / 量化范围 / codec tag，HDR 片源一眼能看出 BT.2020 + PQ。
    var playbackColorText: String {
        let color = playbackProbe.color
        var parts: [String] = []
        if let primaries = color.primaries, !primaries.isEmpty { parts.append(primaries.uppercased()) }
        if let transfer = color.transfer, !transfer.isEmpty { parts.append(transfer.uppercased()) }
        if let range = color.range, !range.isEmpty { parts.append(range.uppercased()) }
        if let tag = color.codecTag, !tag.isEmpty { parts.append(tag) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var playbackFileSizeText: String {
        guard photo.fileSize > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file)
    }

    var playbackPlayedText: String {
        let total = model.duration > 0 ? model.duration : (playbackProbe.duration > 0 ? playbackProbe.duration : 0)
        guard total > 0 else { return "—" }
        return "\(formatPlayerTime(model.currentTime)) / \(formatPlayerTime(total))"
    }

    /// 运行时码率 / 丢帧：从 AVPlayerItem 的访问日志取，起播几秒后才有值。
    var playbackAccessLogEvent: AVPlayerItemAccessLogEvent? {
        model.player.currentItem?.accessLog()?.events.last
    }

    var playbackLiveBitrateText: String {
        guard let bitrate = playbackAccessLogEvent?.observedBitrate, bitrate > 0 else { return "—" }
        return String(format: "%.1f Mbps", bitrate / 1_000_000)
    }

    var playbackDroppedFramesText: String {
        guard let log = playbackAccessLogEvent else { return "—" }
        return "\(log.numberOfDroppedVideoFrames) 帧"
    }

    var playbackDecodeText: String {
        if !playbackProbe.isVideoDecodable { return "软件转码" }
        return playbackProbe.isHEVC ? "硬解 · HEVC" : "系统硬解"
    }

    var playbackSubtitleCurrentText: String {
        if let burn = ui.burnSubtitleName { return burn }
        if let ordinal = ui.embeddedTrackOrdinal,
           let track = ui.embeddedTracks.first(where: { $0.ordinal == ordinal }) {
            return track.displayName
        }
        if let name = ui.subtitleName, !name.isEmpty { return name }
        return "关"
    }

    var playbackSubtitleSourceText: String {
        if ui.burnSubtitleName != nil || ui.burnSubtitleStream != nil { return "烧录" }
        if ui.embeddedTrackOrdinal != nil { return "内嵌" }
        if ui.subtitleName != nil { return "外挂" }
        return "—"
    }

    var playbackSubtitleTracksText: String {
        let embedded = playbackProbe.subtitleTracks.count
        return embedded > 0 ? "内嵌 \(embedded) 轨" : "无内嵌轨"
    }

    var playbackSubtitleOffsetText: String {
        String(format: "%+.1fs", ui.subtitleOffset)
    }

    var playbackSubtitleSizeText: String {
        String(format: "%.0f pt", settings.subtitleFontSize)
    }

    var playbackSubtitlePositionText: String {
        switch settings.subtitlePosition {
        case "middle": return "居中"
        case "lower": return "偏低"
        default: return "底部"
        }
    }

    /// ⌘⇧I 的完整探测信息：直接按字段列出，方便排查 HDR / 音轨 / 字幕轨问题。
    var fullProbeText: String {
        let probe = playbackProbe
        var lines: [String] = []
        lines.append("path        \(playbackPathText)")
        lines.append("container   \(probe.containerName ?? "—")")
        lines.append("codec       \(probe.codec ?? photo.videoCodec ?? "—")  hevc=\(probe.isHEVC)")
        lines.append("size        \(Int(probe.size.width))×\(Int(probe.size.height))")
        lines.append("bitrate     \(probe.bitrate) bps")
        lines.append("frameRate   \(String(format: "%.3f", probe.frameRate))  interlaced=\(probe.isInterlaced)")
        lines.append("hdr         \(probe.hdrLabel ?? "—")  dv=\(probe.isDolbyVision)  profile=\(probe.color.dvProfile.map(String.init) ?? "—")")
        lines.append("color       primaries=\(probe.color.primaries ?? "—") transfer=\(probe.color.transfer ?? "—") matrix=\(probe.color.matrix ?? "—") range=\(probe.color.range ?? "—")")
        lines.append("decodable   \(probe.isVideoDecodable)  angles=\(probe.angleCount)")
        lines.append("chapters    \(probe.chapters.count)")
        for (index, track) in playbackAudioTracks.enumerated() {
            lines.append("audio[\(index)]    \(track.displayName)  codec=\(track.codec) channels=\(track.channels)")
        }
        for (index, track) in probe.subtitleTracks.enumerated() {
            lines.append("subtitle[\(index)] \(track.displayName)  image=\(track.isImage) forced=\(track.isForced)")
        }
        return lines.joined(separator: "\n")
    }

    /// 当前所在章节（信息叠加用）：章节标题来自蓝光播放列表 / Matroska。
    var playbackChapterText: String {
        let chapters = playbackProbe.chapters.sorted { $0.start < $1.start }
        guard !chapters.isEmpty else { return "无" }
        let index = chapters.lastIndex(where: { $0.start <= model.currentTime + 0.2 }) ?? 0
        return "\(index + 1)/\(chapters.count) · \(chapters[index].title)"
    }

    /// 进度条上的章节刻度（比例）。
    var chapterFractions: [Double] {
        guard model.duration > 0 else { return [] }
        return playbackProbe.chapters
            .map { min(1, max(0, $0.start / model.duration)) }
            .filter { $0 > 0.01 && $0 < 0.99 }
    }

    /// 探测结果统一入口：信息叠加、章节菜单与 HDR 开关都从同一份数据刷新，
    /// 避免各条起播分支只更新其中一部分。
    func applyPlaybackProbe(_ probe: VideoProbe) {
        playbackProbe = probe
        // 角度数随探测结果更新；换到单角度片源时把选择收回 1。
        angleCount = max(1, probe.angleCount)
        if selectedAngle > angleCount { selectedAngle = 1 }
        // 蓝光盘内标题只在有章节时读（章节菜单的标题行）；普通片源不做多余的文件枚举。
        let discTitle = probe.chapters.count > 1
            ? sourceURL.flatMap { BluraySource.discTitle(for: $0) }
            : nil
        ui.updateChapters(probe.chapters, discTitle: discTitle)
        ui.updateAngles(count: angleCount, selected: selectedAngle)
        refreshHDRToneMapState()
    }

    /// HDR 映射开关：只有片源是 HDR / 杜比视界、且本机具备映射能力时才出现。
    func refreshHDRToneMapState() {
        let probe = playbackProbe
        let isHDRSource = probe.isHDR || probe.isDolbyVision || probe.color.isHDR
        let capable = isHDRSource
            && VideoSupport.supportsToneMapping
            && !(probe.isDolbyVision && !VideoSupport.supportsLibplacebo)
        ui.updateHDRToneMap(available: capable, enabled: needsToneMapping(probe))
    }

    /// 章节跳转：⌥← / ⌥→ 与章节菜单共用；没有章节时返回 false，让按键继续走原逻辑。
    @discardableResult
    func seekChapter(step: Int) -> Bool {
        let chapters = playbackProbe.chapters.sorted { $0.start < $1.start }
        guard chapters.count > 1 else { return false }
        if step > 0 {
            guard let next = chapters.first(where: { $0.start > model.currentTime + 0.6 }) else {
                return true
            }
            seekPlayback(to: next.start)
        } else {
            if let index = chapters.lastIndex(where: { $0.start <= model.currentTime - 2 }) {
                seekPlayback(to: chapters[index].start)
            } else {
                seekPlayback(to: chapters[0].start)
            }
        }
        return true
    }

    func playbackContent(in size: CGSize) -> some View {
        ZStack {
            if !transparentBackground {
                Color.black
            }

            if hasLoadedVideo, activeFailure == nil {
                // 比例预设裁出居中框，平移与显示方式都在框内完成。
                let layout = framingLayout(in: size)
                ZStack {
                    PlayerLayerView(player: model.player,
                                    gravity: settings.videoFramingMode.gravity,
                                    opaqueBackground: !transparentBackground) { controller in
                        DispatchQueue.main.async {
                            model.attachPip(controller)
                        }
                    }
                    .frame(width: layout.preRotationContentSize.width,
                           height: layout.preRotationContentSize.height)
                    .rotationEffect(.degrees(Double(quarterTurns) * 90))
                    .offset(layout.panOffset)
                }
                .frame(width: layout.boxSize.width, height: layout.boxSize.height)
                .clipped()
                .scaleEffect(zoom)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if activeFailure == nil {
                tapLayer
            }

            // 起播海报在出画面后淡出，等待反馈只保留紧凑缓冲胶囊。
            waitingLayer
                .animation(.easeOut(duration: 0.25), value: model.isItemReady)

            if let failure = activeFailure {
                failureView(failure)
            }

            if activeFailure == nil, let cue = activeCue {
                subtitleOverlay(cue, in: size)
            }

            if activeFailure == nil {
                centerPlayButton
                // 电视直播全屏由频道 OSD 承载操作，不再叠通用播放栏。
                let hidesPlaybackControls = tvLiveChannel != nil && viewer.videoImmersiveFullScreen
                if !hidesPlaybackControls,
                   settings.videoControlPlacement == .floating || !transparentBackground
                    || viewer.videoImmersiveFullScreen {
                    controls(stage: size)
                }
            }

            // 就绪后才显示频道 OSD，避免与失败卡片、起播海报重叠。
            tvOverlay
            if showPlaybackInfo, activeFailure == nil {
                VStack {
                    HStack {
                        Spacer()
                        playbackInfoOverlay
                    }
                    Spacer()
                }
                .padding(18)
                .transition(.opacity)
            }
        }
    }

    func playbackChrome<Content: View>(for content: Content) -> some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // 播放器控件始终按深色玻璃渲染，避免浅色外观下白色文字叠在亮色材质上。
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                handleHoverMove()
            case .ended:
                scheduleControlsHide()
            }
        }
    }

    func playbackObservers<Content: View>(for content: Content) -> some View {
        content
        .onChange(of: model.isPlaying) { _, playing in
            if playing {
                scheduleControlsHide()
            } else {
                hideControlsTask?.cancel()
                controlsShown = true
            }
        }
        .onChange(of: photo.id) { _, _ in resetTVInput() }
        // 暂停时继续生成 EVENT 分片，避免恢复播放时 AVPlayer 报 -12888。
        .onChange(of: model.wantsPlayback) { _, wants in
            if wants { playbackSession.setGenerationActive(true) }
        }
        // 转封装后的 HLS 解码失败仍保留转码兜底入口。
        .onChange(of: model.playbackFailure) { _, failure in
            handlePlaybackFailure(failure)
        }
        .onChange(of: model.isItemReady) { _, ready in
            if ready { rememberTVLiveLineIfReady(generation: loadGeneration) }
        }
        .onChange(of: settings.preservePitchAtSpeed) { _, enabled in
            model.preservesPitch = enabled
            model.applyPitchPreference()
        }
        .onChange(of: settings.systemMediaIntegration) { _, enabled in
            if enabled {
                activateNowPlaying()
            } else {
                NowPlayingCenter.shared.deactivate()
            }
        }
        .onChange(of: model.isBuffering) { _, buffering in
            guard buffering, hasLoadedVideo else { return }
            Diagnostics.record("播放缓冲 \(photo.originalName) at \(Int(model.currentTime))s", level: .verbose)
        }
        .onChange(of: streamFailure) { _, value in
            handleStreamFailureChange(value)
        }
        .onChange(of: model.audioOptions.count) { _, _ in refreshAudioChoices() }
        .onChange(of: model.selectedAudio) { _, _ in refreshAudioChoices() }
        .task(id: playbackReloadKey) {
            await startPlaybackTask()
        }
        .onDisappear {
            handleStageDisappear()
        }
        .background(
            KeyEventMonitor { event in
                handleKey(event)
            }
            .frame(width: 0, height: 0)
        )
        .background(
            WindowAccessor { window in
                if playerWindow !== window { playerWindow = window }
            }
            .frame(width: 0, height: 0)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            playbackObservers(for: playbackChrome(for: playbackContent(in: proxy.size)))
        }
    }

    /// 换片 / 首帧载入的完整准备流程：重置状态、注册播放回调，再起播。
    /// 从 `.task` 里抽出来，避免 SwiftUI 对超大表达式做类型检查超时。
    func preparePlayback(generation: Int) async {
        autoEmbeddedTried = false
        // 播放期偏好：变速保音调、音轨是否即时切换都在装片前交给内核。
        model.preservesPitch = settings.preservePitchAtSpeed
        playbackSession.prefersMultiAudio = settings.instantAudioSwitch
        // 起播底图：本地视频的缩略图先垫一层模糊背景，网络源没有就退回渐变。
        loadingThumbnail = fileExistsThumbnail()
        // 网络资源：用当前这一集的封面做起播底图；单集没有封面时才退回条目封面。
        if loadingThumbnail == nil,
           let context = store.catalogPlaybackContexts[photo.id] {
            let cover = context.episode.coverURL.isEmpty ? context.item.coverURL : context.episode.coverURL
            if !cover.isEmpty {
                let source = context.source
                let targetID = photo.id
                Task { @MainActor in
                    let artwork = await CatalogArtworkCache.shared.image(source: source,
                                                                         urlString: cover,
                                                                         quick: true)
                    guard photo.id == targetID else { return }
                    if let artwork {
                        loadingThumbnail = artwork
                    }
                }
            }
        }
        // 影院匹配过的本地 / SMB 视频：用刮削背景图做起播底图，
        // 大文件探测 / 首段生成期间不会只剩一块黑底。
        // 剧集优先取「本集剧照」，没有剧照（或电影）才回退整部作品的背景。
        if loadingThumbnail == nil,
           let entry = store.cinemaPlaybackEntry,
           entry.file.photoID == photo.id,
           let artwork = store.cinemaGridArtwork(for: photo) {
            let targetID = photo.id
            let tvID = entry.tmdbID
            let season = entry.season
            let episode = entry.episode
            let isEpisode = entry.kind == .tv && tvID != nil && season != nil && episode != nil
            Task { @MainActor in
                if isEpisode, let tvID, let season, let episode {
                    var still = store.cachedCinemaEpisodeInfos(tvID: tvID,
                                                               season: season)?.infos[episode]?.stillURL
                    if still == nil {
                        // 本集剧照还没缓存：补拉一次（12 小时内只请求一次）。
                        still = await store.refreshCinemaEpisodeInfos(tvID: tvID,
                                                                      season: season)?[episode]?.stillURL
                    }
                    if let still,
                       let image = await CinemaArtworkCache.shared.image(for: still) {
                        guard photo.id == targetID else { return }
                        if loadingThumbnail == nil { loadingThumbnail = image }
                        return
                    }
                    guard photo.id == targetID, loadingThumbnail == nil else { return }
                }
                let image = await CinemaArtworkCache.shared.image(for: artwork)
                guard photo.id == targetID, loadingThumbnail == nil else { return }
                if let image { loadingThumbnail = image }
            }
        }
        // 先停掉上一个视频：新视频的 URL / 探测还是要等一会，
        // 期间旧音频继续播会让"画面已经是别的照片，声音还在"。
        model.stop()
        playbackSession.stop()
        cloudResourceLoader?.invalidate()
        cloudResourceLoader = nil
        sourceURL = nil
        sourceHeaders = [:]
        hasLoadedVideo = false
        probeDuration = 0
        probeIsHEVC = false
        probeIsHDR = false
        probeAudioCount = 0
        probeAudioTracks = []
        applyPlaybackProbe(VideoProbe())
        hdrToneMapOverride = nil
        selectedAngle = 1
        showPlaybackInfo = false
        ui.reset()
        configureSubtitleQuery()
        registerPlaybackCallbacks()
        quarterTurns = 0
        videoSize = .zero
        refreshVideoNeighbors()
        await load(generation: generation)
        registerScrubPreviewFallback()
        activateNowPlaying()
        await loadTechnicalProbe(generation: generation)
        // 优先级最低的一档：同目录 / 内嵌都没挂上时，才按设置在线匹配一条。
        await ui.autoMatchOnlineSubtitleIfNeeded()
    }

    /// 在线字幕搜索上下文：影院用刮削出的片名与季集号，网络资源用条目标题与集数。
    func configureSubtitleQuery() {
        if let entry = store.cinemaPlaybackEntry, entry.file.photoID == photo.id {
            ui.subtitleQuery = CinemaSubtitleQuery(title: entry.title,
                                                   season: entry.season,
                                                   episode: entry.episode)
        } else if let context = store.catalogPlaybackContext(for: photo.id) {
            ui.subtitleQuery = CinemaSubtitleQuery(title: context.item.title,
                                                   season: nil,
                                                   episode: context.episode.index)
        } else {
            // 图库里的视频没有刮削信息：用文件名兜底，手动搜在线字幕时还能用。
            let name = (photo.originalName as NSString).deletingPathExtension
            ui.subtitleQuery = name.isEmpty ? nil : CinemaSubtitleQuery(title: name,
                                                                        season: nil,
                                                                        episode: nil)
        }
    }

    /// 拖动进度条的预览帧：先试播放项自身，再回退到原始片源。
    func scrubThumbnail(fraction: Double) async -> NSImage? {
        guard settings.scrubPreviewEnabled, model.duration > 0 else { return nil }
        if let image = await VideoScrubThumbnails.image(player: model.player,
                                                        fraction: fraction,
                                                        duration: model.duration) {
            return image
        }
        return await previewFrame(seconds: model.duration * fraction,
                                  duration: model.duration)
    }

    /// 顶栏悬停预览的回退取帧：拖到还没生成的区间时，换一路片源抽一帧。
    func registerScrubPreviewFallback() {
        VideoScrubPreviewCenter.shared.fallbackProvider = { fraction, duration in
            guard settings.scrubPreviewEnabled, duration > 0 else { return nil }
            return await previewFrame(seconds: duration * fraction, duration: duration)
        }
    }

    /// 预览取帧的统一回退链：本地转封装会话 → 远端影子播放器 → ffmpeg 直接抽帧。
    /// MKV / HDR 这类 AVFoundation 播不了的片源全靠会话，分片在本机磁盘上，最快。
    func previewFrame(seconds: Double, duration: Double) async -> NSImage? {
        if let session = VideoScrubThumbnails.localSessionURL(player: model.player),
           let image = await VideoScrubThumbnails.playerImage(source: session,
                                                              headers: [:],
                                                              seconds: seconds,
                                                              duration: duration) {
            return image
        }
        guard let sourceURL else { return nil }
        // 网络 HLS：分片常伪装成 .jpeg，ImageGenerator 取不到帧，改由影子播放器取。
        if !sourceURL.isFileURL,
           let image = await VideoScrubThumbnails.playerImage(source: sourceURL,
                                                              headers: sourceHeaders,
                                                              seconds: seconds,
                                                              duration: duration) {
            return image
        }
        return await VideoScrubThumbnails.sourceImage(source: sourceURL,
                                                      headers: sourceHeaders,
                                                      seconds: seconds,
                                                      duration: duration)
    }

    /// 播放回调只在换片时注册一次：一切跳转、音轨、字幕操作都从这里分发。
    func registerPlaybackCallbacks() {
        model.onPlaybackEnd = {
            playbackSession.notifyPlaybackFinished()
            guard settings.autoPlayNextVideo else { return }
            store.playNextVideo(after: photo.id)
        }
        // 所有界面跳转（进度条 / 工具栏 / 快捷键）统一走路由器：
        // 云盘拖到未生成区间时重建流，已完成缓存的 HLS 直接 seek。
        model.seekRouter = { target in
            // 正在重建流：新会话还没装好，先记下最新目标，就绪后再追过去。
            if playbackSession.isRestartingStream {
                playbackSession.queueRestart(target)
                return true
            }
            guard playbackSession.streamSession != nil else { return false }
            if playbackSession.isCompleteCache { return false }
            // 是否要重建流由内核统一判定，播放页不再自己算窗口。
            if playbackSession.seekDecision(target: target) == .restart {
                restartStreaming(at: target)
                return true
            }
            return false
        }
        // 卡死兜底：分片充足却长时间不前进，AVPlayer 可能进入了无法自愈的等待状态，
        // 由播放页在当前位置重建一次流。
        playbackSession.onHardStall = { target in
            guard !playbackSession.isRestartingStream else { return }
            restartStreaming(at: target)
        }
        // 直连云端视频卡住：网盘直链只有一条连接，被限速后永远等不到数据，
        // 改走转封装 + 本地 Range 代理的并行预取。
        playbackSession.onNativeStall = { target in
            switchToStreamingForSlowSource(at: target)
        }
        // 拖动时只允许在已生成区间内落帧预览，越界位置等松手后再重建流。
        model.scrubGuard = { target in
            // 重建流期间旧会话已经/正在废弃，不再用它做预览落帧。
            if playbackSession.isRestartingStream { return false }
            guard let session = playbackSession.streamSession,
                  !session.isCompleteCache else { return true }
            return target >= session.retainedStartSeconds - 1
                && target <= session.generatedEndSeconds + 2
        }
        ui.onMessage = { message in store.showToast(message) }
        ui.onSelectStreamAudio = { index in
            // 多音轨 HLS：所有音轨都已在同一会话里，AVPlayer 即时换轨即可。
            if playbackSession.isMultiAudio, index < model.audioOptions.count {
                playbackSession.previewAudioIndex(index)
                model.selectAudio(index: index)
                refreshAudioChoices()
                return
            }
            if playbackSession.streamSession != nil {
                switchAudio(to: index)
            } else if index < model.audioOptions.count {
                model.selectAudio(model.audioOptions[index])
            }
        }
        ui.onSeekChapter = { target in
            seekPlayback(to: target)
        }
        ui.onToggleHDRToneMapping = { enabled in
            setHDRToneMapping(enabled)
        }
        ui.onSelectAngle = { angle in
            setAngle(angle)
        }
        ui.onSelectEmbeddedSubtitle = { track in
            Task { await extractEmbeddedSubtitle(track) }
        }
        ui.onSubtitleSelectionRemembered = { selection in
            settings.rememberSubtitle(selection, for: photo.id)
        }
        ui.onBurnSubtitleChanged = {
            guard sourceURL != nil else {
                store.showToast("当前视频没有可读取的源文件，无法烧录字幕")
                return
            }
            let target = model.currentTime
            playbackSession.stop()
            hasLoadedVideo = false
            isPreparing = true
            let generation = loadGeneration
            Task { @MainActor in
                let started = await startStreaming(generation: generation, autoplay: true,
                                                   offset: max(0, target - 1),
                                                   resumeAt: target,
                                                   mode: .transcode,
                                                   audioIndex: playbackSession.streamAudioIndex)
                if !started, generation == loadGeneration {
                    model.seek(to: target)
                }
                isPreparing = false
            }
        }
    }

    /// 系统媒体集成：控制中心 / 耳机 / 键盘媒体键看到当前视频并可直接控制。
    func activateNowPlaying() {
        guard settings.systemMediaIntegration else {
            NowPlayingCenter.shared.deactivate()
            return
        }
        let subtitle: String?
        if let entry = store.cinemaPlaybackEntry {
            var parts = [entry.title]
            if let title = photo.title, title != entry.title { parts.append(title) }
            subtitle = parts.joined(separator: " · ")
        } else if let title = photo.title, title != photo.originalName {
            subtitle = title
        } else {
            subtitle = nil
        }
        NowPlayingCenter.shared.activate(model: model,
                                         title: photo.title ?? photo.originalName,
                                         subtitle: subtitle,
                                         artwork: loadingThumbnail,
                                         onNext: { store.viewerStepVideo(1) },
                                         onPrevious: { store.viewerStepVideo(-1) })
    }

    /// 起播后再补一次 ffprobe：拿码率 / 帧率 / HDR / 章节，供 I 键信息叠加与章节菜单使用。
    /// 不阻塞起播；HLS 播放列表与不存在的本地文件直接跳过。
    func loadTechnicalProbe(generation: Int) async {
        // 缓存起播时真实直链还在后台解析：先不拿占位地址做探测，等直链回来再补。
        guard !cachedSourcePending else { return }
        guard let url = sourceURL else { return }
        if url.pathExtension.lowercased() == "m3u8" { return }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return }
        let probe = await VideoSupport.technicalProbe(url: url, options: assetOptions)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        guard probe.hasVideoTrack || !probe.chapters.isEmpty || !probe.subtitleTracks.isEmpty else { return }

        var merged = playbackProbe
        if probe.size.width > 0 { merged.size = probe.size }
        if let codec = probe.codec { merged.codec = codec }
        merged.isHDR = merged.isHDR || probe.isHDR
        merged.isDolbyVision = merged.isDolbyVision || probe.isDolbyVision
        merged.isInterlaced = merged.isInterlaced || probe.isInterlaced
        merged.angleCount = max(merged.angleCount, probe.angleCount)
        if let label = probe.hdrLabel, !label.isEmpty { merged.hdrLabel = label }
        if probe.bitrate > 0 { merged.bitrate = probe.bitrate }
        if probe.frameRate > 0 { merged.frameRate = probe.frameRate }
        if let container = probe.containerName { merged.containerName = container }
        if !probe.chapters.isEmpty { merged.chapters = probe.chapters }
        if probe.audioTracks.count > merged.audioTracks.count { merged.audioTracks = probe.audioTracks }
        merged.duration = max(merged.duration, probe.duration)
        if merged.subtitleTracks.isEmpty, !probe.subtitleTracks.isEmpty {
            merged.subtitleTracks = probe.subtitleTracks
        }
        applyPlaybackProbe(merged)
        applyDisplayRate(merged.frameRate)
        // 预热接管 / 转封装起流时音轨信息可能为空：探测到后补齐菜单。
        if merged.audioTracks.count > probeAudioTracks.count {
            probeAudioTracks = merged.audioTracks
            probeAudioCount = merged.audioTracks.count
            refreshAudioChoices()
        }
        ui.updateEmbeddedTracks(merged.subtitleTracks)
        restoreRememberedSubtitleIfNeeded()
        autoLoadEmbeddedSubtitleIfNeeded()
    }

    /// 上次手动选过的字幕：同一部影片重开时优先恢复，不再走默认偏好。
    /// 同目录外挂字幕可能已经自动挂上，这里按记忆覆盖；当次已手动选过则不打扰。
    func restoreRememberedSubtitleIfNeeded() {
        guard !ui.hasManualSubtitleChoice else { return }
        guard let memory = settings.rememberedSubtitle(for: photo.id) else { return }
        switch memory.kind {
        case .embedded:
            guard ui.embeddedTrackOrdinal == nil, let ordinal = memory.ordinal,
                  let track = ui.embeddedTracks.first(where: { $0.ordinal == ordinal && !$0.isImage })
            else { return }
            ui.selectEmbeddedTrack(track, remember: false)
        case .external:
            guard let fileName = memory.fileName, let sourceURL,
                  let url = SubtitleLoader.sibling(named: fileName, of: sourceURL) else { return }
            guard ui.subtitleName != fileName else { return }
            ui.loadSubtitle(url: url)
        }
    }

    /// 内嵌字幕轨探测到后自动挂载一条：按默认中文偏好排序（简体 > 繁体 > 中文 > 原文）。
    /// 只对本地 / SMB 源自动提取，云端交给用户手动选，避免和起流抢网盘带宽。
    func autoLoadEmbeddedSubtitleIfNeeded() {
        // 默认字幕设为「不自动挂载」时，连内嵌轨也不主动提取。
        guard settings.videoPreferredSubtitle != "off" else { return }
        guard settings.autoEmbeddedSubtitles else { return }
        guard let sourceURL, sourceURL.isFileURL else { return }
        guard !autoEmbeddedTried,
              !ui.hasSubtitle,
              ui.embeddedTrackOrdinal == nil else { return }
        // 图形字幕（PGS）提不出来，只从文本轨里挑；forced 只翻译招牌 / 歌曲，排在完整轨之后。
        let textTracks = ui.embeddedTracks.filter { !$0.isImage }
        guard !textTracks.isEmpty else { return }
        autoEmbeddedTried = true
        let preferred = textTracks.filter { !$0.isForced }
        let pool = preferred.isEmpty ? textTracks : preferred
        guard let index = SubtitlePreference.bestIndex(languages: pool.map(\.language),
                                                      titles: pool.map(\.title)) else { return }
        ui.selectEmbeddedTrack(pool[index], remember: false)
    }

    /// 用 ffmpeg 把选中的内嵌字幕轨提取成 ASS 文本，再交给字幕覆盖层渲染。
    func extractEmbeddedSubtitle(_ track: SubtitleTrackInfo) async {
        guard let sourceURL else {
            ui.failEmbeddedSubtitle("当前视频没有可读取的源文件")
            return
        }
        let mount = photo.isCloud ? store.cloudMount(for: photo.cloudMountID) : nil
        let cues = await EmbeddedSubtitleLoader.extract(source: sourceURL,
                                                        headers: sourceHeaders,
                                                        trustSelfSigned: mount?.trustSelfSigned ?? false,
                                                        track: track.ordinal)
        guard !Task.isCancelled else { return }
        ui.applyEmbeddedSubtitle(name: track.displayName, cues: cues)
    }

    /// 按片源帧率切显示器刷新率：设置里可关，找不到合适模式会自动保持原样。
    /// 延迟到首帧出来之后再切：切模式会短暂黑屏，和起播叠在一起就会被看成「打开时卡了一下」。
    func applyDisplayRate(_ rate: Double) {
        guard settings.matchDisplayFrameRate, rate > 1 else { return }
        let generation = loadGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            DisplayModeMatcher.match(frameRate: rate)
        }
    }

    /// 显示器是否能显示 HDR（EDR headroom > 1.0）。SDR 屏上让系统自己 tone map 观感会变，
    /// 所以自动策略改为先映射成 SDR 再播。
    ///
    /// 必须优先看播放窗口所在的那块屏：`NSScreen.main` 在 App 不是前台 / 窗口全屏切换时
    /// 可能为 nil，之前会误判成 SDR 屏，把 4K60 HDR 强行转码（只有 1× 实时，必然周期性缓冲）。
    var displaySupportsHDR: Bool {
        if let screen = playerWindow?.screen ?? NSScreen.main {
            return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        }
        // 窗口还没挂到屏幕上：只要任意一块屏支持 EDR 就按 HDR 处理。
        return NSScreen.screens.contains {
            $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        }
    }

    /// 屏幕信息：排查「为什么这条 HDR 片走了转码」时直接看日志。
    var displayHDRDiagnostics: String {
        let screen = playerWindow?.screen ?? NSScreen.main
        let edr = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? -1
        return "displayHDR=\(displaySupportsHDR) edr=\(String(format: "%.2f", edr))"
    }

    /// 缓存快路径没有探测，只能按当前设置与屏幕能力判断是否必须拿 SDR 结果：
    /// 否则 SDR 屏 / 强制映射会命中之前生成的 HDR remux 缓存，画面发灰过曝。
    var cacheRequiresSDR: Bool {
        // 用本次播放实际生效的策略判断：播放器内的 HDR 开关优先于全局设置，
        // 否则手动切换映射后仍会命中之前生成的 HDR remux 缓存。
        let mode = effectiveHDRMode
        guard mode != .keepHDR, VideoSupport.supportsToneMapping else { return false }
        return mode == .toneMapSDR || !displaySupportsHDR
    }

    /// 本次播放实际生效的 HDR 策略：播放器内的开关优先于全局设置。
    var effectiveHDRMode: VideoHDRMode {
        guard let hdrToneMapOverride else { return settings.videoHDRMode }
        return hdrToneMapOverride ? .toneMapSDR : .keepHDR
    }

    /// 这条片源是否需要先做 HDR → SDR 映射再交给播放器。
    /// 决策顺序：保持原样 > 能力检查 > 用户强制 > 自动（屏幕 EDR）。
    func needsToneMapping(_ probe: VideoProbe) -> Bool {
        guard probe.isHDR || probe.isDolbyVision || probe.color.isHDR else { return false }
        guard effectiveHDRMode != .keepHDR else { return false }
        guard VideoSupport.supportsToneMapping else { return false }
        // 杜比视界的 RPU 只有 libplacebo 能应用：没有它就别转码，宁可按原样交给系统。
        if probe.isDolbyVision, !VideoSupport.supportsLibplacebo { return false }
        if effectiveHDRMode == .toneMapSDR { return true }
        // HDR 屏优先保留片源：杜比视界 P5 也交给系统解码，只有 SDR 屏才映射。
        // 若系统拒绝该码流，PlaybackSession 会按起流失败自动降级为重编码 + tone map。
        return !displaySupportsHDR
    }

    /// 杜比视界 P5 的播放路径提示：HDR 屏保留原样时记录一次诊断；
    /// 没有 libplacebo 时明确告诉用户颜色无法还原，而不是静默偏色。
    func notifyIfDolbyVisionUnsupported(_ probe: VideoProbe) {
        guard probe.isDolbyVision, probe.color.dvProfile == 5, !dvHintShown else { return }
        if !VideoSupport.supportsLibplacebo {
            dvHintShown = true
            Diagnostics.record("杜比视界 Profile 5 缺少 libplacebo，无法正确映射颜色：\(photo.originalName)")
            store.showToast("杜比视界 Profile 5 需要带 libplacebo 的 ffmpeg 才能还原颜色")
        } else if settings.videoHDRMode == .automatic, displaySupportsHDR {
            dvHintShown = true
            Diagnostics.record("杜比视界 P5：HDR 屏保留原样，交给系统解码：\(photo.originalName)")
        }
    }

    /// 当前播放的是网络资源的分集（每一集都是一个虚拟视频）。
    var isCatalogPlayback: Bool {
        store.catalogPlaybackContext(for: photo.id) != nil
    }

    /// 分集式片源（网络资源 / 网络存储影院）：方向键让给播放控制，← / → 快进快退，↑ / ↓ 上一条 / 下一条。
    var isEpisodeTransport: Bool {
        store.usesEpisodeTransport(for: photo)
    }

    /// 视频快捷键：
    /// - 图库视频与照片翻页一致：← / → 上一个 / 下一个项目（照片与视频都算），↑ / ↓ 快退 / 快进。
    /// - 网络资源与网络存储影院的视频：← / → 快退 / 快进，↑ / ↓ 上一条 / 下一条。
    /// - ⌘ + 方向键：始终只切换上一个 / 下一个视频。
    /// - J / L：快退 / 快进，与方向键共用同一个步长与加速。
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)

        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于固定键位匹配。
        if !hasCommand, handleCustomShortcut(event) { return true }

        // 电视遥控语义：↑↓ 换台、数字键输入频道号、E 节目单、S 收藏。
        if let channel = tvPlaybackChannel, !hasCommand, flags.isEmpty {
            // Esc 逐层退出：先回直播 / 收节目单抽屉，再收 OSD，最后交给查看器退出播放。
            if event.keyCode == 53 {
                if viewer.tvTimeshiftActive {
                    viewer.tvTimeshiftActive = false
                    model.requestSeek(to: max(0, model.bufferedEndTime - 0.5))
                    model.play()
                    return true
                }
                if viewer.tvGuideShown {
                    withAnimation(.easeOut(duration: 0.2)) { viewer.tvGuideShown = false }
                    return true
                }
                if controlsShown, model.isPlaying {
                    withAnimation(.easeInOut(duration: 0.25)) { controlsShown = false }
                    return true
                }
            }
            if tvLiveChannel != nil {
                if event.keyCode == 126 {
                    switchTVChannel(step: -1)
                    return true
                }
                if event.keyCode == 125 {
                    switchTVChannel(step: 1)
                    return true
                }
                // 时移模式里 ← / → 变成 10 秒步进；否则仍按直播语义切线路。
                if viewer.tvTimeshiftActive {
                    if event.keyCode == 123 {
                        seekTimeshift(by: -10)
                        return true
                    }
                    if event.keyCode == 124 {
                        seekTimeshift(by: 10)
                        return true
                    }
                }
                if let live = tvLiveChannel, live.streamLines.count > 1 {
                    if event.keyCode == 123 {
                        store.switchTVLine(for: photo.id, delta: -1)
                        return true
                    }
                    if event.keyCode == 124 {
                        store.switchTVLine(for: photo.id, delta: 1)
                        return true
                    }
                }
                // L：从时移 / 落后处跳回直播边缘。
                if event.keyCode == 37 {
                    viewer.tvTimeshiftActive = false
                    model.requestSeek(to: max(0, model.bufferedEndTime - 0.5))
                    model.play()
                    store.showToast("已回到直播")
                    return true
                }
                if let digit = channelDigit(event.keyCode) {
                    appendChannelDigit(digit)
                    return true
                }
            }
            if event.keyCode == 14 {
                viewer.tvGuideShown.toggle()
                return true
            }
            if event.keyCode == 1 {
                store.tvModel.toggleFavorite(channel)
                store.showToast(store.tvModel.isFavorite(channel)
                                ? "已收藏 \(channel.name)"
                                : "已取消收藏 \(channel.name)")
                return true
            }
        }

        // ⌥← / ⌥→：上一章 / 下一章；I：播放信息叠加；⇧⌘I：完整探测信息。
        if flags == .option, event.keyCode == 123, seekChapter(step: -1) { return true }
        if flags == .option, event.keyCode == 124, seekChapter(step: 1) { return true }
        if hasCommand, flags.contains(.shift), event.keyCode == 34 {
            showPlaybackInfo = true
            showFullProbe.toggle()
            return true
        }
        if event.keyCode == 34, flags.isEmpty {
            showPlaybackInfo.toggle()
            return true
        }
        // S / A：快速切换字幕 / 音轨，切换结果用 Toast 回报当前轨道。
        if event.keyCode == 1, flags.isEmpty {
            cycleSubtitleTrack()
            return true
        }
        if event.keyCode == 0, flags.isEmpty {
            cycleAudioTrack()
            return true
        }

        guard !flags.contains(.control), !flags.contains(.option) else { return false }

        let episodeTransport = isEpisodeTransport
        // 回看是一档节目的点播：← / → 用来快退 / 快进，不翻上一条 / 下一条。
        let seeksWithArrows = episodeTransport || (tvPlaybackChannel?.isCatchUp == true)
        switch event.keyCode {
        case 123:
            if seeksWithArrows {
                model.seekStep(-1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            } else if hasCommand {
                store.viewerStepVideo(-1)
            } else {
                store.viewerStep(-1)
            }
            return true
        case 124:
            if seeksWithArrows {
                model.seekStep(1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            } else if hasCommand {
                store.viewerStepVideo(1)
            } else {
                store.viewerStep(1)
            }
            return true
        case 126:
            if episodeTransport || hasCommand {
                store.viewerStepVideo(-1)
            } else {
                model.seekStep(1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            }
            return true
        case 125:
            if episodeTransport || hasCommand {
                store.viewerStepVideo(1)
            } else {
                model.seekStep(-1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            }
            return true
        case 49:
            // 空格与系统「照片」一致：收起查看器回到图库；播放/暂停用 K 或回车。
            // 长按的重复事件直接吞掉，避免刚打开又被关掉。
            guard !event.isARepeat else { return true }
            store.closeViewer()
            return true
        case 36:
            // 回车：播放 / 暂停（始终保留为备用键）。
            model.togglePlay()
            return true
        case 43:
            model.stepFrame(by: -1)
            return true
        case 47:
            model.stepFrame(by: 1)
            return true
        default:
            return false
        }
    }

    /// ↑↓ 换台：沿用查看器里的频道上下文，并在顶部提示目标频道。
    func switchTVChannel(step: Int) {
        let photos = store.tvPlaybackPhotos
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        let target = photos[(index + step + photos.count) % photos.count]
        if let next = store.tvPlaybackChannel(for: target.id) {
            store.showToast("\(String(format: "%02d", store.tvModel.channelNumber(for: next))) · \(next.name)")
        }
        store.viewerStep(step)
    }

    /// 主键盘数字 0–9 的 keyCode。
    func channelDigit(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 29: return 0
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    /// 数字键 1.5 秒缓冲：期间继续输入就拼成多位频道号，超时后直接跳转。
    func appendChannelDigit(_ digit: Int) {
        guard tvChannelNumberBuffer.count < 3 else { return }
        tvChannelNumberBuffer.append(String(digit))
        store.showToast("频道号 \(tvChannelNumberBuffer)")
        tvChannelNumberTask?.cancel()
        tvChannelNumberTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            commitChannelNumber()
        }
    }

    func commitChannelNumber() {
        let value = Int(tvChannelNumberBuffer) ?? 0
        tvChannelNumberBuffer = ""
        tvChannelNumberTask = nil
        guard value > 0 else { return }
        let list = store.tvModel.channelsForFocusedSource
        guard let target = list.first(where: { store.tvModel.channelNumber(for: $0) == value }) else {
            store.showToast("没有 \(value) 号频道")
            return
        }
        store.showToast("\(String(format: "%02d", value)) · \(target.name)")
        store.switchTVChannel(target)
    }

    /// S 键：在内嵌文本字幕之间轮换，最后一轨之后关闭字幕。
    func cycleSubtitleTrack() {
        let tracks = playbackProbe.subtitleTracks.filter { !$0.isImage }
        guard !tracks.isEmpty else {
            store.showToast("这个视频没有可切换的内嵌字幕")
            return
        }
        if let current = ui.embeddedTrackOrdinal,
           let index = tracks.firstIndex(where: { $0.ordinal == current }) {
            let next = tracks.index(after: index)
            if next < tracks.endIndex {
                ui.selectEmbeddedTrack(tracks[next])
                store.showToast("字幕 · \(tracks[next].displayName)")
            } else {
                ui.clearEmbeddedSubtitle()
                store.showToast("已关闭字幕")
            }
        } else {
            ui.selectEmbeddedTrack(tracks[0])
            store.showToast("字幕 · \(tracks[0].displayName)")
        }
    }

    /// A 键：在音轨之间轮换。
    func cycleAudioTrack() {
        let choices = ui.audioChoices
        guard choices.count > 1 else {
            store.showToast("这个视频只有一条音轨")
            return
        }
        guard let index = choices.firstIndex(where: { $0.index == ui.selectedAudioIndex }) else {
            ui.selectAudio(choices[0].index)
            return
        }
        let next = choices[(index + 1) % choices.count]
        ui.selectAudio(next.index)
        store.showToast("音轨 · \(next.title.isEmpty ? "音轨 \(next.index + 1)" : next.title)")
    }

    /// 设置 › 快捷键里可自定义的播放器动作。
    func handleCustomShortcut(_ event: NSEvent) -> Bool {
        if ShortcutStore.matches(event, .videoPlayPause) {
            model.togglePlay()
            return true
        }
        if ShortcutStore.matches(event, .videoMute) {
            model.isMuted.toggle()
            return true
        }
        if ShortcutStore.matches(event, .videoForward) {
            model.seekStep(1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            return true
        }
        if ShortcutStore.matches(event, .videoBackward) {
            model.seekStep(-1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            return true
        }
        if ShortcutStore.matches(event, .videoAspect) {
            toggleGravity()
            return true
        }
        if ShortcutStore.matches(event, .videoRotate) {
            rotatePlayer()
            return true
        }
        if ShortcutStore.matches(event, .videoFullscreen) {
            toggleFullScreen()
            return true
        }
        return false
    }

    var tapLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                toggleFullScreen()
            }
            .onTapGesture {
                model.togglePlay()
            }
    }

}
