import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage

enum ImportError: Error {
    case unsupported
}

enum ImportService {
    static func isSupported(_ url: URL) -> Bool {
        if VideoFormats.isVideo(url) { return true }
        if RawFormats.isRaw(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    static func importFile(_ url: URL) throws -> PhotoItem {
        LibraryPaths.prepare()
        let isVideo = VideoFormats.isVideo(url)
        guard isVideo || isSupported(url) else {
            throw ImportError.unsupported
        }
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? (isVideo ? "mov" : "jpg") : url.pathExtension.lowercased()
        let filename = "\(id.uuidString).\(ext)"
        let destination = LibraryPaths.originals
            .appendingPathComponent(LibraryPaths.shard(for: id), isDirectory: true)
            .appendingPathComponent(filename)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: destination)

        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let fileSize = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? resourceValues?.fileSize ?? 0)
        let fallbackDate = resourceValues?.creationDate ?? Date()

        var item: PhotoItem
        if isVideo {
            item = videoItem(url: url, destination: destination, id: id, filename: filename,
                             fileSize: fileSize, fallbackDate: fallbackDate)
        } else {
            item = imageItem(url: url, id: id, filename: filename,
                             fileSize: fileSize, fallbackDate: fallbackDate)
            // 自动配对实况照片：同目录同名的 MOV/MP4 一起拷贝为配对视频。
            if let companion = livePhotoCompanion(for: url) {
                let liveFilename = "\(id.uuidString).\(companion.pathExtension.lowercased())"
                let liveDestination = destination.deletingLastPathComponent()
                    .appendingPathComponent(liveFilename)
                if (try? FileManager.default.copyItem(at: companion, to: liveDestination)) != nil {
                    item.isLivePhoto = true
                    item.livePhotoFilename = liveFilename
                }
            }
        }
        generateThumbnail(for: item)
        return item
    }

    /// 同目录视频索引缓存：批量导入同一文件夹时避免每张照片都重新列目录。
    private static let companionLock = NSLock()
    private static var companionCache: [String: (stamp: Date?, files: [String: URL])] = [:]

    /// 查找与图片同名的实况照片视频（例如 IMG_1234.HEIC + IMG_1234.MOV）。
    private static func livePhotoCompanion(for imageURL: URL) -> URL? {
        let directory = imageURL.deletingLastPathComponent()
        let stem = imageURL.deletingPathExtension().lastPathComponent.lowercased()
        return videoFilesByStem(in: directory)[stem]
    }

    private static func videoFilesByStem(in directory: URL) -> [String: URL] {
        let key = directory.path
        let stamp = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        companionLock.lock()
        if let cached = companionCache[key], cached.stamp == stamp {
            companionLock.unlock()
            return cached.files
        }
        companionLock.unlock()

        var files: [String: URL] = [:]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for file in contents where VideoFormats.isVideo(file) {
                let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                if files[stem] == nil { files[stem] = file }
            }
        }
        companionLock.lock()
        companionCache[key] = (stamp, files)
        companionLock.unlock()
        return files
    }

    private static func imageItem(url: URL, id: UUID, filename: String,
                                  fileSize: Int64, fallbackDate: Date) -> PhotoItem {
        var item = PhotoItem(filename: filename, originalName: url.lastPathComponent,
                             capturedAt: fallbackDate, pixelWidth: 0, pixelHeight: 0,
                             fileSize: fileSize)
        item.id = id

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return item
        }
        item.pixelWidth = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        item.pixelHeight = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        if let date = exifDate(exif) {
            item.capturedAt = date
        }

        item.make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        item.model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        item.lens = (exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespaces)

        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double {
            item.focalLength = String(format: "%.0f mm", focal)
        }
        if let fnumber = exif?[kCGImagePropertyExifFNumber] as? Double {
            item.aperture = String(format: "ƒ/%.1f", fnumber)
        }
        if let exposure = exif?[kCGImagePropertyExifExposureTime] as? Double {
            if exposure <= 0 {
                item.shutterSpeed = nil
            } else if exposure < 1 {
                item.shutterSpeed = String(format: "1/%d 秒", Int((1 / exposure).rounded()))
            } else {
                item.shutterSpeed = String(format: "%.1f 秒", exposure)
            }
        }
        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
            item.iso = "\(first)"
        } else if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            item.iso = "\(iso)"
        }

        if let gps {
            let lat = gps[kCGImagePropertyGPSLatitude] as? Double
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
            let lon = gps[kCGImagePropertyGPSLongitude] as? Double
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
            if let lat, let lon {
                let latitude = latRef == "S" ? -lat : lat
                let longitude = lonRef == "W" ? -lon : lon
                if CoordinateValidator.isValid(latitude: latitude, longitude: longitude) {
                    item.latitude = latitude
                    item.longitude = longitude
                }
            }
        }

        item.kind = detectKind(name: url.lastPathComponent,
                               width: item.pixelWidth, height: item.pixelHeight)
        return item
    }

    private static func videoItem(url: URL, destination: URL, id: UUID, filename: String,
                                  fileSize: Int64, fallbackDate: Date) -> PhotoItem {
        var item = PhotoItem(filename: filename, originalName: url.lastPathComponent,
                             capturedAt: fallbackDate, pixelWidth: 0, pixelHeight: 0,
                             fileSize: fileSize, kind: .video)
        item.id = id
        let probe = VideoSupport.quickMetadata(url: destination)
        item.pixelWidth = Int(probe.size.width)
        item.pixelHeight = Int(probe.size.height)
        if probe.duration > 0 {
            item.duration = probe.duration
        }
        let asset = AVURLAsset(url: destination)
        if let date = asset.creationDate?.dateValue {
            item.capturedAt = date
        }
        return item
    }

    private static func detectKind(name: String, width: Int, height: Int) -> MediaKind {
        let lower = name.lowercased()
        if lower.contains("screenshot") || lower.contains("screen shot")
            || lower.contains("截屏") || lower.contains("屏幕快照") {
            return .screenshot
        }
        if width > 0, height > 0, CGFloat(width) / CGFloat(height) >= 2.2 {
            return .panorama
        }
        if lower.contains("selfie") || lower.contains("自拍") {
            return .selfie
        }
        return .photo
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func exifDate(_ exif: [CFString: Any]?) -> Date? {
        let candidates = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized]
        for key in candidates {
            if let string = exif?[key] as? String, let date = exifDateFormatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    static func generateThumbnail(for photo: PhotoItem) {
        let sourceURL = LibraryPaths.sourceURL(for: photo)
        let targetURL = LibraryPaths.thumbnailURL(for: photo)
        if photo.isVideo {
            makeVideoThumbnail(url: sourceURL, destination: targetURL)
        } else {
            makeImageThumbnail(url: sourceURL, destination: targetURL, rotation: photo.rotationAngle)
        }
        makeQuickThumbnail(for: photo, from: targetURL)
    }

    /// 从主缩略图生成快速层小文件（192px），网格滚动时直接读小图。
    static func makeQuickThumbnail(for photo: PhotoItem, from thumbnailURL: URL) {
        guard let source = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ImageLoader.gridQuickPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let quick = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
        writeJPEG(quick, to: LibraryPaths.quickThumbnailURL(for: photo), quality: 0.75)
    }

    static func makeImageThumbnail(url: URL, destination: URL, maxPixel: Int = 1200, rotation: Int = 0) {
        var thumbnail: CGImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        // RAW 若缺少可用内嵌预览，走专用解码。
        if thumbnail == nil, RawFormats.isRaw(url) {
            thumbnail = RawFormats.decode(url: url, maxPixel: CGFloat(maxPixel))
        }
        guard let thumbnail else { return }
        let image = ImageTransform.rotate(thumbnail, degrees: rotation) ?? thumbnail
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        writeJPEG(image, to: destination, quality: 0.9)
    }

    static func makeVideoThumbnail(url: URL, destination: URL) {
        VideoSupport.makeThumbnail(url: url, destination: destination)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat = 0.92) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // 先编码到内存，再原子替换目标文件：网格与内容识别线程可能同时在读同一张缩略图，
        // 直接写目标路径会让它们读到写了一半的 JPEG。
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
        // 写入成功即登记到缩略图索引，网格读取时不再对每个格子做磁盘 stat。
        ThumbnailFileIndex.shared.recordWrite(url: url)
    }

    /// 导入窗口的预览缩略图：视频走临时帧，图片直接快速解码。
    static func previewThumbnail(url: URL, isMovie: Bool, maxPixel: CGFloat = 220) -> NSImage? {
        guard isMovie else {
            return ImageLoader.quickThumbnail(url: url, maxPixel: maxPixel)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("photosclone-preview-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temp) }
        makeVideoThumbnail(url: url, destination: temp)
        return NSImage(contentsOf: temp)
    }
}
