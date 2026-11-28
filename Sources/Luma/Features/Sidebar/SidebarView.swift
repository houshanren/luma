import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaContentCore

/// 「固定」分区拖拽排序用的自定义类型，避免和照片拖拽（纯文本）互相干扰。
let pinnedSidebarDragType = UTType(exportedAs: "com.luma.sidebar-pinned-item")
/// 网络资源拖拽排序：拖动只调整源顺序，不会与照片 / 固定项混淆。
let catalogSourceDragType = UTType(exportedAs: "com.luma.sidebar-catalog-source")
/// 网络电视源拖拽排序：顺序写进电视库的 `tv_playlists.position`。
let tvSourceDragType = UTType(exportedAs: "com.luma.sidebar-tv-source")
/// 系统图库侧边栏的相簿拖拽：拖进文件夹时只认这个类型，不会和照片拖拽互相混淆。
let systemSidebarDragType = UTType(exportedAs: "com.luma.sidebar-system-item")

struct SidebarView: View {
    @Environment(LibraryStore.self) var store
    @Environment(CloudBrowserModel.self) var cloud
    @Environment(CatalogBrowserModel.self) var catalog
    @Environment(IPTVBrowserModel.self) var tv
    @Environment(AppSettings.self) var settings
    /// 模块开关随当前图库保存：关闭后整段入口不渲染，搜索也不再返回对应来源。
    private var showTelevision: Bool { settings.moduleTelevision }
    private var showCloudModule: Bool { settings.moduleCloud }
    private var showCatalogModule: Bool { settings.moduleCatalog }
    private var showCinemaModule: Bool { settings.moduleCinema }
    /// 星图不看模块开关：资料库被加载后入口才出现，卸载后整段消失。
    private var showAtlasLibrary: Bool { AtlasCatalogLibrary.shared.isLoaded }
    /// 侧边栏相簿默认全部收起，只记录被用户展开的文件夹，避免一次渲染上千行。
    /// 展开 / 收起状态写入本地，下次启动沿用上次的层级。
    @State private var expandedFolders: Set<UUID> =
        SidebarStateStorage.uuidSet(SidebarStateStorage.Key.expandedFolders)
    @State var expandedSystemFolders: Set<Int64> =
        SidebarStateStorage.int64Set(SidebarStateStorage.Key.expandedSystemFolders)
    /// 系统树展开状态版本：让拍平结果只在展开/收起时重算，悬停等无关状态直接命中缓存。
    @State var systemExpansionRevision = 0
    @State var collapsedSystemLibraries: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.collapsedSystemLibraries)
    @State var hoveredSystemLibraryPath: String?
    /// 已收起的侧边栏分区（键为分区标识），同样持久化。
    @State var collapsedSections: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.collapsedSections)
    /// 默认收起的分区被用户主动展开后的记录；没有记录时按默认收起。
    @State var expandedSections: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.expandedSections)
    /// 默认收起「图库」分区内的当前图库实例，以及「媒体类型」与「场景」；
    /// 展开「图库」先看到实例，再展开实例才看到树，和网络存储一致。
    private static let defaultCollapsedSections: Set<String> = [
        "library.current", "luma.media", "luma.scenes", "sys.media", "sys.scenes"
    ]
    @State private var hoveredSection: String?
    @State private var dropTargetAlbumID: UUID?
    /// 系统相簿被拖到哪个文件夹上方（落点高亮）。
    @State var systemFolderDropTarget: Int64?
    /// 「场景」分区危险操作的二次确认：清空本地 / 系统图库分析结果、系统图库重新识别。
    @State var showResetAnalysisConfirm = false
    @State var showResetSystemAnalysisConfirm = false
    @State var showRestartSystemAnalysisConfirm = false
    /// 网络资源拖拽排序时的目标行：用来画一条落点提示线。
    @State var catalogDropTargetID: UUID?
    /// 网络电视源拖拽排序时的目标行。
    @State var tvDropTargetID: UUID?
    /// 网络电视源下展开的分类：默认全部收起，需要时再手动展开单个源。
    @State var expandedTVSources: Set<UUID> = []
    /// 网络存储同一时间只展开一个接入：点别的接入（或它的影院）时自动收起上一个。
    @State var expandedCloudMountID: UUID? =
        SidebarStateStorage.uuidSet(SidebarStateStorage.Key.expandedCloudMounts).first

    /// 「图库」分区里当前图库这一行的悬停状态。
    @State var hoveredCurrentLibrary = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            // 系统图库可能带成千上万个相簿，侧边栏必须懒加载，否则一次性创建全部行会卡死主线程。
            LazyVStack(alignment: .leading, spacing: 1) {
                // 智能助手工作台：左侧菜单里的独立一页，不挂在任何图库实例下面。
                sidebarRow(.assistant, icon: "sparkles", title: "助手", color: Color.accentColor)
                    .padding(.bottom, 6)
                librariesSection
                if showCloudModule {
                    cloudSection
                }
                if showCatalogModule {
                    catalogSection
                }
                if showCinemaModule {
                    networkCinemaSection
                }
                if showTelevision {
                    tvSection
                }
                if showAtlasLibrary {
                    atlasSection
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
            // 撑满分栏列宽、左对齐：拖动分栏时内容跟着列宽一起变。
            // 不用 containerRelativeFrame：它在分栏拖拽的实时布局里会按「上一帧的列宽」
            // 算宽，内容会缩成一条贴在右边的窄栏（截图里的错位就是这样来的）。
            .frame(maxWidth: .infinity, alignment: .leading)
            // 整理面板挂在内容上而不是根视图：根视图已经有命名弹窗，避免两个 sheet 抢同一个挂载点。
            .sheet(item: $store.systemFolderPrompt) { _ in
                SystemFolderOrganizeSheet()
                    .environment(store)
            }
        }
        .scrollIndicators(.never)
        // 截图工具要求「逐层展开」时，把分区 / 文件夹 / 网盘 / 电视源一次展开。
        .onChange(of: store.sidebarExpandRequest) { _, _ in
            expandLevels(focus: store.sidebarExpandTarget)
        }
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
            // 后台任务统一露出：网盘扫描 / 影院刮削 / 健康检测 / 日历补录。
            SourceJobStatusBar()
        }
        // 拖拽范围收在 150–360：再窄行内文字会挤成省略号，再宽只是给行尾留白。
        // 内容本身用上面 LazyVStack 的 frame(maxWidth: .infinity) 跟随列宽：
        // 之前用 containerRelativeFrame，分栏拖拽的实时布局里会按上一帧列宽算宽，
        // 内容缩成一条贴在右边的窄栏、两侧大片空白（截图里的错位就是这样来的）。
        .navigationSplitViewColumnWidth(min: 150, ideal: 248, max: 360)
        .confirmationDialog("清空照片与视频的内容分析结果？",
                            isPresented: $showResetAnalysisConfirm,
                            titleVisibility: .visible) {
            Button("清空全部结果", role: .destructive) {
                store.resetIntelligenceAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除全部照片与视频的场景标签、图内文字与相似检索特征（含已保存到图库的结果）；原文件本身不受影响，之后可重新分析。")
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

    func sidebarRow(_ item: SidebarItem,
                            icon: String,
                            title: String,
                            color: Color = .secondary,
                            pinKey: String? = nil) -> some View {
        SidebarCategoryRow(icon: icon,
                           title: title,
                           iconColor: color,
                           trailingIcon: pinKey == "trash" ? "lock.fill" : nil,
                           isActive: store.sidebarItem == item,
                           action: { store.navigate(to: item) })
            .contextMenu {
                if let pinKey {
                    Button(store.isPinned(.system(pinKey)) ? "取消固定" : "固定到侧边栏") {
                        store.togglePin(.system(pinKey))
                    }
                }
            }
    }

    /// 「固定」区已经展示过的入口，原分区不再重复出现。
    /// 固定项只做快捷方式，侧边栏里每个入口只占一行。
    func isUnpinned(_ pinKey: String) -> Bool {
        !store.isPinned(.system(pinKey))
    }

    /// 「媒体类型」分区的入口：数量为 0 的不占位，已固定的只在「固定」区出现。
    func visibleMediaTypes(system: Bool) -> [MediaTypeKey] {
        let keys = system ? MediaTypeKey.allCases : MediaTypeKey.localCases
        return keys.filter { (mediaTypeCounts[$0] ?? 0) > 0 && isUnpinned($0.rawValue) }
    }

    /// 「更多项目」分区的入口顺序：与对应总览页一致；
    /// 数量为 0 的项不占位，已固定的项从原分区移走。返回空数组时整段不渲染。
    func visibleMoreItemKeys(system: Bool) -> [String] {
        var keys = ["favorites", "health", "ratings", "revisit"]
        if (system ? store.systemDuplicateCount : store.duplicateCount) > 0 {
            keys.append("duplicates")
        }
        keys.append(contentsOf: ["map", "places", "people", "keywords"])
        if (system ? store.ocrPhotoCount : store.analyzedCount) > 0 {
            keys.append("ocrTexts")
        }
        // 最近查看是系统图库独有入口。
        if system {
            keys.append("recentlyViewed")
        }
        keys.append(contentsOf: ["recentlyEdited", "recentlySaved", "trash", "imports"])
        if (system ? store.systemHiddenCount : store.hiddenCount) > 0 {
            keys.append("hidden")
        }
        return keys.filter { isUnpinned($0) }
    }

    /// 本地场景分区是否还有内容：已识别场景全部被固定后整段隐藏，避免只剩一个空标题。
    var hasUnpinnedScenes: Bool {
        // 还没分析时，分区里放的是「分析照片内容…」入口，不属于可固定项。
        guard store.analyzedCount > 0 else { return true }
        let counts = store.sceneCounts
        let recognized = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
        return recognized.isEmpty || recognized.contains { isUnpinned("scene:\($0.id)") }
    }

    /// 系统图库场景分区是否还有内容：逻辑同本地场景，另需保留「继续识别」入口。
    var hasUnpinnedSystemScenes: Bool {
        guard store.systemAnalyzedCount > 0 else { return true }
        if store.systemPendingAnalysisCount > 0 { return true }
        let counts = store.sceneCounts
        let recognized = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
        return recognized.isEmpty || recognized.contains { isUnpinned("scene:\($0.id)") }
    }

    /// 「固定」区的条目：可拖动排序，右键取消固定。
    /// - Parameter system: 当前是否在系统「照片」图库范围内，决定条目指向系统入口还是拾光入口。
    @ViewBuilder
    func pinnedRows(system: Bool) -> some View {
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
                           color: info.color, pinKey: key)
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

    struct PinnedSystemInfo {
        let title: String
        let icon: String
        /// 图标默认单色；只有语义项（个人收藏的红心、最近删除的灰锁）才单独指定颜色。
        var color: Color = .secondary
        let item: SidebarItem
    }

    /// 固定项 key 在当前范围对应的入口：系统图库范围指向系统入口，拾光范围指向本地入口。
    func pinnedSystemInfo(for key: String, system: Bool) -> PinnedSystemInfo? {
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
            return PinnedSystemInfo(title: "图库整理", icon: "square.grid.2x2",
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
    static let folderChevronWidth: CGFloat = 12
    /// 箭头与封面之间的间隙，保持紧贴但可点。
    static let folderChevronGap: CGFloat = 3

    /// 侧边栏树形缩进：顶层与普通相簿同一列，展开后的每一层多缩进 14 pt。
    func rowLeadingPadding(_ level: Int) -> CGFloat {
        8 + CGFloat(level) * 14
    }

    /// 相簿没有展开箭头，留出同宽的箭头列，封面才和文件夹图标对齐。
    /// 「固定」区的条目本身就是第一层，不再为箭头列预留缩进，和其它固定项左对齐。
    func albumLeadingPadding(_ level: Int, scope: String = "albums") -> CGFloat {
        if scope == "fixed", level == 0 { return rowLeadingPadding(0) }
        return rowLeadingPadding(level) + Self.folderChevronWidth + Self.folderChevronGap
    }

    func folderNode(_ folder: AlbumFolder, level: Int, scope: String = "albums") -> AnyView {
        let isExpanded = expandedFolders.contains(folder.id)
        let childFolders = store.childFolders(of: folder.id)
        let childAlbums = store.albums(in: folder.id)
        let hasChildren = !childFolders.isEmpty || !childAlbums.isEmpty

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                // 悬停高亮收进行内：父视图不再因为鼠标划过而在上百行之间整体重算。
                HoverRowHighlight(active: store.sidebarItem == .folder(folder.id)) {
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
                                    .foregroundStyle(.secondary)
                                    .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                                    .background(Color.primary.opacity(0.08),
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
                        store.namePrompt = .newAlbum(folderID: folder.id)
                    }
                    Button("新建子文件夹…") {
                        store.namePrompt = .newFolder(parentID: folder.id)
                    }
                    Divider()
                    Button("重命名文件夹…") {
                        store.namePrompt = .renameFolder(folder.id, current: folder.name)
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

    func albumRow(_ album: Album, level: Int, scope: String = "albums") -> some View {
        // 悬停高亮收进行内：相簿多时，鼠标划过只重算这一行。
        HoverRowHighlight(active: store.sidebarItem == .album(album.id)) {
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
            .buttonStyle(.plain)
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
                store.namePrompt = .renameAlbum(album.id, current: album.name)
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

    func smartAlbumRow(_ album: SmartAlbum, scope: String = "smart") -> some View {
        let item = SidebarItem.smartAlbum(album.id)
        return HoverRowHighlight(active: store.sidebarItem == item) {
            Button {
                store.navigate(to: item)
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                        .background(Color.primary.opacity(0.08),
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
            }
            .buttonStyle(.plain)
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
    /// `active` 可覆盖默认判定：一级标题与二级行同属一个 `sidebarItem` 时，
    /// 由调用方按更具体的选择（某个源 / 某个分类）让标题让位，保证同一时刻只有一处高亮。
    func sectionHeader<MenuContent: View>(
        _ title: String,
        key: String,
        topPadding: CGFloat = 16,
        indent: CGFloat = 0,
        isModule: Bool = false,
        navigateTo: SidebarItem? = nil,
        active: Bool? = nil,
        beforeNavigate: (() -> Void)? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent = { EmptyView() }
    ) -> some View {
        SidebarSectionHeader(
            title: title,
            collapsed: isCollapsed(key),
            active: active ?? (navigateTo.map { $0 == store.sidebarItem } ?? false),
            topPadding: topPadding,
            indent: indent,
            isModule: isModule,
            isHovered: hoveredSection == key,
            onOpen: navigateTo.map { item in
                {
                    if isTopLevelSection(key) {
                        withAnimation(settings.motion.layout) { expandExclusively(key) }
                    }
                    beforeNavigate?()
                    store.navigate(to: item)
                }
            },
            onToggle: {
                withAnimation(settings.motion.layout) { toggleSection(key) }
            },
            menu: menu
        )
        .onHover { inside in
            hoveredSection = inside ? key : (hoveredSection == key ? nil : hoveredSection)
        }
    }

    func toggleSection(_ key: String) {
        if isCollapsed(key) {
            if isTopLevelSection(key) {
                expandExclusively(key)
                return
            }
            collapsedSections.remove(key)
            expandedSections.insert(key)
        } else {
            collapsedSections.insert(key)
            expandedSections.remove(key)
        }
        persistExpansionState()
    }

    /// 顶层分区（图库 / 网络存储 / 网络资源 / 网络电视）做手风琴：
    /// 展开一个，其余已展开的顶层分区自动合上；嵌套分区不参与。
    private static let topLevelSectionKeys: Set<String> = [
        "library", "cloud", "catalog", "netcinema", "tv", "atlas"
    ]

    private func isTopLevelSection(_ key: String) -> Bool {
        Self.topLevelSectionKeys.contains(key)
    }

    /// 当前真正渲染出来的顶层分区：只在这些分区之间做手风琴，
    /// 避免把当前模式里看不见的分区也写进「已收起」。
    private var visibleTopLevelSectionKeys: [String] {
        var keys: [String] = ["library"]
        if showCloudModule { keys.append("cloud") }
        if showCatalogModule { keys.append("catalog") }
        if showCinemaModule { keys.append("netcinema") }
        if showTelevision { keys.append("tv") }
        if showAtlasLibrary { keys.append("atlas") }
        return keys
    }

    private func expandExclusively(_ key: String) {
        for other in visibleTopLevelSectionKeys where other != key {
            guard !isCollapsed(other) else { continue }
            collapsedSections.insert(other)
            expandedSections.remove(other)
        }
        collapsedSections.remove(key)
        expandedSections.insert(key)
        persistExpansionState()
    }

    /// 把当前所有层级的展开 / 收起状态写入本地：下次启动按同样的层级展示。
    func persistExpansionState() {
        SidebarStateStorage.save(SidebarStateStorage.Key.collapsedSections, collapsedSections)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedSections, expandedSections)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedFolders, expandedFolders)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedSystemFolders, expandedSystemFolders)
        SidebarStateStorage.save(SidebarStateStorage.Key.collapsedSystemLibraries, collapsedSystemLibraries)
    }

    func isCollapsed(_ key: String) -> Bool {
        if collapsedSections.contains(key) { return true }
        return Self.defaultCollapsedSections.contains(key) && !expandedSections.contains(key)
    }

    /// 把侧边栏各层级一次性展开：分区头、相簿文件夹、网盘分类、电视源分类。
    /// - Parameter focus: 要聚焦的分区；其它一级分区会收起，让目标段落在可视区域里。
    ///   只由截图工具的 `sidebarExpandRequest` 触发，正常交互仍按用户自己的展开状态走。
    func expandLevels(focus: String) {
        collapsedSections.removeAll()
        expandedSections.removeAll()
        switch focus {
        case "albums":
            // 相簿上面的分区保持收起，相簿列表才能落进首屏。
            expandedSections.formUnion(["library", "library.current", "luma.albums", "luma.smart"])
            collapsedSections.formUnion(["luma.fixed", "luma.media", "luma.more", "luma.scenes"])
        case "scenes":
            expandedSections.formUnion(["library", "library.current", "luma.scenes"])
            collapsedSections.formUnion(["luma.fixed", "luma.media", "luma.more",
                                         "luma.albums", "luma.smart"])
        case "library":
            expandedSections.formUnion(["library", "library.current", "luma.fixed", "luma.media",
                                        "luma.more", "luma.scenes", "luma.albums", "luma.smart"])
        case "cloud", "catalog", "tv":
            expandedSections.insert(focus)
            if focus == "catalog" {
                for category in CatalogSiteCategory.displayOrder {
                    expandedSections.insert("catalog.site.\(category.rawValue)")
                }
            }
        default:
            expandedSections.formUnion(Self.allSectionKeys)
            for category in CatalogSiteCategory.displayOrder {
                expandedSections.insert("catalog.site.\(category.rawValue)")
            }
        }
        // 聚焦某一个一级分区时，其余一级分区全部收起（与手风琴一致）。
        let focusTop = (focus == "library" || focus == "albums" || focus == "scenes") ? "library" : focus
        if focusTop != "all" {
            for key in Self.topLevelSectionKeys where key != focusTop {
                collapsedSections.insert(key)
                expandedSections.remove(key)
            }
        }
        expandedFolders.formUnion(store.folders.map(\.id))
        expandedSystemFolders.formUnion(store.systemFolders.map(\.id))
        expandedTVSources.formUnion(tv.playlists.map(\.id))
        if let firstMount = store.cloudMounts.first?.id {
            expandedCloudMountID = firstMount
        }
        // 网盘内的分类分区在 CloudMountDetailView 首次出现时读这份记录。
        for mount in store.cloudMounts {
            SidebarStateStorage.save(SidebarStateStorage.Key.cloudDetailSections(mount.id),
                                     Set<String>())
        }
        persistExpansionState()
    }

    /// 侧边栏可能出现的全部分区 key（含默认收起的几个）。
    private static let allSectionKeys: Set<String> = [
        "library", "library.current",
        "luma.fixed", "luma.media", "luma.more", "luma.scenes", "luma.albums", "luma.smart",
        "sys.fixed", "sys.media", "sys.more", "sys.scenes", "sys.albums",
        "cloud", "catalog", "netcinema", "tv", "atlas"
    ]
}
