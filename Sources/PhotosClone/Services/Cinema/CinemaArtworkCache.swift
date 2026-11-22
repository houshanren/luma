import AppKit

/// 刮削海报 / 背景图的内存缓存。图片本身已由数据源缩放，直接按 URL 复用即可。
final class CinemaArtworkCache {
    static let shared = CinemaArtworkCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // 不设条数 / 字节硬上限：最多也就上万张，NSCache 在系统内存紧张时
        // 仍会自动回收，不会把内存吃死；大库来回滚动时海报可以一直复用。
        cache.countLimit = 0
        cache.totalCostLimit = 0
    }

    nonisolated func image(for urlString: String) async -> NSImage? {
        let key = urlString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        // 豆瓣图片 CDN 会校验 Referer，缺失时直接返回 418。
        if url.host?.contains("douban") == true {
            request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 == 200,
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
