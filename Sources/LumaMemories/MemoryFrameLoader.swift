import AppKit
import LumaDomain

/// 回忆影片的取图出口。
/// 本模块不直接依赖 App 的 `ImageLoader`，由组合根在启动时注入；
/// 未注入时返回 nil，界面显示占位进度。
package enum MemoryFrameLoader {
    package static var load: ((PhotoItem, CGFloat) -> NSImage?)?

    package static func image(for photo: PhotoItem, maxPixel: CGFloat) -> NSImage? {
        load?(photo, maxPixel)
    }
}
