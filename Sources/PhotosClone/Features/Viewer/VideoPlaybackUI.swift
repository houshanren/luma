import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    /// HLS 模式切换音轨需要重建流，由播放页注册。
    var onSelectStreamAudio: ((Int) -> Void)?
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
}
