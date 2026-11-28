import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore
import LumaCore

// MARK: - 视频画面

final class PlayerContainerView: NSView {
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

struct PlayerLayerView: NSViewRepresentable {
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
    /// 缓冲区间末尾与起点（比例）：起点是当前会话还能直接回退的最早位置。
    let buffered: Double
    var bufferedStart: Double = 0
    /// 轨道与进度点颜色：画面控制条用白色，窗口工具栏跟随明暗外观。
    var tint: Color = .white
    /// 进度点的描边色：白点配深描边，彩色点配白描边，深浅底上都能看清。
    var knobBorder: Color = .white.opacity(0.6)
    /// 总时长：用于预览气泡上的时间标签。
    var duration: Double = 0
    /// 章节起点（比例）：轨道上画细刻度，电影 / 蓝光的段落一目了然。
    var chapterFractions: [Double] = []
    /// 悬停 / 拖动时取该比例处的画面帧；为空则不显示预览。
    var thumbnailPreview: ((Double) async -> NSImage?)?
    /// 悬停 / 拖动位置变化（nil 表示离开）：顶栏预览气泡据此跟随光标。
    var onPreviewChange: ((Double?) -> Void)?
    let onSeek: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragValue: Double = 0
    @State private var hoverFraction: Double?
    @State private var previewImage: NSImage?
    @State private var previewFraction: Double?
    @State private var previewLoading = false
    @State private var previewTask: Task<Void, Never>?

    private var isExpanded: Bool { isHovering || isDragging }
    private var trackHeight: CGFloat { isExpanded ? 4.5 : 3 }
    private var knobSize: CGFloat { isExpanded ? 12 : 8 }
    private var haloSize: CGFloat { isExpanded ? 21 : 14 }

    private func clamp(_ value: Double) -> Double {
        // 非有限值会让 frame(width:) 变成 NaN，SwiftUI 布局会直接卡死。
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let value = clamp(isDragging ? dragValue : progress)
            let playedWidth = width * value
            let bufferedStartX = width * clamp(bufferedStart)
            let bufferedEndX = width * clamp(buffered)
            ZStack(alignment: .leading) {
                // 轨道：内凹细槽 + 细描边，像一条嵌进玻璃里的轨道。
                Capsule()
                    .fill(tint.opacity(0.13))
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
                    }

                // 缓冲区间：只画「已经生成、能立即跳过去」的一段。
                // 从保留起点开始画而不是永远从 0 开始——拖到未生成区间后重新起流，
                // 更早的位置需要重建，不该假装已缓存。
                if bufferedEndX > bufferedStartX + 0.5 {
                    Capsule()
                        .fill(tint.opacity(0.24))
                        .frame(width: bufferedEndX - bufferedStartX, height: trackHeight)
                        .offset(x: bufferedStartX)
                }

                // 已播放段：渐变轨道，收尾处更亮。播放中按采样间隔做线性补间，进度是滑行而不是跳格。
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: playedWidth, height: trackHeight)
                    .animation(isDragging ? nil : .linear(duration: 0.25), value: playedWidth)

                // 缓冲前沿：亮线标出「到这里都准备好了」，和 YouTube / Infuse 的处理一致。
                if bufferedEndX > bufferedStartX + 0.5,
                   bufferedEndX < width - 0.5,
                   bufferedEndX > playedWidth + 1 {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: 1.5, height: trackHeight + 1)
                        .offset(x: bufferedEndX - 0.75)
                        .shadow(color: tint.opacity(0.35), radius: 2)
                        .allowsHitTesting(false)
                }

                // 章节刻度：起点位置画一条短竖线，便于在进度条上直接认出段落。
                if !chapterFractions.isEmpty {
                    ForEach(Array(chapterFractions.indices), id: \.self) { index in
                        Capsule()
                            .fill(tint.opacity(isExpanded ? 0.62 : 0.4))
                            .frame(width: 1.2, height: trackHeight + (isExpanded ? 8 : 4))
                            .offset(x: width * clamp(chapterFractions[index]) - 0.6)
                            .allowsHitTesting(false)
                    }
                }

                // 悬停位置标线：像 YouTube 那样先给出落点，再浮出画面预览。
                if let hoverFraction, isExpanded {
                    Rectangle()
                        .fill(tint.opacity(0.42))
                        .frame(width: 1, height: trackHeight + 7)
                        .offset(x: width * hoverFraction - 0.5)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // 进度点：外圈柔光 + 实心圆 + 细描边，悬停 / 拖动时整体放大。
                knob
                    .offset(x: playedWidth - knobSize / 2)
                    .animation(isDragging ? nil : .linear(duration: 0.25), value: playedWidth)
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
                    let fraction = clamp(point.x / width)
                    hoverFraction = fraction
                    onPreviewChange?(fraction)
                    requestPreview(fraction)
                case .ended:
                    isHovering = false
                    hoverFraction = nil
                    // 拖动时指针常常滑出 16pt 高的轨道，这里不能把预览收掉：
                    // 拖动中的位置由 DragGesture 继续驱动，松手时才结束预览。
                    if !isDragging {
                        onPreviewChange?(nil)
                        clearPreview()
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        dragValue = clamp(gesture.location.x / width)
                        hoverFraction = dragValue
                        onPreviewChange?(dragValue)
                        requestPreview(dragValue)
                        onSeek(dragValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                        hoverFraction = nil
                        onPreviewChange?(nil)
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
        } else if previewLoading, let previewFraction {
            // 先占位：帧还在路上时也按最终尺寸留好位置，图到了原位淡入，气泡不跳。
            let bubbleWidth: CGFloat = 168
            let bubbleHeight: CGFloat = 95
            let x = min(max(0, width * previewFraction - bubbleWidth / 2), max(0, width - bubbleWidth))
            ZStack {
                Color.black.opacity(0.55)
                VStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("取帧中…")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: bubbleWidth, height: bubbleHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
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
            .shadow(color: .black.opacity(0.40), radius: 12, y: 4)
            .offset(x: x, y: -(bubbleHeight + 12))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func requestPreview(_ fraction: Double) {
        guard let thumbnailPreview else { return }
        previewFraction = fraction
        previewLoading = true
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            // 轻微防抖：手指快速掠过时不取帧，停住 90ms 再取，预览跟手又不抢解码。
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let image = await thumbnailPreview(fraction)
            guard !Task.isCancelled else { return }
            previewLoading = false
            withAnimation(.easeOut(duration: 0.12)) { previewImage = image }
        }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewLoading = false
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
struct VideoBufferingOverlay: View {
    let active: Bool
    var label: String = "缓冲中"
    /// 起播阶段立即显示，不走 0.22 秒防抖：否则打开视频时中间会空一段时间。
    var immediate = false
    /// 首帧之前的等待用更大的转圈（盖在海报底图上），出画面后的补缓冲保持紧凑。
    var prominent = false

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
                    .frame(width: prominent ? 54 : 40, height: prominent ? 54 : 40)

                    Text(label)
                        .font(.system(size: prominent ? 11.5 : 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(prominent ? 0.82 : 0.62))
                }
                .padding(.horizontal, prominent ? 28 : 20)
                .padding(.vertical, prominent ? 20 : 15)
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
            if !immediate {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
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

/// 工具栏播放按钮里的迷你缓冲环。
struct VideoMiniSpinner: View {
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
struct VideoControlPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 按住连发：按下立刻执行一次，之后重复间隔从 0.30s 递减到 0.14s 后匀速。
/// 配合 `VideoPlayerModel.seekStep(_:base:isRepeat:)` 使用：按住越久步长倍率越高，
/// 到 8× 封顶后就是匀速快进 / 快退。
struct HoldRepeatGesture: ViewModifier {
    let action: () -> Void

    @State private var holdTask: Task<Void, Never>?
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) { pressing in
                if pressing {
                    start()
                } else {
                    stop()
                }
            } perform: {}
            .onDisappear(perform: stop)
    }

    private func start() {
        guard !pressing else { return }
        pressing = true
        action()
        holdTask = Task { @MainActor in
            var interval: UInt64 = 300_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                action()
                if interval > 140_000_000 {
                    interval = max(140_000_000, interval - 20_000_000)
                }
            }
        }
    }

    private func stop() {
        pressing = false
        holdTask?.cancel()
        holdTask = nil
    }
}

/// 播放器控制按钮：悬停高亮、选中态使用强调色。
struct VideoControlButton: View {
    let icon: String
    var active = false
    var emphasized = false
    /// 重建流 / 缓冲时显示转圈，替代播放暂停图标。
    var busy = false
    var help: String?
    /// 快进 / 快退用：按住不放持续步进，而不是只跳一次。
    var repeatsWhileHeld = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        withHelp
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering }
            }
    }

    @ViewBuilder
    private var withHelp: some View {
        if let help {
            core.help(help)
        } else {
            core
        }
    }

    @ViewBuilder
    private var core: some View {
        if repeatsWhileHeld {
            content.modifier(HoldRepeatGesture(action: action))
        } else {
            Button(action: action) { content }
                .buttonStyle(.plain)
        }
    }

    private var content: some View {
        ZStack {
            if busy {
                VideoMiniSpinner()
            } else {
                Image(systemName: icon)
                    .font(.system(size: emphasized ? 13.5 : 11.5, weight: .semibold))
                    .foregroundStyle(active ? Color.accentColor : Color.white.opacity(hovering ? 1 : 0.86))
            }
        }
        .frame(width: emphasized ? 31 : 26, height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
        }
        .contentShape(Rectangle())
    }

    private var fill: Color {
        if active { return Color.accentColor.opacity(0.2) }
        if emphasized { return Color.white.opacity(hovering ? 0.22 : 0.14) }
        return Color.white.opacity(hovering ? 0.14 : 0.001)
    }
}

