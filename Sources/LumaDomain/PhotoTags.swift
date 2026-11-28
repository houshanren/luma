import Foundation

/// 一个端侧识别标签：中文标准名、去重分组、检索别名与命中阈值。
package struct PhotoTagDefinition: Decodable {
    package let id: String
    package let title: String
    package let group: String
    package let prompts: [String]
    package let aliases: [String]
    package let threshold: Double
    package init(
        id: String,
        title: String,
        group: String,
        prompts: [String],
        aliases: [String],
        threshold: Double
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.prompts = prompts
        self.aliases = aliases
        self.threshold = threshold
    }
}

/// 端侧标签目录（源码 `Resources/Models/SigLIP2Assets/tags.json`，安装后位于模型目录的 `SigLIP2/tags.json`）。
/// 标准名唯一，分组用于互斥去重：同一组只保留得分最高的若干个，避免「猫 / 狗 / 动物」叠在一起。
package final class PhotoTagCatalog: Decodable {
    package let version: Int
    package let embeddingDim: Int
    package let defaultThreshold: Double
    package let groupLimits: [String: Int]
    package let tags: [PhotoTagDefinition]

    /// 分析结果里的版本标记：旧分析结果没有它，会按需重扫。
    /// v2：轨迹标签扩充（208 → 249）后必须重扫，否则旧库拿不到亲子 / 戏水 / 古迹等标签。
    /// v3：合入 Apple Vision 分类器补充（天空 / 文档 / 截图 / 服饰等欠触发），存量库需重扫。
    /// v4：第二信号改成门控（仅 SigLIP 标签 < 2 时补），压回 Apple 带来的误报，存量库需重扫。
    package static let sentinel = "siglip2-v4"

    private let orderIndex: [String: Int]
    private let aliasEntries: [(alias: String, title: String)]

    private static let sharedLock = NSLock()
    private static var cached: PhotoTagCatalog?
    private static var loaded = false

    /// 模型资源定位由 App 注入：Domain 不直接依赖模型安装目录。
    package static var resourceResolver: ((String) -> URL?)?

    /// 词表随模型一起安装，所以不能只做一次性静态缓存：模型后装也要能读到。
    package static var shared: PhotoTagCatalog? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if !loaded {
            cached = load()
            loaded = true
        }
        return cached
    }

    /// 模型重新安装后调用，下一次读取会重新加载 tags.json。
    package static func invalidateShared() {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        cached = nil
        loaded = false
    }

    private enum CodingKeys: String, CodingKey {
        case version, embeddingDim, defaultThreshold, groupLimits, tags
    }

    package required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        embeddingDim = try container.decodeIfPresent(Int.self, forKey: .embeddingDim) ?? 768
        defaultThreshold = try container.decodeIfPresent(Double.self, forKey: .defaultThreshold) ?? 0.08
        groupLimits = try container.decodeIfPresent([String: Int].self, forKey: .groupLimits) ?? [:]
        tags = try container.decode([PhotoTagDefinition].self, forKey: .tags)
        var order: [String: Int] = [:]
        var aliases: [(String, String)] = []
        for (index, tag) in tags.enumerated() {
            order[tag.title] = index
            aliases.append((tag.title.lowercased(), tag.title))
            for alias in tag.aliases where !alias.isEmpty {
                aliases.append((alias.lowercased(), tag.title))
            }
        }
        orderIndex = order
        aliasEntries = aliases
    }

    private static func load() -> PhotoTagCatalog? {
        guard let url = resourceResolver?("SigLIP2/tags.json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(PhotoTagCatalog.self, from: data),
              !catalog.tags.isEmpty else { return nil }
        return catalog
    }

    /// 按目录顺序整理已命中的标签，过滤掉版本标记与未知标签。
    package func canonicalTitles(from labels: Set<String>) -> [String] {
        labels
            .filter { orderIndex[$0] != nil }
            .sorted { (orderIndex[$0] ?? 0) < (orderIndex[$1] ?? 0) }
    }

    /// 检索词命中：先精确匹配别名，再允许「查询包含别名 / 别名包含查询」。
    package func searchTitles(for token: String) -> [String] {
        let query = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var seen: Set<String> = []
        var hits: [String] = []
        for entry in aliasEntries {
            let value = entry.alias
            let matched: Bool
            if value == query {
                matched = true
            } else if query.count >= 3, value.count >= 2 {
                // 「海边日落」包含「海边」；单字查询只做精确匹配，避免「手」命中「手机」。
                matched = query.contains(value)
            } else if value.count >= 3, query.count >= 3 {
                matched = value.contains(query)
            } else {
                matched = false
            }
            guard matched, seen.insert(entry.title).inserted else { continue }
            hits.append(entry.title)
            if hits.count >= 8 { break }
        }
        return hits
    }

    package func definition(for title: String) -> PhotoTagDefinition? {
        guard let index = orderIndex[title] else { return nil }
        return tags[index]
    }
}

// 模型资源定位已迁到 `Services/Models/ModelRegistry.swift`，
// 统一处理「下载目录 → App 包内 → 开发源码目录」的解析顺序。
