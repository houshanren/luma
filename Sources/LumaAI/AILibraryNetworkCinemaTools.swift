import Foundation
import LumaDomain

/// 网络影院工具：聚合列表、跨源搜索、续看与播放。
/// 定义收在这个文件；执行分派在 `AIToolProviders.networkCinema`。
package extension AILibraryTools {
    static var networkCinemaToolDefinitions: [AIRequestTool] {
        [listNetworkCinemaSources, listNetworkCinema, searchNetworkCinema,
         networkCinemaHistory, playNetworkCinema]
    }

    // MARK: - 定义

    private static var listNetworkCinemaSources: AIRequestTool {
        AIRequestTool(
            name: "list_network_cinema_sources",
            description: "列出作为「网络影院」聚合来源的影视源：source_id、名称、是否启用与健康状态。只有这些源会出现在电影 / 电视剧页。",
            parameters: objectSchema([:])
        )
    }

    private static var listNetworkCinema: AIRequestTool {
        AIRequestTool(
            name: "list_network_cinema",
            description: "列出网络影院当前聚合的电影或剧集（按标题去重，含 TMDB 补全后的标题、年份、评分与来源）。返回 ref，可直接用于 play_network_cinema 或加入稍后看。",
            parameters: objectSchema([
                "tab": enumSchema(["movies", "shows"], "电影或剧集，默认 movies"),
                "limit": integerSchema("最多返回多少条，默认 100，最大 500", minimum: 1, maximum: 500)
            ])
        )
    }

    private static var searchNetworkCinema: AIRequestTool {
        AIRequestTool(
            name: "search_network_cinema",
            description: "在网络影院的已启用影视源里跨源搜索电影 / 剧集（会请求站点）。返回 ref、source_id、item_id、标题与来源；同名影片会聚合多源候选。",
            parameters: objectSchema([
                "query": stringSchema("片名或剧名关键词"),
                "source": stringSchema("只搜某个源：source_id 或源名称；省略则搜全部影视源"),
                "limit": integerSchema("每个源最多返回多少条，默认 30，最大 60", minimum: 1, maximum: 60)
            ], required: ["query"])
        )
    }

    private static var networkCinemaHistory: AIRequestTool {
        AIRequestTool(
            name: "network_cinema_history",
            description: "列出网络影院里还没看完的条目：标题、来源、上次看到第几集与进度。用于回答「上次看到哪了」或继续播放。",
            parameters: objectSchema([
                "limit": integerSchema("最多返回多少条，默认 50，最大 500", minimum: 1, maximum: 500)
            ])
        )
    }

    private static var playNetworkCinema: AIRequestTool {
        AIRequestTool(
            name: "play_network_cinema",
            description: "直接播放网络影院里的某个条目。用 ref 引用最近一次 list_network_cinema / search_network_cinema / network_cinema_history 的结果，也可以直接给 source_id + item_id。只打开播放器，不修改数据。",
            parameters: objectSchema([
                "ref": stringSchema("结果编号，例如 #1"),
                "source_id": stringSchema("源 UUID；与 item_id 一起使用"),
                "item_id": stringSchema("条目 id；与 source_id 一起使用")
            ])
        )
    }
}
