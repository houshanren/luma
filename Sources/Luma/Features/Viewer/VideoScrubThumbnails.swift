import AppKit
import AVFoundation
import CoreImage
import SwiftUI

/// 进度条悬停 / 拖动时的画面预览：用当前播放项生成该时间点附近的一帧。
///
/// 取帧密度按片长自适应——短片段 1 秒一帧，长片 10 秒一帧。
/// 和 YouTube / Plex 的 storyboard 取向一致：预览只用来认场景，
/// 不必逐秒解码；同一采样段内来回滑动直接命中缓存。
enum VideoScrubThumbnails {
    private static var generators: [ObjectIdentifier: AVAssetImageGenerator] = [:]
    private static let lock = NSLock()

    /// 预览帧缓存：按「片源 + 采样段」存储，来回滑动不再重复解码。
    private static let images = MemoryImageCache(totalCostLimit: 120 * 1024 * 1024, countLimit: 120)

    /// 一段距离一帧：片长越长，采样段越长。
    static func sampleInterval(for duration: Double) -> Double {
        if duration <= 180 { return 1 }
        if duration <= 600 { return 2 }
        if duration <= 1800 { return 5 }
        return 10
    }

    /// 把时间点对齐到所在采样段的中间：同一段内滑动不会触发新的解码。
    static func sampleSeconds(for seconds: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let interval = sampleInterval(for: duration)
        let clamped = max(0, min(duration, seconds))
        return min(duration, floor(clamped / interval) * interval + interval / 2)
    }

    static func image(player: AVPlayer, fraction: Double, duration: Double) async -> NSImage? {
        guard duration > 0 else { return nil }
        return await image(player: player,
                           seconds: duration * fraction,
                           duration: duration)
    }

    /// 同步查缓存：命中时气泡立即出图，不经过取帧任务。
    static func cachedImage(player: AVPlayer,
                            fraction: Double,
                            duration: Double) -> NSImage? {
        guard duration > 0, let asset = player.currentItem?.asset else { return nil }
        let target = sampleSeconds(for: duration * fraction, duration: duration)
        return images.object(forKey: cacheKey(asset: asset, seconds: target))
    }

    /// 取帧失败的片源：加密 HLS 等格式上 ImageGenerator 可能一直不回调，
    /// 标记后同一片源不再重试，直接交给影子播放器。
    private static var generatorUnsupported: Set<UInt> = []

    static func image(player: AVPlayer, seconds: Double, duration: Double) async -> NSImage? {
        guard seconds.isFinite, seconds >= 0, let asset = player.currentItem?.asset else { return nil }
        // 流式片源直接用影子播放器：分片常伪装成 .jpeg，ImageGenerator 取不到帧、
        // 加密 HLS 上甚至会一直挂着不回调，等它超时只会让预览迟迟不出来。
        guard !isStreaming(asset) else { return nil }
        let identity = UInt(bitPattern: ObjectIdentifier(asset))
        guard !isGeneratorUnsupported(identity) else { return nil }

        let target = sampleSeconds(for: seconds, duration: duration)
        let key = cacheKey(asset: asset, seconds: target)
        if let cached = images.object(forKey: key) { return cached }

        let generator = generator(for: asset)
        generator.maximumSize = CGSize(width: 320, height: 180)
        // HLS 的关键帧间隔较大，放宽一点容差，避免经常取不到帧。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.8, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.8, preferredTimescale: 600)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        guard let image = await generate(generator, at: time, timeout: 2) else {
            markGeneratorUnsupported(identity)
            return nil
        }
        images.setObject(image, forKey: key)
        return image
    }

    private static func isGeneratorUnsupported(_ identity: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generatorUnsupported.contains(identity)
    }

    private static func markGeneratorUnsupported(_ identity: UInt) {
        lock.lock()
        defer { lock.unlock() }
        generatorUnsupported.insert(identity)
    }

    /// 片源要不要绕过 ImageGenerator：HLS 分片常伪装成 .jpeg，加密 HLS 还会一直不回调；
    /// 电视回看 / 直播那种没有扩展名的接口地址（`live.php?id=…`）同样是流式，
    /// 交给 ImageGenerator 只会白等一次超时。普通视频文件（mp4 / mov…）照旧用它。
    private static func isStreaming(_ asset: AVAsset) -> Bool {
        guard let url = (asset as? AVURLAsset)?.url, !url.isFileURL else { return false }
        if url.absoluteString.lowercased().contains(".m3u8") { return true }
        return !progressiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// 当前播放项如果是本地转封装会话（ffmpeg 边写边播，挂在 127.0.0.1 的清单），
    /// 返回会话地址：MKV 这类容器只能从会话取帧，分片就在本机磁盘上。
    @MainActor
    static func localSessionURL(player: AVPlayer) -> URL? {
        guard let url = (player.currentItem?.asset as? AVURLAsset)?.url, !url.isFileURL,
              sessionPlaylists.contains(url.lastPathComponent),
              url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        return url
    }

    /// 本地转封装会话的入口清单：`VideoStreamSession` 只暴露这两个名字。
    private static let sessionPlaylists: Set<String> = ["live.m3u8", "master.m3u8"]

    /// 能直接按文件读的容器扩展名：只有这些才值得走 ImageGenerator。
    private static let progressiveExtensions: Set<String> = ["mp4", "mov", "m4v", "m4a", "mp3", "aac"]

    /// 限时等待 ImageGenerator：加密 HLS 上它会一直不回调，超时后取消请求并返回 nil。
    private static func generate(_ generator: AVAssetImageGenerator,
                                 at time: CMTime,
                                 timeout: TimeInterval) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let once = SingleResume(continuation)
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, _ in
                guard let cgImage else { return once.finish(nil) }
                once.finish(NSImage(cgImage: cgImage,
                                    size: NSSize(width: cgImage.width, height: cgImage.height)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                GeneratorTimeout(generator: generator, once: once).fire()
            }
        }
    }

    private static func cacheKey(asset: AVAsset, seconds: Double) -> NSString {
        let identity = UInt(bitPattern: ObjectIdentifier(asset))
        return "\(identity)-\(Int((seconds * 1000).rounded()))" as NSString
    }

    // MARK: - 网络 HLS 取帧（影子播放器）

    /// 按片源复用的影子播放器：网络 HLS 的分片常伪装成 .jpeg，
    /// `AVAssetImageGenerator` 会直接报「Operation Stopped」，只能另起一路静音播放器取帧。
    @MainActor private static var shadowPlayers: [String: ScrubShadowPlayer] = [:]
    @MainActor private static var shadowOrder: [String] = []

    /// 网络片源的悬停取帧：静音影子播放器 seek 到目标时间点，读一帧画面。
    /// 本地文件、以及能正常用 ImageGenerator 的片源走不到这里。
    @MainActor
    static func playerImage(source: URL,
                            headers: [String: String],
                            seconds: Double,
                            duration: Double) async -> NSImage? {
        guard !source.isFileURL, seconds.isFinite, seconds >= 0 else { return nil }
        let target = sampleSeconds(for: seconds, duration: duration)
        let key = "hls-\(source.absoluteString)-\(Int((target * 1000).rounded()))" as NSString
        if let cached = images.object(forKey: key) { return cached }

        let sourceKey = source.absoluteString
        let shadow: ScrubShadowPlayer
        if let existing = shadowPlayers[sourceKey] {
            shadow = existing
        } else {
            shadow = ScrubShadowPlayer(url: source, headers: headers)
            shadowPlayers[sourceKey] = shadow
            shadowOrder.append(sourceKey)
            // 只留最近两路片源，换片 / 拖动其它视频时释放上一路的解码器。
            while shadowOrder.count > 2 {
                shadowPlayers[shadowOrder.removeFirst()] = nil
            }
        }
        guard let frame = await shadow.image(at: target) else {
            Diagnostics.record("悬停取帧失败 \(source.host ?? "-")", level: .verbose)
            return nil
        }
        // 直播 / 不可跳转的地址：seek 会被夹到窗口起点，任何位置都拿到同一帧。
        // 这种「预览」只会误导，宁可不给，让气泡只显示时间。
        if !frame.seconds.isFinite
            || abs(frame.seconds - target) > max(20, sampleInterval(for: duration) * 2) {
            let actual = frame.seconds.isFinite ? String(Int(frame.seconds)) : "-"
            Diagnostics.record("悬停预览跳转失败 \(source.host ?? "-") "
                               + "target=\(Int(target)) actual=\(actual)",
                               level: .verbose)
            return nil
        }
        Diagnostics.record("悬停取帧 \(source.host ?? "-") "
                           + "\(Int(frame.image.size.width))x\(Int(frame.image.size.height))",
                           level: .verbose)
        images.setObject(frame.image, forKey: key,
                         cost: Int(frame.image.size.width * frame.image.size.height * 4))
        return frame.image
    }

    /// 从原始片源抽帧：HLS 会话只覆盖已生成区间，拖到未生成位置时用 ffmpeg 补一帧。
    static func sourceImage(source: URL,
                            headers: [String: String],
                            seconds: Double,
                            duration: Double) async -> NSImage? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let target = sampleSeconds(for: seconds, duration: duration)
        let key = "src-\(source.path)-\(Int((target * 1000).rounded()))" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .utility) {
            ffmpegFrame(source: source, headers: headers, seconds: target)
        }.value
        if let image { images.setObject(image, forKey: key) }
        return image
    }

    private static func ffmpegFrame(source: URL,
                                    headers: [String: String],
                                    seconds: Double) -> NSImage? {
        guard let ffmpeg = FFmpeg.executable else { return nil }
        var arguments = ["-v", "error"]
        if !headers.isEmpty {
            let fields = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            arguments += ["-headers", fields]
        }
        // -ss 放在 -i 之前：快速定位，只读目标附近的数据。
        arguments += ["-ss", String(format: "%.3f", seconds),
                      "-i", source.isFileURL ? source.path : source.absoluteString,
                      "-frames:v", "1",
                      "-vf", "scale=320:-2",
                      "-f", "image2pipe", "-vcodec", "png", "-"]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // SMB / 网盘定位可能要一两秒：最多等 8 秒，超时就放弃这一帧。
        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.terminationHandler = nil
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private static func generator(for asset: AVAsset) -> AVAssetImageGenerator {
        let key = ObjectIdentifier(asset)
        lock.lock()
        defer { lock.unlock() }
        if let cached = generators[key] { return cached }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generators[key] = generator
        return generator
    }
}

// MARK: - 工具栏进度条的悬停预览

/// 保证回调只恢复一次：ImageGenerator 的回调与超时计时器可能先后到达。
private final class SingleResume: @unchecked Sendable {
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<NSImage?, Never>) {
        self.continuation = continuation
    }

    func finish(_ image: NSImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: image)
    }
}

/// 超时兜底：加密 HLS 上 ImageGenerator 可能一直不回调，
/// 到点后取消这次取帧请求并交回 nil，让调用方去走影子播放器。
private final class GeneratorTimeout: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let once: SingleResume

    init(generator: AVAssetImageGenerator, once: SingleResume) {
        self.generator = generator
        self.once = once
    }

    func fire() {
        generator.cancelAllCGImageGeneration()
        once.finish(nil)
    }
}

/// 影子播放器：只用来给进度条取帧。
/// 网络 HLS 常常把分片命名成 .jpeg，`AVAssetImageGenerator` 无法解析，
/// 这里静音播放、seek 到目标时间点后从 `AVPlayerItemVideoOutput` 读一帧。
@MainActor
private final class ScrubShadowPlayer {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let item: AVPlayerItem
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    init(url: URL, headers: [String: String]) {
        // 和主播放器保持一致：这个 option 即使内容为空也要带上，
        // 少了它 AVFoundation 会把没有扩展名的地址（`live.php?id=…` 这类回看接口）
        // 当成本地文件，取帧直接失败（NSURLErrorDomain -1100）。
        let asset = AVURLAsset(url: url,
                               options: [CloudPlayback.headerFieldsKey: headers])
        item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    /// 取到的一帧：带上实际落到的播放位置。
    /// 直播 / 不可跳转的地址 seek 会被夹到窗口起点，据此判断这一帧能不能用来预览。
    struct Frame {
        let image: NSImage
        let seconds: Double
    }

    /// seek 到目标时间点后最多等 `timeout` 秒拿一帧；拿不到就放弃，不阻塞后续悬停。
    func image(at seconds: Double, timeout: TimeInterval = 5) async -> Frame? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        await player.seek(to: time,
                          toleranceBefore: .positiveInfinity,
                          toleranceAfter: .positiveInfinity)
        guard !Task.isCancelled else { return nil }
        player.play()
        defer { player.pause() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            if item.status == .failed {
                // 只记错误域与码：错误描述里可能带出带签名的分片地址。
                let error = item.error as NSError?
                Diagnostics.record("影子播放器失败 \(error?.domain ?? "-") \(error?.code ?? 0)",
                                   level: .verbose)
                return nil
            }
            let hostTime = CACurrentMediaTime()
            let itemTime = output.itemTime(forHostTime: hostTime)
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
               let image = makeImage(buffer) {
                return Frame(image: image, seconds: CMTimeGetSeconds(itemTime))
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return nil
    }

    private func makeImage(_ buffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 顶栏进度条的悬停预览状态。
/// 工具栏自己的容器装不下预览气泡，所以只在这里发状态，由播放页在画面上画；
/// 取帧按采样段缓存，来回滑动命中缓存就不必再解码。
@MainActor
final class VideoScrubPreviewCenter: ObservableObject {
    static let shared = VideoScrubPreviewCenter()

    @Published private(set) var fraction: Double?
    @Published private(set) var image: NSImage?
    @Published private(set) var duration: Double = 0
    /// 鼠标在窗口坐标里的横坐标（左下原点）：播放页据此把气泡对准光标。
    @Published private(set) var windowX: CGFloat?

    /// 由播放页注册：HLS 会话取不到帧（拖到未生成区间）时，用原始源补一帧。
    var fallbackProvider: ((Double, Double) async -> NSImage?)?

    private var task: Task<Void, Never>?

    func hover(fraction: Double, duration: Double, player: AVPlayer, window: NSWindow?) {
        self.fraction = fraction
        self.duration = duration
        if let window {
            windowX = window.convertPoint(fromScreen: NSEvent.mouseLocation).x
        }
        requestFrame(player: player)
    }

    func end() {
        fraction = nil
        image = nil
        windowX = nil
        task?.cancel()
        task = nil
    }

    private func requestFrame(player: AVPlayer) {
        task?.cancel()
        guard let requested = fraction else { return }
        let total = duration
        task = Task { @MainActor in
            // 快速划过时先不取帧：停住 55ms 再取，既不闪也不抢解码。
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard !Task.isCancelled else { return }
            if let cached = VideoScrubThumbnails.cachedImage(player: player,
                                                             fraction: requested,
                                                             duration: total) {
                if self.fraction != nil { image = cached }
                return
            }
            var frame = await VideoScrubThumbnails.image(player: player,
                                                         fraction: requested,
                                                         duration: total)
            if frame == nil, let provider = fallbackProvider {
                // 拖到未生成区间：HLS 里没有这一帧，改从原始片源抽一帧。
                frame = await provider(requested, total)
            }
            guard !Task.isCancelled, let frame else { return }
            if self.fraction != nil { image = frame }
        }
    }
}

/// 顶栏进度条的悬停预览气泡：画在工具栏之外（视频这一层），
/// 水平跟着光标、竖直贴在进度条下方，像 YouTube / Infuse 那样。
struct VideoScrubPreviewOverlay: View {
    @ObservedObject private var center = VideoScrubPreviewCenter.shared
    /// 气泡顶部在画面里的位置：全屏视频浮在工具栏下方，窗口内贴着画面上沿。
    var topInset: CGFloat = 8

    private let bubbleWidth: CGFloat = 176
    private let bubbleHeight: CGFloat = 99

    @State private var originInWindow: CGRect = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                if center.fraction != nil {
                    bubble
                        .frame(width: bubbleWidth, height: bubbleHeight, alignment: .top)
                        .position(x: bubbleX(in: proxy.size),
                                  y: topInset + bubbleHeight / 2)
                        .transition(.opacity)
                }
            }
            .background {
                WindowOriginReader { rect in
                    guard abs(rect.minX - originInWindow.minX) > 0.5
                            || abs(rect.minY - originInWindow.minY) > 0.5 else { return }
                    originInWindow = rect
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: center.fraction != nil)
    }

    @ViewBuilder
    private var bubble: some View {
        if let image = center.image {
            ZStack {
                Color.black.opacity(0.72)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
            .frame(width: bubbleWidth, height: bubbleHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.26), lineWidth: 0.8)
            }
            .overlay(alignment: .bottomTrailing) {
                timeBadge
            }
            .shadow(color: .black.opacity(0.50), radius: 16, y: 6)
        } else if let fraction = center.fraction, center.duration > 0 {
            // 还没取到帧（或该位置不可预览）：只显示时间胶囊，不画空黑框。
            Text(formatScrubTime(center.duration * fraction))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(.black.opacity(0.72)))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        }
    }

    @ViewBuilder
    private var timeBadge: some View {
        if let fraction = center.fraction, center.duration > 0 {
            Text(formatScrubTime(center.duration * fraction))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.62), in: Capsule(style: .continuous))
                .padding(6)
        }
    }

    /// 气泡中心的横坐标：优先跟光标（窗口坐标换算到画面坐标），
    /// 拿不到窗口时按进度比例在顶栏播放舱里估算。
    private func bubbleX(in size: CGSize) -> CGFloat {
        let half = bubbleWidth / 2
        let raw: CGFloat
        if let windowX = center.windowX {
            raw = windowX - originInWindow.minX
        } else if let fraction = center.fraction {
            let deckWidth: CGFloat = 560
            let trackLeft = max(0, (size.width - deckWidth) / 2) + 12
            let trackWidth = max(40, deckWidth - 24 - 28 - 6)
            raw = trackLeft + trackWidth * fraction
        } else {
            raw = size.width / 2
        }
        return min(max(half + 4, raw), max(half + 4, size.width - half - 4))
    }
}

/// 把自身在窗口坐标里的位置报出来（左下原点）：预览气泡要贴着进度条，
/// 但工具栏自己装不下它，只能换算到播放页的坐标里。
private struct WindowOriginReader: NSViewRepresentable {
    var onChange: (CGRect) -> Void

    final class Probe: NSView {
        var onChange: ((CGRect) -> Void)?

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let rect = convert(bounds, to: nil)
            // 布局过程中改状态要推到下一轮，避免 «Modifying state during view update»。
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(rect)
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onChange = onChange
    }
}

/// 进度条气泡 / 胶片条上的时间：与全项目共用 `formatDuration`（超过一小时自动补小时位）。
func formatScrubTime(_ seconds: Double) -> String { formatDuration(seconds) }
