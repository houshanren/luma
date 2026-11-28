import Foundation
import LumaDomain

/// 工具路由：把 86 个工具按「当前页面 + 用户意图」收窄到一轮真正需要的一小组。
/// 目标是少而准：模型不必在几十个近似工具里做选择，token 与误选都会下降。
package enum AIToolRouter {
    /// 单轮最多暴露的工具数。比全量少一个数量级，仍保留跨模块兜底。
    /// 24 是验收台量出来的：18 时「新建文件夹 / 设封面」会在相簿意图下被截断。
    package static let defaultLimit = 24

    /// 永远保留的检索与导航底座。保持精简，给领域工具留出名额。
    private static let coreNames: [String] = [
        "search_photos", "unified_search", "open_search_result", "get_photo_info",
        "navigate", "select_photos", "open_photo"
    ]

    package static func select(question: String,
                               area: String,
                               definitions: [AIRequestTool],
                               limit: Int = defaultLimit) -> [AIRequestTool] {
        let lowered = question.lowercased()
        let domains = detectDomains(lowered, area: area)
        let intents = detectIntents(lowered)

        var selectedNames: [String] = []
        var seen = Set<String>()

        func append(_ names: [String]) {
            for name in names where seen.insert(name).inserted {
                selectedNames.append(name)
            }
        }

        append(coreNames)
        for domain in domains {
            append(names(for: domain, intents: intents))
        }

        // 当前页面不是图库时，补一组图库兜底，避免「顺便问一句照片」失联。
        if !domains.contains("library"),
           intents.contains(Intent.album) || intents.contains(Intent.keyword) {
            append(names(for: "library", intents: intents))
        }

        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        var result: [AIRequestTool] = []
        for name in selectedNames {
            if let tool = byName[name] {
                result.append(tool)
                if result.count >= limit { break }
            }
        }
        // 外部连接器（MCP）由用户显式安装、数量少：始终保留，不参与领域收窄。
        for tool in definitions where tool.name.hasPrefix("mcp__")
            && !result.contains(where: { $0.name == tool.name }) {
            result.append(tool)
        }
        // 极端情况下路由为空：交给调用方决定是否回退到全量工具。
        return result
    }

    // MARK: - 领域

    private static func detectDomains(_ question: String, area: String) -> [String] {
        var result: [String] = []
        func add(_ value: String) {
            if !result.contains(value) { result.append(value) }
        }

        switch area {
        case "cinema": add("cinema")
        case "catalog": add("catalog")
        case "networkCinema": add("networkCinema")
        case "tv": add("tv")
        case "atlas": add("atlas")
        default: add("library")
        }

        if containsAny(question, ["影院", "电影", "剧集", "刮削", "匹配", "片单", "跳过片头", "季", "集"]) {
            add("cinema")
        }
        if containsAny(question, ["网络资源", "站点", "番号", "女优", "片商", "稍后看", "资源站"]) {
            add("catalog")
        }
        if containsAny(question, ["网络影院", "影视源", "在线影院"]) {
            add("networkCinema")
        }
        if containsAny(question, ["电视", "频道", "节目单", "直播", "回看", "epg", "今晚"]) {
            add("tv")
        }
        if containsAny(question, ["照片", "图库", "相簿", "相册", "关键词", "评分", "星级", "旗标", "色标", "压缩", "美化", "最近删除", "旅行", "回忆"]) {
            add("library")
        }
        return result
    }

    private static func names(for domain: String, intents: Set<Intent>) -> [String] {
        switch domain {
        case "cinema":
            if intents.contains(.play) {
                return ["list_cinema_scopes", "search_cinema_library", "list_cinema_series",
                        "list_cinema_activity", "play_cinema", "navigate_cinema", "resume_watching"]
            }
            if intents.contains(.organize) {
                return ["list_cinema_scopes", "cinema_tree", "cinema_health_report",
                        "search_cinema_candidates", "apply_cinema_match", "scrape_cinema",
                        "match_cinema", "refresh_cinema_metadata", "list_cinema_items",
                        "list_cinema_series"]
            }
            if intents.contains(.state) {
                return ["list_cinema_scopes", "search_cinema_library", "list_cinema_series",
                        "list_cinema_lists", "update_cinema_state", "manage_cinema_list",
                        "set_cinema_intro_skip", "manage_cinema_progress",
                        "ignore_cinema", "restore_cinema_ignored", "list_cinema_activity"]
            }
            return ["list_cinema_scopes", "search_cinema_library", "list_cinema_series",
                    "list_cinema_activity", "play_cinema", "cinema_health_report"]

        case "catalog":
            if intents.contains(.play) {
                return ["list_catalog_sources", "search_catalog", "browse_catalog", "play_catalog_item"]
            }
            if intents.contains(.update) || intents.contains(.state) {
                return ["list_catalog_sources", "search_catalog", "catalog_new_today",
                        "list_catalog_watchlist", "set_catalog_watchlist",
                        "list_catalog_following", "follow_catalog_person", "browse_catalog"]
            }
            return ["list_catalog_sources", "search_catalog", "catalog_new_today",
                    "list_catalog_watchlist", "browse_catalog"]

        case "networkCinema":
            return ["list_network_cinema_sources", "list_network_cinema",
                    "search_network_cinema", "network_cinema_history", "play_network_cinema"]

        case "tv":
            return ["list_tv_sources", "list_tv_channels", "get_tv_guide", "tv_tonight",
                    "play_tv_channel", "favorite_tv_channel", "navigate_tv"]

        case "atlas":
            return ["search_photos", "unified_search", "get_photo_info", "open_search_result"]

        default:
            return libraryNames(intents: intents)
        }
    }

    private static func libraryNames(intents: Set<Intent>) -> [String] {
        // 先给「解析对象」的底座（要找相簿 / 文件夹 / 关键词的 id），再给意图工具，最后是概览。
        // 顺序有讲究：上限 18 会截断尾部，意图工具必须排在概览前面，否则「改名」会拿不到 rename_album。
        var result = ["list_albums", "list_folders", "list_videos", "list_keywords", "list_people"]
        if intents.contains(.album) {
            result += ["create_albums", "add_photos_to_album", "remove_photos_from_album",
                       "rename_album", "delete_album", "move_album", "set_album_cover",
                       "create_folder", "rename_folder", "delete_folder"]
        }
        if intents.contains(.keyword) {
            result += ["add_keywords", "remove_keywords", "set_title"]
        }
        if intents.contains(.rating) {
            result += ["set_rating", "set_flag", "set_color_label", "set_favorite", "set_hidden"]
        }
        if intents.contains(.process) {
            result += ["compress_photos", "beautify_photos"]
        }
        if intents.contains(.trash) {
            result += ["trash_photos", "restore_photos"]
        }
        if intents.contains(.health) {
            result += ["library_health_report", "library_insights"]
        }
        if intents.contains(.trip) {
            result += ["list_trips", "play_trip_memory"]
        }
        if intents.contains(.digest) {
            result += ["today_digest", "resume_watching"]
        }
        result += ["library_overview", "library_insights", "library_health_report"]
        return result
    }

    // MARK: - 意图

    private enum Intent: Hashable {
        case album, keyword, rating, process, trash, health, trip, digest
        case play, organize, state, update
    }

    private static func detectIntents(_ question: String) -> Set<Intent> {
        var result: Set<Intent> = []
        if containsAny(question, ["相簿", "相册", "文件夹", "归组", "整理成"]) { result.insert(.album) }
        if containsAny(question, ["关键词", "标签", "标题", "改名"]) { result.insert(.keyword) }
        if containsAny(question, ["评分", "星级", "几星", "旗标", "色标", "收藏", "隐藏"])
            || question.range(of: "[0-9一二三四五]\\s*星", options: .regularExpression) != nil {
            result.insert(.rating)
        }
        if containsAny(question, ["压缩", "美化", "减小", "体积"]) { result.insert(.process) }
        if containsAny(question, ["删除", "删掉", "最近删除", "恢复", "清理"]) { result.insert(.trash) }
        if containsAny(question, ["体检", "重复", "模糊", "空间", "画像", "统计"]) { result.insert(.health) }
        if containsAny(question, ["旅行", "行程", "回忆"]) { result.insert(.trip) }
        if containsAny(question, ["今天", "日报", "续看", "没看完"]) { result.insert(.digest) }
        if containsAny(question, ["播放", "继续看", "看这部", "看那部", "直播", "回看"]) { result.insert(.play) }
        if containsAny(question, ["整理", "刮削", "匹配", "识别", "季集"]) { result.insert(.organize) }
        if containsAny(question, ["收藏", "评分", "想看", "片单", "清单", "跳过片头", "片头", "进度", "忽略", "恢复"])
            { result.insert(.state) }
        if containsAny(question, ["更新", "新片", "稍后看", "关注"]) { result.insert(.update) }
        return result
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
