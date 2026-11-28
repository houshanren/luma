import Foundation
import LumaDomain

/// 内容渲染：把工具结果里「能看的」东西抽成模块内容卡。
/// 影院竖版海报、资源与频道横版卡；照片仍走缩略图条，避免重复。
extension LibraryStore {
    /// 一次工具结果最多展示 8 条，避免回答被卡片淹没。
    private static let previewLimit = 8

    func aiResultPreviews(for call: AIToolCall,
                          args: [String: Any],
                          result: AIToolExecution) -> [AIResultPreview] {
        let domain = Self.aiPreviewDomain(for: call.name)
        guard domain != .photo else { return [] }
        guard let data = result.json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var items: [[String: Any]] = []
        Self.collectPreviewItems(from: root, into: &items)
        var previews: [AIResultPreview] = []
        var seen = Set<String>()
        for item in items {
            guard let title = Self.previewTitle(item), !title.isEmpty else { continue }
            let key = domain.rawValue + "|" + title
            guard seen.insert(key).inserted else { continue }
            previews.append(AIResultPreview(domain: domain,
                                            title: title,
                                            subtitle: Self.previewSubtitle(item),
                                            imageURL: Self.previewImage(item),
                                            targetID: Self.previewID(item)))
            if previews.count >= Self.previewLimit { break }
        }
        return previews
    }

    /// 点击结果卡：跳到对应模块，让人接着用原来的界面。
    func openAIPreview(_ preview: AIResultPreview) {
        switch preview.domain {
        case .cinema:
            sidebarItem = .cinema
        case .networkCinema:
            sidebarItem = .networkCinema
        case .catalog:
            sidebarItem = .catalogSources
        case .tv:
            sidebarItem = .iptv
        case .photo:
            if let id = preview.photoID {
                openViewer(id)
            }
        }
    }

    // MARK: - 解析

    static func aiPreviewDomain(for name: String) -> AIResultDomain {
        if name.contains("network_cinema") { return .networkCinema }
        if name.hasPrefix("tv_") || name.contains("_tv_") { return .tv }
        if name.contains("catalog") { return .catalog }
        if name.contains("cinema") { return .cinema }
        if name == "resume_watching" { return .cinema }
        return .photo
    }

    private static let previewArrayKeys: Set<String> = [
        "items", "results", "list", "movies", "series", "channels",
        "candidates", "videos", "entries", "matches", "records"
    ]

    private static let titleKeys = [
        "title", "name", "display_name", "displayName", "filename",
        "original_name", "channel_name", "show_title"
    ]

    private static func collectPreviewItems(from object: Any,
                                            into items: inout [[String: Any]],
                                            depth: Int = 0) {
        guard depth < 3, items.count < 60 else { return }
        if let dict = object as? [String: Any] {
            if previewTitle(dict) != nil {
                items.append(dict)
            }
            for (key, value) in dict {
                if let array = value as? [Any] {
                    if previewArrayKeys.contains(key) {
                        for element in array {
                            if let item = element as? [String: Any] { items.append(item) }
                        }
                    } else {
                        collectPreviewItems(from: value, into: &items, depth: depth + 1)
                    }
                } else if let nested = value as? [String: Any] {
                    collectPreviewItems(from: nested, into: &items, depth: depth + 1)
                }
            }
            return
        }
        if let array = object as? [Any] {
            for element in array {
                collectPreviewItems(from: element, into: &items, depth: depth + 1)
            }
        }
    }

    private static func string(_ any: Any?) -> String? {
        switch any {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func previewTitle(_ item: [String: Any]) -> String? {
        for key in titleKeys {
            if let value = string(item[key]) { return value }
        }
        return nil
    }

    private static func previewSubtitle(_ item: [String: Any]) -> String {
        var parts: [String] = []
        if let year = string(item["year"]) {
            parts.append(year)
        }
        if let season = string(item["season"]), let episode = string(item["episode"]) {
            parts.append("S\(season)E\(episode)")
        } else if let episode = string(item["episode"]) {
            parts.append("第 \(episode) 集")
        }
        if let rating = item["rating"] as? Double, rating > 0 {
            parts.append(String(format: "★ %.1f", rating))
        } else if let rating = item["rating"] as? Int, rating > 0 {
            parts.append("★ \(rating)")
        }
        if parts.isEmpty, let kind = string(item["type"]) ?? string(item["kind"]) {
            parts.append(kind)
        }
        return parts.joined(separator: " · ")
    }

    private static let imageKeys = [
        "poster_url", "posterURL", "poster", "artwork_url", "artworkURL",
        "cover", "cover_url", "logo", "logo_url", "image", "image_url"
    ]

    private static func previewImage(_ item: [String: Any]) -> String? {
        for key in imageKeys {
            guard let raw = string(item[key]) else { continue }
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                return raw
            }
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw).absoluteString
            }
        }
        return nil
    }

    private static func previewID(_ item: [String: Any]) -> String? {
        for key in ["id", "uuid", "target_id", "channel_id", "photo_id"] {
            if let value = string(item[key]) { return value }
        }
        return nil
    }
}
