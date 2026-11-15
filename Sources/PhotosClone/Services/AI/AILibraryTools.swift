import Foundation

/// 提供给智能助手的本地工具：搜索与整理图库。
/// 所有写操作都先经过用户确认，再走 LibraryStore 现有方法落盘。
enum AILibraryTools {
    /// 需要用户确认的写操作。
    static let writeToolNames: Set<String> = [
        "create_albums", "add_photos_to_album", "set_favorite", "add_keywords"
    ]

    static var definitions: [AIRequestTool] {
        [
            AIRequestTool(
                name: "search_photos",
                description: "按关键词、时间词、类型、人物或场景搜索当前图库，返回匹配照片的 id 与基本信息。需要照片 id 时优先调用它。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "搜索词，例如「去年 海边」「截图」「小猫」"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "最多返回数量，默认 20"]
                    ],
                    "required": ["query"]
                ]
            ),
            AIRequestTool(
                name: "list_albums",
                description: "列出当前图库的相簿及其 id、名称与照片数量，便于后续把照片加入已有相簿。",
                parameters: ["type": "object", "properties": [:]]
            ),
            AIRequestTool(
                name: "create_albums",
                description: "创建相簿并把指定照片放进去。用户明确要求新建相簿或按主题分组时调用。同名相簿已存在时会把照片追加进去。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "albums": [
                            "type": "array",
                            "description": "要创建的相簿列表",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string", "description": "相簿名称"],
                                    "photo_ids": [
                                        "type": "array",
                                        "items": ["type": "string"],
                                        "description": "要放入该相簿的照片 UUID"
                                    ]
                                ],
                                "required": ["name", "photo_ids"]
                            ]
                        ]
                    ],
                    "required": ["albums"]
                ]
            ),
            AIRequestTool(
                name: "add_photos_to_album",
                description: "把照片加入已有相簿。可以用 album_id 或 album_name 指定相簿。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "album_id": ["type": "string", "description": "相簿 UUID；与 album_name 二选一"],
                        "album_name": ["type": "string", "description": "相簿名称；与 album_id 二选一"],
                        "photo_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "要加入的照片 UUID"
                        ]
                    ],
                    "required": ["photo_ids"]
                ]
            ),
            AIRequestTool(
                name: "set_favorite",
                description: "收藏或取消收藏照片。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "photo_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "照片 UUID"
                        ],
                        "favorite": ["type": "boolean", "description": "true 为收藏，false 为取消收藏"]
                    ],
                    "required": ["photo_ids", "favorite"]
                ]
            ),
            AIRequestTool(
                name: "add_keywords",
                description: "给照片添加关键词（不会删除已有词）。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "photo_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "照片 UUID"
                        ],
                        "keywords": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "要添加的关键词"
                        ]
                    ],
                    "required": ["photo_ids", "keywords"]
                ]
            ),
            AIRequestTool(
                name: "select_photos",
                description: "在当前网格中选中照片，方便用户继续查看或操作。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "photo_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "照片 UUID"
                        ]
                    ],
                    "required": ["photo_ids"]
                ]
            )
        ]
    }

    static func arguments(_ raw: String) -> [String: Any] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 少数模型会把参数包在 Markdown 代码块里。
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func stringArray(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        if let string = value as? String { return [string] }
        return []
    }

    static func integer(_ value: Any?, fallback: Int) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return fallback
    }

    static func bool(_ value: Any?, fallback: Bool) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return fallback
    }

    /// 用于确认弹窗的可读描述。
    static func describe(_ call: AIToolCall) -> String {
        let args = arguments(call.arguments)
        let photoCount = stringArray(args["photo_ids"]).count
        switch call.name {
        case "create_albums":
            let albums = args["albums"] as? [[String: Any]] ?? []
            let parts = albums.compactMap { item -> String? in
                guard let name = item["name"] as? String else { return nil }
                return "\(name)（\(stringArray(item["photo_ids"]).count) 张）"
            }
            return "创建/更新相簿：\(parts.joined(separator: "、"))"
        case "add_photos_to_album":
            let name = (args["album_name"] as? String) ?? "已有相簿"
            return "加入相簿「\(name)」：\(photoCount) 张照片"
        case "set_favorite":
            let favorite = bool(args["favorite"], fallback: true)
            return "\(favorite ? "收藏" : "取消收藏") \(photoCount) 张照片"
        case "add_keywords":
            let keywords = stringArray(args["keywords"]).joined(separator: "、")
            return "为 \(photoCount) 张照片添加关键词：\(keywords)"
        case "select_photos":
            return "选中 \(photoCount) 张照片"
        default:
            return call.name
        }
    }
}
