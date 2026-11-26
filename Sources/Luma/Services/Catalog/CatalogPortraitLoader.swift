import Foundation

/// 资料库人物外链头像的下载：JavBus 图床要求带 Referer，视图只负责解码与展示。
enum CatalogPortraitLoader {
    static func data(for urlString: String) async -> Data? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              let host = url.host else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return data
    }
}
