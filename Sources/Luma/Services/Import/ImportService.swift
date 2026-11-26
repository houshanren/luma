import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage
import LumaCore
import PlaybackCore

enum ImportError: Error, LocalizedError {
    case unsupported
    /// 蓝光原盘导入失败：message 已经翻译成用户能照着处理的说明。
    case bluray(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "不支持的文件格式"
        case .bluray(let message):
            return message
        }
    }
}

enum ImportService {
    static func isSupported(_ url: URL) -> Bool {
        MediaTypeSupport.isSupportedImport(url)
    }

    /// 蓝光目录 / 光盘镜像：不复制原文件，只在图库里留一个引用。
    static func isBlurayDisc(_ url: URL) -> Bool {
        BluraySource.discRoot(for: url) != nil
    }

    static func importFile(_ url: URL) throws -> PhotoItem {
        LibraryPaths.prepare()
        // 原盘动辄几十 GB：不能拷进图库，直接引用外部路径，播放时交给 ffmpeg 的 bluray 协议。
        if let discRoot = BluraySource.discRoot(for: url) {
            return try blurayItem(root: discRoot)
        }
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
    private static var companionCache: [String: (stamp: Date?, files: [URL])] = [:]

    /// 查找与图片同名的实况照片视频（例如 IMG_1234.HEIC + IMG_1234.MOV）。
    /// 原生图库导入也复用它，把配对视频作为 `.pairedVideo` 一起写进「照片」。
    static func livePhotoCompanionURL(for imageURL: URL) -> URL? {
        livePhotoCompanion(for: imageURL)
    }

    private static func livePhotoCompanion(for imageURL: URL) -> URL? {
        ImportRules.livePhotoCompanion(for: imageURL,
                                       among: videoFiles(in: imageURL.deletingLastPathComponent()))
    }

    private static func videoFiles(in directory: URL) -> [URL] {
        let key = directory.path
        let stamp = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        companionLock.lock()
        if let cached = companionCache[key], cached.stamp == stamp {
            companionLock.unlock()
            return cached.files
        }
        companionLock.unlock()

        var files: [URL] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            files = contents.filter { VideoFormats.isVideo($0) }
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

        let originalDate = EXIFDate.parse(
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
        let digitizedDate = EXIFDate.parse(
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
        if let date = originalDate ?? digitizedDate {
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

    /// 蓝光原盘条目：`filename` 为空（originals 里没有副本），源路径写在 `externalPath`。
    /// 时长 / 分辨率通过 ffprobe 的 bluray 协议读取；读不到时把 ffprobe 的报错
    /// （AACS / BD+ / 非蓝光目录）翻译成可执行提示，而不是笼统的「导入失败」。
    private static func blurayItem(root: URL) throws -> PhotoItem {
        let result = VideoSupport.blurayProbe(root: root)
        guard result.probe.hasVideoTrack || result.probe.duration > 0 else {
            throw ImportError.bluray(blurayEncryptionNote(root: root)
                                     ?? blurayFailureMessage(result.error))
        }
        let probe = result.probe
        let id = UUID()
        let values = try? root.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        var item = PhotoItem(filename: "",
                             originalName: root.lastPathComponent.isEmpty ? "蓝光原盘" : root.lastPathComponent,
                             capturedAt: values?.creationDate ?? Date(),
                             pixelWidth: 0, pixelHeight: 0,
                             fileSize: Int64(values?.fileSize ?? 0),
                             kind: .video)
        item.id = id
        item.externalPath = root.path
        item.pixelWidth = Int(probe.size.width)
        item.pixelHeight = Int(probe.size.height)
        if probe.duration > 0 { item.duration = probe.duration }
        return item
    }

    /// 加密标记优先于日志文案：AACS 目录 / BD+ 虚拟机会话即使 ffprobe 只报通用错误，
    /// 也能确定是加密盘，直接给出「先解密」的处理方式。
    private static func blurayEncryptionNote(root: URL) -> String? {
        let fm = FileManager.default
        return ImportRules.blurayEncryptionMessage(
            hasAACS: fm.fileExists(atPath: root.appendingPathComponent("AACS").path),
            hasBDSVM: fm.fileExists(atPath: root.appendingPathComponent("BDSVM").path))
    }

    /// 把 ffprobe 的英文报错翻译成明确文案：加密盘要说清「为什么打不开、怎么办」，
    /// 不能只回一句「导入失败」。
    private static func blurayFailureMessage(_ raw: String) -> String {
        ImportRules.blurayFailureMessage(raw)
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
        switch ImportRules.classify(fileName: name, pixelWidth: width, pixelHeight: height) {
        case .photo: return .photo
        case .video: return .video
        case .screenshot: return .screenshot
        case .panorama: return .panorama
        case .selfie: return .selfie
        }
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
            .appendingPathComponent("luma-preview-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temp) }
        makeVideoThumbnail(url: url, destination: temp)
        return NSImage(contentsOf: temp)
    }
}
