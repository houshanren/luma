import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 录制中心

    var pendingRecordings: [TVRecording] { recordings.filter(\.isPending) }
    var finishedRecordings: [TVRecording] { recordings.filter { !$0.isPending } }

    /// 定时录制：按节目时长录（最长 2 小时）。开始时间已过但仍在窗口内时立即开录。
    func scheduleRecording(channel: TVChannel, program: TVEPGProgram) {
        let now = Date()
        guard program.end > now else {
            reminderNotice = "这档节目已经结束"
            return
        }
        let duplicated = recordings.contains {
            $0.channelID == channel.id && $0.title == program.title
                && abs($0.start.timeIntervalSince(program.start)) < 60 && $0.isPending
        }
        guard !duplicated else {
            reminderNotice = "这档节目已经排过录制"
            return
        }
        let duration = min(max(program.duration, 60), 2 * 3600)
        let recording = TVRecording(id: UUID(),
                                    channelID: channel.id,
                                    channelName: channel.name,
                                    playlistID: channel.playlistID,
                                    title: program.title,
                                    streamURL: channel.streamURL,
                                    headers: channel.headers,
                                    isHLS: channel.isHLS,
                                    start: max(program.start, now),
                                    duration: duration,
                                    state: .scheduled,
                                    photoID: nil,
                                    note: nil,
                                    createdAt: now)
        recordings.insert(recording, at: 0)
        saveRecordings()
        reminderNotice = recording.start <= now
            ? "开始录制《\(program.title)》"
            : "已排定《\(program.title)》的录制"
        processDueRecordings()
    }

    /// 追剧录：给订阅命中的下一场播出排一条录制。
    func scheduleSeriesRecording(for subscription: TVSubscription) {
        guard let next = nextOccurrence(of: subscription) else {
            reminderNotice = "「\(subscription.title)」暂无下一场排期"
            return
        }
        scheduleRecording(channel: next.channel, program: next.program)
    }

    /// 立即录 30 秒：直播里遇到精彩片段时用。
    func recordNow(channel: TVChannel, title: String) {
        let now = Date()
        let recording = TVRecording(id: UUID(),
                                    channelID: channel.id,
                                    channelName: channel.name,
                                    playlistID: channel.playlistID,
                                    title: title,
                                    streamURL: channel.streamURL,
                                    headers: channel.headers,
                                    isHLS: channel.isHLS,
                                    start: now,
                                    duration: 30,
                                    state: .scheduled,
                                    photoID: nil,
                                    note: nil,
                                    createdAt: now)
        recordings.insert(recording, at: 0)
        saveRecordings()
        processDueRecordings()
    }

    func cancelRecording(_ recording: TVRecording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index].state = .cancelled
        recordings[index].note = "已取消"
        saveRecordings()
    }

    func removeRecording(_ recording: TVRecording) {
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }

    func saveRecordings() {
        saveLibraryValue(recordings, key: Keys.recordings)
    }

    func startRecordingTicker() {
        guard recordingTimer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processDueRecordings() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
        processDueRecordings()
    }

    /// 到点就开录：真正录制交给 `IngestService`，进度登记到任务中心。
    func processDueRecordings() {
        let now = Date()
        for recording in recordings where recording.state == .scheduled && recording.start <= now {
            launchRecording(recording)
        }
    }

    func launchRecording(_ recording: TVRecording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        guard !recording.isExpired else {
            recordings[index].state = .cancelled
            recordings[index].note = "错过了开始时间，未录制"
            saveRecordings()
            return
        }
        guard let store = LibraryStore.current,
              let url = URL(string: recording.streamURL) else {
            recordings[index].state = .failed
            recordings[index].note = "当前没有可写入的图库"
            saveRecordings()
            return
        }
        recordings[index].state = .recording
        saveRecordings()

        let jobID = store.beginSourceJob(
            SourceJob(sourceID: .television(recording.playlistID),
                      kind: .record,
                      title: "录制 \(recording.title)",
                      isCancellable: false)
        )
        store.updateSourceJob(jobID, message: "正在抓取直播流…")

        let seconds = max(30, Int(recording.end.timeIntervalSince(Date())))
        let request = IngestRequest(
            payload: .remoteClip(RemoteMedia(url: url, headers: recording.headers), seconds: seconds),
            title: "电视录制·\(recording.title)"
        )
        Task { @MainActor [weak self] in
            do {
                let result = try await store.ingestService.ingest(request)
                store.finishSourceJob(jobID, message: "已保存到图库：\(result.title)")
                self?.completeRecording(recording.id, photoID: result.itemID)
            } catch {
                store.failSourceJob(jobID, message: error.localizedDescription)
                self?.failRecording(recording.id, note: error.localizedDescription)
            }
        }
    }

    func completeRecording(_ id: UUID, photoID: String?) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].state = .finished
        recordings[index].photoID = photoID
        recordings[index].note = nil
        saveRecordings()
    }

    func failRecording(_ id: UUID, note: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].state = .failed
        recordings[index].note = note
        saveRecordings()
    }

    // MARK: - 收藏 / 最近

    func isFavorite(_ channel: TVChannel) -> Bool {
        favoriteIDs.contains(channel.id)
    }

    func toggleFavorite(_ channel: TVChannel) {
        if favoriteIDs.contains(channel.id) {
            favoriteIDs.remove(channel.id)
        } else {
            favoriteIDs.insert(channel.id)
        }
        saveLibraryValue(Array(favoriteIDs), key: Keys.favorites)
    }

    /// 打开频道时调用；回看也记进最近。
    func recordRecent(_ channel: TVChannel) {
        recentIDs.removeAll { $0 == channel.id }
        recentIDs.insert(channel.id, at: 0)
        if recentIDs.count > 40 { recentIDs.removeLast(recentIDs.count - 40) }
        saveLibraryValue(recentIDs, key: Keys.recent)
    }
}
