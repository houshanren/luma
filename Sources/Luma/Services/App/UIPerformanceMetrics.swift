import Foundation

/// 一次图像加载采样：缩略图、快速层与海报都写进同一份记录，
/// 基准结束后按 kind / tier 聚合出 p50 / p95。
struct UIImageLoadSample: Sendable {
    enum Tier: String, Sendable {
        case quick
        case target
        case poster
    }

    let kind: String
    let tier: Tier
    let seconds: Double
    let success: Bool

    var key: String { "\(kind).\(tier.rawValue)" }
}

/// 线程安全的图像加载采样器：加载发生在主线程与后台 Task，基准只在收集窗口内取样。
final class UIPerformanceMetrics: @unchecked Sendable {
    static let shared = UIPerformanceMetrics()

    private let lock = NSLock()
    private var collecting = false
    private var samples: [UIImageLoadSample] = []
    /// 防止异常长窗口把内存撑爆；正常一次滚动只有几百到几千次加载。
    private let sampleLimit = 50_000

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        collecting = true
        lock.unlock()
    }

    func end() -> [UIImageLoadSample] {
        lock.lock()
        collecting = false
        let result = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }

    func record(kind: String, tier: UIImageLoadSample.Tier,
                seconds: Double, success: Bool) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.lock()
        if collecting, samples.count < sampleLimit {
            samples.append(UIImageLoadSample(kind: kind, tier: tier,
                                             seconds: seconds, success: success))
        }
        lock.unlock()
    }
}
