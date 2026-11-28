import Foundation
import CoreML
import AppKit
import ImageIO

// 拾光端侧标签抽检：公开样例图 + 当前 tags.json / tag_embeddings.bin / SigLIP2 ImageEncoder。
// 只输出机器判定，人工对照预期标签统计命中情况。

setvbuf(stdout, nil, _IONBF, 0)

let samplesDir = URL(fileURLWithPath: "/tmp/luma_samples")
let siglipDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Luma/Models/SigLIP2")
let cfg = MLModelConfiguration(); cfg.computeUnits = .all
let encoder = try MLModel(contentsOf: siglipDir.appendingPathComponent("ImageEncoder.mlmodelc"), configuration: cfg)

struct Tag: Decodable { let title: String; let group: String; let threshold: Double }
struct Catalog: Decodable {
    let embeddingDim: Int
    let defaultThreshold: Double
    let groupLimits: [String: Int]
    let tags: [Tag]
}
let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: siglipDir.appendingPathComponent("tags.json")))
let dim = catalog.embeddingDim
let rawVec = try Data(contentsOf: siglipDir.appendingPathComponent("tag_embeddings.bin"))
let count = rawVec.count / (dim * 2)
var tagVectors = [Float](repeating: 0, count: count * dim)
rawVec.withUnsafeBytes { raw in
    let half = raw.bindMemory(to: UInt16.self)
    for i in 0..<(count * dim) {
        let bits = half[i]
        let sign = UInt32(bits & 0x8000) << 16
        let exp = Int((bits >> 10) & 0x1F)
        let mant = UInt32(bits & 0x03FF)
        if exp == 0 {
            tagVectors[i] = 0
        } else if exp == 0x1F {
            tagVectors[i] = Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
        } else {
            tagVectors[i] = Float(bitPattern: sign | (UInt32(exp + 127 - 15) << 23) | (mant << 13))
        }
    }
}

func pixelBuffer(_ image: CGImage, size: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &buffer) == kCVReturnSuccess,
          let pb = buffer else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return pb
}

func embedding(for url: URL) -> ([Float], [String]) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let pb = pixelBuffer(cg, size: 256) else { return ([], []) }
    guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)]),
          let out = try? encoder.prediction(from: input),
          let arr = out.featureValue(for: "embedding")?.multiArrayValue else { return ([], []) }
    var vec = (0..<arr.count).map { arr[$0].floatValue }
    let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
    if norm > 0 { for i in vec.indices { vec[i] /= norm } }
    return (vec, [])
}

func matchedTags(_ vec: [Float]) -> [(String, Float)] {
    var scored: [(Int, Float)] = []
    for i in 0..<min(count, catalog.tags.count) {
        let base = i * dim
        var dot: Float = 0
        for d in 0..<dim { dot += vec[d] * tagVectors[base + d] }
        let threshold = Float(catalog.tags[i].threshold > 0 ? catalog.tags[i].threshold : catalog.defaultThreshold)
        if dot >= threshold { scored.append((i, dot)) }
    }
    scored.sort { $0.1 > $1.1 }
    var used: [String: Int] = [:]
    var result: [(String, Float)] = []
    for (i, score) in scored {
        let tag = catalog.tags[i]
        let limit = catalog.groupLimits[tag.group] ?? 99
        if used[tag.group, default: 0] >= limit { continue }
        used[tag.group] = (used[tag.group] ?? 0) + 1
        result.append((tag.title, score))
        if result.count >= 12 { break }
    }
    return result
}

let expectations: [(String, [String])] = [
    ("beach", ["海边", "沙滩", "海洋"]),
    ("mountain", ["山脉", "雪山", "徒步", "自然风光"]),
    ("cat", ["猫", "宠物"]),
    ("dog", ["狗", "宠物"]),
    ("pizza", ["披萨", "美食"]),
    ("car", ["汽车", "交通工具"]),
    ("wedding", ["婚礼", "人物", "情侣"])
]

var hits = 0
var total = 0
for (name, expected) in expectations {
    let url = samplesDir.appendingPathComponent("\(name).jpg")
    guard FileManager.default.fileExists(atPath: url.path) else { continue }
    let (vec, _) = embedding(for: url)
    guard !vec.isEmpty else { print("\(name): embedding failed"); continue }
    let tags = matchedTags(vec)
    let titles = tags.map(\.0)
    let hit = expected.contains { titles.prefix(6).contains($0) }
    hits += hit ? 1 : 0
    total += 1
    let line = tags.prefix(6).map { String(format: "%@(%.3f)", $0.0, $0.1) }.joined(separator: "  ")
    print("\(hit ? "HIT " : "MISS") \(name)  ->  \(line)")
}
print(String(format: "top-6 hit rate: %d/%d = %.0f%%", hits, total, total > 0 ? Double(hits) / Double(total) * 100 : 0))
