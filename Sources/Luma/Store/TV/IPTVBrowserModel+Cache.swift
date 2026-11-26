import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: key)
    }

    // MARK: - 图库级存储

    /// 读一个属于当前图库的键：新库优先读库内 SQLite，读不到时把旧版 UserDefaults 的值迁移进来。
    func libraryRaw(_ key: String) -> String? {
        if let raw = database.setting(key) { return raw }
        guard let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        database.setSetting(key, legacy)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    /// 收藏、预约、订阅这类「内容数据」必须跟着图库走，不能出现切库后串数据。
    func libraryDecoded<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let raw = libraryRaw(key),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func saveLibraryValue<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        database.setSetting(key, raw)
    }

    /// 从当前图库加载收藏 / 最近 / 预约 / 订阅 / 线路偏好 / 探测历史。
    func loadLibraryScopedState() {
        favoriteIDs = Set(libraryDecoded([String].self, key: Keys.favorites) ?? [])
        recentIDs = libraryDecoded([String].self, key: Keys.recent) ?? []
        preferredLines = libraryDecoded([String: String].self, key: Keys.preferredLines) ?? [:]
        probeHistory = libraryDecoded([String: [TVProbePoint]].self, key: Keys.probeHistory) ?? [:]
        // 预约只保留还没开播的：过期的条目顺手清掉，按钮状态才准。
        let storedReminders = libraryDecoded([String: Date].self, key: Keys.reminders) ?? [:]
        reminderStarts = storedReminders.filter { $0.value > Date() }
        subscriptions = libraryDecoded([TVSubscription].self, key: Keys.subscriptions) ?? []
        sportFollows = libraryDecoded([TVSportFollow].self, key: Keys.sportFollows) ?? []
        // 上次退出时还在「录制中」的条目已经不可能继续：如实标成中断，避免一直转圈。
        let storedRecordings = libraryDecoded([TVRecording].self, key: Keys.recordings) ?? []
        recordings = storedRecordings.map { recording in
            guard recording.state == .recording else { return recording }
            var updated = recording
            updated.state = .cancelled
            updated.note = "应用退出，录制已中断"
            return updated
        }
    }
}
