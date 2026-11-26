import Foundation

/// 影响 `visiblePhotos` 的状态指纹：筛选、排序、搜索等变化都会换 key。
///
/// 用结构体而不是 `[String].joined(...)`：滚动时它每帧都会被读取
/// （顶栏日期范围、查看器序号都依赖它），旧实现里有 30 次字符串拼接
/// 和 `String(describing:)` 反射，分配量太大。这里字段直接读取，比较即逐字段相等。
struct VisibleStateKey: Hashable {
    let contentRevision: Int
    let windowRevision: Int
    let sidebarItem: SidebarItem
    let selectedKeyword: String?
    let searchText: String
    let semanticSearchTags: [String]
    let searchScope: SearchScope
    let analysisCount: Int
    let photoFilter: PhotoFilter
    let keywordFilter: String?
    let ratingFilter: Int
    let flagFilter: PhotoFlag?
    let colorLabelFilter: PhotoColorLabel?
    let selectedPlaceID: String?
    let selectedPersonID: Int64?
    let sortKey: SortKey
    let sortAscending: Bool
    let cloudRevision: Int
    let cloudScope: CloudScope
    let cloudAnalysisCount: Int
    let cloudMetadataRevision: Int
    let cloudPeopleCount: Int
    let isLoadingSystemLibrary: Bool
    let searchAnalysisCount: Int
    let systemAnalysisCount: Int
    let similarSourceID: UUID?
    let similarCount: Int
    let systemIndexSignature: String
    let systemWindowRevision: Int
    let hasLoadedSystemWindow: Bool
    let favoriteBucketID: String?
    let favoritesDigestToken: String
}

/// 分段缓存键：可见集合 + 分组方式 + 堆叠模式与展开版本。
struct SectionsCacheKey: Hashable {
    let visible: VisibleStateKey
    let grouping: GridGrouping
    let stackMode: StackMode
    let stackRevision: Int
}

/// 堆叠计划 / 角标缓存键：只看可见集合与堆叠模式（展开状态不影响分组结果）。
struct StackPlanCacheKey: Hashable {
    let visible: VisibleStateKey
    let stackMode: StackMode
}

/// 查看器位置 / 序号缓存的键：分页窗口（`pagedKey`）与普通可见集合是两套来源，
/// 混用会让缓存命中到另一个范围的数据。
enum ViewerKey: Hashable {
    case paged(String)
    case visible(VisibleStateKey)
}
