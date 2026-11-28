import Foundation
import AVFoundation

/// 系统「照片」图库的只读媒体访问：视图不再直接调用 `PhotoKitBridge`。
extension LibraryStore {
    /// 系统照片 / 视频的原图数据，只读；编辑器预览与导出使用。
    func systemOriginalImageData(for photo: PhotoItem) async -> Data? {
        guard photo.isSystem else { return nil }
        return await PhotoKitBridge.originalImageData(assetID: photo.id)
    }

    /// 系统「照片」视频资产：交给播放器处理共享相簿与 iCloud 下载；
    /// 失败时带回真实原因（找不到 / 无权限 / 资源未就绪 / 确实在云端）。
    func systemVideoAsset(for photo: PhotoItem) async -> PhotoKitBridge.SystemVideoAsset {
        guard photo.isSystem else { return .notFound }
        return await PhotoKitBridge.videoAsset(id: photo.id)
    }
}
