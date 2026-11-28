import Foundation
import LumaContentCore

/// 2.2 的对话主循环：流式输出、计划卡、审批 2.0、检查点、成果物与工具路由。
/// 旧的一次性实现保留在 `sendAIMessageLegacy`，稳定后删除。
extension LibraryStore {
    // MARK: - 入口

    /// 任务中心：只保留最近 20 条，运行中的不裁剪。
    private func recordAITaskStart(id: UUID, title: String, background: Bool, model: String) {
        let record = AITaskRecord(id: id,
                                  title: String(title.prefix(80)),
                                  startedAt: Date(),
                                  isBackground: background,
                                  model: model)
        aiTaskRecords.insert(record, at: 0)
        let running = aiTaskRecords.filter { $0.status == .running }
        let finished = aiTaskRecords.filter { $0.status != .running }
        aiTaskRecords = running + finished.prefix(max(0, 20 - running.count))
    }

    func updateAITaskRecord(_ id: UUID,
                            status: AITaskRecord.Status,
                            toolSteps: Int? = nil,
                            error: String? = nil,
                            promptTokens: Int? = nil,
                            completionTokens: Int? = nil) {
        guard let index = aiTaskRecords.firstIndex(where: { $0.id == id }) else { return }
        aiTaskRecords[index].status = status
        aiTaskRecords[index].finishedAt = status == .running ? nil : Date()
        if let toolSteps { aiTaskRecords[index].toolSteps = toolSteps }
        if let error { aiTaskRecords[index].errorText = error }
        if let promptTokens { aiTaskRecords[index].promptTokens = promptTokens }
        if let completionTokens { aiTaskRecords[index].completionTokens = completionTokens }
    }

    func clearFinishedAITaskRecords() {
        aiTaskRecords.removeAll { $0.status != .running }
    }

    /// 任务收尾：只在仍是「运行中」时才落 finished / cancelled，避免覆盖 catch 里写入的 failed。
    private func finalizeAITaskRecord(_ id: UUID, cancelled: Bool, toolSteps: Int) {
        guard let index = aiTaskRecords.firstIndex(where: { $0.id == id }) else { return }
        if aiTaskRecords[index].status == .running {
            aiTaskRecords[index].status = cancelled ? .cancelled : .finished
            aiTaskRecords[index].finishedAt = Date()
        }
        aiTaskRecords[index].toolSteps = toolSteps
        aiTaskRecords[index].promptTokens = aiLastPromptTokens
        aiTaskRecords[index].completionTokens = aiLastCompletionTokens
        recordAITaskMetrics(aiTaskRecords[index])
    }

    func sendAIMessage() {
        let question = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !aiIsResponding else { return }
        applyLocalModelConfigIfReady()

        if aiConfig.provider == .local, !LocalLLMRuntime.shared.isServerRunning,
           LocalLLMRuntime.shared.isRuntimeInstalled {
            guard !LocalLLMRuntime.shared.stage.isBusy else { return }
            aiError = "本地模型服务未启动，正在自动启动…"
            Task { @MainActor [weak self] in
                await LocalLLMRuntime.shared.startServerIfNeeded()
                guard let self else { return }
                if LocalLLMRuntime.shared.isServerRunning {
                    self.aiError = nil
                    self.sendAIMessage()
                }
            }
            return
        }
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

        pinMentionsFromText(question)
        aiInput = ""
        aiError = nil
        aiMessages.append(AIChatMessage(role: .user, text: question))
        trimAIMessages()
        saveAIConversation()
        aiIsResponding = true
        aiStreamingText = ""
        aiToolSteps = []
        aiPendingPlan = nil
        aiPendingApproval = nil
        aiTaskAutoApproveWrites = false
        cancelAITakeover()
        aiCurrentTaskID = UUID()
        refreshAIContextCapsules()
        if let taskID = aiCurrentTaskID {
            recordAITaskStart(id: taskID,
                              title: question,
                              background: aiBackgroundRun,
                              model: aiConfig.model)
        }
        aiLastPromptTokens = 0
        aiLastCompletionTokens = 0

        let config = aiConfig
        let key = aiAPIKey
        let taskID = aiCurrentTaskID ?? UUID()
        let mode = config.mode
        let candidateLimit: Int
        let historyRounds: Int
        let roundLimit: Int
        switch mode {
        case .fast:
            candidateLimit = 24
            historyRounds = min(3, config.historyRounds)
            roundLimit = min(12, max(4, config.maxToolRounds))
        case .balanced:
            candidateLimit = Self.aiCandidateLimit
            historyRounds = config.historyRounds
            roundLimit = config.maxToolRounds
        case .deep:
            candidateLimit = 64
            historyRounds = max(10, config.historyRounds)
            roundLimit = min(300, max(150, config.maxToolRounds))
        }

        let jobID = beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .assistant,
                      title: "AI 助手"),
            cancel: { [weak self] in
                Task { @MainActor in self?.stopAIResponse() }
            }
        )

        tasks.adopt(.ai, Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            defer {
                self.finalizeAITaskRecord(taskID,
                                          cancelled: Task.isCancelled,
                                          toolSteps: self.aiToolSteps.count)
                self.aiAutoMatchCinema = false
                self.aiStreamingText = ""
                self.aiStreamingReasoning = ""
                self.aiToolSteps = []
                self.aiPendingPlan = nil
                self.aiPendingApproval = nil
                self.aiActivity = nil
                self.aiIsResponding = false
                self.aiTakeoverRequested = false
                self.aiTakeoverPaused = false
                self.aiBackgroundRun = false
                self.aiCurrentTaskID = nil
                self.tasks.finish(.ai)
                if Task.isCancelled {
                    self.cancelSourceJob(jobID)
                } else {
                    self.finishSourceJob(jobID, message: "已回复")
                }
            }

            do {
                try await self.runAITurn(question: question,
                                         taskID: taskID,
                                         config: config,
                                         key: key,
                                         candidateLimit: candidateLimit,
                                         historyRounds: historyRounds,
                                         roundLimit: roundLimit,
                                         startedAt: startedAt)
            } catch {
                if case AIError.cancelled = error {
                    return
                }
                let code = (error as? AIError)?.code ?? .unknown
                let message = (error as? AIError)?.localizedDescription ?? error.localizedDescription
                self.aiError = message
                self.aiMessages.append(AIChatMessage(
                    role: .assistant,
                    text: message,
                    isError: true,
                    elapsed: Date().timeIntervalSince(startedAt),
                    errorCode: code,
                    taskID: taskID
                ))
                self.updateAITaskRecord(taskID, status: .failed, error: message)
                self.saveAIConversation()
            }
        })
    }

    // MARK: - 主循环

    private func runAITurn(question: String,
                           taskID: UUID,
                           config: AIConfig,
                           key: String,
                           candidateLimit: Int,
                           historyRounds: Int,
                           roundLimit: Int,
                           startedAt: Date) async throws {
        aiActivity = "正在理解当前范围"
        // 指认优先：@ 的对象排在候选最前，必要时挤掉尾部。
        var merged: [PhotoItem] = []
        var mergedIDs = Set<UUID>()
        for photo in aiMentionedPhotos where mergedIDs.insert(photo.id).inserted {
            merged.append(photo)
        }
        for photo in aiCandidatePhotosRespectingMute(limit: candidateLimit)
        where mergedIDs.insert(photo.id).inserted {
            merged.append(photo)
        }
        let candidates = Array(merged.prefix(candidateLimit))
        var context = makeAILibraryContext(photos: candidates, limit: candidateLimit)
        if !isAIContextEnabled(.search) { context.searchOverview = nil }
        if !isAIContextEnabled(.cinema) { context.cinema = nil }
        if !isAIContextEnabled(.selection) { context.selectionCount = 0 }

        var promptText = context.promptText(question: question)
        if isAIContextEnabled(.viewer), let photo = viewerPhoto {
            promptText += "\n\n【当前查看】\(photo.isVideo ? "视频" : "照片")：\(photo.displayFilename)"
        }
        let mentionText = aiMentionPrompt()
        if !mentionText.isEmpty {
            promptText += "\n\n" + mentionText
        }
        // 指认是一次性的：已经写进本轮提示词，避免下一轮继续带入。
        clearAIMentions()

        let history = aiMessages.dropLast()
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(max(2, historyRounds * 2))
            .map { AIRequestMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text) }

        let candidateIDs = Set(candidates.map(\.id))
        aiLastCandidateIDs = candidates.map(\.id)
        var candidateNames: [String: UUID] = [:]
        for photo in candidates {
            candidateNames[photo.originalName.lowercased()] = photo.id
            candidateNames[photo.filename.lowercased()] = photo.id
        }
        aiLastCandidateNames = candidateNames

        // 1. 计划阶段：多步任务才先出计划；「计划模式」打开时，只要不是知识问答就先生成计划。
        var approvedPlan: AIPlan?
        let wantsPlan = aiForcePlan
            ? !Self.isKnowledgeQuestion(question)
            : Self.shouldPlan(question)
        if wantsPlan {
            aiActivity = "正在规划步骤"
            let planInput = "【当前范围】\(context.scopeTitle)（\(context.scopeCount) 项）\n【用户问题】\(question)"
            if var plan = try await makePlan(question: question,
                                              promptText: planInput,
                                              config: config,
                                              key: key) {
                if aiBackgroundRun {
                    // 定时任务无人值守：计划自动通过，但写操作仍会在审批处被跳过。
                    plan.status = .approved
                    aiMessages.append(AIChatMessage(role: .assistant,
                                                    text: "定时任务已按计划开始执行（只读）。",
                                                    plan: plan,
                                                    taskID: taskID))
                    saveAIConversation()
                    approvedPlan = plan
                } else {
                    let message = AIChatMessage(role: .assistant,
                                                text: "计划已生成，等待确认。",
                                                plan: plan,
                                                taskID: taskID)
                    aiMessages.append(message)
                    saveAIConversation()
                    aiPendingPlan = plan
                    aiActivity = "等待批准计划"
                    let status = await awaitPlanDecision()
                    aiPendingPlan = nil
                    updatePlanMessageStatus(plan.id, status: status)
                    if status == .cancelled {
                        appendAIAssistantMessage("已取消计划，本次没有执行任何操作。",
                                                 taskID: taskID,
                                                 startedAt: startedAt,
                                                 toolRounds: 0)
                        return
                    }
                    approvedPlan = plan
                }
            }
        }

        if let approvedPlan {
            promptText += "\n\n【已批准的计划】\n"
                + approvedPlan.steps.enumerated().map { index, step in
                    "\(index + 1). \(step.title)（\(step.risk.title)）"
                }.joined(separator: "\n")
                + "\n请按计划执行；如需改变步骤，先说明并等待用户确认。"
        }

        // 2. 工具路由：先按角色划边界，再按领域与意图收窄。
        let role = config.agentRole
        let allTools = aiToolDefinitions.filter { role.allows(toolName: $0.name) }
        let selected = config.toolRoutingEnabled
            ? AIToolRouter.select(question: question,
                                  area: aiRoutingArea(for: role),
                                  definitions: allTools)
            : allTools
        var tools = (selected.isEmpty || !config.toolRoutingEnabled) ? allTools : selected
        if role == .auto, config.delegateToSubAgents,
           !tools.contains(where: { $0.name == "delegate_agent" }) {
            tools.append(Self.delegateAgentTool)
        }
        if !aiBackgroundRun, !tools.contains(where: { $0.name == "ask_user" }) {
            tools.append(Self.askUserTool)
        }
        aiLastToolCount = tools.count
        let allowedToolNames = Set(tools.map(\.name))

        let imageLimit = config.includeImages ? max(1, config.maxImages) : 0
        let imagePhotos = imageLimit > 0 ? Array(candidates.prefix(imageLimit * 2)) : []
        var imagePairs: [(UUID, String)] = []
        if imageLimit > 0 {
            imagePairs = await Task.detached(priority: .userInitiated) {
                AIImageEncoder.dataURLs(for: imagePhotos, limit: imageLimit)
            }.value
        }
        if Task.isCancelled { throw AIError.cancelled }

        var effectivePrompt = promptText
        if !imagePairs.isEmpty {
            let indices = imagePairs.compactMap { pair in
                context.candidates.first(where: { $0.id == pair.0 })?.index
            }
            if !indices.isEmpty {
                let list = indices.map { "#\($0)" }.joined(separator: "、")
                effectivePrompt += "\n\n【随消息发送的图片】依次对应候选照片 \(list)。"
            }
        }

        var systemText = AILibraryContext.systemPrompt + "\n\n"
            + AILibraryContext.modeInstruction(config.mode)
        systemText += "\n\n【本轮工具】只暴露以下 \(tools.count) 个工具："
            + tools.map(\.name).joined(separator: "、")
            + "。不要调用未列出的工具；需要的能力不在列表里时，如实说明。"
        systemText += "\n\n【当前角色】\(role.title)：\(role.systemAddition)"
        systemText += "\n\n" + AIPromptInjectionGuard.systemRule
        if tools.contains(where: { $0.name == "delegate_agent" }) {
            systemText += "\n\n【多 Agent 协作】遇到跨模块任务，可以把只读子任务委派给 delegate_agent"
                + "（role：librarian / curator / cinemaManager），再综合子助手的结论。"
                + "委派只用于查询，写操作仍由你按审批执行。"
                + "互不依赖的子任务用 tasks 数组一次并行委派，最多 3 个。"
        }
        if tools.contains(where: { $0.name == "ask_user" }) {
            systemText += "\n\n【主动追问】信息不足、目标有歧义或需要在多个方案中取舍时，"
                + "先调用 ask_user 问清楚；一次只问最关键的一个问题，能给出 2–4 个选项时一并给出。"
                + "不要为了确认而确认。"
        }
        let memory = aiMemoryPrompt()
        if !memory.isEmpty {
            systemText += "\n\n【长期偏好】以下是用户此前明确要求记住的偏好，只作为默认习惯；"
                + "与用户当前指令冲突时，以当前指令为准：\n" + memory
        }
        let integrationPrompt = aiIntegrations.flatMap {
            $0.systemPromptAdditions(store: self)
        }
        if !integrationPrompt.isEmpty {
            systemText += "\n\n" + integrationPrompt.joined(separator: "\n")
        }

        var wire: [AIRequestMessage] = [AIRequestMessage(role: "system", text: systemText)]
        wire.append(contentsOf: history)
        wire.append(AIRequestMessage(role: "user",
                                     text: effectivePrompt,
                                     images: imagePairs.map(\.1)))

        let provider = AIChatProviderFactory.make(config: config)
        var allowedIDs = candidateIDs
        var finalText = ""
        var finalSuggestion: AISearchSuggestion?
        var toolRounds = 0
        var reminderSent = false
        var didExecuteTool = false
        var artifacts: [AIArtifact] = []
        var previews: [AIResultPreview] = []
        var totalPromptTokens = 0
        var totalCompletionTokens = 0
        var finalReasoning: String?

        // 3. 工具循环：流式取回文本与工具调用。
        while true {
            if Task.isCancelled { throw AIError.cancelled }
            // 接管：每轮开始前给用户一个安全点。
            if !(await awaitAITakeoverIfNeeded()) {
                appendAIAssistantMessage("你已接管本次任务，AI 已停止。已完成的步骤可以在对话里撤销。",
                                         taskID: taskID,
                                         startedAt: startedAt,
                                         toolRounds: toolRounds)
                return
            }
            aiActivity = "正在生成回答"
            let completion = try await streamCompletion(provider: provider,
                                                        config: config,
                                                        key: key,
                                                        wire: wire,
                                                        tools: tools)
            totalPromptTokens += completion.promptTokens ?? 0
            totalCompletionTokens += completion.completionTokens ?? 0
            if let reasoning = completion.reasoning, !reasoning.isEmpty {
                finalReasoning = reasoning
            }

            if completion.toolCalls.isEmpty {
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
            if toolRounds > roundLimit {
                finalText = "工具调用次数过多，已停止。请换一种问法或缩小范围。"
                break
            }

            wire.append(AIRequestMessage(role: "assistant",
                                         text: completion.content,
                                         toolCalls: completion.toolCalls))

            let writeCalls = completion.toolCalls.filter {
                AILibraryTools.isWrite($0.name)
            }
            let approved = writeCalls.isEmpty
                ? Set<String>()
                : await requestAIApproval(for: writeCalls)
            var summaries: [String] = []

            for call in completion.toolCalls {
                if Task.isCancelled { throw AIError.cancelled }
                guard allowedToolNames.contains(call.name) else {
                    wire.append(AIRequestMessage(
                        role: "tool",
                        text: "{\"ok\":false,\"error\":\"本轮没有暴露这个工具。请只使用已列出的工具，或如实说明无法完成。\"}",
                        toolCallID: call.id
                    ))
                    appendToolStep(title: "拒绝未授权工具",
                                   detail: call.name,
                                   status: .failed)
                    continue
                }
                let args = AILibraryTools.arguments(call.arguments)

                // 主动追问：信息不足时先问清楚；不写任何数据。
                if call.name == "ask_user" {
                    let questionText = ((args["question"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !questionText.isEmpty else {
                        wire.append(AIRequestMessage(
                            role: "tool",
                            text: "{\"ok\":false,\"error\":\"ask_user 需要 question\"}",
                            toolCallID: call.id
                        ))
                        continue
                    }
                    guard !aiBackgroundRun else {
                        wire.append(AIRequestMessage(
                            role: "tool",
                            text: "{\"ok\":false,\"error\":\"无人值守任务不能向用户提问，请按最保守的方式继续\"}",
                            toolCallID: call.id
                        ))
                        continue
                    }
                    let options = (args["options"] as? [String]) ?? []
                    let step = appendToolStep(title: "向用户确认",
                                              detail: questionText,
                                              status: .running)
                    let answer = await awaitAIQuestion(questionText, options: options)
                    finishToolStep(step,
                                   status: .done,
                                   detail: answer == nil ? "用户跳过" : "已回答")
                    let payload: [String: Any] = [
                        "ok": true,
                        "answer": answer ?? "用户没有回答，请按最保守的方式继续，并在结果里说明不确定之处。"
                    ]
                    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                    wire.append(AIRequestMessage(
                        role: "tool",
                        text: String(data: data, encoding: .utf8) ?? "{\"ok\":true}",
                        toolCallID: call.id
                    ))
                    continue
                }

                // 多 Agent 协作：把只读子任务交给专门角色，写操作仍留在主循环。
                if call.name == "delegate_agent" {
                    let specs = aiDelegationSpecs(from: args)
                    guard !specs.isEmpty else {
                        wire.append(AIRequestMessage(
                            role: "tool",
                            text: "{\"ok\":false,\"error\":\"委派需要 role + task，或用 tasks 数组\"}",
                            toolCallID: call.id
                        ))
                        appendToolStep(title: "委派未执行", detail: "缺少角色或任务", status: .failed)
                        continue
                    }
                    let step = appendToolStep(
                        title: specs.count > 1
                            ? "并行委派 \(specs.count) 个子任务"
                            : "委派给\(specs[0].role.title)",
                        detail: specs.count > 1
                            ? specs.map(\.task).joined(separator: "；")
                            : specs[0].task,
                        status: .running
                    )
                    do {
                        let contextText = context.promptText(question: "")
                        var outcomes: [AISubAgentOutcome] = []
                        if specs.count == 1 {
                            let summary = try await runSubAIAgent(role: specs[0].role,
                                                                  task: specs[0].task,
                                                                  config: config,
                                                                  key: key,
                                                                  contextText: contextText)
                            outcomes = [AISubAgentOutcome(role: specs[0].role,
                                                          task: specs[0].task,
                                                          summary: summary,
                                                          error: nil)]
                        } else {
                            // 只读子任务互不依赖：并行拉起，最多 3 个；任一失败不影响其余。
                            outcomes = await withTaskGroup(of: AISubAgentOutcome.self) { group in
                                for spec in specs {
                                    group.addTask { @MainActor in
                                        do {
                                            let summary = try await self.runSubAIAgent(
                                                role: spec.role,
                                                task: spec.task,
                                                config: config,
                                                key: key,
                                                contextText: contextText
                                            )
                                            return AISubAgentOutcome(role: spec.role,
                                                                     task: spec.task,
                                                                     summary: summary,
                                                                     error: nil)
                                        } catch {
                                            return AISubAgentOutcome(role: spec.role,
                                                                     task: spec.task,
                                                                     summary: nil,
                                                                     error: error.localizedDescription)
                                        }
                                    }
                                }
                                var collected: [AISubAgentOutcome] = []
                                for await outcome in group { collected.append(outcome) }
                                return collected
                            }
                        }
                        let successes = outcomes.filter { $0.summary != nil }
                        guard !successes.isEmpty else {
                            let message = outcomes.compactMap(\.error).first ?? "子助手执行失败"
                            finishToolStep(step, status: .failed, detail: message)
                            wire.append(AIRequestMessage(
                                role: "tool",
                                text: "{\"ok\":false,\"error\":\"子助手执行失败\"}",
                                toolCallID: call.id
                            ))
                            continue
                        }
                        finishToolStep(step,
                                       status: .done,
                                       detail: outcomes.count > 1
                                           ? "\(successes.count)/\(outcomes.count) 个子助手已返回"
                                           : "子助手已返回")
                        let payload: [String: Any] = [
                            "ok": true,
                            "delegations": successes.map {
                                ["role": $0.role.rawValue, "summary": $0.summary ?? ""]
                            },
                            "summary": successes.map {
                                "\($0.role.title)：\($0.summary ?? "")"
                            }.joined(separator: "；")
                        ]
                        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                        wire.append(AIRequestMessage(
                            role: "tool",
                            text: String(data: data, encoding: .utf8) ?? "{\"ok\":true}",
                            toolCallID: call.id
                        ))
                        for outcome in successes {
                            let summary = outcome.summary ?? ""
                            if AIPromptInjectionGuard.isSuspicious(summary) {
                                wire.append(AIRequestMessage(role: "system",
                                                             text: AIPromptInjectionGuard.suspiciousReminder))
                            }
                            summaries.append("\(outcome.role.title)：\(summary)")
                        }
                        didExecuteTool = true
                    } catch {
                        finishToolStep(step, status: .failed, detail: error.localizedDescription)
                        wire.append(AIRequestMessage(
                            role: "tool",
                            text: "{\"ok\":false,\"error\":\"子助手执行失败\"}",
                            toolCallID: call.id
                        ))
                    }
                    continue
                }

                let risk = AILibraryTools.risk(for: call.name, arguments: args)
                let isWrite = AILibraryTools.isWrite(call.name)
                if isWrite, !approved.contains(call.id) {
                    wire.append(AIRequestMessage(
                        role: "tool",
                        text: "{\"ok\":false,\"error\":\"用户取消了本次操作\"}",
                        toolCallID: call.id
                    ))
                    appendToolStep(title: AILibraryTools.shortTitle(for: call.name),
                                   detail: "用户取消",
                                   status: .failed)
                    continue
                }

                var undoEntryID: UUID?
                if isWrite, let undo = makeAIUndoEntry(for: call, args: args) {
                    aiUndoLog.append(undo)
                    aiUndoRevision &+= 1
                    undoEntryID = undo.id
                }

                aiActivity = "正在" + AILibraryTools.shortTitle(for: call.name)
                let step = appendToolStep(title: AILibraryTools.shortTitle(for: call.name),
                                          detail: risk.title,
                                          status: .running)
                let result = await executeAITool(call)
                let ok = Self.toolResultOK(result)
                if !ok, let undoEntryID {
                    // 写操作没有成功：不留下无效的撤销项。
                    aiUndoLog.removeAll { $0.id == undoEntryID }
                    aiUndoRevision &+= 1
                }
                finishToolStep(step, status: ok ? .done : .failed, detail: result.summary ?? risk.title)
                didExecuteTool = true
                wire.append(AIRequestMessage(role: "tool",
                                             text: result.json,
                                             toolCallID: call.id))
                if AIPromptInjectionGuard.isSuspicious(result.json) {
                    wire.append(AIRequestMessage(role: "system",
                                                 text: AIPromptInjectionGuard.suspiciousReminder))
                }
                allowedIDs.formUnion(result.photoIDs)
                if let summary = result.summary {
                    summaries.append(summary)
                }
                let madeArtifacts = makeAIArtifacts(for: call, args: args, result: result)
                if !madeArtifacts.isEmpty {
                    artifacts.append(contentsOf: madeArtifacts)
                    recordAIArtifacts(madeArtifacts)
                }
                // 影院 / 资源 / 网络影院 / 电视：结果直接渲染成内容卡。
                for preview in aiResultPreviews(for: call, args: args, result: result) {
                    guard previews.count < 12,
                          !previews.contains(where: {
                              $0.domain == preview.domain && $0.title == preview.title
                          }) else { continue }
                    previews.append(preview)
                }
                // 接管：工具之间也是安全点，用户可以先自己动手。
                if !(await awaitAITakeoverIfNeeded()) {
                    appendAIAssistantMessage("你已接管本次任务，AI 已停止。已完成的步骤可以在对话里撤销。",
                                             taskID: taskID,
                                             startedAt: startedAt,
                                             toolRounds: toolRounds)
                    return
                }
            }

            aiStreamingText = ""
            aiActivity = "正在整理结果"
            if !summaries.isEmpty {
                aiMessages.append(AIChatMessage(role: .action,
                                                text: summaries.joined(separator: " · ")))
                trimAIMessages()
                saveAIConversation()
            }
        }

        var photoIDs: [UUID] = []
        if let rawIDs = finalSuggestion?.photoIDs {
            photoIDs = rawIDs.compactMap { UUID(uuidString: $0) }
                .filter { allowedIDs.contains($0) }
        }
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        aiLastPromptTokens = totalPromptTokens
        aiLastCompletionTokens = totalCompletionTokens
        aiMessages.append(AIChatMessage(
            role: .assistant,
            text: text.isEmpty ? "（模型没有返回内容）" : text,
            photoIDs: photoIDs,
            suggestion: finalSuggestion,
            elapsed: Date().timeIntervalSince(startedAt),
            toolSteps: toolRounds,
            artifacts: artifacts,
            taskID: taskID,
            previews: previews,
            reasoning: finalReasoning,
            promptTokens: totalPromptTokens > 0 ? totalPromptTokens : nil,
            completionTokens: totalCompletionTokens > 0 ? totalCompletionTokens : nil
        ))
        if !didExecuteTool, Self.hasActionIntent(question) {
            aiMessages.append(AIChatMessage(
                role: .assistant,
                text: "本次没有执行任何图库操作：模型没有调用工具。可以重试，或在设置 › 助手中改用支持工具调用的模型。",
                isError: true,
                errorCode: .toolFailed,
                taskID: taskID
            ))
        }
        saveAIConversation()
    }

    // MARK: - 主动追问

    private func awaitAIQuestion(_ question: String, options: [String]) async -> String? {
        aiPendingQuestion = AIQuestionRequest(question: question,
                                              options: Array(options.prefix(4)))
        let answer = await withCheckedContinuation { continuation in
            aiQuestionContinuation?.resume(returning: nil)
            aiQuestionContinuation = continuation
        }
        aiPendingQuestion = nil
        return answer
    }

    func resolveAIQuestion(_ answer: String?) {
        aiPendingQuestion = nil
        aiQuestionContinuation?.resume(returning: answer)
        aiQuestionContinuation = nil
    }

    // MARK: - 多 Agent

    /// 主动追问：信息不足或存在多种合理解释时，先问清楚再动手。
    static let askUserTool = AIRequestTool(
        name: "ask_user",
        description: "信息不足、存在多种合理解释或需要用户在几个选项里选择时，先问清楚再执行；无人值守的定时任务不可用。",
        parameters: [
            "type": "object",
            "properties": [
                "question": [
                    "type": "string",
                    "description": "要问用户的问题，一句话说清楚缺什么"
                ] as [String: Any],
                "options": [
                    "type": "array",
                    "description": "可选的候选答案，最多 4 个；用户也可以自己输入",
                    "items": ["type": "string"] as [String: Any]
                ] as [String: Any]
            ] as [String: Any],
            "required": ["question"]
        ]
    )

    /// 主助手唯一的「同事」工具：只读委派，不授予写权限；互不依赖的子任务可并行。
    static let delegateAgentTool = AIRequestTool(
        name: "delegate_agent",
        description: "把一个或多个只读子任务委派给专门角色，返回各自结论；互不依赖的子任务用 tasks 并行。",
        parameters: [
            "type": "object",
            "properties": [
                "role": [
                    "type": "string",
                    "enum": ["librarian", "curator", "cinemaManager"],
                    "description": "单任务时的角色：librarian=图库馆员，curator=策展，cinemaManager=影院管理员"
                ] as [String: Any],
                "task": [
                    "type": "string",
                    "description": "单任务时的只读子任务，尽量具体"
                ] as [String: Any],
                "tasks": [
                    "type": "array",
                    "description": "并行子任务，最多 3 个；彼此不依赖时使用",
                    "maxItems": 3,
                    "items": [
                        "type": "object",
                        "properties": [
                            "role": [
                                "type": "string",
                                "enum": ["librarian", "curator", "cinemaManager"]
                            ] as [String: Any],
                            "task": ["type": "string"] as [String: Any]
                        ] as [String: Any],
                        "required": ["role", "task"]
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any],
            "required": [] as [String]
        ]
    )

    fileprivate struct AISubAgentOutcome: Sendable {
        let role: AIAgentRole
        let task: String
        let summary: String?
        let error: String?
    }

    /// 解析单任务与并行任务两种写法，最多 3 个。
    private func aiDelegationSpecs(from args: [String: Any]) -> [(role: AIAgentRole, task: String)] {
        var specs: [(AIAgentRole, String)] = []
        if let raw = args["tasks"] as? [[String: Any]] {
            for item in raw.prefix(3) {
                let role = AIAgentRole(rawValue: (item["role"] as? String) ?? "librarian") ?? .librarian
                let task = ((item["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !task.isEmpty, role != .auto { specs.append((role, task)) }
            }
        }
        if specs.isEmpty {
            let role = AIAgentRole(rawValue: (args["role"] as? String) ?? "librarian") ?? .librarian
            let task = ((args["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !task.isEmpty, role != .auto { specs.append((role, task)) }
        }
        return specs
    }

    private func aiRoutingArea(for role: AIAgentRole) -> String {
        switch role {
        case .cinemaManager: return "cinema"
        case .librarian, .curator: return "library"
        case .auto: return aiAreaName
        }
    }

    /// 子 Agent：固定的角色提示词 + 角色边界内的只读工具，最多 4 轮。
    private func runSubAIAgent(role: AIAgentRole,
                               task: String,
                               config: AIConfig,
                               key: String,
                               contextText: String) async throws -> String {
        let provider = AIChatProviderFactory.make(config: config)
        let roleTools = aiToolDefinitions.filter {
            role.allows(toolName: $0.name)
                && !AILibraryTools.isWrite($0.name)
                && $0.name != "delegate_agent"
        }
        let routed = AIToolRouter.select(question: task,
                                         area: aiRoutingArea(for: role),
                                         definitions: roleTools,
                                         limit: 12)
        let tools = routed.isEmpty ? Array(roleTools.prefix(12)) : routed

        let system = AILibraryContext.systemPrompt + "\n\n" + role.systemAddition
            + "\n\n你是被主助手委派的只读子 Agent：只完成这一个子任务，不做任何写操作；"
            + "最后用一到两句话汇报结论与关键数量。"
        var wire: [AIRequestMessage] = [
            AIRequestMessage(role: "system", text: system),
            AIRequestMessage(role: "user", text: "【当前上下文】\n\(contextText)\n\n【子任务】\(task)")
        ]

        var rounds = 0
        while rounds < 4 {
            if Task.isCancelled { throw AIError.cancelled }
            let completion = try await provider.complete(AIChatRequest(config: config,
                                                                       apiKey: key,
                                                                       messages: wire,
                                                                       tools: tools))
            guard !completion.toolCalls.isEmpty else {
                let text = completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "子助手没有给出结论。" : text
            }
            wire.append(AIRequestMessage(role: "assistant",
                                         text: completion.content,
                                         toolCalls: completion.toolCalls))
            for call in completion.toolCalls {
                guard tools.contains(where: { $0.name == call.name }),
                      !AILibraryTools.isWrite(call.name) else {
                    wire.append(AIRequestMessage(
                        role: "tool",
                        text: "{\"ok\":false,\"error\":\"子助手只允许使用列出的只读工具\"}",
                        toolCallID: call.id
                    ))
                    continue
                }
                let result = await executeAITool(call)
                wire.append(AIRequestMessage(role: "tool",
                                             text: result.json,
                                             toolCallID: call.id))
            }
            rounds += 1
        }
        return "子助手达到步数上限，未给出最终结论。"
    }

    // MARK: - 流式

    private func streamCompletion(provider: AIChatProvider,
                                  config: AIConfig,
                                  key: String,
                                  wire: [AIRequestMessage],
                                  tools: [AIRequestTool]) async throws -> AICompletion {
        aiStreamingText = ""
        aiStreamingReasoning = ""
        let request = AIChatRequest(config: config, apiKey: key, messages: wire, tools: tools)
        var streamed = ""
        var thinking = ""
        var collected: [AIToolCall] = []
        var finished: AICompletion?
        for try await event in provider.stream(request) {
            if Task.isCancelled { throw AIError.cancelled }
            switch event {
            case .text(let piece):
                streamed += piece
                aiStreamingText = streamed
                if aiTaskRecords.first(where: { $0.id == aiCurrentTaskID })?.firstTokenMs == nil {
                    markAIFirstToken()
                }
            case .reasoning(let piece):
                thinking += piece
                aiStreamingReasoning = thinking
            case .toolCall(let call):
                collected.append(call)
            case .finished(let completion):
                finished = completion
            }
        }
        if var finished {
            if finished.reasoning == nil, !thinking.isEmpty {
                finished.reasoning = thinking
            }
            return finished
        }
        return AICompletion(content: streamed.trimmingCharacters(in: .whitespacesAndNewlines),
                            toolCalls: collected,
                            reasoning: thinking.isEmpty ? nil : thinking)
    }

    // MARK: - 计划

    private func makePlan(question: String,
                          promptText: String,
                          config: AIConfig,
                          key: String) async throws -> AIPlan? {
        let provider = AIChatProviderFactory.make(config: config)
        let request = AIChatRequest(
            config: config,
            apiKey: key,
            messages: [
                AIRequestMessage(role: "system", text: Self.planningPrompt),
                AIRequestMessage(role: "user", text: promptText)
            ]
        )
        let completion = try await provider.complete(request)
        guard let payload = Self.decodePlan(completion.content) else { return nil }
        guard payload.steps.count >= 2 else { return nil }
        let steps = payload.steps.prefix(8).map { draft in
            AIPlanStep(title: draft.title,
                       detail: draft.detail ?? "",
                       tool: draft.tool,
                       risk: Self.parseRisk(draft.risk))
        }
        let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIPlan(summary: (summary?.isEmpty == false ? summary! : question),
                      steps: Array(steps))
    }

    private func awaitPlanDecision() async -> AIPlanStatus {
        await withCheckedContinuation { continuation in
            aiPlanContinuation?.resume(returning: .cancelled)
            aiPlanContinuation = continuation
        }
    }

    func approveAIPlan() {
        guard let plan = aiPendingPlan else { return }
        updatePlanMessageStatus(plan.id, status: .approved, text: "计划已批准，开始执行。")
        aiPlanContinuation?.resume(returning: .approved)
        aiPlanContinuation = nil
    }

    func cancelAIPlan() {
        guard let plan = aiPendingPlan else { return }
        updatePlanMessageStatus(plan.id, status: .cancelled, text: "计划已取消，本次没有执行任何操作。")
        aiPlanContinuation?.resume(returning: .cancelled)
        aiPlanContinuation = nil
    }

    /// 「调整计划」：取消当前计划，把摘要放回输入框，用户改完再发。
    func adjustAIPlan() {
        guard let plan = aiPendingPlan else { return }
        let draft = "请调整这个计划：\(plan.summary)\n当前步骤："
            + plan.steps.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "；")
            + "。请只输出新的计划 JSON。"
        cancelAIPlan()
        aiInput = draft
        aiFocusRequest &+= 1
    }

    private func updatePlanMessageStatus(_ planID: UUID,
                                         status: AIPlanStatus,
                                         text: String? = nil) {
        guard let index = aiMessages.firstIndex(where: { $0.plan?.id == planID }) else { return }
        aiMessages[index].plan?.status = status
        if let text { aiMessages[index].text = text }
        saveAIConversation()
    }

    // MARK: - 审批

    private func requestAIApproval(for calls: [AIToolCall]) async -> Set<String> {
        let allIDs = Set(calls.map(\.id))
        if aiBackgroundRun {
            // 定时任务无人值守：写操作一律跳过，等人回来看结果再决定。
            aiMessages.append(AIChatMessage(role: .action,
                                            text: "定时任务只执行只读步骤；写操作已跳过，需要你确认后手动执行。"))
            saveAIConversation()
            return []
        }
        if aiTaskAutoApproveWrites || aiConfig.approval == .automatic {
            return allIDs
        }
        if aiAutoMatchCinema {
            let cinemaWrites: Set<String> = ["scrape_cinema", "match_cinema", "apply_cinema_match"]
            if calls.allSatisfy({ cinemaWrites.contains($0.name) }) { return allIDs }
        }

        let needsApproval: [AIToolCall]
        let alwaysAllowed = Set(aiAlwaysAllowedTools)
        switch aiConfig.approval {
        case .always:
            needsApproval = calls.filter { call in
                !(Self.aiToolIsRememberable(call.name) && alwaysAllowed.contains(call.name))
            }
        case .smart:
            needsApproval = calls.filter { call in
                // 已「始终允许」的可逆写直接放行；外部连接器与高风险仍然确认。
                if Self.aiToolIsRememberable(call.name), alwaysAllowed.contains(call.name) {
                    return false
                }
                // 外部连接器不可预知副作用，智能模式也逐次确认。
                return call.name.hasPrefix("mcp__")
                    || AILibraryTools.risk(for: call.name,
                                           arguments: AILibraryTools.arguments(call.arguments)) == .destructive
            }
        case .automatic:
            needsApproval = []
        }
        guard !needsApproval.isEmpty else { return allIDs }

        let items = needsApproval.map { call -> AIApprovalItem in
            let args = AILibraryTools.arguments(call.arguments)
            let risk = AILibraryTools.risk(for: call.name, arguments: args)
            let preview = aiApprovalPreview(for: call, args: args)
            return AIApprovalItem(id: call.id,
                                  title: AILibraryTools.describe(call),
                                  detail: preview.isEmpty ? risk.title : "\(risk.title) · \(preview)",
                                  risk: risk)
        }
        let memorable = needsApproval
            .map(\.name)
            .filter { Self.aiToolIsRememberable($0) }
        noteAIApprovalPrompt()
        let request = AIApprovalRequest(
            title: items.contains(where: { $0.risk == .destructive })
                ? "智能助手准备执行高风险操作"
                : "智能助手准备修改本地数据",
            summary: items.count > 1 ? "本轮共 \(items.count) 个写操作，合并为一次确认。" : "",
            items: items,
            toolNames: needsApproval.map(\.name),
            memorableToolNames: Array(Set(memorable)).sorted()
        )
        aiPendingApproval = request
        let decision = await withCheckedContinuation { continuation in
            aiApprovalContinuation?.resume(returning: .deny)
            aiApprovalContinuation = continuation
        }
        aiPendingApproval = nil
        switch decision {
        case .allowOnce:
            return allIDs
        case .allowTask:
            aiTaskAutoApproveWrites = true
            return allIDs
        case .allowAlways:
            rememberAlwaysAllowed(Array(Set(memorable)))
            return allIDs
        case .deny:
            return []
        }
    }

    func resolveAIApproval(_ decision: AIApprovalDecision) {
        aiPendingApproval = nil
        aiApprovalContinuation?.resume(returning: decision)
        aiApprovalContinuation = nil
    }

    /// 审批卡的轻量 diff：字段级前后值 + 受影响的前几项名称。
    private func aiApprovalPreview(for call: AIToolCall, args: [String: Any]) -> String {
        let rawIDs = AILibraryTools.stringArray(args["photo_ids"])
        let ids = Set(rawIDs.compactMap { UUID(uuidString: $0) })
        if !ids.isEmpty {
            let targets = ids.compactMap { anyPhoto(id: $0) }

            switch call.name {
            case "set_rating":
                let new = AILibraryTools.integer(args["rating"], fallback: 0)
                let old = Set(targets.map { $0.rating ?? 0 }).sorted()
                    .map { "\($0)★" }.joined(separator: " / ")
                return "\(old.isEmpty ? "未评分" : old) → \(new)★ · \(ids.count) 项"

            case "set_flag":
                let raw = AILibraryTools.string(args["flag"]) ?? "none"
                let new = PhotoFlag(rawValue: raw)?.title ?? "无"
                let old = Set(targets.map { $0.flag?.title ?? "无" }).sorted().joined(separator: " / ")
                return "\(old.isEmpty ? "无" : old) → \(new) · \(ids.count) 项"

            case "set_color_label":
                let raw = AILibraryTools.string(args["label"]) ?? "none"
                let new = PhotoColorLabel(rawValue: raw)?.title ?? "无"
                let old = Set(targets.map { $0.colorLabel?.title ?? "无" }).sorted().joined(separator: " / ")
                return "\(old.isEmpty ? "无" : old) → \(new) · \(ids.count) 项"

            case "set_favorite":
                let new = AILibraryTools.bool(args["favorite"], fallback: true)
                let old = Set(targets.map { $0.isFavorite ? "已收藏" : "未收藏" }).sorted().joined(separator: " / ")
                return "\(old.isEmpty ? "未收藏" : old) → \(new ? "已收藏" : "未收藏") · \(ids.count) 项"

            case "set_hidden":
                let new = AILibraryTools.bool(args["hidden"], fallback: true)
                let old = Set(targets.map { $0.isHidden ? "已隐藏" : "可见" }).sorted().joined(separator: " / ")
                return "\(old.isEmpty ? "可见" : old) → \(new ? "已隐藏" : "可见") · \(ids.count) 项"

            case "set_title":
                let new = (args["title"] as? String) ?? ""
                let old = Set(targets.map { ($0.title?.isEmpty == false ? $0.title! : "无标题") })
                    .sorted().prefix(3).joined(separator: " / ")
                return "标题：\(old.isEmpty ? "无标题" : old) → 「\(new)」 · \(ids.count) 项"

            case "add_keywords":
                let list = AILibraryTools.stringArray(args["keywords"]).prefix(3).joined(separator: "、")
                return "关键词 +\(list) · \(ids.count) 项"

            case "remove_keywords":
                let list = AILibraryTools.stringArray(args["keywords"]).prefix(3).joined(separator: "、")
                return "关键词 −\(list) · \(ids.count) 项"

            default:
                break
            }

            let names = targets.prefix(3).map(\.displayFilename)
            if !names.isEmpty {
                return names.joined(separator: "、")
                    + (ids.count > names.count ? " 等 \(ids.count) 项" : "")
            }
        }
        if let album = AILibraryTools.string(args["album_name"]) {
            return "相簿「\(album)」"
        }
        if let specs = args["albums"] as? [[String: Any]] {
            let names = specs.compactMap { AILibraryTools.string($0["name"]) }.prefix(4)
            if !names.isEmpty { return names.joined(separator: "、") }
        }
        return ""
    }

    // MARK: - 工具时间线

    @discardableResult
    private func appendToolStep(title: String,
                                detail: String,
                                status: AIToolStepStatus) -> UUID {
        let step = AIToolStep(title: title, detail: detail, status: status)
        aiToolSteps.append(step)
        return step.id
    }

    private func finishToolStep(_ id: UUID,
                                status: AIToolStepStatus,
                                detail: String) {
        guard let index = aiToolSteps.firstIndex(where: { $0.id == id }) else { return }
        aiToolSteps[index].status = status
        aiToolSteps[index].detail = detail
        aiToolSteps[index].duration = Date().timeIntervalSince(aiToolSteps[index].startedAt)
    }

    // MARK: - 辅助

    private func appendAIAssistantMessage(_ text: String,
                                          taskID: UUID,
                                          startedAt: Date,
                                          toolRounds: Int) {
        aiMessages.append(AIChatMessage(role: .assistant,
                                        text: text,
                                        elapsed: Date().timeIntervalSince(startedAt),
                                        toolSteps: toolRounds,
                                        taskID: taskID))
        saveAIConversation()
    }

    private func aiCandidatePhotosRespectingMute(limit: Int) -> [PhotoItem] {
        guard !isAIContextEnabled(.selection) else {
            return aiCandidatePhotos(limit: limit)
        }
        var result: [PhotoItem] = []
        let source = isCloudScope ? cloudVisiblePhotos : visiblePhotos
        for photo in source.prefix(limit) {
            result.append(photo)
        }
        return result
    }

    private var aiAreaName: String {
        switch sidebarItem {
        case .iptv: return "tv"
        case .networkCinema: return "networkCinema"
        case .cinema, .cloudCinema: return "cinema"
        case .catalogSources, .catalogSource: return "catalog"
        case .atlas: return "atlas"
        default: return "library"
        }
    }

    private static func toolResultOK(_ result: AIToolExecution) -> Bool {
        guard let data = result.json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        return (root["ok"] as? Bool) != false
    }

    private static func shouldPlan(_ text: String) -> Bool {
        if isKnowledgeQuestion(text) {
            return false
        }
        let triggers = ["按月", "按年", "按地点", "按人物", "按日期", "按时间",
                        "所有", "全部", "批量", "整个", "逐个",
                        "整理", "清理", "刮削", "体检", "日报", "旅行", "回忆", "生成"]
        return triggers.contains { text.contains($0) }
    }

    /// 纯知识问答没必要先出计划：计划模式只对「要做点什么」的请求生效。
    private static func isKnowledgeQuestion(_ text: String) -> Bool {
        ["怎么", "如何", "为什么", "是什么", "介绍", "区别", "能不能", "可以吗"]
            .contains { text.contains($0) }
    }

    private static func hasActionIntent(_ text: String) -> Bool {
        AIActionIntent.hasIntent(text)
    }

    private static func parseRisk(_ raw: String?) -> AIRiskLevel {
        switch (raw ?? "").lowercased() {
        case "read", "readonly", "只读": return .read
        case "reversible", "write", "可逆": return .reversible
        case "destructive", "high", "高风险": return .destructive
        case "external", "外部": return .external
        default: return .read
        }
    }

    private static func decodePlan(_ raw: String) -> AIPlanDraft? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}") else { return nil }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIPlanDraft.self, from: data)
    }

    private static let planningPrompt = """
    你是拾光的任务规划器。根据用户请求与图库快照，输出一个可执行计划。
    只输出 JSON，不要 Markdown，不要解释：
    {"summary":"一句话目标","steps":[{"title":"步骤标题","detail":"做什么、影响多少","tool":"工具名，可省略","risk":"read|reversible|destructive|external"}]}
    规则：
    - 最多 8 步；只读步骤在前，写操作在后。
    - risk 必须保守：删除、压缩原文件、批量刮削用 destructive；请求站点或播放用 external；普通标记与相簿操作用 reversible。
    - 不确定时不要编造工具名，可以只写步骤标题。
    - 如果任务只需一步，仍然输出单步计划。
    """
}

private struct AIPlanDraft: Decodable {
    var summary: String?
    var steps: [AIPlanStepDraft]
}

private struct AIPlanStepDraft: Decodable {
    var title: String
    var detail: String?
    var tool: String?
    var risk: String?
}
