import Foundation

/// 提供给智能助手的本地工具：检索、浏览、相簿、文件夹、图片与视频。
/// 所有写操作都先经过用户确认，再走 LibraryStore 现有方法落盘。
enum AILibraryTools {
    /// 需要用户确认的写操作。
    static let writeToolNames: Set<String> = [
        "create_albums", "add_photos_to_album", "remove_photos_from_album",
        "rename_album", "delete_album", "move_album", "set_album_cover",
        "create_folder", "rename_folder", "delete_folder",
        "set_favorite", "set_hidden", "add_keywords", "remove_keywords",
        "set_title", "compress_photos", "beautify_photos", "trash_photos", "restore_photos"
    ]

    static var definitions: [AIRequestTool] {
        [searchPhotos, listAlbums, listFolders, listVideos,
         navigate, selectPhotos, openPhoto,
         createAlbums, addPhotosToAlbum, removePhotosFromAlbum,
         renameAlbum, deleteAlbum, moveAlbum, setAlbumCover,
         createFolder, renameFolder, deleteFolder,
         setFavorite, setHidden, addKeywords, removeKeywords,
         setTitle, compressPhotos, beautifyPhotos, trashPhotos, restorePhotos]
    }

    /// 工具总数（界面展示用，避免每次重算 schema）。
    static let count = definitions.count

    // MARK: - 检索

    private static var searchPhotos: AIRequestTool {
        AIRequestTool(
            name: "search_photos",
            description: "按关键词、时间、地点、场景、文件名或类型搜索当前图库，返回照片与视频的 id 与基本信息。需要引用或操作具体项目时先调用它。",
            parameters: objectSchema([
                "query": stringSchema("搜索词，例如「去年 海边」「小猫」「截图」「IMG_2043」；留空则按 filter 返回"),
                "filter": enumSchema(["all", "photos", "videos", "favorites", "screenshots", "edited"],
                                     "按类型过滤，默认 all"),
                "limit": integerSchema("最多返回数量，默认 20，最大 80", minimum: 1, maximum: 80)
            ])
        )
    }

    private static var listAlbums: AIRequestTool {
        AIRequestTool(
            name: "list_albums",
            description: "列出当前图库的全部相簿：id、名称、项目数、所属文件夹与封面。需要把照片加入已有相簿时先调用它。",
            parameters: objectSchema([:])
        )
    }

    private static var listFolders: AIRequestTool {
        AIRequestTool(
            name: "list_folders",
            description: "列出当前图库的文件夹树：id、名称、父级与其中的相簿数。",
            parameters: objectSchema([:])
        )
    }

    private static var listVideos: AIRequestTool {
        AIRequestTool(
            name: "list_videos",
            description: "列出当前图库的最近视频：id、名称、时长、大小、分辨率、收藏状态与所在相簿。",
            parameters: objectSchema([
                "limit": integerSchema("最多返回数量，默认 30，最大 100", minimum: 1, maximum: 100)
            ])
        )
    }

    // MARK: - 浏览

    private static var navigate: AIRequestTool {
        AIRequestTool(
            name: "navigate",
            description: "切换用户当前浏览的范围，并可选设置筛选、搜索词与排序。只改变界面视图，不修改图库内容。",
            parameters: objectSchema([
                "target": enumSchema(["library", "favorites", "videos", "screenshots", "hidden", "trash",
                                      "all_albums", "album", "folder", "scene",
                                      "recently_edited", "imports"],
                                     "要切换到的范围；album 需配合 album_id/album_name，folder 需配合 folder_id/folder_name"),
                "album_id": stringSchema("相簿 id；target = album 时使用"),
                "album_name": stringSchema("相簿名称；target = album 时可用名称代替 id"),
                "folder_id": stringSchema("文件夹 id；target = folder 时使用"),
                "folder_name": stringSchema("文件夹名称；target = folder 时可用名称代替 id"),
                "scene": stringSchema("场景 id 或名称，例如「自然风景」「美食」；target = scene 时使用"),
                "filter": enumSchema(["all", "favorites", "edited", "photos", "videos", "screenshots"],
                                     "额外筛选条件，可省略"),
                "search": stringSchema("搜索词，可省略"),
                "sort": enumSchema(["capturedAt", "addedAt", "title", "filename", "fileSize", "kind", "camera", "place", "duration"],
                                   "排序字段，可省略"),
                "ascending": booleanSchema("是否升序，可省略")
            ], required: ["target"])
        )
    }

    private static var selectPhotos: AIRequestTool {
        AIRequestTool(
            name: "select_photos",
            description: "在当前网格中选中照片或视频，方便用户继续查看或操作。",
            parameters: objectSchema(["photo_ids": photoIDsSchema], required: ["photo_ids"])
        )
    }

    private static var openPhoto: AIRequestTool {
        AIRequestTool(
            name: "open_photo",
            description: "在查看器中打开一张照片或播放一个视频。",
            parameters: objectSchema([
                "photo_id": stringSchema("照片或视频的 id，也支持候选编号 #3 或唯一文件名")
            ], required: ["photo_id"])
        )
    }

    // MARK: - 相簿

    private static var createAlbums: AIRequestTool {
        AIRequestTool(
            name: "create_albums",
            description: "创建相簿并把指定项目放进去，可指定所属文件夹。同名相簿已存在时会把项目追加进去。仅本地图库可用。",
            parameters: objectSchema([
                "albums": arraySchema([
                    "type": "object",
                    "properties": [
                        "name": stringSchema("相簿名称"),
                        "photo_ids": photoIDsSchema,
                        "folder_id": stringSchema("所属文件夹 id，可省略"),
                        "folder_name": stringSchema("所属文件夹名称，可省略")
                    ],
                    "required": ["name", "photo_ids"]
                ], description: "要创建的相簿列表")
            ], required: ["albums"])
        )
    }

    private static var addPhotosToAlbum: AIRequestTool {
        AIRequestTool(
            name: "add_photos_to_album",
            description: "把照片或视频加入已有相簿，可用 album_id 或 album_name 指定相簿。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "photo_ids": photoIDsSchema
            ], required: ["photo_ids"])
        )
    }

    private static var removePhotosFromAlbum: AIRequestTool {
        AIRequestTool(
            name: "remove_photos_from_album",
            description: "把项目从相簿移出（不会删除照片本身）。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "photo_ids": photoIDsSchema
            ], required: ["photo_ids"])
        )
    }

    private static var renameAlbum: AIRequestTool {
        AIRequestTool(
            name: "rename_album",
            description: "重命名相簿。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "new_name": stringSchema("新的相簿名称")
            ], required: ["new_name"])
        )
    }

    private static var deleteAlbum: AIRequestTool {
        AIRequestTool(
            name: "delete_album",
            description: "删除相簿本身，不会删除照片或视频。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一")
            ])
        )
    }

    private static var moveAlbum: AIRequestTool {
        AIRequestTool(
            name: "move_album",
            description: "把相簿移动到某个文件夹；不传文件夹表示移到相簿顶层。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "folder_id": stringSchema("目标文件夹 id；省略则移到顶层"),
                "folder_name": stringSchema("目标文件夹名称；省略则移到顶层")
            ])
        )
    }

    private static var setAlbumCover: AIRequestTool {
        AIRequestTool(
            name: "set_album_cover",
            description: "把相簿里的某个项目设为封面。仅本地图库可用。",
            parameters: objectSchema([
                "album_id": stringSchema("相簿 id；与 album_name 二选一"),
                "album_name": stringSchema("相簿名称；与 album_id 二选一"),
                "photo_id": stringSchema("要作为封面的项目 id")
            ], required: ["photo_id"])
        )
    }

    // MARK: - 文件夹

    private static var createFolder: AIRequestTool {
        AIRequestTool(
            name: "create_folder",
            description: "新建相簿文件夹，可指定父文件夹。仅本地图库可用。",
            parameters: objectSchema([
                "name": stringSchema("文件夹名称"),
                "parent_id": stringSchema("父文件夹 id，可省略"),
                "parent_name": stringSchema("父文件夹名称，可省略")
            ], required: ["name"])
        )
    }

    private static var renameFolder: AIRequestTool {
        AIRequestTool(
            name: "rename_folder",
            description: "重命名相簿文件夹。仅本地图库可用。",
            parameters: objectSchema([
                "folder_id": stringSchema("文件夹 id；与 folder_name 二选一"),
                "folder_name": stringSchema("文件夹名称；与 folder_id 二选一"),
                "new_name": stringSchema("新的文件夹名称")
            ], required: ["new_name"])
        )
    }

    private static var deleteFolder: AIRequestTool {
        AIRequestTool(
            name: "delete_folder",
            description: "删除文件夹及其中的相簿（不会删除照片或视频）。仅本地图库可用。",
            parameters: objectSchema([
                "folder_id": stringSchema("文件夹 id；与 folder_name 二选一"),
                "folder_name": stringSchema("文件夹名称；与 folder_id 二选一")
            ])
        )
    }

    // MARK: - 图片与视频

    private static var setFavorite: AIRequestTool {
        AIRequestTool(
            name: "set_favorite",
            description: "收藏或取消收藏照片与视频。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "favorite": booleanSchema("true 为收藏，false 为取消收藏")
            ], required: ["photo_ids", "favorite"])
        )
    }

    private static var setHidden: AIRequestTool {
        AIRequestTool(
            name: "set_hidden",
            description: "隐藏或取消隐藏照片与视频。仅本地图库，或作为当前图库的官方「照片」图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "hidden": booleanSchema("true 为隐藏，false 为取消隐藏")
            ], required: ["photo_ids", "hidden"])
        )
    }

    private static var addKeywords: AIRequestTool {
        AIRequestTool(
            name: "add_keywords",
            description: "给照片与视频添加关键词（不会删除已有词）。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "keywords": arraySchema(["type": "string"], description: "要添加的关键词")
            ], required: ["photo_ids", "keywords"])
        )
    }

    private static var removeKeywords: AIRequestTool {
        AIRequestTool(
            name: "remove_keywords",
            description: "从照片与视频移除指定关键词（不会删除其它关键词）。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "keywords": arraySchema(["type": "string"], description: "要移除的关键词")
            ], required: ["photo_ids", "keywords"])
        )
    }

    private static var setTitle: AIRequestTool {
        AIRequestTool(
            name: "set_title",
            description: "为照片与视频设置展示标题（传空字符串表示清除标题）。仅本地图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "title": stringSchema("新的标题")
            ], required: ["photo_ids", "title"])
        )
    }

    private static var compressPhotos: AIRequestTool {
        AIRequestTool(
            name: "compress_photos",
            description: "原地压缩照片并替换图库中的原文件（视频、系统图库与网盘项目不支持）。支持有损与无损两种方式；只有在结果更小时才替换，可在「压缩」面板还原。仅本地图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "mode": enumSchema(["lossy", "lossless"],
                                   "压缩方式：lossy 有损（可调质量与长边）；lossless 无损（保持像素与尺寸，JPEG 仅移除元数据，其它格式转无损 PNG）"),
                "quality": integerSchema("有损模式的质量百分比 10–100，默认 80；无损模式忽略", minimum: 10, maximum: 100),
                "max_dimension": integerSchema("有损模式的长边上限像素，0 表示不缩放；无损模式忽略", minimum: 0, maximum: 12000),
                "format": enumSchema(["original", "jpeg", "heic"], "有损模式的输出格式，默认 original 保持原格式；无损模式忽略"),
                "keep_backup": booleanSchema("是否保留压缩前备份，默认 false")
            ], required: ["photo_ids"])
        )
    }

    private static var beautifyPhotos: AIRequestTool {
        AIRequestTool(
            name: "beautify_photos",
            description: "用端侧智能分析为照片生成美化副本：按画面自动调整曝光、对比度、白平衡、饱和度、阴影与锐度。原图与已有编辑都保留，可随时在编辑器里还原。视频、系统图库与网盘项目不支持。仅本地图库可用。",
            parameters: objectSchema([
                "photo_ids": photoIDsSchema,
                "strength": integerSchema("美化强度百分比 20–150，默认 100", minimum: 20, maximum: 150)
            ], required: ["photo_ids"])
        )
    }

    private static var trashPhotos: AIRequestTool {
        AIRequestTool(
            name: "trash_photos",
            description: "把照片与视频移入「最近删除」，之后可以恢复。不会永久删除。仅本地图库可用。",
            parameters: objectSchema(["photo_ids": photoIDsSchema], required: ["photo_ids"])
        )
    }

    private static var restorePhotos: AIRequestTool {
        AIRequestTool(
            name: "restore_photos",
            description: "把「最近删除」中的项目恢复回图库。仅本地图库可用。",
            parameters: objectSchema(["photo_ids": photoIDsSchema], required: ["photo_ids"])
        )
    }

    // MARK: - JSON Schema 构造

    private static var photoIDsSchema: [String: Any] {
        arraySchema(["type": "string"],
                    description: "照片或视频的 id（UUID，也支持候选编号 #3 或唯一文件名）")
    }

    private static func objectSchema(_ properties: [String: Any],
                                     required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func arraySchema(_ items: [String: Any], description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }

    private static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func booleanSchema(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func integerSchema(_ description: String,
                                      minimum: Int,
                                      maximum: Int) -> [String: Any] {
        ["type": "integer", "description": description,
         "minimum": minimum, "maximum": maximum]
    }

    private static func enumSchema(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }

    // MARK: - 参数解析

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

    static func objectArray(_ value: Any?) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? [String: Any] } }
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

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 确认弹窗文案

    /// 用于确认弹窗的可读描述。
    static func describe(_ call: AIToolCall) -> String {
        let args = arguments(call.arguments)
        let photoCount = stringArray(args["photo_ids"]).count
        let albumName = string(args["album_name"])
        let folderName = string(args["folder_name"])
        switch call.name {
        case "create_albums":
            let albums = objectArray(args["albums"])
            let parts = albums.compactMap { item -> String? in
                guard let name = string(item["name"]) else { return nil }
                return "\(name)（\(stringArray(item["photo_ids"]).count) 项）"
            }
            return "创建/更新相簿：\(parts.joined(separator: "、"))"
        case "add_photos_to_album":
            return "加入相簿「\(albumName ?? "已有相簿")」：\(photoCount) 项"
        case "remove_photos_from_album":
            return "从相簿「\(albumName ?? "已有相簿")」移出：\(photoCount) 项"
        case "rename_album":
            return "相簿改名为「\(string(args["new_name"]) ?? "")」"
        case "delete_album":
            return "删除相簿「\(albumName ?? "指定相簿")」（不会删除照片）"
        case "move_album":
            return "移动相簿到「\(folderName ?? "顶层")」"
        case "set_album_cover":
            return "更新相簿「\(albumName ?? "指定相簿")」的封面"
        case "create_folder":
            return "新建文件夹「\(string(args["name"]) ?? "")」"
        case "rename_folder":
            return "文件夹改名为「\(string(args["new_name"]) ?? "")」"
        case "delete_folder":
            return "删除文件夹「\(folderName ?? "指定文件夹")」及其中的相簿（不会删除照片）"
        case "set_favorite":
            let favorite = bool(args["favorite"], fallback: true)
            return "\(favorite ? "收藏" : "取消收藏") \(photoCount) 项"
        case "set_hidden":
            let hidden = bool(args["hidden"], fallback: true)
            return "\(hidden ? "隐藏" : "取消隐藏") \(photoCount) 项"
        case "add_keywords":
            let keywords = stringArray(args["keywords"]).joined(separator: "、")
            return "为 \(photoCount) 项添加关键词：\(keywords)"
        case "remove_keywords":
            let keywords = stringArray(args["keywords"]).joined(separator: "、")
            return "从 \(photoCount) 项移除关键词：\(keywords)"
        case "set_title":
            return "为 \(photoCount) 项设置标题「\(string(args["title"]) ?? "")」"
        case "compress_photos":
            let mode = string(args["mode"]) ?? "lossy"
            if mode == "lossless" {
                return "无损压缩 \(photoCount) 张照片（保持像素与尺寸，仅移除元数据或转 PNG，会替换原文件）"
            }
            let quality = integer(args["quality"], fallback: 80)
            let maxDimension = integer(args["max_dimension"], fallback: 0)
            let sizePart = maxDimension > 0 ? "、长边 \(maxDimension)px" : ""
            return "有损压缩 \(photoCount) 张照片（质量 \(quality)%\(sizePart)，会替换原文件）"
        case "beautify_photos":
            let strength = integer(args["strength"], fallback: 100)
            return "智能美化 \(photoCount) 张照片（强度 \(strength)%，生成副本，原图保留）"
        case "trash_photos":
            return "把 \(photoCount) 项移入最近删除"
        case "restore_photos":
            return "从最近删除恢复 \(photoCount) 项"
        case "select_photos":
            return "选中 \(photoCount) 项"
        default:
            return call.name
        }
    }
}
