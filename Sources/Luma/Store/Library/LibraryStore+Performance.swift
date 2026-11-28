import Foundation

/// 大图库自查：手动触发，测几个最常走的全量路径，结果写进日志。
/// 只做测量，不缓存、不改数据；用户点一次才有开销。
struct LibraryPerformanceSample: Identifiable {
    let name: String
    let milliseconds: Double
    let detail: String
    var id: String { name }
}

struct LibraryPerformanceReport: Identifiable {
    let id = UUID()
    let sampledAt: Date
    let photoCount: Int
    let samples: [LibraryPerformanceSample]

    var slowest: LibraryPerformanceSample? {
        samples.max { $0.milliseconds < $1.milliseconds }
    }

    /// 粗分档：任何一项超过 800ms 就算偏慢，超过 300ms 算一般。
    var verdict: String {
        guard let slowest else { return "没有可测项目" }
        if slowest.milliseconds >= 800 { return "偏慢：\(slowest.name)" }
        if slowest.milliseconds >= 300 { return "一般：\(slowest.name)" }
        return "良好"
    }
}

extension LibraryStore {
    /// 测量顺序固定，便于前后对比：
    /// 关键词表 → 全量搜索 → 重复分组 → 当前范围筛选。
    func measurePerformance() -> LibraryPerformanceReport {
        var samples: [LibraryPerformanceSample] = []

        var start = Date()
        let keywords = keywordOptions
        samples.append(LibraryPerformanceSample(
            name: "关键词表",
            milliseconds: Date().timeIntervalSince(start) * 1000,
            detail: "\(keywords.count) 个关键词"
        ))

        start = Date()
        let query = currentSearchQuery
        let matched = photos.filter { matchesSearch($0, query: query) }.count
        samples.append(LibraryPerformanceSample(
            name: "全量搜索",
            milliseconds: Date().timeIntervalSince(start) * 1000,
            detail: query.isEmpty ? "空条件 · 命中 \(matched) 项" : "命中 \(matched) 项"
        ))

        start = Date()
        let duplicateCount = DuplicateDetector.groups(from: photos).count
        samples.append(LibraryPerformanceSample(
            name: "重复分组",
            milliseconds: Date().timeIntervalSince(start) * 1000,
            detail: "\(duplicateCount) 组"
        ))

        start = Date()
        let visible = visiblePhotos.count
        samples.append(LibraryPerformanceSample(
            name: "当前范围筛选",
            milliseconds: Date().timeIntervalSince(start) * 1000,
            detail: "\(visible) 项"
        ))

        let report = LibraryPerformanceReport(sampledAt: Date(),
                                              photoCount: photos.count,
                                              samples: samples)
        let summary = samples
            .map { "\($0.name) \(Int($0.milliseconds.rounded()))ms" }
            .joined(separator: "，")
        Diagnostics.record("性能自查：\(photos.count) 项 · \(summary) · \(report.verdict)",
                           level: .standard)
        return report
    }
}
