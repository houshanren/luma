import Foundation

/// TMDB 官方 API：v3 API Key（query 参数）或 v4 Read Access Token（Bearer 头）。
struct TMDBClient: CinemaMetadataSource {
    let apiKey: String
    let apiBase: String
    let imageBase: String
    let language: String

    var provider: CinemaProvider { .tmdb }

    enum TMDBError: LocalizedError {
        case missingKey
        case invalidBase
        case http(Int, String)
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingKey: return "请先在设置 › 影院里填写 TMDB API Key"
            case .invalidBase: return "TMDB 接口地址无效，请检查设置里的地址"
            case .http(let status, let message): return "TMDB 请求失败（\(status)）：\(message)"
            case .decoding: return "TMDB 返回内容无法解析"
            }
        }
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usesBearer: Bool { trimmedKey.hasPrefix("eyJ") }

    func search(query: String, isTV: Bool, year: Int?) async throws -> [CinemaMatch] {
        guard !trimmedKey.isEmpty else { throw TMDBError.missingKey }
        let path = isTV ? "/search/tv" : "/search/movie"
        guard var components = URLComponents(string: apiBase.trimmingCharacters(in: .whitespaces)
                                                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw TMDBError.invalidBase
        }
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "page", value: "1")
        ]
        if let year {
            items.append(URLQueryItem(name: isTV ? "first_air_date_year" : "year", value: String(year)))
        }
        if !usesBearer {
            items.append(URLQueryItem(name: "api_key", value: trimmedKey))
        }
        components.queryItems = items
        guard let url = components.url else { throw TMDBError.invalidBase }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesBearer {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (object["status_message"] as? String) ?? "HTTP \(status)"
            throw TMDBError.http(status, message)
        }
        guard let results = object["results"] as? [[String: Any]] else {
            throw TMDBError.decoding
        }
        return results.compactMap { parse($0, isTV: isTV) }
    }

    func imageURL(path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let base = imageBase.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        return "\(base)/\(size)\(path)"
    }

    private func parse(_ item: [String: Any], isTV: Bool) -> CinemaMatch? {
        guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
        let title = (isTV ? item["name"] as? String : item["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let original = (isTV ? item["original_name"] as? String : item["original_title"] as? String)
        let date = (isTV ? item["first_air_date"] as? String : item["release_date"] as? String) ?? ""
        let year = Int(date.prefix(4))
        let genreIDs = (item["genre_ids"] as? [NSNumber])?.map { $0.intValue } ?? []
        var seenGenres = Set<String>()
        let genres = genreIDs.compactMap { Self.genreNames[$0] }.filter { seenGenres.insert($0).inserted }
        return CinemaMatch(id: String(id),
                           isTV: isTV,
                           title: title,
                           originalTitle: original,
                           year: year,
                           posterURL: imageURL(path: item["poster_path"] as? String, size: "w500"),
                           backdropURL: imageURL(path: item["backdrop_path"] as? String, size: "w780"),
                           overview: item["overview"] as? String,
                           rating: (item["vote_average"] as? NSNumber)?.doubleValue,
                           voteCount: (item["vote_count"] as? NSNumber)?.intValue,
                           genres: genres)
    }

    /// 搜索结果只给 genre_ids，这里换成中文类型名，和豆瓣的 types 对齐。
    private static let genreNames: [Int: String] = [
        12: "冒险", 14: "奇幻", 16: "动画", 18: "剧情", 27: "恐怖", 28: "动作",
        35: "喜剧", 36: "历史", 37: "西部", 53: "惊悚", 80: "犯罪", 99: "纪录",
        878: "科幻", 9648: "悬疑", 10402: "音乐", 10749: "爱情", 10751: "家庭",
        10752: "战争", 10770: "电视电影", 10759: "动作冒险", 10762: "儿童",
        10763: "新闻", 10764: "真人秀", 10765: "科幻奇幻", 10766: "肥皂剧",
        10767: "脱口秀", 10768: "战争政治"
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
