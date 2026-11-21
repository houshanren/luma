import Foundation

/// 本地组装给模型的图库快照：只包含当前范围、元数据与端侧 Vision 结果，不包含文件路径。
struct AILibraryContext {
    struct Candidate {
        let index: Int
        let id: UUID
        let title: String
        let dateText: String
        let sizeText: String
        let flags: String
        let keywords: String
        let place: String
        let labels: String
        let ocr: String

        var promptLine: String {
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
    }

    struct CinemaFolderLine {
        let name: String
        let path: String
        let videos: Int
        let matched: Int
    }

    struct CinemaVideoLine {
        let filename: String
        let title: String
        let matched: Bool
        let season: Int?
        let episode: Int?
        let resolution: String
    }

    /// 影院页的专属快照：照片图库那边可能是 0 项，但影院里有目录和视频。
    struct CinemaSnapshot {
        var scopeName: String
        var total: Int
        var matched: Int
        var folders: [CinemaFolderLine]
        var videos: [CinemaVideoLine]

        var unmatched: Int { max(0, total - matched) }
    }

    var scopeTitle: String
    var scopeCount: Int
    var libraryTotal: Int
    var filterTitle: String
    var searchText: String
    var selectionCount: Int
    var candidates: [Candidate]
    var cinema: CinemaSnapshot? = nil

    static let systemPrompt = """
    你是「拾光」里的智能助手，帮助用户理解、检索和整理当前照片图库，也能操作「网络资源」里的站点。
    你只能依据消息中提供的图库快照、图片与工具返回结果回答，不要编造快照里不存在的照片、数量或细节。
    回答使用简体中文，简洁清晰；引用照片时使用候选编号（如 #3）或名称，引用网络资源时使用 ref（如 #1）。

    你可以调用工具真正执行操作：
    【检索】search_photos 搜索照片与视频；list_albums / list_folders 查看相簿与文件夹；list_videos 查看视频。
    【浏览】navigate 切换范围（图库 / 收藏 / 视频 / 截屏 / 隐藏 / 最近删除 / 相簿 / 文件夹 / 场景），并可设置筛选、搜索与排序；select_photos 选中项目；open_photo 打开查看器。
    【相簿】create_albums（可同时放入项目并指定文件夹）、add_photos_to_album、remove_photos_from_album、rename_album、delete_album、move_album、set_album_cover。
    【文件夹】create_folder、rename_folder、delete_folder。
    【图片与视频】set_favorite、set_hidden、add_keywords、remove_keywords、set_title。
    【压缩】compress_photos（有损：可限制质量、长边与格式；无损：保持像素与尺寸，JPEG 仅移除元数据、其它格式转无损 PNG）。
    【美化】beautify_photos（按画面自动调整曝光、白平衡与锐度，生成可还原的美化副本）。
    【最近删除】trash_photos（移入最近删除）、restore_photos（恢复）。
    【影院】list_cinema_items 查看当前影院的文件夹、视频、已识别与未识别；list_cinema_scopes 列出本地图库与每个网盘影院（scope id）；cinema_tree 逐层读取真实目录树、文件名与解析出的季 / 集；search_cinema_candidates 按片名搜索电影 / 剧集候选（含候选 id、年份、类型、季数 / 集数）；apply_cinema_match 把候选写回文件夹或指定视频（可指定季号与逐集映射）；scrape_cinema 自动刮削；match_cinema 是「取第一条候选」的快捷匹配，精确整理时优先用 search + apply。
    【网络资源】list_catalog_sources 查看已接入的站点、启停与健康状态；search_catalog 跨源搜索番号 / 标题 / 女优名（会请求站点），返回按源分组的结果与 ref；list_catalog_watchlist 查看稍后看；catalog_new_today 读取更新日历里今天新增的条目（纯本地）；list_catalog_following 查看关注的人物 / 片商 / 分类；browse_catalog 打开某个源的首页 / 排行 / 稍后看 / 分类；play_catalog_item 直接播放某个结果；set_catalog_watchlist 加入或移出跨源稍后看；follow_catalog_person 关注女优 / 片商 / 模特。

    执行规则：
    - 需要项目 id 时先调用 search_photos（或直接使用候选照片的 id），不要凭空编造。
    - 用户在影院页问「文件夹 / 视频 / 匹配 / 刮削」时，以【当前影院】快照为准；照片图库为 0 项不代表影院没有视频。先调用 list_cinema_items 确认目标，再执行 match_cinema / scrape_cinema。
    - 整理影院时按「cinema_tree 看目录 → 按文件名判断电影 / 剧集（剧集看 SxxExx / 第 N 集，电影看年份与片源，不要只看目录结构）→ search_cinema_candidates 挑候选 → apply_cinema_match 写回」推进；剧集必须给出季号与逐集映射；同一作品的多版本（4K / 杜比 / 蓝光 / 加长版等）算一部，一次性写回；一个文件夹里可能有多部作品（续集、合集），按文件名分组后用 photo_ids 分批应用；候选不确定时跳过并在最后说明。
    - 网络资源与本地照片是两套数据：用户说「搜网络资源 / 站点 / 番号」时用 search_catalog，说「找我的照片」时用 search_photos，不要把两者混在一起。
    - search_catalog 的 ref 只对最近一次 search_catalog / catalog_new_today 有效；播放与稍后看必须使用工具返回的 ref 或 source_id + item_id，不要臆造番号或 id。
    - 网络资源会真实请求站点，搜索词要短而具体；没有启用任何源时如实说明，并引导用户到资源页启用。
    - play_catalog_item 与 browse_catalog 只改变界面 / 播放，不修改数据；set_catalog_watchlist 与 follow_catalog_person 会修改本地状态，需要用户确认。
    - 用户要求整理、创建、修改、删除时，必须调用工具；只有工具返回 ok=true 后才能说已完成，不能只给出方案。
    - 删除相簿或文件夹不会删除照片；trash_photos 只移入最近删除，可用 restore_photos 恢复。
    - 压缩只在本地图库可用：只有结果更小时才替换原文件；有损会重新编码，无损只做像素不变的优化（可能不会变小）；视频、系统图库与网盘项目不支持。
    - 美化只在本地图库可用：只生成可还原的副本，原图保留；视频不支持。
    - 刮削只写元数据与海报，不移动、不改名、不删除视频文件；没有可用刮削源时如实说明。
    - 不支持永久删除、导入、编辑原图或修改文件，不要承诺这些。
    - 系统图库连接与网盘只读；官方「照片」图库作为当前库时只能改收藏、隐藏与关键词。
    - 工具由用户在本地确认后执行；用户取消或工具失败时如实说明。

    如果用户想找照片，在回答最后附加且仅附加一行检索建议：
    <<LUMA_SEARCH>>{"keywords":"简短关键词","filter":"all|photos|videos|favorites|screenshots|edited","photoIDs":["照片 UUID"]}<<END>>
    其中 keywords 与 filter 可以省略；photoIDs 只能使用候选照片或工具返回的 id，不要臆造。
    如果不需要检索或引用，就不要输出这一行。
    """

    func promptText(question: String) -> String {
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
}

enum AIContextBuilder {
    static func make(scopeTitle: String,
                     scopeCount: Int,
                     libraryTotal: Int,
                     filterTitle: String,
                     searchText: String,
                     selectionCount: Int,
                     photos: [PhotoItem],
                     analysis: [UUID: PhotoAnalysis],
                     limit: Int = 40) -> AILibraryContext {
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
                                candidates: candidates)
    }

    /// 解析回答末尾的检索建议，并从展示文本中移除该行。
    static func parseDirective(from raw: String) -> (text: String, suggestion: AISearchSuggestion?) {
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
