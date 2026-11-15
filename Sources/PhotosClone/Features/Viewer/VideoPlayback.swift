import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore

// MARK: - 视频画面

private final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let onPipController: (AVPictureInPictureController?) -> Void

    final class Coordinator {
        var pip: AVPictureInPictureController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
            context.coordinator.pip = controller
            onPipController(controller)
        }
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
    }

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        if coordinator.pip?.isPictureInPictureActive == true {
            coordinator.pip?.stopPictureInPicture()
        }
        coordinator.pip = nil
        nsView.playerLayer.player = nil
    }
}

// MARK: - 进度条

private struct VideoScrubber: View {
    let progress: Double
    let buffered: Double
    let onSeek: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragValue: Double = 0

    private var isExpanded: Bool { isHovering || isDragging }
    private var trackHeight: CGFloat { isExpanded ? 5 : 3.5 }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let value = clamp(isDragging ? dragValue : progress)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.white.opacity(0.38))
                    .frame(width: width * clamp(buffered), height: trackHeight)
                Capsule()
                    .fill(Color.white)
                    .frame(width: width * value, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: isExpanded ? 12 : 9, height: isExpanded ? 12 : 9)
                    .shadow(color: .black.opacity(0.45), radius: 2.5)
                    .offset(x: width * value - (isExpanded ? 6 : 4.5))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        dragValue = clamp(gesture.location.x / width)
                        onSeek(dragValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onCommit(dragValue)
                    }
            )
        }
        .frame(height: 20)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// MARK: - 播放器视图

/// 测量控制条实际尺寸，用于拖拽时把控制条限制在视频区域内。
private struct VideoControlPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 播放器控制按钮：悬停高亮、选中态使用强调色。
private struct VideoControlButton: View {
    let icon: String
    var active = false
    var emphasized = false
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        if let help {
            button.help(help)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: emphasized ? 13.5 : 11.5, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.white.opacity(hovering ? 1 : 0.86))
                .frame(width: emphasized ? 31 : 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering }
        }
    }

    private var fill: Color {
        if active { return Color.accentColor.opacity(0.2) }
        if emphasized { return Color.white.opacity(hovering ? 0.22 : 0.14) }
        return Color.white.opacity(hovering ? 0.14 : 0.001)
    }
}

struct VideoPlayerStage: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let photo: PhotoItem

    @StateObject private var model = VideoPlayerModel()
    @State private var sourceURL: URL?
    @State private var assetOptions: [String: Any] = [:]
    @State private var isPreparing = true
    @State private var failureMessage: String?
    @State private var canTranscode = false
    @State private var isTranscoding = false
    /// 控制层是否处于“刚操作过”的可见状态；播放中静止数秒后自动淡出。
    @State private var controlsShown = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var lastHoverMove = Date.distantPast
    /// 控制条可自由拖动，位置按比例以外的绝对偏移持久化。
    @AppStorage("video.controls.offsetX") private var controlOffsetX: Double = 0
    @AppStorage("video.controls.offsetY") private var controlOffsetY: Double = 0
    @State private var controlPanelSize: CGSize = .zero
    @State private var dragStartOffset: CGSize?
    /// 时长文字点击后显示剩余时间。
    @State private var showRemainingTime = false
    @State private var hasPrevVideo = false
    @State private var hasNextVideo = false

    private var controlsVisible: Bool { controlsShown || !model.isPlaying }

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }

    private var buffered: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.bufferedTime / model.duration))
    }

    private var activeFailure: String? { failureMessage ?? model.errorMessage }

    var body: some View {
        GeometryReader { proxy in
        ZStack {
            Color.black

            if sourceURL != nil, activeFailure == nil {
                PlayerLayerView(player: model.player, gravity: model.gravity) { controller in
                    DispatchQueue.main.async {
                        model.attachPip(controller)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if activeFailure == nil {
                tapLayer
            }

            if isPreparing || (model.isBuffering && model.isPlaying) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }

            if let failure = activeFailure {
                failureView(failure)
            }

            if activeFailure == nil {
                centerPlayButton
                badge
                controls(stage: proxy.size)
            }
        }
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
        .onChange(of: model.isPlaying) { _, playing in
            if playing {
                scheduleControlsHide()
            } else {
                hideControlsTask?.cancel()
                controlsShown = true
            }
        }
        .task(id: photo.id) {
            model.onPlaybackEnd = {
                guard settings.autoPlayNextVideo else { return }
                store.playNextVideo(after: photo.id)
            }
            refreshVideoNeighbors()
            await load()
        }
        .onDisappear {
            hideControlsTask?.cancel()
            model.stop()
        }
        .background(
            KeyEventMonitor { event in
                handleKey(event)
            }
            .frame(width: 0, height: 0)
        )
        }
    }

    /// 视频快捷键：方向键快退/快进，⌘方向键切换上一个/下一个视频。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        guard !flags.contains(.control), !flags.contains(.option) else { return false }

        switch event.keyCode {
        case 123:
            if hasCommand {
                store.viewerStep(-1)
            } else {
                model.seek(by: -5)
            }
            return true
        case 124:
            if hasCommand {
                store.viewerStep(1)
            } else {
                model.seek(by: 5)
            }
            return true
        case 49:
            // 空格与系统「照片」一致：收起查看器回到图库；播放/暂停用 K。
            store.closeViewer()
            return true
        case 43:
            model.stepFrame(by: -1)
            return true
        case 47:
            model.stepFrame(by: 1)
            return true
        default:
            break
        }

        guard !hasCommand else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j":
            model.seek(by: -10)
            return true
        case "k":
            model.togglePlay()
            return true
        case "l":
            model.seek(by: 10)
            return true
        case "m":
            model.isMuted.toggle()
            return true
        case "a":
            toggleGravity()
            return true
        case "f":
            toggleFullScreen()
            return true
        default:
            return false
        }
    }

    private var tapLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                toggleFullScreen()
            }
            .onTapGesture {
                model.togglePlay()
            }
    }

    // MARK: 控制层显隐

    private func handleHoverMove() {
        let now = Date()
        guard now.timeIntervalSince(lastHoverMove) > 0.12 else { return }
        lastHoverMove = now
        revealControls()
    }

    private func revealControls() {
        if !controlsShown {
            withAnimation(.easeOut(duration: 0.18)) { controlsShown = true }
        }
        scheduleControlsHide()
    }

    /// 播放中静止 3 秒后淡出控制层；暂停时控制层始终可见。
    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard model.isPlaying else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.28)) { controlsShown = false }
        }
    }

    private var centerPlayButton: some View {
        let visible = !model.isPlaying && !isPreparing && activeFailure == nil
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

    private var badge: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "video")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    if let resolution = model.resolutionText {
                        Text(resolution)
                    }
                    if let codec = model.codecText, !codec.isEmpty {
                        if model.resolutionText != nil {
                            Text("·")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text(codec)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
            .padding(.trailing, 18)
            .padding(.top, 64)
            Spacer()
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
    }

    private var volumeIcon: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var durationText: String {
        if showRemainingTime, model.duration > 0 {
            return "-" + formatPlayerTime(max(0, model.duration - model.currentTime))
        }
        return formatPlayerTime(model.duration)
    }

    private func controls(stage: CGSize) -> some View {
        VStack {
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
                        .frame(width: 38, alignment: .trailing)
                    VideoScrubber(progress: progress, buffered: buffered) { value in
                        model.seek(to: value * model.duration)
                    } onCommit: { value in
                        model.seek(to: value * model.duration)
                    }
                    Text(durationText)
                        .frame(width: 38, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { showRemainingTime.toggle() }
                        .help("点击切换已播 / 剩余时长")
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 2) {
                    VideoControlButton(icon: model.isPlaying ? "pause.fill" : "play.fill",
                                       emphasized: true,
                                       help: model.isPlaying ? "暂停 (K)" : "播放 (K)") {
                        model.togglePlay()
                    }
                    VideoControlButton(icon: "backward.end", help: "上一个视频 (⌘←)") {
                        store.viewerStepVideo(-1)
                    }
                    .disabled(!hasPrevVideo)
                    VideoControlButton(icon: "gobackward.10", help: "后退 10 秒 (J)") {
                        model.seek(by: -10)
                    }
                    VideoControlButton(icon: "goforward.10", help: "前进 10 秒 (L)") {
                        model.seek(by: 10)
                    }
                    VideoControlButton(icon: "forward.end", help: "下一个视频 (⌘→)") {
                        store.viewerStepVideo(1)
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

                    VideoControlButton(icon: "repeat", active: model.isLooping,
                                       help: model.isLooping ? "关闭循环播放" : "循环播放") {
                        model.isLooping.toggle()
                    }
                    VideoControlButton(icon: "aspectratio", active: model.gravity == .resizeAspectFill,
                                       help: model.gravity == .resizeAspectFill ? "适应画面 (A)" : "填充画面 (A)") {
                        toggleGravity()
                    }
                    VideoControlButton(icon: "pip", active: model.isPipActive, help: "画中画") {
                        model.togglePip()
                    }
                    .disabled(!model.isPipAvailable)
                    VideoControlButton(icon: "camera", help: "保存当前帧") {
                        captureFrame()
                    }
                    VideoControlButton(icon: "arrow.up.left.and.arrow.down.right", help: "全屏 (F)") {
                        toggleFullScreen()
                    }
                }
                .foregroundStyle(.white)
            }
            .frame(maxWidth: 620)
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
            .padding(.bottom, 54)
            .offset(x: controlOffsetX, y: controlOffsetY)
            .gesture(panelDragGesture(stage: stage))
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .scaleEffect(controlsVisible ? 1 : 0.985, anchor: .bottom)
            .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        }
    }

    private func toggleGravity() {
        model.gravity = model.gravity == .resizeAspectFill ? .resizeAspect : .resizeAspectFill
    }

    private func refreshVideoNeighbors() {
        hasPrevVideo = store.hasAdjacentVideo(from: photo.id, delta: -1)
        hasNextVideo = store.hasAdjacentVideo(from: photo.id, delta: 1)
    }

    private func resetControlPanel() {
        withAnimation(.easeOut(duration: 0.2)) {
            controlOffsetX = 0
            controlOffsetY = 0
        }
    }

    private func panelDragGesture(stage: CGSize) -> some Gesture {
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
    private func clampControlOffset(_ proposed: CGSize, stage: CGSize) -> CGSize {
        guard stage.width > 0, stage.height > 0, controlPanelSize.width > 0 else {
            return proposed
        }
        let maxX = max(0, (stage.width - controlPanelSize.width) / 2 - 10)
        let maxUp = max(0, stage.height - 54 - controlPanelSize.height - 10)
        let dx = min(maxX, max(-maxX, proposed.width))
        let dy = min(24, max(-maxUp, proposed.height))
        return CGSize(width: dx, height: dy)
    }

    /// 窗口尺寸或控制条尺寸变化后，把已保存的偏移重新夹回可见范围。
    private func reclampControlOffset(stage: CGSize) {
        let clamped = clampControlOffset(CGSize(width: controlOffsetX, height: controlOffsetY),
                                         stage: stage)
        if clamped.width != CGFloat(controlOffsetX) || clamped.height != CGFloat(controlOffsetY) {
            controlOffsetX = clamped.width
            controlOffsetY = clamped.height
        }
    }

    private var speedMenu: some View {
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
        .help("播放速度")
    }

    private func speedLabel(_ value: Double) -> String {
        String(format: "%g×", value)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.75))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                if canTranscode {
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
                if sourceURL != nil, !photo.isCloud {
                    Button("用其他播放器打开") {
                        if let sourceURL {
                            NSWorkspace.shared.open(sourceURL)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                }
                Button("重试") {
                    Task { await load() }
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

    // MARK: 载入

    private func load() async {
        isPreparing = true
        failureMessage = nil
        canTranscode = false
        isTranscoding = false
        assetOptions = [:]

        guard let url = await resolveURL() else {
            failureMessage = "无法定位视频文件"
            isPreparing = false
            return
        }
        sourceURL = url

        let probe = await VideoSupport.probe(url: url, options: assetOptions)
        let autoplay = settings.autoPlayVideo
        if probe.hasVideoTrack, probe.isPlayable {
            model.load(url: url, options: assetOptions, probe: probe, autoplay: autoplay,
                       loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
            isPreparing = false
            return
        }

        if let cached = cachedTranscodeURL(), FileManager.default.fileExists(atPath: cached.path) {
            let cachedProbe = await VideoSupport.probe(url: cached)
            if cachedProbe.hasVideoTrack, cachedProbe.isPlayable {
                model.load(url: cached, probe: cachedProbe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                isPreparing = false
                return
            }
        }

        isPreparing = false
        if photo.isCloud {
            failureMessage = "该云端视频的编码系统无法直接播放（\(probe.codec ?? "未知编码")）。"
        } else if FFmpeg.isAvailable {
            failureMessage = "该视频编码（\(probe.codec ?? "未知编码")）系统无法直接解码，可转换为 H.264 播放。"
            canTranscode = true
        } else {
            failureMessage = "系统无法解码该视频（\(probe.codec ?? "未知编码")）。安装 ffmpeg 后可自动转换为兼容格式。"
        }
    }

    private func resolveURL() async -> URL? {
        if photo.isCloud {
            guard let stream = await store.cloudStream(for: photo) else { return nil }
            assetOptions = [CloudPlayback.headerFieldsKey: stream.headers]
            return stream.url
        }
        return LibraryPaths.sourceURL(for: photo)
    }

    private func cachedTranscodeURL() -> URL? {
        LibraryPaths.transcodes.appendingPathComponent(photo.id.uuidString + ".mp4")
    }

    private func transcodeAndPlay() {
        guard !isTranscoding, let sourceURL else { return }
        isTranscoding = true
        Task { @MainActor in
            do {
                guard let destination = cachedTranscodeURL() else { return }
                try await VideoSupport.transcode(source: sourceURL, destination: destination)
                let probe = await VideoSupport.probe(url: destination)
                model.load(url: destination, probe: probe, autoplay: true,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                failureMessage = nil
                canTranscode = false
                isTranscoding = false
                store.showToast("已转换为兼容格式并开始播放")
            } catch {
                isTranscoding = false
                failureMessage = "转换失败：\(error.localizedDescription)"
            }
        }
    }

    private func captureFrame() {
        Task { @MainActor in
            guard let image = await model.currentFrameImage() else {
                store.showToast("无法获取当前帧")
                return
            }
            let panel = NSSavePanel()
            let base = (photo.originalName as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "-截图.png"
            panel.canCreateDirectories = true
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                store.showToast("截图保存失败")
                return
            }
            do {
                try data.write(to: url)
                store.showToast("已保存截图")
            } catch {
                store.showToast("截图保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }
}

func formatPlayerTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
