import Foundation

/// 图库体检结果：一次扫描得到的可处理项。仅作用于拾光本地图库。
struct LibraryHealthReport {
    struct Finding: Identifiable {
        let photo: PhotoItem
        /// 清晰度（拉普拉斯方差，越大越清晰）。
        let score: Double
        var id: UUID { photo.id }
    }

    /// 一组相似照片（连拍或同场景重复拍摄），`best` 是按清晰度/像素挑出的保留项。
    struct SimilarGroup: Identifiable {
        let best: PhotoItem
        let duplicates: [PhotoItem]
        var id: UUID { best.id }
        /// 组内平均相似度（0…1）。
        let similarity: Double
    }

    var blurry: [Finding] = []
    var similarGroups: [SimilarGroup] = []
    var largeVideos: [PhotoItem] = []
    var scannedAt: Date = Date()
    var scannedCount = 0

    /// 相似组里被判定为备选、可删除的照片。
    var similarDuplicatePhotos: [PhotoItem] {
        similarGroups.flatMap(\.duplicates)
    }

    /// 若删除相似备选，可释放的字节数。
    var reclaimableBytes: Int64 {
        similarDuplicatePhotos.reduce(0) { $0 + $1.fileSize }
    }

    /// 模糊照片若全部删除可释放的字节数（仅作展示，不自动删除）。
    var blurryBytes: Int64 {
        blurry.reduce(0) { $0 + $1.photo.fileSize }
    }
}
