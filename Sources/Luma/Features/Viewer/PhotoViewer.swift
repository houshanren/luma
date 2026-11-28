import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

struct PhotoViewerView: View {
    @Environment(LibraryStore.self) var store
    @Environment(AppSettings.self) var settings
    @Environment(ViewerModel.self) var viewer
    @Environment(\.colorScheme) var colorScheme
    /// true 表示嵌入主窗口浏览（保留侧边栏与工具栏），对应官方「照片」的窗口内查看。
    var embedded: Bool = false
    @State var image: NSImage?
    /// 动图（GIF / 动画 WebP 等）的逐帧图像，交给 `AnimatedImageView` 打开即播放。
    @State var animatedImage: NSImage?
    /// 窗口内浏览的背景图：照片/视频缩略图，用来铺满舞台两侧，避免竖图出现大片死黑。
    @State var backdropImage: NSImage?
    /// 查看器占位层：先显示网格缩略图/中等尺寸，全尺寸解码完成后直接替换。
    @State var placeholder: NSImage?
    @State var zoom: CGFloat = 1
    @State var offset: CGSize = .zero
    /// 刚打开 / 刚换图后的一小段时间内不接管滚轮缩放：
    /// 从网格双击打开时滚动的惯性事件还没走完，会把刚「适应」的画面直接缩掉。
    @State var zoomScrollBlockedUntil: Date = .distantPast
    /// 舞台尺寸：双指滚动拖动画面时用来限制边界。
    @State var stageSize: CGSize = .zero
    @State var baseOffset: CGSize = .zero
    @State var pinchStartZoom: CGFloat?
    @State var pinchStartOffset: CGSize = .zero
    @State var keyMonitor: Any?
    @State var scrollMonitor: Any?
    @State private var didAppear = false
    @State var hostWindow: NSWindow?
    @State var showShortcutHelp = false
    @State var livePlayer: AVPlayer?
    @State var livePlaying = false
    @State var liveEndObserver: NSObjectProtocol?
    /// 连拍逐帧播放任务。
    @State var burstPlayTask: Task<Void, Never>?
    /// 「保留所选，删除其余」的确认卡片。
    @State var confirmBurstKeep = false
    /// 顶栏与画面内控制条共享的音轨 / 字幕状态（由 ViewerModel 持有，「视频」菜单也读这一份）。
    var videoUI: VideoPlaybackUI { viewer.videoPlaybackUI }
    /// 顶栏时间点击后显示剩余时长。
    @State var videoShowsRemainingTime = false

    var videoModel: VideoPlayerModel { viewer.videoPlayer }

    var photo: PhotoItem? { store.viewerPhoto }
    /// 连拍组内浏览：组为空时按普通照片浏览。
    var burstMembers: [PhotoItem] { viewer.burstMembers }
    /// 分页模式下是当前照片附近的一小段；连拍时是整组成员；否则是完整的可见列表。
    var items: [PhotoItem] {
        if !burstMembers.isEmpty { return burstMembers }
        let strip = store.viewerStrip
        return strip.isEmpty ? store.viewerVisiblePhotos : strip
    }
    /// 序号与总数：优先用查询下标，算不出时由 Store 逐级兜底，
    /// 从相簿位置跳转、场景目录、卡片墙封面等入口打开也必须有数字。
    private var viewerPosition: (index: Int, total: Int) {
        guard let id = photo?.id else { return (0, 1) }
        if !burstMembers.isEmpty {
            return (burstMembers.firstIndex(where: { $0.id == id }) ?? 0, burstMembers.count)
        }
        return store.viewerPosition(of: id)
    }
    var totalCount: Int { viewerPosition.total }
    private var loadKey: String {
        guard let photo else { return "none" }
        // 电视线路切换会自增 token：变化后重新装片，不必退出播放器。
        return "\(photo.id.uuidString)-\(photo.editVersion)-\(settings.viewFullHDR)-\(store.tvLineTokens[photo.id, default: 0])"
    }
    var currentIndex: Int? {
        guard photo != nil else { return nil }
        return viewerPosition.index
    }

    /// 当前照片在可见列表里的位置，用于工具栏上的小进度环。
    var progressFraction: CGFloat {
        guard let currentIndex, totalCount > 0 else { return 0 }
        return min(1, max(0, CGFloat(currentIndex + 1) / CGFloat(totalCount)))
    }

    var body: some View {
        ZStack {
            // 视频真全屏的纯黑底：常驻在层级里、只改透明度。
            // 用 if 切换底色会改变 ZStack 的子视图结构，SwiftUI 会重建播放器，
            // 全屏时表现为「黑屏没画面，但声音还在放」。
            Color.black
                .opacity(viewer.videoImmersiveFullScreen ? 1 : 0)

            // 照片与窗口内浏览的灯箱底；全屏视频时让位给纯黑。
            photoBackdrop(immersive: !embedded)
                .opacity(viewer.videoImmersiveFullScreen ? 0 : 1)

            if let photo {
                if embedded {
                    embeddedLayout(photo)
                } else {
                    HStack(spacing: 0) {
                        ZStack {
                            stage(photo)
                            chrome(photo)
                        }
                        if viewer.showInfoPanel {
                            InfoPanelView(photo: photo)
                                .frame(width: 304)
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
            }
        }
        .task(id: loadKey) {
            await load()
        }
        // 换照片（含打开查看器）时回到「适应窗口」：沿用上一张的放大倍数与拖动位移，
        // 新图会一上来就超出窗口、看起来像没自适应。
        .onChange(of: photo?.id) { _, _ in
            resetZoom()
        }
        .task(id: photo?.cacheKey) {
            await loadBackdrop()
        }
        .onChange(of: settings.viewerBackdrop) { _, enabled in
            // 关掉背景虚化时清掉已加载的模糊底图，打开时补回来。
            if enabled {
                Task { await loadBackdrop() }
            } else {
                backdropImage = nil
            }
        }
        .scaleEffect(didAppear ? 1 : 0.985)
        .opacity(didAppear ? 1 : 0)
        .onAppear {
            installViewerKeyMonitor()
            installViewerScrollMonitor()
            withAnimation(.easeOut(duration: 0.18)) { didAppear = true }
        }
        .onDisappear {
            removeViewerKeyMonitor()
            removeViewerScrollMonitor()
            stopLivePhoto()
            stopBurstPlayback()
            VideoScrubPreviewCenter.shared.end()
        }
        .background(
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
            }
        )
        .animation(settings.motion.overlay, value: viewer.showInfoPanel)
        // 窗口内浏览：把返回、缩放、拍摄时间与操作交给统一工具栏，画面里只留照片。
        .toolbar {
            if embedded {
                embeddedToolbar
            }
        }
        // 连拍处理：保留所选，其余移入最近删除。
        .confirmationDialog("保留所选照片？",
                            isPresented: $confirmBurstKeep,
                            titleVisibility: .visible) {
            Button("保留 \(viewer.burstSelection.count) 张，删除其余 \(max(0, burstMembers.count - viewer.burstSelection.count)) 张",
                   role: .destructive) {
                store.deleteBurstPhotos(keeping: viewer.burstSelection)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("其余照片会移入最近删除，30 天内可恢复。")
        }
    }
}
