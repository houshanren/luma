// 标签阈值标定：用一份带标注的小样本集，为每个标签扫描阈值，
// 输出建议阈值报告（CSV）。不会自动改 tags.json，避免一次小样本把线上阈值带偏。
//
// 输入：manifest.json
//   [
//     {"path": "/abs/img.jpg", "tags": ["beach", "sandy_beach"]},
//     ...
//   ]
// 每个标签的正样本 = manifest 里包含该 id 的图片；负样本 = 其余图片。
//
// 编译（在仓库根目录）：
//   swiftc -O Tools/vision_bench/tag_calibrate.swift \
//     Sources/Luma/Services/Media/SigLIPTokenizer.swift \
//     -o /tmp/tag_calibrate \
//     -framework CoreML -framework AppKit -framework ImageIO -framework Foundation
//
// 运行：
//   /tmp/tag_calibrate /tmp/manifest.json [tags.json] [模型目录] [报告.csv]

import Foundation
import CoreML
import AppKit
import ImageIO

private struct Catalog: Decodable {
    let embeddingDim: Int
    let defaultThreshold: Double
    let tags: [Tag]

    struct Tag: Decodable {
        let id: String
        let title: String
        let group: String
        let threshold: Double
    }
}

private struct Sample: Decodable {
    let path: String
    let tags: [String]
}

@main
enum TagCalibrate {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: tag_calibrate <manifest.json> [tags.json] [modelDir] [report.csv]")
            exit(2)
        }
        let manifestURL = URL(fileURLWithPath: args[1])
        let tagsURL = URL(fileURLWithPath: args.count > 2
                          ? args[2]
                          : "Resources/Models/SigLIP2Assets/tags.json")
        let modelDir = URL(fileURLWithPath: args.count > 3
                           ? args[3]
                           : NSHomeDirectory() + "/Library/Application Support/Luma/Models/SigLIP2")
        let reportURL: URL? = args.count > 4 ? URL(fileURLWithPath: args[4]) : nil

        guard let manifestData = try? Data(contentsOf: manifestURL),
              let samples = try? JSONDecoder().decode([Sample].self, from: manifestData),
              !samples.isEmpty else {
            print("FAIL 读不到或解析不了 manifest：\(manifestURL.path)")
            exit(1)
        }
        guard let tagsData = try? Data(contentsOf: tagsURL),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: tagsData) else {
            print("FAIL 读不到或解析不了 tags.json：\(tagsURL.path)")
            exit(1)
        }
        guard catalog.embeddingDim > 0 else { exit(1) }
        guard let vectors = loadTagVectors(tagsURL: tagsURL,
                                           dimension: catalog.embeddingDim,
                                           count: catalog.tags.count) else {
            print("FAIL tag_embeddings.bin 与 tags.json 不匹配")
            exit(1)
        }
        guard let tokenizer = SigLIPTokenizer(directory: modelDir) else {
            print("FAIL 分词器加载失败")
            exit(1)
        }
        _ = tokenizer // 标定只用图像塔；保留参数说明依赖同一模型目录。

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let imageModel = try? MLModel(contentsOf: modelDir.appendingPathComponent("ImageEncoder.mlmodelc"),
                                            configuration: configuration) else {
            print("FAIL 图像塔加载失败")
            exit(1)
        }

        // 每张图的向量只算一次。
        var scores: [[Float]] = []
        var validSamples: [Sample] = []
        for sample in samples {
            guard let image = loadCGImage(path: sample.path),
                  let embedding = imageEmbedding(image, model: imageModel, dimension: catalog.embeddingDim) else {
                print("WARN 跳过无法读取的图片：\(sample.path)")
                continue
            }
            var row = [Float](repeating: 0, count: catalog.tags.count)
            for index in 0..<catalog.tags.count {
                var dot: Float = 0
                let base = index * catalog.embeddingDim
                for d in 0..<catalog.embeddingDim {
                    dot += embedding[d] * vectors[base + d]
                }
                row[index] = dot
            }
            scores.append(row)
            validSamples.append(sample)
        }

        guard !scores.isEmpty else {
            print("FAIL 没有可用样本")
            exit(1)
        }
        print("samples=\(scores.count) tags=\(catalog.tags.count)")

        var lines = ["id,title,group,old,suggested,positives,negatives,maxPos,minPos,maxNeg,reason"]
        var changed = 0

        for (index, tag) in catalog.tags.enumerated() {
            var positives: [Float] = []
            var negatives: [Float] = []
            for (rowIndex, sample) in validSamples.enumerated() {
                let score = scores[rowIndex][index]
                if sample.tags.contains(tag.id) {
                    positives.append(score)
                } else {
                    negatives.append(score)
                }
            }
            let maxPos = positives.max()
            let minPos = positives.min()
            let maxNeg = negatives.max() ?? 0
            let suggested: Double
            let reason: String

            if positives.isEmpty {
                // 没有正样本：阈值抬到所有负样本之上，避免在已见数据上误报。
                suggested = clamp(max(catalog.defaultThreshold, Double(maxNeg) + 0.005), 0.06, 0.12)
                reason = "no-positive"
            } else if let minPos, minPos > 0 {
                // 有正样本：正负可分时，阈值取「最低正样本 - 0.005」，
                // 既保住召回，又尽量远离负样本；若正负重叠，则优先保精度。
                if Double(minPos) > Double(maxNeg) {
                    suggested = clamp(Double(minPos) - 0.005,
                                      max(0.06, Double(maxNeg) + 0.005),
                                      0.12)
                    reason = "positive-margin"
                } else {
                    suggested = clamp(Double(maxNeg) + 0.005, 0.06, 0.12)
                    reason = "positive-conflict"
                }
            } else {
                suggested = catalog.defaultThreshold
                reason = "zero-vector"
            }

            if abs(suggested - tag.threshold) >= 0.001 { changed += 1 }
            lines.append(String(format: "%@,%@,%@,%.3f,%.3f,%d,%d,%@,%@,%.3f,%@",
                                tag.id, tag.title, tag.group,
                                tag.threshold, suggested,
                                positives.count, negatives.count,
                                maxPos.map { String(format: "%.3f", $0) } ?? "",
                                minPos.map { String(format: "%.3f", $0) } ?? "",
                                maxNeg, reason))
            if (index + 1) % 50 == 0 { print("  scored \(index + 1)/\(catalog.tags.count)") }
        }

        let csv = lines.joined(separator: "\n") + "\n"
        if let reportURL {
            try? csv.write(to: reportURL, atomically: true, encoding: .utf8)
            print("wrote \(reportURL.path)")
        }
        print(csv)
        print("suggested changes: \(changed)")
    }

    // MARK: - 图像

    private static func loadCGImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200
        ] as CFDictionary)
    }

    private static func imageEmbedding(_ image: CGImage,
                                       model: MLModel,
                                       dimension: Int) -> [Float]? {
        let input = model.modelDescription.inputDescriptionsByName["image"]
        let provider: MLFeatureProvider
        if input?.type == .image {
            let size = input?.imageConstraint?.pixelsWide ?? 256
            guard let buffer = pixelBuffer(from: image, size: size) else { return nil }
            provider = try! MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: buffer)
            ])
        } else {
            return nil
        }
        guard let output = try? model.prediction(from: provider),
              let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var vector = floatValues(array)
        guard vector.count >= dimension else { return nil }
        if vector.count > dimension { vector = Array(vector.prefix(dimension)) }
        normalize(&vector)
        return vector
    }

    private static func pixelBuffer(from image: CGImage, size: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                      width: size, height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pb
    }

    // MARK: - 向量与数值

    private static func loadTagVectors(tagsURL: URL, dimension: Int, count: Int) -> [Float]? {
        let binURL = tagsURL.deletingLastPathComponent().appendingPathComponent("tag_embeddings.bin")
        guard let data = try? Data(contentsOf: binURL) else { return nil }
        let available = data.count / (dimension * 2)
        guard available >= count else {
            print("WARN bin 只有 \(available) 条，tags 有 \(count) 条")
            return nil
        }
        var result = [Float](repeating: 0, count: count * dimension)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let half = raw.bindMemory(to: UInt16.self)
            for index in 0..<(count * dimension) {
                result[index] = halfToFloat(half[index])
            }
        }
        return result
    }

    private static func floatValues(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        guard count > 0 else { return [] }
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            return (0..<count).map { halfToFloat(pointer[$0]) }
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            return (0..<count).map { Float(pointer[$0]) }
        default:
            return (0..<count).map { Float(truncating: array[$0]) }
        }
    }

    private static func normalize(_ vector: inout [Float]) {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return }
        let scale = 1 / sqrt(sum)
        for index in vector.indices { vector[index] *= scale }
    }

    private static func halfToFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        var mantissa = UInt32(bits & 0x03FF)
        if exponent == 0 {
            guard mantissa != 0 else { return Float(bitPattern: sign) }
            var shift = -1
            repeat {
                shift += 1
                mantissa <<= 1
            } while (mantissa & 0x0400) == 0
            mantissa &= 0x03FF
            return Float(bitPattern: sign | (UInt32(112 - shift) << 23) | (mantissa << 13))
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | (UInt32(exponent + 127 - 15) << 23) | (mantissa << 13))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
