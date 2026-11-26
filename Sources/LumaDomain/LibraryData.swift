import Foundation
package struct LibraryData: Codable {
    package var photos: [PhotoItem] = []
    package var albums: [Album] = []
    package var folders: [AlbumFolder] = []

    package init() {}

    package init(photos: [PhotoItem] = [], albums: [Album] = [], folders: [AlbumFolder] = []) {
        self.photos = photos
        self.albums = albums
        self.folders = folders
    }







    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photos = (try? container.decodeIfPresent([PhotoItem].self, forKey: .photos)) ?? []
        albums = (try? container.decodeIfPresent([Album].self, forKey: .albums)) ?? []
        folders = (try? container.decodeIfPresent([AlbumFolder].self, forKey: .folders)) ?? []
    }
}
