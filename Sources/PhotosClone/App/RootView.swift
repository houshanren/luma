import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var viewer: ViewerModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            if store.needsLibrarySetup {
                LibrarySetupView()
                    .environmentObject(store)
                    .toolbar(.hidden, for: .windowToolbar)
                    .transition(.opacity)
            } else {
                mainContent
            }

            ToastView()
                .zIndex(4)
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
        .sheet(isPresented: $store.showLibraryPicker) {
            LibraryPickerView()
                .environmentObject(store)
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
        .onOpenURL { url in
            store.handleOpenedLibrary(url)
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
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                GalleryView()
                if settings.viewerLayout == .window, viewer.viewerID != nil {
                    PhotoViewerView(embedded: true)
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

    private var toolbarHidden: Bool {
        viewer.viewerID != nil || viewer.editorID != nil
    }
}
