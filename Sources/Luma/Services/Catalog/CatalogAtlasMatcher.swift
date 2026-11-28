import Foundation

/// 二级目录里「人名牌」的两种形态：女优与片商。
enum CatalogRosterKind: Sendable {
    case people
    case studios
}

/// 名册里的一个人 / 一个厂牌：命中星图时带完整档案，未收录时保留站点原文与空档案。
struct CatalogRosterEntry: Identifiable, Sendable {
    let id: String
    let title: String
    /// 英文名 / 日文名，或资料库里的别名。
    let subtitle: String?
    let region: String?
    let facts: [CatalogRosterFact]
    let tags: [String]
    let summary: String?
    let avatarBase64: String?
    let atlasPersonID: Int64?
    let atlasStudioID: Int64?

    var isMatched: Bool { atlasPersonID != nil || atlasStudioID != nil }
}

/// 浮窗里的一行资料：身高、三围、出生这类短字段。
struct CatalogRosterFact: Identifiable, Sendable, Hashable {
    let label: String
    let value: String
    var id: String { "\(label)|\(value)" }
}

/// 星图匹配的唯一入口：判定一组二级分类是不是「女优 / 片商」名册，
/// 并把名字批量换成资料库档案。
///
/// 性能约定：
/// - 判定只用内存里的两个精确索引，每个名字两次字典查找，几十项也在亚毫秒级；
/// - 判定结果按「标题 + 子项」缓存，SwiftUI 反复重绘不会重复算；
/// - 头像用一条 `IN (…)` SQL 批量取，不再逐条查库；
/// - 所有重活（匹配、取头像、拼档案）都放到后台任务，主线程只拿结果。
enum CatalogAtlasMatcher {
    private struct Detection {
        var kind: CatalogRosterKind?
    }

    private static let cacheLock = NSLock()
    private static var detections: [String: Detection] = [:]
    private static var detectionOrder: [String] = []
    private static let maxDetections = 256

    // MARK: - 判定

    /// 这一组二级分类是不是人名牌？命中时返回女优或片商。
    /// 标题语义优先；没有语义时再看名字在资料库里的命中比例。
    static func kind(parentTitle: String, children: [CatalogCategory]) -> CatalogRosterKind? {
        guard AtlasCatalogPaths.isLoaded,
              !children.isEmpty,
              children.count <= 400 else { return nil }

        let key = signature(parentTitle: parentTitle, children: children)
        cacheLock.lock()
        if let hit = detections[key] {
            cacheLock.unlock()
            return hit.kind
        }
        cacheLock.unlock()

        let started = Date()
        let kind = detect(parentTitle: parentTitle, children: children)

        cacheLock.lock()
        detections[key] = Detection(kind: kind)
        detectionOrder.append(key)
        if detectionOrder.count > maxDetections {
            let dropped = detectionOrder.removeFirst()
            detections[dropped] = nil
        }
        cacheLock.unlock()

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Diagnostics.record("星图匹配判定 \(parentTitle) · \(children.count) 项 · "
                           + "\(kind.map { $0 == .people ? "女优" : "片商" } ?? "不是名册") · \(elapsed)ms")
        return kind
    }

    /// 专题 / 合集卡片墙（`森萝财团精选`、`樱桃喵精选`、`布丁大法写真合集`）：
    /// 一张墙里人物与品牌混着写，逐个标题先查人物再查品牌，命中的都挂档案。
    /// 标题匹配会剥掉「精选 / 合集 / 写真」这类装饰词，并支持两三个字的短名。
    static func mixedEntries(children: [CatalogCategory]) async -> [CatalogRosterEntry] {
        guard !children.isEmpty else { return [] }
        let targets = children.map { (id: $0.id, title: $0.title) }
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> [CatalogRosterEntry] in
            let people = targets.map { CatalogNameDictionary.exactActress(matching: $0.title) }
            let studios = targets.indices.map { index in
                people[index] == nil
                    ? CatalogNameDictionary.exactStudio(matching: targets[index].title)
                    : nil
            }
            let personAvatars = CatalogAvatarStore.personBase64(ids: people.compactMap { $0?.id })
            let studioAvatars = CatalogAvatarStore.studioBase64(ids: studios.compactMap { $0?.id })
            return targets.indices.map { index in
                let target = targets[index]
                if let person = people[index] {
                    return personEntry(id: target.id, record: person,
                                       avatar: personAvatars[person.id])
                }
                if let studio = studios[index] {
                    return studioEntry(id: target.id, record: studio,
                                       avatar: studioAvatars[studio.id])
                }
                return emptyEntry(id: target.id, title: target.title)
            }
        }.value
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let matched = result.filter(\.isMatched).count
        Diagnostics.record("星图合集卡片 · \(children.count) 项 · 命中 \(matched) · \(elapsed)ms")
        return result
    }

    private static func detect(parentTitle: String,
                               children: [CatalogCategory]) -> CatalogRosterKind? {
        // 1. 站点自己已经标好的 id 前缀（JavGG 的 models/ channels/）。
        if children.allSatisfy({ $0.id.hasPrefix("models/") }) { return .people }
        if children.allSatisfy({ $0.id.hasPrefix("channels/") }) { return .studios }

        // 2. 一级标题直接说明是人名牌。
        let peopleWords = ["模特", "女优", "女優", "演员", "演員", "人物", "女郎", "明星"]
        let studioWords = ["厂商", "廠商", "片商", "发布商", "發布商", "传媒", "傳媒",
                           "厂牌", "廠牌", "发行", "發行", "制作", "製作", "机构", "機構",
                           "工作室", "经纪", "經紀"]
        if peopleWords.contains(where: { parentTitle.contains($0) }) { return .people }
        if studioWords.contains(where: { parentTitle.contains($0) }) { return .studios }

        // 3. 题材 / 标签 / 筛选这类目录不做名册，避免把普通分类认成人名。
        let tagWords = ["标签", "標籤", "分类", "分類", "题材", "題材", "地区", "地區",
                        "年份", "排序", "筛选", "篩選", "归档", "歸檔", "排行", "榜单", "榜單", "全部"]
        if tagWords.contains(where: parentTitle.contains) { return nil }

        // 4. 名字命中比例：至少 2 个，且占四分之一以上。
        var people = 0
        var studios = 0
        for child in children {
            if CatalogNameDictionary.exactActress(matching: child.title) != nil { people += 1 }
            if CatalogNameDictionary.exactStudio(matching: child.title) != nil { studios += 1 }
        }
        let count = children.count
        if people >= 2, people * 4 >= count, people >= studios { return .people }
        if studios >= 2, studios * 4 >= count, studios > people { return .studios }
        return nil
    }

    private static func signature(parentTitle: String,
                                  children: [CatalogCategory]) -> String {
        var key = parentTitle
        key.reserveCapacity(parentTitle.count + children.count * 24)
        for child in children {
            key += "|"
            key += child.id
            key += "\u{1F}"
            key += child.title
        }
        return key
    }

    // MARK: - 档案

    /// 把一组二级分类转成名册条目：命中的带完整档案，没命中的也保留一格。
    /// 匹配与头像读取都在后台，一次几十项只需要一条头像 SQL。
    static func entries(kind: CatalogRosterKind,
                        children: [CatalogCategory]) async -> [CatalogRosterEntry] {
        guard !children.isEmpty else { return [] }
        let targets = children.map { (id: $0.id, title: $0.title) }
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> [CatalogRosterEntry] in
            switch kind {
            case .people:
                let records = targets.map {
                    CatalogNameDictionary.exactActress(matching: $0.title)
                }
                let avatars = CatalogAvatarStore.personBase64(
                    ids: records.compactMap { $0?.id }
                )
                return zip(targets, records).map { target, record in
                    guard let record else {
                        return emptyEntry(id: target.id, title: target.title)
                    }
                    return personEntry(id: target.id, record: record,
                                       avatar: avatars[record.id])
                }
            case .studios:
                let records = targets.map {
                    CatalogNameDictionary.exactStudio(matching: $0.title)
                }
                let avatars = CatalogAvatarStore.studioBase64(
                    ids: records.compactMap { $0?.id }
                )
                return zip(targets, records).map { target, record in
                    guard let record else {
                        return emptyEntry(id: target.id, title: target.title)
                    }
                    return studioEntry(id: target.id, record: record,
                                       avatar: avatars[record.id])
                }
            }
        }.value
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let matched = result.filter(\.isMatched).count
        Diagnostics.record("星图名册 \(kind == .people ? "女优" : "片商") · "
                           + "\(children.count) 项 · 命中 \(matched) · \(elapsed)ms")
        return result
    }

    private static func emptyEntry(id: String, title: String) -> CatalogRosterEntry {
        CatalogRosterEntry(id: id,
                           title: title,
                           subtitle: nil,
                           region: nil,
                           facts: [],
                           tags: [],
                           summary: nil,
                           avatarBase64: nil,
                           atlasPersonID: nil,
                           atlasStudioID: nil)
    }

    private static func personEntry(id: String,
                                    record: CatalogActressRecord,
                                    avatar: String?) -> CatalogRosterEntry {
        var facts: [CatalogRosterFact] = []
        if let birth = record.birthDate, !birth.isEmpty {
            let age = record.age.map { " · \($0) 岁" } ?? ""
            facts.append(.init(label: "出生", value: birth + age))
        }
        if let height = record.heightCM {
            facts.append(.init(label: "身高", value: "\(height) cm"))
        }
        if let bust = record.bust, let waist = record.waist, let hips = record.hips {
            facts.append(.init(label: "三围", value: "B\(bust) / W\(waist) / H\(hips)"))
        }
        if let cup = record.cup, !cup.isEmpty {
            facts.append(.init(label: "罩杯", value: cup))
        }
        if !record.aliases.isEmpty {
            facts.append(.init(label: "别名",
                               value: record.aliases.prefix(3).joined(separator: "、")))
        }
        facts.append(.init(label: "地区", value: record.regionTitle))
        let subtitle = [record.nameEN, record.nameJA]
            .compactMap { $0 }
            .first { CatalogNameParser.normalize($0)
                != CatalogNameParser.normalize(record.name) }
        return CatalogRosterEntry(id: id,
                                  title: record.name,
                                  subtitle: subtitle,
                                  region: record.regionTitle,
                                  facts: Array(facts.prefix(6)),
                                  tags: Array(record.tags.prefix(8)),
                                  summary: record.summary,
                                  avatarBase64: avatar,
                                  atlasPersonID: record.id,
                                  atlasStudioID: nil)
    }

    private static func studioEntry(id: String,
                                    record: CatalogStudioRecord,
                                    avatar: String?) -> CatalogRosterEntry {
        var facts: [CatalogRosterFact] = [
            .init(label: "地区", value: record.regionTitle)
        ]
        if record.kindTitle != "片商" {
            facts.append(.init(label: "类型", value: record.kindTitle))
        }
        if !record.aliases.isEmpty {
            facts.append(.init(label: "别名",
                               value: record.aliases.prefix(3).joined(separator: "、")))
        }
        return CatalogRosterEntry(id: id,
                                  title: record.name,
                                  subtitle: record.nameEN,
                                  region: record.regionTitle,
                                  facts: facts,
                                  tags: [],
                                  summary: record.summary,
                                  avatarBase64: avatar,
                                  atlasPersonID: nil,
                                  atlasStudioID: record.id)
    }
}
