import Foundation

/// 把第二批 / 第三批一次性 AI 能力接进助手工具。
/// 分享文案只读；电视清洗与智能相簿是写操作，由审批设置统一决定是否放行。
extension LibraryStore {
    // MARK: - generate_share_copy

    func generateShareCopyTool(_ args: [String: Any]) async -> AIToolExecution {
        let ids = Set(localPhotoIDs(AILibraryTools.stringArray(args["photo_ids"])))
        guard !ids.isEmpty else {
            return failure("没有找到可用的照片；先用 select_photos 选中再调用")
        }
        await generateShareCopy(for: ids, presentSheet: false)
        let center = AIAssistCenter.shared
        if let error = center.shareError { return failure(error) }
        guard !center.shareCopy.isEmpty else { return failure("没有生成可用文案") }
        return success(["copies": center.shareCopy],
                       summary: "已生成 \(center.shareCopy.count) 条分享文案",
                       photoIDs: Array(ids))
    }

    // MARK: - cleanup_tv_channels

    func cleanupTVChannelsTool(_ args: [String: Any]) async -> AIToolExecution {
        let tv = tvModel
        var playlistIDs: [UUID] = []
        if let raw = AILibraryTools.string(args["source"]), !raw.isEmpty {
            if let id = UUID(uuidString: raw) {
                playlistIDs = [id]
            } else if let match = tv.playlists.first(where: {
                $0.name.localizedCaseInsensitiveContains(raw)
            }) {
                playlistIDs = [match.id]
            } else {
                return failure("没有找到电视源「\(raw)」")
            }
        }
        if playlistIDs.isEmpty {
            if let id = tv.focusedPlaylistID {
                playlistIDs = [id]
            } else if let id = tv.channelSourceFilterID {
                playlistIDs = [id]
            } else {
                playlistIDs = tv.playlists.filter(\.isEnabled).map(\.id)
            }
        }
        guard !playlistIDs.isEmpty else { return failure("还没有接入电视源") }

        await aiCleanupTVChannels(tv, playlistIDs: playlistIDs)
        let center = AIAssistCenter.shared
        guard !center.channelCleanupLoading else {
            return failure("正在清洗频道，等这一轮结束再调用")
        }
        let status = center.channelCleanupStatus ?? "已清洗"
        return success(["summary": status], summary: status, photoIDs: [])
    }

    // MARK: - make_smart_album

    func makeSmartAlbumTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let description = AILibraryTools.string(args["description"]),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure("缺少 description")
        }
        guard aiAssistAvailability.isReady else {
            return failure(aiAssistAvailability.hint ?? "AI 不可用")
        }
        let sceneTitles = SceneCatalog.categories.map(\.title).joined(separator: "、")
        do {
            let text = try await AIAssistCenter.shared.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是智能相簿规则生成器。把用户的一句话翻译成规则。
                可用 field 与 value：
                mediaType（照片 / 视频 / 截屏 / 全景 / 自拍）、favorite（是 / 否）、edited（是 / 否）、
                hasLocation（是 / 否）、hasText（是 / 否）、keyword、camera、lens、place、filename、ocrText、
                capturedAfter（yyyy-MM-dd）、capturedBefore（yyyy-MM-dd）、
                minMegapixels、minFileSizeMB、minDuration（数字）、scene（只能从：\(sceneTitles)）。
                条件之间默认全部满足；确实需要「或」时 match_all 设为 false。
                只输出一行 JSON：{"name":"相簿名","match_all":true,"rules":[{"field":"scene","value":"海边"}]}。
                """,
                user: description,
                maxTokens: 420,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let rawRules = object["rules"] as? [[String: Any]] else {
                throw AIError.badResponse
            }
            let rules = Self.validSmartRules(rawRules)
            guard !rules.isEmpty else {
                return failure("没能从这句话里解析出可用的筛选项，换一种说法再试")
            }
            let name = (AILibraryTools.string(args["name"])
                        ?? object["name"] as? String
                        ?? "AI 智能相簿")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let album = SmartAlbum(name: name.isEmpty ? "AI 智能相簿" : String(name.prefix(24)),
                                   matchAll: object["match_all"] as? Bool ?? true,
                                   rules: rules)
            let matched = photos.filter {
                album.matches($0, analysis: analysisIndex[$0.id])
            }.count
            saveSmartAlbum(album)
            return success(["name": album.name, "matched": matched, "summary": album.summary],
                           summary: "已创建智能相簿「\(album.name)」，命中 \(matched) 项",
                           photoIDs: [])
        } catch {
            return failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// 模型给的字段必须能落到 SmartRule 上；非法规则直接丢弃，避免相簿「看起来有规则但永远不命中」。
    private static func validSmartRules(_ raw: [[String: Any]]) -> [SmartRule] {
        var rules: [SmartRule] = []
        for item in raw {
            guard let fieldRaw = item["field"] as? String,
                  let field = SmartAlbumField(rawValue: fieldRaw),
                  let rawValue = item["value"] as? String else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.valueKind {
            case .choice(let options):
                guard options.contains(value) else { continue }
            case .toggle:
                guard value == "是" || value == "否" else { continue }
            case .date:
                guard SmartAlbumDate.date(from: value) != nil else { continue }
            case .number:
                guard Double(value) != nil else { continue }
            case .text:
                guard !value.isEmpty else { continue }
            }
            rules.append(SmartRule(field: field, value: value))
        }
        return rules
    }
}
