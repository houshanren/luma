import Foundation

/// 一条可撤销的 AI 操作：执行前记录，执行后可回滚。
/// 只保存在内存里：撤销是「本次会话」的保险，不写进图库数据库。
@MainActor
struct AIUndoEntry {
    let id = UUID()
    let taskID: UUID
    let title: String
    let detail: String
    let createdAt = Date()
    let revert: @MainActor () -> String
}

/// 本地照片的可回滚字段快照。系统图库与网盘项目不在这里恢复。
private struct AIPhotoSnapshot {
    let id: UUID
    let isFavorite: Bool
    let isHidden: Bool
    let rating: Int?
    let flag: PhotoFlag?
    let colorLabel: PhotoColorLabel?
    let title: String?
    let keywords: [String]?
}

extension LibraryStore {
    /// 相簿 / 文件夹写操作：整组快照，撤销时整体还原。
    private static let aiAlbumWriteNames: Set<String> = [
        "create_albums", "add_photos_to_album", "remove_photos_from_album",
        "rename_album", "delete_album", "move_album", "set_album_cover",
        "create_folder", "rename_folder", "delete_folder"
    ]

    /// 照片字段写操作：按 photo_ids 记录修改前的字段。
    private static let aiPhotoFieldWriteNames: Set<String> = [
        "set_favorite", "set_hidden", "set_rating", "set_flag", "set_color_label",
        "add_keywords", "remove_keywords", "set_title"
    ]

    /// 影院写操作：按「任务 + 作用域」做一次整组快照，撤销时还原索引、状态与清单。
    private static let aiCinemaWriteNames: Set<String> = [
        "scrape_cinema", "match_cinema", "apply_cinema_match", "refresh_cinema_metadata",
        "update_cinema_state", "manage_cinema_list", "ignore_cinema",
        "restore_cinema_ignored", "set_cinema_intro_skip", "manage_cinema_progress"
    ]

    /// 执行写工具前建立检查点；返回 nil 表示这类操作暂不支持撤销。
    func makeAIUndoEntry(for call: AIToolCall, args: [String: Any]) -> AIUndoEntry? {
        let taskID = aiCurrentTaskID ?? UUID()
        let title = AILibraryTools.describe(call)

        if Self.aiCinemaWriteNames.contains(call.name) {
            let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) ?? cinemaActiveScope
            let key = taskID.uuidString + "-" + String(describing: scope)
            guard !aiCinemaUndoKeys.contains(key) else { return nil }
            aiCinemaUndoKeys.insert(key)
            let entriesBefore = cinemaIndexes[scope]
            let ignoredBefore = cinemaIgnoredIDs[scope]
            let userStatesBefore = cinemaUserStates
            let progressBefore = cinemaProgress
            let listsBefore = cinemaLists
            let introBefore = cinemaIntroMarks
            return AIUndoEntry(taskID: taskID,
                               title: "影院：\(cinemaScopeName(scope))",
                               detail: "还原影院索引、观看状态与自定义清单",
                               revert: { [weak self] in
                guard let self else { return "图库已关闭" }
                self.cinemaIndexes[scope] = entriesBefore
                if let ignoredBefore {
                    self.cinemaIgnoredIDs[scope] = ignoredBefore
                } else {
                    self.cinemaIgnoredIDs.removeValue(forKey: scope)
                }
                self.cinemaUserStates = userStatesBefore
                self.cinemaProgress = progressBefore
                self.cinemaLists = listsBefore
                self.cinemaIntroMarks = introBefore
                self.persistCinemaIndex(for: scope)
                self.persistCinemaIgnored(for: scope)
                self.persistCinemaUserState()
                self.persistCinemaProgress()
                self.persistCinemaLists()
                self.persistCinemaIntroMarks()
                return "已还原影院「\(cinemaScopeName(scope))」"
            })
        }

        if Self.aiAlbumWriteNames.contains(call.name) {
            let albumsBefore = albums
            let foldersBefore = folders
            return AIUndoEntry(taskID: taskID,
                               title: title,
                               detail: "还原相簿与文件夹结构",
                               revert: { [weak self] in
                guard let self else { return "图库已关闭" }
                self.albums = albumsBefore
                self.folders = foldersBefore
                self.save()
                return "已还原相簿与文件夹"
            })
        }

        if Self.aiPhotoFieldWriteNames.contains(call.name) {
            let snapshots = aiPhotoSnapshots(from: args)
            guard !snapshots.isEmpty else { return nil }
            return AIUndoEntry(taskID: taskID,
                               title: title,
                               detail: "还原 \(snapshots.count) 项的原始字段",
                               revert: { [weak self] in
                guard let self else { return "图库已关闭" }
                return self.restoreAIPhotoSnapshots(snapshots)
            })
        }

        if call.name == "trash_photos" {
            let ids = Set(localPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
            guard !ids.isEmpty else { return nil }
            return AIUndoEntry(taskID: taskID,
                               title: title,
                               detail: "从最近删除恢复 \(ids.count) 项",
                               revert: { [weak self] in
                guard let self else { return "图库已关闭" }
                self.restore(ids)
                return "已恢复 \(ids.count) 项"
            })
        }

        if call.name == "restore_photos" {
            let ids = Set(localPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
            guard !ids.isEmpty else { return nil }
            return AIUndoEntry(taskID: taskID,
                               title: title,
                               detail: "重新移入最近删除 \(ids.count) 项",
                               revert: { [weak self] in
                guard let self else { return "图库已关闭" }
                self.delete(ids)
                return "已重新移入最近删除 \(ids.count) 项"
            })
        }

        return nil
    }

    /// 当前任务是否有可撤销的操作。
    func canUndoAITask(_ taskID: UUID?) -> Bool {
        _ = aiUndoRevision
        guard let taskID else { return false }
        return aiUndoLog.contains { $0.taskID == taskID }
    }

    /// 撤销某个 AI 任务的全部可逆操作（倒序执行）。
    @discardableResult
    func undoAITask(_ taskID: UUID?) -> Bool {
        guard let taskID else { return false }
        let entries = aiUndoLog.filter { $0.taskID == taskID }
        guard !entries.isEmpty else { return false }
        var messages: [String] = []
        for entry in entries.reversed() {
            messages.append(entry.revert())
        }
        aiUndoLog.removeAll { $0.taskID == taskID }
        aiCinemaUndoKeys = aiCinemaUndoKeys.filter { !$0.hasPrefix(taskID.uuidString + "-") }
        aiUndoRevision &+= 1
        noteAIUndo(taskID: taskID, entries: entries.count)
        showToast(messages.last ?? "已撤销本次修改")
        return true
    }

    /// 撤销最近一次可逆操作。
    @discardableResult
    func undoLastAIOperation() -> Bool {
        guard let last = aiUndoLog.last else {
            showToast("没有可撤销的 AI 操作")
            return false
        }
        let message = last.revert()
        aiCinemaUndoKeys = aiCinemaUndoKeys.filter { !$0.hasPrefix(last.taskID.uuidString + "-") }
        aiUndoLog.removeLast()
        aiUndoRevision &+= 1
        noteAIUndo(taskID: last.taskID, entries: 1)
        showToast(message)
        return true
    }

    // MARK: - 快照

    private func aiPhotoSnapshots(from args: [String: Any]) -> [AIPhotoSnapshot] {
        let raw = AILibraryTools.stringArray(args["photo_ids"])
        let ids = Set(raw.compactMap { UUID(uuidString: $0) })
        guard !ids.isEmpty else { return [] }
        return photos.compactMap { photo in
            guard ids.contains(photo.id) else { return nil }
            return AIPhotoSnapshot(id: photo.id,
                                   isFavorite: photo.isFavorite,
                                   isHidden: photo.isHidden,
                                   rating: photo.rating,
                                   flag: photo.flag,
                                   colorLabel: photo.colorLabel,
                                   title: photo.title,
                                   keywords: photo.keywords)
        }
    }

    private func restoreAIPhotoSnapshots(_ snapshots: [AIPhotoSnapshot]) -> String {
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        var changed = 0
        for index in photos.indices {
            guard let snapshot = byID[photos[index].id] else { continue }
            photos[index].isFavorite = snapshot.isFavorite
            photos[index].isHidden = snapshot.isHidden
            photos[index].rating = snapshot.rating
            photos[index].flag = snapshot.flag
            photos[index].colorLabel = snapshot.colorLabel
            photos[index].title = snapshot.title
            photos[index].keywords = snapshot.keywords
            changed += 1
        }
        guard changed > 0 else { return "没有可还原的本地照片" }
        save()
        return "已还原 \(changed) 项的原始字段"
    }
}
