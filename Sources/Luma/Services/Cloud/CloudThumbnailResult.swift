import AppKit

/// 网盘缩略图 / 探测结果：属于服务层返回值，不放进领域模型。
struct CloudThumbnailResult {
    let image: NSImage?
    let size: CGSize?
    let duration: Double?
}
