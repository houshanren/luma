import Foundation
public struct LibraryData: Codable {
    public var photos: [PhotoItem] = []
    public var albums: [Album] = []
    public var folders: [AlbumFolder] = []

    public init() {}

    public init(photos: [PhotoItem] = [], albums: [Album] = [], folders: [AlbumFolder] = []) {
        self.photos = photos
        self.albums = albums
        self.folders = folders
    }







    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photos = (try? container.decodeIfPresent([PhotoItem].self, forKey: .photos)) ?? []
        albums = (try? container.decodeIfPresent([Album].self, forKey: .albums)) ?? []
        folders = (try? container.decodeIfPresent([AlbumFolder].self, forKey: .folders)) ?? []
    }
}
