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

    static var isAvailable: Bool { executable != nil }

    private static func locate(_ name: String) -> URL? {
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
        for path in candidates where fm.isExecutableFile(atPath: path) {
            Diagnostics.record("视频组件：使用 \(path)")
            return URL(fileURLWithPath: path)
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/which") else { return nil }
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
        guard !path.isEmpty, fm.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - 视频探测与转换

struct VideoProbe {
    var isPlayable = false
    var hasVideoTrack = false
    var duration: Double = 0
    var size: CGSize = .zero
    var codec: String?
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
            let fallback = ffprobeMetadata(url: url)
            if probe.duration <= 0 { probe.duration = fallback.duration }
            if probe.size.width <= 0 { probe.size = fallback.size }
            if probe.codec == nil { probe.codec = fallback.codec }
        }
        return probe
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
            if let formats = try? await track.load(.formatDescriptions), let first = formats.first {
                probe.codec = codecDisplayName(CMFormatDescriptionGetMediaSubType(first))
            }
        }
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
                                tlsInsecure: Bool = false) -> VideoProbe {
        guard !headers.isEmpty || tlsInsecure else { return ffprobeMetadata(url: url) }
        var input: [String] = []
        if tlsInsecure { input += ["-tls_verify", "0"] }
        input += inputArguments(url: url, headers: headers)
        return ffprobeMetadata(inputArguments: input)
    }

    static func ffprobeMetadata(url: URL) -> VideoProbe {
        ffprobeMetadata(inputArguments: ["-i", url.path])
    }

    private static func ffprobeMetadata(inputArguments: [String]) -> VideoProbe {
        var probe = VideoProbe()
        guard let ffprobe = FFmpeg.probe else { return probe }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-print_format", "json",
                             "-show_format", "-show_streams"] + inputArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return probe
        }
        process.waitUntilExit()
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
        }
        return probe
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
    static func transcode(source: URL, destination: URL) async throws {
        try await transcode(inputArguments: ["-i", source.path], destination: destination)
    }

    /// 云端视频转码：ffmpeg 直接从远端读取（带认证头）。
    /// 先尝试把视频流无损封装进 MP4（仅音频转 AAC），系统仍无法播放时再全量转 H.264。
    static func transcodeRemote(source: URL, headers: [String: String],
                                trustSelfSigned: Bool = false,
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
        try await transcode(inputArguments: inputArguments, destination: destination)
    }

    private static func transcode(inputArguments: [String], destination: URL) async throws {
        guard let ffmpeg = FFmpeg.executable else { throw VideoError.transcodeUnavailable }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".transcode-\(UUID().uuidString).mp4")

        var arguments = ["-y", "-v", "error"]
        arguments += inputArguments
        arguments += ["-map", "0:v:0",
                      "-map", "0:a:0?",
                      "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                      "-pix_fmt", "yuv420p",
                      "-c:a", "aac", "-b:a", "160k",
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
