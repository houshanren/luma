import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers

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
    /// 进度点的描边色：白点配深描边，彩色点配白描边，深浅底上都能看清。
    var knobBorder: Color = .white.opacity(0.6)
    /// 总时长：用于预览气泡上的时间标签。
    var duration: Double = 0
    /// 悬停 / 拖动时取该比例处的画面帧；为空则不显示预览。
    var thumbnailPreview: ((Double) async -> NSImage?)?
    let onSeek: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragValue: Double = 0
    @State private var previewImage: NSImage?
    @State private var previewFraction: Double?
    @State private var previewTask: Task<Void, Never>?

    private var isExpanded: Bool { isHovering || isDragging }
    private var trackHeight: CGFloat { isExpanded ? 4.5 : 3 }
    private var knobSize: CGFloat { isExpanded ? 12 : 8 }
    private var haloSize: CGFloat { isExpanded ? 21 : 14 }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let value = clamp(isDragging ? dragValue : progress)
            let playedWidth = width * value
            ZStack(alignment: .leading) {
                // 轨道：内凹细槽 + 细描边，像一条嵌进玻璃里的轨道。
                Capsule()
                    .fill(tint.opacity(0.13))
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(0.10), lineWidth: 0.5)
                    }

                // 缓冲段：更浅的一层，能看出已加载范围。
                Capsule()
                    .fill(tint.opacity(0.26))
                    .frame(width: width * clamp(buffered), height: trackHeight)

                // 已播放段：渐变轨道，收尾处更亮。
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: playedWidth, height: trackHeight)

                // 进度点：外圈柔光 + 实心圆 + 细描边，悬停 / 拖动时整体放大。
                knob
                    .offset(x: playedWidth - knobSize / 2)
                    .animation(.spring(response: 0.26, dampingFraction: 0.72), value: isExpanded)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .topLeading) {
                previewBubble(width: width)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    isHovering = true
                    requestPreview(clamp(point.x / width))
                case .ended:
                    isHovering = false
                    if !isDragging { clearPreview() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        dragValue = clamp(gesture.location.x / width)
                        requestPreview(dragValue)
                        onSeek(dragValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                        clearPreview()
                        onCommit(dragValue)
                    }
            )
        }
        .frame(height: 16)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            if !hovering, !isDragging { clearPreview() }
        }
    }

    @ViewBuilder
    private func previewBubble(width: CGFloat) -> some View {
        if let previewImage, let previewFraction {
            let bubbleWidth: CGFloat = 168
            let bubbleHeight: CGFloat = 95
            let x = min(max(0, width * previewFraction - bubbleWidth / 2), max(0, width - bubbleWidth))
            Image(nsImage: previewImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: bubbleWidth, height: bubbleHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.7)
                }
                .overlay(alignment: .bottomTrailing) {
                    if duration > 0 {
                        Text(formatPreviewTime(duration * previewFraction))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(.black.opacity(0.55), in: Capsule(style: .continuous))
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                .offset(x: x, y: -(bubbleHeight + 12))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func requestPreview(_ fraction: Double) {
        guard let thumbnailPreview else { return }
        previewFraction = fraction
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard !Task.isCancelled else { return }
            let image = await thumbnailPreview(fraction)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { previewImage = image }
        }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewImage = nil
        previewFraction = nil
    }

    private func formatPreviewTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 进度点：一团柔光托着一颗镜头对焦点似的小圆。
    private var knob: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(isExpanded ? 0.32 : 0.16))
                .frame(width: haloSize, height: haloSize)
                .blur(radius: isExpanded ? 3.5 : 2.5)

            Circle()
                .fill(tint)
                .frame(width: knobSize, height: knobSize)
                .overlay {
                    Circle().strokeBorder(knobBorder, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
        }
    }
}

// MARK: - 缓冲提示

/// 起播 / 缓冲 / 跳转落地前的等待动画：一圈渐变弧 + 呼吸光点。
/// 延迟 0.22 秒出现，本地秒开或短跳转不会闪一下白圈。
private struct VideoBufferingOverlay: View {
    let active: Bool
    var label: String = "缓冲中"

    @State private var visible = false
    @State private var spinning = false
    @State private var pulsing = false

    var body: some View {
        Group {
            if visible {
                VStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 2.4)
                        Circle()
                            .trim(from: 0, to: 0.62)
                            .stroke(AngularGradient(colors: [Color.accentColor.opacity(0.15),
                                                             Color.accentColor,
                                                             LumaBrand.cyan],
                                                    center: .center,
                                                    startAngle: .degrees(0),
                                                    endAngle: .degrees(360)),
                                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .rotationEffect(.degrees(spinning ? 360 : 0))
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: 4)
                            .scaleEffect(pulsing ? 1.7 : 0.7)
                            .opacity(pulsing ? 0.32 : 1)
                    }
                    .frame(width: 40, height: 40)

                    Text(label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: visible)
        .allowsHitTesting(false)
        .task(id: active) {
            guard active else {
                visible = false
                spinning = false
                pulsing = false
                return
            }
            // 等一小会儿再出现：进度条小跳一下不该闪出加载动画。
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            visible = true
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                spinning = true
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/// 起播等待页：模糊缩略图 + 片名 + 缓慢漂移的短句，替代纯黑屏。
/// 没有缩略图（网络 / 云盘源）时退回深色渐变，同样不会留一块空白。
private struct VideoLoadingStage: View {
    let active: Bool
    let title: String
    let thumbnail: NSImage?

    @State private var visible = false
    @State private var spinning = false
    @State private var drifting = false
    @State private var hintIndex = 0

    private static let hints = [
        "正在唤醒放映机",
        "正在接通片源",
        "正在准备第一帧",
        "正在校对音轨与字幕",
        "马上就好"
    ]

    var body: some View {
        ZStack {
            if visible {
                backdrop
                content
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.24), value: visible)
        .allowsHitTesting(false)
        .task(id: active) {
            guard active else {
                visible = false
                spinning = false
                drifting = false
                return
            }
            // 本地秒开时不要闪一下：等一小会儿再露面。
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            visible = true
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                spinning = true
            }
            // 背景极慢地推近，等待时不至于完全静止。
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                drifting = true
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    hintIndex = (hintIndex + 1) % Self.hints.count
                }
            }
        }
    }

    private var backdrop: some View {
        Color.clear
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [Color(white: 0.13), Color(white: 0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .blur(radius: thumbnail == nil ? 0 : 44, opaque: true)
            .scaleEffect(drifting ? 1.12 : 1.05)
            .overlay {
                LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.74)],
                               startPoint: .top, endPoint: .bottom)
            }
    }

    private var content: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2.6)
                Circle()
                    .trim(from: 0, to: 0.62)
                    .stroke(AngularGradient(colors: [Color.accentColor.opacity(0.12),
                                                     Color.accentColor,
                                                     LumaBrand.cyan],
                                            center: .center,
                                            startAngle: .degrees(0),
                                            endAngle: .degrees(360)),
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 46, height: 46)

            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                ZStack {
                    Text(Self.hints[hintIndex])
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                        .id(hintIndex)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
                .frame(height: 15)
            }
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, 48)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
    }
}

/// 工具栏播放按钮里的迷你缓冲环。
private struct VideoMiniSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.62)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spinning = true
                }
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
    @EnvironmentObject private var viewer: ViewerModel
    let photo: PhotoItem
    /// 播放状态由查看器持有：顶栏融合模式下，窗口工具栏要用同一份状态渲染播放控件。
    @ObservedObject var model: VideoPlayerModel
    /// 音轨 / 字幕状态：与窗口顶栏共享同一份。
    @ObservedObject var ui: VideoPlaybackUI
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
    /// 起播阶段的底图：本地视频直接读缩略图做模糊背景，网络源没有就退回渐变。
    @State private var loadingThumbnail: NSImage?
    @State private var failureMessage: String?
    /// 云端直链获取失败的具体原因（授权、文件 ID、接口错误等）。
    @State private var streamFailure: String?
    @State private var canTranscode = false
    @State private var isTranscoding = false
    /// 边下边播：ffmpeg 转封装 + 本机回环 HLS 服务，随播放进度释放。
    @State private var streamSession: VideoStreamSession?
    /// 当前边下边播的模式：转封装失败后降级为重编码。
    @State private var streamMode: VideoStreamSession.Mode = .remux
    /// 当前会话的起播位置；拖动到未生成区间会用 -ss 重新起流。
    @State private var streamOffset: Double = 0
    @State private var streamAudioIndex = 0
    @State private var isRestartingStream = false
    /// 探测到的完整时长 / 编码信息：跳转后的新会话仍按完整时间轴显示进度。
    @State private var probeDuration: Double = 0
    @State private var probeIsHEVC = false
    @State private var probeIsHDR = false
    @State private var probeAudioCount = 0
    @State private var probeAudioTracks: [AudioTrackInfo] = []
    /// ffprobe 补齐的完整技术信息：码率 / 帧率 / HDR / 章节。
    @State private var playbackProbe = VideoProbe()
    /// I 键播放信息叠加。
    @State private var showPlaybackInfo = false
    /// 播放中定期清理旧分片，给长片一个可控的磁盘窗口。
    @State private var trimTask: Task<Void, Never>?
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

    /// 还没有第一帧：源解析中，或播放器已装片但 item 还没 ready。
    /// 这段时间最容易看起来「黑屏 / 像被暂停了」，用起播提示兜住。
    private var isFirstFramePending: Bool {
        guard activeFailure == nil else { return false }
        return isPreparing || (hasLoadedVideo && !model.isItemReady)
    }

    /// 读取本地缩略图做起播背景；网络 / 云盘视频没有对应文件时返回 nil。
    private func fileExistsThumbnail() -> NSImage? {
        let url = LibraryPaths.thumbnailURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 等待层：起播用整页遮挡，出画面后的卡顿用紧凑胶囊。
    @ViewBuilder
    private var waitingLayer: some View {
        if activeFailure == nil {
            VideoLoadingStage(active: isFirstFramePending,
                              title: photo.title ?? photo.originalName,
                              thumbnail: loadingThumbnail)
            if !isFirstFramePending {
                VideoBufferingOverlay(active: model.isStalled, label: "缓冲中")
            }
        }
    }

    /// 当前时间点应显示的外挂字幕（已套用字幕偏移）。
    private var activeSubtitle: String? {
        ui.cue(at: model.currentTime)?.text
    }

    private var subtitleTextColor: Color {
        switch settings.subtitleColor {
        case "yellow": return Color(red: 1.0, green: 0.86, blue: 0.38)
        case "cyan": return Color(red: 0.45, green: 0.95, blue: 0.98)
        case "green": return Color(red: 0.58, green: 0.98, blue: 0.66)
        default: return .white
        }
    }

    private func subtitleBottomPadding(in size: CGSize) -> CGFloat {
        switch settings.subtitlePosition {
        case "middle": return max(160, size.height * 0.34)
        case "lower": return 190
        default: return 118
        }
    }

    // MARK: 播放信息 / 章节

    /// I 键信息叠加：码率 / 帧率 / HDR / 音轨 / 章节，全部来自起播后补的 ffprobe。
    private var playbackInfoOverlay: some View {
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

            infoLine("画面", playbackResolutionText)
            infoLine("编码", playbackCodecText)
            infoLine("码率", playbackBitrateText)
            infoLine("帧率", playbackFrameRateText)
            infoLine("HDR", playbackProbe.hdrLabel ?? (playbackProbe.isHDR ? "HDR" : "SDR"))
            infoLine("音轨", playbackAudioText)
            infoLine("章节", playbackProbe.chapters.isEmpty ? "无" : "\(playbackProbe.chapters.count) 个")
            if let burn = ui.burnSubtitleName {
                infoLine("烧录", burn)
            }
            infoLine("输出", "系统默认输出")
        }
        .padding(14)
        .frame(width: 266)
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

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var playbackResolutionText: String {
        let size = playbackProbe.size.width > 0 ? playbackProbe.size : videoSize
        guard size.width > 0, size.height > 0 else { return "—" }
        return "\(Int(size.width))×\(Int(size.height))"
    }

    private var playbackCodecText: String {
        var parts: [String] = []
        if let codec = playbackProbe.codec ?? photo.videoCodec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if let container = playbackProbe.containerName, !container.isEmpty {
            parts.append(container)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var playbackBitrateText: String {
        let bitrate = playbackProbe.bitrate
        guard bitrate > 0 else { return "—" }
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        }
        return "\(bitrate / 1000) kbps"
    }

    private var playbackFrameRateText: String {
        playbackProbe.frameRate > 0
            ? String(format: "%.2f fps", playbackProbe.frameRate)
            : "—"
    }

    private var playbackAudioText: String {
        let tracks = playbackProbe.audioTracks.isEmpty ? probeAudioTracks : playbackProbe.audioTracks
        guard let first = tracks.first else { return "—" }
        let base = first.displayName.isEmpty ? "音轨 1" : first.displayName
        return tracks.count > 1 ? "\(base) · 共 \(tracks.count) 轨" : base
    }

    /// 章节跳转：⌥← / ⌥→ 与章节菜单共用；没有章节时返回 false，让按键继续走原逻辑。
    @discardableResult
    private func seekChapter(step: Int) -> Bool {
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

    private var chapterMenu: some View {
        Menu {
            ForEach(playbackProbe.chapters) { chapter in
                Button {
                    seekPlayback(to: chapter.start)
                } label: {
                    if model.currentTime >= chapter.start - 0.4, model.currentTime < chapter.end {
                        Label(chapter.title, systemImage: "checkmark")
                    } else {
                        Text(chapter.title)
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("章节（⌥← / ⌥→）")
    }

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

            // 起播阶段：模糊缩略图 + 片名 + 轮换短句，别让用户盯着一块黑屏。
            // 出画面之后的卡顿 / 跳转才用紧凑的缓冲胶囊。
            waitingLayer

            if let failure = activeFailure {
                failureView(failure)
            }

            if activeFailure == nil, let subtitle = activeSubtitle {
                VStack {
                    Spacer()
                    Text(subtitle)
                        .font(.system(size: settings.subtitleFontSize, weight: .semibold))
                        .foregroundStyle(subtitleTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(settings.subtitleBackground ? Color.black.opacity(0.55) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(settings.subtitleBackground ? 0.6 : 0.9), radius: 3, y: 1)
                        .frame(maxWidth: 860)
                        .padding(.horizontal, 40)
                        .padding(.bottom, subtitleBottomPadding(in: proxy.size))
                }
                .allowsHitTesting(false)
            }

            if activeFailure == nil {
                centerPlayButton
                // 顶栏融合由窗口工具栏渲染控件；视频真全屏时工具栏被隐藏，改用画面内控制条。
                if settings.videoControlPlacement == .floating || !transparentBackground
                    || viewer.videoImmersiveFullScreen {
                    controls(stage: proxy.size)
                }
                // 顶栏融合模式下音轨 / 字幕入口在窗口工具栏的播放舱里。
            }

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
            // 暂停时挂起转码进程，避免在后台把整部片转成缓存。
            streamSession?.setGenerationActive(playing)
        }
        // 转封装后的 HLS 也可能在解码阶段失败：这时必须把「转换为兼容格式」入口放出来，
        // 否则用户只能停在错误页。真正的兼容性判断由 ffmpeg 转码兜底。
        .onChange(of: model.errorMessage) { _, message in
            guard message != nil, hasLoadedVideo, FFmpeg.isAvailable, sourceURL != nil else { return }
            canTranscode = true
        }
        // 原生容器的音轨组就绪 / 切换后，把选项同步给顶栏与画面内菜单。
        .onChange(of: model.audioOptions.count) { _, _ in refreshAudioChoices() }
        .onChange(of: model.selectedAudio) { _, _ in refreshAudioChoices() }
        .task(id: photo.id) {
            loadGeneration &+= 1
            let generation = loadGeneration
            // 起播底图：本地视频的缩略图先垫一层模糊背景，网络源没有就退回渐变。
            loadingThumbnail = fileExistsThumbnail()
            // 网络资源：用当前剧集的封面做起播底图，海报已缓存时几乎瞬间就有。
            if loadingThumbnail == nil,
               let context = store.catalogPlaybackContexts[photo.id],
               !context.item.coverURL.isEmpty {
                let source = context.source
                let cover = context.item.coverURL
                let targetID = photo.id
                Task { @MainActor in
                    let image = await CatalogArtworkCache.shared.image(source: source,
                                                                       urlString: cover,
                                                                       quick: true)
                    guard photo.id == targetID, let image else { return }
                    loadingThumbnail = image
                }
            }
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
            streamMode = .remux
            streamOffset = 0
            streamAudioIndex = 0
            isRestartingStream = false
            probeDuration = 0
            probeIsHEVC = false
            probeIsHDR = false
            probeAudioCount = 0
            probeAudioTracks = []
            playbackProbe = VideoProbe()
            showPlaybackInfo = false
            ui.reset()
            model.onPlaybackEnd = {
                guard settings.autoPlayNextVideo else { return }
                store.playNextVideo(after: photo.id)
            }
            // 所有界面跳转（进度条 / 工具栏 / 快捷键）统一走路由器：
            // 云盘拖到未生成区间时重建流，已完成缓存的 HLS 直接 seek。
            model.seekRouter = { target in
                guard let session = streamSession else { return false }
                if session.isCompleteCache { return false }
                let horizon = model.bufferedTime
                // 已删除分片不能再回放：早于保留窗口时重新起流。
                let retained = session.retainedStartSeconds
                if target < retained - 1 || target > horizon + 8 {
                    restartStreaming(at: target)
                    return true
                }
                return false
            }
            ui.onMessage = { store.showToast($0) }
            ui.onSelectStreamAudio = { index in
                if streamSession != nil {
                    switchAudio(to: index)
                } else if index < model.audioOptions.count {
                    model.selectAudio(model.audioOptions[index])
                }
            }
            ui.onBurnSubtitleChanged = {
                guard sourceURL != nil else {
                    store.showToast("当前视频没有可读取的源文件，无法烧录字幕")
                    return
                }
                let target = model.currentTime
                streamSession?.stop()
                streamSession = nil
                hasLoadedVideo = false
                isPreparing = true
                let generation = loadGeneration
                Task { @MainActor in
                    let started = await startStreaming(generation: generation, autoplay: true,
                                                       offset: max(0, target - 1),
                                                       resumeAt: target,
                                                       mode: .transcode,
                                                       audioIndex: streamAudioIndex)
                    if !started, generation == loadGeneration {
                        model.seek(to: target)
                    }
                    isPreparing = false
                }
            }
            trimTask?.cancel()
            trimTask = Task { @MainActor in
                while !Task.isCancelled {
                    // 3 秒一次：既滚动清理旧分片，也让生成提前量及时收敛（大文件不写满磁盘）。
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled, let session = streamSession else { continue }
                    session.trim(before: model.currentTime)
                }
            }
            quarterTurns = 0
            videoSize = .zero
            refreshVideoNeighbors()
            await load(generation: generation)
            await loadTechnicalProbe(generation: generation)
        }
        .onDisappear {
            FullScreenDiagnostics.log("video stage disappear \(photo.originalName)")
            loadGeneration &+= 1
            hideControlsTask?.cancel()
            trimTask?.cancel()
            trimTask = nil
            model.seekRouter = nil
            model.stop()
            DisplayModeMatcher.restore()
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

    /// 起播后再补一次 ffprobe：拿码率 / 帧率 / HDR / 章节，供 I 键信息叠加与章节菜单使用。
    /// 不阻塞起播；HLS 播放列表与不存在的本地文件直接跳过。
    private func loadTechnicalProbe(generation: Int) async {
        guard let url = sourceURL else { return }
        if url.pathExtension.lowercased() == "m3u8" { return }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return }
        let probe = await VideoSupport.technicalProbe(url: url, options: assetOptions)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        guard probe.hasVideoTrack || !probe.chapters.isEmpty else { return }

        var merged = playbackProbe
        if probe.size.width > 0 { merged.size = probe.size }
        if let codec = probe.codec { merged.codec = codec }
        merged.isHDR = merged.isHDR || probe.isHDR
        merged.isDolbyVision = merged.isDolbyVision || probe.isDolbyVision
        if let label = probe.hdrLabel, !label.isEmpty { merged.hdrLabel = label }
        if probe.bitrate > 0 { merged.bitrate = probe.bitrate }
        if probe.frameRate > 0 { merged.frameRate = probe.frameRate }
        if let container = probe.containerName { merged.containerName = container }
        if !probe.chapters.isEmpty { merged.chapters = probe.chapters }
        if probe.audioTracks.count > merged.audioTracks.count { merged.audioTracks = probe.audioTracks }
        merged.duration = max(merged.duration, probe.duration)
        playbackProbe = merged
        applyDisplayRate(merged.frameRate)
        // 预热接管 / 转封装起流时音轨信息可能为空：探测到后补齐菜单。
        if merged.audioTracks.count > probeAudioTracks.count {
            probeAudioTracks = merged.audioTracks
            probeAudioCount = merged.audioTracks.count
            refreshAudioChoices()
        }
    }

    /// 按片源帧率切显示器刷新率：设置里可关，找不到合适模式会自动保持原样。
    private func applyDisplayRate(_ rate: Double) {
        guard settings.matchDisplayFrameRate, rate > 1 else { return }
        DisplayModeMatcher.match(frameRate: rate)
    }

    /// 当前播放的是网络资源的分集（每一集都是一个虚拟视频）。
    private var isCatalogPlayback: Bool {
        store.catalogPlaybackContext(for: photo.id) != nil
    }

    /// 视频快捷键：
    /// - 本地视频：← / → 翻页，↑ / ↓ 按设置步长快进快退（默认 5 秒）；J / L 固定 10 秒。
    /// - 网络资源（剧集）：← / → 快退 / 快进，↑ / ↓ 切换上一集 / 下一集。
    /// - ⌘ 方向键始终只切换上一个 / 下一个视频。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)

        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于固定键位匹配。
        if !hasCommand, handleCustomShortcut(event) { return true }

        // ⌥← / ⌥→：上一章 / 下一章；I：播放信息叠加。
        if flags == .option, event.keyCode == 123, seekChapter(step: -1) { return true }
        if flags == .option, event.keyCode == 124, seekChapter(step: 1) { return true }
        if event.keyCode == 34, flags.isEmpty {
            showPlaybackInfo.toggle()
            return true
        }

        guard !flags.contains(.control), !flags.contains(.option) else { return false }

        let catalogPlayback = isCatalogPlayback
        switch event.keyCode {
        case 123:
            if hasCommand {
                store.viewerStepVideo(-1)
            } else if catalogPlayback {
                seekPlayback(to: model.currentTime - settings.videoSeekStep)
            } else {
                store.viewerStep(-1)
            }
            return true
        case 124:
            if hasCommand {
                store.viewerStepVideo(1)
            } else if catalogPlayback {
                seekPlayback(to: model.currentTime + settings.videoSeekStep)
            } else {
                store.viewerStep(1)
            }
            return true
        case 126:
            if hasCommand || catalogPlayback {
                store.viewerStepVideo(-1)
            } else {
                seekPlayback(to: model.currentTime + settings.videoSeekStep)
            }
            return true
        case 125:
            if hasCommand || catalogPlayback {
                store.viewerStepVideo(1)
            } else {
                seekPlayback(to: model.currentTime - settings.videoSeekStep)
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
            seekPlayback(to: model.currentTime + 10)
            return true
        }
        if ShortcutStore.matches(event, .videoBackward) {
            seekPlayback(to: model.currentTime - 10)
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
                    VideoScrubber(progress: progress,
                                  buffered: buffered,
                                  knobBorder: .black.opacity(0.35),
                                  duration: model.duration,
                                  thumbnailPreview: { fraction in
                                      await VideoScrubThumbnails.image(player: model.player,
                                                                       fraction: fraction,
                                                                       duration: model.duration)
                                  }) { value in
                        let target = value * model.duration
                        // 拖动过程中只对已生成区间做实时预览，否则每移动一像素就重建一次流。
                        if streamSession == nil || target <= model.bufferedTime {
                            model.seek(to: target)
                        }
                    } onCommit: { value in
                        seekPlayback(to: value * model.duration)
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
                    VideoControlButton(icon: "backward.end",
                                       help: isCatalogPlayback ? "上一集 (↑)" : "上一个视频 (⌘↑)") {
                        store.viewerStepVideo(-1)
                    }
                    .disabled(!hasPrevVideo)
                    VideoControlButton(icon: "gobackward.10",
                                       help: isCatalogPlayback ? "后退 10 秒 (J / ←)" : "后退 10 秒 (J)") {
                        seekPlayback(to: model.currentTime - 10)
                    }
                    VideoControlButton(icon: "goforward.10",
                                       help: isCatalogPlayback ? "前进 10 秒 (L / →)" : "前进 10 秒 (L)") {
                        seekPlayback(to: model.currentTime + 10)
                    }
                    VideoControlButton(icon: "forward.end",
                                       help: isCatalogPlayback ? "下一集 (↓)" : "下一个视频 (⌘↓)") {
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

                    if playbackProbe.chapters.count > 1 {
                        chapterMenu
                    }
                    VideoControlButton(icon: "info.circle", active: showPlaybackInfo,
                                       help: "播放信息 (I)") {
                        showPlaybackInfo.toggle()
                    }

                    VideoMediaMenuButtons(ui: ui, model: model)

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

    // MARK: - 跳转与流重建

    /// 云盘边下边播的已生成区间随 ffmpeg 进度增长，拖到未生成位置时用 -ss 重新起流。
    private func seekPlayback(to target: Double) {
        model.requestSeek(to: target)
    }

    private func switchAudio(to index: Int) {
        guard streamSession != nil, index != streamAudioIndex else { return }
        let target = model.currentTime
        streamAudioIndex = index
        refreshAudioChoices()
        restartStreaming(at: target)
    }

    /// 把 HLS 音轨或原生 AV 音轨统一映射成菜单里的选项。
    private func refreshAudioChoices() {
        if streamSession != nil {
            if !probeAudioTracks.isEmpty {
                ui.updateAudio(choices: probeAudioTracks.map {
                    VideoPlaybackUI.AudioChoice(index: $0.ordinal, title: $0.displayName)
                }, selected: streamAudioIndex)
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

    private func restartStreaming(at target: Double) {
        guard streamSession != nil, !isRestartingStream else {
            model.seek(to: target)
            return
        }
        isRestartingStream = true
        isPreparing = true
        let generation = loadGeneration
        // 往前留 1 秒，避免落到关键帧前面导致开头一小段缺失。
        let offset = max(0, target - 1)
        let mode = streamMode
        let audio = streamAudioIndex
        let seekStartedAt = Date()
        Task { @MainActor in
            // 云盘直链可能已过期：跳转前重新解析一次，避免重建流仍用旧地址。
            if photo.isCloud, let refreshed = try? await store.cloudStreamOrThrow(for: photo) {
                sourceURL = refreshed.url
                sourceHeaders = refreshed.headers
            }
            // 旧的流先停掉，避免两个 ffmpeg 同时读同一份网盘文件。
            streamSession?.stop()
            streamSession = nil
            let started = await startStreaming(generation: generation, autoplay: true,
                                               offset: offset, resumeAt: target,
                                               mode: mode, audioIndex: audio)
            if !started, generation == loadGeneration {
                model.seek(to: target)
            }
            let elapsed = Int(Date().timeIntervalSince(seekStartedAt) * 1000)
            let remote = photo.isCloud ? "网盘" : "本地"
            Diagnostics.record("拖拽起流 \(photo.originalName) \(remote) → \(Int(target))s 用时 \(elapsed)ms")
            isRestartingStream = false
            isPreparing = false
        }
    }

    /// 云盘直链失效时重新解析；代理的下载线程会阻塞等待结果。
    private func cloudRefreshClosure() -> (() -> (URL, [String: String])?)? {
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

    /// 启动转封装会话；编码不兼容时自动降级为重编码 H.264。
    /// 起流：`offset` 是 ffmpeg 的读取位置（会再对齐到关键帧），
    /// `resumeAt` 是播放器最终要落到的绝对秒数（装片后先定位再开播）。
    private func startStreaming(generation: Int, autoplay: Bool, offset: Double,
                                resumeAt: Double? = nil,
                                mode initialMode: VideoStreamSession.Mode,
                                audioIndex: Int) async -> Bool {
        guard let sourceURL else { return false }
        let startedAt = Date()
        var mode = initialMode
        // 烧录字幕必须重编码，不能沿用 remux。
        if ui.burnSubtitleURL != nil { mode = .transcode }
        var attempt = 0
        while attempt < 2 {
            let session = VideoStreamSession(
                photoID: photo.id,
                source: sourceURL,
                headers: sourceHeaders,
                trustSelfSigned: store.cloudMount(for: photo.cloudMountID)?.trustSelfSigned ?? false,
                mode: mode,
                startOffset: offset,
                isHEVC: probeIsHEVC,
                isHDR: probeIsHDR,
                audioIndex: audioIndex,
                audioChannels: probeAudioTracks.first(where: { $0.ordinal == audioIndex })?.channels
                    ?? probeAudioTracks.first?.channels ?? 2,
                burnSubtitle: ui.burnSubtitleURL,
                refreshSource: cloudRefreshClosure())
            do {
                // 起流要做目录清理、拉起 ffmpeg、等服务写首段：全部是阻塞操作，
                // 放后台执行，否则打开视频的瞬间界面会停住。
                let starting = Task.detached(priority: .userInitiated) {
                    try await session.start()
                }
                let playlist = try await withTaskCancellationHandler {
                    try await starting.value
                } onCancel: {
                    starting.cancel()
                }
                guard generation == loadGeneration, !Task.isCancelled else {
                    session.stop()
                    return false
                }
                streamSession?.stop()
                streamSession = session
                streamMode = mode
                // 会话会把读取位置对齐到关键帧：时间轴以对齐点为 0，再前跳到目标。
                let base = session.playbackStartOffset
                streamOffset = base
                streamAudioIndex = audioIndex
                refreshAudioChoices()
                var probe = VideoProbe()
                probe.hasVideoTrack = true
                probe.isPlayable = true
                probe.duration = probeDuration
                probe.size = videoSize
                model.load(url: playlist, probe: probe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault,
                           muted: settings.muteVideoByDefault,
                           timelineOffset: base,
                           startAt: resumeAt)
                hasLoadedVideo = true
                failureMessage = nil
                isPreparing = false
                canTranscode = false
                // 打开时未自动播放：首段已就绪，先挂起后台生成。
                session.setGenerationActive(autoplay)
                // 记录首段耗时：真实网盘上判断缓冲快慢就看这一条。
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                let remote = sourceURL.isFileURL ? "本地" : "网盘"
                Diagnostics.record("首段就绪 \(photo.originalName) \(remote) mode=\(mode) "
                                   + "offset=\(Int(offset)) 对齐=\(Int(base)) 用时 \(elapsed)ms")
                return true
            } catch {
                session.stop()
                guard generation == loadGeneration, !Task.isCancelled else { return false }
                // 网盘 / 网络失败：重编码也没用，直接暴露转码入口与错误原因。
                if session.failureIsSource {
                    failureMessage = "边下边播启动失败：\(error.localizedDescription)"
                    canTranscode = true
                    isPreparing = false
                    return false
                }
                if mode == .remux {
                    Diagnostics.record("转封装失败，降级为重编码：\(error.localizedDescription)")
                    mode = .transcode
                    attempt += 1
                    continue
                }
                failureMessage = "边下边播启动失败：\(error.localizedDescription)"
                canTranscode = true
                isPreparing = false
                return false
            }
        }
        return false
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

    // MARK: 载入

    private func load(generation: Int) async {
        FullScreenDiagnostics.log("video load start \(photo.originalName) generation=\(generation)")
        // 换片先恢复系统刷新率，探测到新片帧率后再匹配。
        DisplayModeMatcher.restore()
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
        // 影院续播：装片时就落在记录位置，不会先播片头再跳过去。
        let resumeOffset = store.cinemaResumeOffset(for: photo.id)

        // 上一集快看完时预热好的下一集：首段已生成，直接接管，省掉解析直链与探测。
        if ui.burnSubtitleURL == nil,
           let warm = store.takePrewarmedCinemaStream(for: photo.id) {
            sourceURL = warm.sourceURL
            sourceHeaders = warm.headers
            assetOptions = [CloudPlayback.headerFieldsKey: warm.headers]
            streamSession = warm.session
            streamMode = .remux
            streamOffset = 0
            streamAudioIndex = 0
            var probe = VideoProbe()
            probe.hasVideoTrack = true
            probe.isPlayable = true
            probe.duration = max(photo.duration ?? 0, warm.duration)
            if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                probe.size = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
            videoSize = probe.size
            probeDuration = probe.duration
            probeIsHEVC = photo.videoCodec?.lowercased() == "hevc"
            probeIsHDR = false
            probeAudioCount = 0
            probeAudioTracks = []
            playbackProbe = probe
            model.load(url: warm.playlistURL, probe: probe, autoplay: autoplay,
                       loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                       startAt: resumeOffset)
            hasLoadedVideo = true
            isPreparing = false
            failureMessage = nil
            canTranscode = false
            warm.session.setGenerationActive(autoplay)
            refreshAudioChoices()
            ui.loadSiblingIfAvailable(sourceURL: sourceURL)
            return
        }

        let source = await resolveSource()
        guard generation == loadGeneration, !Task.isCancelled else { return }
        var failedProbe: VideoProbe?

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
            model.load(url: source.url, options: assetOptions, probe: probe, autoplay: autoplay,
                       loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                       startAt: resumeOffset)
            hasLoadedVideo = true
            isPreparing = false
            probeDuration = probe.duration
            probeIsHEVC = false
            probeIsHDR = false
            probeAudioCount = 0
            probeAudioTracks = []
            playbackProbe = probe
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
        if let playbackURL, canUseLocal, ui.burnSubtitleURL == nil {
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
                               loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                               startAt: resumeOffset)
                } else {
                    model.load(url: playbackURL, options: assetOptions, probe: probe, autoplay: autoplay,
                               loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                               startAt: resumeOffset)
                }
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = probe.duration
                probeIsHEVC = probe.isHEVC
                probeIsHDR = probe.isHDR
                probeAudioCount = probe.audioTrackCount
                probeAudioTracks = probe.audioTracks
                playbackProbe = probe
                applyDisplayRate(probe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
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

        if ui.burnSubtitleURL == nil,
           let cached = cachedTranscodeURL(), FileManager.default.fileExists(atPath: cached.path) {
            let cachedProbe = await VideoSupport.probe(url: cached)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if cachedProbe.hasVideoTrack, cachedProbe.isPlayable {
                sourceURL = cached
                videoSize = cachedProbe.size
                model.load(url: cached, probe: cachedProbe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           startAt: resumeOffset)
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = cachedProbe.duration
                probeIsHEVC = cachedProbe.isHEVC
                probeIsHDR = cachedProbe.isHDR
                probeAudioCount = cachedProbe.audioTrackCount
                probeAudioTracks = cachedProbe.audioTracks
                playbackProbe = cachedProbe
                applyDisplayRate(cachedProbe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
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
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           startAt: resumeOffset)
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = probe.duration
                probeIsHEVC = probe.isHEVC
                probeIsHDR = probe.isHDR
                probeAudioCount = probe.audioTrackCount
                probeAudioTracks = probe.audioTracks
                playbackProbe = probe
                applyDisplayRate(probe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                return
            }
            failedProbe = probe
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
            probeAudioCount = failedProbe.audioTrackCount
            probeAudioTracks = failedProbe.audioTracks
            playbackProbe = failedProbe
            if failedProbe.size.width > 0, failedProbe.size.height > 0 {
                videoSize = failedProbe.size
            } else if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
        }
        // 烧录字幕跳过了系统原生探测：用列表元数据补齐时长 / 尺寸，转码流才有正确的进度条。
        if ui.burnSubtitleURL != nil {
            if probeDuration <= 0 { probeDuration = photo.duration ?? 0 }
            if videoSize == .zero, photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
        }
        if sourceURL != nil, FFmpeg.isAvailable {
            // 不弹「正在准备」告警卡片：直接进入播放界面转圈，首段就绪后自动开播。
            failureMessage = nil
            isPreparing = true
            streamMode = .remux
            // 续播直接从目标位置起流，省掉「先播片头再重建流」的一跳。
            let startOffset = resumeOffset ?? 0
            streamOffset = startOffset
            streamAudioIndex = 0
            if await startStreaming(generation: generation, autoplay: autoplay,
                                    offset: startOffset,
                                    resumeAt: startOffset > 0 ? startOffset : nil,
                                    mode: .remux, audioIndex: 0) {
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

    /// MKV / AVI 这类容器 AVFoundation 根本不解析，探测拿不到编码，直接说明容器更准确。
    private static func formatDescription(name: String, codec: String?) -> String {
        let unsupported: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "rmvb", "rm",
                                        "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv",
                                        "divx", "mxf", "asf"]
        let ext = (name as NSString).pathExtension.lowercased()
        if unsupported.contains(ext) { return "\(ext.uppercased()) 容器" }
        return codec ?? "未知编码"
    }

    private func resolveSource() async -> (url: URL, headers: [String: String], isHLS: Bool)? {
        // 网络资源：按虚拟分集取当前集的播放直链。
        if let context = store.catalogPlaybackContext(for: photo.id) {
            do {
                let stream = try await store.catalog.stream(source: context.source,
                                                            episode: context.episode)
                return (stream.url, stream.headers, stream.isHLS)
            } catch {
                streamFailure = error.localizedDescription
                return nil
            }
        }
        if photo.isCloud {
            do {
                let stream = try await store.cloudStreamOrThrow(for: photo)
                return (stream.url, stream.headers, stream.isHLS)
            } catch {
                streamFailure = error.localizedDescription
                return nil
            }
        }
        return (LibraryPaths.sourceURL(for: photo), [:], false)
    }

    private func cachedTranscodeURL() -> URL? {
        LibraryPaths.transcodes.appendingPathComponent(photo.id.uuidString + ".mp4", isDirectory: false)
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
                        toneMapHDR: probeIsHDR,
                        destination: destination)
                } else {
                    try await VideoSupport.transcode(source: sourceURL, destination: destination,
                                                     toneMapHDR: probeIsHDR)
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
                streamOffset = 0
                applyDisplayRate(probe.frameRate)
                model.load(url: destination, probe: probe, autoplay: true,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault)
                hasLoadedVideo = true
                failureMessage = nil
                canTranscode = false
                isTranscoding = false
                VideoCacheManager.trimIfNeeded()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
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

/// 播放舱里的播放控制组：上一个 / 后退 10 秒 / 播放 / 前进 10 秒 / 下一个。
struct VideoToolbarTransport: View {
    @ObservedObject var model: VideoPlayerModel
    let hasPrev: Bool
    let hasNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void
    /// 网络资源剧集：↑ / ↓ 切集，← / → 快进快退。
    var episodeMode: Bool = false

    var body: some View {
        HStack(spacing: 1) {
            VideoDeckButton(icon: "backward.end.fill",
                            help: episodeMode ? "上一集 (↑)" : "上一个视频 (⌘↑)") {
                onPrev()
            }
            .disabled(!hasPrev)

            transportDivider

            VideoDeckButton(icon: "gobackward.10",
                            help: episodeMode ? "后退 10 秒 (J / ←)" : "后退 10 秒 (J)") {
                model.requestSeek(to: model.currentTime - 10)
            }

            playButton

            VideoDeckButton(icon: "goforward.10",
                            help: episodeMode ? "前进 10 秒 (L / →)" : "前进 10 秒 (L)") {
                model.requestSeek(to: model.currentTime + 10)
            }

            transportDivider

            VideoDeckButton(icon: "forward.end.fill",
                            help: episodeMode ? "下一集 (↓)" : "下一个视频 (⌘↓)") {
                onNext()
            }
            .disabled(!hasNext)
        }
        // 播放舱内已经留了内边距：这里只需要一点点空隙，避免按钮贴着分隔线。
        .padding(.horizontal, 1)
        .fixedSize()
    }

    private var transportDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 13)
            .padding(.horizontal, 2)
    }

    private var playButton: some View {
        Button {
            model.togglePlay()
        } label: {
            ZStack {
                if model.isStalled {
                    // 缓冲中不显示暂停图标：换成小转环，跟画面里的等待动画一致。
                    VideoMiniSpinner()
                } else {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
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
        .padding(.horizontal, 2)
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
                .frame(width: 36, alignment: .trailing)
                .contentTransition(.numericText())

            // 轨道用强调色：与信息行的进度圆环同一套语言，进度点带柔光。
            VideoScrubber(progress: progress,
                          buffered: buffered,
                          tint: Color.accentColor) { value in
                model.seek(to: value * model.duration)
            } onCommit: { value in
                model.requestSeek(to: value * model.duration)
            }
            // 播放舱宽度固定，进度条吃掉中间的全部宽度，翻页时长度不变。
            .frame(minWidth: 120, maxWidth: .infinity)

            Text(durationText)
                .frame(width: 40, alignment: .leading)
                .contentTransition(.numericText())
                .contentShape(Rectangle())
                .onTapGesture { showsRemaining.toggle() }
                .help("点击切换已播 / 剩余时长")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help("拖动进度条定位")
    }
}

/// 进度条右侧的音量：平时只是一枚扬声器图标，鼠标移上去向左展开一条可拖动的小轨道，
/// 移开自动收起；点图标静音。轨道与进度条同一套配色和进度点样式，展开过程带弹簧动画。
struct VideoInlineVolume: View {
    @ObservedObject var model: VideoPlayerModel

    @State private var isHovering = false
    @State private var isDragging = false

    private var isExpanded: Bool { isHovering || isDragging }

    private var icon: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 5) {
            volumeRail
                .frame(width: isExpanded ? 84 : 0, height: 16)
                .opacity(isExpanded ? 1 : 0)
                .clipped()

            Button {
                if model.volume == 0 {
                    model.volume = 0.6
                    model.isMuted = false
                } else {
                    model.isMuted.toggle()
                }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.isMuted ? "取消静音（移入展开音量）" : "静音（移入展开音量）")
        }
        .onHover { inside in
            isHovering = inside
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isExpanded)
    }

    private var volumeRail: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let value = model.isMuted ? 0 : min(1, max(0, model.volume))
            let knobSize: CGFloat = isDragging ? 10 : 7
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 3)
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }

                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.40),
                                                  Color.accentColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * value, height: 3)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: knobSize, height: knobSize)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.8)
                    }
                    .shadow(color: Color.accentColor.opacity(0.40), radius: 3)
                    .offset(x: width * value - knobSize / 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let next = min(1, max(0, gesture.location.x / width))
                        model.volume = next
                        if model.isMuted, next > 0 { model.isMuted = false }
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
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

/// 音轨 / 字幕菜单：顶栏与画面内控制条共用同一组状态与交互。
struct VideoMediaMenuButtons: View {
    enum Style {
        /// 叠在画面上：白色图标 + 深色底。
        case overlay
        /// 窗口工具栏 / 播放舱：跟随系统明暗。
        case toolbar
    }

    @ObservedObject var ui: VideoPlaybackUI
    @ObservedObject var model: VideoPlayerModel
    var style: Style = .overlay

    var body: some View {
        HStack(spacing: 2) {
            if ui.audioChoices.count > 1 { audioMenu }
            // 顶栏只保留音轨入口：字幕在画面内控制条与「视频 › 字幕」菜单里切换。
            if style == .overlay { subtitleMenu }
        }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(ui.audioChoices) { choice in
                Button {
                    ui.selectAudio(choice.index)
                } label: {
                    let title = choice.title.isEmpty ? "音轨 \(choice.index + 1)" : choice.title
                    if choice.index == ui.selectedAudioIndex {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            icon("waveform", active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("音轨")
    }

    private var subtitleMenu: some View {
        Menu {
            Button("载入字幕文件…") { ui.pickSubtitle() }
            Button("烧录字幕（PGS / SUP / ASS）…") { ui.pickBurnInSubtitle() }
            if let burnName = ui.burnSubtitleName {
                Button("关闭烧录：\(burnName)") { ui.clearBurnInSubtitle() }
            }
            if ui.canSearchOnlineSubtitles {
                Button(ui.onlineSubtitleLoading ? "正在搜索在线字幕…" : "在线搜索字幕…") {
                    ui.searchOnlineSubtitles()
                }
                .disabled(ui.onlineSubtitleLoading)
                if !ui.onlineSubtitles.isEmpty {
                    Menu("选择在线字幕") {
                        ForEach(ui.onlineSubtitles) { match in
                            Button(subtitleOptionTitle(match)) {
                                ui.downloadOnlineSubtitle(match)
                            }
                        }
                    }
                } else if let hint = ui.onlineSubtitleHint {
                    Text(hint)
                }
            }
            if ui.hasSubtitle {
                Button("关闭字幕") { ui.clearSubtitle() }
                Divider()
                Button("字幕延后 0.5 秒") { ui.adjustOffset(0.5) }
                Button("字幕提前 0.5 秒") { ui.adjustOffset(-0.5) }
                Button("重置偏移（当前 \(offsetText)）") { ui.resetOffset() }
            }
            if !model.legibleOptions.isEmpty {
                Divider()
                ForEach(model.legibleOptions.indices, id: \.self) { index in
                    let option = model.legibleOptions[index]
                    Button {
                        ui.clearSubtitle()
                        model.selectLegible(option)
                    } label: {
                        if model.selectedLegible == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
                if model.selectedLegible != nil {
                    Button("关闭内嵌字幕") { model.selectLegible(nil) }
                }
            }
        } label: {
            icon(ui.hasSubtitle || model.selectedLegible != nil ? "captions.bubble.fill" : "captions.bubble",
                 active: ui.hasSubtitle || model.selectedLegible != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕")
    }

    private var offsetText: String {
        String(format: "%+.1fs", ui.subtitleOffset)
    }

    private func subtitleOptionTitle(_ match: CinemaSubtitleMatch) -> String {
        var parts = [match.languageTitle, match.title]
        if let release = match.release, !release.isEmpty { parts.append(release) }
        if let downloads = match.downloads, downloads > 0 { parts.append("↓\(downloads)") }
        return parts.joined(separator: " · ")
    }

    private func icon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(foreground(active))
            .frame(width: 26, height: style == .overlay ? 26 : 24)
            .background {
                RoundedRectangle(cornerRadius: style == .overlay ? 7 : 6, style: .continuous)
                    .fill(background(active))
            }
            .contentShape(Rectangle())
    }

    private func foreground(_ active: Bool) -> Color {
        if active { return Color.accentColor }
        return style == .overlay ? Color.white.opacity(0.86) : Color.primary.opacity(0.82)
    }

    private func background(_ active: Bool) -> Color {
        if active { return Color.accentColor.opacity(style == .overlay ? 0.2 : 0.16) }
        return style == .overlay ? Color.white.opacity(0.001) : Color.primary.opacity(0.001)
    }
}
