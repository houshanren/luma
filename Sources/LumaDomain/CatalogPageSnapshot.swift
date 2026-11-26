import Foundation
/// 列表首屏快照：进入源或分类时先用上次的内容铺满，再在后台请求最新数据。
public struct CatalogPageSnapshot: Codable {
    public var items: [CatalogItem]
    public var page: Int
    public var hasMore: Bool
    public var savedAt: Date
    public init(
        items: [CatalogItem],
        page: Int,
        hasMore: Bool,
        savedAt: Date
    ) {
        self.items = items
        self.page = page
        self.hasMore = hasMore
        self.savedAt = savedAt
    }
}
