import Foundation

/// 官方「照片」图库照片的拾光侧覆盖值；nil 表示沿用 Apple 自己的元数据。
public struct AssetOverlay {
    public var isFavorite: Bool?
    public var isHidden: Bool?
    public var keywords: [String]?
    public var title: String?
    public var viewedAt: Date?
    public var rating: Int?
    public var flag: PhotoFlag?
    public var colorLabel: PhotoColorLabel?

    public var isEmpty: Bool {
        isFavorite == nil && isHidden == nil && keywords == nil && title == nil
            && viewedAt == nil && rating == nil && flag == nil && colorLabel == nil
    }
    public init(
        isFavorite: Bool? = nil,
        isHidden: Bool? = nil,
        keywords: [String]? = nil,
        title: String? = nil,
        viewedAt: Date? = nil,
        rating: Int? = nil,
        flag: PhotoFlag? = nil,
        colorLabel: PhotoColorLabel? = nil
    ) {
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.keywords = keywords
        self.title = title
        self.viewedAt = viewedAt
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
    }
}
