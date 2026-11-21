import Foundation

/// 视频转码 / 边下边播缓存的容量管理。
/// 目录结构：`resources/transcodes/<photoID>.hls/`（分片）与 `<photoID>.mp4`（完整转码）。
/// 超过设置里的上限后按最近最少使用淘汰，避免 4K 影片把图库磁盘吃满。
enum VideoCacheManager {
    /// 0 表示不限制。
    static var limitBytes: Int64 {
        Int64(max(0, AppSettings.shared.videoCacheLimitGB)) * 1_000_000_000
    }

    static func totalSize() -> Int64 {
        entries().reduce(Int64(0)) { $0 + $1.size }
    }

    static func formattedTotalSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalSize(), countStyle: .file)
    }

    /// 按修改时间从旧到新删除，直到总量回到上限以内。
    /// 留 10% 余量：一次预热 / 一部新片不会立刻又触发清理。
    static func trimIfNeeded() {
        let limit = limitBytes
        guard limit > 0 else { return }
        let target = Int64(Double(limit) * 0.9)
        // 正在播放 / 预热的会话目录不能删，交给 cleanupOrphans 处理。
        let items = entries()
            .filter { !$0.url.lastPathComponent.contains("-session-") }
            .sorted { $0.date < $1.date }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        var index = 0
        while total > target, index < items.count {
            try? FileManager.default.removeItem(at: items[index].url)
            total -= items[index].size
            index += 1
        }
    }

    /// 启动时清理异常退出留下的会话目录（`*-session-*.hls` 不会成为可复用缓存）。
    static func cleanupOrphans(maxAge: TimeInterval = 6 * 3600) {
        let now = Date()
        for entry in entries() where entry.url.lastPathComponent.contains("-session-") {
            guard now.timeIntervalSince(entry.date) > maxAge else { continue }
            try? FileManager.default.removeItem(at: entry.url)
        }
        trimIfNeeded()
    }

    /// 命中缓存时更新修改时间：LRU 按「最后一次播放」而不是「第一次生成」淘汰。
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func clear() {
        for entry in entries() {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let date: Date
    }

    private static func entries() -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: LibraryPaths.transcodes,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return []
        }
        return items.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".hls") || name.hasSuffix(".mp4") else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return Entry(url: url, size: size(of: url), date: date)
        }
    }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
