import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct PhotoViewerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewer: ViewerModel
    /// true 表示嵌入主窗口浏览（保留侧边栏与工具栏），对应官方「照片」的窗口内查看。
    var embedded: Bool = false
    @State private var image: NSImage?
    /// 查看器占位层：先显示网格缩略图/中等尺寸，全尺寸解码完成后在其上淡入，避免分辨率突变。
    @State private var placeholder: NSImage?
    @State private var imageToken = 0
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var pinchStartZoom: CGFloat?
    @State private var pinchStartOffset: CGSize = .zero
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var didAppear = false
    @State private var hostWindow: NSWindow?
    @State private var showShortcutHelp = false
    @State private var livePlayer: AVPlayer?
    @State private var livePlaying = false
    @State private var liveEndObserver: NSObjectProtocol?
    /// 鼠标是否停留在图片区域；翻页按钮只在悬停时浮现，减少视觉噪音。
    @State private var stageHovering = false

    private var photo: PhotoItem? { store.viewerPhoto }
    /// 分页模式下是当前照片附近的一小段；否则是完整的可见列表。
    private var items: [PhotoItem] {
        let strip = store.viewerStrip
        return strip.isEmpty ? store.visiblePhotos : strip
    }
    private var totalCount: Int { store.visibleCount }
    private var loadKey: String {
        guard let photo else { return "none" }
        return "\(photo.id.uuidString)-\(photo.editVersion)-\(settings.viewFullHDR)"
    }
    private var currentIndex: Int? {
        guard let id = photo?.id else { return nil }
        return store.viewerIndex(of: id)
    }

    var body: some View {
        ZStack {
            if embedded {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            } else {
                Color.black.opacity(0.97)
                    .ignoresSafeArea()
            }

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
        .scaleEffect(didAppear ? 1 : 0.985)
        .opacity(didAppear ? 1 : 0)
        .onAppear {
            installViewerKeyMonitor()
            if !embedded {
                installViewerScrollMonitor()
            }
            withAnimation(.easeOut(duration: 0.18)) { didAppear = true }
        }
        .onDisappear {
            removeViewerKeyMonitor()
            removeViewerScrollMonitor()
            stopLivePhoto()
        }
        .background(
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
            }
        )
        .animation(settings.motion.overlay, value: viewer.showInfoPanel)
    }

    // MARK: - 嵌入主窗口的查看器

    private func embeddedLayout(_ photo: PhotoItem) -> some View {
        VStack(spacing: 0) {
            embeddedBar(photo)
            Divider()
            HStack(spacing: 0) {
                stage(photo)
                    .padding(20)
                if viewer.showInfoPanel {
                    InfoPanelView(photo: photo)
                        .frame(width: 304)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }

    private func embeddedBar(_ photo: PhotoItem) -> some View {
        ZStack {
            HStack(spacing: 12) {
                Button {
                    store.closeViewer()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("返回图库 (Esc)")

                if !photo.isVideo {
                    HStack(spacing: 6) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 9.5))
                        Slider(value: zoomBinding, in: 1...5)
                            .controlSize(.mini)
                            .frame(width: 112)
                            .accessibilityLabel("缩放照片")
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: 1) {
                Text(DateText.fullFormatter.string(from: photo.capturedAt))
                    .font(.system(size: 12, weight: .medium))
                if let currentIndex {
                    Text("\(currentIndex + 1) / \(totalCount)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(photo.displayTitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                barButton("info.circle", help: "信息") {
                    viewer.showInfoPanel.toggle()
                }
                ShareLink(items: store.shareURLs) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.shareURLs.isEmpty)
                .help("共享")
                if !photo.isReadOnly || photo.isCloud || store.canEditNativeOverlay {
                    barButton(photo.isFavorite ? "heart.fill" : "heart",
                              help: photo.isFavorite ? "取消收藏" : "收藏") {
                        store.toggleFavorite(photo.id)
                    }
                    .foregroundStyle(photo.isFavorite ? Color.pink : Color.primary)
                }
                barButton("play.rectangle", help: "幻灯片播放") {
                    store.presentSlideshow()
                }
                .disabled(store.visibleCount == 0)
                if !photo.isVideo && !photo.isReadOnly {
                    barButton("slider.horizontal.3", help: "编辑") {
                        store.openEditor(photo.id)
                    }
                }
                moreMenu(photo)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    private func barButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { Double(zoom) },
            set: { newValue in
                let old = zoom
                let target = CGFloat(newValue)
                zoom = target
                if target <= 1.01 {
                    offset = .zero
                    baseOffset = .zero
                } else {
                    let ratio = target / max(old, 0.0001)
                    offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
                    baseOffset = offset
                }
                pinchStartZoom = nil
            }
        )
    }

    private func stage(_ photo: PhotoItem) -> some View {
        GeometryReader { proxy in
            ZStack {
                if photo.isVideo {
                    VideoPlayerStage(photo: photo)
                } else if livePlaying, let livePlayer {
                    LivePhotoLayerView(player: livePlayer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let shown = image ?? placeholder {
                    let fitted = fittedSize(shown, in: proxy.size)
                    ZStack {
                        // 占位层一直垫在下面，全尺寸图淡入时不会出现“先糊后清”的跳变。
                        if let placeholder {
                            Image(nsImage: placeholder)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                        }
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(offset)
                    .shadow(color: .black.opacity(embedded ? 0.28 : 0),
                            radius: embedded ? 20 : 0,
                            y: embedded ? 8 : 0)
                    .animation(settings.motion.overlay, value: imageToken)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(embedded ? Color.secondary : Color.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if !photo.isVideo, let shown = image ?? placeholder, !livePlaying {
                    let fitted = fittedSize(shown, in: proxy.size)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { value in
                                    toggleZoom(at: value.location, stage: proxy.size, fitted: fitted)
                                }
                        )
                        .simultaneousGesture(magnifyGesture(stage: proxy.size, fitted: fitted))
                        .simultaneousGesture(panGesture(stage: proxy.size, fitted: fitted))
                }
            }
            .clipped()
            .onHover { hovering in stageHovering = hovering }
        }
        .overlay(alignment: .topLeading) {
            if !photo.isVideo, livePhotoURL(for: photo) != nil {
                Button {
                    toggleLivePhoto()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: livePlaying ? "pause.fill" : "livephoto.play")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("实况")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(livePlaying ? "暂停实况照片 (L)" : "播放实况照片 (L)")
                .padding(16)
            }
        }
        .overlay(alignment: .leading) {
            navButton("chevron.left") { store.viewerStep(-1) }
                .padding(.leading, 16)
                .opacity(totalCount > 1 && (stageHovering || image == nil) ? 1 : 0)
                .disabled(totalCount <= 1)
                .animation(.easeInOut(duration: 0.16), value: stageHovering)
        }
        .overlay(alignment: .trailing) {
            navButton("chevron.right") { store.viewerStep(1) }
                .padding(.trailing, 16)
                .opacity(totalCount > 1 && (stageHovering || image == nil) ? 1 : 0)
                .disabled(totalCount <= 1)
                .animation(.easeInOut(duration: 0.16), value: stageHovering)
        }
    }

    // MARK: - Zoom math

    private func fittedSize(_ image: NSImage, in stage: CGSize) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0, stage.width > 0, stage.height > 0 else {
            return .zero
        }
        let scale = min(stage.width / size.width, stage.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func clampedOffset(_ proposed: CGSize, stage: CGSize,
                               fitted: CGSize, zoom: CGFloat) -> CGSize {
        guard zoom > 1 else { return .zero }
        let maxX = max(0, (fitted.width * zoom - stage.width) / 2)
        let maxY = max(0, (fitted.height * zoom - stage.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    /// 以某个视图坐标为锚点缩放，保持该点下的画面不动。
    private func zoomedOffset(around location: CGPoint, stage: CGSize,
                              oldZoom: CGFloat, oldOffset: CGSize, newZoom: CGFloat) -> CGSize {
        let p = CGPoint(x: location.x - stage.width / 2, y: location.y - stage.height / 2)
        let q = CGPoint(x: (p.x - oldOffset.width) / max(oldZoom, 0.0001),
                        y: (p.y - oldOffset.height) / max(oldZoom, 0.0001))
        return CGSize(width: p.x - q.x * newZoom, height: p.y - q.y * newZoom)
    }

    private func magnifyGesture(stage: CGSize, fitted: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = zoom
                    pinchStartOffset = offset
                }
                guard let startZoom = pinchStartZoom else { return }
                let newZoom = min(5, max(1, startZoom * value.magnification))
                let proposed = zoomedOffset(around: value.startLocation, stage: stage,
                                            oldZoom: startZoom, oldOffset: pinchStartOffset,
                                            newZoom: newZoom)
                zoom = newZoom
                offset = clampedOffset(proposed, stage: stage, fitted: fitted, zoom: newZoom)
            }
            .onEnded { _ in
                pinchStartZoom = nil
                baseOffset = offset
                if zoom <= 1.01 {
                    withAnimation(.easeOut(duration: 0.22)) {
                        zoom = 1
                        offset = .zero
                        baseOffset = .zero
                    }
                }
            }
    }

    private func panGesture(stage: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                let proposed = CGSize(width: baseOffset.width + value.translation.width,
                                      height: baseOffset.height + value.translation.height)
                offset = clampedOffset(proposed, stage: stage, fitted: fitted, zoom: zoom)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func toggleZoom(at location: CGPoint, stage: CGSize, fitted: CGSize) {
        let target: CGFloat = zoom > 1.01 ? 1 : 2.5
        let proposed = target > 1
            ? clampedOffset(zoomedOffset(around: location, stage: stage, oldZoom: zoom,
                                         oldOffset: offset, newZoom: target),
                            stage: stage, fitted: fitted, zoom: target)
            : .zero
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            zoom = target
            offset = proposed
        }
        baseOffset = proposed
        pinchStartZoom = nil
    }

    private func adjustZoom(by factor: CGFloat) {
        let oldZoom = zoom
        let target = min(5, max(1, zoom * factor))
        let ratio = target / max(oldZoom, 0.0001)
        withAnimation(.easeInOut(duration: 0.2)) {
            zoom = target
            if target <= 1.01 {
                offset = .zero
                baseOffset = .zero
            } else {
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
            }
        }
        pinchStartZoom = nil
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.22)) {
            zoom = 1
            offset = .zero
        }
        baseOffset = .zero
        pinchStartZoom = nil
    }

    private func chrome(_ photo: PhotoItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                circleButton("xmark") { store.closeViewer() }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DateText.fullFormatter.string(from: photo.capturedAt))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(photo.displayTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                if !photo.isReadOnly || photo.isCloud || store.canEditNativeOverlay {
                    circleButton(photo.isFavorite ? "heart.fill" : "heart") {
                        store.toggleFavorite(photo.id)
                    }
                    .help(photo.isFavorite ? "取消收藏" : "收藏")
                }

                circleButton("info.circle") {
                    viewer.showInfoPanel.toggle()
                }
                .help("信息")

                circleButton("questionmark.circle") {
                    showShortcutHelp.toggle()
                }
                .help("键盘快捷键")
                .popover(isPresented: $showShortcutHelp, arrowEdge: .bottom) {
                    ShortcutHelpView()
                }

                if !photo.isVideo && !photo.isReadOnly {
                    circleButton("slider.horizontal.3") {
                        store.openEditor(photo.id)
                    }
                    .help("编辑")
                }

                moreMenu(photo)

                if photo.isCloud, store.isCurrentCloudWritable {
                    circleButton("trash") {
                        store.confirmDeleteCloud([photo.id])
                    }
                    .help("从云端删除")
                } else if !photo.isReadOnly {
                    circleButton("trash") {
                        store.delete([photo.id])
                    }
                    .help("删除")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.top, 16)

            Spacer()

            if totalCount > 1, !photo.isVideo {
                FilmstripView(items: items, currentID: photo.id) { id in
                    viewer.viewerID = id
                }
                .padding(.bottom, 10)
            }

            HStack(spacing: 12) {
                if !photo.isVideo {
                    zoomControls
                    Divider()
                        .frame(height: 14)
                        .overlay(.white.opacity(0.18))
                }
                if let currentIndex {
                    Text("\(currentIndex + 1) / \(totalCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 18)
        }

        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
                .allowsHitTesting(false)
        }
    }

    private func moreMenu(_ photo: PhotoItem) -> some View {
        Menu {
            Button("导出…") { store.export(photo.id) }
            Button("打印…") { store.printCommand() }
            Button("幻灯片播放") { store.presentSlideshow() }
            if !photo.isCloud || store.isCurrentCloudSMB {
                Button("在访达中显示") { store.revealInFinder(photo.id) }
            }
            if photo.isCloud, store.isCurrentCloudWritable {
                Button("重命名…") { store.requestCloudRename(photo.id) }
                Divider()
                Button("从云端删除…", role: .destructive) {
                    store.confirmDeleteCloud([photo.id])
                }
            }
            if !photo.isReadOnly {
                Button("复制照片") { store.duplicateCommand() }
                if !photo.isVideo {
                    Menu("旋转") {
                        Button("向右旋转") { store.rotateCommand(clockwise: true) }
                        Button("向左旋转") { store.rotateCommand(clockwise: false) }
                    }
                }
                if !photo.isVideo, !photo.isCloud {
                    Button("压缩…") {
                        store.presentCompression(for: [photo.id])
                    }
                    if PhotoCompressor.hasBackup(for: photo) {
                        Button("还原压缩前的原图") {
                            store.revertCompression(photo.id)
                        }
                    }
                }
                Button(photo.isHidden ? "取消隐藏" : "隐藏") {
                    store.setHidden([photo.id], hidden: !photo.isHidden)
                }
                if photo.hasEdits {
                    Button("复制编辑点") {
                        store.copyEdits(photo.id)
                    }
                    Button("还原为原始照片") {
                        store.revertEdits(photo.id)
                    }
                }
                if store.copiedEditRecipe != nil {
                    Button("粘贴编辑点") {
                        store.pasteEdits(photo.id)
                    }
                }
                Divider()
                Button("删除", role: .destructive) {
                    store.delete([photo.id])
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var zoomControls: some View {
        HStack(spacing: 9) {
            Button {
                adjustZoom(by: 1 / 1.35)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoom <= 1.001)

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .frame(minWidth: 36)

            Button {
                adjustZoom(by: 1.35)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoom >= 4.999)

            Button {
                resetZoom()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("适应窗口 (0)")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.82))
    }

    // MARK: - Viewer keyboard

    private func installViewerKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleViewerKey(event) ? nil : event
        }
    }

    private func removeViewerKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - 滚轮缩放

    private func installViewerScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleViewerScroll(event) ? nil : event
        }
    }

    private func removeViewerScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func handleViewerScroll(_ event: NSEvent) -> Bool {
        guard viewer.viewerID != nil, viewer.editorID == nil, photo?.isVideo != true else { return false }
        guard let window = hostWindow ?? event.window, event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard abs(event.scrollingDeltaY) > 0.01 else { return false }

        // 在胶片条、信息面板、顶部工具栏上滚动时不缩放，避免抢走滚动操作。
        if let content = window.contentView {
            let point = content.convert(event.locationInWindow, from: nil)
            if point.y < 150 { return false }
            if point.y > content.bounds.height - 70 { return false }
            if viewer.showInfoPanel, point.x > content.bounds.width - 310 { return false }
        }

        let delta = event.scrollingDeltaY
        let factor = min(1.3, max(0.72, 1 + delta * 0.02))
        let target = min(5, max(1, zoom * factor))
        guard abs(target - zoom) > 0.0005 else { return false }
        zoom = target
        if target <= 1.01 {
            offset = .zero
            baseOffset = .zero
        }
        pinchStartZoom = nil
        return true
    }

    private func handleViewerKey(_ event: NSEvent) -> Bool {
        guard let window = hostWindow ?? event.window else { return false }
        guard event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard viewer.viewerID != nil, viewer.editorID == nil, store.activeMemory == nil else { return false }
        guard let photo else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 照片与视频通用的命令。
        if flags.contains(.command) {
            if event.keyCode == 51 {
                if photo.isCloud {
                    store.confirmDeleteCloud([photo.id])
                } else if !photo.isSystem {
                    if flags.contains(.option) {
                        store.confirmPermanentDelete([photo.id])
                    } else {
                        store.delete([photo.id])
                    }
                }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                store.copySelectionToPasteboard()
                return true
            case "v":
                guard !store.isReadOnlyScope else { return false }
                store.pasteFromPasteboard()
                return true
            case "d":
                guard !photo.isReadOnly else { return false }
                store.duplicateCommand()
                return true
            default:
                return false
            }
        }
        // 方向键在多数键盘上会带上 Function / 小键盘标记，不能因此丢弃；
        // 只屏蔽会与系统菜单快捷键冲突的修饰键。
        guard flags.intersection([.option, .control]).isEmpty else { return false }

        if !photo.isReadOnly || photo.isCloud, event.charactersIgnoringModifiers == "." {
            store.toggleFavorite(photo.id)
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "i" {
            viewer.showInfoPanel.toggle()
            return true
        }

        // 空格：与系统「照片」一致，打开后再次按下即收起查看器回到图库。
        if event.keyCode == 49,
           flags.intersection([.shift, .option, .control]).isEmpty {
            store.closeViewer()
            return true
        }

        // 视频的方向键、空格等由播放器自行处理。
        guard !photo.isVideo else { return false }

        if photo.isLivePhoto, event.charactersIgnoringModifiers?.lowercased() == "l" {
            toggleLivePhoto()
            return true
        }

        switch event.keyCode {
        case 123, 126:
            store.viewerStep(-1)
            return true
        case 124, 125:
            store.viewerStep(1)
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "=", "+":
            adjustZoom(by: 1.35)
            return true
        case "-", "_":
            adjustZoom(by: 1 / 1.35)
            return true
        case "0":
            resetZoom()
            return true
        case "e":
            guard !photo.isReadOnly else { return false }
            store.openEditor(photo.id)
            return true
        case "f":
            NSApp.keyWindow?.toggleFullScreen(nil)
            return true
        default:
            return false
        }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.28), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 实况照片

    private func livePhotoURL(for photo: PhotoItem) -> URL? {
        guard photo.isLivePhoto, !photo.isVideo,
              let url = LibraryPaths.livePhotoURL(for: photo),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func toggleLivePhoto() {
        guard let photo else { return }
        if livePlaying {
            stopLivePhoto()
            return
        }
        guard let url = livePhotoURL(for: photo) else {
            store.showToast("找不到实况照片的配对视频")
            return
        }
        let player = AVPlayer(url: url)
        livePlayer = player
        livePlaying = true
        liveEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                stopLivePhoto()
            }
        }
        player.play()
    }

    private func stopLivePhoto() {
        livePlayer?.pause()
        livePlayer = nil
        livePlaying = false
        if let liveEndObserver {
            NotificationCenter.default.removeObserver(liveEndObserver)
            self.liveEndObserver = nil
        }
    }

    private func load() async {
        stopLivePhoto()
        zoom = 1
        offset = .zero
        baseOffset = .zero
        pinchStartZoom = nil
        guard let photo else {
            image = nil
            placeholder = nil
            return
        }
        let fullHDR = settings.viewFullHDR
        if photo.isVideo {
            image = nil
            placeholder = nil
        } else {
            // 切换照片时先清掉上一张；占位层直接用网格里已解码的那一档，开图即有内容。
            image = nil
            placeholder = ImageLoader.cachedPreview(for: photo)

            let target = photo
            if target.isCloud {
                let loaded = await store.cloudDisplayImage(for: target)
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                let result = fullHDR ? loaded : loaded.map(ImageLoader.sdrImage)
                if placeholder == nil { image = result } else { show(result) }
            } else if let cached = ImageLoader.cachedDisplayImage(for: target, sdr: !fullHDR) {
                // 命中全尺寸缓存：直接出图，不做多余动画。
                image = cached
            } else {
                // 二级占位：磁盘上的 1200px 缩略图，比 192px 放大清晰得多。
                let medium = await Task.detached(priority: .userInitiated) {
                    ImageLoader.gridThumbnail(for: target, maxPixel: 1024)
                }.value
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                if let medium { placeholder = medium }
                prefetchQuickNeighbors(of: target)
                let loaded = await Task.detached(priority: .userInitiated) {
                    ImageLoader.displayImage(for: target, sdr: !fullHDR)
                }.value
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                if placeholder == nil {
                    image = loaded
                } else {
                    show(loaded)
                }
            }
        }
        prefetchNeighbors(of: photo, fullHDR: fullHDR)
    }

    /// 全尺寸图在占位层上淡入，视觉上不出现“先糊后清”的分辨率跳变。
    private func show(_ newImage: NSImage?) {
        image = newImage
        imageToken &+= 1
    }

    /// 预取前后各两张的快速层，连翻时每一张都能立刻显示。
    private func prefetchQuickNeighbors(of photo: PhotoItem) {
        let photos = items
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        for delta in [1, 2, -1, -2] {
            var next = index + delta
            if next < 0 { next += photos.count }
            if next >= photos.count { next -= photos.count }
            guard next >= 0, next < photos.count else { continue }
            let target = photos[next]
            guard !target.isVideo, !target.isCloud else { continue }
            ImageLoader.prefetchQuick(for: target)
            // 紧邻的一张额外预取 1024px 中等层，翻过去时占位更清晰。
            if abs(delta) == 1 {
                ImageLoader.prefetchMedium(for: target)
            }
        }
    }

    /// 预取前后各一张的全尺寸显示图。
    private func prefetchNeighbors(of photo: PhotoItem, fullHDR: Bool) {
        let photos = items
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        for delta in [1, -1] {
            var next = index + delta
            if next < 0 { next = photos.count - 1 }
            if next >= photos.count { next = 0 }
            let target = photos[next]
            guard !target.isVideo, !target.isCloud else { continue }
            ImageLoader.prefetchDisplay(for: target, sdr: !fullHDR)
        }
    }
}
