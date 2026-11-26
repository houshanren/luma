import Foundation
import LumaDomain

/// 网络资源工具：来源、检索、稍后看与档案关注。
/// 定义、写操作白名单与确认文案都收在这个文件；执行分派在 `AIToolProviders.catalog`。
package extension AILibraryTools {
    /// 需要用户确认的写操作。
    static let catalogWriteToolNames: Set<String> = [
        "set_catalog_watchlist", "follow_catalog_person"
    ]

    /// 由 `AIToolProviders.catalog` 单独提供。
    static var catalogToolDefinitions: [AIRequestTool] {
        [listCatalogSources, searchCatalog, listCatalogFollowing, listCatalogWatchlist,
         catalogNewToday, browseCatalog, playCatalogItem, setCatalogWatchlist, followCatalogPerson]
    }

    // MARK: - 定义

    private static var listCatalogSources: AIRequestTool {
        AIRequestTool(
            name: "list_catalog_sources",
            description: "列出「网络资源」里已接入的站点：source_id、名称、类型、是否启用与健康状态。搜索或播放网络资源前可先调用它；未启用的源不会被搜索。",
            parameters: objectSchema([:])
        )
    }

    private static var searchCatalog: AIRequestTool {
        AIRequestTool(
            name: "search_catalog",
            description: "在「网络资源」里跨源搜索（会请求站点）。返回按源分组的结果，每条带 ref（如 #1）、source_id、item_id、标题与备注；ref 只对最近一次 list / search 有效。只查网络资源，不查本地照片。",
            parameters: objectSchema([
                "query": stringSchema("搜索词：番号、标题或女优名"),
                "source": stringSchema("只搜某个源：source_id、源名称或类型；省略则搜全部已启用源"),
                "limit": integerSchema("每个源最多返回多少条，默认 30，最大 60", minimum: 1, maximum: 60)
            ], required: ["query"])
        )
    }

    private static var listCatalogFollowing: AIRequestTool {
        AIRequestTool(
            name: "list_catalog_following",
            description: "列出网络资源里关注的女优 / 片商与分类，以及各自的新内容数量。回答「我关注了谁」「有什么更新」时使用。",
            parameters: objectSchema([:])
        )
    }

    private static var listCatalogWatchlist: AIRequestTool {
        AIRequestTool(
            name: "list_catalog_watchlist",
            description: "列出跨源「稍后看」里的网络资源条目（按加入时间倒序），返回 ref、source_id、item_id、标题与备注；可直接用于播放或移出稍后看。",
            parameters: objectSchema([
                "limit": integerSchema("最多返回多少条，默认 100，最大 500", minimum: 1, maximum: 500)
            ])
        )
    }

    private static var catalogNewToday: AIRequestTool {
        AIRequestTool(
            name: "catalog_new_today",
            description: "列出更新日历里今天第一次出现的网络资源条目（纯本地，不请求站点）。返回 ref、source_id、item_id、标题与发现时间，可直接用于播放或加入稍后看。",
            parameters: objectSchema([
                "limit": integerSchema("最多返回多少条，默认 100，最大 500", minimum: 1, maximum: 500)
            ])
        )
    }

    private static var browseCatalog: AIRequestTool {
        AIRequestTool(
            name: "browse_catalog",
            description: "把用户带到网络资源的某个源与页面：首页、排行、稍后看或某个分类。只切换界面，不修改数据。",
            parameters: objectSchema([
                "source": stringSchema("源：source_id、源名称或类型；省略则用当前源"),
                "section": enumSchema(["home", "rank", "favorites", "category"],
                                      "要打开的页面，默认 home"),
                "category": stringSchema("分类名称或分类 id；section = category 时使用")
            ])
        )
    }

    private static var playCatalogItem: AIRequestTool {
        AIRequestTool(
            name: "play_catalog_item",
            description: "直接播放网络资源里的某个条目。用 ref 引用最近一次 search_catalog 或 catalog_new_today 的结果，也可以直接给 source_id + item_id。只打开播放器，不修改数据。",
            parameters: objectSchema([
                "ref": stringSchema("结果编号，例如 #1；来自最近一次 search_catalog / catalog_new_today"),
                "source_id": stringSchema("源 UUID；与 item_id 一起使用"),
                "item_id": stringSchema("条目 id；与 source_id 一起使用")
            ])
        )
    }

    private static var setCatalogWatchlist: AIRequestTool {
        AIRequestTool(
            name: "set_catalog_watchlist",
            description: "把网络资源条目加入或移出跨源「稍后看」。用 refs（最近一次 search_catalog / catalog_new_today 的编号）或 source_id + item_ids 指定条目。",
            parameters: objectSchema([
                "refs": arraySchema(["type": "string"],
                                    description: "结果编号列表，例如 [\"#1\", \"#3\"]"),
                "source_id": stringSchema("源 UUID；与 item_ids 一起使用"),
                "item_ids": arraySchema(["type": "string"], description: "条目 id 列表"),
                "favorite": booleanSchema("true 加入稍后看（默认），false 移出")
            ])
        )
    }

    private static var followCatalogPerson: AIRequestTool {
        AIRequestTool(
            name: "follow_catalog_person",
            description: "关注网络资源里的女优 / 片商 / 模特，之后关注页会显示新作数量。已关注时不会重复添加。",
            parameters: objectSchema([
                "name": stringSchema("人物或片商名称"),
                "role": enumSchema(["女优", "片商", "模特"], "角色，默认女优"),
                "source": stringSchema("从哪个源关注：source_id、源名称或类型；省略则用当前源")
            ], required: ["name"])
        )
    }

    // MARK: - 确认弹窗文案

    static func describeCatalog(_ call: AIToolCall) -> String? {
        let args = arguments(call.arguments)
        switch call.name {
        case "set_catalog_watchlist":
            let favorite = bool(args["favorite"], fallback: true)
            let refs = stringArray(args["refs"])
            let count = refs.isEmpty ? stringArray(args["item_ids"]).count : refs.count
            return "\(favorite ? "加入" : "移出")网络资源稍后看：\(count) 条"
        case "follow_catalog_person":
            let name = string(args["name"]) ?? ""
            let role = string(args["role"]) ?? "女优"
            return "关注\(role)「\(name)」"
        default:
            return nil
        }
    }
}
