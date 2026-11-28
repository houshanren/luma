import Foundation
import LumaAI
import LumaDomain
import TestSupport

/// 2.2 验收台（离线部分）：
/// 1) 工具路由准确率：60 条指令，看该出现的工具在不在、不该出现的工具在不在。
/// 2) 假完成判定：30 条对抗句，看「要不要动手」判得对不对。
/// 3) 单轮工具 schema 体积：路由后相对全量省了多少，用来量化 prompt 成本。
/// 这三项都不依赖模型与 API Key，可稳定复现。

struct RouteCase {
    let question: String
    let area: String
    let must: [String]
    var mustNot: [String] = []
}

let routeCases: [RouteCase] = [
    // 图库 · 检索与信息（8）
    RouteCase(question: "找一下去年在海边拍的照片", area: "library", must: ["search_photos", "unified_search"]),
    RouteCase(question: "这张照片的信息是什么", area: "library", must: ["get_photo_info"]),
    RouteCase(question: "打开这张照片", area: "library", must: ["open_photo"]),
    RouteCase(question: "有多少张照片", area: "library", must: ["library_overview"]),
    RouteCase(question: "列出所有人物", area: "library", must: ["list_people"]),
    RouteCase(question: "查看这张视频的详情", area: "library", must: ["list_videos"]),
    RouteCase(question: "筛选所有五星照片", area: "library", must: ["search_photos"]),
    RouteCase(question: "按拍摄时间排序这些照片", area: "library", must: ["search_photos"]),

    // 图库 · 相簿与文件夹（8）
    RouteCase(question: "把选中的照片按地点整理成相簿", area: "library", must: ["create_albums", "list_albums"]),
    RouteCase(question: "新建一个叫「2025 上海」的相簿", area: "library", must: ["create_albums"]),
    RouteCase(question: "把这张照片加进「旅行」相簿", area: "library", must: ["add_photos_to_album"]),
    RouteCase(question: "把这张照片从「旅行」相簿移出", area: "library", must: ["remove_photos_from_album"]),
    RouteCase(question: "把相簿「2025」改名为「2025 旅行」", area: "library", must: ["rename_album", "list_albums"]),
    RouteCase(question: "把「海边」相簿里的照片移动到一个新文件夹", area: "library", must: ["move_album", "create_folder"]),
    RouteCase(question: "把这张照片设为「旅行」相簿的封面", area: "library", must: ["set_album_cover"]),
    RouteCase(question: "查看相簿列表", area: "library", must: ["list_albums"]),

    // 图库 · 关键词与标题（4）
    RouteCase(question: "给这些照片加上「海边」「日落」关键词", area: "library", must: ["add_keywords"]),
    RouteCase(question: "去掉这几张照片的「重复」关键词", area: "library", must: ["remove_keywords"]),
    RouteCase(question: "把标题改成「外滩日落」", area: "library", must: ["set_title"]),
    RouteCase(question: "列出所有关键词", area: "library", must: ["list_keywords"]),

    // 图库 · 评分与标记（5）
    RouteCase(question: "把这 10 张照片评 5 星", area: "library", must: ["set_rating"]),
    RouteCase(question: "把选中的照片标为红色标签", area: "library", must: ["set_color_label"]),
    RouteCase(question: "收藏这几张照片", area: "library", must: ["set_favorite"]),
    RouteCase(question: "把这 3 张照片隐藏起来", area: "library", must: ["set_hidden"]),
    RouteCase(question: "给这些照片打上旗标", area: "library", must: ["set_flag"]),

    // 图库 · 压缩与美化（2）
    RouteCase(question: "把选中的视频压缩一下，减小体积", area: "library", must: ["compress_photos"]),
    RouteCase(question: "给这几张照片做美化副本", area: "library", must: ["beautify_photos"]),

    // 图库 · 体检与删除（5）
    RouteCase(question: "做一次图库体检，看看能释放多少空间", area: "library", must: ["library_health_report"]),
    RouteCase(question: "看看图库统计", area: "library", must: ["library_health_report"]),
    RouteCase(question: "把最近删除里的照片恢复", area: "library", must: ["restore_photos"]),
    RouteCase(question: "把这些照片移入最近删除", area: "library", must: ["trash_photos"]),
    RouteCase(question: "帮我删掉这 5 张重复的照片", area: "library", must: ["trash_photos", "library_health_report"]),

    // 图库 · 旅行与日报（4）
    RouteCase(question: "看看去年的旅行行程", area: "library", must: ["list_trips"]),
    RouteCase(question: "播放去年的回忆影片", area: "library", must: ["play_trip_memory"]),
    RouteCase(question: "今天有什么值得看的", area: "library", must: ["today_digest"]),
    RouteCase(question: "继续看没看完的视频", area: "library", must: ["resume_watching"]),

    // 影院（10）
    RouteCase(question: "整理影院里未识别的影片", area: "cinema", must: ["cinema_tree", "match_cinema"]),
    RouteCase(question: "刮削这个文件夹里的电影", area: "cinema", must: ["scrape_cinema"]),
    RouteCase(question: "搜索影院里的《沙丘》", area: "cinema", must: ["search_cinema_library"]),
    RouteCase(question: "播放《沙丘》", area: "cinema", must: ["play_cinema"]),
    RouteCase(question: "列出影院的剧集", area: "cinema", must: ["list_cinema_series"]),
    RouteCase(question: "更新这部电影的观看进度", area: "cinema", must: ["update_cinema_state"]),
    RouteCase(question: "给影院做一次体检", area: "cinema", must: ["cinema_health_report"]),
    RouteCase(question: "跳过这部片的片头", area: "cinema", must: ["set_cinema_intro_skip"]),
    RouteCase(question: "管理我的片单", area: "cinema", must: ["manage_cinema_list"]),
    RouteCase(question: "恢复之前忽略的影片", area: "cinema", must: ["restore_cinema_ignored"]),

    // 网络资源（4）
    RouteCase(question: "看看今天有什么新资源", area: "catalog", must: ["catalog_new_today"]),
    RouteCase(question: "搜索番号 ABC-123", area: "catalog", must: ["search_catalog"]),
    RouteCase(question: "把这个加入稍后看", area: "catalog", must: ["set_catalog_watchlist"]),
    RouteCase(question: "关注这个女优", area: "catalog", must: ["follow_catalog_person"]),

    // 网络影院（2）
    RouteCase(question: "搜索网络影院里的影片", area: "networkCinema", must: ["search_network_cinema"]),
    RouteCase(question: "继续播放上次没看完的", area: "networkCinema", must: ["play_network_cinema"]),

    // 网络电视（4）
    RouteCase(question: "今晚有什么电视节目", area: "tv", must: ["tv_tonight", "get_tv_guide"]),
    RouteCase(question: "播放 CCTV1", area: "tv", must: ["play_tv_channel"]),
    RouteCase(question: "收藏这个频道", area: "tv", must: ["favorite_tv_channel"]),
    RouteCase(question: "查看节目单", area: "tv", must: ["get_tv_guide"]),

    // 跨域不串台（4）
    RouteCase(question: "找一下去年在海边拍的照片", area: "library", must: ["search_photos"], mustNot: ["play_cinema", "play_catalog_item"]),
    RouteCase(question: "播放《沙丘》", area: "cinema", must: ["play_cinema"], mustNot: ["play_catalog_item", "play_tv_channel"]),
    RouteCase(question: "播放 CCTV1", area: "tv", must: ["play_tv_channel"], mustNot: ["play_cinema"]),
    RouteCase(question: "搜索番号 ABC-123", area: "catalog", must: ["search_catalog"], mustNot: ["search_cinema_library"])
]

let actionCases: [(String, Bool)] = [
    // 该动手（15）
    ("把选中的照片按地点整理成相簿", true),
    ("新建一个「2025 上海」相簿", true),
    ("把这张照片加入旅行相簿", true),
    ("把这 10 张照片评 5 星", true),
    ("收藏这几张照片", true),
    ("把这 3 张照片隐藏起来", true),
    ("给这些照片加上「海边」关键词", true),
    ("把标题改成「外滩日落」", true),
    ("把选中的视频压缩一下", true),
    ("给这几张照片做美化副本", true),
    ("把这些照片移入最近删除", true),
    ("把最近删除里的照片恢复", true),
    ("帮我把影院里未识别的影片刮削一下", true),
    ("更新这部电影的观看进度", true),
    ("把这张照片设成相簿封面", true),
    // 不该动手（15）
    ("怎么把照片按月份整理成相簿", false),
    ("如何给照片批量打标签", false),
    ("为什么这张照片评分是 5 星", false),
    ("这张照片是什么时候拍的", false),
    ("找一下去年海边的照片", false),
    ("看看图库统计", false),
    ("列出所有人物", false),
    ("今天有什么值得看的", false),
    ("这部电影讲的是什么", false),
    ("不要删除这张照片", false),
    ("别再隐藏这几张了", false),
    ("不用压缩，保持原样", false),
    ("我不想收藏这张", false),
    ("特别模糊的照片有哪些", false),
    ("区别一下这两个相簿", false)
]

/// 工具 schema 的字符量，用来估算 prompt 成本（相对值，不需要分词器）。
func schemaCost(_ tools: [AIRequestTool]) -> Int {
    tools.reduce(0) { sum, tool in
        let params = (try? JSONSerialization.data(withJSONObject: tool.parameters, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return sum + tool.name.count + tool.description.count + params.count
    }
}

/// 与运行时 `aiToolDefinitions` 同一份：中央图库工具 + 四个模块 provider。
let allTools = AILibraryTools.definitions
    + AILibraryTools.catalogToolDefinitions
    + AILibraryTools.cinemaToolDefinitions
    + AILibraryTools.networkCinemaToolDefinitions
    + AILibraryTools.tvToolDefinitions
print("工具总数：\(allTools.count)")
print("写工具：\(AILibraryTools.writeToolNames.count)")
print("图库基础：\(AILibraryTools.definitions.count) · 影院：\(AILibraryTools.cinemaToolDefinitions.count) · 资源：\(AILibraryTools.catalogToolDefinitions.count) · 网络影院：\(AILibraryTools.networkCinemaToolDefinitions.count) · 电视：\(AILibraryTools.tvToolDefinitions.count)")

var routeFailures = 0
var routedCosts: [Int] = []
var dropped = 0

for (index, item) in routeCases.enumerated() {
    let selected = AIToolRouter.select(question: item.question,
                                       area: item.area,
                                       definitions: allTools)
    let names = Set(selected.map(\.name))
    let missing = item.must.filter { !names.contains($0) }
    let leaked = item.mustNot.filter { names.contains($0) }
    if missing.isEmpty && leaked.isEmpty {
        routedCosts.append(schemaCost(selected))
    } else {
        routeFailures += 1
        dropped += 1
        var reason: [String] = []
        if !missing.isEmpty { reason.append("缺 \(missing.joined(separator: ","))") }
        if !leaked.isEmpty { reason.append("多 \(leaked.joined(separator: ","))") }
        print("FAIL  #\(index + 1) [\(item.area)] \(item.question) → \(reason.joined(separator: "；"))")
        print("      实际 \(selected.count) 个：\(selected.map(\.name).joined(separator: ","))")
    }
}

let routeTotal = routeCases.count
let routeAccuracy = Double(routeTotal - routeFailures) / Double(routeTotal)
print("\n工具路由：\(routeTotal - routeFailures) / \(routeTotal) 通过，准确率 \(String(format: "%.1f", routeAccuracy * 100))%")

var actionFailures = 0
for (text, expected) in actionCases {
    let actual = AIActionIntent.hasIntent(text)
    if actual != expected {
        actionFailures += 1
        print("FAIL  假完成判定：\(text) → 实际 \(actual ? "要动手" : "不动手")，期望 \(expected ? "要动手" : "不动手")")
    }
}
let actionTotal = actionCases.count
let actionAccuracy = Double(actionTotal - actionFailures) / Double(actionTotal)
print("假完成判定：\(actionTotal - actionFailures) / \(actionTotal) 通过，准确率 \(String(format: "%.1f", actionAccuracy * 100))%\n")

let fullCost = schemaCost(allTools)
let avgRouted = routedCosts.isEmpty ? fullCost : routedCosts.reduce(0, +) / routedCosts.count
let saving = fullCost > 0 ? 1 - Double(avgRouted) / Double(fullCost) : 0
print("单轮工具 schema：全量 \(fullCost) 字符 → 路由后平均 \(avgRouted) 字符，节省 \(String(format: "%.1f", saving * 100))%")
print("（按字符近似；不含 system prompt 与上下文，仅比较工具定义的相对体积）\n")

// 验收门槛：路由 ≥ 90%、假完成判定 100%、schema 节省 ≥ 50%
expect(routeAccuracy >= 0.90, "工具选择准确率 ≥ 90%（实际 \(String(format: "%.1f", routeAccuracy * 100))%）")
expect(actionFailures == 0, "假完成判定 30 条全对（错 \(actionFailures) 条）")
expect(saving >= 0.50, "单轮工具 schema 节省 ≥ 50%（实际 \(String(format: "%.1f", saving * 100))%）")

if dropped > 0 {
    print("\n提示：\(dropped) 条路由用例未通过，看上面的 FAIL 行定位。\n")
}

CheckRecorder.shared.finish()
