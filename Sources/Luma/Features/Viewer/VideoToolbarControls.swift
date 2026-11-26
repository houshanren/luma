import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore
import LumaCore

// MARK: - 窗口工具栏里的播放控件

/// 顶栏播放按钮：尺寸大于系统工具栏图标，带悬停浮层与选中强调色。
struct VideoDeckButton: View {
    let icon: String
    var active = false
    var help: String?
    /// 快进 / 快退用：按住不放持续步进，而不是只跳一次。
    var repeatsWhileHeld = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        core
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            }
            .animation(.snappy(duration: 0.18), value: active)
            .help(help ?? "")
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
}

/// 播放舱里的播放控制组：上一个 / 后退 10 秒 / 播放 / 前进 10 秒 / 下一个。
struct VideoToolbarTransport: View {
    @ObservedObject var model: VideoPlayerModel
    let hasPrev: Bool
    let hasNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void
    /// 快进 / 快退步长：与播放器和快捷键共用设置里的值。
    var seekStep: Double = 10
    /// 网络资源剧集：↑ / ↓ 切集，← / → 快进快退；
    /// 图库视频与照片翻页一致：← / → 上一个 / 下一个项目，↑ / ↓ 快进快退。
    var episodeMode: Bool = false

    var body: some View {
        HStack(spacing: 1) {
            VideoDeckButton(icon: "backward.end.fill",
                            help: episodeMode ? "上一集 (↑)" : "上一个 (←)") {
                onPrev()
            }
            .disabled(!hasPrev)

            transportDivider

            VideoDeckButton(icon: "gobackward",
                            help: episodeMode
                                ? "后退 \(Int(seekStep)) 秒 (← / J)，按住快退"
                                : "后退 \(Int(seekStep)) 秒 (↓ / J)，按住快退",
                            repeatsWhileHeld: true) {
                model.seekStep(-1, base: seekStep, isRepeat: true)
            }

            playButton

            VideoDeckButton(icon: "goforward",
                            help: episodeMode
                                ? "前进 \(Int(seekStep)) 秒 (→ / L)，按住快进"
                                : "前进 \(Int(seekStep)) 秒 (↑ / L)，按住快进",
                            repeatsWhileHeld: true) {
                model.seekStep(1, base: seekStep, isRepeat: true)
            }

            transportDivider

            VideoDeckButton(icon: "forward.end.fill",
                            help: episodeMode ? "下一集 (↓)" : "下一个 (→)") {
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
    /// 播放编排：缓冲区间从它的已生成末尾 / 保留起点来。
    @ObservedObject var session: PlaybackSession
    @Binding var showsRemaining: Bool
    /// 章节刻度（比例）：顶栏进度条与画面内进度条保持一致。
    var chapterFractions: [Double] = []

    /// 悬停预览需要窗口坐标来对准光标（工具栏自己装不下气泡）。
    @State private var hostWindow: NSWindow?

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }

    private var buffered: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.bufferedEndTime / model.duration))
    }

    private var bufferedStart: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, session.retainedStartSeconds / model.duration))
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
                .frame(minWidth: 36, alignment: .trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())

            // 轨道用强调色：与信息行的进度圆环同一套语言，进度点带柔光。
            VideoScrubber(progress: progress,
                          buffered: buffered,
                          bufferedStart: bufferedStart,
                          tint: Color.accentColor,
                          duration: model.duration,
                          chapterFractions: chapterFractions,
                          onPreviewChange: { fraction in
                              guard AppSettings.shared.scrubPreviewEnabled else {
                                  VideoScrubPreviewCenter.shared.end()
                                  return
                              }
                              if let fraction {
                                  VideoScrubPreviewCenter.shared.hover(fraction: fraction,
                                                                       duration: model.duration,
                                                                       player: model.player,
                                                                       window: hostWindow)
                              } else {
                                  VideoScrubPreviewCenter.shared.end()
                              }
                          }) { value in
                model.scrub(to: value * model.duration)
            } onCommit: { value in
                model.requestSeek(to: value * model.duration)
            }
            // 播放舱宽度固定，进度条吃掉中间的全部宽度，翻页时长度不变。
            .frame(minWidth: 120, maxWidth: .infinity)

            Text(durationText)
                .frame(minWidth: 40, alignment: .leading)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
                .contentShape(Rectangle())
                .onTapGesture { showsRemaining.toggle() }
                .help("点击切换已播 / 剩余时长")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        // 进度条上不再挂悬停提示：提示气泡会盖住画面预览，本身也没提供新信息。
        .background {
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
            }
        }
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
                        Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: LumaControlMetrics.hairline)
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
    /// 只保留几份快照，不直接观察播放器：播放器每 250ms 发布一次播放时间，
    /// 直接观察会让工具栏菜单跟着 250ms 重建，展开的子菜单会被收起、点不中。
    let model: VideoPlayerModel
    let settings: AppSettings
    let quarterTurns: Int
    let onRotate: () -> Void
    let onCapture: () -> Void

    @State private var speed: Double
    @State private var looping: Bool
    @State private var muted: Bool
    @State private var pipActive: Bool
    @State private var pipAvailable: Bool

    init(model: VideoPlayerModel,
         settings: AppSettings,
         quarterTurns: Int,
         onRotate: @escaping () -> Void,
         onCapture: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.quarterTurns = quarterTurns
        self.onRotate = onRotate
        self.onCapture = onCapture
        _speed = State(initialValue: model.speed)
        _looping = State(initialValue: model.isLooping)
        _muted = State(initialValue: model.isMuted)
        _pipActive = State(initialValue: model.isPipActive)
        _pipAvailable = State(initialValue: model.isPipAvailable)
    }

    private var pipActiveBinding: Binding<Bool> {
        Binding(get: { pipActive },
                set: { active in
                    guard active != pipActive else { return }
                    pipActive = active
                    model.togglePip()
                })
    }

    var body: some View {
        Menu {
            Section("播放速度") {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                    Button {
                        speed = value
                        model.setSpeed(value)
                    } label: {
                        if speed == value {
                            Label(speedLabel(value), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(value))
                        }
                    }
                }
            }

            Section("画面") {
                Toggle("循环播放", isOn: Binding(get: { looping },
                                                 set: { looping = $0; model.isLooping = $0 }))
                Menu("显示方式") {
                    ForEach(VideoFramingMode.allCases) { mode in
                        Toggle(isOn: Binding(
                            get: { settings.videoFramingMode == mode },
                            set: { isOn in
                                if isOn { settings.videoFramingMode = mode }
                            }
                        )) {
                            Text(mode.title)
                        }
                    }
                }
                Menu("画面比例") {
                    ForEach(VideoAspectPreset.allCases) { preset in
                        Toggle(isOn: Binding(
                            get: { settings.videoAspectPreset == preset },
                            set: { isOn in
                                guard isOn else { return }
                                settings.videoAspectPreset = preset
                                settings.videoPanX = 0
                                settings.videoPanY = 0
                            }
                        )) {
                            Text(preset.title)
                        }
                    }
                }
                Menu("平移画面") {
                    Button("上移画面") { nudgePan(dx: 0, dy: -0.25) }
                    Button("下移画面") { nudgePan(dx: 0, dy: 0.25) }
                    Button("左移画面") { nudgePan(dx: -0.25, dy: 0) }
                    Button("右移画面") { nudgePan(dx: 0.25, dy: 0) }
                    Button("居中") {
                        settings.videoPanX = 0
                        settings.videoPanY = 0
                    }
                }
                Button("旋转 90°") { onRotate() }
                Toggle("画中画", isOn: pipActiveBinding)
                    .disabled(!pipAvailable)
            }

            Section("声音") {
                Toggle("静音", isOn: Binding(get: { muted },
                                             set: { muted = $0; model.isMuted = $0 }))
                Button("音量 25%") { setVolume(0.25) }
                Button("音量 50%") { setVolume(0.5) }
                Button("音量 100%") { setVolume(1) }
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
        // 只在这几个值真的变化时同步快照；播放时间推进不会触发重绘。
        .onReceive(model.$speed) { speed = $0 }
        .onReceive(model.$isLooping) { looping = $0 }
        .onReceive(model.$isMuted) { muted = $0 }
        .onReceive(model.$isPipActive) { pipActive = $0 }
        .onReceive(model.$isPipAvailable) { pipAvailable = $0 }
    }

    private func setVolume(_ value: Double) {
        model.volume = value
        model.isMuted = false
        muted = false
    }

    private func nudgePan(dx: Double, dy: Double) {
        settings.videoPanX = min(1, max(-1, settings.videoPanX + dx))
        settings.videoPanY = min(1, max(-1, settings.videoPanY + dy))
    }

    private func speedLabel(_ value: Double) -> String {
        String(format: "%g×", value)
    }
}

/// 播放器时间标签：与全项目共用 `formatDuration` 的补零规则。
func formatPlayerTime(_ seconds: Double) -> String { formatDuration(seconds) }

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
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 2) {
            // 画面入口顶栏与画面内共用：显示方式、比例预设与平移都只改显示层。
            framingMenu
            if ui.audioChoices.count > 1 { audioMenu }
            // 章节 / 角度 / HDR 入口顶栏与画面内共用：蓝光与电影都靠它跳段、切视角与切映射。
            if ui.chapters.count > 1 { chapterMenu }
            if ui.angleCount > 1 { angleMenu }
            if ui.hdrToneMapAvailable { hdrMenu }
            // 顶栏只保留音轨入口：字幕在画面内控制条与「视频 › 字幕」菜单里切换。
            if style == .overlay { subtitleMenu }
        }
    }

    private var framingMenu: some View {
        Menu {
            Section("显示方式") {
                ForEach(VideoFramingMode.allCases) { mode in
                    Toggle(isOn: Binding(
                        get: { settings.videoFramingMode == mode },
                        set: { isOn in
                            if isOn { settings.videoFramingMode = mode }
                        }
                    )) {
                        Text(mode.title)
                    }
                }
            }
            Section("画面比例") {
                ForEach(VideoAspectPreset.allCases) { preset in
                    Toggle(isOn: Binding(
                        get: { settings.videoAspectPreset == preset },
                        set: { isOn in
                            guard isOn else { return }
                            settings.videoAspectPreset = preset
                            // 换比例后原来的平移量没有意义，回到居中。
                            settings.videoPanX = 0
                            settings.videoPanY = 0
                        }
                    )) {
                        Text(preset.title)
                    }
                }
            }
            Section("平移") {
                Button("上移画面") { nudgePan(dx: 0, dy: -0.25) }
                Button("下移画面") { nudgePan(dx: 0, dy: 0.25) }
                Button("左移画面") { nudgePan(dx: -0.25, dy: 0) }
                Button("右移画面") { nudgePan(dx: 0.25, dy: 0) }
                Button("居中") {
                    settings.videoPanX = 0
                    settings.videoPanY = 0
                }
            }
            Divider()
            Text("\(settings.videoFramingMode.title) · \(settings.videoAspectPreset.title)")
        } label: {
            icon("crop", active: settings.videoFramingMode != .fit
                || settings.videoAspectPreset != .source)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("画面显示方式 / 比例 / 平移")
    }

    /// 平移量是 -1...1 的比例，由布局层换算成像素；画面不超出裁剪框时移动不会有可见效果。
    private func nudgePan(dx: Double, dy: Double) {
        settings.videoPanX = min(1, max(-1, settings.videoPanX + dx))
        settings.videoPanY = min(1, max(-1, settings.videoPanY + dy))
    }

    private var chapterMenu: some View {
        Menu {
            // 蓝光盘内标题：标准里没有逐章文本名，用它做菜单标题行。
            if let discTitle = ui.discTitle {
                Text(discTitle)
                Divider()
            }
            ForEach(Array(ui.chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    ui.onSeekChapter?(chapter.start)
                } label: {
                    if ui.currentChapterIndex(at: model.currentTime) == index {
                        Label(chapterTitle(chapter), systemImage: "checkmark")
                    } else {
                        Text(chapterTitle(chapter))
                    }
                }
            }
        } label: {
            icon("list.bullet.rectangle.portrait", active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("章节（⌥← / ⌥→）")
    }

    private func chapterTitle(_ chapter: VideoChapter) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "章节" : title
    }

    private var angleMenu: some View {
        Menu {
            ForEach(1...ui.angleCount, id: \.self) { angle in
                Button {
                    ui.selectAngle(angle)
                } label: {
                    if angle == ui.selectedAngle {
                        Label("角度 \(angle)", systemImage: "checkmark")
                    } else {
                        Text("角度 \(angle)")
                    }
                }
            }
        } label: {
            icon("camera.rotate", active: ui.selectedAngle > 1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("蓝光多角度")
    }

    private var hdrMenu: some View {
        Menu {
            Toggle("色调映射到 SDR", isOn: Binding(
                get: { ui.hdrToneMapEnabled },
                set: { ui.setHDRToneMap($0) }
            ))
            Text(ui.hdrToneMapEnabled ? "当前：已映射，颜色与片源观感一致（转码）"
                                      : "当前：原样交给系统解码（HDR 屏）")
        } label: {
            icon("sun.max", active: ui.hdrToneMapEnabled)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("HDR 色调映射（本次播放）")
    }

    private var audioMenu: some View {
        Menu {
            // 用菜单式 Toggle 而不是自绘 checkmark：macOS 的 NSMenu 只认系统勾选状态，
            // HStack 里的 Image 会被丢掉，表现就是「一条都没选中」。
            ForEach(ui.audioChoices) { choice in
                let title = choice.title.isEmpty ? "音轨 \(choice.index + 1)" : choice.title
                Toggle(isOn: Binding(
                    get: { choice.index == ui.selectedAudioIndex },
                    set: { isOn in
                        if isOn { ui.selectAudio(choice.index) }
                    }
                )) {
                    Text(title)
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
            if !ui.embeddedTracks.isEmpty {
                ForEach(ui.embeddedTracks) { track in
                    if track.isImage {
                        // 图形字幕（PGS / VobSub）无法转文本，只能烧进画面。
                        Button {
                            ui.burnEmbeddedTrack(track)
                        } label: {
                            if ui.burnSubtitleStream == track.ordinal {
                                Label("烧录图形 · \(track.displayName)", systemImage: "checkmark")
                            } else {
                                Text("烧录图形 · \(track.displayName)")
                            }
                        }
                    } else {
                        Button {
                            ui.selectEmbeddedTrack(track)
                        } label: {
                            if ui.embeddedTrackOrdinal == track.ordinal {
                                Label("内嵌 · \(track.displayName)", systemImage: "checkmark")
                            } else {
                                Text("内嵌 · \(track.displayName)")
                            }
                        }
                        .disabled(ui.embeddedLoading)
                    }
                }
                if ui.embeddedLoading { Text("正在提取内嵌字幕…") }
                Divider()
            }
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
                Button("关闭字幕") { ui.clearEmbeddedSubtitle() }
                Divider()
                Button("字幕延后 0.5 秒") { ui.adjustOffset(0.5) }
                Button("字幕提前 0.5 秒") { ui.adjustOffset(-0.5) }
                Button("重置偏移（当前 \(offsetText)）") { ui.resetOffset() }
            }
            if ui.embeddedTrackOrdinal != nil {
                Button("关闭内嵌字幕") { ui.clearEmbeddedSubtitle() }
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
        var parts = [match.provider.title, match.languageTitle, match.title]
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
