import Foundation

/// 边下载边转封装：ffmpeg 把远端（或本地）MKV 封成 fMP4 分片 HLS，
/// 由本机回环 HTTP 服务交给 AVPlayer。首段生成即可开播，不必等整部文件下载完。
/// 已完整转换过的结果留在图库 transcodes 目录，下次打开同一视频直接复用。
///
/// 网盘直链不走 ffmpeg 自带的 HTTP 客户端：先由 `RemoteRangeSource` 代理成本机可 Range 读取的地址，
/// 再交给 ffmpeg。这样既能复用 App 已验证过的请求头 / 302 / 证书策略，又允许按位置读取而不是只能从头顺序灌。
final class VideoStreamSession {
    enum Mode: Equatable {
        /// 只转封装（-c:v copy）：最快，H.264 / HEVC 等 AVPlayer 能解的编码走这条。
        case remux
        /// 转封装失败时降级为重编码 H.264，兼容 RealVideo / Theora 等编码。
        case transcode
    }

    /// 完整转换结果的缓存目录（只有带 EXT-X-ENDLIST 的播放列表才会放进来）。
    private let cacheDirectory: URL
    /// 本次播放独占的工作目录：避免同一视频的两个会话互删中间文件。
    private let workDirectory: URL
    private let source: URL
    private let headers: [String: String]
    /// 挂载点勾选了「信任自签名证书」：URLSession 需要放行 NAS 的自签名证书。
    private let trustSelfSigned: Bool
    private let mode: Mode
    /// 从第几秒开始读取：用户拖到未生成区间时，用 -ss 重新起一个会话。
    private let startOffset: Double
    /// 实际起流位置（对齐到关键帧）：播放器时间轴从它开始，再由 startAt 前跳到目标位置。
    private(set) var playbackStartOffset: Double = 0
    private let isHEVC: Bool
    private let isHDR: Bool
    /// 只映射这一条音轨；切换音轨时调用方会重新建会话。
    private let audioIndex: Int
    /// 音轨声道数：>2 时给 AAC 更高码率，避免把 5.1 压得太狠。
    private let audioChannels: Int
    /// 需要烧录的外挂字幕；有值时强制走重编码，并把字幕叠进画面。
    private let burnSubtitle: URL?
    /// 云盘直链过期时重新解析（由播放页提供）。
    private let refreshSource: (() -> (URL, [String: String])?)?

    private var process: Process?
    private var server: LocalHLSServer?
    private var rangeSource: RemoteRangeSource?
    private var logURL: URL?
    private let stateLock = NSLock()
    private var sourceFailure: String?
    /// 主动关闭会话时置位：ffmpeg 因收到 SIGTERM 退出属于预期行为，不再记录为转换失败。
    private var stopping = false
    /// ffmpeg 是否被暂停生成（播放器暂停时挂起进程，避免后台把整片转完）。
    private var generationPaused = false
    /// 提前生成太多时临时挂起 ffmpeg：长片不会在几分钟内写满磁盘 / 跑满网盘。
    private var leadPaused = false
    /// 进程当前是否真的处于 SIGSTOP（上面两个意图合并后的实际状态）。
    private var processStopped = false
    /// 当前保留的最小分片序号（播放中滚动清理）。
    private var minSegmentIndex = 0
    /// 最小保留分片对应的时间偏移（相对会话起点）。
    private var retainedOffset: Double = 0
    /// 实际提供给播放器的目录：命中缓存时是缓存目录，否则是工作目录。
    private var servingDirectory: URL
    private var usesCache = false

    init(photoID: UUID, source: URL, headers: [String: String], trustSelfSigned: Bool = false,
         mode: Mode = .remux, startOffset: Double = 0, isHEVC: Bool = false,
         isHDR: Bool = false, audioIndex: Int = 0, audioChannels: Int = 2,
         burnSubtitle: URL? = nil,
         refreshSource: (() -> (URL, [String: String])?)? = nil) {
        let base = LibraryPaths.transcodes
        // 烧录字幕会改变画面，必须和普通缓存分开，否则会命中没有字幕的旧结果。
        let burnSuffix = burnSubtitle.map { "-burn-\(abs($0.path.hashValue))" } ?? ""
        self.cacheDirectory = base.appendingPathComponent(photoID.uuidString + burnSuffix + ".hls",
                                                          isDirectory: true)
        // 工作目录带 `-session-`：启动时据此清理异常退出留下的中间产物。
        self.workDirectory = base.appendingPathComponent(
            photoID.uuidString + burnSuffix + "-session-" + UUID().uuidString + ".hls",
            isDirectory: true)
        self.servingDirectory = workDirectory
        self.source = source
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
        self.mode = mode
        self.startOffset = max(0, startOffset)
        self.playbackStartOffset = max(0, startOffset)
        self.isHEVC = isHEVC
        self.isHDR = isHDR
        self.audioIndex = max(0, audioIndex)
        self.audioChannels = max(1, audioChannels)
        self.burnSubtitle = burnSubtitle
        self.refreshSource = refreshSource
    }

    private var playlistPath: URL {
        // 单参数 appendingPathComponent 会 lstat，这个路径在等首段时每 100ms 读一次。
        servingDirectory.appendingPathComponent("live.m3u8", isDirectory: false)
    }

    /// 本地 / SMB 源不落长期缓存：源就在本地，重转很快，缓存只会白占磁盘。
    private var persistCache: Bool { !source.isFileURL }

    /// 只有「云端、完整、从 0 开始、默认音轨、无损转封装」的结果才值得长期缓存。
    private var canReuseCache: Bool {
        burnSubtitle == nil && persistCache && mode == .remux && startOffset < 0.5 && audioIndex == 0
    }

    /// 已删除分片之前的起点（秒）：跳转到这之前需要重新起流。
    var retainedStartSeconds: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return playbackStartOffset + retainedOffset
    }

    /// 播放中删除窗口外的旧分片，避免长片把磁盘写满。
    /// 只保留当前播放位置之前约 2 分钟的片段，回看更早的位置由调用方重建流。
    func trim(before seconds: Double) {
        guard !usesCache else { return }
        updateGenerationPacing(playback: seconds)
        let keepBehind: Double = 120
        let cutoff = Int(((seconds - playbackStartOffset - keepBehind) / 2).rounded(.down))
        guard cutoff > 0 else { return }
        stateLock.lock()
        guard cutoff > minSegmentIndex else {
            stateLock.unlock()
            return
        }
        minSegmentIndex = cutoff
        stateLock.unlock()

        // 分片长度并不严格等于 hls_time（会在关键帧处切分）：从播放列表读出精确起点。
        if let start = Self.segmentStartTime(playlistPath, index: cutoff) {
            stateLock.lock()
            retainedOffset = start
            stateLock.unlock()
        }

        // 删除动作放到后台：一次可能清掉上百个分片，不能卡主线程。
        let directory = workDirectory
        DispatchQueue.global(qos: .utility).async {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return }
            for url in items {
                let name = url.lastPathComponent
                guard name.hasPrefix("seg"), name.hasSuffix(".m4s"),
                      let index = Int(name.dropFirst(3).dropLast(4)),
                      index < cutoff else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// 是否在播放已经完整生成过的 HLS 缓存（整部片都可直接 seek）。
    var isCompleteCache: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return usesCache
    }

    private func currentMinSegmentIndex() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return minSegmentIndex
    }

    /// 播放器暂停时挂起 ffmpeg，继续播放时恢复：避免暂停期间把整部片转成缓存。
    func setGenerationActive(_ active: Bool) {
        guard !usesCache, let process, process.isRunning else { return }
        stateLock.lock()
        generationPaused = !active
        stateLock.unlock()
        applyGenerationState()
    }

    /// 提前生成窗口：领先播放超过 4 分钟就挂起，回落到 90 秒内再恢复。
    /// 60 GB 的长片即使按 12× 生成，也不会在几分钟内写满磁盘；云端也少跑无用的下载。
    private func updateGenerationPacing(playback seconds: Double) {
        guard let process, process.isRunning else { return }
        let directory = workDirectory
        let offset = playbackStartOffset
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let produced = Self.playlistDuration(
                directory.appendingPathComponent("live.m3u8", isDirectory: false)) else { return }
            let ahead = produced + offset - seconds

            self.stateLock.lock()
            var changed: Bool?
            if ahead > 240, !self.leadPaused {
                self.leadPaused = true
                changed = true
            } else if ahead < 90, self.leadPaused {
                self.leadPaused = false
                changed = false
            }
            self.stateLock.unlock()
            guard changed != nil else { return }
            self.applyGenerationState()
        }
    }

    /// 把「用户暂停」与「提前量过大」两个意图合并成一次 SIGSTOP / SIGCONT。
    private func applyGenerationState() {
        guard !usesCache, let process, process.isRunning else { return }
        stateLock.lock()
        let shouldStop = generationPaused || leadPaused
        guard processStopped != shouldStop else {
            stateLock.unlock()
            return
        }
        processStopped = shouldStop
        stateLock.unlock()
        kill(process.processIdentifier, shouldStop ? SIGSTOP : SIGCONT)
    }

    /// 读播放列表里所有分片的时长总和：比按分片数估算准确，关键帧切分也不会偏。
    private static func playlistDuration(_ url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var total = 0.0
        var found = false
        for line in text.split(separator: "\n") where line.hasPrefix("#EXTINF:") {
            let value = line.dropFirst("#EXTINF:".count)
                .split(separator: ",", maxSplits: 1).first ?? ""
            if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) {
                total += seconds
                found = true
            }
        }
        return found ? total : nil
    }

    /// 失败是否来自网盘（鉴权 / 网络 / 非视频数据）：这类失败重编码也没用。
    var failureIsSource: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sourceFailure != nil
    }

    /// 启动本地服务并返回可播放的 m3u8 地址；首次播放会等第一段分片就绪。
    func start() async throws -> URL {
        if canReuseCache, Self.isComplete(cacheDirectory) {
            usesCache = true
            servingDirectory = cacheDirectory
            // 按「最后一次播放」做 LRU，常用片不会被新片挤掉。
            VideoCacheManager.touch(cacheDirectory)
        } else {
            // 只有完整回放才复用/清理长期缓存；跳转或换音轨的临时会话不能动它。
            // 旧版本还给本地文件存过整部 HLS，这里一并清掉。
            if canReuseCache || !persistCache {
                let stale = cacheDirectory
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager.default.removeItem(at: stale)
                }
            }
            try? FileManager.default.removeItem(at: workDirectory)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        }

        let server = LocalHLSServer(directory: servingDirectory)
        server.minSegmentIndexProvider = { [weak self] in
            guard let self else { return 0 }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            return self.minSegmentIndex
        }
        let port = try server.start()
        self.server = server
        if !usesCache {
            try launch()
            try await waitForPlaylist()
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/live.m3u8") else {
            stop()
            throw VideoError.transcodeUnavailable
        }
        return url
    }

    func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
        if !usesCache, process != nil, !FileManager.default.fileExists(atPath: playlistPath.path) {
            Diagnostics.record("边下边播会话提前结束（首段未生成）")
        }
        rangeSource?.stop()
        rangeSource = nil
        if let process {
            stateLock.lock()
            let paused = processStopped
            stateLock.unlock()
            // 被 SIGSTOP 挂起的进程要先恢复，否则 SIGTERM 不会立即生效。
            if paused { kill(process.processIdentifier, SIGCONT) }
            process.terminate()
        }
        process = nil
        server?.stop()
        server = nil
        if let logURL {
            try? FileManager.default.removeItem(at: logURL)
            self.logURL = nil
        }
        guard !usesCache else { return }
        // 播放中删过旧分片的结果不完整，不能作为下次直接回放的缓存。
        if canReuseCache, currentMinSegmentIndex() == 0, Self.isComplete(workDirectory) {
            // 云端完整结果挪到缓存位置，下次直接回放；本地源不落缓存。
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.moveItem(at: workDirectory, to: cacheDirectory)
            VideoCacheManager.trimIfNeeded()
        } else {
            // 没转完的中间产物留着也没法播；可能有好几 GB，放后台删。
            let stale = workDirectory
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    // MARK: - 内部

    private static func isComplete(_ directory: URL) -> Bool {
        let playlist = directory.appendingPathComponent("live.m3u8", isDirectory: false)
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return false }
        return text.contains("#EXT-X-ENDLIST")
    }

    private func launch() throws {
        let needsToneMap = mode == .transcode && isHDR && VideoSupport.supportsToneMapping
        guard let ffmpeg = FFmpeg.executable(preferToneMap: needsToneMap) else {
            throw VideoError.transcodeUnavailable
        }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let isRemote = !source.isFileURL
        var inputTarget: String
        if isRemote {
            let proxy = RemoteRangeSource(upstream: source,
                                          headers: headers,
                                          trustSelfSigned: trustSelfSigned,
                                          cacheDirectory: workDirectory.appendingPathComponent("range-cache",
                                                                                              isDirectory: true))
            proxy.onFailure = { [weak self] message in
                self?.recordSourceFailure(message)
            }
            proxy.onAuthFailure = refreshSource
            let inputURL = try proxy.start()
            rangeSource = proxy
            inputTarget = inputURL.absoluteString
        } else {
            inputTarget = source.path
        }

        // 转封装只能从关键帧起流。先对齐到目标位置之前的关键帧，让音视频从同一点开始，
        // 再由播放器前跳到目标秒数；否则音频被精确裁到目标点、视频还在关键帧，嘴型必然对不上。
        let alignedStart = startOffset > 0.5
            ? Self.alignedKeyframe(before: startOffset, input: inputTarget)
            : 0
        playbackStartOffset = alignedStart
        if startOffset > 0.5, abs(alignedStart - startOffset) > 0.2 {
            Diagnostics.record("起流对齐关键帧 \(Int(startOffset))s → \(Int(alignedStart))s")
        }

        var arguments = ["-y", "-v", "error"]
        // 只看开头 2 MB 就足够判断流信息，缩短首段等待（原来 4 MB 在网盘上要多读几秒）。
        arguments += ["-probesize", "2M", "-analyzeduration", "2M"]
        // 本地文件读盘快：给 12× 生成，起播与拖动后的首段更早就绪；
        // 云端保守一些，避免短时间把大文件整段拉下来。提前量由 updateGenerationPacing 控制。
        arguments += ["-readrate", isRemote ? "6" : "12"]
        if alignedStart > 0 {
            // 放在 -i 之前：输入侧快速定位；已对齐到关键帧，音视频从同一时间点开始。
            arguments += ["-ss", String(format: "%.3f", alignedStart)]
        }
        arguments += ["-i", inputTarget]
        if alignedStart > 0 {
            // 两路都从 0 起步，避免关键帧前的负时间戳把后续音轨整体推迟。
            arguments += ["-copyts", "-start_at_zero", "-avoid_negative_ts", "make_zero"]
        }
        arguments += ["-map", "0:v:0"]
        // 烧录字幕必须重编码，不能走 -c:v copy。
        switch burnSubtitle == nil ? mode : .transcode {
        case .remux:
            arguments += ["-c:v", "copy"]
            // AVFoundation 只认 hvc1 标签，ffmpeg 默认写 hev1。
            if isHEVC { arguments += ["-tag:v", "hvc1"] }
            // 不强制 -ac 2：保留源的多声道（AAC 5.1 由 AVPlayer 正常输出）。
            // async 1 让音频按时间戳补齐 / 裁掉，跳转后不会与画面越走越偏。
            arguments += ["-async", "1", "-c:a", "aac", "-b:a", audioChannels > 2 ? "384k" : "256k"]
        case .transcode:
            // veryfast：转码档本来就是兼容兜底，先把首段等出来，画质差一点可接受。
            arguments += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
            var filters: [String] = []
            if let burnSubtitle {
                filters.append(VideoSupport.subtitleBurnFilter(burnSubtitle))
            }
            let toneMap = isHDR && VideoSupport.supportsToneMapping
            if toneMap {
                filters.append(VideoSupport.hdrToneMapChain)
            }
            if filters.isEmpty {
                arguments += ["-pix_fmt", "yuv420p"]
            } else {
                arguments += ["-vf", filters.joined(separator: ",")]
            }
            if toneMap {
                arguments += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
            }
            arguments += ["-async", "1", "-c:a", "aac", "-b:a", audioChannels > 2 ? "384k" : "256k"]
        }
        arguments += ["-map", "0:a:\(audioIndex)?"]
        // 4K 高码率重新封装时包队列容易溢出（Too many packets buffered），放宽到 2048。
        arguments += ["-max_muxing_queue_size", "2048"]
        arguments += ["-f", "hls",
                      "-hls_time", "2",
                      "-hls_init_time", "0.5",
                      "-hls_list_size", "0",
                      "-hls_playlist_type", "event",
                      // 分片先写临时文件再改名：AVPlayer 不会读到写了一半的片段。
                      "-hls_flags", "temp_file",
                      "-hls_segment_type", "fmp4",
                      "-hls_fmp4_init_filename", "init.mp4",
                      "-hls_segment_filename", workDirectory.appendingPathComponent("seg%05d.m4s", isDirectory: false).path,
                      workDirectory.appendingPathComponent("live.m3u8", isDirectory: false).path]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardOutput = Pipe()
        // stderr 落到临时文件：失败时把最后几行写进诊断日志，便于定位 401 / 编码不支持。
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-ffmpeg-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardError = logHandle ?? Pipe()
        self.logURL = logURL

        process.terminationHandler = { [weak self] finished in
            try? logHandle?.close()
            guard let self else { return }
            self.stateLock.lock()
            let intentional = self.stopping
            self.stateLock.unlock()
            guard !intentional,
                  finished.terminationReason == .exit,
                  finished.terminationStatus != 0 else { return }
            let tail = Self.tail(of: logURL)
            Diagnostics.record("边下边播转换异常结束 status=\(finished.terminationStatus)：\(tail)")
            self.recordSourceFailure(tail)
        }
        try process.run()
        self.process = process
    }

    /// 找目标位置之前最近的关键帧。最多往回看 15 秒，常规 GOP 足够覆盖；
    /// 探测失败或超时都退回目标位置，保持原来的行为。
    private static func alignedKeyframe(before target: Double, input: String) -> Double {
        guard let ffprobe = FFmpeg.probe else { return target }
        let windowStart = max(0, target - 15)
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_packets",
            "-show_entries", "packet=pts_time,flags",
            "-read_intervals", String(format: "%.3f%%%.3f", windowStart, target),
            "-of", "csv=p=0",
            input
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return target }

        // 网盘读区间偶尔很慢：最多等 4 秒，超时直接按目标位置起流。
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return target
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        var keyframes: [Double] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ",")
            guard parts.count >= 2, parts[1].contains("K"),
                  let value = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  value >= 0, value <= target + 0.05 else { continue }
            keyframes.append(value)
        }
        guard let keyframe = keyframes.max(), target - keyframe < 15.05 else { return target }
        return keyframe
    }

    private func recordSourceFailure(_ message: String) {
        stateLock.lock()
        if sourceFailure == nil { sourceFailure = message }
        stateLock.unlock()
        Diagnostics.record("边下边播失败：\(message)")
    }

    private var currentSourceFailure: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sourceFailure
    }

    /// 等 ffmpeg 写出第一版播放列表（第一段分片完成后才会写）。
    /// 网盘限速时 4K 视频的首段可能要几十秒，这里每 5 秒记一次已写入字节，便于排查卡在下载还是卡在封装。
    private func waitForPlaylist() async throws {
        for index in 0..<1200 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: playlistPath.path) { return }
            if let process, !process.isRunning {
                let reason = currentSourceFailure ?? Self.tail(of: logURL)
                throw VideoError.transcodeFailedMessage(reason)
            }
            if index % 50 == 0 {
                let size = Self.directorySize(workDirectory)
                Diagnostics.record("边下边播等待首段：已写入 \(size / 1024) KB")
            }
            // 取消时直接抛出，避免 try? 吞掉 CancellationError 后空转。
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let size = Self.directorySize(workDirectory)
        let extra = currentSourceFailure.map { "：\($0)" } ?? ""
        throw VideoError.transcodeFailedMessage("等待首段超时，已写入 \(size / 1024 / 1024) MB\(extra)")
    }

    /// 读取播放列表，算出第 index 个分片在会话内的起始秒数。
    private static func segmentStartTime(_ playlist: URL, index: Int) -> Double? {
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return nil }
        var elapsed: Double = 0
        var pendingDuration: Double?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXTINF:") {
                let value = trimmed
                    .dropFirst("#EXTINF:".count)
                    .split(separator: ",")
                    .first
                    .flatMap { Double($0) }
                pendingDuration = value
                continue
            }
            guard trimmed.hasPrefix("seg"), trimmed.hasSuffix(".m4s"),
                  let value = Int(trimmed.dropFirst(3).dropLast(4)) else { continue }
            if value == index { return elapsed }
            elapsed += pendingDuration ?? 2
            pendingDuration = nil
        }
        return nil
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return items.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    private static func tail(of url: URL?) -> String {
        guard let url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "无输出" }
        let lines = text.split(separator: "\n").suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.isEmpty ? "无输出" : lines.joined(separator: " | ")
    }
}
