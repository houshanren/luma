import AppKit
import Foundation

/// 统一的远程图片缓存：海报、台标、频道 Logo、人物头像共用。
///
/// - 内存层：`NSCache`，按 key 复用解码后的 `NSImage`。
/// - 磁盘层：可选 `diskURL`，命中直接读文件；未命中时由 loader 拉取并原子写入。
/// - 并发合并：同一个 key 同时只发一次请求，避免网格滚动时重复下载。
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for key: String,
               diskURL: URL? = nil,
               loader: @escaping @Sendable () async -> Data?) async -> NSImage? {
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<NSImage?, Never> {
            if let diskURL,
               let data = try? Data(contentsOf: diskURL),
               let image = NSImage(data: data) {
                return image
            }
            guard let data = await loader() else { return nil }
            if let diskURL {
                try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: diskURL, options: .atomic)
            }
            return NSImage(data: data)
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = max(1, Int(image.size.width * image.size.height * 4))
            memory.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    func removeAll() {
        memory.removeAllObjects()
    }
}
