import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage
import LumaCore

enum ImageLoader {
    /// 双层网格缩略图（快速层 + 目标层）会同时驻留，上限相应放宽。
    /// 内存池统一由 `MemoryImageCache` 管理，不再单独持有 NSCache。
    private static let cache = MemoryImageCache(totalCostLimit: 384 * 1024 * 1024)
    private static let fullCache = MemoryImageCache(totalCostLimit: 512 * 1024 * 1024)
    /// 32px 微缩略图专用缓存：一张只要 4KB，整墙上千格常驻也才几 MB。
    private static let tinyCache = MemoryImageCache(totalCostLimit: 48 * 1024 * 1024)

    private static func store(_ image: NSImage, forKey key: NSString) {
        let rep = image.representations.first
        let width = rep?.pixelsWide ?? Int(image.size.width)
        let height = rep?.pixelsHigh ?? Int(image.size.height)
        cache.setObject(image, forKey: key, cost: max(1, width * height * 4))
    }

    /// 系统图库自带的 32px 微缩略图（`<UUID>.THM`，约 1KB）。
    /// 马赛克墙先铺这一层：读盘量与解码量都是 derivative 的百分之一，整墙几乎立刻全部可见。
    static func tinyThumbnail(for photo: PhotoItem) -> NSImage? {
        let key = "tiny|\(photo.cacheKey)" as NSString
        if let cached = tinyCache.object(forKey: key) { return cached }
        // 1) 拾光自己缓存的 64px 小图（本地盘，最快，覆盖所有图库）。
        let tinyURL = LibraryPaths.tinyThumbnailURL(for: photo)
        if isTinyFresh(at: tinyURL, for: photo),
           let image = decodeThumbnail(at: tinyURL, maxPixel: 64) {
            let rep = image.representations.first
            tinyCache.setObject(image, forKey: key,
                                cost: max(1, (rep?.pixelsWide ?? 64) * (rep?.pixelsHigh ?? 64) * 4))
            return image
        }
        // 2) 官方图库自带的 `<UUID>.THM`（32px，约 1KB，不必本地再生成一份）。
        if photo.isSystem,
           let path = LibraryPaths.systemTinyThumbnailPath(for: photo),
           let image = decodeThumbnail(at: URL(fileURLWithPath: path), maxPixel: 64) {
            let rep = image.representations.first
            tinyCache.setObject(image, forKey: key,
                                cost: max(1, (rep?.pixelsWide ?? 32) * (rep?.pixelsHigh ?? 32) * 4))
            return image
        }
        // 3) THM 也没有：官方 5005 档（长边约 520px、约 36KB，全库覆盖）解一张 64px。
        //    比直接读一两兆的原图快一个数量级；解完顺手落成本地 3KB 小图。
        if photo.isSystem,
           let master = LibraryPaths.systemMasterThumbnailPath(for: photo),
           let image = decodeThumbnail(at: URL(fileURLWithPath: master), maxPixel: 64) {
            let rep = image.representations.first
            tinyCache.setObject(image, forKey: key,
                                cost: max(1, (rep?.pixelsWide ?? 64) * (rep?.pixelsHigh ?? 64) * 4))
            ensureTinyThumbnail(from: image, for: photo)
            return image
        }
        // 4) 三样都没有：直接从原图生成一张 64px，并落成本地小图。
        // 大图库里少数项目既没有官方 derivative、THM，也没有 5005 档，
        // 不在这里兜底的话，马赛克墙每一格都要读一遍 1～2MB 原图，整墙铺满要好几秒；
        // 生成一次后同一张照片的后续访问只读 3KB。
        guard !photo.isCloud, !photo.isVideo,
              let image = decodeThumbnail(at: LibraryPaths.sourceURL(for: photo), maxPixel: 64) else {
            return nil
        }
        let rep = image.representations.first
        tinyCache.setObject(image, forKey: key,
                            cost: max(1, (rep?.pixelsWide ?? 64) * (rep?.pixelsHigh ?? 64) * 4))
        ensureTinyThumbnail(from: image, for: photo)
        return image
    }

    /// 微缩略图是否还比主缩略图新（编辑 / 重新导入后不能继续用旧小图）。
    private static func isTinyFresh(at tinyURL: URL, for photo: PhotoItem) -> Bool {
        guard let tinyDate = ThumbnailFileIndex.shared.modificationDate(path: tinyURL.path) else {
            return false
        }
        let mainPath: String?
        if photo.isCloud {
            mainPath = nil
        } else if let derivative = photo.systemThumbnailPath,
                  ThumbnailFileIndex.shared.exists(path: derivative) {
            mainPath = derivative
        } else if let master = LibraryPaths.systemMasterThumbnailPath(for: photo),
                  ThumbnailFileIndex.shared.exists(path: master) {
            // 主 derivative 缺档时，5005 档才是真正的小图来源：它一变，小图就该重建。
            mainPath = master
        } else if photo.isSystem {
            mainPath = nil
        } else {
            mainPath = LibraryPaths.thumbnailURL(for: photo).path
        }
        guard let mainPath,
              let mainDate = ThumbnailFileIndex.shared.modificationDate(path: mainPath) else {
            return true
        }
        return tinyDate >= mainDate
    }

    /// 快速层小文件是否已存在。走缩略图内存索引：没索引过的路径只 stat 一次。
    static func hasQuickThumbnail(for photo: PhotoItem) -> Bool {
        guard !photo.isCloud else { return false }
        return ThumbnailFileIndex.shared.exists(path: LibraryPaths.quickThumbnailURL(for: photo).path)
    }

    /// 生成马赛克墙用的 64px 小图（后台写入，已有则跳过）。
    private static func ensureTinyThumbnail(from image: NSImage, for photo: PhotoItem) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        writeTinyThumbnail(from: cgImage, for: photo)
    }

    /// 从已经解码好的图写 64px 小图：网格解码顺带落一份，马赛克墙不必再解一次原图。
    private static func writeTinyThumbnail(from cgImage: CGImage, for photo: PhotoItem) {
        guard !photo.isCloud else { return }
        let url = LibraryPaths.tinyThumbnailURL(for: photo)
        guard !ThumbnailFileIndex.shared.exists(path: url.path) else { return }
        guard let tiny = ImageTransform.downscale(cgImage, maxPixel: 64),
              let data = jpegData(tiny, quality: 0.72) else { return }
        ThumbnailCacheWriter.shared.enqueue(data, to: url)
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
            // 官方 derivative / 本地缓存都没有：现场生成一次，直接复用这次的解码结果。
            guard let image = generateSystemThumbnail(for: photo,
                                                      bucket: ThumbnailSizing.buckets.last ?? 1024)
            else { return nil }
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
    /// `cacheLocally` 为真时（预取路径）顺带把结果落一份到本地缩略图目录：
    /// 图库在外接盘上时，下次会话滚动到同一张只需读本地小文件，不再随机读外接盘。
    static func gridThumbnail(for photo: PhotoItem, maxPixel: CGFloat,
                              cacheLocally: Bool = false) -> NSImage? {
        let bucket = pixelBucket(for: maxPixel)
        let key = "\(bucket)|\(photo.cacheKey)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        // 官方 derivative / 本地缓存都没有：从原图现场生成一次，直接用这次的解码结果，
        // 不再「生成 → 重新读文件 → 再解码」。
        guard let mainURL = thumbnailSourceURL(for: photo, bucket: bucket) else {
            guard photo.isSystem,
                  let generated = generateSystemThumbnail(for: photo, bucket: bucket) else { return nil }
            store(generated, forKey: key)
            return generated
        }

        if bucket <= gridQuickPixel {
            if !photo.isCloud,
               let quickURL = freshQuickThumbnailURL(for: photo, mainURL: mainURL),
               let image = decodeThumbnail(at: quickURL, maxPixel: CGFloat(bucket)) {
                store(image, forKey: key)
                ensureTinyThumbnail(from: image, for: photo)
                return image
            }
            guard let image = decodeThumbnail(at: mainURL, maxPixel: CGFloat(bucket)) else { return nil }
            store(image, forKey: key)
            ensureTinyThumbnail(from: image, for: photo)
            if !photo.isCloud {
                writeQuickThumbnail(from: image, for: photo)
            }
            return image
        }

        guard let image = decodeThumbnail(at: mainURL, maxPixel: CGFloat(bucket)) else { return nil }
        store(image, forKey: key)
        ensureTinyThumbnail(from: image, for: photo)
        if cacheLocally {
            writeLocalGridCache(from: image, for: photo, bucket: bucket, source: mainURL)
        }
        return image
    }

    /// 把从外接盘解出来的网格缩略图落一份到本地（后台写，不阻塞出图）。
    /// 只处理系统图库、且不是从本地缓存解出来的那些；已有缓存不重复写。
    private static func writeLocalGridCache(from image: NSImage, for photo: PhotoItem,
                                            bucket: Int, source: URL) {
        guard photo.isSystem, !photo.isCloud else { return }
        let destination = generatedThumbnailDestination(for: photo, bucket: bucket)
        guard source.path != destination.path else { return }
        guard !ThumbnailFileIndex.shared.exists(path: destination.path) else { return }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = jpegData(cgImage, quality: 0.78) else { return }
        // 缓存总量按会话限流：滚动得越多写得越多，但不能无上限地吃掉本地磁盘。
        guard LocalGridCacheBudget.shared.reserve(data.count) else { return }
        ThumbnailCacheWriter.shared.enqueue(data, to: destination)
    }

    /// 本地缓存的网格缩略图是否仍然可用：不早于它所依据的官方 derivative 即可。
    /// 没有可比对的 derivative 时（该照片本来就没有官方缩略图），本地这份就是唯一来源。
    private static func isLocalCacheFresh(_ local: URL, for photo: PhotoItem) -> Bool {
        guard let localDate = ThumbnailFileIndex.shared.modificationDate(path: local.path) else {
            return false
        }
        guard let derivative = photo.systemThumbnailPath,
              let derivativeDate = ThumbnailFileIndex.shared.modificationDate(path: derivative) else {
            return true
        }
        return localDate >= derivativeDate
    }

    /// 快速层文件存在且不早于主缩略图时返回其路径（主图更新后视为过期）。
    private static func freshQuickThumbnailURL(for photo: PhotoItem, mainURL: URL) -> URL? {
        let quickURL = LibraryPaths.quickThumbnailURL(for: photo)
        // 修改时间走缩略图索引：滚动时不再对每个格子做两次磁盘 stat。
        guard let quickDate = ThumbnailFileIndex.shared.modificationDate(path: quickURL.path),
              let mainDate = ThumbnailFileIndex.shared.modificationDate(path: mainURL.path),
              quickDate >= mainDate else { return nil }
        return quickURL
    }

    /// 生成快速层小文件（后台写入，不阻塞当前格子显示）。
    private static func writeQuickThumbnail(from image: NSImage, for photo: PhotoItem) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let quick = ImageTransform.downscale(cgImage, maxPixel: gridQuickPixel),
              let data = jpegData(quick, quality: 0.75) else { return }
        ThumbnailCacheWriter.shared.enqueue(data, to: LibraryPaths.quickThumbnailURL(for: photo))
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

    /// 外部缓存（云盘快速层等）复用同一套文件解码逻辑，不触发缩略图生成。
    static func decodeThumbnailFile(at url: URL, maxPixel: CGFloat) -> NSImage? {
        decodeThumbnail(at: url, maxPixel: maxPixel)
    }

    /// 外部来源（PhotoKit）取到的缩略图写回网格缓存：与本地解码共用同一套 key 与容量控制。
    static func storeGridThumbnail(_ image: NSImage, for photo: PhotoItem, maxPixel: CGFloat) {
        store(image, forKey: "\(pixelBucket(for: maxPixel))|\(photo.cacheKey)" as NSString)
    }

    /// 现有的缩略图文件（不存在则返回 nil，不触发现场生成）。
    /// `bucket` 决定现场生成缓存里哪一档够用：小档只在不需要放大时才拿来用。
    private static func thumbnailSourceURL(for photo: PhotoItem, bucket: Int) -> URL? {
        if photo.isCloud {
            guard let mountID = photo.cloudMountID, let path = photo.cloudPath else { return nil }
            let url = CloudPaths.thumbnailURL(mountID: mountID, path: path)
            return ThumbnailFileIndex.shared.exists(path: url.path) ? url : nil
        }
        if photo.isSystem {
            // 本地缓存过的网格缩略图优先：图库在外接盘上时，直接读本地小文件，
            // 不必每格都去随机读一次外接盘的 derivative。
            if let local = generatedThumbnailURL(for: photo, bucket: bucket),
               isLocalCacheFresh(local, for: photo) {
                return local
            }
            // 官方 derivative 优先；路径已在查询时算好，这里只查索引，避免每格都碰磁盘。
            if let derivative = photo.systemThumbnailPath {
                let url = URL(fileURLWithPath: derivative)
                if ThumbnailFileIndex.shared.exists(path: url.path) { return url }
            }
            // 主 derivative 只覆盖约四成项目；官方给全库生成的 5005 档（长边约 520px、
            // 约 36KB）足够网格用，先用它出图，不必为每个格子解码一两兆的原图。
            if bucket <= 512, let master = LibraryPaths.systemMasterThumbnailPath(for: photo) {
                let url = URL(fileURLWithPath: master)
                if ThumbnailFileIndex.shared.exists(path: url.path) { return url }
            }
            return generatedThumbnailURL(for: photo, bucket: bucket)
        }
        let url = LibraryPaths.thumbnailURL(for: photo)
        return ThumbnailFileIndex.shared.exists(path: url.path) ? url : nil
    }

    /// 现场生成缓存分两档：`_s`（≤512px，网格常规尺寸）与无后缀（1024px，最大档位）。
    /// 网格首屏只要几百像素，按需生成小档能把编码时间与写盘量都省下来
    /// （每张约 120KB → 约 30KB，一百多万项的缓存体积因此少四分之三）；
    /// 放大到最大档位时才补一张大图。
    private static func generatedThumbnailDestination(for photo: PhotoItem, bucket: Int) -> URL {
        let suffix = bucket > 512 ? "" : "_s"
        return LibraryPaths.systemThumbs.appendingPathComponent(photo.id.uuidString + suffix + ".jpg")
    }

    /// 现成的现场生成缓存里，能满足当前档位的那一份。
    private static func generatedThumbnailURL(for photo: PhotoItem, bucket: Int) -> URL? {
        if bucket > 512 {
            // 大档位只看大图：拿小图放大不值当，交给调用方补一张大图。
            let large = generatedThumbnailDestination(for: photo, bucket: 1024)
            return ThumbnailFileIndex.shared.exists(path: large.path) ? large : nil
        }
        let small = generatedThumbnailDestination(for: photo, bucket: 384)
        if ThumbnailFileIndex.shared.exists(path: small.path) { return small }
        let large = generatedThumbnailDestination(for: photo, bucket: 1024)
        return ThumbnailFileIndex.shared.exists(path: large.path) ? large : nil
    }

    /// 系统图库既没有官方 derivative 也没有本地缓存时，从原图 / 视频现场生成一份缩略图。
    /// 网格滚动会同时请求很多格子，这里限制并发并按目标文件去重，避免几十个大图解码同时抢 CPU 与磁盘。
    ///
    /// 生成尺寸取「本次实际需要的档位」（1024 封顶，不低于 256）：首屏几百像素的格子
    /// 不必为了一次显示解码 / 编码一张 1024px 的图。顺带用同一次解码写出 64px 小图，
    /// 马赛克墙与缩略显示都不必再解一遍原图。
    @discardableResult
    private static func generateSystemThumbnail(for photo: PhotoItem, bucket: Int) -> NSImage? {
        let target = max(256, min(bucket, ThumbnailSizing.buckets.last ?? 1024))
        let destination = generatedThumbnailDestination(for: photo, bucket: target)
        let key = destination.path
        switch ThumbnailGenerationGate.shared.checkout(key) {
        case .duplicate, .throttled:
            // 已有任务在生成同一个文件（或并发已满）：本次直接跳过，稍后重新请求即可命中。
            return nil
        case .granted:
            defer { ThumbnailGenerationGate.shared.finish(key) }
            let source = LibraryPaths.sourceURL(for: photo)
            if photo.isVideo {
                ImportService.makeVideoThumbnail(url: source, destination: destination)
                ThumbnailFileIndex.shared.recordWrite(url: destination)
                return nil
            }
            guard let cgImage = ImportService.makeImageThumbnail(
                url: source,
                destination: destination,
                maxPixel: target,
                rotation: photo.rotationAngle,
                quality: 0.85
            ) else { return nil }
            // 生成完成后立刻登记，紧跟着的存在性检查不必再 stat。
            ThumbnailFileIndex.shared.recordWrite(url: destination)
            writeTinyThumbnail(from: cgImage, for: photo)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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

    private static let displayCache = MemoryImageCache(totalCostLimit: 192 * 1024 * 1024)

    private static func displayKey(for photo: PhotoItem, maxPixel: CGFloat, sdr: Bool) -> NSString {
        "\(photo.cacheKey)-display-\(Int(maxPixel))\(sdr ? "-sdr" : "")" as NSString
    }

    /// 动图专用：保留全部帧交给 `AnimatedImageView` 播放，不走静态解码缓存。
    /// 已编辑照片是静态渲染结果；云端动图由 Store 下载完整文件后再解码。
    static func animatedImage(for photo: PhotoItem) -> NSImage? {
        guard photo.playsAnimation, !photo.isCloud else { return nil }
        let url = LibraryPaths.sourceURL(for: photo)
        return NSImage(contentsOf: url)
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

    /// 滚动预取：窗口 / 分页落位后，提前把即将进入视野的格子解码成快速层。
    /// 参考系统「照片」的预加载策略——只解码一档小图并写入内存与快速层文件，
    /// 真正滚到这些格子时直接命中缓存，不再等磁盘 IO 与解码。
    /// `maxPixel` 传当前网格档位：马赛克墙只要 128px，预取 192px 会全部落空缓存。
    ///
    /// 返回的任务由调用方持有并在下一次预取前取消：滚动时视野连续变化，
    /// 上一批还没跑完就该让位，否则多批预取同时读盘会把可见格子饿死。
    @discardableResult
    static func prefetchGridQuick(for photos: [PhotoItem], maxPixel: CGFloat = CGFloat(gridQuickPixel),
                                  limit: Int = 0) -> Task<Void, Never>? {
        let cap = limit > 0 ? limit : prefetchBatchLimit
        guard !photos.isEmpty, cap > 0 else { return nil }
        let bucket = pixelBucket(for: maxPixel)
        let targets = photos.prefix(cap).filter {
            cache.object(forKey: "\(bucket)|\($0.cacheKey)" as NSString) == nil
        }
        guard !targets.isEmpty else { return nil }
        let workload = Array(targets)
        let workers = min(ThumbnailPrefetchTuner.concurrency, workload.count)
        return Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addWorker() {
                    guard next < workload.count else { return }
                    let photo = workload[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        // 走独立闸门：预取永远排不到可见格子前面。
                        await ThumbnailDecodeGate.prefetch.acquire()
                        guard !Task.isCancelled else {
                            await ThumbnailDecodeGate.prefetch.release()
                            return
                        }
                        let started = Date().timeIntervalSinceReferenceDate
                        _ = gridThumbnail(for: photo, maxPixel: maxPixel, cacheLocally: true)
                        await ThumbnailDecodeGate.prefetch.release()
                        ThumbnailPrefetchTuner.record(
                            milliseconds: (Date().timeIntervalSinceReferenceDate - started) * 1_000
                        )
                    }
                }
                // 并发与单次预取量按实测 IO 延迟自适应：慢盘上少排队，快盘上多预热。
                for _ in 0..<max(1, workers) { addWorker() }
                while await group.next() != nil {
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }
                    addWorker()
                }
            }
        }
    }

    /// 单次窗口预取的张数上限：外接机械盘 / 网络盘上自动缩小，避免预取把可见格子的 IO 抢光。
    static var prefetchBatchLimit: Int { ThumbnailPrefetchTuner.batchLimit }

    /// 打开相簿 / 文件夹后预热前若干张快速缩略图：
    /// 解码一次并写入本地快速层文件与内存缓存，首屏与后续滚动直接命中，不必逐张等外部磁盘。
    /// 返回的任务可在切换相簿时取消。
    @discardableResult
    static func prewarmQuickThumbnails(for photos: [PhotoItem],
                                       concurrency: Int = ThumbnailPrefetchTuner.concurrency) -> Task<Void, Never> {
        let targets = photos
        return Task.detached(priority: .utility) {
            guard !targets.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addWorker() {
                    guard next < targets.count else { return }
                    let photo = targets[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        let started = Date().timeIntervalSinceReferenceDate
                        _ = gridThumbnail(for: photo, maxPixel: CGFloat(gridQuickPixel))
                        ThumbnailPrefetchTuner.record(
                            milliseconds: (Date().timeIntervalSinceReferenceDate - started) * 1_000
                        )
                    }
                }
                for _ in 0..<max(1, concurrency) { addWorker() }
                while await group.next() != nil {
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }
                    addWorker()
                }
            }
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

    /// 本地视频封面补生成：导入时若还没有 ffmpeg（MKV 等容器），derivative 会缺失；
    /// 现在组件内置了就绪后，首次显示时补一帧，不需要重新导入整个图库。
    enum LocalVideoPoster {
        private static let lock = NSLock()
        private static var running: Set<UUID> = []
        /// 本次会话已失败的项目不再反复拉起 ffmpeg。
        private static var failed: Set<UUID> = []

        static func ensure(for photo: PhotoItem) async {
            guard photo.isVideo, !photo.isCloud, !photo.isSystem else { return }
            let destination = LibraryPaths.thumbnailURL(for: photo)
            guard !FileManager.default.fileExists(atPath: destination.path) else { return }
            let source = LibraryPaths.sourceURL(for: photo)
            guard FileManager.default.fileExists(atPath: source.path) else { return }

            lock.lock()
            guard !running.contains(photo.id), !failed.contains(photo.id) else {
                lock.unlock()
                return
            }
            running.insert(photo.id)
            lock.unlock()
            defer {
                lock.lock()
                running.remove(photo.id)
                lock.unlock()
            }

            _ = await Task.detached(priority: .utility) {
                VideoSupport.makeThumbnail(url: source, destination: destination)
            }.value

            if FileManager.default.fileExists(atPath: destination.path) {
                ImageLoader.invalidate(photo: photo)
            } else {
                lock.lock()
                failed.insert(photo.id)
                lock.unlock()
            }
        }
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

/// 本地网格缩略图缓存的写入配额（按会话）。
/// 外接盘图库靠它把「每格一次随机读」变成「第一次读、之后读本地」，
/// 但要防止用户一路滚到底把本地磁盘塞满：每个会话最多写这么多，超出后只读不写。
private final class LocalGridCacheBudget: @unchecked Sendable {
    static let shared = LocalGridCacheBudget()

    private let lock = NSLock()
    private var remaining = 2 * 1024 * 1024 * 1024

    func reserve(_ bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining >= bytes else { return false }
        remaining -= bytes
        return true
    }
}

/// 缩略图预取的吞吐自适应：按实测「读盘 + 解码」耗时调节并发与单批张数。
/// 机械盘 / 网络盘上单张可能要上百毫秒，此时缩小预取规模，避免把可见格子的 IO 抢光。
private enum ThumbnailPrefetchTuner {
    private static let lock = NSLock()
    private static var ewmaMS: Double = 6
    private static var samples = 0

    static func record(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        samples += 1
        if samples < 5 {
            ewmaMS = (ewmaMS * Double(samples - 1) + milliseconds) / Double(samples)
        } else {
            ewmaMS = ewmaMS * 0.8 + milliseconds * 0.2
        }
        lock.unlock()
    }

    static var concurrency: Int {
        lock.lock()
        let value = ewmaMS
        lock.unlock()
        if value > 60 { return 3 }
        if value > 25 { return 5 }
        return 7
    }

    static var batchLimit: Int {
        lock.lock()
        let value = ewmaMS
        lock.unlock()
        if value > 60 { return 120 }
        if value > 25 { return 200 }
        return 280
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
    /// 同时生成的缩略图数量：外接盘上每张要读 1～2MB 原图再编码一次，
    /// 多开几路能让「打开相册后整屏先出来」明显更快；上限仍按核数收敛，避免 CPU 与磁盘互相拖慢。
    private let limit = max(6, min(12, ProcessInfo.processInfo.activeProcessorCount))
    private var active = 0
    private var inFlight: Set<String> = []

    func checkout(_ key: String) -> Ticket {
        // 主线程兜底：不阻塞界面（正常路径都在后台任务里）。
        guard !Thread.isMainThread else { return .granted }
        condition.lock()
        defer { condition.unlock() }
        if inFlight.contains(key) {
            // 等同一个文件的生成结束，避免重复解码；生成完成后调用方会重新检查文件。
            let deadline = Date(timeIntervalSinceNow: 10)
            while inFlight.contains(key), Date() < deadline {
                condition.wait(until: Date(timeIntervalSinceNow: 0.2))
            }
            return .duplicate
        }
        let deadline = Date(timeIntervalSinceNow: 6)
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
