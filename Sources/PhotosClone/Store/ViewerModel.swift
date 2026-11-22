import Foundation
import PlaybackCore

/// 查看器 / 编辑器状态：与图库内容状态分离，翻页和打开编辑不会触发图库整体刷新。
@MainActor
final class ViewerModel: ObservableObject {
    @Published var viewerID: UUID?
    @Published var editorID: UUID?
    @Published var showInfoPanel = false
    /// 视频全屏沉浸：进入系统全屏时隐藏侧边栏与窗口工具栏，退出后恢复原状。
    @Published var videoImmersiveFullScreen = false
    /// 视频播放状态：与查看器同生命周期，窗口工具栏与画面共用同一份播放状态。
    let videoPlayer: VideoPlayerModel
    /// 播放编排：起流 / 降级 / seek 重建 / 分片回收都收在内核里。
    let playbackSession: PlaybackSession
    /// 视频手动旋转角度：画面、顶栏按钮与「视频」菜单共用。
    @Published var videoQuarterTurns = 0
    /// 音轨 / 字幕状态：顶栏、画面内控制条与「视频」菜单共用同一份。
    let videoPlaybackUI = VideoPlaybackUI()

    init() {
        let player = VideoPlayerModel()
        videoPlayer = player
        playbackSession = PlaybackSession(engine: player, environment: .luma)
    }

    // MARK: - 连拍快照
    //
    // 官方「照片」打开连拍代表图后就进入整组浏览：这里保存当前组（按拍摄时间升序），
    // 查看器的序号、胶片条、播放与选择都基于它；组为空时按普通照片浏览。
    @Published var burstMembers: [PhotoItem] = []
    /// 正在按帧连播组内照片。
    @Published var burstPlaying = false
    /// 「进行选择…」的组内选择模式。
    @Published var burstSelectionMode = false
    @Published var burstSelection: Set<UUID> = []
}
