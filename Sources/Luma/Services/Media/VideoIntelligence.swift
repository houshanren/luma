import Foundation
import AppKit
import AVFoundation
import ImageIO

/// 视频端侧理解：抽帧 → 复用照片的整条分析管线 → 聚合标签 / 文字 / 向量。
///
/// 为什么不是「抽一张首帧」：
/// - 首帧经常是黑场、片头、菜单，标签质量最差；
/// - 生活视频的信息分布在多个时间点（人物、场景、食物、地点会变化）；
/// - 6 帧足以覆盖大多数 10 秒–10 分钟的视频，成本约 1 秒/条，远低于逐帧。
///
/// 采样策略：
/// - AVFoundation 按 5%–95% 均匀取 4–6 帧，带 0.25s 容差，优先近似关键帧；
/// - AVFoundation 解不了（MKV / 特殊编码）时退回 ffmpeg，按同一组时间点取帧；
/// - 每帧跑 SigLIP2 + YOLO + Vision，最后按出现频次聚合标签、合并 OCR、平均向量。
enum VideoIntelligence {
    /// 单条视频最多分析多少帧：短视频 4 帧，长视频 6 帧。
    static func frameCount(for duration: Double) -> Int {
        switch duration {
        case ..<30: return 4
        case ..<300: return 5
        default: return 6
        }
    }

    static func analyze(_ photo: PhotoItem) async -> PhotoIntelligence.Result? {
        let url = LibraryPaths.originalURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let duration = await videoDuration(url: url) ?? photo.duration ?? 0
        guard duration > 0 else { return nil }
        let frames = await sampleFrames(url: url, duration: duration)
        guard !frames.isEmpty else { return nil }

        var results: [PhotoIntelligence.Result] = []
        for frame in frames {
            if let result = PhotoIntelligence.analyze(cgImage: frame) {
                results.append(result)
            }
        }
        guard !results.isEmpty else { return nil }
        return aggregate(results, frameCount: frames.count)
    }

    // MARK: - 聚合

    private static func aggregate(_ results: [PhotoIntelligence.Result],
                                  frameCount: Int) -> PhotoIntelligence.Result {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var usedSigLIP = false
        for result in results {
            let pieces = result.labels.split(separator: " ").map(String.init)
            if pieces.contains(PhotoTagCatalog.sentinel) { usedSigLIP = true }
            for piece in pieces where !piece.isEmpty && piece != PhotoTagCatalog.sentinel {
                if counts[piece] == nil { order.append(piece) }
                counts[piece, default: 0] += 1
            }
        }

        // 出现至少 1/3 帧的标签才算稳定；不足时按频次取前几个，避免短视频只剩 1 帧命中就全丢。
        let minimum = max(1, Int((Double(frameCount) * 0.34).rounded(.up)))
        var labels = order.filter { (counts[$0] ?? 0) >= minimum }
        if labels.isEmpty {
            labels = order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }.prefix(4).map { $0 }
        }
        labels = Array(labels.prefix(12))

        var lines: [String] = []
        for result in results {
            for line in result.text.split(separator: "\n") {
                let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !lines.contains(value) else { continue }
                lines.append(value)
            }
        }
        let text = String(lines.joined(separator: "\n").prefix(2000))
        let feature = averageFeature(results.compactMap(\.feature))
        if usedSigLIP { labels.append(PhotoTagCatalog.sentinel) }
        return PhotoIntelligence.Result(labels: labels.joined(separator: " "),
                                        text: text,
                                        feature: feature)
    }

    /// 多帧向量取平均再归一化；维度不一致（例如部分帧回退到 Vision）时放弃向量。
    private static func averageFeature(_ features: [Data]) -> Data? {
        guard let first = features.first, first.count >= 4, first.count % 4 == 0 else { return nil }
        let dimension = first.count / 4
        guard features.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        for data in features {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let values = raw.bindMemory(to: Float.self)
                for index in 0..<min(dimension, values.count) {
                    sum[index] += values[index]
                }
            }
        }
        var norm: Float = 0
        for value in sum { norm += value * value }
        guard norm > 0 else { return nil }
        let scale = 1 / sqrt(norm)
        for index in sum.indices { sum[index] *= scale }
        return sum.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - 抽帧

    private static func videoDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func sampleFrames(url: URL, duration: Double) async -> [CGImage] {
        let times = sampleTimes(duration: duration, count: frameCount(for: duration))
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [CGImage] = []
        for seconds in times {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                frames.append(result.image)
            }
        }
        if frames.count >= 2 { return frames }
        // AVFoundation 对 MKV / 特殊编码经常直接失败：交给 ffmpeg 按同一组时间点取帧。
        return await ffmpegFrames(url: url, times: times)
    }

    private static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0, count > 0 else { return [] }
        // 5%–95% 避开黑场片头与片尾；均匀取点，长视频也不会只看到同一场景。
        let start = min(0.5, duration * 0.05)
        let end = max(start, duration * 0.95)
        guard end > start else { return [duration / 2] }
        let step = (end - start) / Double(max(1, count - 1))
        return (0..<count).map { start + step * Double($0) }
    }

    private static func ffmpegFrames(url: URL, times: [Double]) async -> [CGImage] {
        guard let ffmpeg = FFmpeg.executable else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-video-frames-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var images: [CGImage] = []
        for (index, seconds) in times.enumerated() {
            let destination = directory.appendingPathComponent(String(format: "%02d.jpg", index))
            let arguments = ["-y", "-v", "error",
                             "-ss", String(format: "%.3f", seconds),
                             "-i", url.path,
                             "-frames:v", "1",
                             "-vf", "scale='min(1280,iw)':-2",
                             destination.path]
            _ = await run(ffmpeg, arguments, timeout: 20)
            if let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                images.append(image)
            }
        }
        return images
    }

    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return await withCheckedContinuation { continuation in
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                continuation.resume(returning: process.isRunning ? -1 : process.terminationStatus)
            }
        }
    }
}
