import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 节目预约

    func isReminded(_ program: TVEPGProgram) -> Bool {
        guard let start = reminderStarts[program.id] else { return false }
        return start > Date()
    }

    /// 预约 / 取消预约：预约成功才记状态，避免系统通知没排上却显示「已预约」。
    func toggleReminder(_ program: TVEPGProgram, channel: TVChannel) {
        if isReminded(program) {
            reminderStarts.removeValue(forKey: program.id)
            saveLibraryValue(reminderStarts, key: Keys.reminders)
            TVReminderCenter.shared.cancel(programID: program.id)
            reminderNotice = "已取消预约《\(program.title)》"
            return
        }
        Task { @MainActor in
            let scheduled = await TVReminderCenter.shared.schedule(channel: channel, program: program)
            guard scheduled else {
                reminderNotice = "无法预约：请在系统设置里允许拾光发送通知"
                return
            }
            reminderStarts[program.id] = program.start
            saveLibraryValue(reminderStarts, key: Keys.reminders)
            reminderNotice = "已预约《\(program.title)》"
        }
    }

    func clearReminderNotice() {
        reminderNotice = nil
    }

    // MARK: - 追剧 / 追赛订阅

    /// 节目名归一化：去掉重播标记与集数，跨天、跨频道才能命中同一档节目。
    func programKey(_ title: String) -> String {
        var text = title.lowercased()
        for token in ["（重播）", "(重播)", "重播", "首播"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(
            of: "第[0-9一二三四五六七八九十百]+[集期回季轮]",
            with: "",
            options: .regularExpression
        )
        return text.filter { $0.isLetter || $0.isNumber }
    }

    func isSubscribed(_ program: TVEPGProgram) -> Bool {
        let key = programKey(program.title)
        return subscriptions.contains { $0.key == key }
    }

    /// 追 / 取消追：加入后自动把这档节目未来 7 天里最近的几次排上提醒。
    func toggleSubscription(_ program: TVEPGProgram, channel: TVChannel) {
        let key = programKey(program.title)
        if let index = subscriptions.firstIndex(where: { $0.key == key }) {
            subscriptions.remove(at: index)
            saveLibraryValue(subscriptions, key: Keys.subscriptions)
            cancelReminders(matching: key)
            reminderNotice = "已取消追《\(program.title)》"
            return
        }
        subscriptions.append(TVSubscription(key: key,
                                            title: program.title,
                                            createdAt: Date()))
        saveLibraryValue(subscriptions, key: Keys.subscriptions)
        reminderNotice = "已加入追剧：\(program.title)"
        Task { @MainActor in
            await scheduleSubscriptionReminders(key: key)
        }
    }

    func removeSubscription(_ subscription: TVSubscription) {
        guard let index = subscriptions.firstIndex(where: { $0.key == subscription.key })
        else { return }
        subscriptions.remove(at: index)
        saveLibraryValue(subscriptions, key: Keys.subscriptions)
        cancelReminders(matching: subscription.key)
        reminderNotice = "已取消追《\(subscription.title)》"
    }

    /// 未来若干天里所有命中的播出：按开播时间排序，供「追剧日历」使用。
    func subscriptionOccurrences(days: Int = 7) -> [(channel: TVChannel, program: TVEPGProgram)] {
        guard !subscriptions.isEmpty else { return [] }
        let keys = Set(subscriptions.map(\.key))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = Date()
        var result: [(channel: TVChannel, program: TVEPGProgram)] = []
        var seen = Set<String>()
        for offset in 0..<max(1, days) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for channel in channelsForFocusedSource {
                for program in programs(on: day, for: channel) {
                    guard program.end > now, keys.contains(programKey(program.title))
                    else { continue }
                    guard seen.insert("\(channel.id)#\(program.id)").inserted else { continue }
                    result.append((channel, program))
                }
            }
        }
        return result.sorted { $0.program.start < $1.program.start }
    }

    /// 订阅命中的下一次播出：页头与节目单里显示「下一次」用。
    func nextOccurrence(of subscription: TVSubscription) -> (channel: TVChannel, program: TVEPGProgram)? {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            var best: (TVChannel, TVEPGProgram)?
            for channel in channelsForFocusedSource {
                for program in programs(on: day, for: channel) {
                    guard program.start > now,
                          programKey(program.title) == subscription.key else { continue }
                    if best == nil || program.start < best!.1.start {
                        best = (channel, program)
                    }
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// 给订阅排未来几次提醒：最多 3 次，避免一开订阅就塞满系统通知。
    func scheduleSubscriptionReminders(key: String) async {
        let upcoming = subscriptionOccurrences(days: 7)
            .filter { $0.program.start > Date() && programKey($0.program.title) == key }
            .prefix(3)
        for item in upcoming {
            guard reminderStarts[item.program.id] == nil else { continue }
            let scheduled = await TVReminderCenter.shared.schedule(channel: item.channel,
                                                                   program: item.program)
            guard scheduled else { continue }
            reminderStarts[item.program.id] = item.program.start
        }
        saveLibraryValue(reminderStarts, key: Keys.reminders)
    }

    /// 取消订阅时顺手撤掉已排上的提醒（订阅已从列表移除，这里按节目名直接扫）。
    func cancelReminders(matching key: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for channel in channelsForFocusedSource {
                for program in programs(on: day, for: channel)
                where programKey(program.title) == key {
                    reminderStarts.removeValue(forKey: program.id)
                    TVReminderCenter.shared.cancel(programID: program.id)
                }
            }
        }
        saveLibraryValue(reminderStarts, key: Keys.reminders)
    }

    // MARK: - 赛事关注

    func isFollowingSport(_ keyword: String) -> Bool {
        sportFollows.contains { $0.keyword == keyword }
    }

    func toggleSportFollow(_ keyword: String, kind: TVSportFollow.Kind = .team) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            reminderNotice = "关注词太短，换一个球队或联赛名试试"
            return
        }
        if let index = sportFollows.firstIndex(where: { $0.keyword == trimmed }) {
            sportFollows.remove(at: index)
            reminderNotice = "已取消关注「\(trimmed)」"
        } else {
            sportFollows.append(TVSportFollow(keyword: trimmed, kind: kind, createdAt: Date()))
            reminderNotice = "已关注「\(trimmed)」"
        }
        saveLibraryValue(sportFollows, key: Keys.sportFollows)
    }

    func removeSportFollow(_ follow: TVSportFollow) {
        sportFollows.removeAll { $0.keyword == follow.keyword }
        saveLibraryValue(sportFollows, key: Keys.sportFollows)
    }

    /// 命中的关注项：节目标题包含任一关键词即算「我的主队」。
    func sportFollow(for title: String) -> TVSportFollow? {
        sportFollows.first { title.localizedCaseInsensitiveContains($0.keyword) }
    }

    func isFollowedSport(_ title: String) -> Bool {
        sportFollow(for: title) != nil
    }

    /// 从赛事标题里提出可关注的关键词：按常见分隔符切开，去掉「直播 / 决赛」这类泛词。
    func followCandidates(in title: String) -> [String] {
        var text = title
        let separators = [" vs ", " vs. ", " VS ", " Versus ", " 对 ", "—", "－", "-", "·",
                          "|", "：", ":", " ", "（", "(", "）", ")", "【", "】"]
        for separator in separators {
            text = text.replacingOccurrences(of: separator, with: "\u{1F}")
        }
        let generic = ["直播", "重播", "录像", "录播", "高清", "超清", "4k", "hd", "全场",
                       "集锦", "决赛", "半决赛", "小组赛", "淘汰赛", "常规赛", "季后赛",
                       "联赛", "杯赛", "体育", "第", "轮"]
        var result: [String] = []
        for token in text.split(separator: "\u{1F}") {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, value.count <= 12 else { continue }
            let lowered = value.lowercased()
            if generic.contains(where: { lowered == $0 }) { continue }
            if result.contains(value) { continue }
            result.append(value)
        }
        return Array(result.prefix(4))
    }

    /// 为「关注」命中的待开赛赛事批量排提醒，返回新排上的场次。
    @discardableResult
    func remindFollowedSports(_ items: [(channel: TVChannel, program: TVEPGProgram)]) -> Int {
        let now = Date()
        var count = 0
        for item in items where item.program.start > now
            && isFollowedSport(item.program.title)
            && !isReminded(item.program) {
            toggleReminder(item.program, channel: item.channel)
            count += 1
        }
        reminderNotice = count > 0 ? "已为 \(count) 场关注赛事排好提醒" : "关注赛事都已经排好提醒"
        return count
    }
}
