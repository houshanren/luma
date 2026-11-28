import Foundation

/// 智能助手的统一检索：和界面搜索结果页共用 `SearchProviders` 内核，
/// 一次调用就能跨图库 / 网盘 / 影院 / 网络影院 / 电视 / 资源取回分区、计数与命中。
extension LibraryStore {
    /// 跨来源统一检索。
    func unifiedSearchTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let keyword = AILibraryTools.string(args["query"]) else {
            return failure("请提供要搜索的关键词")
        }
        let scope = AILibraryTools.string(args["scope"]) ?? "global"
        let perSource = min(50, max(1, AILibraryTools.integer(args["limit"], fallback: 12)))
        let requested = AILibraryTools.stringArray(args["sources"])
        let sources = aiUnifiedSearchSources(requested: requested, scope: scope)
        guard !sources.isEmpty else {
            return failure("没有可用的搜索来源：相关模块可能已关闭")
        }

        let providers = SearchProviders
            .makeAll(store: self, catalog: catalogModel, tv: tvModel)
            .filter { sources.contains($0.source) }
        guard !providers.isEmpty else {
            return failure("当前没有可调度的检索来源")
        }

        var sections: [SearchSection] = []
        for provider in providers {
            if Task.isCancelled { break }
            sections.append(await provider.search(query: keyword, limit: perSource))
        }
        sections.sort {
            (sources.firstIndex(of: $0.source) ?? Int.max) < (sources.firstIndex(of: $1.source) ?? Int.max)
        }

        let total = sections.reduce(0) { $0 + $1.total }
        // 命中按返回顺序编号为 #1…#N，存入缓存，供 open_search_result 直接打开。
        var refs: [SearchHit] = []
        var sectionPayloads: [[String: Any]] = []
        for section in sections {
            sectionPayloads.append(aiSearchSectionPayload(section, refs: &refs))
        }
        aiUnifiedSearchHits = refs
        let photoIDs = refs.compactMap { hit -> UUID? in
            if case .photo(let id) = hit.payload { return id }
            return nil
        }
        return success(["query": keyword,
                        "scope": scope,
                        "sources": sources.map(\.rawValue),
                        "total": total,
                        "sections": sectionPayloads],
                       summary: "跨来源检索「\(keyword)」",
                       photoIDs: photoIDs)
    }

    /// 打开最近一次 `unified_search` 的命中：ref 取返回里的 `#N`。
    func openSearchResultTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let raw = AILibraryTools.string(args["ref"]) else {
            return failure("缺少 ref，例如 #3；请先调用 unified_search")
        }
        let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let index = Int(digits),
              index >= 1, index <= aiUnifiedSearchHits.count else {
            return failure("没有这个结果编号：\(raw)。请先调用 unified_search，再用返回的 ref")
        }
        let hit = aiUnifiedSearchHits[index - 1]
        let photoIDs: [UUID]
        if case .photo(let id) = hit.payload {
            photoIDs = [id]
        } else {
            photoIDs = []
        }
        openSearchHit(hit)
        return success(["ref": "#\(index)",
                        "kind": hit.kind.rawValue,
                        "title": hit.title],
                       summary: "打开「\(hit.title)」",
                       photoIDs: photoIDs)
    }

    /// 按关键词自然语言扩展出标准标签：词表直配先命中，SigLIP 文本塔补齐。
    /// 与界面搜索共用同一套数据，但不读写 `semanticSearchTags`，避免搜索框遗留状态污染 AI 查询。
    func aiSemanticTags(for query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var merged = PhotoTagCatalog.shared?.searchTitles(for: trimmed) ?? []
        let expanded = await Task.detached(priority: .userInitiated) {
            SigLIPEngine.shared.expand(query: trimmed)
        }.value
        for tag in expanded where !merged.contains(tag) {
            merged.append(tag)
        }
        return merged
    }

    // MARK: - 来源选择

    private func aiUnifiedSearchSources(requested: [String], scope: String) -> [SearchSourceKind] {
        var sources: [SearchSourceKind]
        let parsed = requested.compactMap(Self.aiSearchSourceKind)
        if !parsed.isEmpty {
            sources = parsed
        } else if scope == "module" {
            sources = aiModuleSearchScopes
        } else {
            sources = AppModules.enabledSearchScopes
        }
        var seen = Set<SearchSourceKind>()
        return sources.filter { source in
            AppModules.isEnabled(source) && seen.insert(source).inserted
        }
    }

    /// 当前页面所属模块对应的来源；不在任何内容模块时按图库处理。
    private var aiModuleSearchScopes: [SearchSourceKind] {
        switch sidebarItem {
        case .iptv:
            return [.television]
        case .networkCinema:
            return [.networkCinema]
        case .cinema, .cloudCinema:
            return [.cinema]
        case .catalogSources, .catalogSource:
            return [.catalog]
        case .atlas:
            return [.atlas]
        case .cloudStorages, .cloudMount:
            return [.cloud]
        default:
            return [.library]
        }
    }

    private static func aiSearchSourceKind(_ raw: String) -> SearchSourceKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "library", "图库": return .library
        case "cloud", "网盘", "网络存储": return .cloud
        case "cinema", "影院": return .cinema
        case "networkcinema", "网络影院": return .networkCinema
        case "television", "tv", "电视", "网络电视": return .television
        case "catalog", "resource", "资源", "网络资源": return .catalog
        case "atlas", "星图", "拾光星图", "资料库": return .atlas
        default: return nil
        }
    }

    // MARK: - 结果序列化

    private func aiSearchSectionPayload(_ section: SearchSection,
                                        refs: inout [SearchHit]) -> [String: Any] {
        var kinds: [String: Int] = [:]
        for (kind, count) in section.kindCounts where count > 0 {
            kinds[kind.title] = count
        }
        var hits: [[String: Any]] = []
        for hit in section.hits {
            refs.append(hit)
            hits.append(aiSearchHitPayload(hit, ref: refs.count))
        }
        var body: [String: Any] = [
            "source": section.source.rawValue,
            "source_title": section.source.title,
            "total": section.total,
            "kinds": kinds,
            "hits": hits
        ]
        let origins = section.origins
        if !origins.isEmpty {
            let rows: [[String: Any]] = origins.prefix(8).map {
                ["title": $0.title, "count": $0.count]
            }
            body["origins"] = rows
        }
        return body
    }

    private func aiSearchHitPayload(_ hit: SearchHit, ref: Int) -> [String: Any] {
        var body: [String: Any] = [
            "ref": "#\(ref)",
            "kind": hit.kind.rawValue,
            "kind_title": hit.kind.title,
            "title": hit.title,
            "subtitle": hit.subtitle
        ]
        if let badge = hit.badge { body["badge"] = badge }
        if let origin = hit.origin { body["origin"] = origin }
        if let category = hit.category { body["category"] = category }
        if let path = hit.libraryPath { body["library_path"] = path }
        switch hit.payload {
        case .photo(let id):
            body["photo_id"] = id.uuidString
        case .localAlbum(let id):
            body["album_id"] = id.uuidString
        case .localFolder(let id):
            body["folder_id"] = id.uuidString
        case .localPerson(let id):
            body["person_id"] = id.uuidString
        case .systemAlbum(let id):
            body["system_album_id"] = id
        case .systemFolder(let id):
            body["system_folder_id"] = id
        case .systemPerson(let person):
            body["person_name"] = person.name
        case .place:
            body["place"] = hit.title
        case .scene(let id):
            body["scene"] = id
        case .cloudFile(let mountID, let folderPath, let path):
            body["mount_id"] = mountID.uuidString
            body["path"] = path
            if let folderPath { body["folder"] = folderPath }
        case .cloudFolder(let mountID, let path):
            body["mount_id"] = mountID.uuidString
            body["path"] = path
        case .cinema(_, let queueTitle, _):
            body["queue"] = queueTitle
        case .channel(let channel):
            body["channel"] = channel.name
            body["playlist_id"] = channel.playlistID.uuidString
        case .program(let channel, let program):
            body["channel"] = channel.name
            body["playlist_id"] = channel.playlistID.uuidString
            body["start"] = Self.aiSearchDateFormatter.string(from: program.start)
        case .catalogItem(let sourceID, let item):
            body["source_id"] = sourceID.uuidString
            body["item_id"] = item.id
        case .networkCinemaItem(let sourceID, let item, let isTV):
            body["source_id"] = sourceID.uuidString
            body["item_id"] = item.id
            body["is_tv"] = isTV
        case .atlasPerson(let id):
            body["actress_id"] = String(id)
        case .atlasWork(let id):
            body["work_id"] = String(id)
        }
        return body
    }

    private static let aiSearchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
