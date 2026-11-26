import Foundation
/// 列表首屏快照：进入源或分类时先用上次的内容铺满，再在后台请求最新数据。
package struct CatalogPageSnapshot: Codable {
    package var items: [CatalogItem]
    package var page: Int
    package var hasMore: Bool
    package var savedAt: Date
    package init(
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
