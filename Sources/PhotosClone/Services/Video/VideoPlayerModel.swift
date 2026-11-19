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
    /// 播放到结尾且未开启循环时回调，用于自动连播下一个视频。
    var onPlaybackEnd: (@MainActor () -> Void)?
    /// 云盘流式播放的跳转路由：返回 true 表示调用方（播放页）已经重建了流，本次不再直接 seek。
    var seekRouter: ((Double) -> Bool)?

    /// 界面上的跳转统一走这里：云盘未生成区间会触发重新起流。
    func requestSeek(to seconds: Double) {
        if let seekRouter, seekRouter(seconds) { return }
        seek(to: seconds)
    }

    init() {
        installTimeObserver()
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
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
                if seconds.isFinite {
                    self.currentTime = max(0, seconds + self.timelineOffset)
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

    func load(url: URL, options: [String: Any] = [:], probe: VideoProbe,
              autoplay: Bool = true, loop: Bool = false, muted: Bool = false,
              timelineOffset: Double = 0) {
        load(asset: AVURLAsset(url: url, options: options), probe: probe,
             autoplay: autoplay, loop: loop, muted: muted, timelineOffset: timelineOffset)
    }

    /// 直接装载 AVAsset：PhotoKit 返回的云端 / 共享相簿素材没有本地文件 URL。
    func load(asset: AVAsset, probe: VideoProbe,
              autoplay: Bool = true, loop: Bool = false, muted: Bool = false,
              timelineOffset: Double = 0) {
        resetForNewItem()
        self.timelineOffset = max(0, timelineOffset)
        duration = probe.duration
        isLooping = loop
        isMuted = muted
        pendingAutoplay = autoplay

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        observe(item)
        player.replaceCurrentItem(with: item)
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
        pendingAutoplay = false
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
                    let value = CMTimeGetSeconds(item.duration)
                    if value.isFinite, value > 0 {
                        let total = value + self.timelineOffset
                        if total > self.duration { self.duration = total }
                    }
                    self.refreshMediaOptions(for: item)
                    if self.pendingAutoplay {
                        self.pendingAutoplay = false
                        self.play()
                    }
                case .failed:
                    self.errorMessage = item.error?.localizedDescription ?? "该视频无法播放"
                    self.isBuffering = false
                default:
                    break
                }
            }
            .store(in: &itemCancellables)

        item.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] empty in
                guard let self, let item, self.player.currentItem === item else { return }
                if empty, self.isPlaying { self.isBuffering = true }
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
        player.playImmediately(atRate: Float(speed))
    }

    func pause() {
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
        player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
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
