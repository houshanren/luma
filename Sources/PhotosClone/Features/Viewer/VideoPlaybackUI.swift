import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 在线字幕搜索上下文：当前影片的片名与季集号。
struct CinemaSubtitleQuery: Equatable {
    var title: String
    var season: Int?
    var episode: Int?

    var isTV: Bool { season != nil || episode != nil }
}

/// 顶栏与画面内控制条共享的播放 UI 状态：音轨列表、外挂字幕与偏移。
/// 播放页（VideoPlayerStage）负责真正重建流 / 切换 AV 音轨，这里只保存展示状态。
@MainActor
final class VideoPlaybackUI: ObservableObject {
    struct AudioChoice: Identifiable, Equatable {
        let index: Int
        let title: String
        var id: Int { index }
    }

    @Published private(set) var audioChoices: [AudioChoice] = []
    @Published private(set) var selectedAudioIndex = 0
    @Published private(set) var subtitleCues: [SubtitleCue] = []
    @Published private(set) var subtitleName: String?
    /// 外挂字幕时间轴偏移（秒），正值表示字幕延后出现。
    @Published var subtitleOffset: Double = 0
    /// 正在烧录的图形字幕文件名；nil 表示未开启烧录。
    @Published private(set) var burnSubtitleName: String?
    /// 已复制到临时目录的烧录字幕路径（交给 ffmpeg 的 subtitles 滤镜）。
    private(set) var burnSubtitleURL: URL?

    /// 从影院进入播放时写入；在线字幕搜索据此拿到片名与季集号。
    var subtitleQuery: CinemaSubtitleQuery?
    @Published private(set) var onlineSubtitles: [CinemaSubtitleMatch] = []
    @Published private(set) var onlineSubtitleLoading = false
    @Published private(set) var onlineSubtitleHint: String?

    /// HLS 模式切换音轨需要重建流，由播放页注册。
    var onSelectStreamAudio: ((Int) -> Void)?
    /// 烧录字幕变化时需要重建转码流，由播放页注册。
    var onBurnSubtitleChanged: (() -> Void)?
    /// 解析失败等提示，由播放页转成 toast。
    var onMessage: ((String) -> Void)?

    private var loadToken = 0

    var hasSubtitle: Bool { subtitleName != nil }

    func reset() {
        loadToken &+= 1
        audioChoices = []
        selectedAudioIndex = 0
        subtitleCues = []
        subtitleName = nil
        subtitleOffset = 0
        burnSubtitleName = nil
        burnSubtitleURL = nil
        subtitleQuery = nil
        onlineSubtitles = []
        onlineSubtitleLoading = false
        onlineSubtitleHint = nil
        onSelectStreamAudio = nil
    }

    func updateAudio(choices: [AudioChoice], selected: Int) {
        audioChoices = choices
        selectedAudioIndex = min(max(0, selected), max(0, choices.count - 1))
    }

    func selectAudio(_ index: Int) {
        guard index != selectedAudioIndex, audioChoices.contains(where: { $0.index == index }) else { return }
        selectedAudioIndex = index
        onSelectStreamAudio?(index)
    }

    /// 当前时间点应显示的字幕（已套用偏移）。正值 = 字幕延后出现。
    func cue(at time: Double) -> SubtitleCue? {
        SubtitleLoader.cue(at: time - subtitleOffset, in: subtitleCues)
    }

    func adjustOffset(_ delta: Double) {
        let value = (subtitleOffset + delta) * 10
        subtitleOffset = value.rounded() / 10
    }

    func resetOffset() {
        subtitleOffset = 0
    }

    func clearSubtitle() {
        loadToken &+= 1
        subtitleCues = []
        subtitleName = nil
    }

    // MARK: 烧录字幕（PGS / SUP / ASS）

    /// 选一个字幕文件交给 ffmpeg 烧进画面：PGS / SUP 等图形字幕无法走原生字幕轨。
    /// 选完后由播放页重建转码流，可能比普通播放慢一点。
    func pickBurnInSubtitle() {
        let panel = NSOpenPanel()
        panel.title = "选择要烧录的字幕"
        panel.allowedContentTypes = ["sup", "pgs", "ass", "ssa", "srt", "vtt"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 复制到纯 ASCII 临时路径：ffmpeg 的 subtitles 滤镜对空格 / 冒号 / 中文很敏感。
        let ext = url.pathExtension.isEmpty ? "ass" : url.pathExtension.lowercased()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-burn-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: temp)
        } catch {
            onMessage?("无法读取这个字幕文件：\(error.localizedDescription)")
            return
        }
        burnSubtitleURL = temp
        burnSubtitleName = url.lastPathComponent
        onMessage?("已开启字幕烧录：\(url.lastPathComponent)，正在重新转码")
        onBurnSubtitleChanged?()
    }

    func clearBurnInSubtitle() {
        guard burnSubtitleURL != nil else { return }
        burnSubtitleURL = nil
        burnSubtitleName = nil
        onMessage?("已关闭字幕烧录")
        onBurnSubtitleChanged?()
    }

    func loadSubtitle(url: URL) {
        loadToken &+= 1
        let token = loadToken
        let name = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let cues = SubtitleLoader.load(url: url)
            Task { @MainActor [weak self] in
                guard let self, token == self.loadToken else { return }
                guard !cues.isEmpty else {
                    self.onMessage?("未能解析该字幕文件")
                    return
                }
                self.subtitleCues = cues
                self.subtitleName = name
                self.subtitleOffset = 0
            }
        }
    }

    /// 同目录同名的外挂字幕自动挂载（本地 / SMB 可直接命中）。
    /// 目录扫描必须离开主线程：图库一个 originals 分片目录可能有几万个文件，
    /// 在外置盘上同步枚举会让打开视频时整个界面卡住好几秒。
    func loadSiblingIfAvailable(sourceURL: URL?) {
        guard subtitleCues.isEmpty, subtitleName == nil, let sourceURL else { return }
        let token = loadToken
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let sibling = SubtitleLoader.discoverSibling(of: sourceURL) else { return }
            Task { @MainActor in
                guard let self, token == self.loadToken, self.subtitleCues.isEmpty else { return }
                self.loadSubtitle(url: sibling)
            }
        }
    }

    func pickSubtitle() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let types = SubtitleLoader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if types.count == SubtitleLoader.supportedExtensions.count {
            panel.allowedContentTypes = types
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSubtitle(url: url)
    }

    // MARK: 在线字幕

    /// 只有在影院播放且配置了 API Key 时才显示在线字幕入口。
    var canSearchOnlineSubtitles: Bool {
        guard subtitleQuery != nil else { return false }
        return !AppSettings.shared.cinemaSubtitleAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var subtitleCredentials: OpenSubtitlesClient.Credentials {
        let settings = AppSettings.shared
        // 第一次真正搜索在线字幕时才读钥匙串。
        settings.loadSubtitleCredentialsIfNeeded()
        return OpenSubtitlesClient.Credentials(apiKey: settings.cinemaSubtitleAPIKey,
                                               username: settings.cinemaSubtitleUsername,
                                               password: settings.cinemaSubtitlePassword)
    }

    func searchOnlineSubtitles() {
        guard let query = subtitleQuery, !onlineSubtitleLoading else { return }
        onlineSubtitleLoading = true
        onlineSubtitleHint = nil
        onlineSubtitles = []
        let credentials = subtitleCredentials
        Task { @MainActor in
            defer { onlineSubtitleLoading = false }
            do {
                let matches = try await OpenSubtitlesClient.search(query: query.title,
                                                                   isTV: query.isTV,
                                                                   season: query.season,
                                                                   episode: query.episode,
                                                                   credentials: credentials)
                onlineSubtitles = matches
                onlineSubtitleHint = matches.isEmpty ? "没有找到中文字幕" : nil
            } catch {
                onlineSubtitleHint = error.localizedDescription
                onMessage?(error.localizedDescription)
            }
        }
    }

    func downloadOnlineSubtitle(_ match: CinemaSubtitleMatch) {
        guard !onlineSubtitleLoading else { return }
        onlineSubtitleLoading = true
        let credentials = subtitleCredentials
        Task { @MainActor in
            defer { onlineSubtitleLoading = false }
            do {
                let url = try await OpenSubtitlesClient.download(match, credentials: credentials)
                loadSubtitle(url: url)
                onlineSubtitleHint = "已载入 \(match.languageTitle)"
            } catch {
                onlineSubtitleHint = error.localizedDescription
                onMessage?(error.localizedDescription)
            }
        }
    }
}
