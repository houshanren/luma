import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore
import LumaCore

extension VideoPlayerStage {
    // MARK: 控制层显隐

    func handleHoverMove() {
        let now = Date()
        guard now.timeIntervalSince(lastHoverMove) > 0.12 else { return }
        lastHoverMove = now
        revealControls()
    }

    func revealControls() {
        if !controlsShown {
            withAnimation(.easeOut(duration: 0.18)) { controlsShown = true }
        }
        scheduleControlsHide()
    }

    /// 播放中静止 3 秒后淡出控制层；暂停时控制层始终可见。
    func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard model.isPlaying else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.28)) { controlsShown = false }
        }
    }

    var centerPlayButton: some View {
        // 缓冲 / 跳转时不要露出播放按钮，否则看起来像是被暂停了。
        let visible = !model.isPlaying && !isPreparing && !model.isStalled && activeFailure == nil
        return Button {
            model.play()
            revealControls()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 1.5)
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.38), radius: 20, y: 8)
        }
        .buttonStyle(.plain)
        .help("播放 (K)")
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.88)
        .allowsHitTesting(visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: visible)
    }

    var volumeIcon: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var durationText: String {
        if showRemainingTime, model.duration > 0 {
            return "-" + formatPlayerTime(max(0, model.duration - model.currentTime))
        }
        return formatPlayerTime(model.duration)
    }

    /// 进度条的抽帧预览。图库视频返回 nil：抽帧会和播放解码抢 CPU / GPU，
    /// 拖动进度条时会明显卡顿，宁可不显示预览。
    var scrubPreviewProvider: ((Double) async -> NSImage?)? {
        guard !store.isLibraryVideoPlayback(photo) else { return nil }
        return { fraction in await scrubThumbnail(fraction: fraction) }
    }

    func controls(stage: CGSize) -> some View {
        // 音量滑杆需要 Binding：`model` 已是 @Observable，这里转发一层 @Bindable。
        @Bindable var model = model
        return VStack {
            Spacer()
            VStack(spacing: 6) {
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 30, height: 3)
                }
                .frame(width: 52, height: 12)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { resetControlPanel() }
                .help("按住拖动控制条，双击复位")

                HStack(spacing: 8) {
                    Text(formatPlayerTime(model.currentTime))
                        .frame(minWidth: 38, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    VideoScrubber(progress: progress,
                                  buffered: buffered,
                                  bufferedStart: bufferedStart,
                                  knobBorder: .black.opacity(0.35),
                                  duration: model.duration,
                                  chapterFractions: chapterFractions,
                                  thumbnailPreview: scrubPreviewProvider) { value in
                        scrubPlayback(to: value * model.duration)
                    } onCommit: { value in
                        seekPlayback(to: value * model.duration)
                    }
                    Text(durationText)
                        .frame(minWidth: 38, alignment: .leading)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentShape(Rectangle())
                        .onTapGesture { showRemainingTime.toggle() }
                        .help("点击切换已播 / 剩余时长")
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 2) {
                    VideoControlButton(icon: model.isPlaying ? "pause.fill" : "play.fill",
                                       emphasized: true,
                                       busy: model.isStalled,
                                       help: model.isStalled ? "正在载入新位置"
                                                             : (model.isPlaying ? "暂停 (K)" : "播放 (K)")) {
                        model.togglePlay()
                    }
                    VideoControlButton(icon: "backward.end",
                                       help: isEpisodeTransport ? "上一条 (↑)" : "上一个 (←)") {
                        if isEpisodeTransport {
                            store.viewerStepVideo(-1)
                        } else {
                            store.viewerStep(-1)
                        }
                    }
                    .disabled(!hasPrevVideo)
                    VideoControlButton(icon: "gobackward",
                                       help: isEpisodeTransport
                                           ? "后退 \(Int(settings.videoSeekStep)) 秒 (← / J)，按住快退"
                                           : "后退 \(Int(settings.videoSeekStep)) 秒 (↓ / J)，按住快退",
                                       repeatsWhileHeld: true) {
                        model.seekStep(-1, base: settings.videoSeekStep, isRepeat: true)
                    }
                    VideoControlButton(icon: "goforward",
                                       help: isEpisodeTransport
                                           ? "前进 \(Int(settings.videoSeekStep)) 秒 (→ / L)，按住快进"
                                           : "前进 \(Int(settings.videoSeekStep)) 秒 (↑ / L)，按住快进",
                                       repeatsWhileHeld: true) {
                        model.seekStep(1, base: settings.videoSeekStep, isRepeat: true)
                    }
                    VideoControlButton(icon: "forward.end",
                                       help: isEpisodeTransport ? "下一条 (↓)" : "下一个 (→)") {
                        if isEpisodeTransport {
                            store.viewerStepVideo(1)
                        } else {
                            store.viewerStep(1)
                        }
                    }
                    .disabled(!hasNextVideo)

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 5)

                    VideoControlButton(icon: volumeIcon,
                                       help: model.isMuted ? "取消静音 (M)" : "静音 (M)") {
                        if model.volume == 0 {
                            model.volume = 1
                            model.isMuted = false
                        } else {
                            model.isMuted.toggle()
                        }
                    }
                    Slider(value: $model.volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 46)
                        .tint(.white)
                        .help("音量")

                    Spacer(minLength: 6)

                    speedMenu

                    VideoControlButton(icon: "info.circle", active: showPlaybackInfo,
                                       help: "播放信息 (I)") {
                        showPlaybackInfo.toggle()
                    }

                    VideoMediaMenuButtons(ui: ui, model: model)

                    VideoControlButton(icon: "repeat", active: model.isLooping,
                                       help: model.isLooping ? "关闭循环播放" : "循环播放") {
                        model.isLooping.toggle()
                    }
                    VideoControlButton(icon: "aspectratio",
                                       active: settings.videoFramingMode == .fill,
                                       help: settings.videoFramingMode == .fill
                                           ? "适应画面 (A)" : "填充画面 (A)") {
                        toggleGravity()
                    }
                    VideoControlButton(icon: "rotate.right", active: quarterTurns != 0, help: "旋转 90° (R)") {
                        rotatePlayer()
                    }
                    if settings.videoPiPEnabled {
                        VideoControlButton(icon: "pip", active: model.isPipActive, help: "画中画") {
                            model.togglePip()
                        }
                        .disabled(!model.isPipAvailable)
                    }
                    VideoControlButton(icon: "camera", help: "保存当前帧") {
                        onCaptureFrame()
                    }
                    VideoControlButton(icon: "arrow.up.left.and.arrow.down.right", help: "全屏 (F)") {
                        toggleFullScreen()
                    }
                }
                .foregroundStyle(.white)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.22))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: VideoControlPanelSizeKey.self,
                                           value: geometry.size)
                }
            }
            .onPreferenceChange(VideoControlPanelSizeKey.self) { size in
                controlPanelSize = size
                reclampControlOffset(stage: stage)
            }
            .onChange(of: stage) { _, _ in
                reclampControlOffset(stage: stage)
            }
            .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
            .padding(.horizontal, 24)
            .padding(.bottom, controlPanelBottomInset)
            .offset(x: controlOffsetX, y: controlOffsetY)
            .gesture(panelDragGesture(stage: stage))
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .scaleEffect(controlsVisible ? 1 : 0.985, anchor: .bottom)
            .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        }
    }

    func toggleGravity() {
        // A 键/按钮仍是「适应 ↔ 填充」的快捷切换；拉伸、原始像素与比例预设在画面菜单里。
        settings.videoFramingMode = settings.videoFramingMode == .fill ? .fit : .fill
    }

    func rotatePlayer() {
        withAnimation(.easeInOut(duration: 0.22)) {
            quarterTurns = (quarterTurns + 1) % 4
        }
    }

    /// 显示层布局：比例预设决定裁剪框，显示方式决定框内画面尺寸，平移只在画面超出裁剪框时生效。
    func framingLayout(in stage: CGSize) -> VideoFramingLayout {
        let natural = videoSize.width > 0 && videoSize.height > 0 ? videoSize : stage
        let layout = VideoFramingGeometry.layout(stage: stage,
                                                 naturalSize: natural,
                                                 quarterTurns: quarterTurns,
                                                 mode: settings.videoFramingMode,
                                                 preset: settings.videoAspectPreset,
                                                 pan: CGSize(width: settings.videoPanX,
                                                             height: settings.videoPanY))
        // 适应模式且没有旋转：让播放层直接铺满裁剪框，由 AVPlayerLayer 的 resizeAspect
        // 按真实视频比例留边。不依赖探测到的片源尺寸，元数据缺失或不准时也能正确适应。
        if settings.videoFramingMode == .fit, quarterTurns % 4 == 0 {
            return VideoFramingLayout(boxSize: layout.boxSize,
                                      preRotationContentSize: layout.boxSize,
                                      panOffset: .zero)
        }
        return layout
    }

    /// 从播放器条目读真实画面尺寸（已含旋转矩阵）：探测拿不到尺寸时用它兜底。
    func adoptNaturalVideoSize() {
        guard let item = model.player.currentItem else { return }
        let size = item.presentationSize
        guard size.width > 1, size.height > 1 else { return }
        if abs(size.width - videoSize.width) > 1 || abs(size.height - videoSize.height) > 1 {
            videoSize = size
        }
    }

    func refreshVideoNeighbors() {
        // 图库视频的 ← / → 与照片翻页一致：前后总有可跳转的项目（首尾循环）。
        if isEpisodeTransport {
            hasPrevVideo = store.hasAdjacentVideo(from: photo.id, delta: -1)
            hasNextVideo = store.hasAdjacentVideo(from: photo.id, delta: 1)
        } else {
            hasPrevVideo = true
            hasNextVideo = true
        }
    }

    func resetControlPanel() {
        withAnimation(.easeOut(duration: 0.2)) {
            controlOffsetX = 0
            controlOffsetY = 0
        }
    }

    func panelDragGesture(stage: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = CGSize(width: controlOffsetX, height: controlOffsetY)
                }
                guard let start = dragStartOffset else { return }
                let proposed = CGSize(width: start.width + value.translation.width,
                                      height: start.height + value.translation.height)
                let clamped = clampControlOffset(proposed, stage: stage)
                controlOffsetX = clamped.width
                controlOffsetY = clamped.height
            }
            .onEnded { _ in dragStartOffset = nil }
    }

    /// 控制条可拖到画面内任意位置，但不会移出视频区域。
    func clampControlOffset(_ proposed: CGSize, stage: CGSize) -> CGSize {
        guard stage.width > 0, stage.height > 0, controlPanelSize.width > 0 else {
            return proposed
        }
        let maxX = max(0, (stage.width - controlPanelSize.width) / 2 - 10)
        let maxUp = max(0, stage.height - controlPanelBottomInset - controlPanelSize.height - 10)
        let dx = min(maxX, max(-maxX, proposed.width))
        let dy = min(controlPanelMaxDownOffset, max(-maxUp, proposed.height))
        return CGSize(width: dx, height: dy)
    }

    /// 窗口尺寸或控制条尺寸变化后，把已保存的偏移重新夹回可见范围。
    func reclampControlOffset(stage: CGSize) {
        let clamped = clampControlOffset(CGSize(width: controlOffsetX, height: controlOffsetY),
                                         stage: stage)
        if clamped.width != CGFloat(controlOffsetX) || clamped.height != CGFloat(controlOffsetY) {
            controlOffsetX = clamped.width
            controlOffsetY = clamped.height
        }
    }

    var speedMenu: some View {
        Menu {
            ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                Button {
                    model.setSpeed(value)
                } label: {
                    if model.speed == value {
                        Label(speedLabel(value), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(value))
                    }
                }
            }
            Divider()
            Menu("音频延迟 \(audioDelayLabel)") {
                Button("音频延后 0.1 秒") { adjustAudioDelay(0.1) }
                Button("音频提前 0.1 秒") { adjustAudioDelay(-0.1) }
                Button("音频延后 0.5 秒") { adjustAudioDelay(0.5) }
                Button("音频提前 0.5 秒") { adjustAudioDelay(-0.5) }
                Button("重置音频延迟") { applyAudioDelay(0) }
            }
        } label: {
            Text(speedLabel(model.speed))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 26)
                .background(Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度与音频延迟")
    }

    var audioDelayLabel: String {
        let milliseconds = Int((playbackSession.audioDelay * 1000).rounded())
        return milliseconds == 0 ? "0 ms" : String(format: "%+d ms", milliseconds)
    }

    func adjustAudioDelay(_ delta: Double) {
        let value = ((playbackSession.audioDelay + delta) * 10).rounded() / 10
        applyAudioDelay(min(2, max(-2, value)))
    }

    /// 音频延迟靠 ffmpeg 滤镜实现：改动后按当前位置重建一次流。
    func applyAudioDelay(_ value: Double) {
        playbackSession.audioDelay = value
        guard playbackSession.streamSession != nil else {
            store.showToast("音频延迟 \(audioDelayLabel)，下次起流生效")
            return
        }
        store.showToast("音频延迟 \(audioDelayLabel)")
        restartStreaming(at: model.currentTime)
    }

    func speedLabel(_ value: Double) -> String {
        String(format: "%g×", value)
    }

}
