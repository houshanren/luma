import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoViewerView {
    /// 查看器放大上限：500% 看不清截图里的文字与焦点，放宽到 1600%。
    /// 圆环、加减按钮、捏合与滚轮共用这一个上限。
    static let maxZoom: CGFloat = 16

    // MARK: - Zoom math

    func fittedSize(_ image: NSImage, in stage: CGSize) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0, stage.width > 0, stage.height > 0 else {
            return .zero
        }
        let scale = min(stage.width / size.width, stage.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func clampedOffset(_ proposed: CGSize, stage: CGSize,
                               fitted: CGSize, zoom: CGFloat) -> CGSize {
        guard zoom > 1 else { return .zero }
        let maxX = max(0, (fitted.width * zoom - stage.width) / 2)
        let maxY = max(0, (fitted.height * zoom - stage.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    /// 以某个视图坐标为锚点缩放，保持该点下的画面不动。
    func zoomedOffset(around location: CGPoint, stage: CGSize,
                              oldZoom: CGFloat, oldOffset: CGSize, newZoom: CGFloat) -> CGSize {
        let p = CGPoint(x: location.x - stage.width / 2, y: location.y - stage.height / 2)
        let q = CGPoint(x: (p.x - oldOffset.width) / max(oldZoom, 0.0001),
                        y: (p.y - oldOffset.height) / max(oldZoom, 0.0001))
        return CGSize(width: p.x - q.x * newZoom, height: p.y - q.y * newZoom)
    }

    func magnifyGesture(stage: CGSize, fitted: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = zoom
                    pinchStartOffset = offset
                }
                guard let startZoom = pinchStartZoom else { return }
                let newZoom = min(Self.maxZoom, max(1, startZoom * value.magnification))
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

    func panGesture(stage: CGSize, fitted: CGSize,
                            bottomGuard: CGFloat = 0) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                // 视频底部是播放控件（进度条可拖动），从这一区域开始的拖动留给播放器。
                if bottomGuard > 0, value.startLocation.y > stage.height - bottomGuard { return }
                let proposed = CGSize(width: baseOffset.width + value.translation.width,
                                      height: baseOffset.height + value.translation.height)
                offset = clampedOffset(proposed, stage: stage, fitted: fitted, zoom: zoom)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    func toggleZoom(at location: CGPoint, stage: CGSize, fitted: CGSize) {
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

    func adjustZoom(by factor: CGFloat) {
        let oldZoom = zoom
        let target = min(Self.maxZoom, max(1, zoom * factor))
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

    func resetZoom() {
        withAnimation(.easeInOut(duration: 0.22)) {
            zoom = 1
            offset = .zero
        }
        baseOffset = .zero
        pinchStartZoom = nil
    }

    func chrome(_ photo: PhotoItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                circleButton("xmark") { store.closeViewer() }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DateText.fullFormatter.string(from: photo.capturedAt))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(burstTitle ?? photo.displayTitle)
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

                if burstMembers.count > 1 {
                    circleButton(viewer.burstPlaying ? "pause.fill" : "play.fill") {
                        toggleBurstPlayback()
                    }
                    .help(viewer.burstPlaying ? "暂停连拍播放 (P)" : "播放连拍快照 (P)")
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

                if !photo.isVideo,
                   !photo.isReadOnly || (photo.isSystem && store.canWriteSystemLibrary) {
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
                        store.confirmDelete([photo.id])
                    }
                    .help("删除")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.top, 16)

            Spacer()

            if settings.viewerFilmstrip, totalCount > 1, !photo.isVideo,
               viewer.burstSelectionMode || burstMembers.isEmpty {
                FilmstripView(items: items,
                              currentID: photo.id,
                              selection: viewer.burstSelectionMode && !burstMembers.isEmpty
                                  ? viewer.burstSelection : nil) { id in
                    if viewer.burstSelectionMode, !burstMembers.isEmpty {
                        store.toggleBurstSelection(id)
                    } else {
                        viewer.viewerID = id
                    }
                }
                .padding(.bottom, 10)
            }

            HStack(spacing: 12) {
                if viewer.burstSelectionMode, !burstMembers.isEmpty {
                    Text("已选 \(viewer.burstSelection.count) / \(burstMembers.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                    Button("全选") { store.selectAllBurstMembers() }
                        .buttonStyle(.plain)
                    Button {
                        store.favoriteBurstSelection()
                    } label: {
                        Image(systemName: "heart")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewer.burstSelection.isEmpty)
                    .help("收藏所选")
                    Button {
                        confirmBurstKeep = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewer.burstSelection.isEmpty)
                    .help("保留所选，删除其余")
                    Button("完成") {
                        endBurstSelection()
                    }
                    .buttonStyle(.plain)
                    .help("完成连拍选择")
                } else {
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
            }
            .foregroundStyle(.white.opacity(0.9))
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

    func moreMenu(_ photo: PhotoItem) -> some View {
        Menu {
            Button("导出…") { store.export(photo.id) }
            Button("打印…") { store.printCommand() }
            // 窗口内浏览时，幻灯片 / 胶片条 / 信息 / 收藏 / 共享都在工具栏右侧有独立按钮，
            // 菜单里不再重复；全屏查看器的顶部只有一排圆钮，这些入口继续保留在这里。
            if !embedded {
                Button("幻灯片播放") { store.presentSlideshow() }
                Button(settings.viewerFilmstrip ? "隐藏底部缩略图" : "显示底部缩略图") {
                    settings.viewerFilmstrip.toggle()
                }
                Button(viewer.showInfoPanel ? "隐藏信息面板" : "显示信息面板") {
                    viewer.showInfoPanel.toggle()
                }
                if !photo.isReadOnly || photo.isCloud || store.canEditNativeOverlay {
                    Button(photo.isFavorite ? "取消收藏" : "收藏") {
                        store.toggleFavorite(photo.id)
                    }
                }
                ShareLink(items: store.shareURLs) {
                    Text("共享…")
                }
                .disabled(store.shareURLs.isEmpty)
            }
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
                    store.confirmDelete([photo.id])
                }
            }
        } label: {
            // 工具栏里与其他图标同尺寸、同风格，不自绘圆底；
            // 全屏查看器顶部是一排圆形材质按钮，这里保持同样的圆钮外观。
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: embedded ? 26 : 34, height: embedded ? 24 : 34)
                .background {
                    if !embedded {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    if !embedded {
                        Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                    }
                }
                .shadow(color: .black.opacity(embedded ? 0 : 0.18), radius: 6, y: 2)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    var zoomControls: some View {
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
            .disabled(zoom >= Self.maxZoom - 0.001)

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

    func installViewerKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleViewerKey(event) ? nil : event
        }
    }

    func removeViewerKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - 滚轮缩放

    func installViewerScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleViewerScroll(event) ? nil : event
        }
    }

    func removeViewerScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    func handleViewerScroll(_ event: NSEvent) -> Bool {
        guard viewer.viewerID != nil, viewer.editorID == nil else { return false }
        guard let window = hostWindow ?? event.window, event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard abs(event.scrollingDeltaY) > 0.01 || abs(event.scrollingDeltaX) > 0.01 else { return false }

        // 在胶片条、信息面板、顶部工具栏上滚动时不缩放，避免抢走滚动操作。
        if let content = window.contentView {
            let point = content.convert(event.locationInWindow, from: nil)
            if point.y < 150 { return false }
            if point.y > content.bounds.height - 70 { return false }
            if viewer.showInfoPanel, point.x > content.bounds.width - 310 { return false }
        }

        // 已放大：双指滚动改为拖动画面（照片和视频一致），边界与鼠标拖动相同。
        if zoom > 1.001 {
            let fitted = stageFittedSize()
            guard fitted.width > 0 else { return false }
            let proposed = CGSize(width: baseOffset.width + event.scrollingDeltaX,
                                  height: baseOffset.height + event.scrollingDeltaY)
            offset = clampedOffset(proposed, stage: stageSize, fitted: fitted, zoom: zoom)
            baseOffset = offset
            return true
        }

        // 未放大：窗口内查看不拦截滚动；全屏时双指滚动仍用于放大。
        guard !embedded else { return false }
        let delta = event.scrollingDeltaY
        let factor = min(1.3, max(0.72, 1 + delta * 0.02))
        let target = min(Self.maxZoom, max(1, zoom * factor))
        guard abs(target - zoom) > 0.0005 else { return false }
        zoom = target
        if target <= 1.01 {
            offset = .zero
            baseOffset = .zero
        }
        pinchStartZoom = nil
        return true
    }

    /// 当前画面的实际显示尺寸：双指拖动时用来限制可移动范围。
    func stageFittedSize() -> CGSize {
        guard stageSize.width > 0, stageSize.height > 0 else { return .zero }
        guard photo?.isVideo != true,
              let shown = image ?? animatedImage ?? placeholder else { return stageSize }
        return fittedSize(shown, in: stageSize)
    }

    func handleViewerKey(_ event: NSEvent) -> Bool {
        guard let window = hostWindow ?? event.window else { return false }
        guard event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        // 确认卡片打开时，把键盘交给卡片。
        guard !store.hasPendingConfirmation else { return false }
        guard viewer.viewerID != nil, viewer.editorID == nil, store.activeMemory == nil else { return false }
        guard let photo else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 连拍选择模式：Esc 只退出选择、空格切换当前照片的勾选，都不关闭查看器。
        if viewer.burstSelectionMode {
            if event.keyCode == 53 {
                endBurstSelection()
                return true
            }
            if event.keyCode == 49,
               flags.intersection([.shift, .option, .command, .control]).isEmpty {
                store.toggleBurstSelection(photo.id)
                return true
            }
        }

        // 照片与视频通用的命令。
        if flags.contains(.command) {
            if event.keyCode == 51 {
                if photo.isCloud {
                    store.confirmDeleteCloud([photo.id])
                } else if !photo.isSystem {
                    if flags.contains(.option) {
                        store.confirmPermanentDelete([photo.id])
                    } else {
                        store.confirmDelete([photo.id])
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
        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于这条守卫匹配。
        if handleCustomShortcut(event, photo: photo) { return true }

        guard flags.intersection([.option, .control]).isEmpty else { return false }

        // 连拍：P 播放 / 暂停整组帧序列。
        if burstMembers.count > 1, event.charactersIgnoringModifiers?.lowercased() == "p" {
            toggleBurstPlayback()
            return true
        }

        // 空格：与系统「照片」一致，打开后再次按下即收起查看器回到图库。
        // 长按的重复事件不处理，避免「刚打开又被关掉」的闪烁。
        if event.keyCode == 49, !event.isARepeat,
           flags.intersection([.shift, .option, .control]).isEmpty {
            store.closeViewer()
            return true
        }

        // 视频的方向键、空格等由播放器自行处理。
        guard !photo.isVideo else { return false }

        switch event.keyCode {
        case 123, 126:
            store.viewerStep(-1)
            return true
        case 124, 125:
            store.viewerStep(1)
            return true
        default:
            return false
        }
    }

    /// 设置 › 快捷键里可自定义的查看器动作。
    /// 放在修饰键守卫之前，才能支持 ⌥ / ⌃ / ⇧ 组合；⌘ 组合仍留给系统菜单。
    func handleCustomShortcut(_ event: NSEvent, photo: PhotoItem) -> Bool {
        if (!photo.isReadOnly || photo.isCloud),
           ShortcutStore.matches(event, .viewerFavorite) {
            store.toggleFavorite(photo.id)
            return true
        }
        if ShortcutStore.matches(event, .viewerInfo) {
            // 视频播放时 I 属于播放信息（VideoPlayerStage 自己处理），
            // 这里不能抢成照片「信息」侧栏。
            guard !photo.isVideo else { return false }
            viewer.showInfoPanel.toggle()
            return true
        }
        if ShortcutStore.matches(event, .viewerZoomIn) {
            adjustZoom(by: 1.35)
            return true
        }
        if ShortcutStore.matches(event, .viewerZoomOut) {
            adjustZoom(by: 1 / 1.35)
            return true
        }
        if ShortcutStore.matches(event, .viewerZoomFit) {
            resetZoom()
            return true
        }

        guard !photo.isVideo else { return false }

        if photo.isLivePhoto, ShortcutStore.matches(event, .viewerLivePhoto) {
            toggleLivePhoto()
            return true
        }
        if (!photo.isReadOnly || (photo.isSystem && store.canWriteSystemLibrary)),
           ShortcutStore.matches(event, .viewerEdit) {
            store.openEditor(photo.id)
            return true
        }
        if ShortcutStore.matches(event, .viewerFullscreen) {
            NSApp.keyWindow?.toggleFullScreen(nil)
            return true
        }
        return false
    }

    func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
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
}
