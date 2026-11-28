import Foundation
import LumaContentCore
import LumaDomain

/// 第二批一次性 AI 辅助的图库侧实现：
/// - 分享文案：按选中照片的场景标签写朋友圈 / 小红书文案；
/// - 关键词与标题补全：给出中文标题与关键词，确认后批量写回；
/// - 搜索框自然语言改写：把口语转成 App 支持的检索词；
/// - 电视 M3U 频道清洗：规范化台名并把频道归进固定分组；
/// - 离线帮助问答：以内置帮助资料为唯一事实来源；
/// - 诊断日志摘要：把日志尾部压成「问题 / 原因 / 建议」。
///
/// 与体检解读等一致：只由按钮触发、只发文本、串行执行、失败保留原结果。
extension LibraryStore {
    // MARK: - 分享文案

    /// 把选中的照片整理成文案素材：只发数量、日期、城市与端侧标签，不发照片与 OCR。
    func generateShareCopy(for ids: Set<UUID>, presentSheet: Bool = true) async {
        let targets = photos
            .filter { ids.contains($0.id) && $0.deletedAt == nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard !targets.isEmpty else {
            showToast("先选择要写文案的照片")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginShare() else { return }
        if presentSheet { center.showShareSheet = true }
        center.rememberShareSources(Set(targets.map(\.id)))
        // 模型没配置 / 服务没起时不让入口空转：按标签直接拼一套模板文案。
        guard aiAssistAvailability.isReady else {
            center.finishShare(.success(templateShareCopy(for: targets)))
            showToast("AI 不可用，已按标签生成模板文案")
            return
        }

        let facts = """
        数量：\(targets.count) 张
        时间：\(shareDateRange(targets))
        地点：\(aiPlaceSummary(targets))
        场景标签：\(aiSceneSummary(targets))
        已有标题/关键词：\(shareExistingTags(targets))
        """
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是社交媒体文案作者。根据给定素材写 3 条中文分享文案，分别对应三种语气：
                1) 朋友圈：轻松口语，可带 1 个 emoji；
                2) 小红书：有标题感的短句 + 简短正文；
                3) 极简：一句不超过 20 字。
                每条不超过 60 字，不要列表符号、不要解释、不要编造素材里没有的地点或事件。
                只输出一行 JSON：{"copies":["第一条","第二条","第三条"]}。
                """,
                user: facts,
                maxTokens: 520,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let raw = object["copies"] as? [String] else {
                throw AIError.badResponse
            }
            let copies = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(3)
            guard !copies.isEmpty else { throw AIError.badResponse }
            center.finishShare(.success(Array(copies)))
            Diagnostics.record("AI 辅助：生成分享文案", level: .standard)
        } catch {
            // 模型出错也不让用户白点：退回标签拼接模板。
            center.finishShare(.success(templateShareCopy(for: targets)))
            showToast("AI 生成失败，已按标签生成模板文案")
        }
    }

    /// 没有模型时的兜底文案：只用日期、城市与场景标签拼三句，不假装是模型写的。
    private func templateShareCopy(for photos: [PhotoItem]) -> [String] {
        let date = shareDateRange(photos)
        let place = aiPlaceSummary(photos)
        let scenes = aiSceneSummary(photos, limit: 4)
        let placeText = place == "未知" ? "" : place
        let sceneText = scenes == "无" ? "" : scenes
        let heading = [placeText, date].filter { !$0.isEmpty }.joined(separator: " · ")
        let body = [heading, sceneText].filter { !$0.isEmpty }.joined(separator: "\n")
        let minimal = heading.isEmpty ? "留住这一刻。" : heading
        return [body, "\(sceneText.isEmpty ? "今天的记录" : sceneText)\n\(heading)", minimal]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func shareDateRange(_ photos: [PhotoItem]) -> String {
        guard let first = photos.first?.capturedAt,
              let last = photos.last?.capturedAt else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return formatter.string(from: first)
        }
        return "\(formatter.string(from: first)) 至 \(formatter.string(from: last))"
    }

    private func shareExistingTags(_ photos: [PhotoItem]) -> String {
        var names: [String] = []
        for photo in photos {
            if let title = photo.title, !title.isEmpty { names.append(title) }
            names.append(contentsOf: (photo.keywords ?? []).prefix(3))
        }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }.prefix(8)
        return unique.isEmpty ? "无" : unique.joined(separator: "、")
    }

    // MARK: - 关键词 / 标题补全

    func generateAIKeywordSuggestions(for ids: Set<UUID>) async {
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘为只读，不能补全关键词")
            return
        }
        let targets = Array(photos
            .filter { ids.contains($0.id) && $0.deletedAt == nil }
            .sorted { $0.capturedAt < $1.capturedAt }
            .prefix(6))
        guard !targets.isEmpty else {
            showToast("先选择要补全的照片")
            return
        }
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginKeywordSuggestions() else { return }
        center.showKeywordSheet = true

        let lines = targets.enumerated().map { index, photo -> String in
            let analysis = analysisIndex[photo.id]
            let labels = (analysis?.labels ?? []).prefix(8).joined(separator: "、")
            let ocr = String((analysis?.text ?? "").prefix(40))
            return """
            \(index + 1). 文件名=\(photo.displayFilename)｜日期=\(Self.keywordDate(photo.capturedAt))｜\
            地点=\([photo.placeCity, photo.placePOI].compactMap { $0 }.joined(separator: " "))｜\
            标签=\(labels.isEmpty ? "无" : labels)｜OCR=\(ocr.isEmpty ? "无" : ocr)｜\
            现有标题=\(photo.title ?? "无")
            """
        }
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是照片整理助手。为每张照片给出 1 个中文标题（不超过 12 字，写具体场景，不要「照片1」这类空话）
                和 3 到 6 个中文关键词（名词为主：地点、人物、活动、物件、氛围）。
                不要重复现有标题与关键词，不要编造看不清的内容。
                只输出一行 JSON：{"items":[{"index":1,"title":"...","keywords":["..."]}]}。
                """,
                user: lines.joined(separator: "\n"),
                maxTokens: 700,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let items = object["items"] as? [[String: Any]] else {
                throw AIError.badResponse
            }
            var suggestions: [AIAssistCenter.KeywordSuggestion] = []
            for item in items {
                guard let index = item["index"] as? Int,
                      index >= 1, index <= targets.count else { continue }
                let photo = targets[index - 1]
                let title = (item["title"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let keywords = (item["keywords"] as? [String] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count <= 10 }
                    .prefix(6)
                guard !title.isEmpty || !keywords.isEmpty else { continue }
                suggestions.append(AIAssistCenter.KeywordSuggestion(
                    id: photo.id,
                    title: String(title.prefix(16)),
                    keywords: Array(keywords)
                ))
            }
            guard !suggestions.isEmpty else { throw AIError.badResponse }
            center.finishKeywordSuggestions(.success(suggestions))
            Diagnostics.record("AI 辅助：生成关键词建议 \(suggestions.count) 张", level: .standard)
        } catch {
            center.finishKeywordSuggestions(.failure(error))
        }
    }

    private static func keywordDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// 用户确认后一次性写回：标题与关键词同批落盘，只记一次撤销。
    func applyAIKeywordSuggestions(_ suggestions: [AIAssistCenter.KeywordSuggestion]) {
        guard !suggestions.isEmpty else { return }
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘为只读，不能写入关键词")
            return
        }
        let ids = Set(suggestions.map(\.id))
        let beforePhotos = photoSnapshot(ids)
        var renamed = 0
        var keywordAdded = 0
        for index in photos.indices where ids.contains(photos[index].id) {
            guard let suggestion = suggestions.first(where: { $0.id == photos[index].id }) else { continue }
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, photos[index].title != title {
                photos[index].title = title
                renamed += 1
            }
            var list = photos[index].keywords ?? []
            var changed = false
            for keyword in suggestion.keywords where !list.contains(keyword) {
                list.append(keyword)
                keywordAdded += 1
                changed = true
            }
            if changed { photos[index].keywords = list }
        }
        guard renamed > 0 || keywordAdded > 0 else {
            showToast("这些建议已经在图库里了")
            return
        }
        save()
        recordUndo("AI 补全关键词与标题", beforePhotos: beforePhotos)
        AIAssistCenter.shared.clearKeywordSuggestions()
        showToast("已写入 \(renamed) 个标题、\(keywordAdded) 个关键词")
    }

    // MARK: - 搜索框自然语言 → 过滤器

    /// 把口语化的一整句改写成 App 已经支持的检索词（时间词 / 类型词 / 收藏 / 名词）。
    func aiRewriteSearchText() async {
        let raw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // 模型不可用时退回纯规则：去掉口语虚词后仍是可用的检索词，不会让按钮空转。
        guard aiAssistAvailability.isReady else {
            applyRuleSearchRewrite(raw, notice: "AI 不可用，已按规则简化检索词")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginSearchRewrite() else { return }
        defer { center.finishSearchRewrite() }
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是搜索词改写器。把用户的口语改写成符合本 App 检索语法的空格分隔检索词。
                可用的时间词：今天、昨天、前天、本周、上周、本月、上个月、今年、去年、前年、2024年、2024年5月、5月20日。
                可用的类型词：照片、视频、截图、实况、已编辑。可用的状态词：收藏。
                其余内容保留为最有区分度的名词（地点、人物、事物、颜色），去掉「帮我找」「所有的」这类虚词。
                不要输出检索词之外的任何文字。
                只输出一行 JSON：{"search":"改写后的检索词"}。
                """,
                user: "原句：\(raw)",
                maxTokens: 160,
                preferLightweight: true
            )
            guard let object = AIAssistCenter.jsonObject(from: text),
                  let rewritten = (object["search"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rewritten.isEmpty else {
                throw AIError.badResponse
            }
            searchText = String(rewritten.prefix(80))
            showToast("已改写为：\(searchText)")
        } catch {
            applyRuleSearchRewrite(raw, notice: "AI 改写失败，已按规则简化检索词")
        }
    }

    /// 规则兜底：只删口语虚词与标点，时间词 / 类型词原样保留，交给现有解析器。
    private func applyRuleSearchRewrite(_ raw: String, notice: String) {
        let fillers = ["帮我找一下", "帮我找", "帮我", "请问", "请", "我想找", "我要找",
                       "想看", "看看", "找找", "一下", "一些", "那些", "所有", "全部"]
        var text = raw
        for filler in fillers {
            text = text.replacingOccurrences(of: filler, with: " ")
        }
        text = text.replacingOccurrences(
            of: "[，。！？、,.!?\\n]+",
            with: " ",
            options: .regularExpression
        )
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let rewritten = tokens.joined(separator: " ")
        guard !rewritten.isEmpty else { return }
        searchText = String(rewritten.prefix(80))
        showToast("\(notice)：\(searchText)")
    }

    // MARK: - 电视 M3U 频道清洗与归类

    /// 只改台名与分组，不动流地址、台标与回看信息；每批 50 个，最多 8 批。
    func aiCleanupTVChannels(_ tv: IPTVBrowserModel, playlistIDs: [UUID]) async {
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        guard !tv.isLoading else {
            showToast("正在刷新电视源，等这一轮结束再试")
            return
        }
        let targets = playlistIDs.filter { id in
            !(tv.channelCache[id] ?? []).isEmpty
        }
        guard !targets.isEmpty else {
            showToast("当前源还没有频道可清洗")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginChannelCleanup() else { return }

        let batchSize = 50
        let maxBatches = 8
        var renamedTotal = 0
        var regroupedTotal = 0
        var truncated = false

        for playlistID in targets {
            let name = tv.playlists.first { $0.id == playlistID }?.name ?? "电视源"
            let original = tv.channelCache[playlistID]
                ?? tv.channels.filter { $0.playlistID == playlistID }
            guard !original.isEmpty else { continue }
            var updated = original
            let batches = stride(from: 0, to: original.count, by: batchSize).map {
                Array(original[$0..<min($0 + batchSize, original.count)])
            }
            if batches.count > maxBatches { truncated = true }

            for (batchIndex, batch) in batches.prefix(maxBatches).enumerated() {
                center.updateChannelCleanup("\(name) · 第 \(batchIndex + 1)/\(min(batches.count, maxBatches)) 批")
                let lines = batch.enumerated().map { index, channel in
                    "\(index + 1)|\(channel.name)|\(channel.group)"
                }
                do {
                    let text = try await center.complete(
                        config: aiConfig,
                        apiKey: aiAPIKey,
                        system: """
                        你是电视直播源清洗助手。对每个频道只做两件事：
                        1) 规范台名：去掉「高清 / 4K / HDR / 备用 / 线路1 / 测试」等画质与线路后缀，
                           央视统一写成「CCTV-1 综合」这种格式，卫视保留「湖南卫视」原样；
                        2) 归入一个固定分组，只能从这些里选：央视、卫视、地方、新闻、财经、体育、少儿、影视、纪录、音乐、港澳台、国际、其他。
                        不要改变频道本身的含义，不确定时保留原名并归到「其他」。
                        只输出一行 JSON：{"items":[{"index":1,"name":"...","group":"..."}]}。
                        """,
                        user: lines.joined(separator: "\n"),
                        maxTokens: 900,
                        preferLightweight: true
                    )
                    guard let object = AIAssistCenter.jsonObject(from: text),
                          let items = object["items"] as? [[String: Any]] else { continue }
                    for item in items {
                        guard let index = item["index"] as? Int,
                              index >= 1, index <= batch.count else { continue }
                        let localIndex = batchIndex * batchSize + index - 1
                        guard updated.indices.contains(localIndex) else { continue }
                        let newName = (item["name"] as? String ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let newGroup = (item["group"] as? String ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !newName.isEmpty, newName != updated[localIndex].name {
                            updated[localIndex].name = String(newName.prefix(30))
                            renamedTotal += 1
                        }
                        if !newGroup.isEmpty, newGroup != updated[localIndex].group {
                            updated[localIndex].group = String(newGroup.prefix(8))
                            regroupedTotal += 1
                        }
                    }
                } catch {
                    // 单批失败不中断：已经改好的批次照常落盘。
                    continue
                }
            }

            tv.channelCache[playlistID] = updated
            tv.database.replaceChannels(updated, for: playlistID)
        }

        tv.rebuildChannels()
        let parts = [
            renamedTotal > 0 ? "规范 \(renamedTotal) 个台名" : nil,
            regroupedTotal > 0 ? "重归 \(regroupedTotal) 个分组" : nil,
            truncated ? "频道过多，只处理了前 \(maxBatches * batchSize) 个" : nil
        ].compactMap { $0 }
        let summary = parts.isEmpty ? "AI 清洗：没有需要改动的频道" : "AI 清洗完成：" + parts.joined(separator: "，")
        center.finishChannelCleanup(summary)
        showToast(summary)
        if renamedTotal > 0 || regroupedTotal > 0 {
            Diagnostics.record("AI 辅助：电视清洗 \(summary)", level: .standard)
        }
    }

    // MARK: - 离线帮助问答

    /// 只以内置帮助资料回答；资料没覆盖就明确说不知道，避免模型编造设置项。
    func answerHelpQuestion(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginHelp() else { return }
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是 Luma（拾光）的内置帮助助手。只能依据下面的帮助资料回答，用中文 2 到 4 句，
                给出具体入口路径；资料里没有的内容直接说「帮助里还没有这条，可以在设置里导出诊断报告反馈」，
                不要编造菜单名或设置项。

                \(Self.helpKnowledge)
                """,
                user: "问题：\(trimmed)",
                maxTokens: 400,
                preferLightweight: true
            )
            center.finishHelp(.success(text))
        } catch {
            center.finishHelp(.failure(error))
        }
    }

    private static let helpKnowledge = """
    【图库】侧边栏「拾光」是本机图库；「系统图库」只读接入 macOS 照片，可在其上加关键词与标题叠加层；
    网盘通过侧边栏添加后只读浏览，可下载到图库再编辑。
    【导入】菜单「文件 › 导入照片」，支持拖拽、指定文件夹与重复检测；导入后可取消导入。
    【搜索】顶栏搜索框支持场景词、时间词（去年 / 2024年5月 / 5月20日）、类型词（视频 / 截图 / 实况 / 已编辑）
    与「收藏」；按 ⌘F 聚焦搜索框。搜索框里的闪光按钮可以把整句话改写为这些检索词。
    【相簿与关键词】右侧可新建相簿、智能相簿；关键词管理器统一改名与删除。选中照片后可批量添加关键词。
    【助手】右侧助手可对话和操作图库；在「设置 › 助手」选择服务，或在「设置 › 本地模型」一键下载本地模型。
    本地模型不联网、不发送照片；档位越大的模型理解越好但更慢，旁边有各档位适用场景说明。
    【一次性 AI 辅助】体检页的「AI 解读」、回忆 / 旅行的「AI 起名」、相册右键的「分享文案 / 关键词补全」、
    搜索框的「改写」、电视页的「AI 清洗」、设置里的「日志摘要」，都是一次性任务：只由按钮触发，只发文本，失败不影响原图库。
    【影院】「网络影院」自动刮削文件名，匹配不上的可手动匹配；顶栏还有「AI 兜底匹配」。
    【网络电视】「网络电视」页可粘贴 M3U 地址或导入播放列表；追剧订阅会提醒未来 7 天的节目。
    【体检与整理】侧边栏「体检」检查模糊、相似连拍和过大视频；「重复项」处理重复照片。
    【诊断】「设置 › 产品化」可导出诊断报告到桌面，也可以让本地模型把最近日志总结成问题与建议。
    【快捷键】空格查看、⌘E 导出所选、⌘F 搜索、⌘⌫ 移到废纸篓、⌘Z 撤销、⌘⇧N 新建相簿。
    """

    // MARK: - 诊断日志摘要

    func summarizeDiagnostics() async {
        guard aiAssistAvailability.isReady else {
            showToast(aiAssistAvailability.hint ?? "AI 不可用")
            return
        }
        let center = AIAssistCenter.shared
        guard center.beginDiagnostics() else { return }
        center.showDiagnosticsSheet = true

        guard let tail = Self.diagnosticTail(lines: 300) else {
            center.finishDiagnostics(.success("日志还没有内容：先用一会儿 App，再回来生成摘要。"))
            return
        }
        do {
            let text = try await center.complete(
                config: aiConfig,
                apiKey: aiAPIKey,
                system: """
                你是 Luma 的技术支持。阅读日志后输出中文三段，总字数不超过 160 字：
                1) 主要问题：最值得注意的错误或异常（没有就写「未发现明显错误」）；
                2) 可能原因：一句话；
                3) 建议操作：一到两条具体动作。
                不要复述日志原文，不要编造日志里没有的模块名。
                """,
                user: tail,
                maxTokens: 400,
                preferLightweight: true
            )
            center.finishDiagnostics(.success(text))
            Diagnostics.record("AI 辅助：生成诊断日志摘要", level: .standard)
        } catch {
            center.finishDiagnostics(.failure(error))
        }
    }

    /// 读日志尾部并做脱敏：去掉本机路径与可能的 Key，超长行截断。
    private static func diagnosticTail(lines limit: Int) -> String? {
        guard let data = try? Data(contentsOf: Diagnostics.logURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var output: [String] = []
        for line in text.split(separator: "\n").suffix(limit) {
            var value = String(line)
            if !home.isEmpty { value = value.replacingOccurrences(of: home, with: "~") }
            if value.count > 400 { value = String(value.prefix(400)) + "…" }
            value = value.replacingOccurrences(
                of: #"sk-[A-Za-z0-9_\-]{8,}"#,
                with: "sk-***",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"Bearer\s+\S+"#,
                with: "Bearer ***",
                options: .regularExpression
            )
            output.append(value)
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }
}
