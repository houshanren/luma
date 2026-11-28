import Foundation

package enum AIScheduleCadence: String, Codable, CaseIterable, Identifiable {
    case daily
    case weekly

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .daily: return "每天"
        case .weekly: return "每周"
        }
    }
}

/// 一条定时任务：到点自动跑一轮只读助手任务，结果留在对话里。
/// 写操作不会被后台自动执行，必须等人回来确认。
package struct AIScheduledTask: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var title: String
    package var prompt: String
    package var cadence: AIScheduleCadence = .daily
    /// 0–23。
    package var hour = 9
    /// 0–59。
    package var minute = 0
    /// 1 = 周一 … 7 = 周日；仅 weekly 使用。
    package var weekday = 1
    package var isEnabled = true
    package var lastRunAt: Date?
    package var nextRunAt: Date?
    package var lastStatus = ""

    package init(title: String,
                 prompt: String,
                 cadence: AIScheduleCadence = .daily,
                 hour: Int = 9,
                 minute: Int = 0,
                 weekday: Int = 1,
                 isEnabled: Bool = true) {
        self.title = title
        self.prompt = prompt
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.isEnabled = isEnabled
        self.nextRunAt = nextRun(after: Date())
    }

    /// 下一次触发时间；已过今天的点就顺延到下一个周期。
    package func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = min(23, max(0, hour))
        components.minute = min(59, max(0, minute))
        if cadence == .weekly {
            let clamped = min(7, max(1, weekday))
            // Calendar：1 = 周日，2 = 周一 … 7 = 周六。
            components.weekday = clamped == 7 ? 1 : clamped + 1
        }
        return calendar.nextDate(after: date,
                                 matching: components,
                                 matchingPolicy: .nextTime)
    }

    package var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    package var weekdayText: String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let index = min(6, max(0, weekday - 1))
        return names[index]
    }

    package var cadenceText: String {
        switch cadence {
        case .daily: return "每天 \(timeText)"
        case .weekly: return "每\(weekdayText) \(timeText)"
        }
    }
}
