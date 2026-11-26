import AppKit

/// 导入向导里的候选项目：预览封面属于展示层数据，不放进领域模型。
struct ImportCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileCount: Int
    let cover: NSImage?
    let previewURLs: [URL]
}
