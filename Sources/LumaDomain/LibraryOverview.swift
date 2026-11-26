import Foundation

/// 多图库总览的数据模型：视图只认识这份 DTO，不依赖数据库层类型。
public struct LibraryOverviewSummary: Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let isNative: Bool
    public let isAppContainer: Bool
    public var photos: Int
    public var videos: Int
    public var albums: Int
    public var folders: Int
    public var updatedAt: Date?
    public var error: String?
    /// 打开过、但不是当前容器的 App 图库：点进去等于切换 App 图库。
    public var isOtherAppLibrary: Bool = false
    public init(
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
public struct LibraryOverviewItem: Identifiable {
    public let photo: PhotoItem
    public let libraryID: String
    public let libraryName: String
    public var id: String { "\(libraryID)|\(photo.id.uuidString)" }
    public init(
        photo: PhotoItem,
        libraryID: String,
        libraryName: String
    ) {
        self.photo = photo
        self.libraryID = libraryID
        self.libraryName = libraryName
    }
}
