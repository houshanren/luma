// 金标集候选采样：从指定照片目录里分层抽 1,200 张，输出待标注的 goldset.json。
// 只读取图片元数据与缩略图；不复制、不上传原图。人脸只用于统计「合影 / 单人」切片，不保存特征。
//
// 编译（仓库根目录；单文件 @main 需要 -parse-as-library）：
//   swiftc -O -parse-as-library Tools/vision_bench/goldset_sample.swift \
//     -o /tmp/goldset_sample \
//     -framework AppKit -framework Vision -framework ImageIO -framework Foundation
//
// 运行：
//   /tmp/goldset_sample <照片目录> [goldset.json] [target=1200] [--no-faces]
//
// 分层：GPS / 无 GPS × 夜景 / 合影 / 单人 / 其他，再单独切出截图与文档。
// 输出的 labels 是空数组，需要人工标注；标注格式见 docs/ai/vision-understanding-benchmark-2026-11.md §7。

import Foundation
import AppKit
import Vision
import ImageIO

private struct Candidate {
    let url: URL
    let width: Int
    let height: Int
    let capturedAt: Date?
    let hasGPS: Bool
    let isScreenshotOrDocument: Bool
    var luminance: Double = 0.5
    var faces: Int = 0

    var strataKey: String {
        if isScreenshotOrDocument { return "document" }
        let light = luminance < 0.18 ? "night" : "day"
        let people = faces >= 3 ? "group" : (faces > 0 ? "people" : "solo")
        return "\(hasGPS ? "gps" : "nogps")_\(light)_\(people)"
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@main
enum GoldSetSample {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: goldset_sample <photoRoot> [goldset.json] [target=1200] [--no-faces]")
            exit(2)
        }
        let root = URL(fileURLWithPath: args[1])
        let outputURL = URL(fileURLWithPath: args.count > 2 ? args[2] : "goldset.json")
        let target = max(1, Int(args.count > 3 ? args[3] : "1200") ?? 1200)
        let detectFaces = !args.contains("--no-faces")

        let files = enumerateImages(root: root)
        guard !files.isEmpty else {
            print("FAIL 目录里没有可用图片：\(root.path)")
            exit(1)
        }
        print("found \(files.count) images under \(root.path)")

        // 先随机抽 4 倍候选池，再读元数据 / 亮度 / 人脸。
        // 图库上万张时，避免对全部图片逐个读 EXIF（外置盘上会非常慢）。
        var rng = SplitMix64(state: 0x1A2B_3C4D_5E6F_7788)
        let poolGoal = min(files.count, max(target * 4, target + 200))
        let shuffled = files.shuffled(using: &rng)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(poolGoal)
        var cursor = 0
        while candidates.count < poolGoal, cursor < shuffled.count {
            let batchEnd = min(shuffled.count, cursor + max(200, poolGoal - candidates.count))
            for url in shuffled[cursor..<batchEnd] {
                if let candidate = metadata(for: url) { candidates.append(candidate) }
                if candidates.count >= poolGoal { break }
            }
            cursor = batchEnd
        }
        guard !candidates.isEmpty else {
            print("FAIL 没有读到可解析的图片元数据")
            exit(1)
        }
        print("candidate pool=\(candidates.count) (read \(cursor)/\(files.count) metadata)")

        var pool = candidates

        for index in pool.indices {
            let thumbnail = loadThumbnail(path: pool[index].url, maxPixel: 512)
            if let thumbnail {
                pool[index].luminance = luminance(thumbnail)
                if detectFaces { pool[index].faces = faceCount(thumbnail) }
            }
            if (index + 1) % 200 == 0 { print("  inspect \(index + 1)/\(pool.count)") }
        }

        let selected = stratifiedSample(pool, target: target, rng: &rng)
        let items = selected.enumerated().map { index, candidate -> [String: Any] in
            var item: [String: Any] = [
                "id": String(format: "%04d", index + 1),
                "path": candidate.url.path,
                "width": candidate.width,
                "height": candidate.height,
                "gps": candidate.hasGPS,
                "faces": candidate.faces,
                "luminance": (candidate.luminance * 1000).rounded() / 1000,
                "stratum": candidate.strataKey,
                "labels": [],
                "text": "",
                "event": NSNull()
            ]
            if let date = candidate.capturedAt {
                item["capturedAt"] = ISO8601DateFormatter().string(from: date)
                item["slice"] = ["month": monthKey(date)]
            } else {
                item["slice"] = [:]
            }
            var slice = item["slice"] as? [String: String] ?? [:]
            slice["gps"] = candidate.hasGPS ? "with" : "without"
            slice["faces"] = candidate.faces >= 3 ? "group" : (candidate.faces > 0 ? "people" : "none")
            slice["light"] = candidate.luminance < 0.18 ? "night" : "day"
            if candidate.isScreenshotOrDocument { slice["kind"] = "document" }
            item["slice"] = slice
            return item
        }

        let payload: [String: Any] = [
            "version": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "root": root.path,
            "target": target,
            "tagsVersion": 2,
            "items": items
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
        } catch {
            print("FAIL 写入失败：\(error)")
            exit(1)
        }

        let counts = Dictionary(grouping: selected, by: \.strataKey).mapValues(\.count)
        print("wrote \(outputURL.path) items=\(selected.count)")
        for key in counts.keys.sorted() {
            print("  \(key): \(counts[key] ?? 0)")
        }
        print("下一步：按 docs/ai/vision-understanding-benchmark-2026-11.md §7 标注 labels，再用 vision_predict + goldset_eval 跑指标。")
    }

    // MARK: - 枚举与元数据

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"
    ]

    private static func enumerateImages(root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func metadata(for url: URL) -> Candidate? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }

        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        let hasGPS = gps != nil && coordinate(gps!).latitude != nil && coordinate(gps!).longitude != nil

        var capturedAt: Date?
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            capturedAt = exifFormatter.date(from: text)
        }
        if capturedAt == nil {
            capturedAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }

        let name = url.lastPathComponent.lowercased()
        let isDocument = ["screenshot", "截屏", "截图", "scan", "发票", "receipt", "invoice",
                          "document", "证书", "合同", "扫描"].contains { name.contains($0) }
        return Candidate(url: url,
                         width: width,
                         height: height,
                         capturedAt: capturedAt,
                         hasGPS: hasGPS,
                         isScreenshotOrDocument: isDocument)
    }

    private static func coordinate(_ gps: [String: Any]) -> (latitude: Double?, longitude: Double?) {
        func value(_ key: CFString, refKey: CFString, positive: String) -> Double? {
            guard let raw = gps[key as String] else { return nil }
            var number: Double?
            if let double = raw as? Double { number = double }
            else if let string = raw as? String { number = Double(string) }
            guard let number else { return nil }
            let ref = (gps[refKey as String] as? String)?.uppercased()
            return ref == positive ? number : -number
        }
        return (value(kCGImagePropertyGPSLatitude, refKey: kCGImagePropertyGPSLatitudeRef, positive: "N"),
                value(kCGImagePropertyGPSLongitude, refKey: kCGImagePropertyGPSLongitudeRef, positive: "E"))
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func monthKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    // MARK: - 缩略图

    private static func loadThumbnail(path: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(path as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary)
    }

    private static func luminance(_ image: CGImage) -> Double {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return 0.5 }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / Double(size * size)
    }

    private static func faceCount(_ image: CGImage) -> Int {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return 0 }
        return request.results?.count ?? 0
    }

    // MARK: - 分层

    private static func stratifiedSample(_ pool: [Candidate],
                                         target: Int,
                                         rng: inout SplitMix64) -> [Candidate] {
        let buckets = Dictionary(grouping: pool, by: \.strataKey)
        // 权重按「人生轨迹」需要分配：人物 / 合影优先，截图文档保留，夜景不丢。
        let weights: [String: Double] = [
            "gps_day_people": 0.12, "gps_day_group": 0.08, "gps_night_people": 0.06,
            "gps_night_group": 0.04, "gps_day_solo": 0.08, "gps_night_solo": 0.04,
            "nogps_day_people": 0.14, "nogps_day_group": 0.08, "nogps_night_people": 0.06,
            "nogps_night_group": 0.04, "nogps_day_solo": 0.08, "nogps_night_solo": 0.03,
            "document": 0.15
        ]
        var quotas: [String: Int] = [:]
        var assigned = 0
        for (key, weight) in weights {
            let count = Int((Double(target) * weight).rounded())
            quotas[key] = count
            assigned += count
        }
        // 余数补给最大桶。
        var remainder = max(0, target - assigned)
        for key in weights.keys.sorted() where remainder > 0 {
            let add = min(remainder, max(0, target / 10))
            quotas[key, default: 0] += add
            remainder -= add
            if remainder == 0 { break }
        }

        var selected: [Candidate] = []
        var used = Set<URL>()
        for key in weights.keys.sorted() {
            guard let bucket = buckets[key] else { continue }
            let take = min(quotas[key] ?? 0, bucket.count)
            for candidate in bucket.shuffled(using: &rng).prefix(take) {
                if used.insert(candidate.url).inserted { selected.append(candidate) }
            }
        }
        // 某些层不足时，从剩余池按顺序补齐，保证接近 target。
        if selected.count < target {
            for candidate in pool.shuffled(using: &rng) {
                if selected.count >= target { break }
                if used.insert(candidate.url).inserted { selected.append(candidate) }
            }
        }
        return Array(selected.prefix(target))
    }
}
