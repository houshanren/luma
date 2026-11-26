import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import LumaCore
import UniformTypeIdentifiers

/// RAW 专用解码：优先使用 Core Image 的 CIRAWFilter（可控制高光恢复与缩放），
/// 失败时回退到 ImageIO 的完整解码。
enum RawFormats {
    /// 扩展名白名单由 `ImportRules` 统一维护，导入判定与测试共用。
    static let extensions: Set<String> = ImportRules.rawExtensions

    static func isRaw(_ url: URL) -> Bool {
        isRaw(name: url.lastPathComponent)
    }

    static func isRaw(name: String) -> Bool {
        ImportRules.isRawExtension((name as NSString).pathExtension)
    }

    /// RAW 的 UTI（部分系统 UTI 未声明为 image，导入时单独放行）。
    static func importContentTypes() -> [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }

    private static let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    /// 用 RAW 流程生成 CIImage（供编辑器与查看器使用）。
    static func ciImage(url: URL, maxPixel: CGFloat? = nil) -> CIImage? {
        guard isRaw(url) else { return nil }
        if let filter = CIRAWFilter(imageURL: url) {
            if #available(macOS 26.0, *) {
                filter.isHighlightRecoveryEnabled = true
            }
            filter.isDraftModeEnabled = false
            if let orientation = exifOrientation(url: url) {
                filter.orientation = orientation
            }
            if let output = filter.outputImage {
                let extent = output.extent
                let longest = max(extent.width, extent.height)
                if let maxPixel, longest > maxPixel, longest > 0 {
                    let scale = maxPixel / longest
                    return output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
                return output
            }
        }
        return fallbackCIImage(url: url, maxPixel: maxPixel)
    }

    static func decode(url: URL, maxPixel: CGFloat? = nil) -> CGImage? {
        guard isRaw(url) else { return nil }
        if let image = ciImage(url: url, maxPixel: maxPixel) {
            let extent = image.extent.integral
            guard extent.width >= 1, extent.height >= 1 else { return nil }
            return context.createCGImage(image, from: extent)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let maxPixel {
            var thumbOptions = options
            thumbOptions[kCGImageSourceCreateThumbnailFromImageAlways] = true
            thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                return thumb
            }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    private static func fallbackCIImage(url: URL, maxPixel: CGFloat?) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        var image = CIImage(cgImage: cgImage)
        if let maxPixel {
            let longest = max(image.extent.width, image.extent.height)
            if longest > maxPixel, longest > 0 {
                let scale = maxPixel / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        return image
    }

    private static func exifOrientation(url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32 else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }
}
