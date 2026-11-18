import Foundation
import SwiftUI

/// 智能助手：只读问答 + 检索建议。
/// 每条消息随当前图库保存；API Key 只存钥匙串。
extension LibraryStore {
    private static let aiConfigKey = "ai_config"
    private static let aiConversationKey = "ai_conversation"
    private static let aiMaxHistory = 40
    private static let aiHistoryForRequest = 8
    private static let aiCandidateLimit = 40

    // MARK: - 加载与保存

    func loadAIState() {
        aiTask?.cancel()
        aiTask = nil
        aiIsResponding = false
        aiError = nil

        if let json = metadataStore?.setting(Self.aiConfigKey),
           let data = json.data(using: .utf8),
           let config = try? JSONDecoder().decode(AIConfig.self, from: data) {
            aiConfig = config
        } else {
            aiConfig = AIConfig()
        }

        if let json = metadataStore?.setting(Self.aiConversationKey),
           let data = json.data(using: .utf8),
           let messages = try? JSONDecoder().decode([AIChatMessage].self, from: data) {
            aiMessages = messages
        } else {
            aiMessages = []
        }
    }

    func saveAIConfig() {
        guard let data = try? JSONEncoder().encode(aiConfig),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.aiConfigKey, json)
    }

    func saveAIConversation() {
        trimAIMessages()
        guard let data = try? JSONEncoder().encode(aiMessages),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.aiConversationKey, json)
    }

    func clearAIConversation() {
        aiTask?.cancel()
        aiTask = nil
        aiIsResponding = false
        aiMessages = []
        aiError = nil
        saveAIConversation()
    }

    func updateAIProvider(_ provider: AIProvider) {
        aiConfig.provider = provider
        aiConfig.model = provider.defaultModel
        aiConfig.baseURL = provider.defaultBaseURL
        saveAIConfig()
    }

    /// API Key 只存钥匙串，随设备而不是图库；切换图库不需要重新填写。
    var aiAPIKey: String {
        aiConfig.provider.requiresAPIKey ? AIKeychain.key(for: aiConfig.provider) : ""
    }

    var aiHasAPIKey: Bool {
        !aiConfig.provider.requiresAPIKey || AIKeychain.hasKey(for: aiConfig.provider)
    }

    /// 接口地址与模型名都必须填写（豆包与自定义提供商默认不预填模型）。
    var aiConfigurationReady: Bool {
        !aiConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !aiConfig.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAIAPIKey(_ key: String) {
        AIKeychain.setKey(key, for: aiConfig.provider)
    }

    // MARK: - 发送

    func sendAIMessage() {
        let question = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !aiIsResponding else { return }
        guard aiConfigurationReady else {
            aiError = "请先在设置 › 助手中填写接口地址与模型"
            showToast("请先在设置 › 助手中填写接口地址与模型")
            return
        }
        guard aiHasAPIKey else {
            aiError = AIError.missingKey.localizedDescription
            showToast(AIError.missingKey.localizedDescription)
            return
        }

        aiInput = ""
        aiError = nil
        aiMessages.append(AIChatMessage(role: .user, text: question))
        trimAIMessages()
        saveAIConversation()
        aiIsResponding = true

        let config = aiConfig
        let key = aiAPIKey
        let candidates = aiCandidatePhotos(limit: Self.aiCandidateLimit)
        let context = makeAILibraryContext(photos: candidates)
        let history = aiMessages.dropLast()
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(Self.aiHistoryForRequest)
            .map { AIRequestMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text) }
        let candidateIDs = Set(candidates.map(\.id))
        aiLastCandidateIDs = candidates.map(\.id)
        var candidateNames: [String: UUID] = [:]
        for photo in candidates {
            candidateNames[photo.originalName.lowercased()] = photo.id
            candidateNames[photo.filename.lowercased()] = photo.id
        }
        aiLastCandidateNames = candidateNames
        let prompt = context.promptText(question: question)
        let imageLimit = config.includeImages ? max(1, config.maxImages) : 0
        let imagePhotos = imageLimit > 0 ? Array(candidates.prefix(imageLimit * 2)) : []

        aiTask = Task { [weak self] in
            guard let self else { return }
            var imagePairs: [(UUID, String)] = []
            if imageLimit > 0 {
                imagePairs = await Task.detached(priority: .userInitiated) {
                    AIImageEncoder.dataURLs(for: imagePhotos, limit: imageLimit)
                }.value
            }
            if Task.isCancelled {
                self.aiIsResponding = false
                self.aiTask = nil
                return
            }

            var promptText = prompt
            if !imagePairs.isEmpty {
                let indices = imagePairs.compactMap { pair in
                    context.candidates.first(where: { $0.id == pair.0 })?.index
                }
                if !indices.isEmpty {
                    let list = indices.map { "#\($0)" }.joined(separator: "、")
                    promptText += "\n\n【随消息发送的图片】依次对应候选照片 \(list)。"
                }
            }

            var wire: [AIRequestMessage] = [
                AIRequestMessage(role: "system", text: AILibraryContext.systemPrompt)
            ]
            wire.append(contentsOf: history)
            wire.append(AIRequestMessage(role: "user",
                                         text: promptText,
                                         images: imagePairs.map(\.1)))

            var allowedIDs = candidateIDs
            var finalText = ""
            var finalSuggestion: AISearchSuggestion?
            var toolRounds = 0
            var reminderSent = false
            var didExecuteTool = false

            do {
                while true {
                    let completion = try await AIProviderClient.complete(
                        config: config,
                        apiKey: key,
                        messages: wire,
                        tools: AILibraryTools.definitions
                    )
                    guard !Task.isCancelled else {
                        self.aiIsResponding = false
                        self.aiTask = nil
                        return
                    }

                    if completion.toolCalls.isEmpty {
                        // 有些模型会先给方案而不调用工具：对有明确操作意图的问题提醒一次。
                        if !reminderSent, Self.hasActionIntent(question) {
                            reminderSent = true
                            wire.append(AIRequestMessage(role: "assistant", text: completion.content))
                            wire.append(AIRequestMessage(
                                role: "user",
                                text: "请调用工具实际执行上面的操作；只有在工具返回成功后才能说已完成。若无法执行，请说明原因。"
                            ))
                            continue
                        }
                        let parsed = AIContextBuilder.parseDirective(from: completion.content)
                        finalText = parsed.text
                        finalSuggestion = parsed.suggestion
                        break
                    }

                    toolRounds += 1
                    if toolRounds > 4 {
                        finalText = "工具调用次数过多，已停止。请换一种问法或缩小范围。"
                        break
                    }

                    wire.append(AIRequestMessage(role: "assistant",
                                                 text: completion.content,
                                                 toolCalls: completion.toolCalls))

                    let writeCalls = completion.toolCalls.filter {
                        AILibraryTools.writeToolNames.contains($0.name)
                    }
                    let confirmed = writeCalls.isEmpty ? true : self.confirmAIToolActions(writeCalls)
                    var summaries: [String] = []

                    for call in completion.toolCalls {
                        let isWrite = AILibraryTools.writeToolNames.contains(call.name)
                        if isWrite, !confirmed {
                            wire.append(AIRequestMessage(
                                role: "tool",
                                text: "{\"ok\":false,\"error\":\"用户取消了本次操作\"}",
                                toolCallID: call.id
                            ))
                            continue
                        }
                        let result = await self.executeAITool(call)
                        didExecuteTool = true
                        wire.append(AIRequestMessage(role: "tool",
                                                     text: result.json,
                                                     toolCallID: call.id))
                        allowedIDs.formUnion(result.photoIDs)
                        if let summary = result.summary {
                            summaries.append(summary)
                        }
                    }

                    if !summaries.isEmpty {
                        self.aiMessages.append(AIChatMessage(role: .action,
                                                             text: summaries.joined(separator: " · ")))
                        self.trimAIMessages()
                        self.saveAIConversation()
                    }
                }

                var photoIDs: [UUID] = []
                if let rawIDs = finalSuggestion?.photoIDs {
                    photoIDs = rawIDs.compactMap { UUID(uuidString: $0) }
                        .filter { allowedIDs.contains($0) }
                }
                let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.aiMessages.append(AIChatMessage(role: .assistant,
                                                     text: text.isEmpty ? "（模型没有返回内容）" : text,
                                                     photoIDs: photoIDs,
                                                     suggestion: finalSuggestion))
                // 有明确操作意图却一次工具都没调用：明确提示未执行，避免被模型的“已完成”误导。
                if !didExecuteTool, Self.hasActionIntent(question) {
                    self.aiMessages.append(AIChatMessage(
                        role: .assistant,
                        text: "本次没有执行任何图库操作：模型没有调用工具。可以重试，或在设置 › 助手中改用支持工具调用的模型。",
                        isError: true
                    ))
                }
                self.saveAIConversation()
                self.aiIsResponding = false
                self.aiTask = nil
            } catch {
                if case AIError.cancelled = error {
                    self.aiIsResponding = false
                    self.aiTask = nil
                    return
                }
                self.aiError = error.localizedDescription
                self.aiMessages.append(AIChatMessage(role: .assistant,
                                                     text: error.localizedDescription,
                                                     isError: true))
                self.saveAIConversation()
                self.aiIsResponding = false
                self.aiTask = nil
            }
        }
    }

    func stopAIResponse() {
        aiTask?.cancel()
        aiTask = nil
        aiIsResponding = false
    }

    /// 把助手给出的检索条件套到当前网格（复用现有搜索与筛选管线）。
    func applyAISuggestion(_ suggestion: AISearchSuggestion) {
        if let keywords = suggestion.keywords?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keywords.isEmpty {
            searchText = keywords
            prepareSemanticSearch()
        }
        if let raw = suggestion.filter, let filter = PhotoFilter(rawValue: raw) {
            photoFilter = filter
        }
        showToast("已按助手的条件筛选当前图库")
    }

    func testAIConnection() async -> (Bool, String) {
        guard aiConfigurationReady else {
            return (false, "请先填写接口地址与模型")
        }
        let key = aiAPIKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, AIError.missingKey.localizedDescription)
        }
        do {
            let reply = try await AIProviderClient.complete(
                config: aiConfig,
                apiKey: key,
                messages: [AIRequestMessage(role: "user", text: "请只回复 OK")]
            )
            let preview = reply.content.prefix(40)
            return (true, "连接成功：\(preview)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 上下文

    /// 选中项优先，其次当前范围的前若干张；数量固定，避免把整个图库塞进提示词。
    func aiCandidatePhotos(limit: Int) -> [PhotoItem] {
        var result: [PhotoItem] = []
        var seen: Set<UUID> = []
        for id in selection {
            guard let photo = anyPhoto(id: id) else { continue }
            guard seen.insert(photo.id).inserted else { continue }
            result.append(photo)
            if result.count >= limit { return result }
        }
        let source = isCloudScope ? cloudVisiblePhotos : visiblePhotos
        for photo in source {
            guard seen.insert(photo.id).inserted else { continue }
            result.append(photo)
            if result.count >= limit { break }
        }
        return result
    }

    func makeAILibraryContext(photos: [PhotoItem]) -> AILibraryContext {
        let scopeCount = visibleCount
        let total: Int
        if isSystemScope {
            total = systemTotalAssetCount > 0 ? systemTotalAssetCount : systemPhotos.count
        } else if isCloudScope {
            total = cloudPhotos.count
        } else {
            total = self.photos.count
        }
        let analysis = isSystemScope || isCloudScope ? [:] : analysisIndex
        return AIContextBuilder.make(scopeTitle: sidebarTitle,
                                     scopeCount: scopeCount,
                                     libraryTotal: total,
                                     filterTitle: photoFilter.title,
                                     searchText: searchText,
                                     selectionCount: selection.count,
                                     photos: photos,
                                     analysis: analysis,
                                     limit: Self.aiCandidateLimit)
    }

    private func trimAIMessages() {
        if aiMessages.count > Self.aiMaxHistory {
            aiMessages.removeFirst(aiMessages.count - Self.aiMaxHistory)
        }
    }

    /// 粗略识别「要动手」的请求，用于提醒模型调用工具，而不是只给方案。
    private static func hasActionIntent(_ text: String) -> Bool {
        if text.contains("怎么") || text.contains("如何") || text.contains("为什么") { return false }
        let keywords = ["创建", "新建", "加入", "放到", "放进", "归入", "移出", "移除",
                        "收藏", "取消收藏", "添加关键词", "去掉关键词", "删除关键词", "打标签",
                        "整理成", "重命名", "改名", "移动", "隐藏", "取消隐藏", "恢复",
                        "设为封面", "封面", "改标题", "设置标题", "移入最近删除", "压缩", "美化",
                        "选中", "打开", "切换到", "筛选", "排序", "直接操作", "执行"]
        return keywords.contains { text.contains($0) }
    }
}
