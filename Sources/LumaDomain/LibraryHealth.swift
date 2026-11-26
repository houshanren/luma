import Foundation

/// 图库体检结果：一次扫描得到的可处理项。本地图库、系统图库与网盘目录结果都复用这一份模型，
/// 结果按范围签名写入当前图库的 `derived_reports`，打开页面时可以直接回填上次结果。
public struct LibraryHealthReport: Codable {
    public struct Finding: Identifiable, Codable {
        public let photo: PhotoItem
        /// 清晰度（拉普拉斯方差，越大越清晰）。
        public let score: Double
        public var id: UUID { photo.id }
        public init(
            photo: PhotoItem,
            score: Double
        ) {
            self.photo = photo
            self.score = score
        }
    }

    /// 一组相似照片（连拍或同场景重复拍摄），`best` 是按清晰度/像素挑出的保留项。
    public struct SimilarGroup: Identifiable, Codable {
        public let best: PhotoItem
        public let duplicates: [PhotoItem]
        public var id: UUID { best.id }
        /// 组内平均相似度（0…1）。
        public let similarity: Double
        public init(
            best: PhotoItem,
            duplicates: [PhotoItem],
            similarity: Double
        ) {
            self.best = best
            self.duplicates = duplicates
            self.similarity = similarity
        }
    }

    public var blurry: [Finding] = []
    public var similarGroups: [SimilarGroup] = []
    public var largeVideos: [PhotoItem] = []
    public var scannedAt: Date = Date()
    public var scannedCount = 0

    /// 相似组里被判定为备选、可删除的照片。
    public var similarDuplicatePhotos: [PhotoItem] {
        similarGroups.flatMap(\.duplicates)
    }

    /// 若删除相似备选，可释放的字节数。
    public var reclaimableBytes: Int64 {
        similarDuplicatePhotos.reduce(0) { $0 + $1.fileSize }
    }

    /// 模糊照片若全部删除可释放的字节数（仅作展示，不自动删除）。
    public var blurryBytes: Int64 {
        blurry.reduce(0) { $0 + $1.photo.fileSize }
    }

    /// 只保留仍存在于当前列表里的条目（回填网盘缓存时过滤远端已删除文件）。
    public func filtered(to ids: Set<UUID>) -> LibraryHealthReport {
        var copy = self
        copy.blurry = blurry.filter { ids.contains($0.photo.id) }
        copy.similarGroups = similarGroups.compactMap { group in
            let duplicates = group.duplicates.filter { ids.contains($0.id) }
            guard ids.contains(group.best.id), !duplicates.isEmpty else { return nil }
            return SimilarGroup(best: group.best, duplicates: duplicates, similarity: group.similarity)
        }
        copy.largeVideos = largeVideos.filter { ids.contains($0.id) }
        return copy
    }
    public init(
        blurry: [Finding] = [],
        similarGroups: [SimilarGroup] = [],
        largeVideos: [PhotoItem] = [],
        scannedAt: Date = Date(),
        scannedCount: Int = 0
    ) {
        self.blurry = blurry
        self.similarGroups = similarGroups
        self.largeVideos = largeVideos
        self.scannedAt = scannedAt
        self.scannedCount = scannedCount
    }
}
