import Foundation

/// 指认：用 @ 明确指定「就是这张 / 这一段」，不靠模型猜。
extension LibraryStore {
    var aiMentionedPhotos: [PhotoItem] {
        aiMentionedPhotoIDs.compactMap { anyPhoto(id: $0) }
    }

    /// 输入 @ 时的候选：选中优先，其次是当前可见范围。
    func aiMentionCandidates(_ query: String, limit: Int = 6) -> [PhotoItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<UUID>()
        var result: [PhotoItem] = []

        func consider(_ photo: PhotoItem) {
            guard result.count < limit, seen.insert(photo.id).inserted else { return }
            guard keyword.isEmpty
                    || photo.originalName.lowercased().contains(keyword)
                    || photo.filename.lowercased().contains(keyword) else { return }
            result.append(photo)
        }

        if selection.isEmpty {
            for photo in visiblePhotos.prefix(60) { consider(photo) }
        } else {
            for id in selection {
                if let photo = anyPhoto(id: id) { consider(photo) }
            }
            for photo in visiblePhotos.prefix(60) { consider(photo) }
        }
        return result
    }

    func pinAIMention(_ photo: PhotoItem) {
        if !aiMentionedPhotoIDs.contains(photo.id) {
            aiMentionedPhotoIDs.append(photo.id)
        }
        refreshAIContextCapsules()
    }

    func unpinAIMention(_ id: UUID) {
        aiMentionedPhotoIDs.removeAll { $0 == id }
        refreshAIContextCapsules()
    }

    func pinAIMentionTimecode(_ seconds: Double) {
        aiMentionedTimecode = max(0, seconds)
        refreshAIContextCapsules()
    }

    func unpinAIMentionTimecode() {
        aiMentionedTimecode = nil
        refreshAIContextCapsules()
    }

    func clearAIMentions() {
        aiMentionedPhotoIDs = []
        aiMentionedTimecode = nil
        refreshAIContextCapsules()
    }

    /// 当前视频播放位置；不在看视频时为 nil。
    var aiViewerTimecode: Double? {
        guard let photo = viewerPhoto, photo.isVideo else { return nil }
        let time = viewerModel.videoPlayer.currentTime
        return time > 0 ? time : nil
    }

    var aiViewerTimecodeLabel: String? {
        aiViewerTimecode.map { Self.aiTimecodeText($0) }
    }

    /// 从输入文本里补捞 @文件名 与 @mm:ss：手动输入也能指认。
    func pinMentionsFromText(_ text: String) {
        if let seconds = Self.parseAITimecode(text), viewerPhoto?.isVideo == true,
           aiMentionedTimecode == nil {
            aiMentionedTimecode = seconds
        }
        guard aiMentionedPhotoIDs.count < 8 else { return }
        var seen = Set(aiMentionedPhotoIDs)
        let tokens = Self.mentionTokens(in: text)
        guard !tokens.isEmpty else { return }
        var pool: [PhotoItem] = []
        for id in selection {
            if let photo = anyPhoto(id: id) { pool.append(photo) }
        }
        pool.append(contentsOf: visiblePhotos.prefix(120))
        for photo in pool {
            guard seen.insert(photo.id).inserted else { continue }
            let name = photo.originalName.lowercased()
            let filename = photo.filename.lowercased()
            if tokens.contains(where: { token in
                let value = token.lowercased()
                return value.count >= 2 && (name.hasPrefix(value) || filename.hasPrefix(value))
            }) {
                aiMentionedPhotoIDs.append(photo.id)
                if aiMentionedPhotoIDs.count >= 8 { break }
            }
        }
        refreshAIContextCapsules()
    }

    /// 组装进提示词的指认段落；胶囊被关掉时整段不出现。
    func aiMentionPrompt() -> String {
        guard isAIContextEnabled(.mention) else { return "" }
        var blocks: [String] = []
        let photos = aiMentionedPhotos.prefix(8)
        if !photos.isEmpty {
            let lines = photos.map { photo in
                "- @\(photo.originalName)（\(photo.isVideo ? "视频" : "照片")）"
            }
            blocks.append("【用户指认】以下对象由用户用 @ 明确指定，回答与操作优先引用它们：\n"
                          + lines.joined(separator: "\n"))
        }
        if let timecode = aiMentionedTimecode {
            blocks.append("【指认时间点】当前视频 \(Self.aiTimecodeText(timecode))；"
                          + "问题里的「这里 / 这段 / 这个画面」都以该时间点为准。")
        }
        return blocks.joined(separator: "\n")
    }

    // MARK: - 解析

    static func aiTimecodeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func parseAITimecode(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "@(\\d{1,3}):([0-5]\\d)") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let minuteRange = Range(match.range(at: 1), in: text),
              let secondRange = Range(match.range(at: 2), in: text),
              let minutes = Int(text[minuteRange]),
              let seconds = Int(text[secondRange]) else { return nil }
        return Double(minutes * 60 + seconds)
    }

    private static func mentionTokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "@" || $0.isWhitespace })
            .map { token in
                String(token.prefix { !"@，。,.!?！？、；;：:".contains($0) })
            }
            .filter { !$0.isEmpty && $0.count <= 40 && !$0.allSatisfy(\.isNumber) }
    }
}
