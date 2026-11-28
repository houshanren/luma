// 标签向量构建：把 tags.json 里的每条 prompt 送进 SigLIP2 文本塔，
// 按标签取平均并归一化，写出 float16 的 tag_embeddings.bin。
//
// 用途：新增标签后必须重建向量，否则标签数量与向量数量错位，匹配会整体失效。
//
// 编译（在仓库根目录）：
//   swiftc -O Tools/vision_bench/tag_embedding_build.swift \
//     Sources/Luma/Services/Media/SigLIPTokenizer.swift \
//     -o /tmp/tag_embedding_build \
//     -framework CoreML -framework Foundation
//
// 运行：
//   /tmp/tag_embedding_build [tags.json] [输出目录] [模型目录]
// 默认：
//   tags.json   = Resources/Models/SigLIP2Assets/tags.json
//   输出目录    = 与 tags.json 同目录
//   模型目录    = ~/Library/Application Support/Luma/Models/SigLIP2

import Foundation
import CoreML

private struct Catalog: Decodable {
    let embeddingDim: Int
    let tags: [Tag]

    struct Tag: Decodable {
        let id: String
        let title: String
        let prompts: [String]
    }
}

@main
enum TagEmbeddingBuild {
    static func main() {
        let args = CommandLine.arguments
        let tagsURL = URL(fileURLWithPath: args.count > 1
                          ? args[1]
                          : "Resources/Models/SigLIP2Assets/tags.json")
        let outDir = URL(fileURLWithPath: args.count > 2
                         ? args[2]
                         : tagsURL.deletingLastPathComponent().path)
        let modelDir = URL(fileURLWithPath: args.count > 3
                           ? args[3]
                           : NSHomeDirectory() + "/Library/Application Support/Luma/Models/SigLIP2")

        guard let data = try? Data(contentsOf: tagsURL),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            fail("读不到或解析不了 tags.json：\(tagsURL.path)")
        }
        guard catalog.embeddingDim > 0, !catalog.tags.isEmpty else {
            fail("tags.json 缺少 embeddingDim 或 tags")
        }
        guard let tokenizer = SigLIPTokenizer(directory: modelDir) else {
            fail("分词器加载失败：\(modelDir.path)")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelDir.appendingPathComponent("TextEncoder.mlmodelc"),
                                       configuration: configuration) else {
            fail("文本塔加载失败：\(modelDir.path)/TextEncoder.mlmodelc")
        }

        print("tags=\(catalog.tags.count) dim=\(catalog.embeddingDim) model=\(modelDir.path)")

        var vectors: [Float] = []
        vectors.reserveCapacity(catalog.tags.count * catalog.embeddingDim)
        var emptyPromptTags: [String] = []

        for (index, tag) in catalog.tags.enumerated() {
            let prompts = tag.prompts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !prompts.isEmpty else {
                emptyPromptTags.append(tag.title)
                vectors.append(contentsOf: [Float](repeating: 0, count: catalog.embeddingDim))
                continue
            }
            var sum = [Float](repeating: 0, count: catalog.embeddingDim)
            var used = 0
            for prompt in prompts {
                guard let vector = embed(prompt,
                                         tokenizer: tokenizer,
                                         model: model,
                                         dimension: catalog.embeddingDim) else { continue }
                for d in 0..<catalog.embeddingDim { sum[d] += vector[d] }
                used += 1
            }
            guard used > 0 else {
                emptyPromptTags.append(tag.title)
                vectors.append(contentsOf: [Float](repeating: 0, count: catalog.embeddingDim))
                continue
            }
            normalize(&sum)
            vectors.append(contentsOf: sum)
            if (index + 1) % 40 == 0 || index + 1 == catalog.tags.count {
                print("  embedded \(index + 1)/\(catalog.tags.count)")
            }
        }

        if !emptyPromptTags.isEmpty {
            print("WARN 没有可用 prompt 的标签：\(emptyPromptTags.joined(separator: "、"))")
        }

        let outURL = outDir.appendingPathComponent("tag_embeddings.bin")
        let previous = try? Data(contentsOf: outURL)
        var bytes = Data(capacity: vectors.count * 2)
        for value in vectors {
            var half = floatToHalf(value)
            withUnsafeBytes(of: &half) { bytes.append(contentsOf: $0) }
        }
        do {
            try bytes.write(to: outURL)
        } catch {
            fail("写入失败：\(outURL.path) \(error)")
        }
        print("wrote \(outURL.path) bytes=\(bytes.count)")

        if let previous {
            verify(previous: previous,
                   vectors: vectors,
                   catalog: catalog,
                   dimension: catalog.embeddingDim)
        }
    }

    // MARK: - 推理

    private static func embed(_ text: String,
                              tokenizer: SigLIPTokenizer,
                              model: MLModel,
                              dimension: Int) -> [Float]? {
        do {
            let tokens = tokenizer.encode(text)
            let array = try MLMultiArray(shape: [1, NSNumber(value: tokenizer.maxLength)],
                                         dataType: .int32)
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: tokenizer.maxLength)
            for index in 0..<tokenizer.maxLength {
                pointer[index] = index < tokens.count ? tokens[index] : tokenizer.padID
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "tokens": MLFeatureValue(multiArray: array)
            ])
            let output = try model.prediction(from: provider)
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            var vector = floatValues(embedding)
            guard vector.count >= dimension else { return nil }
            if vector.count > dimension { vector = Array(vector.prefix(dimension)) }
            normalize(&vector)
            return vector
        } catch {
            print("ERROR prompt=\(text) \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 校验

    /// 与旧文件对照：存量标签的向量应当几乎不变（差异只来自 float16 舍入）。
    private static func verify(previous: Data,
                               vectors: [Float],
                               catalog: Catalog,
                               dimension: Int) {
        let oldCount = previous.count / (dimension * 2)
        guard oldCount > 0 else { return }
        var drifted: [(String, Float)] = []
        previous.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let half = raw.bindMemory(to: UInt16.self)
            for index in 0..<min(oldCount, catalog.tags.count) {
                var dot: Float = 0
                for d in 0..<dimension {
                    let old = halfToFloat(half[index * dimension + d])
                    dot += old * vectors[index * dimension + d]
                }
                if dot < 0.999 {
                    drifted.append((catalog.tags[index].title, dot))
                }
            }
        }
        if drifted.isEmpty {
            print("verify: 存量 \(min(oldCount, catalog.tags.count)) 条向量与旧文件一致（cos ≥ 0.999）")
        } else {
            print("verify WARN: \(drifted.count) 条向量发生漂移")
            for item in drifted.prefix(10) {
                print(String(format: "  %@  cos=%.4f", item.0, item.1))
            }
        }
    }

    // MARK: - 数值

    private static func normalize(_ vector: inout [Float]) {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return }
        let scale = 1 / sqrt(sum)
        for index in vector.indices { vector[index] *= scale }
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

    private static func floatToHalf(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        var exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        var mantissa = bits & 0x7F_FFFF
        if exponent <= 0 {
            if exponent < -10 { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - exponent)
            let rounded = (mantissa &+ (1 << (shift - 1))) >> shift
            return sign | UInt16(rounded)
        }
        if exponent >= 0x1F {
            return sign | 0x7C00
        }
        // 就近舍入（half-away-from-zero 的近似）。
        mantissa &+= 0x1000
        if mantissa & 0x80_0000 != 0 {
            mantissa = 0
            exponent += 1
            if exponent >= 0x1F { return sign | 0x7C00 }
        }
        return sign | (UInt16(exponent) << 10) | UInt16((mantissa >> 13) & 0x03FF)
    }

    private static func fail(_ message: String) -> Never {
        print("FAIL \(message)")
        exit(1)
    }
}
