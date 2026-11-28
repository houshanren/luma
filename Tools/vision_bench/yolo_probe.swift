// YOLO11n 边际贡献探针：在已人工标注的缩略图上跑内置 YOLO，看它相对 SigLIP 多给了什么。
//
// 用途：回答「YOLO 要不要升级 / 要不要保留」。
// 结论（2026-11-28，39 张）：YOLO 命中 22 个标签全部已被 SigLIP 覆盖，新增正确 0 个、
// 新增错误 12 个；无条件合入把接受率 0.840 拉到 0.769，门控 < 2 后为 0.827。
// 因此 App 侧也把 YOLO 改成「仅 SigLIP 标签 < 2 时补」（见 PhotoIntelligence.swift）。
//
// 编译（仓库根目录）：
//   swiftc -O Tools/vision_bench/yolo_probe.swift -o /tmp/yolo_probe \
//     -framework CoreML -framework AppKit -framework ImageIO -framework CoreVideo -framework Foundation
//
// 运行：
//   /tmp/yolo_probe docs/ai/goldset-40/images
// 输出每行 `<id>.jpg<TAB>标签1,标签2`，最后一行是耗时。
//
// 注意：COCO 类名与中文映射是 Sources/Luma/Services/Media/ObjectDetector.swift 的镜像，
// 改一边必须同步另一边，否则离线结论会与 App 行为不一致。

import AppKit
import CoreML
import CoreVideo
import Foundation
import ImageIO

let modelPath = "Resources/Models/YOLO11n/YOLO11n.mlmodelc"
let imagesDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/ai/goldset-40/images"

let cocoClasses: [String] = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
    "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
    "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
    "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
    "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
    "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
]

let mapping: [String: String] = [
    "person": "人物",
    "bicycle": "自行车", "car": "汽车", "motorcycle": "摩托车", "airplane": "飞机",
    "bus": "公交车", "train": "火车", "truck": "汽车", "boat": "船",
    "bird": "鸟", "cat": "猫", "dog": "狗", "horse": "马", "sheep": "羊", "cow": "牛",
    "elephant": "大象", "bear": "野生动物", "zebra": "野生动物", "giraffe": "野生动物",
    "backpack": "包包", "umbrella": "雨伞", "handbag": "包包", "tie": "衣服", "suitcase": "包包",
    "frisbee": "运动器材", "skis": "运动器材", "snowboard": "运动器材", "sports ball": "运动器材",
    "kite": "玩具", "baseball bat": "运动器材", "baseball glove": "运动器材",
    "skateboard": "运动器材", "surfboard": "运动器材", "tennis racket": "运动器材",
    "bottle": "瓶子", "wine glass": "杯子", "cup": "杯子", "fork": "餐具", "knife": "餐具",
    "spoon": "餐具", "bowl": "餐具",
    "banana": "水果", "apple": "水果", "sandwich": "美食", "orange": "水果",
    "broccoli": "蔬菜", "carrot": "蔬菜", "hot dog": "美食", "pizza": "披萨",
    "donut": "甜点", "cake": "蛋糕",
    "chair": "家具", "couch": "家具", "potted plant": "盆栽", "bed": "家具", "dining table": "家具",
    "laptop": "电脑", "mouse": "电脑", "keyboard": "电脑", "cell phone": "手机",
    "book": "书本", "teddy bear": "玩具"
]

/// 与 ImageTensor.make 一致：NCHW、RGB、0…255，不经过 Core ML 的 ImageType 归一化。
func makeTensor(_ image: CGImage, size: Int) -> MLMultiArray? {
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                              attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let pixelBuffer = buffer,
          let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
                                        dataType: .float32) else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                  width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
          let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.bindMemory(to: UInt8.self,
                                                                        capacity: size * size * 4) else {
        return nil
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let plane = size * size
    let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: plane * 3)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<size {
        for x in 0..<size {
            let source = y * stride + x * 4
            let target = y * size + x
            pointer[target] = Float(base[source + 2])
            pointer[plane + target] = Float(base[source + 1])
            pointer[plane * 2 + target] = Float(base[source])
        }
    }
    return array
}

func decode(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

guard let model = try? MLModel(contentsOf: URL(fileURLWithPath: modelPath),
                               configuration: MLModelConfiguration()) else {
    print("FAIL load model")
    exit(2)
}

let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir))?
    .filter { $0.hasSuffix(".jpg") }.sorted() ?? []
var seconds: [Double] = []
for name in files {
    let path = imagesDir + "/" + name
    guard let image = decode(path), let tensor = makeTensor(image, size: 640) else {
        print("\(name)\tDECODE_FAIL")
        continue
    }
    let started = Date()
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(multiArray: tensor),
        "iouThreshold": MLFeatureValue(double: 0.5),
        "confidenceThreshold": MLFeatureValue(double: 0.4)
    ])
    guard let output = try? model.prediction(from: input),
          let confidence = output.featureValue(for: "confidence")?.multiArrayValue,
          let coordinates = output.featureValue(for: "coordinates")?.multiArrayValue else {
        print("\(name)\tPREDICT_FAIL")
        continue
    }
    seconds.append(Date().timeIntervalSince(started))
    let rows = confidence.shape.first?.intValue ?? 0
    let classes = confidence.shape.count > 1 ? confidence.shape[1].intValue : 0
    var titles: [String] = []
    for row in 0..<rows {
        var bestClass = -1
        var bestScore: Float = 0
        for column in 0..<classes {
            let value = confidence[[NSNumber(value: row), NSNumber(value: column)]].floatValue
            if value > bestScore { bestScore = value; bestClass = column }
        }
        guard bestClass >= 0, bestScore >= 0.4, bestClass < cocoClasses.count else { continue }
        if coordinates.shape.count > 1, coordinates.shape[1].intValue >= 4 {
            let area = coordinates[[NSNumber(value: row), NSNumber(value: 2)]].doubleValue
                * coordinates[[NSNumber(value: row), NSNumber(value: 3)]].doubleValue
            if area < 0.01 { continue }
        }
        guard let title = mapping[cocoClasses[bestClass]] else { continue }
        if !titles.contains(title) { titles.append(title) }
        if titles.count >= 4 { break }
    }
    print("\(name)\t" + titles.joined(separator: ","))
}
seconds.sort()
if !seconds.isEmpty {
    let median = seconds[seconds.count / 2] * 1000
    let worst = (seconds.last ?? 0) * 1000
    print(String(format: "TIMING\tmedian=%.1fms\tmax=%.1fms\tn=%d", median, worst, seconds.count))
}
