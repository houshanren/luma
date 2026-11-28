import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore
import LumaCore

struct VideoPlayerStage: View {
    @Environment(LibraryStore.self) var store
    @Environment(AppSettings.self) var settings
    @Environment(ViewerModel.self) var viewer
    let photo: PhotoItem
    /// 播放状态由查看器持有：顶栏融合模式下，窗口工具栏要用同一份状态渲染播放控件。
    let model: VideoPlayerModel
    /// 音轨 / 字幕状态：与窗口顶栏共享同一份。
    let ui: VideoPlaybackUI
    /// 手动旋转角度同样提到查看器，顶栏按钮与画面共用。
    @Binding var quarterTurns: Int
    /// 保存当前帧需要读取查看器里的照片与旋转状态，由查看器提供。
    var onCaptureFrame: () -> Void = {}
    /// 窗口内浏览：播放器透明，画面两侧露出照片模糊灯箱。
    var transparentBackground: Bool = false
    /// 查看器的缩放与位移：只作用于画面，控制层始终保持原尺寸。
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    @State var sourceURL: URL?
    /// 当前片源的播放模式与能力：直播不显示进度条 / 续播，后续电视频道页直接读它。
    @State var playbackMode: PlaybackMode = .vod
    @State var playbackCapabilities: PlaybackCapabilities = .vod
    /// 云端直链要求的请求头（WebDAV 的 Basic 认证等），转码时同样要带上。
    @State var sourceHeaders: [String: String] = [:]
    /// 百度直链不带扩展名、要求固定 UA，且会 302 到 CDN；
    /// 用资源加载器转发，保证每一跳都带请求头并补全 Content-Type。
    @State var cloudResourceLoader: CloudAssetResourceLoader?
    /// 播放器是否已经装上片子。PhotoKit 返回的素材可能没有本地 URL，不能只看 sourceURL。
    @State var hasLoadedVideo = false
    @State var assetOptions: [String: Any] = [:]
    @State var isPreparing = true
    /// 起播阶段的底图：本地视频直接读缩略图做模糊背景，网络源没有就退回渐变。
    @State var loadingThumbnail: NSImage?
    /// 本地 / SMB 起播点真实帧：拿得到就优先于缩略图，质量足够铺满。
    @State var loadingFrame: NSImage?
    @State var posterFrameTask: Task<Void, Never>?
    /// 起播进行到哪一步：等待层据此显示阶段文案。
    @State var waitingStage: VideoWaitingStage = .preparing
    @State var failureMessage: String?
    /// 云端直链获取失败的具体原因（授权、文件 ID、接口错误等）。
    @State var streamFailure: String?
    @State var canTranscode = false
    @State var isTranscoding = false
    /// 本次装片是否已经为「系统播放器不兼容」自动重编码过一次：失败后不再反复拉起 ffmpeg。
    @State var didAutoTranscodeFallback = false
    /// 探测到的完整时长 / 编码信息：跳转后的新会话仍按完整时间轴显示进度。
    @State var probeDuration: Double = 0
    @State var probeIsHEVC = false
    @State var probeIsHDR = false
    /// 片源色彩管线：转封装写回容器、HDR 策略判断都要用。
    @State var probeColor = VideoColorInfo()
    /// 杜比视界缺 libplacebo 的提示只弹一次。
    @State var dvHintShown = false
    @State var probeAudioCount = 0
    @State var probeAudioTracks: [AudioTrackInfo] = []
    /// ffprobe 补齐的完整技术信息：码率 / 帧率 / HDR / 章节。
    @State var playbackProbe = VideoProbe()
    /// 本次播放的 HDR 映射覆盖：nil 表示跟随设置；用户切开关后按新策略重建流。
    @State var hdrToneMapOverride: Bool?
    /// 蓝光多角度：可用视角数量与当前选择（1 起）。
    @State var angleCount = 1
    @State var selectedAngle = 1
    /// I 键播放信息叠加。
    @State var showPlaybackInfo = false
    /// ⌘⇧I：在播放信息里展开完整 ffprobe 字段。
    @State var showFullProbe = false
    /// 电视 OSD：频道号输入缓冲。
    @State var tvChannelNumberBuffer = ""
    @State var tvChannelNumberTask: Task<Void, Never>?
    /// 内嵌字幕只自动尝试挂载一次，避免用户主动关掉后又弹回来。
    @State var autoEmbeddedTried = false
    /// 完整缓存起播时真实直链还在后台解析：技术探测等直链回来再做，先不探测占位地址。
    @State var cachedSourcePending = false
    /// 控制层是否处于“刚操作过”的可见状态；播放中静止数秒后自动淡出。
    @State var controlsShown = true
    @State var hideControlsTask: Task<Void, Never>?
    @State var lastHoverMove = Date.distantPast
    /// 控制条可自由拖动，位置按比例以外的绝对偏移持久化。
    @AppStorage("video.controls.offsetX") var controlOffsetX: Double = 0
    @AppStorage("video.controls.offsetY") var controlOffsetY: Double = 0
    @State var controlPanelSize: CGSize = .zero
    @State var dragStartOffset: CGSize?
    /// 时长文字点击后显示剩余时间。
    @State var showRemainingTime = false
    @State var hasPrevVideo = false
    @State var hasNextVideo = false
    /// 视频原始尺寸（仅影响播放显示，不改原文件）。
    @State var videoSize: CGSize = .zero
    /// 载入代次：连续翻页时作废旧任务，避免旧视频覆盖新照片并继续出声。
    @State var loadGeneration = 0
    /// 已开始装片的线路身份；Store 换线后、SwiftUI 新任务启动前的旧回调据此作废。
    @State var tvAttemptKey: String?
    /// 播放器真正所在的窗口：全屏按钮必须切换这个窗口，
    /// 用 NSApp.keyWindow 在弹出面板 / 子窗口存在时会切错窗口。
    @State var playerWindow: NSWindow?

    /// 播放编排状态由内核持有；这里只读转发，避免 View 再维护一份会话状态。
    var playbackSession: PlaybackSession { viewer.playbackSession }
    var streamSession: VideoStreamSession? { playbackSession.streamSession }
    var streamMode: VideoStreamSession.Mode { playbackSession.streamMode }
    var streamAudioIndex: Int { playbackSession.streamAudioIndex }
    var isRestartingStream: Bool { playbackSession.isRestartingStream }

    /// 控制条距视频底部的默认间距；向上拖动的下限与之一致。
    let controlPanelBottomInset: CGFloat = 28
    /// 允许向下拖动控制条的距离上限，避免贴到画面边缘。
    let controlPanelMaxDownOffset: CGFloat = 16

    var controlsVisible: Bool { controlsShown || !model.isPlaying }

    var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }

    var buffered: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.bufferedEndTime / model.duration))
    }

    /// 起播前向缓冲：先用短缓冲把画面放出来，播放开始后由播放编排拉到设置里的档位。
    /// 直接给 16 秒会让 AVPlayer 先攒够数据才起播，网络源上就是几秒黑屏。
    var startupForwardBuffer: Double {
        min(4, settings.videoBufferProfile.forwardBufferDuration)
    }

    /// 当前会话还能直接回退到的最早位置：更早的分片已经不在，跳过去会重建流。
    var bufferedStart: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, playbackSession.retainedStartSeconds / model.duration))
    }

    var activeFailure: String? {
        // 重建流期间旧会话的本地分片服务会短暂断开，AVPlayer 随即报「无法连接服务器」。
        // 这属于中间态，真正的失败由 failureMessage 表达，不能把瞬时错误弹成错误卡片。
        if isPreparing || playbackSession.isRestartingStream { return failureMessage }
        return failureMessage ?? model.errorMessage
    }

    /// 当前画面是不是电视频道（直播或回看）。
    var tvPlaybackChannel: TVChannel? {
        store.tvPlaybackChannel(for: photo.id)
    }

    /// 文件就在本机磁盘（拾光图库、系统「照片」本地原件、外接目录），且不是网络卷。
    /// 按设计这类源起播几乎瞬时：不取首帧、不显示等待层，也不弹缓冲提示，直接出画面。
    var isLocalVideo: Bool {
        guard photo.isVideo,
              !photo.isCloud,
              store.catalogPlaybackContext(for: photo.id) == nil,
              tvPlaybackChannel == nil else { return false }
        let url = LibraryPaths.sourceURL(for: photo)
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        return !VideoSupport.isNetworkVolume(url)
    }

    /// 只有直播才启用遥控语义（换台 / 频道带）；回看走点播的进度条。
    var tvLiveChannel: TVChannel? {
        guard playbackMode == .live, let channel = tvPlaybackChannel, !channel.isCatchUp else {
            return nil
        }
        return channel
    }

    /// 装片键：换台（photo.id 变化）或换线（tvLineTokens 自增）都要重新装片。
    /// 之前只监听 photo.id，手动选线路后地址变了、代次也变了，但没有触发重新装片，
    /// 表现就是「点了线路没反应」。
    var playbackReloadKey: String {
        "\(photo.id.uuidString)-\(store.tvLineTokens[photo.id, default: 0])"
    }

    /// 电视 OSD 的独立子视图：把大段类型推断从 `body` 里拆出去。
    @ViewBuilder
    var tvOverlay: some View {
        @Bindable var viewer = viewer
        // 失败态也保留频道信息条，和概念图「状态 C」一致：先知道是哪个台，再看卡片。
        if let channel = tvPlaybackChannel {
            TVPlaybackOverlay(channel: channel,
                              photoID: photo.id,
                              isLive: playbackMode == .live && !channel.isCatchUp,
                              controlsVisible: activeFailure == nil ? controlsVisible : true,
                              timeshiftActive: $viewer.tvTimeshiftActive,
                              showGuide: $viewer.tvGuideShown,
                              model: model,
                              failureMode: activeFailure != nil,
                              usesWindowToolbarActions: transparentBackground
                                  && !viewer.videoImmersiveFullScreen
                                  && settings.videoControlPlacement == .topIntegrated,
                              onCaptureFrame: onCaptureFrame)
        }
    }

    func resetTVInput() {
        // 换台后收起节目单抽屉，清掉未提交的频道号输入。
        viewer.tvGuideShown = false
        viewer.tvTimeshiftActive = false
        tvChannelNumberTask?.cancel()
        tvChannelNumberTask = nil
        tvChannelNumberBuffer = ""
    }

    /// 时移步进：限制在真实可 seek 的窗口内，避免越过河床两端。
    func seekTimeshift(by delta: Double) {
        let lower = model.seekableStartTime
        let upper = max(lower, model.bufferedEndTime - 0.4)
        let target = min(upper, max(lower, model.currentTime + delta))
        model.requestSeek(to: target)
    }

    /// 直播失败只推进当前装片；旧任务、重复回调与回看都不消耗重试次数。
    func attemptTVLineFallback(reason: String? = nil, generation: Int) {
        guard generation == loadGeneration, tvAttemptKey == playbackReloadKey,
              let channel = tvPlaybackChannel, !channel.isCatchUp else { return }
        let url = channel.streamURL
        let token = store.tvLineTokens[photo.id, default: 0]
        switch store.advanceTVLineAfterFailure(for: photo.id, token: token, url: url, reason: reason) {
        case .next:
            failureMessage = nil
            streamFailure = nil
        case .exhausted:
            failureMessage = store.tvLiveRetryExhaustedMessage(for: photo.id)
        case .ignored:
            break
        }
    }

    func rememberTVLiveLineIfReady(generation: Int) {
        guard generation == loadGeneration, tvAttemptKey == playbackReloadKey, model.isItemReady, let channel = tvLiveChannel else { return }
        store.rememberTVLiveLine(for: photo.id,
                                 token: store.tvLineTokens[photo.id, default: 0],
                                 url: channel.streamURL)
    }

    /// 把播放错误翻译成失败卡片上的一行原因。
    func lineFailureReason(_ failure: PlaybackFailure?) -> String {
        guard let failure else { return "无响应" }
        if let status = failure.httpStatus { return "返回 \(status)" }
        switch failure.code {
        case -1001: return "超时"
        case -1004, -1005, -1009: return "无法连接"
        case -11800, -11828, -12927: return "编码不兼容"
        default: break
        }
        return failure.domain == NSURLErrorDomain ? "网络错误" : "无响应"
    }

    func startPlaybackTask() async {
        tvAttemptKey = playbackReloadKey
        loadGeneration &+= 1
        let generation = loadGeneration
        if settings.videoRememberSpeed, settings.videoLastSpeed > 0,
           settings.videoLastSpeed != 1 {
            model.setSpeed(settings.videoLastSpeed)
        }
        await preparePlayback(generation: generation)
        rememberTVLiveLineIfReady(generation: generation)
    }

    /// 直播独立处理三轮换线；回看与普通视频继续沿用原有兜底。
    func handlePlaybackFailure(_ failure: PlaybackFailure?) {
        guard let failure else { return }
        if let channel = tvPlaybackChannel, !channel.isCatchUp {
            let line = store.tvLineIndex(for: photo.id) + 1
            let total = store.tvLineCount(for: photo.id)
            let host = URL(string: channel.streamURL)?.host ?? "-"
            Diagnostics.record("电视线路失败 \(channel.name) 线路\(line)/\(total) \(host)："
                               + "\(failure.domain ?? "-") \(failure.code.map(String.init) ?? "-") "
                               + "http=\(failure.httpStatus.map(String.init) ?? "-") \(failure.message)")
            attemptTVLineFallback(reason: "\(lineFailureReason(failure))（\(host)）",
                                  generation: loadGeneration)
            return
        }
        guard hasLoadedVideo else { return }
        Diagnostics.record("装片失败 \(photo.originalName)："
                           + "\(failure.domain ?? "-") \(failure.code.map(String.init) ?? "-") "
                           + "incompatible=\(failure.isIncompatibleAsset) \(failure.message)")
        guard FFmpeg.isAvailable, sourceURL != nil else { return }
        canTranscode = true
        // -12927 / -11828：系统播放器判定码流不兼容，重封装不会变好，直接改走兼容转码。
        guard failure.isIncompatibleAsset, !didAutoTranscodeFallback else { return }
        didAutoTranscodeFallback = true
        autoFallbackToTranscode(after: failure)
    }

    /// 流地址解析失败也走同一个直播三轮入口，避免重复计数。
    func handleStreamFailureChange(_ value: String?) {
        guard let value, let channel = tvPlaybackChannel, !channel.isCatchUp else { return }
        let line = store.tvLineIndex(for: photo.id) + 1
        let total = store.tvLineCount(for: photo.id)
        let host = URL(string: channel.streamURL)?.host ?? "-"
        let reason = value.lowercased().contains("403") ? "返回 403" : "无响应"
        Diagnostics.record("电视流出错 \(channel.name) 线路\(line)/\(total) \(host)：\(value)")
        attemptTVLineFallback(reason: "\(reason)（\(host)）", generation: loadGeneration)
    }

    /// 离开播放层：停流、撤销画中画与窗口显示模式，全部集中在这里，避免 `body` 里的闭包过大。
    func handleStageDisappear() {
        FullScreenDiagnostics.log("video stage disappear \(photo.originalName)")
        if settings.videoRememberSpeed { settings.videoLastSpeed = model.speed }
        NowPlayingCenter.shared.deactivate()
        VideoScrubPreviewCenter.shared.fallbackProvider = nil
        VideoScrubPreviewCenter.shared.end()
        loadGeneration &+= 1
        posterFrameTask?.cancel()
        posterFrameTask = nil
        tvAttemptKey = nil
        hideControlsTask?.cancel()
        model.seekRouter = nil
        model.scrubGuard = nil
        playbackSession.onHardStall = nil
        playbackSession.onNativeStall = nil
        model.stop()
        DisplayModeMatcher.restore()
        cloudResourceLoader?.invalidate()
        cloudResourceLoader = nil
        playbackSession.stop()
    }

    /// 读取本地缩略图做起播底图；网络 / 云盘视频没有对应文件时返回 nil。
    func fileExistsThumbnail() -> NSImage? {
        let url = LibraryPaths.thumbnailURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 等待层：信息优先，只有分辨率合格的素材才铺满；出画面后淡出。
    /// 出画面之后的卡顿只用紧凑缓冲胶囊，不整页遮挡。
    @ViewBuilder
    func waitingLayer() -> some View {
        if activeFailure == nil {
            // 本地视频起播几乎瞬时：不垫首帧、不显示等待层，直接出画面。
            if !model.isItemReady, !isLocalVideo {
                VideoWaitingLayer(info: waitingInfo())
                    .transition(.opacity)
            }
            // 本地视频的卡顿 / 重建流也不加缓冲提示，避免在画面上叠任何东西。
            if !isLocalVideo {
                VideoBufferingOverlay(active: model.isItemReady && (model.isStalled || isRestartingStream),
                                      label: "缓冲中",
                                      immediate: false,
                                      prominent: false)
            }
        }
    }

    /// 按来源拼出等待层要展示的标题 / 副标题 / 徽标与可用素材。
    func waitingInfo() -> VideoWaitingInfo {
        var title = (photo.originalName as NSString).deletingPathExtension
        if title.isEmpty { title = photo.filename }
        var subtitle: String?
        var badges: [String] = []

        if let context = store.catalogPlaybackContext(for: photo.id) {
            title = context.item.title
            subtitle = context.episode.title
            if !context.source.name.isEmpty { badges.append(context.source.name) }
        } else if let channel = tvPlaybackChannel {
            title = channel.name
            if let program = store.tvModel.currentProgram(for: channel) {
                subtitle = program.title
            }
            badges.append(channel.isCatchUp ? "回看" : "直播")
            if let quality = channel.qualityLabel, !quality.isEmpty { badges.append(quality) }
            let line = store.tvLineIndex(for: photo.id) + 1
            let total = store.tvLineCount(for: photo.id)
            if total > 1 { badges.append("线路 \(line)/\(total)") }
        } else if photo.isCloud {
            if let mount = store.cloudMount(for: photo.cloudMountID) {
                subtitle = mount.name
            }
            badges.append("网盘")
        }

        let width = max(photo.pixelWidth, Int(videoSize.width))
        let height = max(photo.pixelHeight, Int(videoSize.height))
        if let resolution = Self.resolutionBadge(width: width, height: height) {
            badges.append(resolution)
        }
        if probeColor.isDolbyVision {
            badges.append("Dolby Vision")
        } else if probeIsHDR {
            badges.append("HDR")
        }
        if probeIsHEVC || (photo.videoCodec?.lowercased() == "hevc" && !probeIsHEVC) {
            badges.append("HEVC")
        }
        if probeAudioCount > 1 { badges.append("\(probeAudioCount) 音轨") }
        if ui.isBurningSubtitle { badges.append("字幕烧录") }

        return VideoWaitingInfo(title: title,
                                subtitle: subtitle,
                                stage: waitingStage,
                                badges: badges,
                                image: loadingFrame ?? loadingThumbnail)
    }

    static func resolutionBadge(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let shortEdge = min(width, height)
        if shortEdge >= 2000 { return "4K" }
        if shortEdge >= 1000 { return "1080P" }
        if shortEdge >= 700 { return "720P" }
        return nil
    }

    /// 当前时间点应显示的字幕（已套用字幕偏移），带 ASS 样式时会按样式渲染。
    var activeCue: SubtitleCue? {
        ui.cue(at: model.currentTime)
    }

    /// 字幕覆盖层：SRT / VTT 用用户设置，ASS / SSA 优先用字幕自带的颜色、字号与对齐。
    @ViewBuilder
    func subtitleOverlay(_ cue: SubtitleCue, in size: CGSize) -> some View {
        let style = cue.style
        let fontSize = settings.subtitleFontSize * (style?.fontScale ?? 1)
        let color = style?.primaryColor.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue).opacity($0.alpha)
        } ?? subtitleTextColor
        let outline = style?.outlineColor.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue).opacity($0.alpha)
        } ?? Color.black
        let anchor = style?.verticalAnchor ?? 1

        VStack(spacing: 0) {
            if anchor <= 0.25 {
                subtitleText(cue, fontSize: fontSize, color: color, outline: outline)
                    .padding(.top, 48)
                Spacer(minLength: 0)
            } else if anchor < 0.75 {
                Spacer(minLength: 0)
                subtitleText(cue, fontSize: fontSize, color: color, outline: outline)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                subtitleText(cue, fontSize: fontSize, color: color, outline: outline)
                    .padding(.bottom, subtitleBottomPadding(in: size))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    func subtitleText(_ cue: SubtitleCue,
                              fontSize: Double,
                              color: Color,
                              outline: Color) -> some View {
        Text(cue.text)
            .font(.system(size: fontSize, weight: cue.style?.bold == true ? .bold : .semibold))
            .italic(cue.style?.italic == true)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(settings.subtitleBackground ? Color.black.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            // 用四个方向的零模糊阴影模拟 ASS 描边。
            .shadow(color: outline.opacity(0.95), radius: 1, x: 0, y: 0)
            .shadow(color: outline.opacity(0.8), radius: 0, x: 1.2, y: 0)
            .shadow(color: outline.opacity(0.8), radius: 0, x: -1.2, y: 0)
            .shadow(color: outline.opacity(0.8), radius: 0, x: 0, y: 1.2)
            .shadow(color: outline.opacity(0.8), radius: 0, x: 0, y: -1.2)
            .frame(maxWidth: 860)
            .padding(.horizontal, 40)
    }

    var subtitleTextColor: Color {
        switch settings.subtitleColor {
        case "yellow": return Color(red: 1.0, green: 0.86, blue: 0.38)
        case "cyan": return Color(red: 0.45, green: 0.95, blue: 0.98)
        case "green": return Color(red: 0.58, green: 0.98, blue: 0.66)
        default: return .white
        }
    }

    func subtitleBottomPadding(in size: CGSize) -> CGFloat {
        switch settings.subtitlePosition {
        case "middle": return max(160, size.height * 0.34)
        case "lower": return 190
        default: return 118
        }
    }

}
