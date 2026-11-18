import Foundation

// MARK: - 影院刮削与播放

extension LibraryStore {
    /// 本地图库的刮削结果沿用旧 key，网盘各自一份。
    static let cinemaIndexSettingKey = "cinema_index"

    static func cinemaSettingKey(for scope: CinemaScope) -> String {
        switch scope {
        case .local:
            return cinemaIndexSettingKey
        case .mount(let id):
            return "cinema_index_\(id.uuidString)"
        }
    }

    // MARK: 读写

    /// 当前查看作用域的条目。
    var cinemaEntries: [UUID: CinemaEntry] {
        cinemaIndexes[cinemaActiveScope] ?? [:]
    }

    func cinemaEntries(for scope: CinemaScope) -> [UUID: CinemaEntry] {
        cinemaIndexes[scope] ?? [:]
    }

    func cinemaMatchedCount(for scope: CinemaScope) -> Int {
        (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
    }

    /// 启动时把本地与每个网盘的结果都读进内存，网格缩略图随时能拿到海报。
    func loadCinemaIndexes() {
        guard let metadataStore else { return }
        var loaded: [CinemaScope: [UUID: CinemaEntry]] = [:]
        let scopes: [CinemaScope] = [.local] + cloudMounts.map { .mount($0.id) }
        for scope in scopes {
            let key = Self.cinemaSettingKey(for: scope)
            guard let json = metadataStore.setting(key),
                  let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([CinemaEntry].self, from: data) else { continue }
            loaded[scope] = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
        cinemaIndexes = loaded
    }

    /// 旧版本把所有网盘的条目混在一个 key 里：按 `cloudMountID` 拆回各自作用域。
    func migrateLegacyCinemaIndexIfNeeded() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaIndexSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaEntry].self, from: data),
              list.contains(where: { $0.file.cloudMountID != nil }) else { return }

        var split: [CinemaScope: [UUID: CinemaEntry]] = [:]
        for entry in list {
            let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
            split[scope, default: [:]][entry.id] = entry
        }
        for (scope, entries) in split {
            // 已经有新数据的网盘不覆盖。
            if scope != .local, let existing = cinemaIndexes[scope], !existing.isEmpty { continue }
            cinemaIndexes[scope] = entries
            persistCinemaIndex(for: scope)
        }
    }

    func persistCinemaIndex(for scope: CinemaScope) {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(Array((cinemaIndexes[scope] ?? [:]).values)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaSettingKey(for: scope), json)
    }

    func clearCinemaIndex(for scope: CinemaScope) {
        cinemaIndexes[scope] = [:]
        persistCinemaIndex(for: scope)
        cinemaScrapeMessage = "已清除这个影院的刮削结果"
    }

    func activateCinemaScope(_ scope: CinemaScope) {
        if cinemaActiveScope != scope {
            cinemaScrapeMessage = nil
            // 换了影院就回到「全部年代 / 全部类型」，避免筛选条件在另一个库里把人筛空。
            cinemaDecade = nil
            cinemaGenre = nil
        }
        cinemaActiveScope = scope
    }

    func cinemaEntry(for id: UUID) -> CinemaEntry? {
        cinemaEntries[id]
    }

    var cinemaScrapeProgress: Double {
        guard cinemaScrapeTotal > 0 else { return 0 }
        return min(1, Double(cinemaScrapeDone) / Double(cinemaScrapeTotal))
    }

    /// 网格里的视频优先显示刮削背景图：按视频所属网盘取对应作用域的条目。
    func cinemaGridArtwork(for photo: PhotoItem) -> String? {
        guard photo.isVideo else { return nil }
        if let mountID = photo.cloudMountID {
            return cinemaIndexes[.mount(mountID)]?[photo.id]?.gridArtworkURL
        }
        return cinemaIndexes[.local]?[photo.id]?.gridArtworkURL
    }

    // MARK: 聚合

    var cinemaMatchedEntries: [CinemaEntry] {
        cinemaEntries.values
            .filter { $0.matched }
            .sorted { $0.file.capturedAt > $1.file.capturedAt }
    }

    var cinemaMovies: [CinemaEntry] {
        cinemaMatchedEntries.filter { $0.kind == .movie }
    }

    var cinemaTVEpisodes: [CinemaEntry] {
        cinemaMatchedEntries.filter { $0.kind == .tv }
    }

    /// 当前作用域的剧集聚合：同一部剧的多集合成一张卡片。
    var cinemaSeries: [CinemaSeries] {
        cinemaSeries(for: cinemaActiveScope)
    }

    func cinemaSeries(for scope: CinemaScope, matched: Bool = true) -> [CinemaSeries] {
        let episodes = (cinemaIndexes[scope] ?? [:]).values
            .filter { $0.kind == .tv && $0.matched == matched }
        var groups: [String: [CinemaEntry]] = [:]
        for entry in episodes {
            groups[seriesKey(entry), default: []].append(entry)
        }
        return groups.compactMap { key, items in
            let sorted = items.sorted { lhs, rhs in
                if lhs.season != rhs.season { return (lhs.season ?? 0) < (rhs.season ?? 0) }
                if lhs.episode != rhs.episode { return (lhs.episode ?? 0) < (rhs.episode ?? 0) }
                return lhs.file.capturedAt < rhs.file.capturedAt
            }
            // 海报 / 简介取信息最全的一集。
            let sample = sorted.first(where: { $0.backdropURL != nil })
                ?? sorted.first(where: { $0.posterURL != nil })
                ?? sorted[0]
            return CinemaSeries(id: key,
                                title: sample.title,
                                year: sample.year,
                                overview: sample.overview,
                                rating: sample.rating,
                                posterURL: sample.posterURL,
                                backdropURL: sample.backdropURL,
                                episodes: sorted)
        }
        .sorted { lhs, rhs in
            (lhs.latestEpisode?.file.capturedAt ?? .distantPast)
                > (rhs.latestEpisode?.file.capturedAt ?? .distantPast)
        }
    }

    private func seriesKey(_ entry: CinemaEntry) -> String {
        if let providerID = entry.tmdbID { return "tv-\(providerID)" }
        let normalized = entry.title.lowercased().filter { $0.isLetter || $0.isNumber }
        // 未识别时年份只是从文件名猜的：同一部剧有的集能猜到、有的猜不到，
        // 一旦把年份放进 key 就会被拆成好几张卡，所以未识别只按剧名分桶。
        guard entry.matched, let year = entry.year else { return "tv-\(normalized)" }
        return "tv-\(normalized)-\(year)"
    }

    /// 可刮削的视频：本地图库只取本地；网盘取这个链接的扫描清单，并带上所在目录链。
    func cinemaCandidates(for scope: CinemaScope) -> [CinemaCandidate] {
        var byID: [UUID: CinemaCandidate] = [:]

        func merge(_ photo: PhotoItem, hint: String?) {
            guard CinemaScraper.isCandidate(photo) else { return }
            if let existing = byID[photo.id] {
                // 已经有目录线索的不要被后来的「无线索」覆盖。
                if existing.folderHint == nil, hint != nil {
                    byID[photo.id] = CinemaCandidate(photo: photo, folderHint: hint)
                }
            } else {
                byID[photo.id] = CinemaCandidate(photo: photo, folderHint: hint)
            }
        }

        switch scope {
        case .local:
            for photo in photos { merge(photo, hint: nil) }
        case .mount(let mountID):
            guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { break }

            // 目录名 → 父目录，用来还原「剧名 / 季」链条。
            var names: [String: String] = [:]
            var parents: [String: String] = [:]
            let snapshot = cloudAlbumSnapshot(mountID: mountID)
            if let folders = snapshot?.folders {
                for folder in folders {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }
            if cloudModel.scanMountID == mountID {
                for folder in cloudModel.scanFolders {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }

            if cloudModel.scanMountID == mountID {
                for photo in cloudModel.scanPhotos {
                    let folder = photo.cloudPath.flatMap { cloudModel.scanMediaFolder[$0] }
                    merge(photo, hint: folderChain(folder, names: names, parents: parents))
                }
            }

            // 上次扫描的快照：即使当前没有打开这个网盘，也能拿到完整清单与目录名。
            if let snapshot {
                for record in snapshot.records where record.isVideo {
                    let photo = cloudAlbumPhoto(record: record, mount: mount)
                    merge(photo, hint: folderChain(record.folderPath,
                                                   names: names,
                                                   parents: parents))
                }
            }

            for photo in cloudPhotos where photo.cloudMountID == mountID {
                let folder = photo.cloudPath.flatMap { cloudModel.scanMediaFolder[$0] }
                merge(photo, hint: folderChain(folder, names: names, parents: parents))
            }
        }
        return Array(byID.values)
    }

    /// 拼出「剧名 / Season 01」这类目录链，最多向上三级；未知目录返回 nil。
    private func folderChain(_ path: String?,
                             names: [String: String],
                             parents: [String: String],
                             limit: Int = 3) -> String? {
        guard var cursor = path, !cursor.isEmpty else { return nil }
        var parts: [String] = []
        var hops = 0
        while hops < limit {
            guard let name = names[cursor], !name.isEmpty else { break }
            parts.append(name)
            guard let parent = parents[cursor], !parent.isEmpty else { break }
            cursor = parent
            hops += 1
        }
        return parts.isEmpty ? nil : parts.reversed().joined(separator: "/")
    }

    // MARK: 配置

    /// 当前数据源是否还需要用户补配置（只有 TMDB 需要 Key，豆瓣免 Key）。
    var cinemaNeedsConfiguration: Bool {
        switch AppSettings.shared.cinemaProvider {
        case .tmdb:
            return AppSettings.shared.cinemaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .douban:
            return false
        }
    }

    private func metadataSource() -> (any CinemaMetadataSource)? {
        let settings = AppSettings.shared
        switch settings.cinemaProvider {
        case .tmdb:
            let key = settings.cinemaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TMDBClient(apiKey: key,
                              apiBase: settings.cinemaAPIBase,
                              imageBase: settings.cinemaImageBase,
                              language: settings.cinemaLanguage)
        case .douban:
            return DoubanClient(apiBase: settings.cinemaDoubanBase,
                                cookie: settings.cinemaDoubanCookie)
        }
    }

    /// 设置面板里的「测试连接」：用固定片名搜一次，验证凭据与网络。
    func testCinemaConnection() async {
        guard !cinemaConnectionTesting else { return }
        guard let source = metadataSource() else {
            cinemaConnectionResult = CinemaConnectionResult(ok: false, message: "先填写 TMDB API Key")
            return
        }
        cinemaConnectionTesting = true
        cinemaConnectionResult = nil
        do {
            let results = try await source.search(query: "流浪地球", isTV: false, year: nil)
            if let first = results.first {
                let year = first.year.map { "（\($0)）" } ?? ""
                cinemaConnectionResult = CinemaConnectionResult(ok: true, message: "连接正常：\(first.title)\(year)")
            } else {
                cinemaConnectionResult = CinemaConnectionResult(ok: true, message: "连接正常，但搜索没有返回结果")
            }
        } catch {
            cinemaConnectionResult = CinemaConnectionResult(ok: false, message: error.localizedDescription)
        }
        cinemaConnectionTesting = false
    }

    // MARK: 刮削

    /// 刮削某一个影院（本地图库或某个网盘）。`force` 为 true 时连已刮削过的也重新匹配。
    func scrapeCinema(for scope: CinemaScope, force: Bool = false) async {
        guard !cinemaScrapeRunning else { return }
        guard let source = metadataSource() else {
            cinemaScrapeMessage = "请先在设置 › 影院里填写 TMDB API Key"
            return
        }

        let all = cinemaCandidates(for: scope)
        let existing = cinemaIndexes[scope] ?? [:]
        // 没识别成功的条目留在「未识别」里；再次点刮削时重试它们，而不是直接说「都已刮削」。
        let pending = force ? all : all.filter { existing[$0.photo.id]?.matched != true }
        guard !pending.isEmpty else {
            cinemaScrapeMessage = all.isEmpty
                ? "这个链接下还没有可刮削的视频清单，先在「相簿」里重新扫描网盘"
                : "这个链接的视频都已识别，没有新的可刮削"
            return
        }

        cinemaScrapeRunning = true
        cinemaScrapeScope = scope
        cinemaScrapeDone = 0
        cinemaScrapeTotal = pending.count
        cinemaScrapeMessage = nil
        showToast("开始刮削这个链接下的 \(pending.count) 个视频…")

        // 同一部剧的多集共用同名搜索结果，避免几十集重复请求。
        let cache = CinemaSearchCache()
        var failures = 0
        var consecutiveFailures = 0
        var firstError: String?
        for (index, candidate) in pending.enumerated() {
            if Task.isCancelled { break }
            let outcome = await CinemaScraper.scrape(photo: candidate.photo,
                                                     folderHint: candidate.folderHint,
                                                     source: source,
                                                     cache: cache)
            if let entry = outcome.entry {
                cinemaIndexes[scope, default: [:]][entry.id] = entry
            }
            if let error = outcome.error {
                failures += 1
                consecutiveFailures += 1
                if firstError == nil { firstError = error }
                // 连续失败多半是断网 / 代理 / 凭据失效：立刻停下并说清楚原因，
                // 不要每个视频再等一轮超时，也不要让界面看起来「毫无反应」。
                if consecutiveFailures >= 2 {
                    persistCinemaIndex(for: scope)
                    cinemaScrapeRunning = false
                    cinemaScrapeScope = nil
                    cinemaScrapeMessage = "刮削中断：连续 \(consecutiveFailures) 个视频请求失败。"
                        + Self.cinemaNetworkHint(for: error)
                    showToast("刮削中断：连不上\(AppSettings.shared.cinemaProvider.title)")
                    return
                }
            } else {
                consecutiveFailures = 0
            }
            cinemaScrapeDone = index + 1
            if index % 5 == 0 {
                persistCinemaIndex(for: scope)
                await Task.yield()
            }
        }

        persistCinemaIndex(for: scope)
        cinemaScrapeRunning = false
        cinemaScrapeScope = nil
        let scopeEntries = cinemaIndexes[scope] ?? [:]
        let matched = scopeEntries.values.filter { $0.matched }.count
        let unmatched = scopeEntries.count - matched
        var message = "刮削完成：共 \(scopeEntries.count) 个视频，识别 \(matched) 个，未识别 \(unmatched) 个"
        if failures > 0 {
            message += "；\(failures) 条失败：" + Self.cinemaNetworkHint(for: firstError ?? "网络或接口异常")
        }
        cinemaScrapeMessage = message
    }

    /// 把常见网络错误翻译成能直接照做的提示。
    static func cinemaNetworkHint(for message: String) -> String {
        let lower = message.lowercased()
        let networkLike = ["timed out", "timeout", "超时", "offline", "internet", "connect",
                           "network", "networkconnection", "连接", "无法访问"]
        if networkLike.contains(where: { lower.contains($0) }) {
            return "当前网络无法连接 \(AppSettings.shared.cinemaProvider.title)，请检查代理或网络后重试。"
        }
        return "\(AppSettings.shared.cinemaProvider.title) 返回：\(message)"
    }

    /// 单条重新刮削（右键菜单），结果写回条目所属的影院。
    func rescrapeCinema(_ entry: CinemaEntry) async {
        guard let source = metadataSource() else {
            cinemaScrapeMessage = "请先在设置 › 影院里填写 TMDB API Key"
            return
        }
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let outcome = await CinemaScraper.scrape(photo: photo,
                                                 folderHint: entry.folderHint,
                                                 source: source)
        if let error = outcome.error {
            cinemaScrapeMessage = "重新刮削失败：\(error)"
            showToast("重新刮削失败")
            return
        }
        guard let updated = outcome.entry else { return }
        cinemaIndexes[scope, default: [:]][updated.id] = updated
        persistCinemaIndex(for: scope)
        showToast(updated.matched ? "已匹配「\(updated.title)」" : "仍未找到匹配结果")
    }

    // MARK: 播放

    /// 从影院直接进入查看器；不依赖该网盘目录当前是否加载。
    func openCinema(_ entry: CinemaEntry) {
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        cinemaPlaybackPhoto = photo
        openViewer(photo.id)
    }
}
