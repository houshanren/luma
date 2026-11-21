import AppKit
import AVFoundation

/// 进度条悬停 / 拖动时的画面预览：用当前播放项生成该时间点的一帧。
enum VideoScrubThumbnails {
    private static var generators: [ObjectIdentifier: AVAssetImageGenerator] = [:]
    private static let lock = NSLock()

    static func image(player: AVPlayer, fraction: Double, duration: Double) async -> NSImage? {
        guard duration > 0, let asset = player.currentItem?.asset else { return nil }
        let generator = generator(for: asset)
        generator.maximumSize = CGSize(width: 240, height: 135)
        // HLS 的关键帧间隔较大，放宽一点容差，避免经常取不到帧。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.8, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.8, preferredTimescale: 600)
        let seconds = max(0, min(duration, duration * fraction))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage,
                           size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
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
