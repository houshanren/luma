import Foundation
import AppKit

struct ImportCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileCount: Int
    let cover: NSImage?
    let previewURLs: [URL]
}

struct ImportOptions {
    var createAlbumsFromFolders: Bool = true
    var preserveFolderStructure: Bool = true
    var targetAlbumID: UUID?
}

struct ImportProgress {
    var total: Int
    var completed: Int
    var currentName: String
    var importedCount: Int = 0
    var isCancelled: Bool = false

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}
