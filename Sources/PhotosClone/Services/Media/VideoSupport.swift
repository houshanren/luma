import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - 视频格式

/// 集中维护可导入/可播放的视频扩展名。部分容器（mkv/avi/flv/wmv…）系统 UTI 未声明为 movie，
/// 只能按扩展名识别，因此这里以白名单为主、UTType 为辅。
enum VideoFormats {
    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "qt",
        "avi", "mkv", "webm", "flv", "f4v", "wmv", "asf",
        "mpg", "mpeg", "m2v", "mpe", "m1v", "vob", "ts", "m2ts", "mts", "mtts",
        "3gp", "3g2", "ogv", "rm", "rmvb", "divx", "dv", "mxf", "amv"
    ]

    static func isVideoExtension(_ ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie)
    }

    /// 打开面板允许的文件类型：系统 image/movie 加上每种视频扩展名的 UTI。
    static var importContentTypes: [UTType] {
        var types: [UTType] = [.image, .movie]
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext), !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }
}

// MARK: - ffmpeg / ffprobe

/// 系统未安装 ffmpeg 时，AVFoundation 无法解码的容器会给出明确提示；
/// 安装后即可自动转码播放，并用于生成缩略图。
enum FFmpeg {
    static let executable: URL? = locate("ffmpeg")
    static let probe: URL? = locate("ffprobe")
    /// 支持 zscale + tonemap 的 ffmpeg：优先用内置静态包（已带 libzimg），
    /// 内置包缺失或过旧时退回系统 / Homebrew ffmpeg。
    static let toneMapExecutable: URL? = locate("ffmpeg", requiredFilters: ["zscale", "tonemap"])

    static var isAvailable: Bool { executable != nil }

    /// 转码时按需选择可做色调映射的二进制。
    static func executable(preferToneMap: Bool) -> URL? {
        if preferToneMap, let toneMapExecutable { return toneMapExecutable }
        return executable
    }

    private static func locate(_ name: String,
                               requiredFilters: [String] = []) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        // 优先使用 App 内置的静态 ffmpeg（由 build.sh 打进 Contents/Resources/bin）。
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/\(name)").path {
            candidates.append(bundled)
        }
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/local/bin/\(name)"
        ]
        var searchPaths = candidates
        if let whichPath = which(name) { searchPaths.append(whichPath) }
        for path in searchPaths where fm.isExecutableFile(atPath: path) {
            if !requiredFilters.isEmpty {
                guard supportsFilters(URL(fileURLWithPath: path), requiredFilters) else { continue }
                Diagnostics.record("视频组件：HDR 色调映射使用 \(path)")
            } else {
                Diagnostics.record("视频组件：使用 \(path)")
            }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/which") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func supportsFilters(_ url: URL, _ required: [String]) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return required.allSatisfy { text.contains($0) }
    }
}

// MARK: - 视频探测与转换

/// 音轨信息：用于播放器的音轨菜单展示语言 / 声道 / 编码。
struct AudioTrackInfo: Identifiable, Equatable {
    /// 在音频流中的序号（0 起），与 ffmpeg 的 `-map 0:a:N` 对应。
    let ordinal: Int
    let codec: String
    let channels: Int
    let language: String?
    let title: String?

    var id: Int { ordinal }

    var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty, language.lowercased() != "und" {
            parts.append(language)
        }
        if channels > 0 {
            parts.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : channels == 2 ? "立体声" : "\(channels) 声道")
        }
        if !codec.isEmpty { parts.append(codec) }
        return parts.joined(separator: " · ")
    }
}

/// 一个视频章节：来自 ffprobe 的 `chapters`，用于播放器章节菜单与快捷键。
struct VideoChapter: Identifiable, Equatable {
    let start: Double
    let end: Double
    let title: String
    var id: Double { start }
}

struct VideoProbe {
    var isPlayable = false
    var hasVideoTrack = false
    var duration: Double = 0
    var size: CGSize = .zero
    var codec: String?
    /// HEVC 转封装时需要显式写 hvc1 标签，AVFoundation 不认 ffmpeg 默认的 hev1。
    var isHEVC = false
    /// HDR（PQ / HLG）：转码时按需做色调映射，避免 SDR 屏幕发灰。
    var isHDR = false
    /// 杜比视界：ffprobe 的 codec_tag_string（dvh1 / dvhe）或 DOVI side data。
    var isDolbyVision = false
    /// 展示用 HDR 标记：Dolby Vision / HDR10+ / HDR10 / HLG。
    var hdrLabel: String?
    /// 整体码率（bps），来自 format.bit_rate。
    var bitrate: Int = 0
    /// 帧率（fps），来自 avg_frame_rate / r_frame_rate 或 AVAssetTrack。
    var frameRate: Double = 0
    /// 容器名（format_name，例如 matroska,webm）。
    var containerName: String?
    /// 章节列表；没有章节时为空。
    var chapters: [VideoChapter] = []
    /// 音轨数量：HLS 转封装一次只映射一条，用来决定是否显示音轨切换。
    var audioTrackCount = 0
    /// 音轨明细（ffprobe 能拿到语言 / 声道 / 编码）。
    var audioTracks: [AudioTrackInfo] = []
}

enum VideoError: LocalizedError {
    case transcodeUnavailable
    case transcodeFailed
    /// 带 ffmpeg 输出的失败原因（401、编码不支持等）。
    case transcodeFailedMessage(String)

    var errorDescription: String? {
        switch self {
        case .transcodeUnavailable:
            return "未检测到 ffmpeg，无法转换该视频格式"
        case .transcodeFailed:
            return "视频转换失败"
        case .transcodeFailedMessage(let message):
            return "视频转换失败：\(message)"
        }
    }
}

enum VideoSupport {
    /// 用于播放前的快速探测。
    static func probe(url: URL, options: [String: Any] = [:]) async -> VideoProbe {
        var probe = await probe(asset: AVURLAsset(url: url, options: options))
        if !probe.isPlayable || probe.duration <= 0 || probe.size.width <= 0 {
            // 云端 MKV 的 ffprobe 也必须带鉴权头，否则拿不到时长 / 音轨数 / HDR 信息。
            let headers = options[CloudPlayback.headerFieldsKey] as? [String: String] ?? [:]
            // ffprobe 是阻塞子进程：外置盘 / 网盘片源动辄几秒到几十秒，
            // 一定不能跑在调用方线程（打开视频时就是主线程）上，否则整个 App 像卡死。
            let fallback = await Task.detached(priority: .userInitiated) {
                headers.isEmpty
                    ? ffprobeMetadata(url: url, timeout: 30)
                    : ffprobeMetadata(url: url, headers: headers, timeout: 30)
            }.value
            if probe.duration <= 0 { probe.duration = fallback.duration }
            if probe.size.width <= 0 { probe.size = fallback.size }
            if probe.codec == nil { probe.codec = fallback.codec }
            if !probe.isHEVC { probe.isHEVC = fallback.isHEVC }
            if !probe.isHDR { probe.isHDR = fallback.isHDR }
            if !probe.isDolbyVision { probe.isDolbyVision = fallback.isDolbyVision }
            if probe.hdrLabel == nil { probe.hdrLabel = fallback.hdrLabel }
            if probe.bitrate == 0 { probe.bitrate = fallback.bitrate }
            if probe.frameRate <= 0 { probe.frameRate = fallback.frameRate }
            if probe.containerName == nil { probe.containerName = fallback.containerName }
            if probe.chapters.isEmpty { probe.chapters = fallback.chapters }
            if probe.audioTrackCount == 0 { probe.audioTrackCount = fallback.audioTrackCount }
            if probe.audioTracks.isEmpty { probe.audioTracks = fallback.audioTracks }
        }
        return probe
    }

    /// 播放信息叠加与章节用：总是跑一次 ffprobe，拿码率 / 帧率 / HDR / 章节等完整字段。
    /// 调用方在后台任务里 await，不阻塞起播；ffprobe 失败时退回 AVFoundation 探测。
    static func technicalProbe(url: URL, options: [String: Any] = [:]) async -> VideoProbe {
        let headers = options[CloudPlayback.headerFieldsKey] as? [String: String] ?? [:]
        let probed = await Task.detached(priority: .utility) {
            headers.isEmpty
                ? ffprobeMetadata(url: url, timeout: 20)
                : ffprobeMetadata(url: url, headers: headers, timeout: 20)
        }.value
        if probed.hasVideoTrack || probed.duration > 0 {
            return probed
        }
        return await probe(asset: AVURLAsset(url: url, options: options))
    }

    /// 任意 AVAsset（例如 PhotoKit 返回的云端素材，没有本地 URL）的轨道探测。
    static func probe(asset: AVAsset) async -> VideoProbe {
        var probe = VideoProbe()

        let playable = (try? await asset.load(.isPlayable)) ?? false
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        probe.hasVideoTrack = !tracks.isEmpty
        probe.isPlayable = playable && !tracks.isEmpty

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            probe.duration = max(0, duration.seconds)
        }
        if let track = tracks.first {
            let natural = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let oriented = natural.applying(transform)
            probe.size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            probe.frameRate = Double(track.nominalFrameRate)
            if let formats = try? await track.load(.formatDescriptions), let first = formats.first {
                probe.codec = codecDisplayName(CMFormatDescriptionGetMediaSubType(first))
                probe.isHEVC = probe.codec == "HEVC"
                if let extensions = CMFormatDescriptionGetExtensions(first) as? [String: Any] {
                    let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                    let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                    // 常量在不同 SDK 上的 Swift 导入名不一致，直接比对字符串值。
                    probe.isHDR = primaries == "ITU_R_2020"
                        || transfer == "SMPTE_ST_2084"
                        || transfer == "ITU_R_2100_HLG"
                }
            }
        }
        probe.audioTrackCount = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).count
        return probe
    }

    /// 导入时同步读取尺寸/时长，AVFoundation 读不到时回退 ffprobe。
    static func quickMetadata(url: URL) -> VideoProbe {
        var probe = VideoProbe()
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .video).first {
            let natural = track.naturalSize
            let oriented = natural.applying(track.preferredTransform)
            probe.size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            probe.hasVideoTrack = true
            if let formats = track.formatDescriptions as? [CMFormatDescription], let first = formats.first {
                probe.codec = codecDisplayName(CMFormatDescriptionGetMediaSubType(first))
            }
        }
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 { probe.duration = seconds }
        probe.isPlayable = probe.hasVideoTrack

        if !probe.hasVideoTrack || probe.duration <= 0 {
            let fallback = ffprobeMetadata(url: url)
            if probe.size.width <= 0 { probe.size = fallback.size }
            if probe.duration <= 0 { probe.duration = fallback.duration }
            if probe.codec == nil { probe.codec = fallback.codec }
            probe.hasVideoTrack = probe.hasVideoTrack || fallback.hasVideoTrack
        }
        return probe
    }

    /// 远端视频探测：WebDAV 需要 Basic 认证头等，ffprobe 同样要带上。
    static func ffprobeMetadata(url: URL, headers: [String: String],
                                tlsInsecure: Bool = false,
                                timeout: TimeInterval? = nil) -> VideoProbe {
        guard !headers.isEmpty || tlsInsecure else { return ffprobeMetadata(url: url, timeout: timeout) }
        var input: [String] = []
        if tlsInsecure { input += ["-tls_verify", "0"] }
        input += inputArguments(url: url, headers: headers)
        return ffprobeMetadata(inputArguments: input, timeout: timeout)
    }

    static func ffprobeMetadata(url: URL, timeout: TimeInterval? = nil) -> VideoProbe {
        ffprobeMetadata(inputArguments: ["-i", url.path], timeout: timeout)
    }

    private static func ffprobeMetadata(inputArguments: [String],
                                        timeout: TimeInterval? = nil) -> VideoProbe {
        var probe = VideoProbe()
        guard let ffprobe = FFmpeg.probe else { return probe }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-print_format", "json",
                             "-show_format", "-show_streams", "-show_chapters"] + inputArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr 直接丢弃：用 Pipe 却不读，ffprobe 报错一多就会写满管道而永久阻塞。
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return probe
        }
        if let timeout {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.terminationHandler = nil
                Diagnostics.record("ffprobe 探测超时（\(Int(timeout)) 秒），已终止")
                return probe
            }
        } else {
            finished.wait()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return probe }

        let streams = json["streams"] as? [[String: Any]] ?? []
        guard let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            return probe
        }
        probe.hasVideoTrack = true
        probe.isPlayable = true

        var width = video["width"] as? Int ?? 0
        var height = video["height"] as? Int ?? 0
        var rotation = 0
        if let sideData = video["side_data_list"] as? [[String: Any]],
           let value = sideData.compactMap({ $0["rotation"] as? Double }).first {
            rotation = Int(value)
        } else if let tags = video["tags"] as? [String: Any], let value = tags["rotate"] as? String {
            rotation = Int(value) ?? 0
        }
        rotation = ((rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            swap(&width, &height)
        }
        probe.size = CGSize(width: width, height: height)

        let format = json["format"] as? [String: Any]
        let durationText = (format?["duration"] as? String) ?? (video["duration"] as? String)
        if let text = durationText, let seconds = Double(text) {
            probe.duration = max(0, seconds)
        }
        if let codec = video["codec_name"] as? String {
            probe.codec = prettyCodec(codec)
            probe.isHEVC = codec.lowercased() == "hevc"
        }
        // HDR 判定：PQ（smpte2084）/ HLG（arib-std-b67）或 BT.2020 色域。
        let primaries = (video["color_primaries"] as? String)?.lowercased()
        let transfer = (video["color_transfer"] as? String)?.lowercased()
        probe.isHDR = primaries == "bt2020"
            || transfer == "smpte2084"
            || transfer == "arib-std-b67"

        // 杜比视界：codec_tag_string（dvh1 / dvhe）或 DOVI side data。
        let sideData = video["side_data_list"] as? [[String: Any]] ?? []
        let sideTypes = sideData.compactMap { $0["side_data_type"] as? String }
            .joined(separator: " ").lowercased()
        let codecTag = (video["codec_tag_string"] as? String)?.lowercased() ?? ""
        probe.isDolbyVision = codecTag.hasPrefix("dvh") || codecTag == "dovi"
            || sideTypes.contains("dovi") || sideTypes.contains("dolby vision")
            || sideData.contains(where: { $0["dv_profile"] != nil })
        if probe.isDolbyVision {
            probe.hdrLabel = "Dolby Vision"
        } else if sideTypes.contains("smpte2094-40") || sideTypes.contains("hdr10+") {
            probe.hdrLabel = "HDR10+"
        } else if transfer == "smpte2084" {
            probe.hdrLabel = "HDR10"
        } else if transfer == "arib-std-b67" {
            probe.hdrLabel = "HLG"
        } else if primaries == "bt2020" {
            probe.hdrLabel = "HDR"
        }

        let averageRate = parseFrameRate(video["avg_frame_rate"])
        probe.frameRate = averageRate > 0 ? averageRate : parseFrameRate(video["r_frame_rate"])
        if probe.bitrate == 0,
           let text = format?["bit_rate"] as? String,
           let value = Int(text) {
            probe.bitrate = value
        }
        probe.containerName = format?["format_name"] as? String
        probe.chapters = (json["chapters"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
            guard let start = Double((item["start_time"] as? String) ?? "") else { return nil }
            let end = Double((item["end_time"] as? String) ?? "") ?? start
            let title = ((item["tags"] as? [String: Any])?["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return VideoChapter(start: start,
                                end: end,
                                title: (title?.isEmpty == false ? title! : "章节 \(index + 1)"))
        }
        let audioStreams = streams.filter { ($0["codec_type"] as? String) == "audio" }
        probe.audioTracks = audioStreams.enumerated().map { offset, stream in
            let tags = stream["tags"] as? [String: Any]
            return AudioTrackInfo(
                ordinal: offset,
                codec: (stream["codec_name"] as? String).map(prettyCodec) ?? "",
                channels: stream["channels"] as? Int ?? 0,
                language: tags?["language"] as? String,
                title: tags?["title"] as? String)
        }
        probe.audioTrackCount = probe.audioTracks.count
        return probe
    }

    /// ffprobe 的帧率是 `30000/1001` 这样的分数，也兼容直接的浮点数。
    private static func parseFrameRate(_ raw: Any?) -> Double {
        guard let text = raw as? String, !text.isEmpty else { return 0 }
        let parts = text.split(separator: "/")
        if parts.count == 2,
           let numerator = Double(parts[0]),
           let denominator = Double(parts[1]),
           denominator > 0 {
            return numerator / denominator
        }
        return Double(text) ?? 0
    }

    /// 生成视频缩略图：先走 AVFoundation，失败则用 ffmpeg 抽帧。
    @discardableResult
    static func makeThumbnail(url: URL, destination: URL) -> Bool {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        for seconds in [0.2, 0.0, 1.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                ImportService.writeJPEG(image, to: destination, quality: 0.9)
                return true
            }
        }

        guard let ffmpeg = FFmpeg.executable else { return false }
        // ffmpeg 同样先写临时文件，成功后再替换：读取方（网格 / 内容识别）不会读到半张图。
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString).jpg")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-y", "-v", "error", "-ss", "0.3", "-i", url.path,
                             "-frames:v", "1", "-vf", "scale='min(1200,iw)':-2", temp.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        ThumbnailFileIndex.shared.recordWrite(url: destination)
        return true
    }

    /// 远端抽帧：MKV 等容器系统无法解码，由 ffmpeg 直接读取远端地址（带认证头）。
    @discardableResult
    static func makeRemoteThumbnail(url: URL, headers: [String: String],
                                    trustSelfSigned: Bool = false, destination: URL) -> Bool {
        guard let ffmpeg = FFmpeg.executable else { return false }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString).jpg")
        var arguments = ["-y", "-v", "error"]
        if !headers.isEmpty {
            arguments += ["-headers", headerBlock(headers)]
        }
        // NAS 的自签名证书：只有挂载点明确信任时才跳过校验。
        if trustSelfSigned {
            arguments += ["-tls_verify", "0"]
        }
        arguments += ["-ss", "1"]
        arguments += inputArguments(url: url, headers: [:])
        arguments += ["-frames:v", "1", "-vf", "scale='min(1200,iw)':-2", temp.path]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        return true
    }

    /// 用 ffmpeg 转成 H.264 + AAC 的 MP4，供系统不支持解码的容器播放。
    /// HDR 源按需做色调映射，避免 SDR 屏幕发灰 / 过曝。
    static func transcode(source: URL, destination: URL, toneMapHDR: Bool = false) async throws {
        try await transcode(inputArguments: ["-i", source.path],
                            destination: destination,
                            toneMapHDR: toneMapHDR)
    }

    /// HDR → SDR 色调映射的滤镜链（不含 `-vf`，方便和字幕烧录合并成同一条）。
    static let hdrToneMapChain = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
        + "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    /// HDR → SDR 色调映射参数；内置 ffmpeg 不带 zscale 时返回空，退化为普通转码。
    static func hdrToneMapArguments(toneMapHDR: Bool) -> [String] {
        guard toneMapHDR, supportsToneMapping else { return [] }
        return ["-vf", hdrToneMapChain,
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
    }

    /// ffmpeg 的 subtitles 烧录滤镜；路径里的反斜杠、冒号与单引号必须转义。
    /// 文本字幕（srt / ass / vtt / ssa）由 libass 渲染；PGS / SUP 取决于内置 ffmpeg 的解码能力。
    static func subtitleBurnFilter(_ url: URL) -> String {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
        return "subtitles=filename='\(escaped)'"
    }

    /// 是否有可用的 zscale + tonemap（内置静态包已带 libzimg，缺失时回退系统 ffmpeg）。
    static var supportsToneMapping: Bool { FFmpeg.toneMapExecutable != nil }

    /// 云端视频转码：ffmpeg 直接从远端读取（带认证头）。
    /// 先尝试把视频流无损封装进 MP4（仅音频转 AAC），系统仍无法播放时再全量转 H.264。
    static func transcodeRemote(source: URL, headers: [String: String],
                                trustSelfSigned: Bool = false,
                                toneMapHDR: Bool = false,
                                destination: URL) async throws {
        guard let ffmpeg = FFmpeg.executable else { throw VideoError.transcodeUnavailable }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        var tlsArguments: [String] = []
        if trustSelfSigned { tlsArguments = ["-tls_verify", "0"] }
        var inputArguments = tlsArguments
        inputArguments += self.inputArguments(url: source, headers: headers)

        let metadata = ffprobeMetadata(url: source, headers: headers, tlsInsecure: trustSelfSigned)
        let remuxed = destination.deletingLastPathComponent()
            .appendingPathComponent(".remux-\(UUID().uuidString).mp4")
        var arguments = ["-y", "-v", "error"]
        arguments += inputArguments
        arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"]
        // AVFoundation 只认 hvc1 标签，ffmpeg 默认写 hev1。
        if metadata.codec == "HEVC" { arguments += ["-tag:v", "hvc1"] }
        arguments += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", remuxed.path]

        _ = try? await run(ffmpeg, arguments)
        if FileManager.default.fileExists(atPath: remuxed.path) {
            let check = await probe(asset: AVURLAsset(url: remuxed))
            if check.hasVideoTrack, check.isPlayable {
                try moveIntoPlace(remuxed, destination: destination)
                return
            }
            try? FileManager.default.removeItem(at: remuxed)
        }
        // HDR 源不能走无损封装时，必须做色调映射后再编码。
        try await transcode(inputArguments: inputArguments,
                            destination: destination,
                            toneMapHDR: toneMapHDR || metadata.isHDR)
    }

    private static func transcode(inputArguments: [String], destination: URL,
                                  toneMapHDR: Bool) async throws {
        let toneMap = hdrToneMapArguments(toneMapHDR: toneMapHDR)
        guard let ffmpeg = FFmpeg.executable(preferToneMap: !toneMap.isEmpty) else {
            throw VideoError.transcodeUnavailable
        }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".transcode-\(UUID().uuidString).mp4")

        var arguments = ["-y", "-v", "error"]
        arguments += inputArguments
        arguments += ["-map", "0:v:0",
                      "-map", "0:a:0?",
                      "-c:v", "libx264", "-preset", "medium", "-crf", "20"]
        if toneMap.isEmpty {
            arguments += ["-pix_fmt", "yuv420p"]
        } else {
            arguments += toneMap
        }
        arguments += ["-c:a", "aac", "-b:a", "160k",
                      "-movflags", "+faststart",
                      partial.path]
        let status = try await run(ffmpeg, arguments)

        guard status == 0, FileManager.default.fileExists(atPath: partial.path) else {
            try? FileManager.default.removeItem(at: partial)
            throw VideoError.transcodeFailed
        }
        try moveIntoPlace(partial, destination: destination)
    }

    /// ffmpeg 的 `-headers`：每个请求头一行，以 CRLF 结尾。
    private static func headerBlock(_ headers: [String: String]) -> String {
        headers.map { "\($0.key): \($0.value)\r\n" }.joined()
    }

    private static func inputArguments(url: URL, headers: [String: String]) -> [String] {
        var arguments: [String] = []
        if !headers.isEmpty {
            arguments += ["-headers", headerBlock(headers)]
        }
        arguments += ["-i", url.absoluteString]
        return arguments
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func moveIntoPlace(_ partial: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try? FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    static func codecDisplayName(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let raw = String(bytes: bytes, encoding: .ascii) ?? ""
        return prettyCodec(raw)
    }

    private static func prettyCodec(_ raw: String) -> String {
        switch raw.lowercased() {
        case "avc1", "h264", "x264": return "H.264"
        case "hvc1", "hev1", "hevc", "h265": return "HEVC"
        case "vp09", "vp9": return "VP9"
        case "vp08", "vp8": return "VP8"
        case "av01", "av1": return "AV1"
        case "mp4v", "mpeg4": return "MPEG-4"
        case "ap4h", "apch", "apcn", "apcs", "apco", "ap4x": return "ProRes"
        case "mjpg", "mjpeg": return "Motion JPEG"
        case "mpeg2video", "m2v1": return "MPEG-2"
        case "theora": return "Theora"
        case "rv40", "rv30": return "RealVideo"
        case "wmv3", "wmv2", "wmv1": return "WMV"
        case "flv1": return "Sorenson H.263"
        default: return raw.isEmpty ? "未知编码" : raw.uppercased()
        }
    }
}
