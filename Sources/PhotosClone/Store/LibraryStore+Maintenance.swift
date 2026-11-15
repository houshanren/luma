import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - 缓存

    func cloudThumbnailCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: LibraryPaths.cloudThumbs,
                                             includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    func clearCloudThumbnailCache() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: LibraryPaths.cloudThumbs,
                                                        includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
        cloudDirectoryCache.removeAll()
        ImageLoader.clearMemoryCaches()
        showToast("已清理网盘缩略图缓存")
    }

    func systemThumbnailCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: LibraryPaths.systemThumbs,
                                             includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    func clearSystemThumbnailCache() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: LibraryPaths.systemThumbs,
                                                        includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
        ImageLoader.clearMemoryCaches()
        showToast("已清理系统图库缩略图缓存")
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
