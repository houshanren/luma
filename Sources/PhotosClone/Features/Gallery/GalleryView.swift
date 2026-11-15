import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GalleryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selectionModel: SelectionModel
    @State private var isDropTarget = false
    @State private var keyMonitor: Any?
    @State private var pinchBase: Double?
    @State private var lastGridWidth: CGFloat = 900
    @State private var hostWindow: NSWindow?
    /// 单元格位置用引用类型缓存：滚动时偏好值频繁变化，不能触发整页重排。
    @State private var frameCache = PhotoFrameCache()
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBase: Set<UUID> = []
    /// 从照片内部按下时让位给系统拖拽，避免同时触发框选。
    @State private var marqueeBlockedStart: CGPoint?
    /// 浮动信息卡：可拖动位置、可拖右下角调整大小（双击标题复位）。
    @State private var infoPanelSize = CGSize(width: 400, height: 560)
    @State private var infoPanelOffset: CGSize = .zero
    @State private var infoDragOrigin: CGSize?
    @State private var infoResizeOrigin: CGSize?
    /// 系统图库（十万～几十万项）网格首屏只渲染这么多项，滚动到底再继续追加，
    /// 避免每次选中或切换都让 SwiftUI 对整库做 diff。
    @State private var systemRenderLimit = 1_200

    private var isGridScope: Bool {
        switch store.sidebarItem {
        case .collections, .systemCollections, .map, .places, .systemMap, .systemPlaces, .systemPeople,
             .allAlbums, .folder, .systemFolder, .people, .duplicates, .health,
             .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes,
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages,
             .systemDuplicates:
            return false
        default:
            // 网络存储也使用照片网格：排序、筛选、搜索、缩放与键盘导航一致可用。
            return true
        }
    }

    private var isPlacesScope: Bool {
        store.sidebarItem == .places || store.sidebarItem == .systemPlaces
    }

    /// 需要缩放控件的范围：照片/相簿网格，以及人物、位置这类卡片墙。
    private var supportsZoomControl: Bool {
        if isGridScope { return true }
        switch store.sidebarItem {
        case .allAlbums, .folder, .systemFolder, .people, .systemPeople, .places, .systemPlaces,
             .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes,
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages:
            return true
        default: return false
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                content(width: proxy.size.width)
                    .transition(.opacity)
                if showsCountPill {
                    countPill
                        .padding(.bottom, 16)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                SelectionBar()
                if store.showLibraryInfo {
                    libraryInfoPanel(container: proxy.size)
                        .padding(.top, 10)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(infoPanelOffset)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(3)
                }
            }
        }
        .task(id: store.pagedKey) {
            // 大图库：筛选/排序/分段下推到 SQLite，这里只加载窗口的第一页。
            store.reloadVisibleWindowIfNeeded()
        }
        .navigationTitle(store.sidebarTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let parent = store.navigationParent {
                    Button {
                        store.navigateUp()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text(parent.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .leading)
                        }
                    }
                    .help("返回\(parent.title)")
                    .accessibilityLabel("返回\(parent.title)")
                }
            }
            ToolbarItem(placement: .navigation) {
                if supportsZoomControl {
                    zoomControl
                }
            }
            ToolbarItem(placement: .principal) {
                if isGridScope, store.isTimelineScope {
                    Picker("分组", selection: $store.grouping) {
                        ForEach(GridGrouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                    .help("按时间分组")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isGridScope {
                    layoutMenu
                    sortMenu
                    filterMenu
                }
                assistantButton
                ellipsisMenu
                infoButton
                shareButton
                favoriteButton
            }
        }
        .searchableIf(!isPlacesScope, text: $store.searchText,
                      prompt: "搜索名称、场景、图内文字（试试：去年 海边 狗）")
        .onChange(of: store.searchText) { _, _ in
            store.prepareSemanticSearch()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTarget {
                dropOverlay
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if store.isImporting, let progress = store.importProgress {
                    Button {
                        store.requestImportPanel()
                    } label: {
                        HStack(spacing: 8) {
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                                .frame(width: 130)
                            Text("导入中 \(progress.completed.formatted()) / \(progress.total.formatted())")
                                .font(.system(size: 11, design: .monospaced))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("打开导入窗口")
                }

                if store.isLoadingSystemLibrary, store.isSystemScope {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(store.systemScanCount > 0
                             ? "正在读取系统图库… \(store.systemScanCount.formatted()) 项"
                             : "正在读取系统图库…")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                }

                if store.similarScope != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                        Text(store.sidebarTitle)
                            .font(.system(size: 11))
                        Button("完成") { store.clearSimilarScope() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .help("退出相似照片范围")
                }
            }
            .padding(.top, 8)
        }
        .animation(settings.motion.overlay, value: store.showLibraryInfo)
        .animation(settings.motion.layout, value: store.sidebarItem)
        .animation(settings.motion.layout, value: store.thumbnailAspect)
        .onAppear { installKeyboardMonitor() }
        .onDisappear { removeKeyboardMonitor() }
        .background(
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
            }
        )
    }

    // MARK: - Keyboard

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSTextField
    }

    private var gridColumnCount: Int {
        let contentWidth = max(120, lastGridWidth - 40)
        let target = CGFloat(store.thumbSize)
        return max(1, Int((contentWidth + 4) / (target + 4)))
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = hostWindow ?? event.window else { return false }
        guard event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard isGridScope,
              store.viewerID == nil,
              store.editorID == nil,
              !store.showSlideshow,
              store.activeMemory == nil,
              store.activeTrip == nil,
              !store.showNewAlbumSheet,
              !store.showKeywordManager,
              !store.showImportSheet,
              !store.showShortcutHelp else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            // 文本输入中不劫持 ⌘A/⌘C/⌘F 等系统文本命令。
            if isEditingText { return false }
            if event.keyCode == 51 {
                guard !store.isReadOnlyScope else { return false }
                let ids = selectionModel.ids
                guard !ids.isEmpty else { return false }
                // 最近删除里再按删除就是永久删除（需确认）。
                if flags.contains(.option) || store.sidebarItem == .trash {
                    store.confirmPermanentDelete(ids)
                } else {
                    store.delete(ids)
                }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                store.selectAll()
                return true
            case "c":
                store.copySelectionToPasteboard()
                return true
            case "v":
                guard !store.isReadOnlyScope else { return false }
                store.pasteFromPasteboard()
                return true
            case "d":
                guard !store.isReadOnlyScope, !selectionModel.ids.isEmpty else { return false }
                store.duplicateCommand()
                return true
            case "f":
                store.focusSearchField()
                return true
            case "r":
                guard !store.isReadOnlyScope else { return false }
                store.rotateCommand(clockwise: !flags.contains(.option))
                return true
            case "0":
                store.thumbSize = 132
                return true
            default:
                return false
            }
        }
        // 方向键自带 Function / 小键盘标记，不能因此丢弃；
        // 只屏蔽会与菜单快捷键冲突的修饰键。
        guard flags.intersection([.option, .control]).isEmpty else { return false }

        // 正在输入搜索词且尚未选中任何项目时，把方向键留给文本输入。
        if isEditingText, selectionModel.ids.isEmpty { return false }

        switch event.keyCode {
        case 123:
            store.moveSelection(by: -1)
            return true
        case 124:
            store.moveSelection(by: 1)
            return true
        case 126:
            moveSelectionVertically(-1)
            return true
        case 125:
            moveSelectionVertically(1)
            return true
        case 47:
            guard !flags.contains(.shift), !selectionModel.ids.isEmpty,
                  store.canToggleFavorite else { return false }
            store.toggleFavoriteSelection()
            return true
        case 36, 49:
            guard !selectionModel.ids.isEmpty else { return false }
            store.openSelectionInViewer()
            return true
        case 53:
            guard !selectionModel.ids.isEmpty else { return false }
            store.clearSelection()
            return true
        default:
            return false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        #if DEBUG
        if CommandLine.arguments.contains("--debug-system-videos"), store.sidebarItem == .systemVideos {
            let _ = print("[ui] visible=\(store.visibleCount) total=\(store.systemPhotos.count) videos=\(store.systemPhotos.lazy.filter(\.isVideo).count) loading=\(store.isLoadingSystemLibrary) scan=\(store.systemScanCount)")
        }
        #endif
        switch store.sidebarItem {
        case .collections:
            CollectionsView()
        case .systemCollections:
            SystemCollectionsView()
        case .map, .systemMap:
            PhotoMapView()
        case .places, .systemPlaces:
            PlaceStatisticsView()
        case .duplicates:
            DuplicatesView()
        case .systemDuplicates:
            DuplicatesView(system: true)
        case .health:
            LibraryHealthView()
        case .allAlbums:
            AlbumsOverviewView()
        case .folder(let id):
            AlbumsOverviewView(folderID: id)
        case .systemFolder(let id):
            SystemFolderOverviewView(folderID: id)
        case .systemAlbums:
            SystemFolderOverviewView()
        case .mediaTypes, .systemMediaTypes:
            MediaTypesOverviewView()
        case .scenes:
            ScenesOverviewView()
        case .moreItems:
            MoreItemsOverviewView(system: false)
        case .systemMoreItems:
            MoreItemsOverviewView(system: true)
        case .systemLibraries:
            SystemLibrariesOverviewView()
        case .cloudStorages:
            CloudStoragesOverviewView()
        case .people, .systemPeople:
            PeopleView()
        case .cloudMount:
            CloudBrowserView()
        default:
            if store.visibleCount == 0 {
                if store.isPagedScope, store.isWindowLoading || !store.hasLoadedWindow {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在读取图库…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.isLoadingSystemLibrary, store.isSystemScope {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(store.systemScanCount > 0
                             ? "正在读取系统图库… \(store.systemScanCount.formatted()) 项"
                             : "正在读取系统图库…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView()
                }
            } else {
                photoGrid(width: width)
            }
        }
    }

    // MARK: - 底部计数胶囊

    /// 网格页没有选中项时，在底部居中显示当前范围的照片/视频总数（对齐系统「照片」）。
    private var showsCountPill: Bool {
        isGridScope && selectionModel.ids.isEmpty && store.visibleCount > 0
    }

    private var countPill: some View {
        HStack(spacing: 6) {
            Image(systemName: store.visibleVideoCount > 0 && store.visibleCount == store.visibleVideoCount
                  ? "video" : "photo.stack")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(countPillText)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .animation(settings.motion.overlay, value: countPillText)
        .accessibilityLabel(countPillText)
    }

    private var countPillText: String {
        let total = store.visibleCount
        let videos = store.visibleVideoCount
        let photos = total - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos.formatted()) 张照片") }
        if videos > 0 { parts.append("\(videos.formatted()) 个视频") }
        return parts.joined(separator: "、")
    }

    @ViewBuilder
    private func photoGrid(width: CGFloat) -> some View {
        if store.isTimelineScope {
            switch store.grouping {
            case .years:
                YearOverviewView(width: width)
            case .months:
                MonthOverviewView(width: width)
            case .all:
                allPhotosGrid(width: width)
            }
        } else {
            allPhotosGrid(width: width)
        }
    }

    /// 系统图库超大时按「首屏 1200 张」渐进渲染；本地图库仍走 SQL 分页窗口。
    private var systemWindowActive: Bool {
        store.isSystemScope && store.grouping == .all && store.visibleCount > 1_500
    }

    private var canLoadMoreSystemWindow: Bool {
        systemWindowActive && systemRenderLimit < store.visibleCount
    }

    /// 范围、筛选、搜索或排序变化时，把系统图库的渲染窗口收回首屏。
    private var systemWindowKey: String {
        [String(describing: store.sidebarItem), store.photoFilter.rawValue,
         store.keywordFilter ?? "", store.searchText,
         store.sortKey.rawValue, String(store.sortAscending)]
            .joined(separator: "\u{1F}")
    }

    private func windowedPhotos(_ photos: [PhotoItem]) -> [PhotoItem] {
        guard systemWindowActive, photos.count > systemRenderLimit else { return photos }
        return Array(photos.prefix(systemRenderLimit))
    }

    private func allPhotosGrid(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.sections) { section in
                        Section {
                            sectionGrid(photos: windowedPhotos(section.photos), width: width)
                        } header: {
                            if let title = section.title {
                                SectionHeaderView(title: title, count: section.photos.count)
                            }
                        }
                    }
                    if store.canLoadMoreVisible || canLoadMoreSystemWindow {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在加载更多…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .onAppear {
                            if store.canLoadMoreVisible {
                                store.loadMoreVisibleWindow()
                            } else if canLoadMoreSystemWindow {
                                systemRenderLimit += 1_200
                            }
                        }
                        .onChange(of: store.windowPhotos.count) { _, _ in
                            store.loadMoreVisibleWindow()
                        }
                        .help("继续加载更多照片")
                    }
                    Color.clear.frame(height: 76)
                }
                .coordinateSpace(name: "galleryGrid")
                .onPreferenceChange(PhotoFramePreferenceKey.self) { frames in
                    frameCache.frames = frames
                }
                .overlay(alignment: .topLeading) { marqueeOverlay }
                .simultaneousGesture(marqueeGesture)
            }
            .scrollIndicators(.automatic)
            .onAppear {
                lastGridWidth = width
                if let target = store.scrollTargetID {
                    DispatchQueue.main.async {
                        proxy.scrollTo(target, anchor: .center)
                        store.scrollTargetID = nil
                    }
                }
            }
            .onChange(of: width) { _, newValue in lastGridWidth = newValue }
            .onChange(of: systemWindowKey) { _, _ in systemRenderLimit = 1_200 }
            .simultaneousGesture(pinchGesture)
            .onChange(of: store.scrollTargetID) { _, target in
                guard let target else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                store.scrollTargetID = nil
            }
        }
    }

    /// 按用户选择的显示形式渲染一段照片：正方形 / 完整宽高比 / 瀑布流 / 列表。
    @ViewBuilder
    private func sectionGrid(photos: [PhotoItem], width: CGFloat) -> some View {
        switch store.thumbnailAspect {
        case .square:
            SquarePhotoGrid(photos: photos, availableWidth: width)
                .padding(.horizontal, 20)
                .padding(.bottom, 26)
        case .actual:
            JustifiedPhotoGrid(photos: photos,
                               availableWidth: width,
                               targetHeight: CGFloat(store.thumbSize) * 0.92)
                .padding(.horizontal, 20)
                .padding(.bottom, 26)
        case .masonry:
            MasonryPhotoGrid(photos: photos,
                             availableWidth: width,
                             targetWidth: CGFloat(store.thumbSize))
                .padding(.horizontal, 20)
                .padding(.bottom, 26)
        case .list:
            PhotoListView(photos: photos, availableWidth: width)
                .padding(.bottom, 20)
        }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: - 键盘上下移动

    /// 上下方向键按单元格的真实位置找「下一排」，落在正下方。
    /// 正方形与瀑布流、跨分段边界都适用；找不到可用行时退回按列数步进。
    private func moveSelectionVertically(_ direction: Int) {
        let frames = frameCache.frames
        guard let currentID = navigationAnchorID(), let current = frames[currentID] else {
            store.moveSelection(by: direction)
            return
        }

        let epsilon: CGFloat = 1
        let candidates = frames.filter { id, frame in
            guard id != currentID else { return false }
            return direction > 0
                ? frame.minY > current.minY + epsilon
                : frame.minY < current.minY - epsilon
        }
        guard !candidates.isEmpty else {
            // 下一排还没被 LazyVGrid 创建：按列数步进，触发滚动后再继续沿真实位置移动。
            store.moveSelection(by: direction * gridColumnCount)
            return
        }

        // 先锁定最近的一排（上方取最大 minY，下方取最小 minY），再选水平中心最近的一格。
        let targetY = direction > 0
            ? candidates.values.map(\.minY).min() ?? current.minY
            : candidates.values.map(\.minY).max() ?? current.minY
        let row = candidates.filter { abs($0.value.minY - targetY) <= 1.5 }
        guard let best = row.min(by: {
            abs($0.value.midX - current.midX) < abs($1.value.midX - current.midX)
        }) else { return }

        selectionModel.ids = [best.key]
        store.selectionAnchorID = best.key
        store.scrollTargetID = best.key
    }

    private func navigationAnchorID() -> UUID? {
        if let anchor = store.selectionAnchorID, selectionModel.ids.contains(anchor) {
            return anchor
        }
        return selectionModel.ids.first
    }

    // MARK: - 框选

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(x: min(start.x, current.x),
                      y: min(start.y, current.y),
                      width: abs(current.x - start.x),
                      height: abs(current.y - start.y))
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect, rect.width > 2, rect.height > 2 {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("galleryGrid"))
            .onChanged { value in
                if let blocked = marqueeBlockedStart {
                    if blocked == value.startLocation { return }
                    marqueeBlockedStart = nil
                }
                if marqueeStart == nil {
                    if frameCache.frames.values.contains(where: { $0.contains(value.startLocation) }) {
                        marqueeBlockedStart = value.startLocation
                        return
                    }
                    marqueeStart = value.startLocation
                    let flags = NSEvent.modifierFlags
                    let additive = flags.contains(.command) || flags.contains(.shift)
                    marqueeBase = additive ? selectionModel.ids : []
                    if !additive {
                        store.clearSelection()
                    }
                }
                marqueeCurrent = value.location
                guard let rect = marqueeRect else { return }
                let hits = frameCache.frames.filter { $0.value.intersects(rect) }.map { $0.key }
                selectionModel.ids = marqueeBase.union(hits)
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBase = []
                marqueeBlockedStart = nil
            }
    }

    // MARK: - Toolbar items

    /// 缩放控件：滑杆拖拽实时跟手（不加动画），按钮/快捷键才用短动画补间。
    private var zoomControl: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(settings.motion.layout) {
                    store.thumbSize = max(LibraryStore.thumbSizeRange.lowerBound, store.thumbSize - 16)
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.thumbSize <= LibraryStore.thumbSizeRange.lowerBound)
            .help("缩小")
            .accessibilityLabel("缩小")

            Slider(value: $store.thumbSize, in: LibraryStore.thumbSizeRange)
                .frame(width: 80)
                .controlSize(.mini)
                .accessibilityLabel(zoomControlTitle)

            Button {
                withAnimation(settings.motion.layout) {
                    store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound, store.thumbSize + 16)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.thumbSize >= LibraryStore.thumbSizeRange.upperBound)
            .help("放大")
            .accessibilityLabel("放大")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .help("\(zoomControlTitle)（⌘+ / ⌘- / ⌘0，或双指捏合）")
    }

    private var zoomControlTitle: String {
        switch store.sidebarItem {
        case .allAlbums, .folder, .systemFolder: return "相簿卡片大小"
        case .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes,
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages:
            return "卡片大小"
        case .people, .systemPeople: return "人物卡片大小"
        case .places, .systemPlaces: return "地点卡片大小"
        default: return "缩略图大小"
        }
    }

    private var layoutMenu: some View {
        Menu {
            // 用 Toggle 而不是 Button：菜单里当前正在使用的形式会带系统勾选标记。
            ForEach(ThumbnailAspect.allCases) { aspect in
                Toggle(isOn: Binding(
                    get: { store.thumbnailAspect == aspect },
                    set: { isOn in
                        guard isOn else { return }
                        withAnimation(settings.motion.layout) {
                            store.thumbnailAspect = aspect
                        }
                    }
                )) {
                    Text(aspect.title)
                }
            }
        } label: {
            Image(systemName: store.thumbnailAspect.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(store.thumbnailAspect == .square ? Color.primary : Color.accentColor)
                .frame(width: 26, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(store.thumbnailAspect == .square
                              ? Color.clear
                              : Color.accentColor.opacity(0.18))
                }
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换显示形式：正方形 / 完整宽高比 / 瀑布流 / 列表")
        .accessibilityLabel("显示形式")
        .accessibilityValue(store.thumbnailAspect.title)
    }

    private var isFiltering: Bool {
        store.photoFilter != .all || store.keywordFilter != nil
    }

    private var sortMenu: some View {
        Menu {
            Section("排序方式") {
                sortOptions()
            }
            Section("元数据") {
                metadataOptions()
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("排序与元数据")
        .accessibilityLabel("排序与元数据")
    }

    @ViewBuilder
    private func sortOptions() -> some View {
        ForEach(SortKey.allCases) { key in
            Button {
                store.applySort(key)
            } label: {
                Label(store.sortKey == key
                      ? "\(key.title) · \(store.sortAscending ? "升序 ↑" : "降序 ↓")"
                      : key.title,
                      systemImage: store.sortKey == key ? "checkmark" : key.icon)
            }
        }
        Divider()
        Button {
            store.sortAscending.toggle()
        } label: {
            Label(store.sortAscending ? "改为降序 ↓" : "改为升序 ↑",
                  systemImage: "arrow.up.arrow.down")
        }
    }

    @ViewBuilder
    private func metadataOptions() -> some View {
        Toggle("标题", isOn: $settings.metadata.title)
        Toggle("拍摄日期", isOn: $settings.metadata.capturedDate)
        Toggle("关键词", isOn: $settings.metadata.keywords)
        Toggle("已编辑", isOn: $settings.metadata.edited)
        Toggle("文件类型", isOn: $settings.metadata.fileType)
        Toggle("个人收藏", isOn: $settings.metadata.favorite)
        Toggle("位置", isOn: $settings.metadata.location)
        Toggle("相机", isOn: $settings.metadata.camera)
        Toggle("分辨率", isOn: $settings.metadata.resolution)
        Toggle("文件大小", isOn: $settings.metadata.fileSize)
        Toggle("来源", isOn: $settings.metadata.source)
        Toggle("视频时长", isOn: $settings.metadata.duration)
    }

    /// 网络存储没有「已编辑」与「相簿」概念，隐藏这两个无效筛选项。
    private var availableFilters: [PhotoFilter] {
        guard store.isCloudScope else { return PhotoFilter.allCases }
        return PhotoFilter.allCases.filter { $0 != .edited && $0 != .notInAlbum }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(availableFilters) { filter in
                Button {
                    store.photoFilter = filter
                } label: {
                    if store.photoFilter == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Label(filter.title, systemImage: filter.icon)
                    }
                }
            }

            Divider()

            if !store.isSystemScope, !store.isCloudScope, !store.keywordOptions.isEmpty {
                Section("关键词") {
                    ForEach(store.keywordOptions.prefix(10)) { option in
                        Button {
                            store.keywordFilter = option.name
                        } label: {
                            if store.keywordFilter == option.name {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Label(option.name, systemImage: "tag")
                            }
                        }
                    }
                    if store.keywordFilter != nil {
                        Button("清除关键词筛选") {
                            store.keywordFilter = nil
                        }
                    }
                }
            }

            if !store.isSystemScope, !store.isCloudScope {
                Button("管理关键词…") {
                    store.showKeywordManager = true
                }
            }
        } label: {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .foregroundStyle(isFiltering ? Color.accentColor : Color.primary)
        }
        .help("筛选")
        .accessibilityLabel("筛选")
    }

    /// 「更多」只放图库里没有独立入口的动作；排序、元数据、缩略图比例已在工具栏按钮与菜单栏中提供。
    private var ellipsisMenu: some View {
        Menu {
            if store.canImportCurrentSystemScope {
                Button(store.currentSystemScopeImportTitle) {
                    store.importCurrentSystemScopeToLibrary()
                }
                Divider()
            }

            if !selectionModel.ids.isEmpty, !store.isReadOnlyScope {
                Section("所选 \(selectionModel.ids.count) 项") {
                    Button("压缩所选…") {
                        store.presentCompression(for: selectionModel.ids)
                    }
                    Button("导出所选到文件夹…") {
                        store.presentBatchExport()
                    }
                }
                Divider()
            }

            Button(store.isImporting ? "查看导入…" : "导入照片…") {
                store.presentImportPanel()
            }
            if !store.isCloudScope {
                Button("在访达中显示图库") {
                    if store.isSystemScope {
                        store.revealSystemLibraryInFinder()
                    } else {
                        store.revealLibraryInFinder()
                    }
                }
            }
            if store.trashCount > 0 {
                Divider()
                Button("清空最近删除", role: .destructive) {
                    store.confirmEmptyTrash()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }

    private var assistantButton: some View {
        Button {
            store.showAIAssistant = true
        } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
        }
        .help("智能助手（只读问答与检索）")
        .accessibilityLabel("智能助手")
    }

    private var infoButton: some View {
        Button {
            store.showLibraryInfo.toggle()
        } label: {
            Image(systemName: store.showLibraryInfo ? "info.circle.fill" : "info.circle")
                .foregroundStyle(store.showLibraryInfo ? Color.accentColor : Color.primary)
        }
        .help("信息")
        .accessibilityLabel("信息面板")
    }

    /// 浮动信息卡：不随选择变化关闭，方向键切换照片时内容就地更新；
    /// 标题区域可拖动移动，右下角可拖动调整大小，双击标题复位。
    private func libraryInfoPanel(container: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("信息")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .gesture(infoPanelDragGesture(container: container))
                .onTapGesture(count: 2) { resetInfoPanel(container: container) }
                .help("拖动移动；双击复位")

                Button {
                    store.showLibraryInfo = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭信息")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Group {
                    if selectionModel.ids.count == 1,
                       let id = selectionModel.ids.first,
                       let photo = store.anyPhoto(id: id) {
                        PhotoQuickInfoView(photo: photo)
                    } else if store.isCloudScope {
                        CloudMountInfoView()
                    } else if store.isSystemScope {
                        SystemLibraryInfoView()
                    } else {
                        LibraryInfoView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: infoPanelSize.width, height: infoPanelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .gesture(infoPanelResizeGesture(container: container))
                .help("拖动调整大小")
                .padding(4)
        }
        .shadow(color: .black.opacity(0.20), radius: 22, y: 10)
    }

    private func infoPanelDragGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if infoDragOrigin == nil { infoDragOrigin = infoPanelOffset }
                guard let origin = infoDragOrigin else { return }
                infoPanelOffset = clampedInfoOffset(
                    CGSize(width: origin.width + value.translation.width,
                           height: origin.height + value.translation.height),
                    container: container)
            }
            .onEnded { _ in infoDragOrigin = nil }
    }

    private func infoPanelResizeGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if infoResizeOrigin == nil { infoResizeOrigin = infoPanelSize }
                guard let origin = infoResizeOrigin else { return }
                infoPanelSize = clampedInfoSize(
                    CGSize(width: origin.width + value.translation.width,
                           height: origin.height + value.translation.height),
                    container: container)
                infoPanelOffset = clampedInfoOffset(infoPanelOffset, container: container)
            }
            .onEnded { _ in infoResizeOrigin = nil }
    }

    private func resetInfoPanel(container: CGSize) {
        infoPanelSize = clampedInfoSize(CGSize(width: 400, height: 560), container: container)
        infoPanelOffset = .zero
    }

    private func clampedInfoSize(_ size: CGSize, container: CGSize) -> CGSize {
        let maxWidth = max(380, min(760, container.width - 60))
        let maxHeight = max(240, min(900, container.height - 90))
        return CGSize(width: min(max(380, size.width), maxWidth),
                      height: min(max(240, size.height), maxHeight))
    }

    private func clampedInfoOffset(_ offset: CGSize, container: CGSize) -> CGSize {
        let maxLeft = -(container.width - infoPanelSize.width - 28)
        let maxDown = container.height - infoPanelSize.height - 24
        return CGSize(width: min(0, max(maxLeft, offset.width)),
                      height: min(max(0, maxDown), max(0, offset.height)))
    }

    private var shareButton: some View {
        ShareLink(items: store.shareURLs) {
            Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .disabled(store.shareURLs.isEmpty)
        .help("共享")
        .accessibilityLabel("共享")
    }

    private var favoriteButton: some View {
        Button {
            store.toggleFavoriteCurrent()
        } label: {
            Image(systemName: store.currentIsFavorite ? "heart.fill" : "heart")
                .foregroundStyle(store.currentIsFavorite ? Color.pink : Color.primary)
        }
        .disabled(!store.canToggleFavorite
                  || (selectionModel.ids.isEmpty && store.viewerID == nil))
        .help(store.currentIsFavorite ? "取消收藏" : "收藏")
        .accessibilityLabel(store.currentIsFavorite ? "取消个人收藏" : "标记为个人收藏")
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.85),
                          style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            .background(Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 56, height: 56)
                        .background(.regularMaterial, in: Circle())
                    Text("松开以导入照片")
                        .font(.system(size: 14, weight: .semibold))
                    Text("支持照片、视频与文件夹")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            store.prepareImport(urls)
        }
        return true
    }
}
