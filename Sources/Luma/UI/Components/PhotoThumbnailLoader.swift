import AppKit
import Foundation

/// 网格解码闸门。
///
/// 马赛克墙一屏要出上千个格子，如果每个格子都直接并发读盘解码，IO 会互相抢，
/// 结果是「整墙一起空白 → 过一会儿一起出图」。限流后按格子出现的顺序稳定出图，
/// 首屏几百毫秒内就开始逐块填充，滚动时也始终是「出来一些显示一些」。
/// 并发按核数放宽：外接盘 / SSD 上每格只是一次随机读 + 一次解码，多开几路能明显加快铺满速度。
actor ThumbnailDecodeGate {
    static let shared = ThumbnailDecodeGate(
        limit: max(6, min(14, ProcessInfo.processInfo.activeProcessorCount))
    )

    /// 32px 微缩略图专用闸门：单张只要几 KB，可以放更多并发来掩盖外接盘的寻道延迟。
    static let tiny = ThumbnailDecodeGate(limit: 32)

    /// 滚动预取专用闸门：与可见格子分开排队。
    /// 之前预取不受限地解 100～280 张，外接盘上会把可见格子的读取挤到后面，
    /// 表现就是快速滚动时一片灰、要等一两秒才逐块出图。
    static let prefetch = ThumbnailDecodeGate(limit: 3)

    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        let safeLimit = max(1, limit)
        self.limit = safeLimit
        self.available = safeLimit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 缩略图取图的唯一实现：缓存命中、快速层、目标档位解码与取消都在这里，
/// 视图组件与网格单元格共用，避免各处重复写解码顺序。
/// 代码与重构前逐行一致，仅从组件文件里独立出来，由组合根注入给 `LumaUI` 的组件。
@MainActor
enum PhotoThumbnailLoader {
    /// 返回目标档位图像；`onQuick` 会在快速层就绪时先回调（仅 `.grid` 有快速层）。
    static func load(photo: PhotoItem,
                     purpose: ThumbnailPurpose,
                     store: LibraryStore,
                     onQuick: (NSImage) -> Void = { _ in }) async -> NSImage? {
        // 性能基准只关心「从请求到出图」的端到端时间：快速层与目标档位各记一次。
        let started = CFAbsoluteTimeGetCurrent()
        let kind = purpose.isTwoTier ? "grid" : "cover"
        var recordedQuick = false
        let result = await loadImage(photo: photo, purpose: purpose, store: store) { quick in
            if !recordedQuick {
                recordedQuick = true
                UIPerformanceMetrics.shared.record(kind: kind, tier: .quick,
                                                   seconds: CFAbsoluteTimeGetCurrent() - started,
                                                   success: true)
            }
            onQuick(quick)
        }
        guard !Task.isCancelled else { return result }
        UIPerformanceMetrics.shared.record(kind: kind, tier: .target,
                                           seconds: CFAbsoluteTimeGetCurrent() - started,
                                           success: result != nil)
        return result
    }

    private static func loadImage(photo: PhotoItem,
                                  purpose: ThumbnailPurpose,
                                  store: LibraryStore,
                                  onQuick: (NSImage) -> Void) async -> NSImage? {
        // 已刮削的视频优先显示海报 / 背景图，所有网盘与本地库通用。
        if photo.isVideo, let artwork = store.cinemaGridArtwork(for: photo),
           let image = await CinemaArtworkCache.shared.image(for: artwork) {
            return image
        }
        let maxPixel = purpose.maxPixel
        // 网络图集：图片来自站点，直接走图集缓存，不落到网盘缩略图分支。
        if store.catalogGalleryContext(for: photo.id) != nil {
            if purpose.isTwoTier,
               let quick = await store.catalogGalleryThumbnail(for: photo.id) {
                guard !Task.isCancelled else { return nil }
                onQuick(quick)
            }
            return await store.catalogGalleryThumbnail(for: photo.id)
        }
        if photo.isCloud {
            // 云盘两层加载：先读 192px 快速层（纯本地），目标图仍按需走网络。
            if purpose.isTwoTier,
               ImageLoader.pixelBucket(for: maxPixel) > ImageLoader.gridQuickPixel,
               let quick = await store.cloudQuickThumbnail(for: photo,
                                                           maxPixel: CGFloat(ImageLoader.gridQuickPixel)) {
                guard !Task.isCancelled else { return nil }
                onQuick(quick)
            }
            return await store.cloudThumbnail(for: photo)
        }
        // 本地视频缺封面（导入时尚不支持 MKV）时，用内置 ffmpeg 补一帧。
        if photo.isVideo {
            await ImageLoader.LocalVideoPoster.ensure(for: photo)
        }
        if let cached = ImageLoader.cachedGridImage(for: photo, maxPixel: maxPixel) {
            return cached
        }
        // 原生系统图库：优先由系统「照片」给出缩略图（含预取、iCloud 与共享相簿资源）。
        // 这条路径必须排在本地微缩略图层之前：系统自己维护全量缩略图缓存并支持按窗口预热，
        // 比逐格读盘解码快一个数量级；本地解码只作为它取不到时的兜底。
        if photo.isSystem, store.usesPhotoKitThumbnails {
            let bucket = ImageLoader.pixelBucket(for: maxPixel)
            if purpose.isTwoTier, bucket > ImageLoader.gridQuickPixel {
                if let quick = await PhotoKitThumbnailProvider.shared.thumbnail(
                    for: photo,
                    maxPixel: ImageLoader.gridQuickPixel,
                    degradedAllowed: true
                ) {
                    guard !Task.isCancelled else { return nil }
                    ImageLoader.storeGridThumbnail(quick, for: photo,
                                                   maxPixel: CGFloat(ImageLoader.gridQuickPixel))
                    onQuick(quick)
                }
            }
            if let image = await PhotoKitThumbnailProvider.shared.thumbnail(for: photo, maxPixel: bucket) {
                guard !Task.isCancelled else { return nil }
                ImageLoader.storeGridThumbnail(image, for: photo, maxPixel: maxPixel)
                return image
            }
            // 系统取不到（该项目不在当前系统照片库等）：继续走本地 derivative / 现场解码。
        }
        // 马赛克档（格子约 ≤ 36pt）走微缩略图层：本地 64px 小图 / 官方 32px THM / 官方 5005 档，
        // 读盘量与解码量都只有原图的百分之一，整墙几乎立刻全部可见。
        if !photo.isCloud, purpose.isTwoTier, maxPixel <= 72,
           let tiny = await decodeTiny(photo: photo) {
            return tiny
        }
        // 快速层只在本地已有 192px 小文件时才走：没有小文件时本来就要完整解码一次主缩略图，
        // 先解一遍 192px 再解一遍目标档位等于把同一个文件读两次、解两次，
        // 外接盘上这两次随机读会直接拖慢整屏出图。
        if purpose.isTwoTier,
           ImageLoader.pixelBucket(for: maxPixel) > ImageLoader.gridQuickPixel,
           ImageLoader.hasQuickThumbnail(for: photo) {
            if let quick = await decodeGated(photo: photo,
                                             maxPixel: CGFloat(ImageLoader.gridQuickPixel)) {
                guard !Task.isCancelled else { return nil }
                onQuick(quick)
            }
        }
        return await decodeGated(photo: photo, maxPixel: maxPixel)
    }

    /// 走统一闸门解码：可见格子优先（userInitiated）。
    /// 排队期间格子被滚走 / 缩放取消时直接放弃，不浪费一次读盘。
    private static func decodeGated(photo: PhotoItem, maxPixel: CGFloat) async -> NSImage? {
        await ThumbnailDecodeGate.shared.acquire()
        guard !Task.isCancelled else {
            await ThumbnailDecodeGate.shared.release()
            return nil
        }
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoader.gridThumbnail(for: photo, maxPixel: maxPixel)
        }.value
        await ThumbnailDecodeGate.shared.release()
        return image
    }

    /// 32px 微缩略图：走更宽的闸门，先让整墙铺满图，再谈清晰度。
    private static func decodeTiny(photo: PhotoItem) async -> NSImage? {
        await ThumbnailDecodeGate.tiny.acquire()
        guard !Task.isCancelled else {
            await ThumbnailDecodeGate.tiny.release()
            return nil
        }
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoader.tinyThumbnail(for: photo)
        }.value
        await ThumbnailDecodeGate.tiny.release()
        return image
    }
}
