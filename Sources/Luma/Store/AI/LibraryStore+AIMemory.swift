import Foundation

extension LibraryStore {
    private var aiMemoryFileURL: URL {
        let dir = LibraryPaths.overlayRoot.appendingPathComponent("ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }

    func loadAIMemory() {
        guard let data = try? Data(contentsOf: aiMemoryFileURL),
              let decoded = try? JSONDecoder().decode([AIMemoryNote].self, from: data) else {
            aiMemories = []
            return
        }
        aiMemories = decoded
    }

    func persistAIMemory() {
        guard let data = try? JSONEncoder().encode(aiMemories) else { return }
        try? data.write(to: aiMemoryFileURL, options: .atomic)
    }

    /// 加一条偏好：去重、限长、限条数，避免记忆变成第二份提示词。
    func addAIMemory(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !aiMemories.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else {
            showToast("这条偏好已经记住了")
            return
        }
        let prefix = String(text.prefix(200))
        var note = AIMemoryNote(text: prefix)
        note.createdAt = Date()
        note.updatedAt = Date()
        aiMemories.insert(note, at: 0)
        if aiMemories.count > 20 {
            aiMemories = Array(aiMemories.prefix(20))
        }
        persistAIMemory()
        aiMemoryDraft = ""
    }

    func removeAIMemory(_ note: AIMemoryNote) {
        aiMemories.removeAll { $0.id == note.id }
        persistAIMemory()
    }

    func toggleAIMemory(_ note: AIMemoryNote) {
        guard let index = aiMemories.firstIndex(where: { $0.id == note.id }) else { return }
        aiMemories[index].isEnabled.toggle()
        aiMemories[index].updatedAt = Date()
        persistAIMemory()
    }

    /// 注入系统提示词的长期偏好：只作为偏好，不覆盖用户当前指令。
    func aiMemoryPrompt() -> String {
        let lines = aiMemories
            .filter { $0.isEnabled }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
            .map { "- \($0)" }
        return lines.joined(separator: "\n")
    }
}
