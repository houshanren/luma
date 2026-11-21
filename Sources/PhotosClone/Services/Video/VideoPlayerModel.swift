import AVFoundation
import AVKit
import Combine
import AppKit
import QuartzCore

final class VideoPlayerModel: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// 当前 AVPlayerItem 是否已经 readyToPlay。装上片子到出第一帧之间还有一段空窗，
    /// 这段时间界面必须显示等待动画，否则看起来就像「暂停了」。
    @Published private(set) var isItemReady = false
    /// 跳转请求还没有落地：大文件 / 网络流拖进度条时要等一会儿。
    @Published private(set) var isSeeking = false
    /// 用户意图是「要播放」：暂停时为 false。
    /// 缓冲等待也算播放中，否则中央会冒出播放按钮、控制条也会突然弹出来。
    @Published private(set) var wantsPlayback = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPipAvailable = false
    @Published private(set) var isPipActive = false
    /// 可选音轨 / 内嵌字幕（AVFoundation 原生容器与 HLS 音轨组）。
    @Published private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published private(set) var selectedAudio: AVMediaSelectionOption?
    @Published private(set) var legibleOptions: [AVMediaSelectionOption] = []
    @Published private(set) var selectedLegible: AVMediaSelectionOption?
    /// 从第几秒开始播放：云盘跳转后会话从目标位置重新起流，
    /// 播放器时间轴从 0 开始，对外统一换算成完整时间轴。
    private(set) var timelineOffset: Double = 0

    @Published var speed: Double = 1
    @Published var volume: Double = 1 {
        didSet { player.volume = Float(volume) }
    }
    @Published var isMuted = false {
        didSet { player.isMuted = isMuted }
    }
    @Published var isLooping = false
    @Published var gravity: AVLayerVideoGravity = .resizeAspect

    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var itemCancellables: Set<AnyCancellable> = []
    private var pipObservers: Set<AnyCancellable> = []
    private var endObserver: NSObjectProtocol?
    private weak var pipController: AVPictureInPictureController?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var pendingAutoplay = false
    /// 续播定位：装片后先 seek 到目标位置再开播，避免先播 0 秒再跳。
    private var pendingInitialSeek: Double?
    /// 定位完成前不让周期采样把时间轴改回 0，进度文字不会闪一下片头。
    private var suppressTimeUpdates = false
    /// 连续拖动时只认最后一次跳转：旧的 seek 回调不能把「跳转中」提前关掉。
    private var seekToken = 0
    /// 兜底判定：周期采样里进度连续 1 秒不动就算卡住了（KVO 偶尔不报 waiting 状态）。
    private var lastSampleTime: Double = -1
    private var stalledSamples = 0
    /// 播放到结尾且未开启循环时回调，用于自动连播下一个视频。
    var onPlaybackEnd: (@MainActor () -> Void)?
    /// 云盘流式播放的跳转路由：返回 true 表示调用方（播放页）已经重建了流，本次不再直接 seek。
    var seekRouter: ((Double) -> Bool)?

    /// 界面上的跳转统一走这里：云盘未生成区间会触发重新起流。
    func requestSeek(to seconds: Double) {
        if let seekRouter, seekRouter(seconds) { return }
        seek(to: seconds)
    }

    /// 需要给用户看得见的等待动画：还没出画面、缓冲中，或正在跳转。
    /// 暂停时拖动进度条不该弹动画，安静等目标帧解码完就行。
    var isStalled: Bool {
        guard errorMessage == nil, player.currentItem != nil else { return false }
        if !isItemReady { return true }
        return isBuffering || (isSeeking && wantsPlayback)
    }

    init() {
        installTimeObserver()
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let waiting = status == .waitingToPlayAtSpecifiedRate
                // 「等待数据」仍然算播放中：只是画面暂时跟不上，不能当成暂停。
                self.isPlaying = status == .playing || waiting
                self.isBuffering = waiting
                if status == .playing { self.isSeeking = false }
            }
            .store(in: &cancellables)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let item = note.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                if self.duration > 0 { self.currentTime = self.duration }
                if self.isLooping {
                    self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    self.player.playImmediately(atRate: Float(self.speed))
                } else {
                    self.player.pause()
                    self.onPlaybackEnd?()
                }
            }
        }
    }

    deinit {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite, !self.suppressTimeUpdates {
                    self.currentTime = max(0, seconds + self.timelineOffset)
                }
                if seconds.isFinite, !self.suppressTimeUpdates {
                    self.sampleStall(localSeconds: max(0, seconds))
                }
                guard let item = self.player.currentItem else { return }
                // 边下边播的 HLS 时长会随分片写入增长，取较大值更新进度条上限。
                let value = CMTimeGetSeconds(item.duration)
                if value.isFinite, value > 0 {
                    let total = value + self.timelineOffset
                    if total > self.duration { self.duration = total }
                }
                if let range = item.loadedTimeRanges.last?.timeRangeValue {
                    let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
                    if end.isFinite {
                        let absolute = end + self.timelineOffset
                        let clamped = self.duration > 0 ? min(absolute, self.duration) : absolute
                        if clamped > self.bufferedTime { self.bufferedTime = clamped }
                    }
                }
            }
        }
    }

    /// 采样兜底：KVO 偶尔不会报「等待数据」，但进度停住是能直接看到的。
    /// 连续 4 个采样（约 1 秒）没前进就置为缓冲中；一旦重新前进立即恢复。
    private func sampleStall(localSeconds: Double) {
        let advanced = abs(localSeconds - lastSampleTime) >= 0.01
        lastSampleTime = localSeconds
        if advanced {
            stalledSamples = 0
            if isBuffering, player.timeControlStatus == .playing { isBuffering = false }
            return
        }
        guard wantsPlayback, isItemReady else {
            stalledSamples = 0
            return
        }
        // 片尾停在最后一帧不算卡顿。
        if duration > 0, currentTime >= duration - 0.6 {
            stalledSamples = 0
            return
        }
        stalledSamples += 1
        if stalledSamples >= 4 { isBuffering = true }
    }

    func load(url: URL, options: [String: Any] = [:], probe: VideoProbe,
              autoplay: Bool = true, loop: Bool = false, muted: Bool = false,
              timelineOffset: Double = 0, startAt: Double? = nil) {
        load(asset: AVURLAsset(url: url, options: options), probe: probe,
             autoplay: autoplay, loop: loop, muted: muted,
             timelineOffset: timelineOffset, startAt: startAt)
    }

    /// 直接装载 AVAsset：PhotoKit 返回的云端 / 共享相簿素材没有本地文件 URL。
    /// `startAt` 是完整时间轴上的起播秒数：装片后先定位再开播，不会先闪一下 0 秒。
    func load(asset: AVAsset, probe: VideoProbe,
              autoplay: Bool = true, loop: Bool = false, muted: Bool = false,
              timelineOffset: Double = 0, startAt: Double? = nil) {
        resetForNewItem()
        self.timelineOffset = max(0, timelineOffset)
        duration = probe.duration
        isLooping = loop
        isMuted = muted
        pendingAutoplay = autoplay
        if let startAt, startAt > 0 {
            pendingInitialSeek = startAt
            suppressTimeUpdates = true
            currentTime = startAt
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        observe(item)
        player.replaceCurrentItem(with: item)
        // 可能在订阅之后就已经 ready：补一次同步，避免等待动画一直不消失。
        isItemReady = item.status == .readyToPlay
        player.isMuted = isMuted
        player.volume = Float(volume)
    }

    func stop() {
        player.pause()
        resetForNewItem()
        player.replaceCurrentItem(with: nil)
    }

    private func resetForNewItem() {
        errorMessage = nil
        itemCancellables.removeAll()
        currentTime = 0
        bufferedTime = 0
        isBuffering = false
        isPlaying = false
        isItemReady = false
        isSeeking = false
        wantsPlayback = false
        seekToken &+= 1
        lastSampleTime = -1
        stalledSamples = 0
        pendingAutoplay = false
        pendingInitialSeek = nil
        suppressTimeUpdates = false
        timelineOffset = 0
        audioOptions = []
        selectedAudio = nil
        legibleOptions = []
        selectedLegible = nil
        audioGroup = nil
        legibleGroup = nil
    }

    private func observe(_ item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.errorMessage = nil
                    // 到这里才真正有画面：之前一律按「还没准备好」显示等待动画。
                    self.isItemReady = true
                    let value = CMTimeGetSeconds(item.duration)
                    if value.isFinite, value > 0 {
                        let total = value + self.timelineOffset
                        if total > self.duration { self.duration = total }
                    }
                    self.refreshMediaOptions(for: item)
                    // 续播：先定位到目标帧，再开始播放，界面不会闪一下片头。
                    if let start = self.pendingInitialSeek {
                        self.pendingInitialSeek = nil
                        let local = max(0, start - self.timelineOffset)
                        self.player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            DispatchQueue.main.async {
                                guard let self else { return }
                                self.suppressTimeUpdates = false
                                if self.pendingAutoplay {
                                    self.pendingAutoplay = false
                                    self.play()
                                }
                            }
                        }
                    } else if self.pendingAutoplay {
                        self.pendingAutoplay = false
                        self.play()
                    }
                case .failed:
                    self.errorMessage = item.error?.localizedDescription ?? "该视频无法播放"
                    self.isItemReady = false
                    self.isBuffering = false
                    self.isSeeking = false
                default:
                    self.isItemReady = false
                }
            }
            .store(in: &itemCancellables)

        item.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] empty in
                guard let self, let item, self.player.currentItem === item else { return }
                // 用「想播」判断，不能用 isPlaying：等待数据时它已经不是 .playing。
                if empty, self.wantsPlayback { self.isBuffering = true }
            }
            .store(in: &itemCancellables)

        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] keepUp in
                guard let self, let item, self.player.currentItem === item else { return }
                if keepUp { self.isBuffering = false }
            }
            .store(in: &itemCancellables)
    }

    // MARK: 播放控制

    func play() {
        guard player.currentItem != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            // 从本段起点重新播：跳转会话的时间轴 0 对应 timelineOffset。
            seek(to: timelineOffset)
        }
        wantsPlayback = true
        player.playImmediately(atRate: Float(speed))
    }

    func pause() {
        wantsPlayback = false
        isBuffering = false
        player.pause()
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: Double) {
        let lower = timelineOffset
        let upper = duration > 0 ? max(lower, duration) : max(lower, seconds)
        let target = min(max(seconds, lower), upper)
        currentTime = target
        let local = max(0, target - timelineOffset)
        seekToken &+= 1
        let token = seekToken
        isSeeking = true
        player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, token == self.seekToken else { return }
                // 目标帧已经解出来了；如果播放器还停在等待状态，
                // 让 timeControlStatus 的回调收尾，避免动画提前闪掉。
                if self.player.timeControlStatus == .playing || !self.wantsPlayback {
                    self.isSeeking = false
                }
            }
        }
    }

    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setSpeed(_ value: Double) {
        speed = value
        if isPlaying { player.rate = Float(value) }
    }

    func stepFrame(by count: Int) {
        guard let item = player.currentItem else { return }
        if isPlaying { pause() }
        item.step(byCount: count)
    }

    // MARK: 音轨 / 内嵌字幕

    /// 装载完成后读取可切换的音轨与内嵌字幕（HLS 只有音轨组）。
    private func refreshMediaOptions(for item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor [weak self] in
            guard let self, self.player.currentItem === item else { return }
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                self.audioGroup = group
                self.audioOptions = group.options
                self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: group)
            }
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                self.legibleGroup = group
                self.legibleOptions = group.options
                self.selectedLegible = item.currentMediaSelection.selectedMediaOption(in: group)
            }
        }
    }

    func selectAudio(_ option: AVMediaSelectionOption?) {
        guard let group = audioGroup, let item = player.currentItem else { return }
        if let option {
            item.select(option, in: group)
        } else {
            item.select(nil, in: group)
        }
        selectedAudio = option
    }

    func selectLegible(_ option: AVMediaSelectionOption?) {
        guard let group = legibleGroup, let item = player.currentItem else { return }
        if let option {
            item.select(option, in: group)
        } else {
            item.select(nil, in: group)
        }
        selectedLegible = option
    }

    // MARK: 画中画

    func attachPip(_ controller: AVPictureInPictureController?) {
        pipController = controller
        pipObservers.removeAll()
        guard let controller else {
            isPipAvailable = false
            isPipActive = false
            return
        }
        controller.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] possible in
                self?.isPipAvailable = possible
            }
            .store(in: &pipObservers)

        controller.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isPipActive = active
            }
            .store(in: &pipObservers)
    }

    func togglePip() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
    }

    // MARK: 截图

    func currentFrameImage() async -> CGImage? {
        guard let item = player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = player.currentTime()
        guard let result = try? await generator.image(at: time) else { return nil }
        return result.image
    }
}
