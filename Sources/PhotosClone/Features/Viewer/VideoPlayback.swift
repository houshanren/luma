import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore

// MARK: - 视频画面

private final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()
    /// 窗口内浏览时设为 false：播放器与容器都透明，露出背后的照片模糊灯箱。
    var showsOpaqueBackground = true {
        didSet {
            let color = showsOpaqueBackground ? NSColor.black : NSColor.clear
            layer?.backgroundColor = color.cgColor
            playerLayer.backgroundColor = color.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
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
    var opaqueBackground: Bool = true
    let onPipController: (AVPictureInPictureController?) -> Void

    final class Coordinator {
        var pip: AVPictureInPictureController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.showsOpaqueBackground = opaqueBackground
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
        nsView.showsOpaqueBackground = opaqueBackground
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
        // 视图被移除时兜底停播：避免上层没走 onDisappear 时声音还在响。
        nsView.playerLayer.player?.pause()
        nsView.playerLayer.player = nil
    }
}

// MARK: - 进度条

struct VideoScrubber: View {
    let progress: Double
    let buffered: Double
    /// 轨道与进度点颜色：画面控制条用白色，窗口工具栏跟随明暗外观。
    var tint: Color = .white
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
                    .fill(tint.opacity(0.18))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(tint.opacity(0.38))
                    .frame(width: width * clamp(buffered), height: trackHeight)
                Capsule()
                    .fill(tint)
                    .frame(width: width * value, height: trackHeight)
                Circle()
                    .fill(tint)
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
    /// 播放状态由查看器持有：顶栏融合模式下，窗口工具栏要用同一份状态渲染播放控件。
    @ObservedObject var model: VideoPlayerModel
    /// 手动旋转角度同样提到查看器，顶栏按钮与画面共用。
    @Binding var quarterTurns: Int
    /// 保存当前帧需要读取查看器里的照片与旋转状态，由查看器提供。
    var onCaptureFrame: () -> Void = {}
    /// 窗口内浏览：播放器透明，画面两侧露出照片模糊灯箱。
    var transparentBackground: Bool = false
    /// 查看器的缩放与位移：只作用于画面，控制层始终保持原尺寸。
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    @State private var sourceURL: URL?
    /// 云端直链要求的请求头（WebDAV 的 Basic 认证等），转码时同样要带上。
    @State private var sourceHeaders: [String: String] = [:]
    /// 百度直链不带扩展名、要求固定 UA，且会 302 到 CDN；
    /// 用资源加载器转发，保证每一跳都带请求头并补全 Content-Type。
    @State private var cloudResourceLoader: CloudAssetResourceLoader?
    /// 播放器是否已经装上片子。PhotoKit 返回的素材可能没有本地 URL，不能只看 sourceURL。
    @State private var hasLoadedVideo = false
    @State private var assetOptions: [String: Any] = [:]
    @State private var isPreparing = true
    @State private var failureMessage: String?
    /// 云端直链获取失败的具体原因（授权、文件 ID、接口错误等）。
    @State private var streamFailure: String?
    @State private var canTranscode = false
    @State private var isTranscoding = false
    /// 边下边播：ffmpeg 转封装 + 本机回环 HLS 服务，随播放进度释放。
    @State private var streamSession: VideoStreamSession?
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
    /// 视频原始尺寸（仅影响播放显示，不改原文件）。
    @State private var videoSize: CGSize = .zero
    /// 载入代次：连续翻页时旧任务从 await 恢复后不能再把上一个视频装进播放器，
    /// 否则界面已经切到别的照片，旧视频的声音还在继续。
    @State private var loadGeneration = 0
    /// 播放器真正所在的窗口：全屏按钮必须切换这个窗口，
    /// 用 NSApp.keyWindow 在弹出面板 / 子窗口存在时会切错窗口。
    @State private var playerWindow: NSWindow?

    /// 控制条距视频底部的默认间距；向上拖动的下限与之一致。
    private let controlPanelBottomInset: CGFloat = 28
    /// 允许向下拖动控制条的距离上限，避免贴到画面边缘。
    private let controlPanelMaxDownOffset: CGFloat = 16

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
            if !transparentBackground {
                Color.black
            }

            if hasLoadedVideo, activeFailure == nil {
                let frame = playerFrame(in: proxy.size)
                PlayerLayerView(player: model.player,
                                gravity: model.gravity,
                                opaqueBackground: !transparentBackground) { controller in
                    DispatchQueue.main.async {
                        model.attachPip(controller)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .rotationEffect(.degrees(Double(quarterTurns) * 90))
                .scaleEffect(zoom)
                .offset(offset)
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
                // 顶栏融合由窗口工具栏渲染控件；全屏沉浸没有工具栏，仍用画面内控制条。
                if settings.videoControlPlacement == .floating || !transparentBackground {
                    controls(stage: proxy.size)
                }
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
            loadGeneration &+= 1
            let generation = loadGeneration
            // 先停掉上一个视频：新视频的 URL / 探测还是要等一会，
            // 期间旧音频继续播会让"画面已经是别的照片，声音还在"。
            model.stop()
            cloudResourceLoader?.invalidate()
            cloudResourceLoader = nil
            streamSession?.stop()
            streamSession = nil
            sourceURL = nil
            sourceHeaders = [:]
            hasLoadedVideo = false
            model.onPlaybackEnd = {
                guard settings.autoPlayNextVideo else { return }
                store.playNextVideo(after: photo.id)
            }
            quarterTurns = 0
            videoSize = .zero
            refreshVideoNeighbors()
            await load(generation: generation)
        }
        .onDisappear {
            FullScreenDiagnostics.log("video stage disappear \(photo.originalName)")
            loadGeneration &+= 1
            hideControlsTask?.cancel()
            model.stop()
            cloudResourceLoader?.invalidate()
            cloudResourceLoader = nil
            streamSession?.stop()
            streamSession = nil
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
    }

    /// 视频快捷键：← / → 翻页，↑ / ↓ 按设置步长快进快退（默认 5 秒）；J / L 固定 10 秒；
    /// ⌘ 方向键只切换上一个 / 下一个视频，避免与翻页冲突。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)

        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于固定键位匹配。
        if !hasCommand, handleCustomShortcut(event) { return true }

        guard !flags.contains(.control), !flags.contains(.option) else { return false }

        switch event.keyCode {
        case 123:
            if hasCommand {
                store.viewerStepVideo(-1)
            } else {
                store.viewerStep(-1)
            }
            return true
        case 124:
            if hasCommand {
                store.viewerStepVideo(1)
            } else {
                store.viewerStep(1)
            }
            return true
        case 126:
            if hasCommand {
                store.viewerStepVideo(-1)
            } else {
                model.seek(by: settings.videoSeekStep)
            }
            return true
        case 125:
            if hasCommand {
                store.viewerStepVideo(1)
            } else {
                model.seek(by: -settings.videoSeekStep)
            }
            return true
        case 49:
            // 空格与系统「照片」一致：收起查看器回到图库；播放/暂停用 K 或回车。
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

    /// 设置 › 快捷键里可自定义的播放器动作。
    private func handleCustomShortcut(_ event: NSEvent) -> Bool {
        if ShortcutStore.matches(event, .videoPlayPause) {
            model.togglePlay()
            return true
        }
        if ShortcutStore.matches(event, .videoMute) {
            model.isMuted.toggle()
            return true
        }
        if ShortcutStore.matches(event, .videoForward) {
            model.seek(by: 10)
            return true
        }
        if ShortcutStore.matches(event, .videoBackward) {
            model.seek(by: -10)
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
                    VideoControlButton(icon: "backward.end", help: "上一个视频 (⌘↑)") {
                        store.viewerStepVideo(-1)
                    }
                    .disabled(!hasPrevVideo)
                    VideoControlButton(icon: "gobackward.10", help: "后退 10 秒 (J)") {
                        model.seek(by: -10)
                    }
                    VideoControlButton(icon: "goforward.10", help: "前进 10 秒 (L)") {
                        model.seek(by: 10)
                    }
                    VideoControlButton(icon: "forward.end", help: "下一个视频 (⌘↓)") {
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
                    VideoControlButton(icon: "rotate.right", active: quarterTurns != 0, help: "旋转 90° (R)") {
                        rotatePlayer()
                    }
                    VideoControlButton(icon: "pip", active: model.isPipActive, help: "画中画") {
                        model.togglePip()
                    }
                    .disabled(!model.isPipAvailable)
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

    private func toggleGravity() {
        model.gravity = model.gravity == .resizeAspectFill ? .resizeAspect : .resizeAspectFill
    }

    private func rotatePlayer() {
        withAnimation(.easeInOut(duration: 0.22)) {
            quarterTurns = (quarterTurns + 1) % 4
        }
    }

    /// 旋转后按画面比例计算播放层尺寸；填充模式下按铺满计算，避免旋转后出现黑边。
    private func playerFrame(in stage: CGSize) -> CGSize {
        guard stage.width > 0, stage.height > 0 else { return stage }
        let natural = videoSize.width > 0 && videoSize.height > 0 ? videoSize : stage
        let swapped = quarterTurns % 2 == 1
        let aspect = swapped ? natural.height / natural.width : natural.width / natural.height
        guard aspect.isFinite, aspect > 0 else { return stage }
        var width = stage.width
        var height = width / aspect
        if model.gravity == .resizeAspectFill {
            if height < stage.height {
                height = stage.height
                width = height * aspect
            }
        } else if height > stage.height {
            height = stage.height
            width = height * aspect
        }
        return swapped ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
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
        let maxUp = max(0, stage.height - controlPanelBottomInset - controlPanelSize.height - 10)
        let dx = min(maxX, max(-maxX, proposed.width))
        let dy = min(controlPanelMaxDownOffset, max(-maxUp, proposed.height))
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

    // MARK: 载入

    private func load(generation: Int) async {
        FullScreenDiagnostics.log("video load start \(photo.originalName) generation=\(generation)")
        isPreparing = true
        failureMessage = nil
        streamFailure = nil
        canTranscode = false
        isTranscoding = false
        assetOptions = [:]
        sourceHeaders = [:]
        hasLoadedVideo = false
        cloudResourceLoader?.invalidate()
        cloudResourceLoader = nil
        streamSession?.stop()
        streamSession = nil

        let autoplay = settings.autoPlayVideo
        let source = await resolveSource()
        guard generation == loadGeneration, !Task.isCancelled else { return }
        var failedProbe: VideoProbe?

        // 百度直链：URL 没有扩展名、AVPlayer 跳转后不会继续带 UA；
        // WebDAV：必须带 Basic 认证头，AVPlayer 直连不会发送；
        // 两者都由资源加载器代取，探测与播放都拿到明确的 Content-Type。
        var playbackAsset: AVAsset?
        var playbackURL = source?.url
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
        if let playbackURL, canUseLocal {
            let probe: VideoProbe
            if let playbackAsset {
                probe = await VideoSupport.probe(asset: playbackAsset)
            } else {
                probe = await VideoSupport.probe(url: playbackURL, options: assetOptions)
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if probe.hasVideoTrack, probe.isPlayable {
                videoSize = probe.size
                if let playbackAsset {
                    model.load(asset: playbackAsset, probe: probe, autoplay: autoplay,
                               loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                } else {
                    model.load(url: playbackURL, options: assetOptions, probe: probe, autoplay: autoplay,
                               loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                }
                hasLoadedVideo = true
                isPreparing = false
                return
            }
            failedProbe = probe
            if photo.isCloud {
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

        if let cached = cachedTranscodeURL(), FileManager.default.fileExists(atPath: cached.path) {
            let cachedProbe = await VideoSupport.probe(url: cached)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if cachedProbe.hasVideoTrack, cachedProbe.isPlayable {
                sourceURL = cached
                videoSize = cachedProbe.size
                model.load(url: cached, probe: cachedProbe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                hasLoadedVideo = true
                isPreparing = false
                return
            }
        }

        // 系统「照片」图库：本机没有原图时交给 PhotoKit，
        // 共享相簿与仅存 iCloud 的视频会由 Photos 自己下载后再交给播放器。
        if photo.isSystem {
            guard let resolved = await PhotoKitBridge.videoAsset(id: photo.id) else {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                failureMessage = "无法从系统「照片」图库读取该视频，可能仍在 iCloud 或共享相簿中下载。"
                isPreparing = false
                return
            }
            let probe = await VideoSupport.probe(asset: resolved.asset)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if probe.hasVideoTrack, probe.isPlayable {
                sourceURL = resolved.url
                videoSize = probe.size
                model.load(asset: resolved.asset, probe: probe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                hasLoadedVideo = true
                isPreparing = false
                return
            }
            failedProbe = probe
        }

        // 系统不支持的容器（MKV / AVI…）：ffmpeg 边下载边封装成 fMP4 HLS，
        // 第一段分片就绪即可播放，不必等整部文件下载 / 转换完。
        let formatName = Self.formatDescription(name: photo.originalName, codec: failedProbe?.codec)
        if let sourceURL, FFmpeg.isAvailable {
            // 不弹「正在准备」告警卡片：直接进入播放界面转圈，首段就绪后自动开播。
            failureMessage = nil
            isPreparing = true
            let session = VideoStreamSession(photoID: photo.id,
                                             source: sourceURL,
                                             headers: sourceHeaders,
                                             trustSelfSigned: store.cloudMount(for: photo.cloudMountID)?.trustSelfSigned ?? false)
            do {
                let playlist = try await session.start()
                guard generation == loadGeneration, !Task.isCancelled else {
                    session.stop()
                    return
                }
                streamSession = session
                var probe = VideoProbe()
                probe.hasVideoTrack = true
                probe.isPlayable = true
                probe.duration = failedProbe?.duration ?? 0
                probe.size = failedProbe?.size ?? .zero
                videoSize = probe.size
                model.load(url: playlist, probe: probe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                hasLoadedVideo = true
                failureMessage = nil
                isPreparing = false
                canTranscode = false
                return
            } catch {
                session.stop()
                // 翻页 / 关闭播放器导致的取消不算失败，也不要弹提示。
                guard generation == loadGeneration, !Task.isCancelled else { return }
                isPreparing = false
                failureMessage = "边下边播启动失败：\(error.localizedDescription)"
                // 兜底：仍可走完整转换（下载完再播放）。
                canTranscode = true
                return
            }
        }

        isPreparing = false
        if photo.isCloud {
            failureMessage = "该云端视频（\(formatName)）系统无法直接播放。"
                + "安装 ffmpeg（brew install ffmpeg）后可转换为兼容格式。"
        } else {
            failureMessage = "系统无法解码该视频（\(formatName)）。安装 ffmpeg 后可自动转换为兼容格式。"
        }
    }

    /// MKV / AVI 这类容器 AVFoundation 根本不解析，探测拿不到编码，直接说明容器更准确。
    private static func formatDescription(name: String, codec: String?) -> String {
        let unsupported: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "rmvb", "rm",
                                        "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv",
                                        "divx", "mxf", "asf"]
        let ext = (name as NSString).pathExtension.lowercased()
        if unsupported.contains(ext) { return "\(ext.uppercased()) 容器" }
        return codec ?? "未知编码"
    }

    private func resolveSource() async -> (url: URL, headers: [String: String])? {
        if photo.isCloud {
            do {
                let stream = try await store.cloudStreamOrThrow(for: photo)
                return (stream.url, stream.headers)
            } catch {
                streamFailure = error.localizedDescription
                return nil
            }
        }
        return (LibraryPaths.sourceURL(for: photo), [:])
    }

    private func cachedTranscodeURL() -> URL? {
        LibraryPaths.transcodes.appendingPathComponent(photo.id.uuidString + ".mp4")
    }

    private func transcodeAndPlay() {
        guard !isTranscoding, let sourceURL else { return }
        isTranscoding = true
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
                        destination: destination)
                } else {
                    try await VideoSupport.transcode(source: sourceURL, destination: destination)
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
                model.load(url: destination, probe: probe, autoplay: true,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                hasLoadedVideo = true
                failureMessage = nil
                canTranscode = false
                isTranscoding = false
                store.showToast("已转换为兼容格式并开始播放")
            } catch {
                guard generation == loadGeneration else { return }
                isTranscoding = false
                failureMessage = "转换失败：\(error.localizedDescription)"
            }
        }
    }

    private func toggleFullScreen() {
        // 优先用播放器自己所在的窗口：弹出面板 / 子窗口抢到 key 时也不会切错窗口。
        let target = playerWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        FullScreenDiagnostics.log("toggleFullScreen window=\(String(describing: target)) isFullScreen=\(target?.styleMask.contains(.fullScreen) ?? false)")
        target?.toggleFullScreen(nil)
    }
}

// MARK: - 窗口工具栏里的播放控件

/// 顶栏播放按钮：尺寸大于系统工具栏图标，带悬停浮层与选中强调色。
struct VideoDeckButton: View {
    let icon: String
    var active = false
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.accentColor
                                        : Color.primary.opacity(hovering ? 1 : 0.82))
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.16)
                                     : Color.primary.opacity(hovering ? 0.09 : 0.001))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .animation(.snappy(duration: 0.18), value: active)
        .help(help ?? "")
    }
}

/// 工具栏左侧的播放控制组：紧挨返回按钮，与工具栏共用同一行。
struct VideoToolbarTransport: View {
    @ObservedObject var model: VideoPlayerModel
    let hasPrev: Bool
    let hasNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            VideoDeckButton(icon: "backward.end.fill", help: "上一个视频 (⌘↑)") {
                onPrev()
            }
            .disabled(!hasPrev)

            transportDivider

            VideoDeckButton(icon: "gobackward.10", help: "后退 10 秒 (J)") {
                model.seek(by: -10)
            }

            playButton

            VideoDeckButton(icon: "goforward.10", help: "前进 10 秒 (L)") {
                model.seek(by: 10)
            }

            transportDivider

            VideoDeckButton(icon: "forward.end.fill", help: "下一个视频 (⌘↓)") {
                onNext()
            }
            .disabled(!hasNext)
        }
        // 工具栏会把胶囊背景贴着内容绘制：这里留出内边距，图标才不会顶到胶囊边缘。
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .fixedSize()
    }

    private var transportDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 13)
            .padding(.horizontal, 1)
    }

    private var playButton: some View {
        Button {
            model.togglePlay()
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(Color.accentColor)
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                }
                .shadow(color: Color.accentColor.opacity(0.30), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: model.isPlaying)
        .help(model.isPlaying ? "暂停 (K)" : "播放 (K)")
    }
}

/// 工具栏中部的进度行：当前时间 / 可拖动进度条 / 总时长（点击切换剩余时间）。
struct VideoToolbarProgress: View {
    @ObservedObject var model: VideoPlayerModel
    @Binding var showsRemaining: Bool

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }

    private var buffered: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.bufferedTime / model.duration))
    }

    private var durationText: String {
        if showsRemaining, model.duration > 0 {
            return "-" + formatPlayerTime(max(0, model.duration - model.currentTime))
        }
        return formatPlayerTime(model.duration)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(formatPlayerTime(model.currentTime))
                .frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText())

            VideoScrubber(progress: progress,
                          buffered: buffered,
                          tint: Color.primary.opacity(0.78)) { value in
                model.seek(to: value * model.duration)
            } onCommit: { value in
                model.seek(to: value * model.duration)
            }
            .frame(minWidth: 120, idealWidth: 190, maxWidth: 220)

            Text(durationText)
                .frame(width: 44, alignment: .leading)
                .contentTransition(.numericText())
                .contentShape(Rectangle())
                .onTapGesture { showsRemaining.toggle() }
                .help("点击切换已播 / 剩余时长")
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help("拖动进度条定位")
    }
}

/// 工具栏音量：扬声器图标（点击静音/恢复）+ 紧凑滑杆。
/// 顶栏融合模式把控制条收进了工具栏，音量大小也要能直接拖，不再只藏在菜单里。
struct VideoToolbarVolume: View {
    @ObservedObject var model: VideoPlayerModel

    private var icon: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if model.volume == 0 {
                    model.volume = 1
                    model.isMuted = false
                } else {
                    model.isMuted.toggle()
                }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.isMuted ? "取消静音 (M)" : "静音 (M)")

            Slider(value: $model.volume, in: 0...1) { editing in
                if editing, model.isMuted { model.isMuted = false }
            }
            .controlSize(.mini)
            .frame(width: 72)
            .help("音量")
        }
        .fixedSize()
    }
}

/// 工具栏右侧的播放选项：把倍速、循环、填充、旋转、画中画、音量与截图收进一个菜单，
/// 顶栏只留一枚入口，避免按钮挤在一起。
struct VideoToolbarOptions: View {
    @ObservedObject var model: VideoPlayerModel
    let quarterTurns: Int
    let onRotate: () -> Void
    let onCapture: () -> Void

    private var gravityFilled: Binding<Bool> {
        Binding(get: { model.gravity == .resizeAspectFill },
                set: { model.gravity = $0 ? .resizeAspectFill : .resizeAspect })
    }

    private var pipActive: Binding<Bool> {
        Binding(get: { model.isPipActive },
                set: { active in
                    guard active != model.isPipActive else { return }
                    model.togglePip()
                })
    }

    var body: some View {
        Menu {
            Section("播放速度") {
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
            }

            Section("画面") {
                Toggle("循环播放", isOn: $model.isLooping)
                Toggle("填充画面", isOn: gravityFilled)
                Button("旋转 90°") { onRotate() }
                Toggle("画中画", isOn: pipActive)
                    .disabled(!model.isPipAvailable)
            }

            Section("声音") {
                Toggle("静音", isOn: $model.isMuted)
                Button("音量 25%") { model.volume = 0.25; model.isMuted = false }
                Button("音量 50%") { model.volume = 0.5; model.isMuted = false }
                Button("音量 100%") { model.volume = 1; model.isMuted = false }
            }

            Divider()

            Button("保存当前帧…") { onCapture() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.82))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(quarterTurns == 0 ? "播放选项" : "播放选项（画面已旋转）")
    }

    private func speedLabel(_ value: Double) -> String {
        String(format: "%g×", value)
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
