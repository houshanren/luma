import Foundation

/// 多图库总览的数据模型：视图只认识这份 DTO，不依赖数据库层类型。
package struct LibraryOverviewSummary: Identifiable {
    package let id: String
    package let name: String
    package let path: String
    package let isNative: Bool
    package let isAppContainer: Bool
    package var photos: Int
    package var videos: Int
    package var albums: Int
    package var folders: Int
    package var updatedAt: Date?
    package var error: String?
    /// 打开过、但不是当前容器的 App 图库：点进去等于切换 App 图库。
    package var isOtherAppLibrary: Bool = false
    package init(
        id: String,
        name: String,
        path: String,
        isNative: Bool,
        isAppContainer: Bool,
        photos: Int,
        videos: Int,
        albums: Int,
        folders: Int,
        updatedAt: Date? = nil,
        error: String? = nil,
        isOtherAppLibrary: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isNative = isNative
        self.isAppContainer = isAppContainer
        self.photos = photos
        self.videos = videos
        self.albums = albums
        self.folders = folders
        self.updatedAt = updatedAt
        self.error = error
        self.isOtherAppLibrary = isOtherAppLibrary
    }
}

/// 多图库总览里的单条照片 / 视频。
package struct LibraryOverviewItem: Identifiable {
    package let photo: PhotoItem
    package let libraryID: String
    package let libraryName: String
    package var id: String { "\(libraryID)|\(photo.id.uuidString)" }
    package init(
        photo: PhotoItem,
        libraryID: String,
        libraryName: String
    ) {
        self.photo = photo
        self.libraryID = libraryID
        self.libraryName = libraryName
    }
}
