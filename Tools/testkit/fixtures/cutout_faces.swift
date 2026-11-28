// 拾光 Luma 测试集 · 人像抠图
//
// 用 Vision 的人像分割把「一家四口」的参考照片裁成透明背景 PNG，
// 供 generate_images.swift 叠加到合成的旅行 / 生活场景里。
//
// 用法：
//   xcrun swiftc -O Tools/testkit/fixtures/cutout_faces.swift -o /tmp/luma-cutout
//   /tmp/luma-cutout <in.jpg> <out.png>

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: cutout_faces <in.jpg> <out.png>")
    exit(1)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("读取失败：\(inputURL.path)")
    exit(2)
}

let request = VNGeneratePersonSegmentationRequest()
request.qualityLevel = .accurate
request.outputPixelFormat = kCVPixelFormatType_OneComponent8
let handler = VNImageRequestHandler(cgImage: image, options: [:])
do {
    try handler.perform([request])
} catch {
    print("人像分割失败：\(error)")
    exit(3)
}
guard let result = request.results?.first else {
    print("没有分割出人像：\(inputURL.lastPathComponent)")
    exit(4)
}

let maskImage = CIImage(cvPixelBuffer: result.pixelBuffer)
let scaleX = CGFloat(image.width) / maskImage.extent.width
let scaleY = CGFloat(image.height) / maskImage.extent.height
let mask = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

let clear = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0,
                                                      width: image.width, height: image.height))
let transparent = CIImage(cgImage: image).applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: clear,
    kCIInputMaskImageKey: mask
])

let context = CIContext()
guard let cutout = context.createCGImage(transparent, from: transparent.extent) else {
    print("合成失败")
    exit(5)
}

// 裁掉透明边距，保证后续按身高缩放时人物高度准确。
guard let trimmed = trimAlpha(cutout) else {
    print("没有找到不透明像素")
    exit(6)
}
guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil) else {
    print("无法写入：\(outputURL.path)")
    exit(7)
}
CGImageDestinationAddImage(destination, trimmed, nil)
guard CGImageDestinationFinalize(destination) else {
    print("写入失败")
    exit(8)
}
print("已生成 \(outputURL.lastPathComponent)（\(trimmed.width)x\(trimmed.height)）")

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
    // 上下各留一点余量，避免贴边。
    let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return image.cropping(to: rect)
}
