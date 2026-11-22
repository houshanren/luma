import AppKit

/// 刮削海报 / 背景图的内存缓存。
/// 统一走 `ArtworkCache`，与电视 Logo、人物头像共用同一套内存层与并发合并。
final class CinemaArtworkCache {
    static let shared = CinemaArtworkCache()

    nonisolated func image(for urlString: String) async -> NSImage? {
        await ArtworkCache.shared.image(for: "cinema:\(urlString)") {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            // 豆瓣图片 CDN 会校验 Referer，缺失时直接返回 418。
            if url.host?.contains("douban") == true {
                request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            }
            guard let (data, response) = try? await Self.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode ?? 0 == 200 else { return nil }
            return data
        }
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
