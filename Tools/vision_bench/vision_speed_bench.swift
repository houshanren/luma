import Foundation
import CoreML
import Vision
import AppKit
import ImageIO
import CoreText
import UniformTypeIdentifiers

// 拾光端侧图像理解基准（本机合成图，不含用户照片）。
// 只测速度与 OCR 合成图准确率；真实准确率需要标注集，另行评测。

func ms(_ t: Double) -> Double { t * 1000 }

func pct(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, max(0, Int(round(Double(sorted.count - 1) * p))))
    return sorted[idx]
}

func measure(_ count: Int, warmup: Int = 3, _ body: () -> Void) -> [Double] {
    for _ in 0..<warmup { body() }
    var out: [Double] = []
    out.reserveCapacity(count)
    for _ in 0..<count {
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        out.append(ms(CFAbsoluteTimeGetCurrent() - t0))
    }
    return out
}

func report(_ name: String, _ values: [Double]) {
    let mean = values.reduce(0, +) / Double(max(1, values.count))
    print(String(format: "%-28s n=%d  p50=%7.2fms  p95=%7.2fms  mean=%7.2fms  min=%7.2fms",
                 (name as NSString).utf8String!, values.count,
                 pct(values, 0.5), pct(values, 0.95), mean, values.min() ?? 0))
}

// MARK: - 机器与模型

setvbuf(stdout, nil, _IONBF, 0)

let cpu: String = {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
        return "Apple Silicon"
    }
    var buf = [CChar](repeating: 0, count: size)
    let ok = buf.withUnsafeMutableBytes { raw in
        sysctlbyname("machdep.cpu.brand_string", raw.baseAddress, &size, nil, 0) == 0
    }
    return ok ? String(cString: buf) : "Apple Silicon"
}()
let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
print("machine: \(cpu)  cores=\(ProcessInfo.processInfo.processorCount)  mem=\(String(format: "%.0f", memGB))GB  macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")

let home = FileManager.default.homeDirectoryForCurrentUser
let siglipDir = home.appendingPathComponent("Library/Application Support/Luma/Models/SigLIP2")
let yoloURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Models/YOLO11n/YOLO11n.mlmodelc")

let cfg = MLModelConfiguration()
cfg.computeUnits = .all

var loadT0 = CFAbsoluteTimeGetCurrent()
let siglip = try MLModel(contentsOf: siglipDir.appendingPathComponent("ImageEncoder.mlmodelc"), configuration: cfg)
let loadSiglip = ms(CFAbsoluteTimeGetCurrent() - loadT0)

loadT0 = CFAbsoluteTimeGetCurrent()
let textModel = try MLModel(contentsOf: siglipDir.appendingPathComponent("TextEncoder.mlmodelc"), configuration: cfg)
let loadText = ms(CFAbsoluteTimeGetCurrent() - loadT0)

var yolo: MLModel?
var loadYolo = 0.0
if FileManager.default.fileExists(atPath: yoloURL.path) {
    loadT0 = CFAbsoluteTimeGetCurrent()
    yolo = try? MLModel(contentsOf: yoloURL, configuration: cfg)
    loadYolo = ms(CFAbsoluteTimeGetCurrent() - loadT0)
}
print(String(format: "load: siglip_image=%.0fms siglip_text=%.0fms yolo=%.0fms", loadSiglip, loadText, loadYolo))
print("siglip inputs:", siglip.modelDescription.inputDescriptionsByName.map { "\($0.key):\($0.value.type)" })
print("siglip imageConstraint:", siglip.modelDescription.inputDescriptionsByName["image"]?.imageConstraint as Any)
if let yolo {
    print("yolo inputs:", yolo.modelDescription.inputDescriptionsByName.map { "\($0.key):\($0.value.type)" })
    print("yolo outputs:", yolo.modelDescription.outputDescriptionsByName.map { "\($0.key):\($0.value.type)" })
}

// MARK: - 合成图

func makeImage(width: Int, height: Int, text: [String]) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let grad = CGGradient(colorsSpace: colorSpace,
                          colors: [CGColor(red: 0.09, green: 0.11, blue: 0.18, alpha: 1),
                                   CGColor(red: 0.22, green: 0.30, blue: 0.62, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: height), options: [])
    let font = CTFontCreateWithName("PingFang SC" as CFString, CGFloat(width) / 28, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white.cgColor
    ]
    var y = height - Int(CGFloat(height) * 0.22)
    for line in text {
        let attributed = NSAttributedString(string: line, attributes: attrs)
        let lineRef = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: CGFloat(width) * 0.08, y: CGFloat(y))
        CTLineDraw(lineRef, ctx)
        y -= Int(CGFloat(width) / 18)
    }
    return ctx.makeImage()!
}

let ocrLines = [
    "拾光图像理解评测 2026 年 11 月",
    "Luma Vision Benchmark 12345",
    "发票代码 011002100311 金额 128.00 元",
    "北京市朝阳区建国路 88 号 电话 010-88886666"
]
let synthetic = makeImage(width: 1600, height: 1200, text: ocrLines)

// MARK: - SigLIP 图像编码

// SigLIP 图像编码：模型输入是 ImageType（不是 MultiArray），
// 必须用 CVPixelBuffer 喂，否则 prediction 直接抛错。
func makePixelBuffer(_ size: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                        attrs as CFDictionary, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<size {
        for x in 0..<size {
            let p = y * stride + x * 4
            base[p + 0] = UInt8((x * 7) % 255)
            base[p + 1] = UInt8((y * 11) % 255)
            base[p + 2] = UInt8((x + y) % 255)
            base[p + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

let pixelBuffer = makePixelBuffer(256)
let imageInput = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
do {
    let probe = try siglip.prediction(from: imageInput)
    print("siglip probe outputs:", probe.featureNames)
} catch {
    print("siglip probe error:", error.localizedDescription)
}
let imageTimes = measure(30) { _ = try? siglip.prediction(from: imageInput) }
report("SigLIP2 image 256x256", imageTimes)

var embedding: [Float] = []
if let out = try? siglip.prediction(from: imageInput),
   let arr = out.featureValue(for: "embedding")?.multiArrayValue {
    embedding = (0..<arr.count).map { arr[$0].floatValue }
}
print("embedding dim=\(embedding.count)")

// MARK: - SigLIP 文本编码

let tokens = try MLMultiArray(shape: [1, 64], dataType: .int32)
for i in 0..<64 { tokens[i] = NSNumber(value: Int32(i % 1000 + 10)) }
let textInput = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: tokens)])
let textTimes = measure(20) { _ = try? textModel.prediction(from: textInput) }
report("SigLIP2 text 64 tokens", textTimes)

if embedding.isEmpty {
    print("embedding empty: skip tag-match benchmark")
} else if let data = try? Data(contentsOf: siglipDir.appendingPathComponent("tag_embeddings.bin")) {
    // MARK: - 标签匹配（249 标签 × 768 维，float16 向量）
    let dim = 768
    let count = data.count / (dim * 2)
    var vectors = [Float](repeating: 0, count: count * dim)
    data.withUnsafeBytes { raw in
        let half = raw.bindMemory(to: UInt16.self)
        for i in 0..<(count * dim) {
            let bits = half[i]
            let sign = UInt32(bits & 0x8000) << 16
            let exp = Int((bits >> 10) & 0x1F)
            var mant = UInt32(bits & 0x03FF)
            if exp == 0 {
                vectors[i] = 0
            } else if exp == 0x1F {
                vectors[i] = Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
            } else {
                vectors[i] = Float(bitPattern: sign | (UInt32(exp + 127 - 15) << 23) | (mant << 13))
            }
        }
    }
    let matchTimes = measure(200) {
        var hits = 0
        for index in 0..<count {
            var dot: Float = 0
            let base = index * dim
            for d in 0..<dim { dot += embedding[d] * vectors[base + d] }
            if dot >= 0.085 { hits += 1 }
        }
        if hits < 0 { print("") }
    }
    report("tag match \(count)×768", matchTimes)
     print("tags=\(count) dim=\(dim)")
}

// MARK: - YOLO11n

var yoloTimes: [Double] = []
if let yolo {
    let yoloArray = try MLMultiArray(shape: [1, 3, 640, 640], dataType: .float32)
    for i in 0..<(3 * 640 * 640) { yoloArray[i] = NSNumber(value: Float(i % 255)) }
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(multiArray: yoloArray),
        "iouThreshold": MLFeatureValue(double: 0.5),
        "confidenceThreshold": MLFeatureValue(double: 0.4)
    ])
    let times = measure(20) { _ = try? yolo.prediction(from: input) }
    yoloTimes = times
    report("YOLO11n 640²", times)
}

// MARK: - Vision 全管线（不含 SigLIP/YOLO）

func visionAnalyze(_ cgImage: CGImage) -> String {
    let barcodes = VNDetectBarcodesRequest()
    let faces = VNDetectFaceRectanglesRequest()
    let pose = VNDetectHumanBodyPoseRequest()
    let segmentation = VNDetectDocumentSegmentationRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([barcodes, faces, pose, segmentation])
    let recognize = VNRecognizeTextRequest()
    recognize.recognitionLevel = .accurate
    recognize.usesLanguageCorrection = true
    recognize.recognitionLanguages = ["zh-Hans", "en-US"]
    try? handler.perform([recognize])
    return (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

let visionTimes = measure(12) { _ = visionAnalyze(synthetic) }
report("Vision full (OCR+detect)", visionTimes)

func ocrOnly(_ cgImage: CGImage) -> String {
    let recognize = VNRecognizeTextRequest()
    recognize.recognitionLevel = .accurate
    recognize.usesLanguageCorrection = true
    recognize.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([recognize])
    return (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}
let ocrTimes = measure(12) { _ = ocrOnly(synthetic) }
report("Vision OCR only (zh+en)", ocrTimes)

// 合成图 OCR 字符准确率（CER，忽略空白）
func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    var prev = Array(0...b.count)
    for i in 1...max(1, a.count) {
        var cur = [i] + [Int](repeating: 0, count: b.count)
        for j in 1...max(1, b.count) {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[b.count]
}
let truth = Array(ocrLines.joined().filter { !$0.isWhitespace })
let got = Array(ocrOnly(synthetic).filter { !$0.isWhitespace })
let dist = editDistance(got, truth)
let cer = Double(dist) / Double(max(1, truth.count))
print(String(format: "synthetic OCR: truth=%d chars, got=%d chars, edit=%d, CER=%.2f%%",
             truth.count, got.count, dist, cer * 100))
print("ocr text: \(ocrOnly(synthetic).replacingOccurrences(of: "\n", with: " | "))")

// MARK: - 解码（1200px 缩略图）

let tmpJPEG = FileManager.default.temporaryDirectory.appendingPathComponent("luma_bench_4032.jpg")
if !FileManager.default.fileExists(atPath: tmpJPEG.path) {
    let big = makeImage(width: 4032, height: 3024, text: ocrLines)
    let dest = CGImageDestinationCreateWithURL(tmpJPEG as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, big, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
let decodeTimes = measure(12) {
    guard let src = CGImageSourceCreateWithURL(tmpJPEG as CFURL, nil) else { return }
    _ = CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1200,
        kCGImageSourceCreateThumbnailWithTransform: true
    ] as CFDictionary)
}
report("decode 4032→1200px", decodeTimes)

print("\nserial per-photo estimate = decode + SigLIP + YOLO + Vision full")
let est = pct(decodeTimes, 0.5) + pct(imageTimes, 0.5)
    + (yoloTimes.isEmpty ? 0 : pct(yoloTimes, 0.5))
    + pct(visionTimes, 0.5)
print(String(format: "estimated p50 ≈ %.0f ms/photo (serial, synthetic, warm)", est))
