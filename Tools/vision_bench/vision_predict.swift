// 金标集预测器：对 goldset.json 里的每张图片，输出 249 个标签的分数。
// 与 App 使用同一套 SigLIP2 图像塔 / 标签向量 / 阈值数据，便于离线算 P/R/F1 与阈值校准。
//
// 编译（仓库根目录；单文件 @main 需要 -parse-as-library）：
//   swiftc -O -parse-as-library Tools/vision_bench/vision_predict.swift \
//     -o /tmp/vision_predict \
//     -framework CoreML -framework AppKit -framework ImageIO -framework Foundation
//
// 运行：
//   /tmp/vision_predict goldset.json [tags.json] [模型目录] [predictions.json] [limit] [--apple]
//   --apple 会额外跑 Apple Vision 分类器，作为独立参照（本地，不上传）。
// 默认：
//   tags.json   = Resources/Models/SigLIP2Assets/tags.json
//   模型目录    = ~/Library/Application Support/Luma/Models/SigLIP2
//   输出        = tools 旁边 predictions.json

import Foundation
import CoreML
import AppKit
import ImageIO
import Vision

private struct GoldSet: Decodable {
    let version: Int?
    let items: [Item]

    struct Item: Decodable {
        let id: String
        let path: String
        let labels: [String]?
        let slice: [String: String]?
    }
}

private struct Tag: Decodable {
    let id: String
    let title: String
    let group: String
    let threshold: Double
}

private struct Catalog: Decodable {
    let version: Int?
    let embeddingDim: Int
    let tags: [Tag]
}

@main
enum VisionPredict {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: vision_predict <goldset.json> [tags.json] [modelDir] [output.json] [limit]")
            exit(2)
        }
        let goldURL = URL(fileURLWithPath: args[1])
        let tagsURL = URL(fileURLWithPath: args.count > 2
                          ? args[2]
                          : "Resources/Models/SigLIP2Assets/tags.json")
        let modelDir = URL(fileURLWithPath: args.count > 3
                           ? args[3]
                           : NSHomeDirectory() + "/Library/Application Support/Luma/Models/SigLIP2")
        let outputURL = URL(fileURLWithPath: args.count > 4
                            ? args[4]
                            : "predictions.json")
        let limit = args.count > 5 ? (Int(args[5]) ?? Int.max) : Int.max
        let classifyApple = args.contains("--apple")

        guard let goldData = try? Data(contentsOf: goldURL),
              let gold = try? JSONDecoder().decode(GoldSet.self, from: goldData) else {
            fail("读不到 goldset：\(goldURL.path)")
        }
        guard let tagsData = try? Data(contentsOf: tagsURL),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: tagsData) else {
            fail("读不到 tags.json：\(tagsURL.path)")
        }
        guard let vectors = loadVectors(tagsURL: tagsURL,
                                        dimension: catalog.embeddingDim,
                                        count: catalog.tags.count) else {
            fail("tag_embeddings.bin 与 tags.json 不匹配")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelDir.appendingPathComponent("ImageEncoder.mlmodelc"),
                                       configuration: configuration) else {
            fail("图像塔加载失败：\(modelDir.path)")
        }

        print("goldset items=\(gold.items.count) tags=\(catalog.tags.count) model=\(modelDir.path)")
        var output: [[String: Any]] = []
        var failed = 0

        for (index, item) in gold.items.prefix(limit).enumerated() {
            let startedAt = CFAbsoluteTimeGetCurrent()
            guard let image = loadImage(path: item.path),
                  let vector = imageEmbedding(image, model: model, dimension: catalog.embeddingDim) else {
                failed += 1
                print("WARN 跳过无法读取的图片：\(item.path)")
                continue
            }
            let embeddingMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            var appleMs = 0.0
            var apple: [[String: Any]] = []
            if classifyApple {
                let appleStartedAt = CFAbsoluteTimeGetCurrent()
                apple = appleClassifications(image)
                appleMs = (CFAbsoluteTimeGetCurrent() - appleStartedAt) * 1000
            }
            var scores: [String: Double] = [:]
            var ranked: [(id: String, title: String, score: Double)] = []
            ranked.reserveCapacity(catalog.tags.count)
            for tagIndex in 0..<catalog.tags.count {
                let base = tagIndex * catalog.embeddingDim
                var dot: Float = 0
                for d in 0..<catalog.embeddingDim {
                    dot += vector[d] * vectors[base + d]
                }
                let tag = catalog.tags[tagIndex]
                let score = Double(dot)
                scores[tag.id] = (score * 10_000).rounded() / 10_000
                ranked.append((tag.id, tag.title, score))
            }
            ranked.sort { $0.score > $1.score }
            let top = ranked.prefix(12).map { entry -> [String: Any] in
                ["id": entry.id,
                 "title": entry.title,
                 "score": (entry.score * 10_000).rounded() / 10_000]
            }
            output.append([
                "id": item.id,
                "path": item.path,
                "labels": item.labels ?? [],
                "slice": item.slice ?? [:],
                "scores": scores,
                "top": top,
                "embeddingMs": (embeddingMs * 100).rounded() / 100,
                "apple": apple,
                "appleMs": (appleMs * 100).rounded() / 100
            ])
            if (index + 1) % 50 == 0 || index + 1 == min(gold.items.count, limit) {
                print("  predicted \(index + 1)/\(min(gold.items.count, limit))")
            }
        }

        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "tagsVersion": catalog.version ?? 1,
            "tagsCount": catalog.tags.count,
            "model": "siglip2-base-patch16-256",
            "modelDir": modelDir.path,
            "appleClassifier": classifyApple,
            "items": output
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
        } catch {
            fail("写入失败：\(outputURL.path) \(error)")
        }
        print("wrote \(outputURL.path) items=\(output.count) failed=\(failed)")
    }

    // MARK: - 图像

    private static func loadImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200
        ] as CFDictionary)
    }

    private static func appleClassifications(_ image: CGImage) -> [[String: Any]] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        // 只保留置信度 ≥ 0.10 的前 10 个，避免把噪声当参照。
        let results = (request.results ?? [])
            .filter { $0.confidence >= 0.10 }
            .prefix(10)
        return results.map { observation in
            ["label": observation.identifier,
             "confidence": (Double(observation.confidence) * 1000).rounded() / 1000]
        }
    }

    private static func imageEmbedding(_ image: CGImage,
                                       model: MLModel,
                                       dimension: Int) -> [Float]? {
        let input = model.modelDescription.inputDescriptionsByName["image"]
        guard input?.type == .image else {
            print("WARN 图像塔输入不是 ImageType，无法复用 App 管线")
            return nil
        }
        let size = input?.imageConstraint?.pixelsWide ?? 256
        guard let buffer = pixelBuffer(from: image, size: size),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [
                  "image": MLFeatureValue(pixelBuffer: buffer)
              ]),
              let output = try? model.prediction(from: provider),
              let array = output.featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }
        var vector = floatValues(array)
        guard vector.count >= dimension else { return nil }
        if vector.count > dimension { vector = Array(vector.prefix(dimension)) }
        var norm: Float = 0
        for value in vector { norm += value * value }
        guard norm > 0 else { return nil }
        let scale = 1 / sqrt(norm)
        for index in vector.indices { vector[index] *= scale }
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

    // MARK: - 向量

    private static func loadVectors(tagsURL: URL, dimension: Int, count: Int) -> [Float]? {
        let binURL = tagsURL.deletingLastPathComponent().appendingPathComponent("tag_embeddings.bin")
        guard let data = try? Data(contentsOf: binURL) else { return nil }
        guard data.count / (dimension * 2) >= count else { return nil }
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

    private static func fail(_ message: String) -> Never {
        print("FAIL \(message)")
        exit(1)
    }
}
