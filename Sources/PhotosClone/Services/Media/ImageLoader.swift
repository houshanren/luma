import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage
import LumaCore

enum ImageLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // 双层网格缩略图（快速层 + 目标层）会同时驻留，上限相应放宽。
        cache.totalCostLimit = 384 * 1024 * 1024
        return cache
    }()

    private static let fullCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()

    private static func store(_ image: NSImage, forKey key: NSString) {
        let rep = image.representations.first
        let width = rep?.pixelsWide ?? Int(image.size.width)
        let height = rep?.pixelsHigh ?? Int(image.size.height)
        cache.setObject(image, forKey: key, cost: max(1, width * height * 4))
    }

    static func thumbnail(for photo: PhotoItem) -> NSImage? {
        let key = photo.cacheKey as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if photo.isCloud {
            guard let mountID = photo.cloudMountID, let path = photo.cloudPath else { return nil }
            let url = CloudPaths.thumbnailURL(mountID: mountID, path: path)
            guard let image = NSImage(contentsOf: url) else { return nil }
            store(image, forKey: key)
            return image
        }

        if photo.isSystem {
            let thumbnailURL = LibraryPaths.thumbnailURL(for: photo)
            if let image = NSImage(contentsOf: thumbnailURL) {
                store(image, forKey: key)
                return image
            }
            let destination = LibraryPaths.systemThumbs.appendingPathComponent(photo.id.uuidString + ".jpg")
            generateSystemThumbnail(for: photo, destination: destination)
            guard let image = NSImage(contentsOf: destination) else { return nil }
            store(image, forKey: key)
            return image
        }

        let url = LibraryPaths.thumbnailURL(for: photo)
        guard let image = NSImage(contentsOf: url) else { return nil }
        store(image, forKey: key)
        return image
    }

    /// 网格缩略图：按格子实际像素尺寸解码，避免为小格子解码并常驻 1200px 大图。
    /// 解码尺寸会向上取整到固定档位，档位相同的格子共用同一份缓存。
    /// 快速层（≤192px）优先读独立小文件，缺失或主缩略图更新后由主图重建。
    static func gridThumbnail(for photo: PhotoItem, maxPixel: CGFloat) -> NSImage? {
        let bucket = pixelBucket(for: maxPixel)
        let key = "\(bucket)|\(photo.cacheKey)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let mainURL = thumbnailSourceURL(for: photo) else { return nil }

        if bucket <= gridQuickPixel {
            if !photo.isCloud,
               let quickURL = freshQuickThumbnailURL(for: photo, mainURL: mainURL),
               let image = decodeThumbnail(at: quickURL, maxPixel: CGFloat(bucket)) {
                store(image, forKey: key)
                return image
            }
            guard let image = decodeThumbnail(at: mainURL, maxPixel: CGFloat(bucket)) else { return nil }
            store(image, forKey: key)
            if !photo.isCloud {
                writeQuickThumbnail(from: image, for: photo)
            }
            return image
        }

        guard let image = decodeThumbnail(at: mainURL, maxPixel: CGFloat(bucket)) else { return nil }
        store(image, forKey: key)
        return image
    }

    /// 快速层文件存在且不早于主缩略图时返回其路径（主图更新后视为过期）。
    private static func freshQuickThumbnailURL(for photo: PhotoItem, mainURL: URL) -> URL? {
        let fm = FileManager.default
        let quickURL = LibraryPaths.quickThumbnailURL(for: photo)
        guard let quickDate = (try? fm.attributesOfItem(atPath: quickURL.path))?[.modificationDate] as? Date,
              let mainDate = (try? fm.attributesOfItem(atPath: mainURL.path))?[.modificationDate] as? Date,
              quickDate >= mainDate else { return nil }
        return quickURL
    }

    /// 生成快速层小文件（后台写入，不阻塞当前格子显示）。
    private static func writeQuickThumbnail(from image: NSImage, for photo: PhotoItem) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let quick = ImageTransform.downscale(cgImage, maxPixel: gridQuickPixel),
              let data = jpegData(quick, quality: 0.75) else { return }
        let url = LibraryPaths.quickThumbnailURL(for: photo)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 档位策略由 LumaCore 统一定义，这里只做转发。
    private static var gridPixelBuckets: [Int] { ThumbnailSizing.buckets }

    /// 网格快速层：先用这一档位出图，滚动时立即可见，随后替换为目标档位。
    static let gridQuickPixel = ThumbnailSizing.quickPixel

    static func pixelBucket(for maxPixel: CGFloat) -> Int {
        ThumbnailSizing.bucket(for: maxPixel)
    }

    static func cachedGridImage(for photo: PhotoItem, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: "\(pixelBucket(for: maxPixel))|\(photo.cacheKey)" as NSString)
    }

    /// 缩略图磁盘位置；系统图库缺失时按需生成。
    private static func thumbnailSourceURL(for photo: PhotoItem) -> URL? {
        let url: URL
        if photo.isCloud {
            guard let mountID = photo.cloudMountID, let path = photo.cloudPath else { return nil }
            url = CloudPaths.thumbnailURL(mountID: mountID, path: path)
        } else if photo.isSystem {
            let existing = LibraryPaths.thumbnailURL(for: photo)
            if FileManager.default.fileExists(atPath: existing.path) { return existing }
            let destination = LibraryPaths.systemThumbs.appendingPathComponent(photo.id.uuidString + ".jpg")
            generateSystemThumbnail(for: photo, destination: destination)
            url = destination
        } else {
            url = LibraryPaths.thumbnailURL(for: photo)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 系统图库没有现成 derivative 时，从原图 / 视频现场生成缩略图。
    /// 网格滚动会同时请求很多格子，这里限制并发并按目标文件去重，避免几十个大图解码同时抢 CPU 与磁盘。
    private static func generateSystemThumbnail(for photo: PhotoItem, destination: URL) {
        let key = destination.path
        switch ThumbnailGenerationGate.shared.checkout(key) {
        case .duplicate, .throttled:
            // 已有任务在生成同一个文件（或并发已满）：本次直接跳过，稍后重新请求即可命中。
            return
        case .granted:
            defer { ThumbnailGenerationGate.shared.finish(key) }
            if photo.isVideo {
                ImportService.makeVideoThumbnail(url: LibraryPaths.sourceURL(for: photo), destination: destination)
            } else {
                ImportService.makeImageThumbnail(url: LibraryPaths.sourceURL(for: photo),
                                                 destination: destination,
                                                 rotation: photo.rotationAngle)
            }
        }
    }

    private static func decodeThumbnail(at url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static let displayCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    private static func displayKey(for photo: PhotoItem, maxPixel: CGFloat, sdr: Bool) -> NSString {
        "\(photo.cacheKey)-display-\(Int(maxPixel))\(sdr ? "-sdr" : "")" as NSString
    }

    /// 查看器显示图：解码结果写入内存缓存，回翻或连翻时不重复解码。
    /// `sdr` 为 true 时在调用线程完成 8 位 sRGB 转换，调用方需放到后台执行。
    static func displayImage(for photo: PhotoItem, maxPixel: CGFloat = 2600, sdr: Bool = false) -> NSImage? {
        let key = displayKey(for: photo, maxPixel: maxPixel, sdr: sdr)
        if let cached = displayCache.object(forKey: key) {
            return cached
        }
        guard let decoded = decodeDisplayImage(for: photo, maxPixel: maxPixel) else { return nil }
        let result = sdr ? sdrImage(decoded) : decoded
        let rep = result.representations.first
        let width = rep?.pixelsWide ?? Int(result.size.width)
        let height = rep?.pixelsHigh ?? Int(result.size.height)
        displayCache.setObject(result, forKey: key, cost: max(1, width * height * 4))
        return result
    }

    static func cachedDisplayImage(for photo: PhotoItem, maxPixel: CGFloat = 2600, sdr: Bool = false) -> NSImage? {
        displayCache.object(forKey: displayKey(for: photo, maxPixel: maxPixel, sdr: sdr))
    }

    /// 后台预取相邻照片的显示图，按住方向键连翻时直接命中缓存。
    static func prefetchDisplay(for photo: PhotoItem, maxPixel: CGFloat = 2600, sdr: Bool = false) {
        guard cachedDisplayImage(for: photo, maxPixel: maxPixel, sdr: sdr) == nil else { return }
        guard DisplayPrefetchLimiter.shared.begin() else { return }
        Task.detached(priority: .background) {
            _ = displayImage(for: photo, maxPixel: maxPixel, sdr: sdr)
            DisplayPrefetchLimiter.shared.end()
        }
    }

    /// 后台预取快速层缩略图（192px，代价很低），连翻时每张都能立刻显示。
    static func prefetchQuick(for photo: PhotoItem) {
        guard cache.object(forKey: "\(gridQuickPixel)|\(photo.cacheKey)" as NSString) == nil else { return }
        Task.detached(priority: .utility) {
            _ = gridThumbnail(for: photo, maxPixel: CGFloat(gridQuickPixel))
        }
    }

    /// 后台预取查看器用的中等尺寸（1024px），作为全尺寸解码前的清晰占位层。
    static func prefetchMedium(for photo: PhotoItem) {
        let key = "\(pixelBucket(for: 1024))|\(photo.cacheKey)" as NSString
        guard cache.object(forKey: key) == nil else { return }
        Task.detached(priority: .utility) {
            _ = gridThumbnail(for: photo, maxPixel: 1024)
        }
    }

    /// 仅查内存中的网格缩略图，作为连翻时的即时占位图（不触发磁盘读取）。
    static func cachedPreview(for photo: PhotoItem) -> NSImage? {
        for bucket in gridPixelBuckets.reversed() {
            if let image = cache.object(forKey: "\(bucket)|\(photo.cacheKey)" as NSString) {
                return image
            }
        }
        return cache.object(forKey: photo.cacheKey as NSString)
    }

    private static func decodeDisplayImage(for photo: PhotoItem, maxPixel: CGFloat) -> NSImage? {
        if !photo.isVideo, !photo.hasEdits {
            let url = LibraryPaths.sourceURL(for: photo)
            if RawFormats.isRaw(url) {
                if let decoded = RawFormats.decode(url: url, maxPixel: maxPixel) {
                    let cgImage = ImageTransform.rotate(decoded, degrees: photo.rotationAngle) ?? decoded
                    return NSImage(cgImage: cgImage,
                                   size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }
        }
        guard let source = CGImageSourceCreateWithURL(LibraryPaths.sourceURL(for: photo) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let cgImage = ImageTransform.rotate(thumbnail, degrees: photo.rotationAngle) ?? thumbnail
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 关闭「查看完整 HDR」时把图像压成 8 位 sRGB，去掉 EDR 高光扩展。
    static func sdrImage(_ image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.workingColorSpace: space])
        guard let output = context.createCGImage(ciImage,
                                                 from: ciImage.extent,
                                                 format: .RGBA8,
                                                 colorSpace: space) else { return image }
        return NSImage(cgImage: output, size: image.size)
    }

    static func invalidate(photo: PhotoItem) {
        cache.removeObject(forKey: photo.cacheKey as NSString)
        for bucket in gridPixelBuckets {
            cache.removeObject(forKey: "\(bucket)|\(photo.cacheKey)" as NSString)
        }
        fullCache.removeObject(forKey: "\(photo.cacheKey)-full" as NSString)
        for pixel in [2600, 3000] {
            for sdr in [false, true] {
                displayCache.removeObject(forKey: displayKey(for: photo,
                                                             maxPixel: CGFloat(pixel),
                                                             sdr: sdr))
            }
        }
    }

    static func clearMemoryCaches() {
        cache.removeAllObjects()
        fullCache.removeAllObjects()
        displayCache.removeAllObjects()
    }

    // MARK: - 网络存储

    /// 云端缩略图：内存缓存读写（磁盘缓存与生成由 CloudThumbnailLoader 负责）。
    static func cachedCloudThumbnail(for photo: PhotoItem) -> NSImage? {
        cache.object(forKey: photo.cacheKey as NSString)
    }

    static func cacheCloudThumbnail(_ image: NSImage, for photo: PhotoItem) {
        store(image, forKey: photo.cacheKey as NSString)
    }

    static func cachedCloudFullImage(for photo: PhotoItem) -> NSImage? {
        fullCache.object(forKey: "\(photo.cacheKey)-full" as NSString)
    }

    static func cacheCloudFullImage(_ image: NSImage, for photo: PhotoItem) {
        let key = "\(photo.cacheKey)-full" as NSString
        let width = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let height = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        fullCache.setObject(image, forKey: key, cost: max(1, width * height * 4))
    }

    /// 云端原图：按需下载完整文件用于查看器显示。
    static func cloudFullImage(for photo: PhotoItem, client: WebDAVClient) async -> NSImage? {
        let key = "\(photo.cacheKey)-full" as NSString
        if let cached = fullCache.object(forKey: key) {
            return cached
        }
        guard let path = photo.cloudPath,
              let data = try? await client.data(path: path),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        fullCache.setObject(image, forKey: key, cost: max(1, cgImage.width * cgImage.height * 4))
        return image
    }

    /// 从已挂载的本地文件读取云端原图（SMB 共享）。
    static func fullImage(from url: URL, maxPixel: CGFloat = 6000) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func sourcePixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func quickThumbnail(url: URL, maxPixel: CGFloat = 260) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func fullNSImage(for photo: PhotoItem) -> NSImage? {
        if photo.isVideo {
            return NSImage(contentsOf: LibraryPaths.thumbnailURL(for: photo))
        }
        let url = LibraryPaths.sourceURL(for: photo)
        if !photo.hasEdits, RawFormats.isRaw(url) {
            if let decoded = RawFormats.decode(url: url, maxPixel: 6000) {
                let cgImage = ImageTransform.rotate(decoded, degrees: photo.rotationAngle) ?? decoded
                return NSImage(cgImage: cgImage,
                               size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let cgImage = ImageTransform.rotate(thumbnail, degrees: photo.rotationAngle) ?? thumbnail
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 限制后台预取解码的并发数，避免连翻时预取任务挤占当前照片的解码。
private final class DisplayPrefetchLimiter: @unchecked Sendable {
    static let shared = DisplayPrefetchLimiter()

    private let lock = NSLock()
    private let limit = 2
    private var active = 0

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < limit else { return false }
        active += 1
        return true
    }

    func end() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}

/// 系统图库缩略图生成门控：限制并发，并在同一个目标文件上做去重。
private final class ThumbnailGenerationGate: @unchecked Sendable {
    enum Ticket {
        /// 本次调用负责生成，结束后必须 `finish`。
        case granted
        /// 已有任务在生成同一个文件，等待其完成后放弃本次生成。
        case duplicate
        /// 并发已满且等待超时，本次放弃（滚动回来会再请求）。
        case throttled
    }

    static let shared = ThumbnailGenerationGate()

    private let condition = NSCondition()
    private let limit = 3
    private var active = 0
    private var inFlight: Set<String> = []

    func checkout(_ key: String) -> Ticket {
        // 主线程兜底：不阻塞界面（正常路径都在后台任务里）。
        guard !Thread.isMainThread else { return .granted }
        condition.lock()
        defer { condition.unlock() }
        if inFlight.contains(key) {
            // 等同一个文件的生成结束，避免重复解码。
            let deadline = Date(timeIntervalSinceNow: 3)
            while inFlight.contains(key), Date() < deadline {
                condition.wait(until: Date(timeIntervalSinceNow: 0.2))
            }
            return .duplicate
        }
        let deadline = Date(timeIntervalSinceNow: 3)
        while active >= limit {
            guard Date() < deadline else { return .throttled }
            condition.wait(until: Date(timeIntervalSinceNow: 0.2))
            if inFlight.contains(key) { return .duplicate }
        }
        active += 1
        inFlight.insert(key)
        return .granted
    }

    func finish(_ key: String) {
        // 主线程授予的票没有登记，不参与计数。
        guard !Thread.isMainThread else { return }
        condition.lock()
        active = max(0, active - 1)
        inFlight.remove(key)
        condition.broadcast()
        condition.unlock()
    }
}
