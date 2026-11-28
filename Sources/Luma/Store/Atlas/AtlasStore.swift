import Foundation
import Observation
import SwiftUI

/// 星图的六个看法：发现 / 星图 / 影院 / 作品集 / 图集 / 人物。
/// 「图集」「影院」会同时接住网络资源里的在线条目，不再只是资料库内部浏览。
enum AtlasMode: String, CaseIterable, Identifiable {
    case discover
    case constellation
    case theater
    case works
    case galleries
    case people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: return "发现"
        case .constellation: return "星图"
        case .theater: return "影院"
        case .works: return "作品集"
        case .galleries: return "图集"
        case .people: return "人物"
        }
    }

    var symbol: String {
        switch self {
        case .discover: return "sparkles.rectangle.stack"
        case .constellation: return "circle.hexagongrid.fill"
        case .theater: return "play.rectangle.fill"
        case .works: return "square.grid.2x2.fill"
        case .galleries: return "photo.stack.fill"
        case .people: return "person.text.rectangle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .discover: return "人物、作品与在线资源汇成一屏；从这里开始探索"
        case .constellation: return "七万位人物按作品与共演关系铺成星图"
        case .theater: return "大银幕试看，资料库没有的就去在线资源里找"
        case .works: return "按年份、分类与番号翻作品集"
        case .galleries: return "网络资源里的图集与写真，按人物与站点聚合"
        case .people: return "杂志式人物档案，一键关联在线资源"
        }
    }
}

/// 星图的数据与选择状态。整个模块共用一份，搜索跳转也写在这里。
@MainActor
@Observable
final class AtlasStore {
    static let shared = AtlasStore()

    var mode: AtlasMode = .discover
    /// 人物页内部的视角：档案 / 胸型谱 / 身高谱 / 标签星座 / 作品量。
    var peopleView: AtlasPeopleView = .archive
    private(set) var people: [AtlasPerson] = []
    private(set) var years: [AtlasYearCount] = []
    private(set) var genres: [AtlasGenre] = []
    private(set) var totals: (people: Int, works: Int, genres: Int) = (0, 0, 0)
    private(set) var isLoading = false
    private(set) var isAvailable = true

    var selectedPersonID: Int64? {
        didSet { loadDetailIfNeeded() }
    }
    private(set) var detail: AtlasPersonDetail?

    /// 搜索 / 网络资源跳转：页面出现时消费。
    var pendingPersonID: Int64?
    var pendingWorkID: Int64?
    var pendingCode: String?
    /// 点开的作品：统一用一张详情弹层展示，各视图共用。
    var focusedWork: AtlasWork?

    var regionFilter: String? {
        didSet { if regionFilter != oldValue { filterDidChange() } }
    }
    /// 星图内的全局搜索词：作品集、人物、图集与发现页共用。
    var searchText = ""

    // MARK: 人物检索台（尺子 + 标签）
    //
    // 花名册不再从常驻的 1400 位里筛，而是带着条件回 SQL 查：
    // 这样尺子上的人数与列表里的结果永远对得上，也不会被载入上限截断。
    var cupFilter: String? {
        didSet { if cupFilter != oldValue { filterDidChange() } }
    }
    var heightBandFilter: Int? {
        didSet { if heightBandFilter != oldValue { filterDidChange() } }
    }
    var tagFilter: String? {
        didSet { if tagFilter != oldValue { filterDidChange() } }
    }
    /// 作品量阶梯：存档位下限（1000 / 500 / 200 / 50 / 0）。
    var workTierFilter: Int? {
        didSet { if workTierFilter != oldValue { filterDidChange() } }
    }
    /// 花名册与分析结果的排序。
    var personSort: AtlasPersonSort = .works {
        didSet { if personSort != oldValue { reloadRoster() } }
    }
    private(set) var roster: [AtlasPerson] = []
    private(set) var rosterTotal = 0
    private(set) var cupFacets: [AtlasCupFacet] = []
    private(set) var heightBands: [AtlasHeightBand] = []
    private(set) var tagFacets: [AtlasTagFacet] = []
    private(set) var cupHeightMatrix: [AtlasCupHeightCell] = []
    private(set) var workTiers: [AtlasWorkTier] = []
    private(set) var isLoadingRoster = false
    private var rosterGeneration = 0
    private var suppressFilterReload = false

    var hasFigureFilters: Bool {
        cupFilter != nil || heightBandFilter != nil || tagFilter != nil || workTierFilter != nil
    }

    // MARK: 人物检索台

    /// 尺子 / 标签 / 地区变了：分面与花名册各刷一次（都很轻，直接查 SQL）。
    private func filterDidChange() {
        guard !suppressFilterReload else { return }
        reloadFacets()
        reloadRoster()
    }

    func reloadFacets() {
        guard isAvailable else { return }
        let region = regionFilter
        Task {
            let payload = await run { db in
                (db.cupFacets(region: region),
                 db.heightBands(region: region),
                 db.tagFacets(region: region))
            }
            guard let payload else { return }
            cupFacets = payload.0
            heightBands = payload.1
            tagFacets = payload.2
        }
        Task {
            let payload = await run { db in
                (db.cupHeightMatrix(region: region), db.workTierFacets(region: region))
            }
            guard let payload else { return }
            cupHeightMatrix = payload.0
            workTiers = payload.1
        }
    }

    /// 按当前地区 / 罩杯 / 身高段 / 标签 / 搜索词重查花名册。
    func reloadRoster() {
        guard isAvailable else {
            roster = []
            rosterTotal = 0
            isLoadingRoster = false
            return
        }
        rosterGeneration &+= 1
        let generation = rosterGeneration
        let region = regionFilter
        let cup = cupFilter
        let band = heightBandFilter
        let tag = tagFilter
        let tier = workTierFilter
        let sort = personSort
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyword.isEmpty ? nil : keyword
        isLoadingRoster = true
        Task {
            let payload = await run { db -> ([AtlasPerson], Int) in
                (db.rosterPeople(region: region, cup: cup, heightBand: band,
                                 tag: tag, workTier: tier, keyword: key, sort: sort),
                 db.rosterCount(region: region, cup: cup, heightBand: band,
                                tag: tag, workTier: tier, keyword: key))
            }
            guard generation == rosterGeneration else { return }
            let people = payload?.0 ?? []
            roster = people
            rosterTotal = payload?.1 ?? people.count
            isLoadingRoster = false
            // 选中的人被筛掉了就落到第一位，避免右侧档案与左侧花名册对不上。
            if let id = selectedPersonID, people.contains(where: { $0.id == id }) { return }
            selectedPersonID = people.first?.id
        }
    }

    func toggleCup(_ cup: String) {
        cupFilter = cupFilter == cup ? nil : cup
    }

    /// 体型矩阵一次点中罩杯 + 身高段：合并成一次重查。
    func selectCupAndBand(cup: String?, band: Int?) {
        guard cupFilter != cup || heightBandFilter != band else { return }
        suppressFilterReload = true
        cupFilter = cup
        heightBandFilter = band
        suppressFilterReload = false
        reloadRoster()
    }

    func toggleHeightBand(_ start: Int) {
        heightBandFilter = heightBandFilter == start ? nil : start
    }

    func toggleTag(_ tag: String) {
        tagFilter = tagFilter == tag ? nil : tag
    }

    func toggleWorkTier(_ min: Int) {
        workTierFilter = workTierFilter == min ? nil : min
    }

    func resetFigureFilters() {
        guard hasFigureFilters else { return }
        suppressFilterReload = true
        cupFilter = nil
        heightBandFilter = nil
        tagFilter = nil
        workTierFilter = nil
        suppressFilterReload = false
        reloadRoster()
    }

    // MARK: 作品集浏览
    var workYear: Int?
    var workGenre: String?
    var workSort: AtlasWorkSort = .newest
    private(set) var workItems: [AtlasWork] = []
    private(set) var workTotal = 0
    private(set) var isLoadingWorks = false
    private(set) var canLoadMoreWorks = false
    private var workOffset = 0
    private let workPageSize = 60
    /// 每换一次筛选 / 关键词就加一：旧的分页结果回来时直接丢弃。
    private var workGeneration = 0

    private var worksByYear: [Int: [AtlasWork]] = [:]
    private var worksByGenre: [String: [AtlasWork]] = [:]
    private var detailCache: [Int64: AtlasPersonDetail] = [:]
    private var didBootstrap = false

    private var database: AtlasDatabase { AtlasDatabase() }

    /// 发现页头图：按日期轮换，同一天进来看到同一位。
    var featuredPerson: AtlasPerson? {
        guard !people.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return people[(day * 7) % people.count]
    }

    // MARK: 加载

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        isLoading = true
        Task {
            let payload = await run { db in
                (db.totals(), db.people(limit: 1400), db.yearCounts())
            }
            if let payload {
                totals = payload.0
                people = payload.1
                years = payload.2
                isAvailable = !payload.1.isEmpty
            } else {
                isAvailable = false
            }
            isLoading = false
        }
        Task {
            let genres = await run { $0.genres(limit: 72) }
            if let genres { self.genres = genres }
        }
        reloadFacets()
        reloadRoster()
        reloadWorks()
    }

    /// 资料库被加载 / 卸载 / 换了一份之后重置：清掉所有缓存重新取一遍。
    func reload() {
        didBootstrap = false
        people = []
        years = []
        genres = []
        totals = (0, 0, 0)
        detail = nil
        selectedPersonID = nil
        worksByYear.removeAll()
        worksByGenre.removeAll()
        detailCache.removeAll()
        workItems = []
        workTotal = 0
        workOffset = 0
        canLoadMoreWorks = false
        roster = []
        rosterTotal = 0
        cupFacets = []
        heightBands = []
        tagFacets = []
        cupHeightMatrix = []
        workTiers = []
        isLoadingRoster = false
        rosterGeneration &+= 1
        isAvailable = AtlasCatalogPaths.isLoaded
        guard isAvailable else {
            isLoading = false
            isLoadingWorks = false
            return
        }
        bootstrapIfNeeded()
    }

    // MARK: 作品集

    func reloadWorks() {
        // 换筛选 / 换关键词时作废还在路上的那一页，否则旧结果会覆盖新列表。
        workGeneration &+= 1
        isLoadingWorks = false
        workOffset = 0
        workItems = []
        workTotal = 0
        canLoadMoreWorks = true
        loadMoreWorks()
    }

    func loadMoreWorks() {
        guard !isLoadingWorks, canLoadMoreWorks else { return }
        isLoadingWorks = true
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = workYear
        let genre = workGenre
        let sort = workSort
        let offset = workOffset
        let limit = workPageSize
        let generation = workGeneration
        Task {
            if !keyword.isEmpty {
                // 有关键词时按番号 / 片名检索，不做分页。
                let payload = await run { db -> ([AtlasWork], Int) in
                    (db.searchWorks(keyword, limit: 120), 0)
                }
                guard generation == workGeneration else { return }
                if let payload {
                    workItems = payload.0
                    workTotal = payload.0.count
                }
                canLoadMoreWorks = false
            } else {
                let payload = await run { db -> ([AtlasWork], Int) in
                    (db.works(year: year, genre: genre, sort: sort, offset: offset, limit: limit),
                     db.workTotal(year: year, genre: genre))
                }
                guard generation == workGeneration else { return }
                if let payload {
                    workItems += payload.0
                    workTotal = payload.1
                    workOffset += payload.0.count
                    canLoadMoreWorks = payload.0.count >= limit && workOffset < payload.1
                } else {
                    canLoadMoreWorks = false
                }
            }
            isLoadingWorks = false
        }
    }

    func openWorks(year: Int? = nil, genre: String? = nil) {
        workYear = year
        workGenre = genre
        mode = .works
        reloadWorks()
    }

    func works(for year: Int) -> [AtlasWork] {
        worksByYear[year] ?? []
    }

    func loadWorksIfNeeded(year: Int) {
        guard worksByYear[year] == nil else { return }
        Task {
            let works = await run { $0.works(year: year, limit: 24) } ?? []
            worksByYear[year] = works
        }
    }

    func works(forGenre genre: String) -> [AtlasWork] {
        worksByGenre[genre] ?? []
    }

    func loadWorksIfNeeded(genre: String) {
        guard worksByGenre[genre] == nil else { return }
        Task {
            let works = await run { $0.works(genre: genre, limit: 24) } ?? []
            worksByGenre[genre] = works
        }
    }

    // MARK: 影院

    func theaterQueue(hour: Int = Calendar.current.component(.hour, from: Date())) -> [AtlasWork] {
        // 按小时轮换：同一小时进入看到同一组，跨小时自动换一档。
        let pool = worksByYear.values.flatMap { $0 }
        guard !pool.isEmpty else { return [] }
        let start = (hour * 7) % max(pool.count, 1)
        return Array(pool[start...].prefix(12)) + Array(pool[..<min(start, 12)])
    }

    func loadTheaterPool() {
        guard worksByYear[0] == nil else { return }
        Task {
            let seed = await run { db in
                db.randomWorks(limit: 30)
            } ?? []
            worksByYear[0] = seed
        }
    }

    // MARK: 人物

    func loadDetailIfNeeded() {
        guard let id = selectedPersonID, detailCache[id] == nil else {
            if let id = selectedPersonID { detail = detailCache[id] }
            return
        }
        Task {
            let loaded = await run { db -> AtlasPersonDetail? in
                guard let person = db.person(id: id) else { return nil }
                return AtlasPersonDetail(
                    person: person,
                    works: db.personWorks(id: id, limit: 48),
                    coStars: db.coStars(id: id, limit: 10),
                    genres: db.personGenres(id: id, limit: 8),
                    topWorks: db.personWorks(id: id, limit: 8),
                    links: db.personLinks(id: id),
                    labels: db.personLabels(id: id, limit: 8))
            }
            if let loaded {
                detailCache[id] = loaded
                if selectedPersonID == id { detail = loaded }
            }
        }
    }

    func selectPerson(_ id: Int64) {
        mode = .people
        peopleView = .archive
        selectedPersonID = id
    }

    // MARK: 搜索与反查

    func searchPeople(_ keyword: String, limit: Int = 12) async -> [AtlasPerson] {
        await run { $0.searchPeople(keyword, limit: limit) } ?? []
    }

    func searchWorks(_ keyword: String, limit: Int = 12) async -> [AtlasWork] {
        await run { $0.searchWorks(keyword, limit: limit) } ?? []
    }

    func work(code: String) async -> AtlasWork? {
        await run { $0.work(code: code) } ?? nil
    }

    func work(id: Int64) async -> AtlasWork? {
        await run { $0.work(id: id) } ?? nil
    }

    // MARK: 工具

    private func run<T: Sendable>(_ body: @escaping @Sendable (AtlasDatabase) -> T) async -> T? {
        await Task.detached(priority: .userInitiated) {
            let db = AtlasDatabase()
            guard db.isAvailable else { return nil }
            return body(db)
        }.value
    }
}
