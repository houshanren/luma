import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var viewer: ViewerModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// 主窗口与全局空格键监听：相簿 / 媒体类型 / 人物 / 地点等任意照片网格都能用空格打开查看。
    @State private var hostWindow: NSWindow?
    @State private var spaceMonitor: Any?
    /// 当前侧边栏可见性；视频全屏时临时切到 `.detailOnly`，退出后恢复。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var columnVisibilityBeforeFullScreen: NavigationSplitViewVisibility = .all
    /// 进入视频全屏前的窗口尺寸，退出全屏后还原。
    @State private var windowFrameBeforeFullScreen: NSRect?

    var body: some View {
        ZStack {
            if store.needsLibrarySetup {
                LibrarySetupView()
                    .environmentObject(store)
                    .toolbar(.hidden, for: .windowToolbar)
                    .transition(.opacity)
            } else if store.libraryPickerOnLaunch {
                // 启动占位：选定图库之前不打开任何图库。此时主窗口已被选取图库窗口整窗隐藏，
                // 这里的空白环境光只兜住隐藏生效前一瞬间的画面。
                LumaAmbientBackground()
                    .toolbar(.hidden, for: .windowToolbar)
                    .transition(.opacity)
            } else {
                mainContent
            }

            ToastView()
                .zIndex(4)

            // 删除前的确认卡片：盖在网格、查看器与编辑器之上，确认后才真正删除。
            if let request = store.pendingDeletion {
                DeleteConfirmOverlay(request: request)
                    .environmentObject(store)
                    .environmentObject(settings)
                    .transition(.opacity)
                    .zIndex(8)
            }

            // 断开系统图库 / 网络存储前的确认卡片。
            if let request = store.pendingDisconnect {
                DisconnectConfirmOverlay(request: request)
                    .environmentObject(store)
                    .environmentObject(settings)
                    .transition(.opacity)
                    .zIndex(8)
            }
        }
        .sheet(isPresented: $store.showNewAlbumSheet) {
            NewAlbumSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showKeywordManager) {
            KeywordManagerView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showCompressionSheet) {
            CompressionSheetView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showShortcutHelp) {
            ShortcutHelpView(showsCloseButton: true)
        }
        .sheet(isPresented: $store.showAIAssistant) {
            AIAssistantView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $store.showBeautyPanel) {
            BeautyRecommendView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $cloud.showSheet) {
            CloudConnectSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $cloud.showWizard) {
            CloudSetupWizardView()
                .environmentObject(store)
        }
        .sheet(item: $cloud.nameRequest) { request in
            CloudNameSheet(request: request)
                .environmentObject(store)
        }
        .sheet(item: $store.editingSmartAlbum) { album in
            SmartAlbumEditorView(album: album)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showBatchChangeSheet) {
            BatchChangeView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showExportSheet) {
            ExportOptionsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showPhotoPicker) {
            PhotoPickerSheet()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
        }
        .onChange(of: store.showImportSheet) { _, visible in
            if visible {
                openWindow(id: "import")
            } else {
                dismissWindow(id: "import")
            }
        }
        .onChange(of: store.importPanelOpenRequest) { _, _ in
            openWindow(id: "import")
        }
        .onChange(of: store.showLibraryPicker) { _, visible in
            syncLibraryPickerWindow(visible: visible)
        }
        // 视频全屏：进入系统全屏时收起侧边栏，退出时恢复进入前的状态。
        // 用 willEnter 而不是 didEnter：侧边栏与系统全屏动画同时开始，避免先看到一条完整侧边栏。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            FullScreenDiagnostics.log("willEnter frame=\(window.frame)")
            beginVideoImmersiveFullScreenIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            FullScreenDiagnostics.log("didExit frame=\(window.frame)")
            endVideoImmersiveFullScreen()
            restoreWindowFrameAfterFullScreen()
        }
        .onChange(of: viewer.viewerID) { _, newValue in
            FullScreenDiagnostics.log("viewerID -> \(String(describing: newValue)) immersive=\(viewer.videoImmersiveFullScreen)")
            // 全屏里直接关掉查看器：只退出全屏，布局与侧边栏等系统退出后再恢复，
            // 避免退出动画途中改布局把窗口尺寸算歪（反复进出会让窗口越来越矮）。
            guard newValue == nil, viewer.videoImmersiveFullScreen else { return }
            hostWindow?.toggleFullScreen(nil)
        }
        .onOpenURL { url in
            store.handleOpenedLibrary(url)
        }
        .task(id: store.visibleCount) {
            guard ProcessInfo.processInfo.environment["LUMA_OPEN_FIRST"] != nil,
                  store.viewerID == nil else { return }
            let wantsVideo = ProcessInfo.processInfo.environment["LUMA_OPEN_VIDEO"] != nil
            let target = wantsVideo
                ? store.visiblePhotos.first(where: { $0.isVideo })
                : store.visiblePhotos.first(where: { !$0.isVideo })
            guard let target else { return }
            store.openViewer(target.id)
        }
        .preferredColorScheme(settings.appearance.colorScheme)
        // tint 负责控件（滑杆、开关、按钮），accentColor 让 Color.accentColor（选中框、高亮、强调文字）
        // 解析成同一个颜色，避免出现「滑杆粉色、选中框蓝色」两套配色。
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .animation(settings.motion.overlay, value: viewer.viewerID == nil)
        .animation(settings.motion.overlay, value: viewer.editorID == nil)
        .animation(settings.motion.overlay, value: store.showSlideshow)
        .animation(settings.motion.overlay, value: store.activeMemory?.id)
        .animation(settings.motion.overlay, value: store.activeTrip?.id)
        .animation(settings.motion.overlay, value: store.pendingDeletion?.id)
        .animation(settings.motion.overlay, value: store.pendingDisconnect?.id)
        .background(WindowAccessor { window in
            if hostWindow !== window { hostWindow = window }
            // 选取图库窗口打开期间主窗口不能露出框架：捕获到窗口就立刻隐藏，
            // 覆盖按住 Option 启动、主窗口刚建好就被前置的首帧。
            if store.showLibraryPicker, let window {
                window.orderOut(nil)
            }
        })
        .onAppear {
            installSpaceMonitor()
            // 按住 Option 启动：store 在 init 里已置位，这里直接开选择器窗口。
            if store.showLibraryPicker { syncLibraryPickerWindow(visible: true) }
        }
        .task {
            // 启动兜底：极端时序下 onAppear 里的 openWindow 可能被 SwiftUI 丢弃，
            // 主窗口已隐藏而选择器没弹出会让应用看起来「无窗口」。稍后补开一次。
            try? await Task.sleep(nanoseconds: 500_000_000)
            if store.showLibraryPicker { openWindow(id: "libraryPicker") }
        }
        .onDisappear { removeSpaceMonitor() }
    }

    // MARK: - 选取图库窗口

    /// 图库选择器走独立小窗口（对齐系统「照片」）：打开期间主窗口整窗隐藏（含框架），
    /// 选定 / 取消 / 红叉关闭后由 `showLibraryPicker` 归零触发恢复。
    /// 不能改回挂主窗口的 sheet：sheet 是主窗口的子窗口，主窗口一隐藏 sheet 会跟着消失。
    private func syncLibraryPickerWindow(visible: Bool) {
        if visible {
            openWindow(id: "libraryPicker")
            hostWindow?.orderOut(nil)
            // 下一帧再补一次：兜住启动过程中 SwiftUI 把主窗口重新前置的时序。
            DispatchQueue.main.async {
                hostWindow?.orderOut(nil)
            }
        } else {
            dismissWindow(id: "libraryPicker")
            hostWindow?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 空格键

    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleSpaceKey(event) ? nil : event
        }
    }

    private func removeSpaceMonitor() {
        if let spaceMonitor {
            NSEvent.removeMonitor(spaceMonitor)
            self.spaceMonitor = nil
        }
    }

    /// 空格：任意照片网格里打开所选照片，查看器里再次按下收起（由查看器自己的键盘处理）。
    /// 放在 RootView 是为了让相簿 / 媒体类型 / 人物 / 地点 / 重复项等所有页面行为一致。
    private func handleSpaceKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        guard let window = hostWindow ?? event.window,
              event.window === window,
              window.attachedSheet == nil else { return false }
        // 查看器 / 编辑器 / 幻灯片 / 回忆 / 行程 / 确认卡片 / 文本输入都交给各自的处理器。
        guard store.viewerID == nil, store.editorID == nil,
              !store.showSlideshow, store.activeMemory == nil, store.activeTrip == nil,
              !store.hasPendingConfirmation else { return false }
        let responder = window.firstResponder
        if responder is NSTextView || responder is NSTextField { return false }
        guard !store.selection.isEmpty else { return false }
        store.openSelectionInViewer()
        return true
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            ZStack {
                // 环境光垫在内容之下：磨砂侧边栏、浮动胶囊与网格间隙都能透出颜色。
                LumaAmbientBackground()
                GalleryView()
                if settings.viewerLayout == .window, viewer.viewerID != nil {
                    PhotoViewerView(embedded: true)
                        // 视频真全屏：查看器自身伸进顶部安全区，把工具栏空出来的那一条吃掉。
                        // 只加在组件上、不加在整窗或分栏上，避免影响窗口尺寸计算。
                        .ignoresSafeArea(edges: viewer.videoImmersiveFullScreen ? .all : [])
                        .background(Color(nsColor: .windowBackgroundColor))
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(toolbarHidden ? .hidden : .visible, for: .windowToolbar)

        if store.viewerPhoto != nil, settings.viewerLayout == .fullscreen {
            PhotoViewerView()
                .transition(.opacity.combined(with: .scale(scale: settings.motion.viewerScale)))
                .zIndex(2)
        }

        if let editorID = viewer.editorID, let photo = store.photo(id: editorID) {
            PhotoEditorView(photo: photo)
                .transition(.opacity.combined(with: .scale(scale: settings.motion.viewerScale)))
                .zIndex(3)
        }

        if store.showSlideshow {
            SlideshowView()
                .environmentObject(store)
                .transition(.opacity)
                .zIndex(6)
        }

        if let trip = store.activeTrip {
            TripStoryView(trip: trip)
                .environmentObject(store)
                .environmentObject(settings)
                .transition(.opacity)
                .zIndex(6.5)
        }

        if let memory = store.activeMemory {
            MemoryMovieView(memory: memory)
                .environmentObject(store)
                .transition(.opacity)
                .zIndex(7)
        }
    }

    /// 进入系统全屏且当前看的是视频：隐藏侧边栏，画面独占整个窗口。
    private func beginVideoImmersiveFullScreenIfNeeded() {
        guard viewer.viewerID != nil, store.viewerPhoto?.isVideo == true else { return }
        guard !viewer.videoImmersiveFullScreen else { return }
        // 记住进入前的窗口尺寸：反复进出全屏时，AppKit 会按内容算回退尺寸，
        // 不还原就会一次比一次矮。
        if let window = hostWindow, !window.styleMask.contains(.fullScreen) {
            windowFrameBeforeFullScreen = window.frame
        }
        columnVisibilityBeforeFullScreen = columnVisibility
        viewer.videoImmersiveFullScreen = true
        FullScreenDiagnostics.log("begin immersive savedFrame=\(String(describing: windowFrameBeforeFullScreen))")
        // 不叠加 SwiftUI 动画：系统正在播放全屏动画，两套动画同时改侧边栏
        // 会把分栏停在「侧边栏已收起、详情列还是旧宽度」的中间态。
        columnVisibility = .detailOnly
    }

    /// 退出全屏：恢复进入前的侧边栏可见性，顶栏随全屏状态自动恢复。
    private func endVideoImmersiveFullScreen() {
        guard viewer.videoImmersiveFullScreen else { return }
        viewer.videoImmersiveFullScreen = false
        FullScreenDiagnostics.log("end immersive")
        columnVisibility = columnVisibilityBeforeFullScreen
    }

    /// 退出全屏后把窗口拉回进入前的尺寸，避免多次进出后窗口越来越矮。
    private func restoreWindowFrameAfterFullScreen() {
        guard let frame = windowFrameBeforeFullScreen, let window = hostWindow else { return }
        windowFrameBeforeFullScreen = nil
        // 等系统退出全屏的回位动画和窗口 frame 自动保存都结束再钉回原尺寸，
        // 太早设置会被 AppKit 后续的回位覆盖掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            FullScreenDiagnostics.log("restore frame saved=\(frame) current=\(window.frame)")
            window.setFrame(frame, display: true)
        }
    }

    private var toolbarHidden: Bool {
        // 窗口内浏览保留统一工具栏：返回、缩放、拍摄时间与操作都放在工具栏里。
        // 视频全屏时不再显式隐藏工具栏：交给系统全屏自动收起（鼠标移到顶部才出现），
        // 显式隐藏会让 SwiftUI 在进出全屏时改窗口内容高度，反复进出窗口就会越退越矮。
        viewer.editorID != nil
            || (viewer.viewerID != nil && settings.viewerLayout == .fullscreen)
    }
}

/// 临时诊断：视频全屏进出与窗口尺寸问题排查用，定位后删除。
enum FullScreenDiagnostics {
    static func log(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/luma-fs.log")
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)\n"
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
