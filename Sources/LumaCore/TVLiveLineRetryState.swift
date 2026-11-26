import Foundation

/// 网络电视直播固定线路目录的一次失败处理结果。
public enum TVLiveLineRetryFailure: Equatable {
    /// 当前线路已有效失败，应切换到返回的下一条线路。
    case next(URL: String)
    /// 装片 token 与最近一次有效失败相同，本次重复回调已忽略。
    case ignored
    /// 所有线路均已尝试完指定轮数，没有下一条线路。
    case exhausted
}

/// 按固定线路目录循环、包含首次尝试在内的多轮失败重试状态。
public struct TVLiveLineRetryState {
    /// 按输入出现顺序去重后的固定线路目录。
    public let lines: [String]
    /// 每条线路参与的最大轮数，包含首次尝试。
    public let maxRounds: Int
    /// 已处理的有效失败次数，重复 token 不计入。
    public private(set) var failureCount: Int
    /// 最近一次有效失败对应的装片 token。
    public private(set) var lastFailureToken: String?
    /// 当前应尝试的线路；目录为空或重试耗尽时为 nil。
    public private(set) var currentURL: String?

    private var currentIndex: Int

    /// 创建固定目录重试状态；首选线路无效或缺失时从首条线路开始。
    public init(lines: [String], startURL: String? = nil, maxRounds: Int = 3) {
        precondition(maxRounds > 0, "重试轮数必须大于零")

        var seen = Set<String>()
        let uniqueLines = lines.filter { seen.insert($0).inserted }
        self.lines = uniqueLines
        self.maxRounds = maxRounds
        self.failureCount = 0
        self.lastFailureToken = nil

        if let startURL, let index = uniqueLines.firstIndex(of: startURL) {
            self.currentIndex = index
        } else {
            self.currentIndex = 0
        }
        self.currentURL = uniqueLines.isEmpty ? nil : uniqueLines[currentIndex]
    }

    /// 记录一次装片失败；有效失败会推进固定目录，重复 token 不会改变状态。
    public mutating func recordFailure(token: String) -> TVLiveLineRetryFailure {
        if token == lastFailureToken {
            return .ignored
        }
        guard currentURL != nil else {
            return .exhausted
        }

        lastFailureToken = token
        failureCount += 1

        if failureCount >= lines.count * maxRounds {
            currentURL = nil
            return .exhausted
        }

        currentIndex = (currentIndex + 1) % lines.count
        let nextURL = lines[currentIndex]
        currentURL = nextURL
        return .next(URL: nextURL)
    }
}
