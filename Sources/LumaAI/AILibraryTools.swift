import Foundation
import LumaDomain

/// 提供给智能助手的本地工具：检索、浏览、相簿、文件夹、图片与视频。
/// 所有写操作都先经过用户确认，再走 LibraryStore 现有方法落盘。
package enum AILibraryTools {
    /// 需要用户确认的写操作。
    package static let writeToolNames: Set<String> = Set([
        "create_albums", "add_photos_to_album", "remove_photos_from_album",
        "rename_album", "delete_album", "move_album", "set_album_cover",
        "create_folder", "rename_folder", "delete_folder",
        "set_favorite", "set_hidden", "set_rating", "set_flag", "set_color_label",
        "add_keywords", "remove_keywords",
        "set_title", "compress_photos", "beautify_photos", "trash_photos", "restore_photos",
        "cleanup_tv_channels", "make_smart_album"
    ])
        .union(cinemaWriteToolNames)
        .union(catalogWriteToolNames)
        .union(tvWriteToolNames)

    package static var definitions: [AIRequestTool] {
        [searchPhotos, unifiedSearch, listAlbums, listFolders, listVideos,
         getPhotoInfo, listKeywords, listPeople, libraryOverview, libraryInsights,
         listTrips, playTripMemory, libraryHealthReport, resumeWatching, todayDigest,
         navigate, selectPhotos, openPhoto, openSearchResult,
         createAlbums, addPhotosToAlbum, removePhotosFromAlbum,
         renameAlbum, deleteAlbum, moveAlbum, setAlbumCover,
         createFolder, renameFolder, deleteFolder,
         setFavorite, setHidden, setRating, setFlag, setColorLabel,
         addKeywords, removeKeywords,
         setTitle, compressPhotos, beautifyPhotos, trashPhotos, restorePhotos,
         generateShareCopy, cleanupTVChannels, makeSmartAlbum]
    }

    /// 工具总数（界面展示用，避免每次重算 schema）。影院 / 资源 / 网络影院 / 网络电视工具由 provider 单独提供。
    package static let count = definitions.count
        + catalogToolDefinitions.count
        + cinemaToolDefinitions.count
        + networkCinemaToolDefinitions.count
        + tvToolDefinitions.count

    /// 高风险写工具：「仅高风险」审批模式下仍然弹窗。
    /// 只收会删除、覆盖原文件或批量改大量数据的操作。
    package static let riskyToolNames: Set<String> = [
        "trash_photos", "compress_photos",
        "delete_album", "delete_folder",
        "scrape_cinema", "refresh_cinema_metadata",
        "ignore_cinema", "manage_cinema_progress"
    ]

    /// 同一次工具调用是否属于高风险；少数工具要按 action 判断。
    package static func isRisky(_ call: AIToolCall) -> Bool {
        if riskyToolNames.contains(call.name) { return true }
        if call.name == "manage_cinema_list" {
            let args = arguments(call.arguments)
            let action = string(args["action"]) ?? ""
            return action == "delete" || action == "clear_items"
        }
        return false
    }

    /// 写操作判定：内置写工具 + 外部 MCP 工具（可能产生副作用，一律走审批）。
    package static func isWrite(_ name: String) -> Bool {
        writeToolNames.contains(name) || name.hasPrefix("mcp__")
    }

    /// 工具的风险等级：只读 / 可逆写 / 破坏性 / 外部副作用。
    /// 这是审批 2.0 的唯一分类入口，界面与执行侧不再各自维护名单。
    package static func risk(for name: String, arguments args: [String: Any] = [:]) -> AIRiskLevel {
        if name.hasPrefix("mcp__") { return .external }
        if !writeToolNames.contains(name) {
            if externalToolNames.contains(name) || name.hasPrefix("play_") {
                return .external
            }
            return .read
        }
        if riskyToolNames.contains(name) { return .destructive }
        if name == "manage_cinema_list" {
            let action = string(args["action"]) ?? ""
            if action == "delete" || action == "clear_items" { return .destructive }
        }
        if name == "compress_photos" || name == "trash_photos" { return .destructive }
        if externalToolNames.contains(name) { return .external }
        return .reversible
    }

    /// 有外部副作用的工具：会请求站点、打开外链或开始播放。
    package static let externalToolNames: Set<String> = [
        "search_catalog", "browse_catalog", "play_catalog_item",
        "play_cinema", "play_network_cinema", "play_tv_channel",
        "play_trip_memory", "open_photo", "open_search_result"
    ]

    /// 工具的中文短名：助手运行中用一句话说明「正在做什么」。
    package static func shortTitle(for name: String) -> String {
        switch name {
        case "search_photos", "unified_search", "list_videos", "list_albums", "list_folders",
             "search_cinema_library", "search_catalog", "list_catalog_watchlist",
             "catalog_new_today", "search_network_cinema", "list_network_cinema":
            return "检索内容"
        case "get_photo_info", "list_keywords", "list_people", "library_overview":
            return "读取图库信息"
        case "library_insights":
            return "分析图库画像"
        case "list_trips":
            return "读取旅行"
        case "play_trip_memory":
            return "播放回忆影片"
        case "library_health_report":
            return "读取图库体检"
        case "resume_watching":
            return "汇总未看完"
        case "today_digest":
            return "生成今日日报"
        case "list_cinema_items", "cinema_tree", "list_cinema_scopes",
             "list_cinema_series", "list_cinema_lists", "list_cinema_activity",
             "list_catalog_sources", "list_catalog_following", "list_network_cinema_sources",
             "network_cinema_history":
            return "读取目录与清单"
        case "search_cinema_candidates":
            return "搜索影片候选"
        case "apply_cinema_match":
            return "写回匹配结果"
        case "scrape_cinema", "refresh_cinema_metadata", "match_cinema":
            return "刮削影片资料"
        case "create_albums", "add_photos_to_album", "remove_photos_from_album",
             "rename_album", "delete_album", "move_album", "set_album_cover",
             "create_folder", "rename_folder", "delete_folder":
            return "整理相簿"
        case "compress_photos", "beautify_photos":
            return "处理图片"
        case "trash_photos", "restore_photos":
            return "整理最近删除"
        case "set_favorite", "set_hidden", "add_keywords", "remove_keywords", "set_title",
             "set_rating", "set_flag", "set_color_label":
            return "修改照片信息"
        case "update_cinema_state", "manage_cinema_list", "ignore_cinema",
             "restore_cinema_ignored", "set_cinema_intro_skip", "manage_cinema_progress":
            return "更新影院状态"
        case "navigate", "select_photos", "open_photo", "open_search_result",
             "navigate_cinema", "play_cinema", "browse_catalog",
             "play_catalog_item", "play_network_cinema",
             "navigate_tv", "play_tv_channel":
            return "调整界面"
        case "list_tv_sources", "list_tv_channels", "get_tv_guide", "tv_tonight":
            return "读取电视节目"
        case "cinema_health_report":
            return "读取影院报告"
        case "favorite_tv_channel":
            return "收藏频道"
        case "generate_share_copy":
            return "写分享文案"
        case "cleanup_tv_channels":
            return "清洗电视频道"
        case "make_smart_album":
            return "创建智能相簿"
        default:
            if name.hasPrefix("list_") { return "读取列表" }
            return "执行操作"
        }
    }

    // MARK: - 检索

    private static var searchPhotos: AIRequestTool {
        AIRequestTool(
            name: "search_photos",
            description: "按关键词、时间、地点、场景、文件名、类型、相簿、文件夹、评分、旗标、色标或人物搜索当前图库，返回照片与视频的 id 与基本信息。结果按 offset 翻页、返回总数与 has_more：一次可传多个条件，limit 单页最多 500，需要更多时带上 next_offset 继续取。需要引用或操作具体项目时先调用它。",
            parameters: objectSchema([
                "query": stringSchema("搜索词，例如「去年 海边」「小猫」「截图」「IMG_2043」；支持时间词（去年 / 本月 / 2024年5月）；留空则按条件过滤"),
                "filter": enumSchema(["all", "photos", "videos", "favorites", "hidden", "screenshots", "edited"],
                                     "按类型 / 状态过滤，默认 all"),
                "album_id": stringSchema("只搜这个相簿里的项目：相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("只搜这个相簿里的项目：相簿名称"),
                "folder_id": stringSchema("只搜这个文件夹（含子文件夹）里各相簿的项目：文件夹 id"),
                "folder_name": stringSchema("只搜这个文件夹（含子文件夹）里各相簿的项目：文件夹名称"),
                "rating_min": integerSchema("只要评分不低于这个星级（1–5）", minimum: 1, maximum: 5),
                "flag": enumSchema(["none", "pick", "reject"],
                                   "按旗标筛选：pick 留用、reject 排除、none 无旗标"),
                "color_label": enumSchema(["none", "red", "orange", "yellow", "green",
                                           "blue", "purple", "gray"],
                                          "按色标筛选"),
                "has_location": booleanSchema("只要带 GPS 位置的项目"),
                "person": stringSchema("只搜包含这个人物（人物名单里的名字）的项目"),
                "limit": integerSchema("单页最多返回数量，默认 50，最大 500", minimum: 1, maximum: 500),
                "offset": integerSchema("跳过前多少条命中，用于翻页；默认 0", minimum: 0, maximum: 200000)
            ])
        )
    }

    /// 跨来源统一检索：与界面搜索结果页共用同一套 SearchProviding 内核。
    private static var unifiedSearch: AIRequestTool {
        AIRequestTool(
            name: "unified_search",
            description: "在统一搜索内核里跨来源检索：图库、网盘、影院、网络影院、网络电视、网络资源。返回每个来源的分区、总数、类型计数（图片 / 视频 / 相簿 / 人物 / 场景 / 频道 / 节目 / 条目等）、来源与分类分布，以及命中的条目。用户问「全库搜」「各模块一起搜」「这些结果里有哪些」时优先用它；只要本地照片时仍用 search_photos（可翻页取全量）。",
            parameters: objectSchema([
                "query": stringSchema("搜索词，支持时间词与自然语言，例如「去年 海边」「猫」「CCTV1」"),
                "sources": arraySchema(["type": "string"],
                                       description: "可选来源：library / cloud / cinema / networkCinema / television / catalog；不传按 scope 决定"),
                "scope": enumSchema(["global", "module"],
                                    "global 搜全部已启用模块（默认）；module 只搜当前页面所属模块"),
                "limit": integerSchema("每个来源最多返回多少条，默认 12，最大 50", minimum: 1, maximum: 50)
            ], required: ["query"])
        )
    }

    private static var getPhotoInfo: AIRequestTool {
        AIRequestTool(
            name: "get_photo_info",
            description: "查看若干项目的完整信息：尺寸、大小、拍摄与加入时间、相机 / 镜头 / 参数、地点、评分 / 旗标 / 色标、关键词、所属相簿与文件夹、是否编辑、人物与来源。需要详情或核对元数据时用它。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "limit": integerSchema("最多返回多少项，默认 50，最大 100", minimum: 1, maximum: 100)
            ], required: ["photo_ids"])
        )
    }

    private static var listKeywords: AIRequestTool {
        AIRequestTool(
            name: "list_keywords",
            description: "列出当前范围的关键词及出现次数（按次数倒序），用于整理、复用已有标签或回答「有哪些标签」。",
            parameters: objectSchema([
                "query": stringSchema("只看包含这个词的关键词，可省略"),
                "limit": integerSchema("最多返回多少个关键词，默认 100，最大 1000", minimum: 1, maximum: 1000)
            ])
        )
    }

    private static var listPeople: AIRequestTool {
        AIRequestTool(
            name: "list_people",
            description: "列出当前范围的人物名单：id、名称、照片数。要按人物找照片时，把名字传给 search_photos 的 person 参数即可。",
            parameters: objectSchema([
                "query": stringSchema("只看名字包含这个词的人物，可省略"),
                "limit": integerSchema("最多返回多少个人物，默认 200，最大 1000", minimum: 1, maximum: 1000)
            ])
        )
    }

    private static var libraryOverview: AIRequestTool {
        AIRequestTool(
            name: "library_overview",
            description: "一次了解当前图库概况：项目 / 照片 / 视频数、收藏 / 隐藏 / 带位置 / 已评分 / 已编辑数量、相簿与文件夹数、人物数、高频关键词，以及当前范围与筛选。回答「有多少」「概览」「统计」类问题先调用它，避免多次检索。",
            parameters: objectSchema([:])
        )
    }

    private static var libraryInsights: AIRequestTool {
        AIRequestTool(
            name: "library_insights",
            description: "深入分析当前图库：拍摄年份与月份分布、常用机型与镜头、出现最多的地点、存储占用、视频占比，以及未打关键词 / 未评分 / 没有定位 / 不在任何相簿的覆盖情况。回答「图库有什么特点」「哪年拍得最多」「用什么设备」「去过哪些地方」「还有多少没整理」时用它；只要总量仍用 library_overview。",
            parameters: objectSchema([
                "top": integerSchema("每类分布最多返回多少项，默认 8，最大 30", minimum: 1, maximum: 30)
            ])
        )
    }

    private static var listTrips: AIRequestTool {
        AIRequestTool(
            name: "list_trips",
            description: "列出自动识别的旅行：标题、起止日期、天数、地点数、照片数与封面。识别依据是拍摄时间与 GPS 位置，适合回答「我去过几次旅行」「去年去了哪」「最近一次旅行拍了什么」。要直接播放某次旅行的回忆影片，用 play_trip_memory。",
            parameters: objectSchema([
                "limit": integerSchema("最多返回多少次旅行，默认 10，最大 50", minimum: 1, maximum: 50),
                "year": integerSchema("只看这一年的旅行，例如 2024", minimum: 1990, maximum: 2100)
            ])
        )
    }

    private static var playTripMemory: AIRequestTool {
        AIRequestTool(
            name: "play_trip_memory",
            description: "把一次自动识别的旅行播放成回忆影片（幻灯片）。trip 传 list_trips 返回的 id、标题关键词，或 latest 表示最近一次。只播放，不修改任何照片。",
            parameters: objectSchema([
                "trip": stringSchema("旅行 id、标题关键词，或 latest"),
                "style": enumSchema(["classic", "cinematic", "fresh"], "回忆风格，默认 cinematic")
            ], required: ["trip"])
        )
    }

    private static var libraryHealthReport: AIRequestTool {
        AIRequestTool(
            name: "library_health_report",
            description: "读取图库体检结果：可能模糊的照片、相似连拍里可删除的备选、体积过大的视频，以及可释放空间。还没有结果时传 scan=true 会在后台开始体检（进度在左下角任务条），open=true 可直接打开体检页面。适合回答「有没有重复或模糊照片」「清理能省多少空间」「图库哪里有问题」。",
            parameters: objectSchema([
                "scan": booleanSchema("没有结果时是否在后台开始一次体检，默认 false"),
                "open": booleanSchema("是否顺便打开「图库体检」页面，默认 false"),
                "limit": integerSchema("每类最多返回多少条，默认 10，最大 50", minimum: 1, maximum: 50)
            ])
        )
    }

    private static var resumeWatching: AIRequestTool {
        AIRequestTool(
            name: "resume_watching",
            description: "跨端汇总所有没看完的内容：本地影院、网盘影院、网络影院与网络资源的续看记录，按最近观看排序，并给出可直接播放的 scope / 来源与条目。用户问「继续看什么」「上次看到哪了」「还有哪些没看完」时先用它，再调用 play_cinema / play_network_cinema / play_catalog_item 播放。",
            parameters: objectSchema([
                "limit": integerSchema("最多返回多少条，默认 10，最大 50", minimum: 1, maximum: 50)
            ])
        )
    }

    private static var todayDigest: AIRequestTool {
        AIRequestTool(
            name: "today_digest",
            description: "今日日报：一次返回网络资源今天新增的条目、追更人物的更新数量、本地与网络影院/资源的续看，以及收藏电视频道今晚的节目。用户问「今天有什么新内容」「今晚看什么」「做个今日推荐」时优先用它，再按需播放或加入稍后看。",
            parameters: objectSchema([
                "limit": integerSchema("每个分区最多返回多少条，默认 8，最大 30", minimum: 1, maximum: 30),
                "include_tv": booleanSchema("是否包含电视节目，默认 true"),
                "include_continue": booleanSchema("是否包含续看记录，默认 true")
            ])
        )
    }

    private static var listAlbums: AIRequestTool {
        AIRequestTool(
            name: "list_albums",
            description: "列出当前图库的全部相簿：id、名称、项目数、所属文件夹与封面。需要把照片加入已有相簿时先调用它。",
            parameters: objectSchema([:])
        )
    }

    private static var listFolders: AIRequestTool {
        AIRequestTool(
            name: "list_folders",
            description: "列出当前图库的文件夹树：id、名称、父级与其中的相簿数。",
            parameters: objectSchema([:])
        )
    }

    private static var listVideos: AIRequestTool {
        AIRequestTool(
            name: "list_videos",
            description: "列出当前图库的最近视频：id、名称、时长、大小、分辨率、收藏状态与所在相簿。",
            parameters: objectSchema([
                "limit": integerSchema("最多返回数量，默认 100，最大 1000", minimum: 1, maximum: 1000)
            ])
        )
    }

    // MARK: - 浏览

    private static var navigate: AIRequestTool {
        AIRequestTool(
            name: "navigate",
            description: "切换用户当前浏览的范围，并可选设置筛选、搜索词与排序。覆盖图库、相簿、文件夹、场景、人物、关键词、地图与地点、重复项、整理工作室（评分 / 旗标 / 色标 / 图库体检）等全部页面。只改变界面视图，不修改图库内容。",
            parameters: objectSchema([
                "target": enumSchema(["library", "favorites", "videos", "screenshots", "hidden", "trash",
                                      "all_albums", "album", "folder", "collections", "recently_saved",
                                      "duplicates", "map", "places", "people", "keywords",
                                      "media_types", "scenes", "more_items", "selfies", "panoramas",
                                      "live_photos", "animated", "raws", "ocr_texts", "health",
                                      "ratings", "flags", "color_labels", "blurry",
                                      "similar_duplicates", "large_videos", "revisit",
                                      "scene", "recently_edited", "imports"],
                                     "要切换到的范围；album 需配合 album_id/album_name，folder 需配合 folder_id/folder_name，scene 需配合 scene"),
                "album_id": stringSchema("相簿 id；target = album 时使用"),
                "album_name": stringSchema("相簿名称；target = album 时可用名称代替 id"),
                "folder_id": stringSchema("文件夹 id；target = folder 时使用"),
                "folder_name": stringSchema("文件夹名称；target = folder 时可用名称代替 id"),
                "scene": stringSchema("场景 id 或名称，例如「自然风景」「美食」；target = scene 时使用"),
                "filter": enumSchema(["all", "favorites", "edited", "photos", "videos", "screenshots"],
                                     "额外筛选条件，可省略"),
                "search": stringSchema("搜索词，可省略；填了会进入搜索状态"),
                "search_scope": enumSchema(["global", "module", "window"],
                                           "搜索范围：global 打开全部来源的统一搜索结果页（默认）；module 只搜当前页面所属模块；window 只过滤当前网格"),
                "sort": enumSchema(["capturedAt", "addedAt", "title", "filename", "fileSize", "kind", "camera", "place", "duration"],
                                   "排序字段，可省略"),
                "ascending": booleanSchema("是否升序，可省略")
            ], required: ["target"])
        )
    }

    /// 打开一条统一搜索命中：引用最近一次 unified_search 的结果编号。
    private static var openSearchResult: AIRequestTool {
        AIRequestTool(
            name: "open_search_result",
            description: "打开最近一次 unified_search 命中的条目：照片进查看器、相簿 / 文件夹 / 人物 / 场景切到对应页面、网盘条目直达文件、影院 / 网络影院 / 网络资源 / 电视频道进入详情或播放。只改变界面与播放，不修改数据。",
            parameters: objectSchema([
                "ref": stringSchema("结果编号，例如 #3；来自最近一次 unified_search")
            ], required: ["ref"])
        )
    }

    private static var selectPhotos: AIRequestTool {
        AIRequestTool(
            name: "select_photos",
            description: "在当前网格中选中照片或视频，方便用户继续查看或操作。",
            parameters: objectSchema(["photo_ids": photoIDsSchema], required: ["photo_ids"])
        )
    }

    private static var openPhoto: AIRequestTool {
        AIRequestTool(
            name: "open_photo",
            description: "在查看器中打开一张照片或播放一个视频。",
            parameters: objectSchema([
                "photo_id": stringSchema("照片或视频的 id，也支持候选编号 #3 或唯一文件名")
            ], required: ["photo_id"])
        )
    }

    // MARK: - 相簿

    private static var createAlbums: AIRequestTool {
        AIRequestTool(
            name: "create_albums",
            description: "创建相簿并把指定项目放进去，可指定所属文件夹。同名相簿已存在时会把项目追加进去。仅本地图库可用。",
            parameters: objectSchema([
                "albums": arraySchema([
                    "type": "object",
                    "properties": [
                        "name": stringSchema("相簿名称"),
                        "photo_ids": photoIDsSchema,
                        "folder_id": stringSchema("所属文件夹 id，可省略"),
                        "folder_name": stringSchema("所属文件夹名称，可省略")
                    ],
                    "required": ["name", "photo_ids"]
                ], description: "要创建的相簿列表")
            ], required: ["albums"])
        )
    }

    private static var addPhotosToAlbum: AIRequestTool {
        AIRequestTool(
            name: "add_photos_to_album",
            description: "把照片或视频加入已有相簿，可用 album_id 或 album_name 指定相簿。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "photo_ids": photoIDsSchema
            ], required: ["photo_ids"])
        )
    }

    private static var removePhotosFromAlbum: AIRequestTool {
        AIRequestTool(
            name: "remove_photos_from_album",
            description: "把项目从相簿移出（不会删除照片本身）。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "photo_ids": photoIDsSchema
            ], required: ["photo_ids"])
        )
    }

    private static var renameAlbum: AIRequestTool {
        AIRequestTool(
            name: "rename_album",
            description: "重命名相簿。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "new_name": stringSchema("新的相簿名称")
            ], required: ["new_name"])
        )
    }

    private static var deleteAlbum: AIRequestTool {
        AIRequestTool(
            name: "delete_album",
            description: "删除相簿本身，不会删除照片或视频。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一")
            ])
        )
    }

    private static var moveAlbum: AIRequestTool {
        AIRequestTool(
            name: "move_album",
            description: "把相簿移动到某个文件夹；不传文件夹表示移到相簿顶层。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "folder_id": stringSchema("目标文件夹 id；省略则移到顶层"),
                "folder_name": stringSchema("目标文件夹名称；省略则移到顶层")
            ])
        )
    }

    private static var setAlbumCover: AIRequestTool {
        AIRequestTool(
            name: "set_album_cover",
            description: "把相簿里的某个项目设为封面。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "photo_id": stringSchema("要作为封面的项目 id")
            ], required: ["photo_id"])
        )
    }

    // MARK: - 文件夹

    private static var createFolder: AIRequestTool {
        AIRequestTool(
            name: "create_folder",
            description: "新建相簿文件夹，可指定父文件夹。仅本地图库可用。",
            parameters: objectSchema([
                "name": stringSchema("文件夹名称"),
                "parent_id": stringSchema("父文件夹 id，可省略"),
                "parent_name": stringSchema("父文件夹名称，可省略")
            ], required: ["name"])
        )
    }

    private static var renameFolder: AIRequestTool {
        AIRequestTool(
            name: "rename_folder",
            description: "重命名相簿文件夹。仅本地图库可用。",
            parameters: objectSchema([
                "folder_id": stringSchema("文件夹 id；与 folder_name 二选一"),
                "folder_name": stringSchema("文件夹名称；与 folder_id 二选一"),
                "new_name": stringSchema("新的文件夹名称")
            ], required: ["new_name"])
        )
    }

    private static var deleteFolder: AIRequestTool {
        AIRequestTool(
            name: "delete_folder",
            description: "删除文件夹及其中的相簿（不会删除照片或视频）。仅本地图库可用。",
            parameters: objectSchema([
                "folder_id": stringSchema("文件夹 id；与 folder_name 二选一"),
                "folder_name": stringSchema("文件夹名称；与 folder_id 二选一")
            ])
        )
    }

    // MARK: - 图片与视频

    private static var setFavorite: AIRequestTool {
        AIRequestTool(
            name: "set_favorite",
            description: "收藏或取消收藏照片与视频。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "favorite": booleanSchema("true 为收藏，false 为取消收藏")
            ], required: ["photo_ids", "favorite"])
        )
    }

    private static var setHidden: AIRequestTool {
        AIRequestTool(
            name: "set_hidden",
            description: "隐藏或取消隐藏照片与视频。仅本地图库，或作为当前图库的官方「照片」图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "hidden": booleanSchema("true 为隐藏，false 为取消隐藏")
            ], required: ["photo_ids", "hidden"])
        )
    }

    private static var setRating: AIRequestTool {
        AIRequestTool(
            name: "set_rating",
            description: "给照片与视频设置星级评分（1–5，传 0 清除评分）。支持本地图库、官方「照片」图库与网盘项目。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "rating": integerSchema("星级 0–5；0 表示清除评分", minimum: 0, maximum: 5)
            ], required: ["photo_ids", "rating"])
        )
    }

    private static var setFlag: AIRequestTool {
        AIRequestTool(
            name: "set_flag",
            description: "设置选片旗标：pick 留用、reject 排除、none 清除。支持本地图库、官方「照片」图库与网盘项目。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "flag": enumSchema(["none", "pick", "reject"], "旗标")
            ], required: ["photo_ids", "flag"])
        )
    }

    private static var setColorLabel: AIRequestTool {
        AIRequestTool(
            name: "set_color_label",
            description: "设置色标：red / orange / yellow / green / blue / purple / gray，none 清除。支持本地图库、官方「照片」图库与网盘项目。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "label": enumSchema(["none", "red", "orange", "yellow", "green",
                                     "blue", "purple", "gray"], "色标")
            ], required: ["photo_ids", "label"])
        )
    }

    private static var addKeywords: AIRequestTool {
        AIRequestTool(
            name: "add_keywords",
            description: "给照片与视频添加关键词（不会删除已有词）。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "keywords": arraySchema(["type": "string"], description: "要添加的关键词")
            ], required: ["photo_ids", "keywords"])
        )
    }

    private static var removeKeywords: AIRequestTool {
        AIRequestTool(
            name: "remove_keywords",
            description: "从照片与视频移除指定关键词（不会删除其它关键词）。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "keywords": arraySchema(["type": "string"], description: "要移除的关键词")
            ], required: ["photo_ids", "keywords"])
        )
    }

    private static var setTitle: AIRequestTool {
        AIRequestTool(
            name: "set_title",
            description: "为照片与视频设置展示标题（传空字符串表示清除标题）。仅本地图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "title": stringSchema("新的标题")
            ], required: ["photo_ids", "title"])
        )
    }

    private static var compressPhotos: AIRequestTool {
        AIRequestTool(
            name: "compress_photos",
            description: "原地压缩照片并替换图库中的原文件（视频、系统图库与网盘项目不支持）。支持有损与无损两种方式；只有在结果更小时才替换，可在「压缩」面板还原。仅本地图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "mode": enumSchema(["lossy", "lossless"],
                                   "压缩方式：lossy 有损（可调质量与长边）；lossless 无损（保持像素与尺寸，JPEG 仅移除元数据，其它格式转无损 PNG）"),
                "quality": integerSchema("有损模式的质量百分比 10–100，默认 80；无损模式忽略", minimum: 10, maximum: 100),
                "max_dimension": integerSchema("有损模式的长边上限像素，0 表示不缩放；无损模式忽略", minimum: 0, maximum: 12000),
                "format": enumSchema(["original", "jpeg", "heic"], "有损模式的输出格式，默认 original 保持原格式；无损模式忽略"),
                "keep_backup": booleanSchema("是否保留压缩前备份，默认 false")
            ], required: ["photo_ids"])
        )
    }

    private static var beautifyPhotos: AIRequestTool {
        AIRequestTool(
            name: "beautify_photos",
            description: "用端侧智能分析为照片生成美化副本：按画面自动调整曝光、对比度、白平衡、饱和度、阴影与锐度。原图与已有编辑都保留，可随时在编辑器里还原。视频、系统图库与网盘项目不支持。仅本地图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "strength": integerSchema("美化强度百分比 20–150，默认 100", minimum: 20, maximum: 150)
            ], required: ["photo_ids"])
        )
    }

    private static var trashPhotos: AIRequestTool {
        AIRequestTool(
            name: "trash_photos",
            description: "把照片与视频移入「最近删除」，之后可以恢复。不会永久删除。仅本地图库可用。",
            parameters: objectSchema(["photo_ids": photoIDsSchema], required: ["photo_ids"])
        )
    }

    private static var restorePhotos: AIRequestTool {
        AIRequestTool(
            name: "restore_photos",
            description: "把「最近删除」中的项目恢复回图库。仅本地图库可用。",
            parameters: objectSchema(["photo_ids": photoIDsSchema], required: ["photo_ids"])
        )
    }

    private static var generateShareCopy: AIRequestTool {
        AIRequestTool(
            name: "generate_share_copy",
            description: "为选中的照片生成 3 条中文分享文案（朋友圈 / 小红书 / 极简）。只读：不修改照片，也不直接发布到任何平台。模型不可用时会退回标签模板。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema
            ], required: ["photo_ids"])
        )
    }

    private static var cleanupTVChannels: AIRequestTool {
        AIRequestTool(
            name: "cleanup_tv_channels",
            description: "清洗网络电视的频道表：规范台名（去掉高清 / 4K / 线路后缀，央视统一成「CCTV-1 综合」）并归入央视 / 卫视 / 体育等分组。只改台名与分组，不动流地址；想还原重新刷新电视源即可。",
            parameters: objectSchema([
                "source": stringSchema("只清洗这个源（名称或 id）；省略时优先当前聚焦源，否则清洗全部启用的源")
            ])
        )
    }

    private static var makeSmartAlbum: AIRequestTool {
        AIRequestTool(
            name: "make_smart_album",
            description: "用一句自然语言创建智能相簿，例如「去年海边且收藏过的照片」。模型会把描述翻译成相簿规则并直接保存。",
            parameters: objectSchema([
                "description": stringSchema("自然语言条件，例如「2024 年在杭州拍的视频」"),
                "name": stringSchema("相簿名称；省略时由条件生成")
            ], required: ["description"])
        )
    }

    // MARK: - JSON Schema 构造

    private static var photoIDsSchema: [String: Any] {
        arraySchema(["type": "string"],
                    description: "照片或视频的 id（UUID，也支持候选编号 #3 或唯一文件名）")
    }

    package static func objectSchema(_ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    package static func arraySchema(_ items: [String: Any], description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }

    package static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    package static func booleanSchema(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    package static func integerSchema(_ description: String,
                              minimum: Int,
                              maximum: Int) -> [String: Any] {
        ["type": "integer", "description": description,
         "minimum": minimum, "maximum": maximum]
    }

    package static func enumSchema(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }

    // MARK: - 参数解析

    package static func arguments(_ raw: String) -> [String: Any] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 少数模型会把参数包在 Markdown 代码块里。
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    package static func stringArray(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        if let string = value as? String { return [string] }
        return []
    }

    package static func objectArray(_ value: Any?) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? [String: Any] } }
        return []
    }

    package static func integer(_ value: Any?, fallback: Int) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return fallback
    }

    package static func bool(_ value: Any?, fallback: Bool) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return fallback
    }

    package static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 一键整理指令

    /// 影院顶栏「一键智能整理」的预设指令：怎么分组、怎么判断电影 / 剧集、季集怎么对齐，
    /// 全交给模型；工具只负责提供目录树、候选与写回。
    package static func cinemaAutoMatchPrompt(scopeName: String) -> String {
        """
        请帮我把当前影院「\(scopeName)」整理匹配好。全程只写元数据与海报，不移动、不改名、不删除任何视频文件。

        步骤：
        1. 先调用 cinema_tree（省略 folder）看顶层文件夹概览；对含视频的目录用 depth 2–3、limit 1000–5000 一次性把整棵子树（含各季文件）读回来，几千个文件也尽量一两次读完，不要一个目录一个目录来回翻。
        2. 判断电影还是剧集以文件名为准，不要只看目录结构：
           - 文件名里有 SxxExx / 1x02 / EPxx / Exx / 第 N 集，或同组连续纯数字（目录或文件名带 Season N / 第 N 季 / Sxx）→ 剧集。
           - 文件名带年份、分辨率（2160p / 4K）、片源（BluRay / WEB-DL / REMUX）而没有集号 → 电影。
           - 同一文件夹里可能有多部电影：第一部 / 第二部、Part 1 / Part 2、不同年份的续集，它们是不同作品，不要当成一部剧的不同集。
        3. 先分组再匹配，同一作品的多版本只算一个作品：
           - 多版本包括 4K / 1080p、HDR / DV 杜比视界、REMUX / 蓝光原盘 / WEB-DL、国语 / 中字 / 导演剪辑版 / 加长版 / 未删减、上下部等。
           - parsed_title 相同且 parsed_year 相同的文件通常是同一部作品的不同版本；写回时这一批要放在同一次 apply_cinema_match 里，不要只写其中一份。
           - 剧集同一集的多版本（4K 与 1080p 各一份）要映射到同一个集号。
        4. 用 search_cinema_candidates 搜候选：剧集传 is_tv=true，电影传 is_tv=false；query 用干净的片名（去掉年份、分辨率、编码、字幕组、季集号与版本标签），year 用文件名或目录里的年份。优先选片名完全一致、年份一致、类型一致；同名动画 / 短片 / 不同版本不要选。
        5. 写回：
           - 剧集：apply_cinema_match 传 folder（或 photo_ids）、candidate_id、season，并用 episodes 逐文件给出集号（SxxExx / EPxx / 第 N 集 / 纯数字）。同一部剧不同季分开应用，季与集都要对得上。
           - 电影：apply_cinema_match 传 candidate_id；文件夹里只有这一部作品时可用 folder。
           - 文件夹里有续集、合集等多部作品时，必须用 photo_ids 按作品分批应用，同一作品的多版本放同一批。
        6. 每一批处理完可调用 cinema_tree(only_unmatched=true, depth=3) 复查；还有未识别的就继续，可以连续多轮，直到整理完。大批量目录一次读全、一次批量写回，减少来回调用。
        7. 最后用一段话汇总：匹配成功多少部 / 多少集（说明合并了哪些多版本），还剩多少未识别，哪些没有候选或不确定需要人工确认。

        约束：
        - 一个文件夹里的视频不一定属于同一部作品：先按文件名分组，再决定用 folder 还是 photo_ids。
        - 候选不确定时宁可跳过并在最后列出，不要乱匹配。
        - 不要调用 match_cinema 的「取第一条」快捷方式，必须自己看候选后再 apply_cinema_match。
        """
    }

    // MARK: - 确认弹窗文案

    /// 用于确认弹窗的可读描述。
    /// 各业务域先自行认领（影院 / 网络资源 / 网络电视），剩下的图库工具在这里兜底。
    package static func describe(_ call: AIToolCall) -> String {
        if let text = describeCinema(call) ?? describeCatalog(call) ?? describeTV(call) {
            return text
        }
        let args = arguments(call.arguments)
        let photoCount = stringArray(args["photo_ids"]).count
        let albumName = string(args["album_name"])
        let folderName = string(args["folder_name"])
        switch call.name {
        case "create_albums":
            let albums = objectArray(args["albums"])
            let parts = albums.compactMap { item -> String? in
                guard let name = string(item["name"]) else { return nil }
                return "\(name)（\(stringArray(item["photo_ids"]).count) 项）"
            }
            return "创建/更新相簿：\(parts.joined(separator: "、"))"
        case "add_photos_to_album":
            return "加入相簿「\(albumName ?? "已有相簿")」：\(photoCount) 项"
        case "remove_photos_from_album":
            return "从相簿「\(albumName ?? "已有相簿")」移出：\(photoCount) 项"
        case "rename_album":
            return "相簿改名为「\(string(args["new_name"]) ?? "")」"
        case "delete_album":
            return "删除相簿「\(albumName ?? "指定相簿")」（不会删除照片）"
        case "move_album":
            return "移动相簿到「\(folderName ?? "顶层")」"
        case "set_album_cover":
            return "更新相簿「\(albumName ?? "指定相簿")」的封面"
        case "create_folder":
            return "新建文件夹「\(string(args["name"]) ?? "")」"
        case "rename_folder":
            return "文件夹改名为「\(string(args["new_name"]) ?? "")」"
        case "delete_folder":
            return "删除文件夹「\(folderName ?? "指定文件夹")」及其中的相簿（不会删除照片）"
        case "set_favorite":
            let favorite = bool(args["favorite"], fallback: true)
            return "\(favorite ? "收藏" : "取消收藏") \(photoCount) 项"
        case "set_hidden":
            let hidden = bool(args["hidden"], fallback: true)
            return "\(hidden ? "隐藏" : "取消隐藏") \(photoCount) 项"
        case "set_rating":
            let rating = integer(args["rating"], fallback: 0)
            return rating == 0 ? "清除 \(photoCount) 项的星级评分"
                : "把 \(photoCount) 项设为 \(rating) 星"
        case "set_flag":
            let flag = string(args["flag"]) ?? "none"
            return "\(photoCount) 项旗标设为「\(flag)」"
        case "set_color_label":
            let label = string(args["label"]) ?? "none"
            return "\(photoCount) 项色标设为「\(label)」"
        case "add_keywords":
            let keywords = stringArray(args["keywords"]).joined(separator: "、")
            return "为 \(photoCount) 项添加关键词：\(keywords)"
        case "remove_keywords":
            let keywords = stringArray(args["keywords"]).joined(separator: "、")
            return "从 \(photoCount) 项移除关键词：\(keywords)"
        case "set_title":
            return "为 \(photoCount) 项设置标题「\(string(args["title"]) ?? "")」"
        case "compress_photos":
            let mode = string(args["mode"]) ?? "lossy"
            if mode == "lossless" {
                return "无损压缩 \(photoCount) 张照片（保持像素与尺寸，仅移除元数据或转 PNG，会替换原文件）"
            }
            let quality = integer(args["quality"], fallback: 80)
            let maxDimension = integer(args["max_dimension"], fallback: 0)
            let sizePart = maxDimension > 0 ? "、长边 \(maxDimension)px" : ""
            return "有损压缩 \(photoCount) 张照片（质量 \(quality)%\(sizePart)，会替换原文件）"
        case "beautify_photos":
            let strength = integer(args["strength"], fallback: 100)
            return "智能美化 \(photoCount) 张照片（强度 \(strength)%，生成副本，原图保留）"
        case "trash_photos":
            return "把 \(photoCount) 项移入最近删除"
        case "restore_photos":
            return "从最近删除恢复 \(photoCount) 项"
        case "select_photos":
            return "选中 \(photoCount) 项"
        default:
            return call.name
        }
    }
}
