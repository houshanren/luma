import AppKit
import Foundation

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
        if purpose.isTwoTier,
           ImageLoader.pixelBucket(for: maxPixel) > ImageLoader.gridQuickPixel {
            let quick = await Task.detached(priority: .userInitiated) {
                ImageLoader.gridThumbnail(for: photo, maxPixel: CGFloat(ImageLoader.gridQuickPixel))
            }.value
            guard !Task.isCancelled else { return nil }
            if let quick { onQuick(quick) }
        }
        return await Task.detached(priority: .utility) {
            ImageLoader.gridThumbnail(for: photo, maxPixel: maxPixel)
        }.value
    }
}
