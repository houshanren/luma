import Foundation
import LumaDomain

/// 用户在统一搜索页看到的现场：由 `SearchCenter` 每次检索后写回，
/// 让助手能「接着用户正在看的结果继续找」，而不是只看到一行搜索词。
package struct AISearchOverview {
    package struct SourceLine {
        package let title: String
        package let total: Int
        /// 该来源下的类型计数（中文类型名 → 数量）。
        package let kinds: [(title: String, count: Int)]
        package init(
            title: String,
            total: Int,
            kinds: [(title: String, count: Int)]
        ) {
            self.title = title
            self.total = total
            self.kinds = kinds
        }
    }

    package var query: String
    package var total: Int
    package var sources: [SourceLine]
    package var activeSource: String?
    package var activeKind: String?
    package var activeOrigin: String?
    package var activeCategory: String?
    /// 各来源前几条命中，帮助模型快速确认这批结果讲的是什么。
    package var samples: [String]
    package init(
        query: String,
        total: Int,
        sources: [SourceLine],
        activeSource: String? = nil,
        activeKind: String? = nil,
        activeOrigin: String? = nil,
        activeCategory: String? = nil,
        samples: [String]
    ) {
        self.query = query
        self.total = total
        self.sources = sources
        self.activeSource = activeSource
        self.activeKind = activeKind
        self.activeOrigin = activeOrigin
        self.activeCategory = activeCategory
        self.samples = samples
    }
}

/// 本地组装给模型的图库快照：只包含当前范围、元数据与端侧 Vision 结果，不包含文件路径。
package struct AILibraryContext {
    package struct Candidate {
        package let index: Int
        package let id: UUID
        package let title: String
        package let dateText: String
        package let sizeText: String
        package let flags: String
        package let keywords: String
        package let place: String
        package let labels: String
        package let ocr: String

        package var promptLine: String {
            var parts = ["#\(index)", "id=\(id.uuidString)"]
            parts.append(dateText)
            parts.append(title)
            if !sizeText.isEmpty { parts.append(sizeText) }
            if !flags.isEmpty { parts.append(flags) }
            if !keywords.isEmpty { parts.append("关键词=\(keywords)") }
            if !place.isEmpty { parts.append("地点=\(place)") }
            if !labels.isEmpty { parts.append("标签=\(labels)") }
            if !ocr.isEmpty { parts.append("文字=\(ocr)") }
            return parts.joined(separator: " ")
        }
        package init(
            index: Int,
            id: UUID,
            title: String,
            dateText: String,
            sizeText: String,
            flags: String,
            keywords: String,
            place: String,
            labels: String,
            ocr: String
        ) {
            self.index = index
            self.id = id
            self.title = title
            self.dateText = dateText
            self.sizeText = sizeText
            self.flags = flags
            self.keywords = keywords
            self.place = place
            self.labels = labels
            self.ocr = ocr
        }
    }

    package struct CinemaFolderLine {
        package let name: String
        package let path: String
        package let videos: Int
        package let matched: Int
        package init(
            name: String,
            path: String,
            videos: Int,
            matched: Int
        ) {
            self.name = name
            self.path = path
            self.videos = videos
            self.matched = matched
        }
    }

    package struct CinemaVideoLine {
        package let filename: String
        package let title: String
        package let matched: Bool
        package let season: Int?
        package let episode: Int?
        package let resolution: String
        package init(
            filename: String,
            title: String,
            matched: Bool,
            season: Int? = nil,
            episode: Int? = nil,
            resolution: String
        ) {
            self.filename = filename
            self.title = title
            self.matched = matched
            self.season = season
            self.episode = episode
            self.resolution = resolution
        }
    }

    /// 影院页的专属快照：照片图库那边可能是 0 项，但影院里有目录和视频。
    package struct CinemaSnapshot {
        package var scopeName: String
        package var total: Int
        package var matched: Int
        package var folders: [CinemaFolderLine]
        package var videos: [CinemaVideoLine]

        package var unmatched: Int { max(0, total - matched) }
        package init(
            scopeName: String,
            total: Int,
            matched: Int,
            folders: [CinemaFolderLine],
            videos: [CinemaVideoLine]
        ) {
            self.scopeName = scopeName
            self.total = total
            self.matched = matched
            self.folders = folders
            self.videos = videos
        }
    }

    package var scopeTitle: String
    package var scopeCount: Int
    package var libraryTotal: Int
    package var filterTitle: String
    package var searchText: String
    package var selectionCount: Int
    package var candidates: [Candidate]
    package var cinema: CinemaSnapshot? = nil
    package var searchOverview: AISearchOverview? = nil

    package static let systemPrompt = """
    你是「拾光」里的智能助手，帮助用户理解、检索和整理照片图库，也能操作本地影院、网络影院、网络资源与网络电视，并用组合工具完成体检、旅行回忆、跨端续看与今日日报等深度场景。
    你只能依据消息中提供的图库快照、图片与工具返回结果回答，不要编造快照里不存在的照片、数量或细节。
    回答使用简体中文，简洁清晰；引用照片时使用候选编号（如 #3）或名称，引用网络资源时使用 ref（如 #1）。
    回答用 Markdown：短段落、要点用「- 」、步骤用「1. 」，强调用 **粗体**；不要输出表格或大段 JSON，也不要重复工具返回的原始清单。

    你可以调用工具真正执行操作：
    【检索】unified_search 走统一搜索内核跨来源检索（图库 / 网盘 / 影院 / 网络影院 / 网络电视 / 网络资源），返回各来源分区、总数、类型计数、来源与分类分布；search_photos 搜索照片与视频（可组合关键词、时间、类型、相簿、文件夹、评分、旗标、色标、人物，按 offset 翻页取全量）；list_albums / list_folders 查看相簿与文件夹；list_videos 查看视频；get_photo_info 批量查看项目详情（EXIF、地点、评分、关键词、相簿、人物）；list_keywords 查看关键词与次数；list_people 查看人物名单；library_overview 一次拿到图库统计概览。
    【浏览】navigate 切换范围（图库 / 收藏 / 视频 / 截屏 / 隐藏 / 最近删除 / 相簿 / 文件夹 / 场景），并可设置筛选、搜索与排序，`search_scope` 选 global / module / window（global 直接打开统一搜索结果页）；select_photos 选中项目；open_photo 打开查看器；open_search_result 打开最近一次 unified_search 命中的条目（用返回的 ref，如 #3）。
    【相簿】create_albums（可同时放入项目并指定文件夹）、add_photos_to_album、remove_photos_from_album、rename_album、delete_album、move_album、set_album_cover。
    【文件夹】create_folder、rename_folder、delete_folder。
    【图片与视频】set_favorite、set_hidden、set_rating（星级）、set_flag（留用 / 排除）、set_color_label（色标）、add_keywords、remove_keywords、set_title。
    【压缩】compress_photos（有损：可限制质量、长边与格式；无损：保持像素与尺寸，JPEG 仅移除元数据、其它格式转无损 PNG）。
    【美化】beautify_photos（按画面自动调整曝光、白平衡与锐度，生成可还原的美化副本）。
    【最近删除】trash_photos（移入最近删除）、restore_photos（恢复）。
    【影院 · 浏览】list_cinema_scopes 列出所有影院作用域（scope id）；cinema_tree 读取真实目录树、文件名与解析出的季 / 集（传 depth 可一次展开整棵子树，几千个文件一次读完）；list_cinema_items 查看文件夹与视频清单；search_cinema_library 在本库按片名 / 文件名 / 演员 / 导演 / 类型检索，可只看收藏 / 想看 / 已评分 / 未识别；list_cinema_series 查看聚合后的剧集；list_cinema_lists 查看自定义清单；list_cinema_activity 查看继续观看 / 观看记录 / 刮削任务 / 通知；navigate_cinema 切换影院、全部 / 电影 / 剧集 / 文件夹分段、视图、排序与筛选，并可打开搜索 / 历史 / 任务 / 通知 / 新建清单面板；play_cinema 播放影片或剧集的下一集。
    【影院 · 整理与个人状态】search_cinema_candidates 按片名搜索电影 / 剧集候选（含候选 id、年份、类型、季数 / 集数）；apply_cinema_match 把候选写回文件夹或指定视频（可指定季号与逐集映射）；scrape_cinema 自动刮削；match_cinema 是「取第一条候选」的快捷匹配，精确整理时优先用 search + apply；update_cinema_state 修改收藏 / 想看 / 个人评分；manage_cinema_list 新建 / 删除 / 加入 / 移出 / 清空自定义清单；ignore_cinema 与 restore_cinema_ignored 忽略或恢复视频；refresh_cinema_metadata 补全 TMDB 详情或重新刮削；set_cinema_intro_skip 设置跳过片头 / 片尾；manage_cinema_progress 移除或清空观看记录。
    【网络资源】list_catalog_sources 查看已接入的站点、启停与健康状态；search_catalog 跨源搜索番号 / 标题 / 女优名（会请求站点），返回按源分组的结果与 ref；list_catalog_watchlist 查看稍后看；catalog_new_today 读取更新日历里今天新增的条目（纯本地）；list_catalog_following 查看关注的人物 / 片商 / 分类；browse_catalog 打开某个源的首页 / 排行 / 稍后看 / 分类；play_catalog_item 直接播放某个结果；set_catalog_watchlist 加入或移出跨源稍后看；follow_catalog_person 关注女优 / 片商 / 模特。
    【网络电视】list_tv_sources 查看电视源；list_tv_channels 聚合频道（可按关键词 / 源 / 分组筛选）；get_tv_guide 查频道节目单；tv_tonight 聚合收藏频道或指定频道的今晚节目；play_tv_channel 播放直播或回看节目；favorite_tv_channel 收藏频道；navigate_tv 打开直播 / 夜航 / 节目回看 / 信号 / 源库。
    【深度场景】library_insights 分析图库画像（年份、机型、地点、存储与未整理比例）；library_health_report 读取或开始图库体检（模糊、相似连拍、过大视频、可释放空间）；list_trips 列出自动识别的旅行，play_trip_memory 把某次旅行播成回忆影片；resume_watching 汇总本地影院、网盘、网络影院与网络资源的未看完记录；today_digest 生成今日日报（新资源 + 追更 + 续看 + 收藏频道今晚节目）；cinema_health_report 统计影院的匹配、缺海报与剧集集数。

    执行规则：
    - 用户问「今天有什么 / 今晚看什么 / 做个今日推荐」时先调用 today_digest，一次拿到新资源、追更、续看与电视节目，不要分别调用多个工具再拼。
    - 用户问「没看完 / 接着看 / 上次看到哪」时先调用 resume_watching，再按返回的 play_tool、scope / target 或 ref 播放；不要凭印象猜。
    - 用户提到清理、重复、模糊、空间占用时用 library_health_report；没有结果就用 scan=true 让体检在后台跑，并说明进度在任务条。
    - 用户想回顾旅行、做回忆影片时先 list_trips 确认是哪一次，再 play_trip_memory；trip 传 id 或 latest。
    - 用户问图库风格、年份 / 设备 / 地点分布、还有多少没整理时用 library_insights；问影院整理程度、缺海报、未识别数量时用 cinema_health_report。
    - 需要项目 id 时先调用 search_photos（或直接使用候选照片的 id），不要凭空编造。
    - 提效原则：筛选条件一次放进 search_photos（例如 album_name + rating_min + person + 时间词）；单页 limit 最多 500，命中更多时用返回的 next_offset 继续翻页，直到 has_more=false；批量修改在一次工具调用里传多个 photo_ids；要看多项详情用 get_photo_info 一次多传；「有多少 / 概览 / 统计」先用 library_overview，不要反复检索。
    - 消息里出现【当前搜索结果】时，那是用户正在搜索页看的那一轮统一检索结果：先基于它回答；需要看更多条目、换关键词或换来源时，用 unified_search（scope 保持 global）而不是重新拼多次单源工具。只要本地照片的 id 与可操作项时，用 search_photos。
    - unified_search 的 ref 只对最近一次调用有效：要替用户打开某条命中，用 open_search_result 传该 ref；要让用户自己看完整结果页，用 navigate 带 search + search_scope=global。不要臆造 ref。
    - 标记与整理：星级用 set_rating、选片用 set_flag、色标用 set_color_label；这些与收藏 / 关键词一样支持本地图库、官方「照片」图库与网盘项目。
    - 用户在影院页问「文件夹 / 视频 / 匹配 / 刮削 / 收藏 / 清单 / 继续观看」时，以【当前影院】快照为准；照片图库为 0 项不代表影院没有视频。先调用 search_cinema_library、list_cinema_series 或 list_cinema_items 确认目标，再执行对应工具；要操作具体影片或剧集时必须先拿到工具返回的 id 或 series_id。
    - 影院工具的条目引用支持视频 id、series_id、文件名或片名；传 series_id 会作用于整部剧。不要臆造 id；找不到时如实说明并列出候选。
    - 影院不提供永久删除：ignore_cinema 只把视频从影院移除且可用 restore_cinema_ignored 恢复；manage_cinema_progress 只删观看进度；scrape_cinema / refresh_cinema_metadata 只写元数据与海报，不移动、不改名、不删除视频。
    - 整理影院时按「cinema_tree 批量看目录（深度 2–3、limit 上千，一次拿全）→ 按文件名判断电影 / 剧集（剧集看 SxxExx / 第 N 集，电影看年份与片源，不要只看目录结构）→ search_cinema_candidates 挑候选 → apply_cinema_match 写回」推进；剧集必须给出季号与逐集映射；同一作品的多版本（4K / 杜比 / 蓝光 / 加长版等）算一部，一次性写回；一个文件夹里可能有多部作品（续集、合集），按文件名分组后用 photo_ids 分批应用；候选不确定时跳过并在最后说明。
    - 网络资源与本地照片是两套数据：用户说「搜网络资源 / 站点 / 番号」时用 search_catalog，说「找我的照片」时用 search_photos，不要把两者混在一起。
    - search_catalog 的 ref 只对最近一次 search_catalog / catalog_new_today 有效；播放与稍后看必须使用工具返回的 ref 或 source_id + item_id，不要臆造番号或 id。
    - 网络资源会真实请求站点，搜索词要短而具体；没有启用任何源时如实说明，并引导用户到资源页启用。
    - play_catalog_item 与 browse_catalog 只改变界面 / 播放，不修改数据；set_catalog_watchlist 与 follow_catalog_person 会修改本地状态，需要用户确认。
    - 用户要求整理、创建、修改、删除时，必须调用工具；只有工具返回 ok=true 后才能说已完成，不能只给出方案。
    - 删除相簿或文件夹不会删除照片；trash_photos 只移入最近删除，可用 restore_photos 恢复。
    - 压缩只在本地图库可用：只有结果更小时才替换原文件；有损会重新编码，无损只做像素不变的优化（可能不会变小）；视频、系统图库与网盘项目不支持。
    - 美化只在本地图库可用：只生成可还原的副本，原图保留；视频不支持。
    - 刮削只写元数据与海报，不移动、不改名、不删除视频文件；没有可用刮削源时如实说明。
    - 影院收藏 / 想看 / 评分、自定义清单、跳过片头与观看记录都属于本地状态，修改前需要用户确认；navigate_cinema 与 play_cinema 只改变界面或播放，不修改数据。
    - 不支持永久删除、导入、编辑原图或修改文件，不要承诺这些。
    - 系统图库连接与网盘只读；官方「照片」图库作为当前库时可以改收藏、隐藏、星级、旗标、色标与关键词。
    - 工具执行前可能由用户在本地确认；用户取消或工具失败时如实说明。

    如果回答里给出「需要用户确认后才执行」的具体动作，在回答末尾单独一行用固定格式列出：
    可选：① 动作一；② 动作二；③ 动作三。
    每一项都写成可直接执行的指令（动词开头，包含目标与范围，例如「建「杭州」「北京」等地点相簿」），2–6 项；界面会把它渲染成可点击动作，用户点选后你会直接收到这一条指令。这里不要写工具名或参数。

    如果用户想找照片，在回答最后附加且仅附加一行检索建议：
    <<LUMA_SEARCH>>{"keywords":"简短关键词","filter":"all|photos|videos|favorites|screenshots|edited","photoIDs":["照片 UUID"]}<<END>>
    其中 keywords 与 filter 可以省略；photoIDs 只能使用候选照片或工具返回的 id，不要臆造。
    如果不需要检索或引用，就不要输出这一行。
    """

    /// 会话模式追加到系统提示词：快速 / 标准 / 深度的行为差异。
    package static func modeInstruction(_ mode: AIMode) -> String {
        switch mode {
        case .fast:
            return "【模式：快速】优先直接回答；只有用户明确要求执行或必须拿到 id 时才调用工具，最多几步就给出结论，回答控制在几行内。"
        case .balanced:
            return "【模式：标准】按需调用工具；先批量检索再执行，回答简洁但信息完整。"
        case .deep:
            return "【模式：深度】可以多轮批量读取与执行：先 library_overview / 目录概览 / 批量搜索，再一次性处理；宁可多核对一步，也要保证数量、季集与结果准确，最后给出完整汇总。"
        }
    }

    package func promptText(question: String) -> String {
        var lines: [String] = []
        lines.append("【当前范围】")
        lines.append("名称：\(scopeTitle)")
        lines.append("当前范围项目数：\(scopeCount.formatted())")
        if libraryTotal != scopeCount {
            lines.append("整个图库项目数：\(libraryTotal.formatted())")
        }
        lines.append("筛选：\(filterTitle)")
        if !searchText.isEmpty {
            lines.append("搜索词：\(searchText)")
        }
        lines.append("已选中：\(selectionCount) 张")
        if let overview = searchOverview {
            lines.append("")
            lines.append("【当前搜索结果】（用户正在搜索页查看）")
            lines.append("关键词：\(overview.query)　总计：\(overview.total) 项")
            for source in overview.sources {
                let kinds = source.kinds.map { "\($0.title) \($0.count)" }.joined(separator: " · ")
                lines.append("- \(source.title)：\(source.total) 项\(kinds.isEmpty ? "" : "（\(kinds)）")")
            }
            var filters: [String] = []
            if let value = overview.activeSource { filters.append("来源=\(value)") }
            if let value = overview.activeKind { filters.append("类型=\(value)") }
            if let value = overview.activeOrigin { filters.append("源=\(value)") }
            if let value = overview.activeCategory { filters.append("分类=\(value)") }
            if !filters.isEmpty {
                lines.append("当前筛选：" + filters.joined(separator: " · "))
            }
            if !overview.samples.isEmpty {
                lines.append("前几条：" + overview.samples.joined(separator: " / "))
            }
        }
        if let cinema {
            lines.append("")
            lines.append("【当前影院】")
            lines.append("名称：\(cinema.scopeName)")
            lines.append("视频：\(cinema.total)（已识别 \(cinema.matched) · 未识别 \(cinema.unmatched)）")
            if !cinema.folders.isEmpty {
                lines.append("文件夹（名称 · 直属+子目录视频 · 已识别）：")
                for folder in cinema.folders {
                    lines.append("- \(folder.name)（\(folder.path)）\(folder.videos) 个视频 · 已识别 \(folder.matched)")
                }
            }
            if !cinema.videos.isEmpty {
                lines.append("视频样本：")
                for video in cinema.videos {
                    var parts = [video.filename]
                    parts.append("匹配=" + (video.matched ? "已识别" : "未识别"))
                    if !video.title.isEmpty { parts.append("解析标题=\(video.title)") }
                    if let season = video.season, let episode = video.episode {
                        parts.append(String(format: "S%02dE%02d", season, episode))
                    }
                    if !video.resolution.isEmpty { parts.append(video.resolution) }
                    lines.append("- " + parts.joined(separator: " · "))
                }
            }
        }
        lines.append("")
        lines.append("【候选照片】（编号用于回答引用，id 可用于检索建议与工具参数）")
        if candidates.isEmpty {
            lines.append("当前范围没有可引用的照片。")
        } else {
            lines.append(contentsOf: candidates.map(\.promptLine))
        }
        lines.append("")
        lines.append("【用户问题】")
        lines.append(question)
        return lines.joined(separator: "\n")
    }
    package init(
        scopeTitle: String,
        scopeCount: Int,
        libraryTotal: Int,
        filterTitle: String,
        searchText: String,
        selectionCount: Int,
        candidates: [Candidate],
        cinema: CinemaSnapshot? = nil,
        searchOverview: AISearchOverview? = nil
    ) {
        self.scopeTitle = scopeTitle
        self.scopeCount = scopeCount
        self.libraryTotal = libraryTotal
        self.filterTitle = filterTitle
        self.searchText = searchText
        self.selectionCount = selectionCount
        self.candidates = candidates
        self.cinema = cinema
        self.searchOverview = searchOverview
    }
}

package enum AIContextBuilder {
    package static func make(scopeTitle: String,
                     scopeCount: Int,
                     libraryTotal: Int,
                     filterTitle: String,
                     searchText: String,
                     selectionCount: Int,
                     photos: [PhotoItem],
                     analysis: [UUID: PhotoAnalysis],
                     limit: Int = 40,
                     searchOverview: AISearchOverview? = nil) -> AILibraryContext {
        var candidates: [AILibraryContext.Candidate] = []
        candidates.reserveCapacity(min(limit, photos.count))
        for photo in photos.prefix(limit) {
            let info = analysis[photo.id]
            let labels = (info?.labels ?? [])
                .filter { !$0.isEmpty }
                .sorted()
                .prefix(12)
                .joined(separator: " ")
            let ocr = String((info?.text ?? "").prefix(240))
            candidates.append(.init(index: candidates.count + 1,
                                    id: photo.id,
                                    title: photo.originalName,
                                    dateText: Self.dateFormatter.string(from: photo.capturedAt),
                                    sizeText: sizeText(photo),
                                    flags: flags(photo),
                                    keywords: (photo.keywords ?? []).prefix(8).joined(separator: " "),
                                    place: placeText(photo),
                                    labels: labels,
                                    ocr: ocr))
        }
        return AILibraryContext(scopeTitle: scopeTitle,
                                scopeCount: scopeCount,
                                libraryTotal: libraryTotal,
                                filterTitle: filterTitle,
                                searchText: searchText,
                                selectionCount: selectionCount,
                                candidates: candidates,
                                searchOverview: searchOverview)
    }

    /// 解析回答末尾的检索建议，并从展示文本中移除该行。
    package static func parseDirective(from raw: String) -> (text: String, suggestion: AISearchSuggestion?) {
        guard let start = raw.range(of: "<<LUMA_SEARCH>>"),
              let end = raw.range(of: "<<END>>", range: start.upperBound..<raw.endIndex) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let json = String(raw[start.upperBound..<end.lowerBound])
        let text = raw.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let suggestion = try? JSONDecoder().decode(AISearchSuggestion.self, from: data) else {
            return (text, nil)
        }
        return (text, suggestion)
    }

    private static func sizeText(_ photo: PhotoItem) -> String {
        guard photo.pixelWidth > 0, photo.pixelHeight > 0 else { return "" }
        return "\(photo.pixelWidth)×\(photo.pixelHeight)"
    }

    private static func flags(_ photo: PhotoItem) -> String {
        var items: [String] = []
        if photo.isVideo { items.append("视频") }
        if photo.isFavorite { items.append("收藏") }
        if photo.hasEdits { items.append("已编辑") }
        return items.joined(separator: " ")
    }

    private static func placeText(_ photo: PhotoItem) -> String {
        [photo.placeCountry, photo.placeProvince, photo.placeCity,
         photo.placeDistrict, photo.placePOI]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
