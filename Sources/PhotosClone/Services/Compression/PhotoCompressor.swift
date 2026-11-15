import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct CompressionSettings: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case original
        case jpeg
        case heic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return "保持原格式"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            }
        }
    }

    var quality: Double = 0.8
    var maxDimension: Int = 0
    var format: Format = .original
    var preserveMetadata = true
    var onlyIfSmaller = true
    var keepBackup = false
}

struct CompressionEstimate: Identifiable {
    let photoID: UUID
    let originalBytes: Int64
    let estimatedBytes: Int64
    let width: Int
    let height: Int
    let isSupported: Bool
    let note: String?

    var id: UUID { photoID }

    var savings: Int64 { max(0, originalBytes - estimatedBytes) }

    var savingsRatio: Double {
        guard originalBytes > 0 else { return 0 }
        return Double(savings) / Double(originalBytes)
    }
}

struct CompressionResult {
    let skipped: Bool
    let savedBytes: Int64
    let bytes: Int64
    let width: Int
    let height: Int
    let filename: String
    let note: String?
}

struct CompressionRestoreResult {
    let filename: String
    let bytes: Int64
    let width: Int
    let height: Int
}

struct CompressionProgress {
    var total: Int = 0
    var completed: Int = 0
    var currentName: String = ""
    var savedBytes: Int64 = 0
    var compressed: Int = 0
    var skipped: Int = 0
    var failed: Int = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

enum CompressionError: LocalizedError {
    case missingFile
    case unreadable
    case unsupported(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingFile: return "原始文件不存在"
        case .unreadable: return "无法读取照片"
        case .unsupported(let reason): return reason
        case .encodingFailed: return "压缩编码失败"
        }
    }
}

// MARK: - 压缩引擎

enum PhotoCompressor {
    private static let supportedOriginalTypes: Set<String> = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.heic.identifier,
        UTType("public.heif")?.identifier ?? "public.heif",
        UTType.tiff.identifier,
        UTType.bmp.identifier
    ]

    static func backupDirectory(for photo: PhotoItem) -> URL {
        LibraryPaths.backups.appendingPathComponent(photo.id.uuidString, isDirectory: true)
    }

    static func hasBackup(for photo: PhotoItem) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: backupDirectory(for: photo).path) else {
            return false
        }
        return !items.isEmpty
    }

    static func estimate(photo: PhotoItem, settings: CompressionSettings) -> CompressionEstimate {
        let url = LibraryPaths.originalURL(for: photo)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            ?? photo.fileSize

        func unsupported(_ note: String) -> CompressionEstimate {
            CompressionEstimate(photoID: photo.id, originalBytes: fileSize, estimatedBytes: fileSize,
                                width: photo.pixelWidth, height: photo.pixelHeight,
                                isSupported: false, note: note)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return unsupported("原始文件不存在")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return unsupported("无法读取图片")
        }
        if CGImageSourceGetCount(source) > 1 {
            return unsupported("动图暂不支持压缩")
        }
        guard let type = destinationType(source: source, settings: settings) else {
            return unsupported(settings.format == .original ? "该格式需选择 JPEG 或 HEIC" : "无法确定输出格式")
        }
        guard let encoded = encode(source: source, settings: settings, type: type) else {
            return unsupported("编码失败，可能是不支持的图片格式")
        }

        var note: String?
        if type == .png, settings.maxDimension == 0 {
            note = "PNG 为无损格式，未缩放时体积可能不会减小"
        }
        return CompressionEstimate(photoID: photo.id,
                                   originalBytes: fileSize,
                                   estimatedBytes: Int64(encoded.data.count),
                                   width: encoded.width,
                                   height: encoded.height,
                                   isSupported: true,
                                   note: note)
    }

    static func compress(photo: PhotoItem, settings: CompressionSettings) throws -> CompressionResult {
        let fm = FileManager.default
        let originalURL = LibraryPaths.originalURL(for: photo)
        guard fm.fileExists(atPath: originalURL.path) else { throw CompressionError.missingFile }
        guard let originalSize = (try? fm.attributesOfItem(atPath: originalURL.path)[.size] as? NSNumber)?.int64Value else {
            throw CompressionError.unreadable
        }
        guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil) else {
            throw CompressionError.unreadable
        }
        if CGImageSourceGetCount(source) > 1 {
            throw CompressionError.unsupported("动图暂不支持压缩")
        }
        guard let type = destinationType(source: source, settings: settings) else {
            throw CompressionError.unsupported(settings.format == .original
                ? "该格式需选择 JPEG 或 HEIC"
                : "无法确定输出格式")
        }
        guard let encoded = encode(source: source, settings: settings, type: type) else {
            throw CompressionError.encodingFailed
        }

        let newSize = Int64(encoded.data.count)
        if settings.onlyIfSmaller, newSize >= originalSize {
            return CompressionResult(skipped: true, savedBytes: 0, bytes: originalSize,
                                     width: photo.pixelWidth, height: photo.pixelHeight,
                                     filename: photo.filename, note: "未产生更小的文件，已跳过")
        }

        if settings.keepBackup {
            let directory = backupDirectory(for: photo)
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let backupURL = directory.appendingPathComponent(photo.filename)
            if !fm.fileExists(atPath: backupURL.path) {
                try? fm.copyItem(at: originalURL, to: backupURL)
            }
        }

        let ext = type.preferredFilenameExtension ?? originalURL.pathExtension
        let filename = photo.id.uuidString + "." + ext
        let targetURL = LibraryPaths.originals
            .appendingPathComponent(LibraryPaths.shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(filename)
        try? fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let tempURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(".compress-\(UUID().uuidString).\(ext)")
        try encoded.data.write(to: tempURL)

        let attributes = (try? fm.attributesOfItem(atPath: originalURL.path)) ?? [:]
        let creationDate = attributes[.creationDate] as? Date
        let modificationDate = attributes[.modificationDate] as? Date

        if filename == photo.filename {
            _ = try fm.replaceItemAt(originalURL, withItemAt: tempURL)
            setDates(creationDate, modificationDate, at: originalURL)
        } else {
            try? fm.removeItem(at: originalURL)
            try fm.moveItem(at: tempURL, to: targetURL)
            setDates(creationDate, modificationDate, at: targetURL)
        }

        return CompressionResult(skipped: false,
                                 savedBytes: originalSize - newSize,
                                 bytes: newSize,
                                 width: encoded.width,
                                 height: encoded.height,
                                 filename: filename,
                                 note: nil)
    }

    static func restoreBackup(for photo: PhotoItem) -> CompressionRestoreResult? {
        let fm = FileManager.default
        let directory = backupDirectory(for: photo)
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path),
              let name = names.first(where: { !$0.hasPrefix(".") }) else { return nil }
        let backupURL = directory.appendingPathComponent(name)
        let targetURL = LibraryPaths.originals
            .appendingPathComponent(LibraryPaths.shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(name)
        try? fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let currentURL = LibraryPaths.originalURL(for: photo)
        if currentURL.standardizedFileURL.path != targetURL.standardizedFileURL.path {
            try? fm.removeItem(at: currentURL)
        }
        try? fm.removeItem(at: targetURL)
        do {
            try fm.copyItem(at: backupURL, to: targetURL)
        } catch {
            return nil
        }

        let size = (try? fm.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let dims = ImageLoader.sourcePixelSize(url: targetURL)
        try? fm.removeItem(at: directory)
        return CompressionRestoreResult(filename: name,
                                        bytes: size,
                                        width: Int(dims?.width ?? 0),
                                        height: Int(dims?.height ?? 0))
    }

    // MARK: 编码

    private struct EncodedImage {
        let data: Data
        let width: Int
        let height: Int
        let type: UTType
    }

    private static func destinationType(source: CGImageSource,
                                        settings: CompressionSettings) -> UTType? {
        switch settings.format {
        case .jpeg:
            return .jpeg
        case .heic:
            return .heic
        case .original:
            guard let identifier = CGImageSourceGetType(source) as String?,
                  let type = UTType(identifier),
                  supportedOriginalTypes.contains(type.identifier) else { return nil }
            return type
        }
    }

    private static func encode(source: CGImageSource,
                               settings: CompressionSettings,
                               type: UTType) -> EncodedImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxPixel = settings.maxDimension > 0
            ? settings.maxDimension
            : max(sourceWidth, sourceHeight)

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if maxPixel > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = type == .jpeg ? flattenAlpha(cgImage) : cgImage

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,
                                                                 type.identifier as CFString, 1, nil) else {
            return nil
        }

        var outputProperties: [CFString: Any] = [:]
        if settings.preserveMetadata, let properties {
            outputProperties = properties
        }
        outputProperties[kCGImagePropertyOrientation] = 1
        outputProperties[kCGImagePropertyPixelWidth] = image.width
        outputProperties[kCGImagePropertyPixelHeight] = image.height
        outputProperties[kCGImageDestinationLossyCompressionQuality] = settings.quality

        CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return EncodedImage(data: data as Data, width: image.width, height: image.height, type: type)
    }

    private static func flattenAlpha(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .premultipliedLast, .premultipliedFirst, .last, .first:
            break
        default:
            return image
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func setDates(_ creation: Date?, _ modification: Date?, at url: URL) {
        guard creation != nil || modification != nil else { return }
        var attributes: [FileAttributeKey: Any] = [:]
        if let creation { attributes[.creationDate] = creation }
        if let modification { attributes[.modificationDate] = modification }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
