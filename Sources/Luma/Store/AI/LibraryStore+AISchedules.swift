import Foundation

/// 定时任务：按天 / 按周自动跑一轮助手任务。
/// 后台只执行只读步骤；需要写入时直接跳过，等人回来看结果再确认。
extension LibraryStore {
    private var aiScheduleFileURL: URL {
        let dir = LibraryPaths.overlayRoot.appendingPathComponent("ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedules.json")
    }

    // MARK: - 持久化

    func loadAISchedules() {
        aiScheduleTicker?.cancel()
        aiScheduleTicker = nil
        guard let data = try? Data(contentsOf: aiScheduleFileURL),
              let decoded = try? JSONDecoder().decode([AIScheduledTask].self, from: data) else {
            aiSchedules = []
            return
        }
        let now = Date()
        aiSchedules = decoded.map { task in
            var copy = task
            if copy.isEnabled, copy.nextRunAt == nil || (copy.nextRunAt ?? now) < now {
                copy.nextRunAt = copy.nextRun(after: now)
            }
            return copy
        }
        persistAISchedules()
        startAIScheduleTicker()
    }

    func persistAISchedules() {
        guard let data = try? JSONEncoder().encode(aiSchedules) else { return }
        try? data.write(to: aiScheduleFileURL, options: .atomic)
    }

    // MARK: - 管理

    @discardableResult
    func addAISchedule(title: String,
                       prompt: String,
                       cadence: AIScheduleCadence,
                       hour: Int,
                       minute: Int,
                       weekday: Int) -> AIScheduledTask? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedPrompt.isEmpty else { return nil }
        var task = AIScheduledTask(title: trimmedTitle,
                                   prompt: trimmedPrompt,
                                   cadence: cadence,
                                   hour: hour,
                                   minute: minute,
                                   weekday: weekday)
        task.nextRunAt = task.nextRun(after: Date())
        aiSchedules.append(task)
        persistAISchedules()
        startAIScheduleTicker()
        return task
    }

    func updateAISchedule(_ task: AIScheduledTask) {
        guard let index = aiSchedules.firstIndex(where: { $0.id == task.id }) else { return }
        var copy = task
        copy.nextRunAt = copy.nextRun(after: Date())
        aiSchedules[index] = copy
        persistAISchedules()
        startAIScheduleTicker()
    }

    func removeAISchedule(_ id: UUID) {
        aiSchedules.removeAll { $0.id == id }
        persistAISchedules()
        startAIScheduleTicker()
    }

    func toggleAISchedule(_ id: UUID) {
        guard let index = aiSchedules.firstIndex(where: { $0.id == id }) else { return }
        aiSchedules[index].isEnabled.toggle()
        if aiSchedules[index].isEnabled {
            aiSchedules[index].nextRunAt = aiSchedules[index].nextRun(after: Date())
        }
        persistAISchedules()
        startAIScheduleTicker()
    }

    /// 手动「立即运行」：不改变周期，只跑一次。
    func runAIScheduleNow(_ id: UUID) {
        Task { await executeAISchedule(id) }
    }

    // MARK: - 运行

    func startAIScheduleTicker() {
        aiScheduleTicker?.cancel()
        aiScheduleTicker = nil
        guard aiSchedules.contains(where: \.isEnabled) else { return }
        aiScheduleTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.runDueAISchedules()
            }
        }
    }

    private func runDueAISchedules() async {
        guard !aiIsResponding, !aiBackgroundRun else { return }
        let now = Date()
        guard let due = aiSchedules.first(where: {
            $0.isEnabled && ($0.nextRunAt ?? Date.distantPast) <= now
        }) else { return }
        await executeAISchedule(due.id)
    }

    func executeAISchedule(_ id: UUID) async {
        guard let index = aiSchedules.firstIndex(where: { $0.id == id }) else { return }
        guard !aiIsResponding else {
            showToast("助手正在处理另一个任务，稍后再跑定时任务")
            return
        }
        guard aiConfigurationReady, aiHasAPIKey else {
            aiSchedules[index].lastStatus = "未配置模型"
            persistAISchedules()
            return
        }

        let task = aiSchedules[index]
        // 先排下一次：即使这次失败也不会每分钟重复触发。
        aiSchedules[index].lastRunAt = Date()
        aiSchedules[index].nextRunAt = task.nextRun(after: Date())
        aiSchedules[index].lastStatus = "运行中…"
        persistAISchedules()

        aiBackgroundRun = true
        aiInput = "⏰ \(task.title)：\(task.prompt)"
        sendAIMessage()

        // sendAIMessage 启动的是独立任务：等它收尾再写回结果。
        while aiIsResponding {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { break }
        }
        aiBackgroundRun = false

        guard let updated = aiSchedules.firstIndex(where: { $0.id == id }) else { return }
        aiSchedules[updated].lastRunAt = Date()
        if let error = aiError, !error.isEmpty {
            aiSchedules[updated].lastStatus = "失败：\(error)"
        } else {
            aiSchedules[updated].lastStatus = "已完成"
        }
        persistAISchedules()
    }
}
