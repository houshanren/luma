import Foundation

/// 刮削数据源：TMDB 与豆瓣都归一到 `CinemaMatch`，上层只做标题打分。
protocol CinemaMetadataSource {
    var provider: CinemaProvider { get }
    func search(query: String, isTV: Bool, year: Int?) async throws -> [CinemaMatch]
}
