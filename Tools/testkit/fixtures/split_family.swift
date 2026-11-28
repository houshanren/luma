// 拾光 Luma 测试集 · 全家福拆人
//
// 从一张「一家四口并排站立」的照片里，按横向区间拆出每个人，
// 用 Vision 人像分割去掉背景，裁掉透明边距后写成透明 PNG。
//
// 用法：
//   xcrun swiftc -O Tools/testkit/fixtures/split_family.swift -o /tmp/luma-split
//   /tmp/luma-split 全家福.jpg 输出目录 \
//       0.00 0.30 father  0.30 0.48 elder  0.51 0.67 mother  0.67 1.00 younger
//
// 整张图只分割一次，再按列拆；这样相邻的人互相有遮挡时，掩码也更准。
// 生成后建议确认每张 PNG 只有一张脸。

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let arguments = CommandLine.arguments
guard arguments.count >= 6, (arguments.count - 3) % 3 == 0 else {
    print("usage: split_family <in.jpg> <out-dir> <x0> <x1> <name> ...")
    exit(1)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("读取失败：\(inputURL.path)")
    exit(2)
}
let width = CGFloat(image.width)
let height = CGFloat(image.height)

// 1) 整张图做一次人像分割。
let request = VNGeneratePersonSegmentationRequest()
request.qualityLevel = .accurate
request.outputPixelFormat = kCVPixelFormatType_OneComponent8
do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
} catch {
    print("分割失败：\(error)")
    exit(3)
}
guard let result = request.results?.first else {
    print("没有分割出人像")
    exit(4)
}
let rawMask = CIImage(cvPixelBuffer: result.pixelBuffer)
// 2) 掩码放大到原图尺寸，并把浅色衣服的半透明值抬起来，避免人变得发白。
let mask = rawMask
    .transformed(by: CGAffineTransform(scaleX: width / rawMask.extent.width,
                                       y: height / rawMask.extent.height))
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 2.4, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 2.4, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 2.4, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
    ])
let context = CIContext()

for index in stride(from: 3, to: arguments.count, by: 3) {
    guard let x0 = Double(arguments[index]), let x1 = Double(arguments[index + 1]),
          x1 > x0 else {
        print("参数错误：\(arguments[index]) \(arguments[index + 1])")
        exit(5)
    }
    let name = arguments[index + 2]
    let rect = CGRect(x: (width * CGFloat(x0)).rounded(),
                      y: 0,
                      width: (width * CGFloat(x1 - x0)).rounded(),
                      height: height)
    guard let crop = image.cropping(to: rect) else {
        print("裁剪失败：\(name)")
        continue
    }
    // 掩码跟着裁同一条竖带，并移回原点。
    let maskCrop = mask
        .cropped(to: rect)
        .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    let clear = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: rect.size))
    let transparent = CIImage(cgImage: crop).applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: clear,
        kCIInputMaskImageKey: maskCrop
    ])
    guard let cutout = context.createCGImage(transparent, from: transparent.extent),
          let trimmed = trimAlpha(cutout) else {
        print("合成失败：\(name)")
        continue
    }
    let outputURL = outputDirectory.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("无法写入：\(outputURL.path)")
        continue
    }
    CGImageDestinationAddImage(destination, trimmed, nil)
    guard CGImageDestinationFinalize(destination) else {
        print("写入失败：\(name)")
        continue
    }
    print("\(name).png \(trimmed.width)x\(trimmed.height)")
}

/// 扫描 alpha 通道，返回裁到不透明范围的图像。
func trimAlpha(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let bitmap = CGContext(data: &pixels, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let cropped = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return image.cropping(to: cropped)
}
