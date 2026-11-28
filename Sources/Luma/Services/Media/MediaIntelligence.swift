import Foundation

/// 照片与视频的统一端侧分析入口。
/// 图片走原有的 Vision / SigLIP / YOLO 单帧管线；视频先抽帧，再复用同一条管线并聚合结果。
enum MediaIntelligence {
    static func analyze(_ photo: PhotoItem) async -> PhotoIntelligence.Result? {
        if photo.isVideo {
            return await VideoIntelligence.analyze(photo)
        }
        return PhotoIntelligence.analyze(photo)
    }
}
