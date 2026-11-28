import Foundation
import Observation

/// 网络资源里的一条在线条目：视频或图集。
struct AtlasOnlineEntry: Identifiable, Hashable, Codable {
    let sourceID: UUID
    let sourceName: String
    /// 站点类型是图集站（综合站仍可能混着视频，按站点归类即可）。
    let isGallery: Bool
    let item: CatalogItem

    var id: String { "\(sourceID.uuidString)|\(item.id)" }

    /// 标题里的番号：用来和资料库作品对齐。
    var code: String? { CatalogNameParser.titleMetadata(item.title).code }
}

/// 把「网络资源」接进星图：按人物名 / 番号检索所有启用的资源站，
/// 结果按视频与图集分开，并在内存 + Application Support 里缓存 7 天。
@MainActor
@Observable
final class AtlasOnlineStore {
    static let shared = AtlasOnlineStore()

    struct Snapshot: Codable {
        var at: Date
        var videos: [AtlasOnlineEntry]
        var galleries: [AtlasOnlineEntry]
    }

    private(set) var keyword = ""
    private(set) var videos: [AtlasOnlineEntry] = []
    private(set) var galleries: [AtlasOnlineEntry] = []
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    private(set) var note: String?

    private var memory: [String: Snapshot] = [:]
    private var didLoadDisk = false
    private(set) var revision = 0

    private static let ttl: TimeInterval = 7 * 24 * 60 * 60
    private static let memoryLimit = 40

    /// 已缓存就立即返回（供人物档案首屏直接铺结果）。
    func snapshot(for raw: String) -> Snapshot? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        ensureDiskLoaded()
        guard let cached = memory[key], Date().timeIntervalSince(cached.at) < Self.ttl else { return nil }
        return cached
    }

    func load(_ raw: String, catalog: CatalogBrowserModel, force: Bool = false) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            clearResults()
            return
        }
        keyword = key
        ensureDiskLoaded()
        if !force, let cached = memory[key], Date().timeIntervalSince(cached.at) < Self.ttl {
            videos = cached.videos
            galleries = cached.galleries
            lastUpdated = cached.at
            note = nil
            return
        }
        if force { memory[key] = nil }

        let sources = catalog.enabledResourceSources
        guard !sources.isEmpty else {
            videos = []
            galleries = []
            lastUpdated = nil
            note = "还没有启用的网络资源站点，先去「网络资源」接入，星图才能联动在线内容。"
            return
        }

        isLoading = true
        note = nil
        var collected: [(index: Int, entries: [AtlasOnlineEntry])] = []
        await withTaskGroup(of: (Int, [AtlasOnlineEntry]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let items = await CatalogSearchSupport.search(source, keyword: key)
                    let entries = items.prefix(12).map { item in
                        AtlasOnlineEntry(sourceID: source.id,
                                         sourceName: source.name,
                                         isGallery: source.kind.isGallerySite,
                                         item: item)
                    }
                    return (index, entries)
                }
            }
            for await result in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if !result.1.isEmpty { collected.append((index: result.0, entries: result.1)) }
            }
        }
        guard !Task.isCancelled else { return }

        let ordered = collected.sorted { $0.index < $1.index }.flatMap { $0.entries }
        videos = ordered.filter { !$0.isGallery }
        galleries = ordered.filter { $0.isGallery }
        lastUpdated = Date()
        isLoading = false
        if ordered.isEmpty {
            note = "网络资源里没有匹配「\(key)」的条目。"
        }
        let snapshot = Snapshot(at: Date(), videos: videos, galleries: galleries)
        memory[key] = snapshot
        trimMemory()
        persist()
        revision += 1
    }

    func clearResults() {
        keyword = ""
        videos = []
        galleries = []
        isLoading = false
        lastUpdated = nil
        note = nil
    }

    /// 清空全部在线缓存（内存 + 磁盘）。
    func clearCache() {
        memory = [:]
        clearResults()
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    // MARK: 缓存

    private func trimMemory() {
        guard memory.count > Self.memoryLimit else { return }
        let kept = memory.sorted { $0.value.at > $1.value.at }.prefix(Self.memoryLimit)
        memory = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func ensureDiskLoaded() {
        guard !didLoadDisk else { return }
        didLoadDisk = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let decoded = try? JSONDecoder().decode([String: Snapshot].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        memory = decoded.filter { $0.value.at > cutoff }
    }

    private func persist() {
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        let kept = memory.filter { $0.value.at > cutoff }
            .sorted { $0.value.at > $1.value.at }
            .prefix(Self.memoryLimit)
        let payload = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Luma/atlas-online-cache.json")
    }
}
