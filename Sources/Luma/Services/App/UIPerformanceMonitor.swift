import AppKit
import QuartzCore

/// 一次自动滚动的帧采样结果。所有时间单位在字段名里标明，避免报告里混淆秒与毫秒。
struct UIPerformancePassReport: Codable {
    var label: String
    var seconds: Double
    var frames: Int
    var fps: Double
    var expectedFrameMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var p99Ms: Double
    var maxMs: Double
    var slowFrameCount: Int
    var slowFrameRatio: Double
    var estimatedDroppedFrames: Int
    var documentHeight: Double
    var viewportHeight: Double
    var startOffset: Double
    var endOffset: Double
}

/// 用 CADisplayLink 采样真实刷新节奏，并在每个回调里推进底层 NSScrollView，
/// 让 SwiftUI 网格 / 海报墙按正常滚动路径创建、复用与加载图片。
@MainActor
final class UIPerformanceMonitor: NSObject {
    static let shared = UIPerformanceMonitor()

    private var link: CADisplayLink?
    private weak var scrollView: NSScrollView?
    private var lastTimestamp: CFTimeInterval = 0
    private var startTimestamp: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var velocity: CGFloat = 0
    private var intervals: [Double] = []
    private var expectedInterval: Double = 1.0 / 60.0
    private var completion: ((UIPerformancePassReport) -> Void)?
    private var label = ""
    private var startOffset: CGFloat = 0
    private var endOffset: CGFloat = 0

    func run(scrollView: NSScrollView,
             label: String,
             seconds: TimeInterval,
             velocity: CGFloat = 1_800) async -> UIPerformancePassReport {
        await withCheckedContinuation { continuation in
            start(scrollView: scrollView, label: label, seconds: seconds,
                  velocity: velocity) { report in
                continuation.resume(returning: report)
            }
        }
    }

    private func start(scrollView: NSScrollView,
                       label: String,
                       seconds: TimeInterval,
                       velocity: CGFloat,
                       completion: @escaping (UIPerformancePassReport) -> Void) {
        link?.invalidate()
        link = nil

        guard let view = scrollView.window?.contentView else {
            completion(Self.emptyReport(label: label, seconds: seconds))
            return
        }
        self.scrollView = scrollView
        self.label = label
        self.duration = max(0.5, seconds)
        self.velocity = velocity
        self.completion = completion
        self.intervals.removeAll(keepingCapacity: true)
        self.lastTimestamp = 0
        self.startTimestamp = 0
        self.expectedInterval = 1.0 / 60.0
        self.startOffset = scrollView.contentView.bounds.origin.y
        self.endOffset = startOffset

        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp == 0 {
            lastTimestamp = now
            startTimestamp = now
            if link.duration > 0 { expectedInterval = link.duration }
            return
        }
        let interval = now - lastTimestamp
        lastTimestamp = now
        if interval > 0 { intervals.append(interval) }

        advanceScroll(by: min(max(interval, 0), 0.1))

        if now - startTimestamp >= duration {
            finish(link: link)
        }
    }

    private func advanceScroll(by dt: Double) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let bounds = clip.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, documentHeight - bounds.height)
        guard maxY > 1 else { return }
        var y = bounds.origin.y + velocity * CGFloat(dt)
        // 循环回顶部：持续滚动才有新格子进入可视区，避免停在片尾后没有渲染负载。
        if y >= maxY { y = 0 }
        clip.scroll(to: NSPoint(x: bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        endOffset = y
    }

    private func finish(link: CADisplayLink) {
        link.invalidate()
        self.link = nil
        let elapsed = max(0.001, lastTimestamp - startTimestamp)
        let documentHeight = scrollView?.documentView?.frame.height ?? 0
        let viewportHeight = scrollView?.contentView.bounds.height ?? 0
        let expected = expectedInterval > 0 ? expectedInterval : 1.0 / 60.0
        let slowThreshold = max(expected * 1.5, 0.024)
        let sorted = intervals.sorted()
        let slowFrames = intervals.filter { $0 > slowThreshold }.count
        let dropped = intervals.reduce(0) { partial, interval in
            partial + max(0, Int((interval / expected).rounded()) - 1)
        }
        let report = UIPerformancePassReport(
            label: label,
            seconds: elapsed,
            frames: intervals.count,
            fps: Double(intervals.count) / elapsed,
            expectedFrameMs: expected * 1_000,
            p50Ms: Self.percentile(sorted, 50) * 1_000,
            p95Ms: Self.percentile(sorted, 95) * 1_000,
            p99Ms: Self.percentile(sorted, 99) * 1_000,
            maxMs: (sorted.last ?? 0) * 1_000,
            slowFrameCount: slowFrames,
            slowFrameRatio: intervals.isEmpty ? 0 : Double(slowFrames) / Double(intervals.count),
            estimatedDroppedFrames: dropped,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight,
            startOffset: startOffset,
            endOffset: endOffset
        )
        completion?(report)
        completion = nil
        scrollView = nil
    }

    private static func emptyReport(label: String, seconds: TimeInterval) -> UIPerformancePassReport {
        UIPerformancePassReport(label: label, seconds: seconds, frames: 0, fps: 0,
                                expectedFrameMs: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0, maxMs: 0,
                                slowFrameCount: 0, slowFrameRatio: 0,
                                estimatedDroppedFrames: 0, documentHeight: 0,
                                viewportHeight: 0, startOffset: 0, endOffset: 0)
    }

    /// 与 playbook 报表一致的分位数口径：向上取整到第 n 个样本。
    private static func percentile(_ sorted: [Double], _ pct: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(0, min(sorted.count - 1, Int(ceil(pct / 100 * Double(sorted.count))) - 1))
        return sorted[index]
    }
}
