import Foundation
import AppKit

/// 一次工具调用的本地执行结果。
struct AIToolExecution {
    let json: String
    let summary: String?
    let photoIDs: [UUID]
}

/// 智能助手工具的执行入口：所有写操作都走 LibraryStore 现有方法并 `save()`。
extension LibraryStore {
    func executeAITool(_ call: AIToolCall) -> AIToolExecution {
        let args = AILibraryTools.arguments(call.arguments)
        switch call.name {
        case "search_photos":
            return searchPhotosTool(args)
        case "list_albums":
            return listAlbumsTool()
        case "create_albums":
            return createAlbumsTool(args)
        case "add_photos_to_album":
            return addToAlbumTool(args)
        case "set_favorite":
            return setFavoriteTool(args)
        case "add_keywords":
            return addKeywordsTool(args)
        case "select_photos":
            return selectPhotosTool(args)
        default:
            return failure("不支持的工具：\(call.name)")
        }
    }

    /// 写操作执行前统一确认；一次模型回复里的多个写操作只弹一次。
    func confirmAIToolActions(_ calls: [AIToolCall]) -> Bool {
        guard !calls.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "智能助手准备修改当前图库"
        alert.informativeText = calls
            .prefix(8)
            .map { "• " + AILibraryTools.describe($0) }
            .joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 工具实现

    private func searchPhotosTool(_ args: [String: Any]) -> AIToolExecution {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(50, max(1, AILibraryTools.integer(args["limit"], fallback: 20)))
        let source: [PhotoItem]
        if isCloudScope {
            source = cloudVisiblePhotos
        } else if isSystemScope {
            source = systemPhotos
        } else {
            source = photos
        }
        let search = query.isEmpty ? SearchQuery() : SearchQueryParser.parse(query)
        var items: [[String: Any]] = []
        var ids: [UUID] = []
        for photo in source {
            guard photo.deletedAt == nil else { continue }
            if !query.isEmpty, !matchesSearch(photo, query: search) { continue }
            ids.append(photo.id)
            items.append([
                "id": photo.id.uuidString,
                "name": photo.originalName,
                "date": Self.aiDateFormatter.string(from: photo.capturedAt),
                "is_video": photo.isVideo,
                "is_favorite": photo.isFavorite,
                "keywords": (photo.keywords ?? []).prefix(8).joined(separator: " ")
            ])
            if items.count >= limit { break }
        }
        return success(["count": items.count, "photos": items],
                       summary: nil,
                       photoIDs: ids)
    }

    private func listAlbumsTool() -> AIToolExecution {
        let items = albums.map { album -> [String: Any] in
            ["id": album.id.uuidString, "name": album.name, "count": album.photoIDs.count]
        }
        return success(["count": items.count, "albums": items], summary: nil, photoIDs: [])
    }

    private func createAlbumsTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isNativeContainer else {
            return failure("当前图库是官方「照片」图库，不能新建相簿")
        }
        guard !isSystemScope, !isCloudScope else {
            return failure("当前范围是只读来源，请先切换到拾光图库")
        }
        let specs = args["albums"] as? [[String: Any]] ?? []
        guard !specs.isEmpty else { return failure("没有提供要创建的相簿") }

        var created: [[String: Any]] = []
        var summaries: [String] = []
        for spec in specs {
            let name = (spec["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let ids = localPhotoIDs(AILibraryTools.stringArray(spec["photo_ids"]))
            if let index = albums.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let existing = Set(albums[index].photoIDs)
                let additions = ids.subtracting(existing)
                let ordered = photos.map(\.id).filter { additions.contains($0) }
                albums[index].photoIDs.append(contentsOf: ordered)
                created.append(["name": albums[index].name, "added": ordered.count, "existing": true])
                summaries.append("更新相簿「\(albums[index].name)」+\(ordered.count) 张")
            } else {
                var album = Album(name: name)
                album.photoIDs = photos.map(\.id).filter { ids.contains($0) }
                albums.append(album)
                created.append(["name": name, "added": album.photoIDs.count, "existing": false])
                summaries.append("创建相簿「\(name)」\(album.photoIDs.count) 张")
            }
        }
        guard !created.isEmpty else { return failure("没有有效的相簿名称") }
        save()
        showToast("智能助手已更新 \(created.count) 个相簿")
        return success(["albums": created], summary: summaries.joined(separator: " · "), photoIDs: [])
    }

    private func addToAlbumTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isSystemScope, !isCloudScope else {
            return failure("当前范围是只读来源，请先切换到拾光图库")
        }
        var albumIndex: Int?
        if let rawID = args["album_id"] as? String, let id = UUID(uuidString: rawID) {
            albumIndex = albums.firstIndex(where: { $0.id == id })
        }
        if albumIndex == nil, let name = args["album_name"] as? String {
            albumIndex = albums.firstIndex {
                $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
        }
        guard let index = albumIndex else { return failure("没有找到对应相簿，可先调用 list_albums") }

        let ids = localPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !ids.isEmpty else { return failure("没有找到可加入的有效照片") }
        let before = Set(albums[index].photoIDs)
        addToAlbum(albums[index].id, photoIDs: ids)
        let after = Set(albums[index].photoIDs)
        let added = after.subtracting(before).count
        return success(["album": albums[index].name, "added": added],
                       summary: "加入相簿「\(albums[index].name)」\(added) 张",
                       photoIDs: [])
    }

    private func setFavoriteTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isSystemScope || canEditNativeOverlay else {
            return failure("当前是只读系统图库，不能修改收藏")
        }
        let favorite = AILibraryTools.bool(args["favorite"], fallback: true)
        let rawIDs = resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !rawIDs.isEmpty else { return failure("没有提供可识别的照片 id") }

        var touched = 0
        let localIDs = localPhotoIDs(rawIDs.map(\.uuidString))
        if !localIDs.isEmpty {
            var changed = false
            for index in photos.indices where localIDs.contains(photos[index].id) {
                if photos[index].isFavorite != favorite {
                    photos[index].isFavorite = favorite
                    changed = true
                }
            }
            if changed { save() }
            touched += localIDs.count
        }

        if canEditNativeOverlay {
            let systemIDs = Set(rawIDs.filter { systemPhotoIndex[$0] != nil })
            if !systemIDs.isEmpty {
                setSystemFavorite(favorite, ids: systemIDs)
                touched += systemIDs.count
            }
        }

        let cloudIDs = Set(rawIDs.filter { anyPhoto(id: $0)?.isCloud == true })
        if !cloudIDs.isEmpty {
            setCloudFavorite(favorite, for: cloudIDs)
            touched += cloudIDs.count
        }

        guard touched > 0 else { return failure("没有找到可修改的照片") }
        return success(["favorite": favorite, "count": touched],
                       summary: "\(favorite ? "收藏" : "取消收藏") \(touched) 张",
                       photoIDs: [])
    }

    private func addKeywordsTool(_ args: [String: Any]) -> AIToolExecution {
        guard !isSystemScope || canEditNativeOverlay else {
            return failure("当前是只读系统图库，不能修改关键词")
        }
        let keywords = AILibraryTools.stringArray(args["keywords"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return failure("没有提供关键词") }
        let rawIDs = resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
        guard !rawIDs.isEmpty else { return failure("没有提供可识别的照片 id") }

        var touchedIDs: Set<UUID> = []
        let localIDs = localPhotoIDs(rawIDs.map(\.uuidString))
        if !localIDs.isEmpty {
            var changed = false
            for index in photos.indices where localIDs.contains(photos[index].id) {
                var list = photos[index].keywords ?? []
                var added = false
                for keyword in keywords where !list.contains(keyword) {
                    list.append(keyword)
                    added = true
                }
                if added {
                    photos[index].keywords = list
                    changed = true
                    touchedIDs.insert(photos[index].id)
                }
            }
            if changed { save() }
        }

        if canEditNativeOverlay {
            for id in rawIDs where systemPhotoIndex[id] != nil {
                var list = systemPhotoIndex[id]?.keywords ?? []
                var added = false
                for keyword in keywords where !list.contains(keyword) {
                    list.append(keyword)
                    added = true
                }
                guard added else { continue }
                setSystemKeywords(list, ids: [id])
                touchedIDs.insert(id)
            }
        }

        guard !touchedIDs.isEmpty else { return failure("这些照片已经包含该关键词") }
        return success(["keywords": keywords, "count": touchedIDs.count],
                       summary: "为 \(touchedIDs.count) 张添加关键词：\(keywords.joined(separator: "、"))",
                       photoIDs: [])
    }

    private func selectPhotosTool(_ args: [String: Any]) -> AIToolExecution {
        let ids = resolveAIPhotoIDs(AILibraryTools.stringArray(args["photo_ids"]))
            .filter { anyPhoto(id: $0) != nil }
        guard !ids.isEmpty else { return failure("没有找到可选中的照片") }
        selection = Set(ids)
        selectionAnchorID = ids.first
        return success(["count": ids.count],
                       summary: "选中 \(ids.count) 张照片",
                       photoIDs: ids)
    }

    // MARK: - 辅助

    /// 只接受当前本地图库中存在且未删除的照片 id。
    private func localPhotoIDs(_ raw: [String]) -> Set<UUID> {
        let ids = Set(resolveAIPhotoIDs(raw))
        guard !ids.isEmpty else { return [] }
        let live = Set(photos.lazy.filter { $0.deletedAt == nil }.map(\.id))
        return ids.intersection(live)
    }

    /// 兼容模型常见的三种引用方式：UUID、候选编号（#3）与唯一文件名。
    private func resolveAIPhotoIDs(_ raw: [String]) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = []
        var nameMap: [String: [UUID]]?

        func append(_ id: UUID) {
            guard seen.insert(id).inserted else { return }
            result.append(id)
        }

        for value in raw {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let id = UUID(uuidString: text) {
                append(id)
                continue
            }

            let indexText = text.hasPrefix("#") ? String(text.dropFirst()) : text
            if let index = Int(indexText), index >= 1, index <= aiLastCandidateIDs.count {
                append(aiLastCandidateIDs[index - 1])
                continue
            }

            if let id = aiLastCandidateNames[text.lowercased()] {
                append(id)
                continue
            }

            if nameMap == nil {
                var map: [String: [UUID]] = [:]
                for list in [photos, systemPhotos, cloudPhotos] {
                    for photo in list {
                        map[photo.originalName.lowercased(), default: []].append(photo.id)
                        map[photo.filename.lowercased(), default: []].append(photo.id)
                        map[photo.displayTitle.lowercased(), default: []].append(photo.id)
                    }
                }
                nameMap = map
            }
            if let matches = nameMap?[text.lowercased()], matches.count == 1 {
                append(matches[0])
            }
        }
        return result
    }

    private func success(_ payload: [String: Any],
                         summary: String?,
                         photoIDs: [UUID]) -> AIToolExecution {
        var body = payload
        body["ok"] = true
        return AIToolExecution(json: Self.aiJSONString(body) ?? "{\"ok\":true}",
                               summary: summary,
                               photoIDs: photoIDs)
    }

    private func failure(_ message: String) -> AIToolExecution {
        AIToolExecution(json: Self.aiJSONString(["ok": false, "error": message]) ?? "{\"ok\":false}",
                        summary: nil,
                        photoIDs: [])
    }

    private static func aiJSONString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static let aiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
