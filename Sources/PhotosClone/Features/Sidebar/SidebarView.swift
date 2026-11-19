import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「固定」分区拖拽排序用的自定义类型，避免和照片拖拽（纯文本）互相干扰。
let pinnedSidebarDragType = UTType(exportedAs: "com.luma.sidebar-pinned-item")

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    /// 侧边栏相簿默认全部收起，只记录被用户展开的文件夹，避免一次渲染上千行。
    /// 展开 / 收起状态写入本地，下次启动沿用上次的层级。
    @State private var expandedFolders: Set<UUID> =
        SidebarStateStorage.uuidSet(SidebarStateStorage.Key.expandedFolders)
    @State private var expandedSystemFolders: Set<Int64> =
        SidebarStateStorage.int64Set(SidebarStateStorage.Key.expandedSystemFolders)
    @State private var collapsedSystemLibraries: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.collapsedSystemLibraries)
    @State private var hoveredItem: SidebarItem?
    /// 与 hoveredItem 搭配的分区标识：同一个相簿可能同时出现在「固定」和「相簿」里。
    @State private var hoveredItemScope: String = ""
    @State private var hoveredSystemFolder: Int64?
    @State private var hoveredSystemLibraryPath: String?
    /// 已收起的侧边栏分区（键为分区标识），同样持久化。
    @State private var collapsedSections: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.collapsedSections)
    /// 默认收起的分区被用户主动展开后的记录；没有记录时按默认收起。
    @State private var expandedSections: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.expandedSections)
    /// 每个图库默认收起「媒体类型」与「场景」，其余分区默认展开。
    private static let defaultCollapsedSections: Set<String> = [
        "luma.media", "luma.scenes", "sys.media", "sys.scenes"
    ]
    @State private var hoveredSection: String?
    @State private var namePrompt: NamePromptPayload?
    @State private var dropTargetAlbumID: UUID?
    /// 「场景」分区危险操作的二次确认：清空本地 / 系统图库分析结果、系统图库重新识别。
    @State private var showResetAnalysisConfirm = false
    @State private var showResetSystemAnalysisConfirm = false
    @State private var showRestartSystemAnalysisConfirm = false

    var body: some View {
        ScrollView {
            // 系统图库可能带成千上万个相簿，侧边栏必须懒加载，否则一次性创建全部行会卡死主线程。
            LazyVStack(alignment: .leading, spacing: 1) {
                if store.isNativeContainer {
                    // 打开的是官方「照片」图库：它就是当前图库，结构直接放在主侧边栏。
                    nativeLibrarySection
                } else {
                sectionHeader("拾光", key: "luma", topPadding: 4)
                if !isCollapsed("luma") {
                    sidebarRow(.library, icon: "photo.stack", title: "图库")
                    sidebarRow(.collections, icon: "square.stack.3d.up", title: "精选集")
                }

                sectionHeader("固定", key: "luma.fixed")
                if !isCollapsed("luma.fixed") {
                    pinnedRows(system: false)
                }

                sectionHeader("媒体类型", key: "luma.media", navigateTo: .mediaTypes)
                if !isCollapsed("luma.media") {
                    // 与系统「照片」一致：数量为 0 的媒体类型不占位。
                    ForEach(MediaTypeKey.localCases) { key in
                        if (mediaTypeCounts[key] ?? 0) > 0 {
                            sidebarRow(key.item(system: false), icon: key.icon, title: key.title,
                                       pinKey: key.rawValue)
                        }
                    }
                }

                sectionHeader("更多项目", key: "luma.more", navigateTo: .moreItems)
                if !isCollapsed("luma.more") {
                    // 顺序与「更多项目」总览页保持一致。
                    sidebarRow(.favorites, icon: "heart.fill", title: "个人收藏", color: .pink, pinKey: "favorites")
                    sidebarRow(.health, icon: "stethoscope", title: "图库体检", pinKey: "health")
                    sidebarRow(.ratings, icon: "square.grid.2x2", title: "图库整理", color: .yellow,
                               pinKey: "ratings")
                    sidebarRow(.revisit, icon: "clock.arrow.circlepath", title: "值得重看", pinKey: "revisit")
                    if store.duplicateCount > 0 {
                        sidebarRow(.duplicates, icon: "square.on.square", title: "重复项目", pinKey: "duplicates")
                    }
                    sidebarRow(.map, icon: "map", title: "地图", pinKey: "map")
                    sidebarRow(.places, icon: "mappin.and.ellipse", title: "位置", pinKey: "places")
                    sidebarRow(.people, icon: "person.crop.square", title: "人物", pinKey: "people")
                    sidebarRow(.keywords, icon: "tag", title: "关键词", pinKey: "keywords")
                    if store.analyzedCount > 0 {
                        sidebarRow(.ocrTexts, icon: "text.viewfinder", title: "包含文字", pinKey: "ocrTexts")
                    }
                    sidebarRow(.recentlyEdited, icon: "slider.horizontal.3", title: "最近编辑", pinKey: "recentlyEdited")
                    sidebarRow(.recentlySaved, icon: "square.and.arrow.down", title: "最近保存", pinKey: "recentlySaved")
                    trashRow(pinKey: "trash")
                    sidebarRow(.imports, icon: "square.and.arrow.down.on.square", title: "导入项目", pinKey: "imports")
                    if store.hiddenCount > 0 {
                        sidebarRow(.hidden, icon: "eye.slash", title: "已隐藏", color: .secondary, pinKey: "hidden")
                    }
                }

                sectionHeader("场景", key: "luma.scenes", navigateTo: .scenes) {
                    if store.isAnalyzingIntelligence {
                        Button("停止分析") { store.cancelIntelligenceAnalysis() }
                    } else {
                        Button(store.analyzedCount > 0 ? "分析新照片…" : "分析照片内容…") {
                            store.analyzeIntelligence()
                        }
                        if store.analyzedCount > 0 {
                            Button("重新分析全部照片…") {
                                store.reanalyzeIntelligence()
                            }
                            Button("重置（清空结果）…", role: .destructive) {
                                showResetAnalysisConfirm = true
                            }
                        }
                    }
                    if store.hasAnyScene {
                        Divider()
                        Button("生成场景智能相簿") {
                            store.createSceneSmartAlbums()
                        }
                    }
                }
                if !isCollapsed("luma.scenes") {
                    sceneSectionBody
                }

                sectionHeader("相簿", key: "luma.albums", navigateTo: .allAlbums) {
                    Button("新建相簿") {
                        store.showNewAlbumSheet = true
                    }
                    Button("新建智能相簿…") {
                        store.presentSmartAlbumEditor()
                    }
                }
                if !isCollapsed("luma.albums") {
                    sidebarRow(.allAlbums, icon: "rectangle.stack", title: "所有相簿")

                    ForEach(store.rootFolders()) { folder in
                        folderNode(folder, level: 0)
                    }
                    ForEach(store.rootAlbums) { album in
                        albumRow(album, level: 0)
                    }
                }

                if !store.smartAlbums.isEmpty {
                    sectionHeader("智能相簿", key: "luma.smart") {
                        Button("新建智能相簿…") {
                            store.presentSmartAlbumEditor()
                        }
                    }
                    if !isCollapsed("luma.smart") {
                        ForEach(store.smartAlbums) { album in
                            smartAlbumRow(album)
                        }
                    }
                }

                systemSection
                }
                cloudSection
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.never)
        // 环境光垫在材质下面：侧边栏不是一块死灰，而是一层带颜色的磨砂玻璃。
        .background {
            ZStack {
                LumaAmbientBackground(intensity: 0.75)
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [Color.white.opacity(0.05), .clear],
                               startPoint: .top, endPoint: .center)
            }
        }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [.clear, Color.primary.opacity(0.14), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 0.5)
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom) {
            // 官方「照片」图库只做增强层：不往 Apple 的图库里导入文件，因此不显示导入入口。
            if !store.isNativeContainer {
                importFooter
                    .background {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            LinearGradient(colors: [Color.primary.opacity(0.05), .clear],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
            }
        }
        // 允许拖拽到更窄（收起封面更紧凑）或更宽（长相簿名少截断）。
        .navigationSplitViewColumnWidth(min: 180, ideal: 248, max: 440)
        .sheet(item: $namePrompt) { payload in
            NamePromptSheet(payload: payload)
                .environmentObject(store)
        }
        .confirmationDialog("清空照片内容分析结果？",
                            isPresented: $showResetAnalysisConfirm,
                            titleVisibility: .visible) {
            Button("清空全部结果", role: .destructive) {
                store.resetIntelligenceAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除全部照片的场景标签、图内文字与相似检索特征（含已保存到图库的结果）；照片本身不受影响，之后可重新分析。")
        }
        .confirmationDialog("重新识别全部照片？",
                            isPresented: $showRestartSystemAnalysisConfirm,
                            titleVisibility: .visible) {
            Button("清空并重新识别", role: .destructive) {
                store.restartSystemAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空现有识别结果并从头识别整个系统图库，耗时较长；「照片」图库本身不受影响。")
        }
        .confirmationDialog("清空系统图库识别结果？",
                            isPresented: $showResetSystemAnalysisConfirm,
                            titleVisibility: .visible) {
            Button("清空全部结果", role: .destructive) {
                store.resetSystemAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本机保存的识别缓存（场景标签、图内文字与特征）；「照片」图库与照片本身不受影响，之后可重新识别。")
        }
    }

    private var importFooter: some View {
        Button {
            store.presentImportPanel()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: store.isImporting ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.isImporting ? "导入中…" : "导入照片")
                        .font(.system(size: 12, weight: .medium))
                    if let progress = store.importProgress {
                        HStack(spacing: 6) {
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                                .frame(width: 120)
                            Text("\(progress.completed.formatted())/\(progress.total.formatted())")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                if store.isImporting {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .help(store.isImporting ? "打开导入窗口" : "导入照片")
    }

    private func sidebarRow(_ item: SidebarItem,
                            icon: String,
                            title: String,
                            color: Color = .accentColor,
                            scope: String = "main",
                            pinKey: String? = nil) -> some View {
        SidebarCategoryRow(icon: icon,
                           title: title,
                           iconColor: color,
                           trailingIcon: pinKey == "trash" ? "lock.fill" : nil,
                           isActive: store.sidebarItem == item,
                           isHovered: hoveredItem == item && hoveredItemScope == scope,
                           action: { store.navigate(to: item) })
            .onHover { hovering in
                if hovering {
                    hoveredItem = item
                    hoveredItemScope = scope
                } else if hoveredItem == item && hoveredItemScope == scope {
                    hoveredItem = nil
                }
            }
            .contextMenu {
                if let pinKey {
                    Button(store.isPinned(.system(pinKey)) ? "取消固定" : "固定到侧边栏") {
                        store.togglePin(.system(pinKey))
                    }
                }
            }
    }

    private func trashRow(scope: String = "main", pinKey: String? = nil) -> some View {
        Button {
            store.navigate(to: .trash)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "trash")
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text("最近删除")
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: store.sidebarItem == .trash,
                                 hovered: hoveredItem == .trash && hoveredItemScope == scope)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = .trash
                hoveredItemScope = scope
            } else if hoveredItem == .trash && hoveredItemScope == scope {
                hoveredItem = nil
            }
        }
        .contextMenu {
            if let pinKey {
                Button(store.isPinned(.system(pinKey)) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system(pinKey))
                }
            }
        }
    }

    /// 「固定」区的条目：可拖动排序，右键取消固定。
    /// - Parameter system: 当前是否在系统「照片」图库范围内，决定条目指向系统入口还是拾光入口。
    @ViewBuilder
    private func pinnedRows(system: Bool) -> some View {
        if store.pinnedItems.isEmpty {
            Text("在项目、场景、相簿或文件夹上右键可固定到这里")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        } else {
            ForEach(store.pinnedItems) { item in
                pinnedItemRow(item, system: system)
                    .onDrag { pinnedDragProviderForSidebar(item) }
                    .onDrop(of: [pinnedSidebarDragType],
                            delegate: PinnedReorderDropDelegate(target: item, store: store))
            }
            // 拖到列表下方空白处 → 移到末尾。
            Color.clear
                .frame(height: 6)
                .onDrop(of: [pinnedSidebarDragType],
                        delegate: PinnedEndDropDelegate(store: store))
        }
    }

    /// 「固定」区里的条目：系统项、相簿、智能相簿、文件夹或系统图库的相簿 / 文件夹。
    @ViewBuilder
    private func pinnedItemRow(_ item: PinnedSidebarItem, system: Bool) -> some View {
        switch item {
        case .system(let key):
            if let info = pinnedSystemInfo(for: key, system: system) {
                sidebarRow(info.item, icon: info.icon, title: info.title,
                           color: info.color, scope: "fixed", pinKey: key)
            }
        case .album(let id):
            if let album = store.albums.first(where: { $0.id == id }) {
                albumRow(album, level: 0, scope: "fixed")
            }
        case .smartAlbum(let id):
            if let album = store.smartAlbums.first(where: { $0.id == id }) {
                smartAlbumRow(album, scope: "fixed")
            }
        case .folder(let id):
            if let folder = store.folders.first(where: { $0.id == id }) {
                folderNode(folder, level: 0, scope: "fixed")
            }
        case .systemAlbum(let id):
            if let album = store.systemAlbums.first(where: { $0.id == id }) {
                systemAlbumRow(album, level: 0, scope: "fixed")
            }
        case .systemFolder(let id):
            if let folder = store.systemFolders.first(where: { $0.id == id }) {
                systemFolderNode(folder, level: 0, scope: "fixed")
            }
        }
    }

    private struct PinnedSystemInfo {
        let title: String
        let icon: String
        var color: Color = .accentColor
        let item: SidebarItem
    }

    /// 固定项 key 在当前范围对应的入口：系统图库范围指向系统入口，拾光范围指向本地入口。
    private func pinnedSystemInfo(for key: String, system: Bool) -> PinnedSystemInfo? {
        switch key {
        case "favorites":
            return PinnedSystemInfo(title: "个人收藏", icon: "heart.fill", color: .pink,
                                    item: system ? .systemFavorites : .favorites)
        case "trash":
            return PinnedSystemInfo(title: "最近删除", icon: "trash", color: .secondary,
                                    item: system ? .systemTrash : .trash)
        case "duplicates":
            return PinnedSystemInfo(title: "重复项目", icon: "square.on.square",
                                    item: system ? .systemDuplicates : .duplicates)
        case "recentlySaved":
            return PinnedSystemInfo(title: "最近保存", icon: "square.and.arrow.down",
                                    item: system ? .systemRecentlySaved : .recentlySaved)
        case "recentlyViewed":
            return PinnedSystemInfo(title: "最近查看", icon: "eye", item: .systemRecentlyViewed)
        case "recentlyEdited":
            return PinnedSystemInfo(title: "最近编辑", icon: "slider.horizontal.3",
                                    item: system ? .systemEdited : .recentlyEdited)
        case "imports":
            return PinnedSystemInfo(title: "导入项目", icon: "square.and.arrow.down.on.square",
                                    item: system ? .systemImports : .imports)
        case "map":
            return PinnedSystemInfo(title: "地图", icon: "map", item: system ? .systemMap : .map)
        case "places":
            return PinnedSystemInfo(title: "位置", icon: "mappin.and.ellipse",
                                    item: system ? .systemPlaces : .places)
        case "people":
            return PinnedSystemInfo(title: "人物", icon: "person.crop.square",
                                    item: system ? .systemPeople : .people)
        case "hidden":
            return PinnedSystemInfo(title: "已隐藏", icon: "eye.slash", color: .secondary,
                                    item: system ? .systemHidden : .hidden)
        case "ocrTexts":
            return PinnedSystemInfo(title: "包含文字", icon: "text.viewfinder",
                                    item: system ? .systemOcrTexts : .ocrTexts)
        case "keywords":
            return PinnedSystemInfo(title: "关键词", icon: "tag",
                                    item: system ? .systemKeywords : .keywords)
        case "revisit":
            return PinnedSystemInfo(title: "值得重看", icon: "clock.arrow.circlepath",
                                    item: system ? .systemRevisit : .revisit)
        case "health":
            return PinnedSystemInfo(title: "图库体检", icon: "stethoscope",
                                    item: system ? .systemHealth : .health)
        case "ratings", "flags", "colorLabels":
            // 旧的三个固定项统一收敛成「图库整理」入口。
            return PinnedSystemInfo(title: "图库整理", icon: "square.grid.2x2", color: .yellow,
                                    item: system ? .systemRatings : .ratings)
        default:
            // 场景固定 key：`scene:<分类 id>`，与媒体类型一样随当前范围指向拾光或系统图库入口。
            if key.hasPrefix("scene:"),
               let category = SceneCatalog.category(id: String(key.dropFirst(6))) {
                return PinnedSystemInfo(title: category.title, icon: category.icon,
                                        item: system ? .systemScene(category.id)
                                                     : .scene(category.id))
            }
            guard let type = MediaTypeKey(rawValue: key) else { return nil }
            return PinnedSystemInfo(title: type.title, icon: type.icon,
                                    item: type.item(system: system))
        }
    }

    /// 文件夹展开箭头的列宽：只够放下箭头，避免封面被推远。
    private static let folderChevronWidth: CGFloat = 12
    /// 箭头与封面之间的间隙，保持紧贴但可点。
    private static let folderChevronGap: CGFloat = 3

    /// 侧边栏树形缩进：顶层与普通相簿同一列，展开后的每一层多缩进 14 pt。
    private func rowLeadingPadding(_ level: Int) -> CGFloat {
        8 + CGFloat(level) * 14
    }

    /// 相簿没有展开箭头，留出同宽的箭头列，封面才和文件夹图标对齐。
    /// 「固定」区的条目本身就是第一层，不再为箭头列预留缩进，和其它固定项左对齐。
    private func albumLeadingPadding(_ level: Int, scope: String = "albums") -> CGFloat {
        if scope == "fixed", level == 0 { return rowLeadingPadding(0) }
        return rowLeadingPadding(level) + Self.folderChevronWidth + Self.folderChevronGap
    }

    private func folderNode(_ folder: AlbumFolder, level: Int, scope: String = "albums") -> AnyView {
        let isExpanded = expandedFolders.contains(folder.id)
        let childFolders = store.childFolders(of: folder.id)
        let childAlbums = store.albums(in: folder.id)
        let hasChildren = !childFolders.isEmpty || !childAlbums.isEmpty

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Self.folderChevronGap) {
                    Button {
                        withAnimation(settings.motion.layout) {
                            if isExpanded {
                                expandedFolders.remove(folder.id)
                            } else {
                                expandedFolders.insert(folder.id)
                            }
                        }
                        persistExpansionState()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: Self.folderChevronWidth, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hasChildren ? 1 : 0)
                    .disabled(!hasChildren)

                    Button {
                        store.navigate(to: .folder(folder.id))
                    } label: {
                        HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                                .background(Color.accentColor.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                                 style: .continuous))
                            Text(folder.name)
                                .font(.system(size: LumaMetrics.sidebarTextSize))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, rowLeadingPadding(level))
                .padding(.trailing, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .background {
                    LumaRowHighlight(active: store.sidebarItem == .folder(folder.id),
                                     hovered: hoveredItem == .folder(folder.id) && hoveredItemScope == scope)
                }
                .onHover { hovering in
                    if hovering {
                        hoveredItem = .folder(folder.id)
                        hoveredItemScope = scope
                    } else if hoveredItem == .folder(folder.id) && hoveredItemScope == scope {
                        hoveredItem = nil
                    }
                }
                .contextMenu {
                    Button("打开文件夹") {
                        store.navigate(to: .folder(folder.id))
                    }
                    Button(store.isPinned(.folder(folder.id)) ? "取消固定" : "固定到侧边栏") {
                        store.togglePin(.folder(folder.id))
                    }
                    Divider()
                    Button("新建相簿…") {
                        namePrompt = .newAlbum(folderID: folder.id)
                    }
                    Button("新建子文件夹…") {
                        namePrompt = .newFolder(parentID: folder.id)
                    }
                    Divider()
                    Button("重命名文件夹…") {
                        namePrompt = .renameFolder(folder.id, current: folder.name)
                    }
                    Button("删除文件夹", role: .destructive) {
                        store.deleteFolder(folder.id)
                    }
                }

                if isExpanded {
                    ForEach(childFolders) { child in
                        folderNode(child, level: level + 1, scope: scope)
                    }
                    ForEach(childAlbums) { album in
                        albumRow(album, level: level + 1, scope: scope)
                    }
                }
            }
        )
    }

    private func albumRow(_ album: Album, level: Int, scope: String = "albums") -> some View {
        Button {
            store.navigate(to: .album(album.id))
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                AlbumCoverView(album: album)
                Text(album.name)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, albumLeadingPadding(level, scope: scope))
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background {
                ZStack {
                    LumaRowHighlight(active: store.sidebarItem == .album(album.id),
                                     hovered: hoveredItem == .album(album.id) && hoveredItemScope == scope)
                    if dropTargetAlbumID == album.id {
                        RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.24))
                            .overlay {
                                RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                            }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = .album(album.id)
                hoveredItemScope = scope
            } else if hoveredItem == .album(album.id) && hoveredItemScope == scope {
                hoveredItem = nil
            }
        }
        .onDrop(of: [.plainText], isTargeted: Binding(
            get: { dropTargetAlbumID == album.id },
            set: { targeted in
                if targeted {
                    dropTargetAlbumID = album.id
                } else if dropTargetAlbumID == album.id {
                    dropTargetAlbumID = nil
                }
            }
        )) { providers in
            PhotoDrag.loadIDs(from: providers) { ids in
                guard !ids.isEmpty else { return }
                store.addToAlbum(album.id, photoIDs: Set(ids))
            }
            return true
        }
        .contextMenu {
            Button("打开相簿") {
                store.navigate(to: .album(album.id))
            }
            Button(store.isPinned(.album(album.id)) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.album(album.id))
            }
            Button("重命名相簿…") {
                namePrompt = .renameAlbum(album.id, current: album.name)
            }
            Menu("移到文件夹") {
                Button("相簿顶层") {
                    store.moveAlbum(album.id, toFolder: nil)
                }
                if !store.folderOptions.isEmpty {
                    Divider()
                }
                ForEach(store.folderOptions) { option in
                    Button(option.path) {
                        store.moveAlbum(album.id, toFolder: option.id)
                    }
                }
            }
            Divider()
            Button("删除相簿", role: .destructive) {
                store.deleteAlbum(album.id)
            }
        }
    }

    private func smartAlbumRow(_ album: SmartAlbum, scope: String = "smart") -> some View {
        let item = SidebarItem.smartAlbum(album.id)
        return Button {
            store.navigate(to: item)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                    .background(Color.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                     style: .continuous))
                Text(album.name)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: store.sidebarItem == item,
                                 hovered: hoveredItem == item && hoveredItemScope == scope)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = item
                hoveredItemScope = scope
            } else if hoveredItem == item && hoveredItemScope == scope {
                hoveredItem = nil
            }
        }
        .contextMenu {
            Button("打开智能相簿") { store.navigate(to: item) }
            Button(store.isPinned(.smartAlbum(album.id)) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.smartAlbum(album.id))
            }
            Button("编辑条件…") { store.presentSmartAlbumEditor(album) }
            Divider()
            Button("删除智能相簿", role: .destructive) { store.deleteSmartAlbum(album.id) }
        }
        .help(album.summary)
    }

    /// 可收起的分区头：悬停时显示「更多」与「收起 / 展开」。
    /// 传入 `navigateTo` 时标题可点击，右侧显示该分区的二级总览视图。
    private func sectionHeader<MenuContent: View>(
        _ title: String,
        key: String,
        topPadding: CGFloat = 16,
        navigateTo: SidebarItem? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent = { EmptyView() }
    ) -> some View {
        SidebarSectionHeader(
            title: title,
            collapsed: isCollapsed(key),
            active: navigateTo.map { $0 == store.sidebarItem } ?? false,
            topPadding: topPadding,
            isHovered: hoveredSection == key,
            onOpen: navigateTo.map { item in { store.navigate(to: item) } },
            onToggle: {
                withAnimation(settings.motion.layout) { toggleSection(key) }
            },
            menu: menu
        )
        .onHover { inside in
            hoveredSection = inside ? key : (hoveredSection == key ? nil : hoveredSection)
        }
    }

    private func toggleSection(_ key: String) {
        if isCollapsed(key) {
            collapsedSections.remove(key)
            expandedSections.insert(key)
        } else {
            collapsedSections.insert(key)
            expandedSections.remove(key)
        }
        persistExpansionState()
    }

    /// 把当前所有层级的展开 / 收起状态写入本地：下次启动按同样的层级展示。
    private func persistExpansionState() {
        SidebarStateStorage.save(SidebarStateStorage.Key.collapsedSections, collapsedSections)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedSections, expandedSections)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedFolders, expandedFolders)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedSystemFolders, expandedSystemFolders)
        SidebarStateStorage.save(SidebarStateStorage.Key.collapsedSystemLibraries, collapsedSystemLibraries)
    }

    private func isCollapsed(_ key: String) -> Bool {
        if collapsedSections.contains(key) { return true }
        return Self.defaultCollapsedSections.contains(key) && !expandedSections.contains(key)
    }

    // MARK: - 场景（端侧智能分析）

    @ViewBuilder
    private var sceneSectionBody: some View {
        if store.isAnalyzingIntelligence {
            HStack(spacing: 7) {
                ProgressView(value: analysisFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
                Text("分析中 \(store.intelligenceDone)/\(store.intelligenceTotal)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else if store.analyzedCount == 0 {
            Button {
                store.analyzeIntelligence()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "sparkles")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text("分析照片内容…")
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("识别场景与照片中的文字，全部在本机完成")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        } else {
            let counts = store.sceneCounts
            let visible = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
            if visible.isEmpty {
                Text("未识别到常见场景")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            } else {
                ForEach(visible) { category in
                    sceneRow(category, count: counts[category.id] ?? 0)
                }
            }
        }
    }

    private var analysisFraction: Double {
        guard store.intelligenceTotal > 0 else { return 0 }
        return min(1, Double(store.intelligenceDone) / Double(store.intelligenceTotal))
    }

    private func sceneRow(_ category: SceneCategory, count: Int) -> some View {
        let item = SidebarItem.scene(category.id)
        return SidebarCategoryRow(icon: category.icon,
                                  title: category.title,
                                  count: count,
                                  isActive: store.sidebarItem == item,
                                  isHovered: hoveredItem == item,
                                  helpText: "查看「\(category.title)」照片",
                                  action: { store.navigate(to: item) })
            .contextMenu {
                Button(store.isPinned(.system("scene:\(category.id)")) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system("scene:\(category.id)"))
                }
            }
            .onHover { hovering in
                hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            }
    }

    // MARK: - 系统图库场景（端侧识别，缓存到 system_analysis）

    private var systemAnalysisFraction: Double {
        guard store.systemAnalysisTotal > 0 else { return 0 }
        return min(1, Double(store.systemAnalysisDone) / Double(store.systemAnalysisTotal))
    }

    @ViewBuilder
    private var systemSceneSectionBody: some View {
        if store.isAnalyzingSystemContent {
            HStack(spacing: 7) {
                ProgressView(value: systemAnalysisFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
                Text("识别中 \(store.systemAnalysisDone)/\(store.systemAnalysisTotal)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }

        if store.systemAnalyzedCount == 0 {
            if !store.isAnalyzingSystemContent {
                Button {
                    store.analyzeSystemContent()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("识别照片内容…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("在本机识别系统图库的场景与图内文字；结果只保存在内存，不写回「照片」")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        } else {
            // 结果边识别边出现：每识别一批就刷新下面的场景行。
            let counts = store.sceneCounts
            let visible = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
            if visible.isEmpty {
                if !store.isAnalyzingSystemContent {
                    Text("未识别到常见场景")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                }
            } else {
                ForEach(visible) { category in
                    systemSceneRow(category, count: counts[category.id] ?? 0)
                }
            }
            if !store.isAnalyzingSystemContent {
                let pending = store.systemPendingAnalysisCount
                if pending > 0 {
                    Button {
                        store.analyzeSystemContent()
                    } label: {
                        HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                            Image(systemName: "sparkles")
                                .font(.system(size: LumaMetrics.sidebarIconSize))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: LumaMetrics.sidebarIconColumn)
                            Text("继续识别（剩余 \(pending) 张）")
                                .font(.system(size: LumaMetrics.sidebarTextSize))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("在后台持续识别，可随时停止；结果只保存在内存")
                }
            }
        }
    }

    private func systemSceneRow(_ category: SceneCategory, count: Int) -> some View {
        let item = SidebarItem.systemScene(category.id)
        return SidebarCategoryRow(icon: category.icon,
                                  title: category.title,
                                  count: count,
                                  isActive: store.sidebarItem == item,
                                  isHovered: hoveredItem == item,
                                  helpText: "查看「\(category.title)」照片",
                                  action: { store.navigate(to: item) })
            .contextMenu {
                Button(store.isPinned(.system("scene:\(category.id)")) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system("scene:\(category.id)"))
                }
            }
            .onHover { hovering in
                hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            }
    }

    // MARK: - System libraries

    /// 媒体类型数量：与系统「照片」一致，数量为 0 的类型不显示入口。
    private var mediaTypeCounts: [MediaTypeKey: Int] {
        store.mediaTypeSummary.counts
    }

    /// 当前图库就是官方「照片」图库：把它自己的结构（共享、媒体类型、更多项目、相簿）直接作为主侧边栏。
    @ViewBuilder
    private var nativeLibrarySection: some View {
        sectionHeader(store.systemLibraryName ?? "图库", key: "native.library", topPadding: 4) {
            Button("在「照片」中打开图库") { store.openContainerInPhotos() }
            Button("重新读取") { store.reloadSystemLibrary() }
            Button("在访达中显示图库") { store.revealSystemLibraryInFinder() }
            Divider()
            Button("打开其他图库…") { store.presentLibraryContainerPanel() }
            Button("新建照片图库…") { store.presentNewLibraryPanel() }
        }
        if !isCollapsed("native.library") {
            systemLibraryDetail
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        sectionHeader("系统图库", key: "sys.libraries", navigateTo: .systemLibraries) {
            Button("选择其他图库…") { store.presentSystemLibraryPanel() }
            Button("新建照片图库…") { store.presentNewLibraryPanel() }
            if let path = store.systemLibraryPath {
                Divider()
                Button("在「照片」中打开图库") { store.openSystemLibraryInPhotos(path) }
                Button("重新读取") { store.reloadSystemLibrary() }
            }
        }

        if !isCollapsed("sys.libraries") {
            if store.systemLibraries.isEmpty {
                Button {
                    store.presentSystemLibraryPanel()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("连接照片图库…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // 每个系统图库各自一套子项，只展开当前连接的那个。
                ForEach(store.systemLibraries) { ref in
                    let isExpanded = store.systemLibraryPath == ref.path
                        && !collapsedSystemLibraries.contains(ref.path)
                    systemLibraryRefRow(ref, isExpanded: isExpanded)
                    if isExpanded {
                        systemLibraryDetail
                    }
                }
            }
        }
    }

    /// 已连接的系统图库列表；同一时间只有一个处于连接/展开状态。
    private func systemLibraryRefRow(_ ref: SystemLibraryRef, isExpanded: Bool) -> some View {
        let isActive = store.systemLibraryPath == ref.path
        let isHighlighted = isActive && store.isSystemScope
        let isHovered = hoveredSystemLibraryPath == ref.path

        return HStack(spacing: 2) {
            Button {
                if isActive {
                    withAnimation(settings.motion.layout) {
                        if isExpanded {
                            collapsedSystemLibraries.insert(ref.path)
                        } else {
                            collapsedSystemLibraries.remove(ref.path)
                        }
                    }
                } else {
                    collapsedSystemLibraries.remove(ref.path)
                    store.activateSystemLibrary(ref)
                }
                persistExpansionState()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .help(isExpanded ? "收起" : "展开")

            Button {
                collapsedSystemLibraries.remove(ref.path)
                store.activateSystemLibrary(ref)
                persistExpansionState()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(ref.name)
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isActive {
                        if store.isLoadingSystemLibrary {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Text("\(store.systemActivePhotoCount)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("在「照片」中打开图库") {
                    store.openSystemLibraryInPhotos(ref.path)
                }
                Button("重新读取") {
                    store.connectSystemLibrary(URL(fileURLWithPath: ref.path))
                }
                Button("在访达中显示图库") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
                }
                Button("选择其他图库…") { store.presentSystemLibraryPanel() }
                Button("新建照片图库…") { store.presentNewLibraryPanel() }
                Divider()
                Button("断开连接", role: .destructive) {
                    store.confirmRemoveSystemLibrary(path: ref.path, name: ref.name)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .padding(.trailing, 6)
            .opacity(isHovered || isHighlighted ? 1 : 0)
        }
        .background {
            LumaRowHighlight(active: isHighlighted, hovered: isHovered)
        }
        .onHover { hovering in
            hoveredSystemLibraryPath = hovering
                ? ref.path
                : (hoveredSystemLibraryPath == ref.path ? nil : hoveredSystemLibraryPath)
        }
        .contextMenu {
            Button("在「照片」中打开图库") { store.openSystemLibraryInPhotos(ref.path) }
            Button("重新读取") { store.connectSystemLibrary(URL(fileURLWithPath: ref.path)) }
            Button("在访达中显示图库") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
            }
            Divider()
            Button("断开连接", role: .destructive) {
                store.confirmRemoveSystemLibrary(path: ref.path, name: ref.name)
            }
        }
    }

    /// 当前系统图库的浏览入口（图库 / 精选集 / 固定 / 媒体类型 / 更多项目 / 场景 / 相簿），与其它分区左对齐。
    @ViewBuilder
    private var systemLibraryDetail: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            // 与「拾光」分区一致：最上面是系统图库自己的「图库」与「精选集」。
            sidebarRow(.systemLibrary, icon: "photo.stack", title: "图库")
            sidebarRow(.systemCollections, icon: "square.stack.3d.up", title: "精选集")

            sectionHeader("固定", key: "sys.fixed", topPadding: 12)
            if !isCollapsed("sys.fixed") {
                pinnedRows(system: true)
            }

            let visibleMediaTypes = MediaTypeKey.allCases.filter { (mediaTypeCounts[$0] ?? 0) > 0 }
            if !visibleMediaTypes.isEmpty {
                sectionHeader("媒体类型", key: "sys.media", topPadding: 12, navigateTo: .systemMediaTypes)
                if !isCollapsed("sys.media") {
                    ForEach(visibleMediaTypes) { key in
                        sidebarRow(key.item(system: true), icon: key.icon, title: key.title,
                                   pinKey: key.rawValue)
                    }
                }
            }

            sectionHeader("更多项目", key: "sys.more", topPadding: 12, navigateTo: .systemMoreItems)
            if !isCollapsed("sys.more") {
                // 与「更多项目」总览页保持同一顺序与图标；最近查看是系统图库独有入口。
                sidebarRow(.systemFavorites, icon: "heart.fill", title: "个人收藏", color: .pink,
                           pinKey: "favorites")
                sidebarRow(.systemHealth, icon: "stethoscope", title: "图库体检", pinKey: "health")
                sidebarRow(.systemRatings, icon: "square.grid.2x2", title: "图库整理", color: .yellow,
                           pinKey: "ratings")
                sidebarRow(.systemRevisit, icon: "clock.arrow.circlepath", title: "值得重看",
                           pinKey: "revisit")
                if store.systemDuplicateCount > 0 {
                    sidebarRow(.systemDuplicates, icon: "square.on.square", title: "重复项目",
                               pinKey: "duplicates")
                }
                sidebarRow(.systemMap, icon: "map", title: "地图", pinKey: "map")
                sidebarRow(.systemPlaces, icon: "mappin.and.ellipse", title: "位置", pinKey: "places")
                sidebarRow(.systemPeople, icon: "person.crop.square", title: "人物", pinKey: "people")
                sidebarRow(.systemKeywords, icon: "tag", title: "关键词", pinKey: "keywords")
                if store.ocrPhotoCount > 0 {
                    sidebarRow(.systemOcrTexts, icon: "text.viewfinder", title: "包含文字",
                               pinKey: "ocrTexts")
                }
                sidebarRow(.systemRecentlyViewed, icon: "eye", title: "最近查看",
                           pinKey: "recentlyViewed")
                sidebarRow(.systemEdited, icon: "slider.horizontal.3", title: "最近编辑",
                           pinKey: "recentlyEdited")
                sidebarRow(.systemRecentlySaved, icon: "square.and.arrow.down", title: "最近保存",
                           pinKey: "recentlySaved")
                systemTrashRow
                sidebarRow(.systemImports, icon: "square.and.arrow.down.on.square", title: "导入项目",
                           pinKey: "imports")
                if store.systemHiddenCount > 0 {
                    sidebarRow(.systemHidden, icon: "eye.slash", title: "已隐藏", color: .secondary,
                               pinKey: "hidden")
                }
            }

            sectionHeader("场景", key: "sys.scenes", topPadding: 12, navigateTo: .systemScenes) {
                if store.isAnalyzingSystemContent {
                    Button("停止识别") { store.cancelSystemContentAnalysis() }
                } else {
                    Button(store.systemAnalyzedCount > 0 ? "继续识别…" : "识别照片内容…") {
                        store.analyzeSystemContent()
                    }
                    if store.systemAnalyzedCount > 0 {
                        Button("重新识别全部照片…") {
                            showRestartSystemAnalysisConfirm = true
                        }
                        Button("重置（清空结果）…", role: .destructive) {
                            showResetSystemAnalysisConfirm = true
                        }
                    }
                }
            }
            if !isCollapsed("sys.scenes") {
                systemSceneSectionBody
            }

            if store.isLoadingSystemLibrary {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(store.systemScanCount > 0
                         ? "正在读取系统图库… \(store.systemScanCount.formatted()) 项"
                         : "正在读取系统图库…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            if let error = store.systemLibraryError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }

            if !store.systemFolders.isEmpty || !store.systemAlbums.isEmpty {
                sectionHeader("相簿", key: "sys.albums", topPadding: 12, navigateTo: .systemAlbums)
            }
            if !isCollapsed("sys.albums") {
                ForEach(store.systemChildren(of: nil)) { entry in
                    systemNode(entry, level: 0)
                }
            }
        }
    }

    private var systemTrashRow: some View {
        Button {
            store.navigate(to: .systemTrash)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "trash")
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text("最近删除")
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: store.sidebarItem == .systemTrash,
                                 hovered: hoveredItem == .systemTrash)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? .systemTrash : (hoveredItem == .systemTrash ? nil : hoveredItem)
        }
        .contextMenu {
            Button(store.isPinned(.system("trash")) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.system("trash"))
            }
        }
    }

    // MARK: - Network storage

    @ViewBuilder
    private var cloudSection: some View {
        sectionHeader("网络存储", key: "cloud", navigateTo: .cloudStorages) {
            Button("网盘接入向导…") {
                store.presentCloudWizard()
            }
        }

        if !isCollapsed("cloud") {
            if cloud.mounts.isEmpty {
                Button {
                    store.presentCloudWizard()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("网盘接入向导…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(cloud.mounts) { mount in
                    CloudMountSidebarRow(mount: mount)
                }
            }
        }
    }

    private func systemFolderNode(_ folder: SystemFolderInfo, level: Int, scope: String = "system") -> AnyView {
        let isExpanded = expandedSystemFolders.contains(folder.id)
        let children = store.systemChildren(of: folder.id)
        let hasChildren = !children.isEmpty

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Self.folderChevronGap) {
                    Button {
                        withAnimation(settings.motion.layout) {
                            if isExpanded {
                                expandedSystemFolders.remove(folder.id)
                            } else {
                                expandedSystemFolders.insert(folder.id)
                            }
                        }
                        persistExpansionState()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: Self.folderChevronWidth, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hasChildren ? 1 : 0)
                    .disabled(!hasChildren)

                    Button {
                        store.navigate(to: .systemFolder(folder.id))
                    } label: {
                        HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                                .background(Color.accentColor.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                                 style: .continuous))
                            Text(folder.name)
                                .font(.system(size: LumaMetrics.sidebarTextSize))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, rowLeadingPadding(level))
                .padding(.trailing, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .background {
                    LumaRowHighlight(active: store.sidebarItem == .systemFolder(folder.id),
                                     hovered: hoveredSystemFolder == folder.id)
                }
                .onHover { hovering in
                    hoveredSystemFolder = hovering ? folder.id : (hoveredSystemFolder == folder.id ? nil : hoveredSystemFolder)
                }
                .contextMenu {
                    Button("打开文件夹") {
                        store.navigate(to: .systemFolder(folder.id))
                    }
                    Button(store.isPinned(.systemFolder(folder.id)) ? "取消固定" : "固定到侧边栏") {
                        store.togglePin(.systemFolder(folder.id))
                    }
                    Button("拷贝到拾光（含子文件夹）") {
                        store.importSystemFolderToLibrary(folder.id)
                    }
                }

                if isExpanded {
                    ForEach(children) { child in
                        systemNode(child, level: level + 1)
                    }
                }
            }
        )
    }

    /// 文件夹与相簿按图库原始顺序混排渲染。
    @ViewBuilder
    private func systemNode(_ entry: SystemSidebarEntry, level: Int) -> some View {
        switch entry {
        case .folder(let folder):
            systemFolderNode(folder, level: level)
        case .album(let album):
            systemAlbumRow(album, level: level)
        }
    }

    private func systemAlbumRow(_ album: SystemAlbumInfo, level: Int, scope: String = "system") -> some View {
        Button {
            store.navigate(to: .systemAlbum(album.id))
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                SystemAlbumCoverView(albumID: album.id)
                Text(album.name)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if store.systemAlbumIsEmpty(album.id) {
                    Image(systemName: "tray")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, albumLeadingPadding(level, scope: scope))
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: store.sidebarItem == .systemAlbum(album.id),
                                 hovered: hoveredItem == .systemAlbum(album.id) && hoveredItemScope == scope)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = .systemAlbum(album.id)
                hoveredItemScope = scope
            } else if hoveredItem == .systemAlbum(album.id) && hoveredItemScope == scope {
                hoveredItem = nil
            }
        }
        .contextMenu {
            Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
            Button(store.isPinned(.systemAlbum(album.id)) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.systemAlbum(album.id))
            }
            Button("拷贝到拾光") {
                store.importSystemAlbumToLibrary(album.id)
            }
            if store.canManageSystemAlbums {
                Divider()
                Button("重命名相簿…") {
                    namePrompt = .renameSystemAlbum(album.id, current: album.name)
                }
                Button("删除相簿", role: .destructive) {
                    store.deleteSystemAlbum(album.id)
                }
            }
            if let path = store.systemLibraryPath {
                Divider()
                Button("在访达中显示图库") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }
}

/// 「固定」分区的拖动数据：拾光 / 系统图库 / 网盘共用同一种拖拽类型。
func pinnedDragProviderForSidebar(_ item: PinnedSidebarItem) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: pinnedSidebarDragType.identifier,
                                        visibility: .ownProcess) { completion in
        completion(Data(item.id.utf8), nil)
        return nil
    }
    return provider
}

/// 「固定」分区的拖拽排序：只接受固定项自身的拖拽，照片拖拽仍交给相簿 / 文件夹处理。
func loadPinnedDragID(from info: DropInfo, completion: @escaping (String) -> Void) -> Bool {
    guard let provider = info.itemProviders(for: [pinnedSidebarDragType]).first else {
        return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: pinnedSidebarDragType.identifier) { data, _ in
        guard let data, let raw = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            completion(raw)
        }
    }
    return true
}

struct PinnedReorderDropDelegate: DropDelegate {
    let target: PinnedSidebarItem
    let store: LibraryStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [pinnedSidebarDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        loadPinnedDragID(from: info) { id in
            store.movePinned(id: id, before: target.id)
        }
    }
}

/// 拖到「固定」列表末尾：移到最后一位。
struct PinnedEndDropDelegate: DropDelegate {
    let store: LibraryStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [pinnedSidebarDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        loadPinnedDragID(from: info) { id in
            store.movePinnedToEnd(id: id)
        }
    }
}

private struct AlbumCoverView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    let album: Album

    private var coverPhoto: PhotoItem? {
        if let coverID = album.coverPhotoID, album.photoIDs.contains(coverID),
           let cover = store.photo(id: coverID) {
            return cover
        }
        guard let first = album.photoIDs.first else { return nil }
        return store.photo(id: first)
    }

    var body: some View {
        Group {
            if let coverPhoto {
                PhotoThumbnailView(photo: coverPhoto, purpose: .cover(LumaMetrics.sidebarCoverSize))
            } else {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
        .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous))
    }
}

private struct SystemAlbumCoverView: View {
    @EnvironmentObject private var store: LibraryStore
    let albumID: Int64
    @State private var photo: PhotoItem?
    @State private var loadedAlbumID: Int64?

    var body: some View {
        Group {
            if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(LumaMetrics.sidebarCoverSize))
            } else {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
        .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous))
        // 封面在后台查询并按相簿缓存：侧边栏有上百个相簿时，body 里逐行查库会直接卡住滚动。
        .task(id: albumID) {
            if loadedAlbumID != albumID { photo = nil }
            let loaded = await store.systemAlbumCover(albumID)
            guard !Task.isCancelled else { return }
            loadedAlbumID = albumID
            photo = loaded
        }
    }
}
