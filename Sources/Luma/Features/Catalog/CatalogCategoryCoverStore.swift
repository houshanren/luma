import Foundation
import Observation
import LumaContentCore

/// 二级分类（衣着 / 身材 / 玩法…）的门面图：取该分类第一页里第一张内容的封面。
///
/// 标签本身没有配图，抽象图标又对不上「黑絲」「巨乳」这种具体说法；
/// 直接用这一类里真实的内容缩略图，比任何符号都传神。
/// 拿到的地址按源缓存到本地，下次进来不再重复请求。
@MainActor
@Observable
final class CatalogCategoryCoverStore {
    static let shared = CatalogCategoryCoverStore()

    private var covers: [String: String] = [:]
    private var loading: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private static let defaultsKey = "catalog.categoryCovers.v1"
    /// 同时最多抓几张：一个分组二三十个标签，串行会让缩略图久久不出。
    private static let concurrency = 4

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        covers = decoded
    }

    func cover(sourceID: UUID, categoryID: String) -> String? {
        covers[Self.key(sourceID, categoryID)]
    }

    /// 面板出现时调用：只补缺图的分类，失败过的 5 分钟内不重试。
    func prefetch(source: CatalogSource, categories: [CatalogCategory]) {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return }
        let pending = categories.filter { category in
            let key = Self.key(source.id, category.id)
            if covers[key] != nil || loading.contains(key) { return false }
            if let failed = failedAt[key], Date().timeIntervalSince(failed) < 300 { return false }
            return true
        }
        guard !pending.isEmpty else { return }
        pending.forEach { loading.insert(Self.key(source.id, $0.id)) }
        Task { [weak self] in
            await withTaskGroup(of: (String, String?).self) { group in
                var next = 0
                func addNext() {
                    guard next < pending.count else { return }
                    let category = pending[next]
                    next += 1
                    group.addTask {
                        let page = try? await provider.category(source: source,
                                                                category: category,
                                                                sort: .latest, page: 1)
                        let cover = page?.items.first { !$0.coverURL.isEmpty }?.coverURL
                        return (category.id, cover)
                    }
                }
                for _ in 0..<Self.concurrency { addNext() }
                for await (categoryID, cover) in group {
                    self?.finish(sourceID: source.id, categoryID: categoryID, cover: cover)
                    addNext()
                }
            }
        }
    }

    private func finish(sourceID: UUID, categoryID: String, cover: String?) {
        let key = Self.key(sourceID, categoryID)
        loading.remove(key)
        guard let cover, !cover.isEmpty else {
            failedAt[key] = Date()
            return
        }
        covers[key] = cover
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(covers) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func key(_ sourceID: UUID, _ categoryID: String) -> String {
        "\(sourceID.uuidString)|\(categoryID)"
    }
}
