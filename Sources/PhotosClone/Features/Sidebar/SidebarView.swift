import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    /// 侧边栏相簿默认全部收起，只记录被用户展开的文件夹，避免一次渲染上千行。
    @State private var expandedFolders: Set<UUID> = []
    @State private var expandedSystemFolders: Set<Int64> = []
    @State private var collapsedSystemLibraries: Set<String> = []
    @State private var hoveredItem: SidebarItem?
    /// 与 hoveredItem 搭配的分区标识：同一个相簿可能同时出现在「固定」和「相簿」里。
    @State private var hoveredItemScope: String = ""
    @State private var hoveredSystemFolder: Int64?
    @State private var hoveredSystemLibraryPath: String?
    /// 已收起的侧边栏分区（键为分区标识）。
    @State private var collapsedSections: Set<String> = []
    @State private var hoveredSection: String?
    @State private var namePrompt: NamePromptPayload?
    @State private var dropTargetAlbumID: UUID?

    var body: some View {
        ScrollView {
            // 系统图库可能带成千上万个相簿，侧边栏必须懒加载，否则一次性创建全部行会卡死主线程。
            LazyVStack(alignment: .leading, spacing: 1) {
                if store.isNativeContainer {
                    // 打开的是官方「照片」图库：它就是当前图库，内容直接放在主侧边栏，
                    // 不再单独挂在「系统图库」分区下面。
                    nativeLibrarySection
                } else {
                sectionHeader("拾光", key: "luma", topPadding: 4)
                if !isCollapsed("luma") {
                    sidebarRow(.library, icon: "photo.stack", title: "图库")
                    sidebarRow(.collections, icon: "square.stack.3d.up", title: "精选集")
                }

                sectionHeader("固定", key: "luma.fixed")
                if !isCollapsed("luma.fixed") {
                    if store.pinnedItems.isEmpty {
                        Text("在相簿或文件夹上右键可固定到这里")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                    } else {
                        ForEach(store.pinnedItems) { item in
                            pinnedItemRow(item)
                        }
                    }
                }

                sectionHeader("相簿", key: "luma.albums") {
                    Button("新建相簿") {
                        store.showNewAlbumSheet = true
                    }
                    Button("新建智能相簿…") {
                        store.presentSmartAlbumEditor()
                    }
                    Button("新建文件夹") {
                        namePrompt = .newFolder(parentID: nil)
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

                    Button {
                        namePrompt = .newFolder(parentID: nil)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 18)
                            Text("新建文件夹")
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
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

                sectionHeader("媒体类型", key: "luma.media")
                if !isCollapsed("luma.media") {
                    sidebarRow(.videos, icon: "video", title: "视频", pinKey: "videos")
                    sidebarRow(.selfies, icon: "person.crop.circle", title: "自拍", pinKey: "selfies")
                    sidebarRow(.livePhotos, icon: "livephoto", title: "实况照片", pinKey: "livePhotos")
                    sidebarRow(.panoramas, icon: "pano", title: "全景照片", pinKey: "panoramas")
                    sidebarRow(.screenshots, icon: "camera.viewfinder", title: "截屏", pinKey: "screenshots")
                    sidebarRow(.animated, icon: "photo.on.rectangle.angled", title: "动图", pinKey: "animated")
                    sidebarRow(.raws, icon: "camera.aperture", title: "RAW", pinKey: "raws")
                }

                sectionHeader("场景", key: "luma.scenes") {
                    if store.isAnalyzingIntelligence {
                        Button("停止分析") { store.cancelIntelligenceAnalysis() }
                    } else {
                        Button(store.analyzedCount > 0 ? "分析新照片…" : "分析照片内容…") {
                            store.analyzeIntelligence()
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

                sectionHeader("更多项目", key: "luma.more")
                if !isCollapsed("luma.more") {
                    sidebarRow(.favorites, icon: "heart.fill", title: "个人收藏", color: .pink, pinKey: "favorites")
                    trashRow(pinKey: "trash")
                    if store.duplicateCount > 0 {
                        sidebarRow(.duplicates, icon: "square.on.square", title: "重复项目", pinKey: "duplicates")
                    }
                    sidebarRow(.recentlySaved, icon: "square.and.arrow.down", title: "最近保存", pinKey: "recentlySaved")
                    sidebarRow(.recentlyEdited, icon: "slider.horizontal.3", title: "最近编辑", pinKey: "recentlyEdited")
                    sidebarRow(.imports, icon: "square.and.arrow.down.on.square", title: "导入项目", pinKey: "imports")
                    if store.analyzedCount > 0 {
                        sidebarRow(.ocrTexts, icon: "text.viewfinder", title: "包含文字")
                    }
                    sidebarRow(.revisit, icon: "clock.arrow.circlepath", title: "值得重看")
                    sidebarRow(.health, icon: "stethoscope", title: "图库体检")
                    sidebarRow(.map, icon: "map", title: "地图", pinKey: "map")
                    sidebarRow(.places, icon: "mappin.and.ellipse", title: "位置", pinKey: "places")
                    sidebarRow(.people, icon: "person.crop.square", title: "人物", pinKey: "people")
                    if store.hiddenCount > 0 {
                        sidebarRow(.hidden, icon: "eye.slash", title: "已隐藏", color: .secondary, pinKey: "hidden")
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
        .background(.ultraThinMaterial)
        .safeAreaInset(edge: .bottom) {
            // 官方「照片」图库只做增强层：不往 Apple 的图库里导入文件，因此不显示导入入口。
            if !store.isNativeContainer {
                importFooter
                    .background(.ultraThinMaterial)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 320)
        .sheet(item: $namePrompt) { payload in
            NamePromptSheet(payload: payload)
                .environmentObject(store)
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
        Button {
            store.navigate(to: item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pinKey == "trash" {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredItem == item && hoveredItemScope == scope {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
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
            if let pinKey {
                Button(store.isPinned(.system(pinKey)) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system(pinKey))
                }
            }
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private func trashRow(scope: String = "main", pinKey: String? = nil) -> some View {
        Button {
            store.navigate(to: .trash)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "trash")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("最近删除")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == .trash {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredItem == .trash && hoveredItemScope == scope {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
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

    /// 「固定」区里的条目：系统项、相簿或文件夹。
    @ViewBuilder
    private func pinnedItemRow(_ item: PinnedSidebarItem) -> some View {
        switch item {
        case .system(let key):
            switch key {
            case "favorites":
                sidebarRow(.favorites, icon: "heart.fill", title: "个人收藏",
                           color: .pink, scope: "fixed", pinKey: key)
            case "recentlySaved":
                sidebarRow(.recentlySaved, icon: "square.and.arrow.down", title: "最近保存",
                           scope: "fixed", pinKey: key)
            case "duplicates":
                sidebarRow(.duplicates, icon: "square.on.square", title: "重复项目",
                           scope: "fixed", pinKey: key)
            case "map":
                sidebarRow(.map, icon: "map", title: "地图", scope: "fixed", pinKey: key)
            case "places":
                sidebarRow(.places, icon: "mappin.and.ellipse", title: "位置", scope: "fixed", pinKey: key)
            case "videos":
                sidebarRow(.videos, icon: "video", title: "视频", scope: "fixed", pinKey: key)
            case "screenshots":
                sidebarRow(.screenshots, icon: "camera.viewfinder", title: "截屏", scope: "fixed", pinKey: key)
            case "people":
                sidebarRow(.people, icon: "person.crop.square", title: "人物", scope: "fixed", pinKey: key)
            case "selfies":
                sidebarRow(.selfies, icon: "person.crop.circle", title: "自拍", scope: "fixed", pinKey: key)
            case "livePhotos":
                sidebarRow(.livePhotos, icon: "livephoto", title: "实况照片", scope: "fixed", pinKey: key)
            case "panoramas":
                sidebarRow(.panoramas, icon: "pano", title: "全景照片", scope: "fixed", pinKey: key)
            case "animated":
                sidebarRow(.animated, icon: "photo.on.rectangle.angled", title: "动图",
                           scope: "fixed", pinKey: key)
            case "raws":
                sidebarRow(.raws, icon: "camera.aperture", title: "RAW", scope: "fixed", pinKey: key)
            case "recentlyEdited":
                sidebarRow(.recentlyEdited, icon: "slider.horizontal.3", title: "最近编辑",
                           scope: "fixed", pinKey: key)
            case "imports":
                sidebarRow(.imports, icon: "square.and.arrow.down.on.square", title: "导入项目",
                           scope: "fixed", pinKey: key)
            case "hidden":
                sidebarRow(.hidden, icon: "eye.slash", title: "已隐藏",
                           color: .secondary, scope: "fixed", pinKey: key)
            case "trash":
                trashRow(scope: "fixed", pinKey: key)
            default:
                EmptyView()
            }
        case .album(let id):
            if let album = store.albums.first(where: { $0.id == id }) {
                albumRow(album, level: 0, scope: "fixed")
            }
        case .folder(let id):
            if let folder = store.folders.first(where: { $0.id == id }) {
                folderNode(folder, level: 0, scope: "fixed")
            }
        }
    }

    private func folderNode(_ folder: AlbumFolder, level: Int, scope: String = "albums") -> AnyView {
        let isExpanded = expandedFolders.contains(folder.id)
        let childFolders = store.childFolders(of: folder.id)
        let childAlbums = store.albums(in: folder.id)
        let hasChildren = !childFolders.isEmpty || !childAlbums.isEmpty

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Button {
                        withAnimation(settings.motion.layout) {
                            if isExpanded {
                                expandedFolders.remove(folder.id)
                            } else {
                                expandedFolders.insert(folder.id)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hasChildren ? 1 : 0)
                    .disabled(!hasChildren)

                    Button {
                        store.navigate(to: .folder(folder.id))
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "folder.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18, height: 18)
                            .background(Color.accentColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: settings.smallCoverRadius))
                        Text(folder.name)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, CGFloat(level) * 14 + 4)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .background {
                    if store.sidebarItem == .folder(folder.id) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.accentColor.opacity(0.16))
                    } else if hoveredItem == .folder(folder.id) && hoveredItemScope == scope {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(0.06))
                    }
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
            HStack(spacing: 7) {
                AlbumCoverView(album: album)
                Text(album.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(level) * 14 + 22)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == .album(album.id) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if dropTargetAlbumID == album.id {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.24))
                } else if hoveredItem == .album(album.id) && hoveredItemScope == scope {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
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

    private func smartAlbumRow(_ album: SmartAlbum) -> some View {
        let item = SidebarItem.smartAlbum(album.id)
        return Button {
            store.navigate(to: item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: settings.smallCoverRadius))
                Text(album.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredItem == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
        }
        .contextMenu {
            Button("打开智能相簿") { store.navigate(to: item) }
            Button("编辑条件…") { store.presentSmartAlbumEditor(album) }
            Divider()
            Button("删除智能相簿", role: .destructive) { store.deleteSmartAlbum(album.id) }
        }
        .help(album.summary)
    }

    /// 可收起的分区头：悬停时显示「更多」与「收起 / 展开」。
    @ViewBuilder
    private func sectionHeader<MenuContent: View>(
        _ title: String,
        key: String,
        topPadding: CGFloat = 16,
        @ViewBuilder menu: () -> MenuContent = { EmptyView() }
    ) -> some View {
        let collapsed = collapsedSections.contains(key)
        let hovering = hoveredSection == key

        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if hovering {
                Menu {
                    Button(collapsed ? "展开" : "收起") {
                        withAnimation(settings.motion.layout) { toggleSection(key) }
                    }
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .help("更多")
            }
            if hovering || collapsed {
                Button {
                    withAnimation(settings.motion.layout) { toggleSection(key) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "展开" : "收起")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, topPadding)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredSection = inside ? key : (hoveredSection == key ? nil : hoveredSection)
        }
    }

    private func toggleSection(_ key: String) {
        if collapsedSections.contains(key) {
            collapsedSections.remove(key)
        } else {
            collapsedSections.insert(key)
        }
    }

    private func isCollapsed(_ key: String) -> Bool {
        collapsedSections.contains(key)
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
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    Text("分析照片内容…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
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
        return Button {
            store.navigate(to: item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: category.icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(category.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.13))
                } else if hoveredItem == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .help("查看「\(category.title)」照片")
        .onHover { hovering in
            hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
        }
    }

    // MARK: - System libraries

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
        sectionHeader("系统图库", key: "sys.libraries") {
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
                    HStack(spacing: 7) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("连接照片图库…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
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
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 12.5))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: 18)
                    Text(ref.name)
                        .font(.system(size: 12.5))
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
                .padding(.vertical, 5)
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
                    store.removeSystemLibrary(ref.path)
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
            if isHighlighted {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.16))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.06))
            }
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
            Button("断开连接", role: .destructive) { store.removeSystemLibrary(ref.path) }
        }
    }

    /// 当前系统图库的浏览入口（共享 / 媒体类型 / 更多项目 / 项目 / 相簿），缩进挂在对应图库下面。
    @ViewBuilder
    private var systemLibraryDetail: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            sectionHeader("共享", key: "sys.shared", topPadding: 8)
            if !isCollapsed("sys.shared") {
                systemSharedAlbumsRow
            }

            sectionHeader("媒体类型", key: "sys.media", topPadding: 12)
            if !isCollapsed("sys.media") {
                sidebarRow(.systemVideos, icon: "video", title: "视频")
                sidebarRow(.systemSelfies, icon: "person.crop.circle", title: "自拍")
                sidebarRow(.systemLivePhotos, icon: "livephoto", title: "实况照片")
                sidebarRow(.systemPortraits, icon: "person.crop.rectangle", title: "人像")
                sidebarRow(.systemPanoramas, icon: "pano", title: "全景照片")
                sidebarRow(.systemSlowMotion, icon: "slowmo", title: "慢动作")
                sidebarRow(.systemScreenshots, icon: "camera.viewfinder", title: "截屏")
                sidebarRow(.systemScreenRecordings, icon: "record.circle", title: "录屏")
                sidebarRow(.systemAnimated, icon: "photo.on.rectangle.angled", title: "动图")
                sidebarRow(.systemRAW, icon: "camera.aperture", title: "RAW")
            }

            sectionHeader("更多项目", key: "sys.more", topPadding: 12)
            if !isCollapsed("sys.more") {
                sidebarRow(.systemFavorites, icon: "heart.fill", title: "个人收藏", color: .pink)
                systemTrashRow
                if store.systemDuplicateCount > 0 {
                    sidebarRow(.systemDuplicates, icon: "square.on.square", title: "重复项目")
                }
                sidebarRow(.systemHandwriting, icon: "pencil.tip", title: "手写")
                sidebarRow(.systemIllustrations, icon: "scribble.variable", title: "插图")
                if store.systemRecentlySavedCount > 0 {
                    sidebarRow(.systemRecentlySaved, icon: "square.and.arrow.down", title: "最近保存")
                }
                sidebarRow(.systemRecentlyViewed, icon: "eye", title: "最近查看")
                sidebarRow(.systemEdited, icon: "slider.horizontal.3", title: "最近编辑")
                if store.systemImportCount > 0 {
                    sidebarRow(.systemImports, icon: "square.and.arrow.down.on.square", title: "导入项目")
                }
                sidebarRow(.systemMap, icon: "map", title: "地图")
                sidebarRow(.systemPlaces, icon: "mappin.and.ellipse", title: "位置")
                sidebarRow(.systemPeople, icon: "person.2", title: "人物")
                if store.systemHiddenCount > 0 {
                    sidebarRow(.systemHidden, icon: "eye.slash", title: "已隐藏", color: .secondary)
                }
            }

            sectionHeader("项目", key: "sys.project", topPadding: 12)
            if !isCollapsed("sys.project") {
                sidebarRow(.systemLibrary, icon: "photo.stack", title: "所有项目")
            }

            if store.isLoadingSystemLibrary {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 18)
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
                sectionHeader("相簿", key: "sys.albums", topPadding: 12)
            }
            if !isCollapsed("sys.albums") {
                ForEach(store.systemChildren(of: nil)) { entry in
                    systemNode(entry, level: 0)
                }
            }
        }
        .padding(.leading, 14)
    }

    private var systemSharedAlbumsRow: some View {
        Button {
            store.navigate(to: .systemSharedAlbums)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text("共享相簿")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == .systemSharedAlbums {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredItem == .systemSharedAlbums {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering
                ? .systemSharedAlbums
                : (hoveredItem == .systemSharedAlbums ? nil : hoveredItem)
        }
    }

    private var systemTrashRow: some View {
        Button {
            store.navigate(to: .systemTrash)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "trash")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("最近删除")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == .systemTrash {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredItem == .systemTrash {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? .systemTrash : (hoveredItem == .systemTrash ? nil : hoveredItem)
        }
    }

    // MARK: - Network storage

    @ViewBuilder
    private var cloudSection: some View {
        sectionHeader("网络存储", key: "cloud") {
            Button("网盘接入向导…") {
                store.presentCloudWizard()
            }
        }

        if !isCollapsed("cloud") {
            if cloud.mounts.isEmpty {
                Button {
                    store.presentCloudWizard()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        Text("网盘接入向导…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(cloud.mounts) { mount in
                    cloudMountRow(mount)
                }
            }
        }
    }

    private func cloudMountRow(_ mount: CloudMount) -> some View {
        let item = SidebarItem.cloudMount(mount.id)
        return Button {
            store.navigate(to: item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: mountIcon(mount.kind))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(mount.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if cloud.loading, store.sidebarItem == item {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredItem == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
        }
        .contextMenu {
            Button("刷新") {
                if store.sidebarItem == item {
                    store.refreshCloudDirectory()
                } else {
                    store.navigate(to: item)
                }
            }
            if mount.kind == .webdav || mount.kind == .smb {
                Button("编辑连接…") {
                    store.presentCloudSheet(mount)
                }
            } else {
                Button("重新授权…") {
                    store.presentCloudWizard(flow: mount.kind == .aliyun ? .aliyun : .baidu)
                }
            }
            Divider()
            Button("断开连接", role: .destructive) {
                store.removeCloudMount(mount.id)
            }
        }
    }

    private func mountIcon(_ kind: CloudKind) -> String {
        switch kind {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .smb: return "network"
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        }
    }

    private func systemFolderNode(_ folder: SystemFolderInfo, level: Int) -> AnyView {
        let isExpanded = expandedSystemFolders.contains(folder.id)
        let children = store.systemChildren(of: folder.id)
        let hasChildren = !children.isEmpty

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Button {
                        withAnimation(settings.motion.layout) {
                            if isExpanded {
                                expandedSystemFolders.remove(folder.id)
                            } else {
                                expandedSystemFolders.insert(folder.id)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hasChildren ? 1 : 0)
                    .disabled(!hasChildren)

                    Button {
                        store.navigate(to: .systemFolder(folder.id))
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "folder.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18, height: 18)
                            .background(Color.accentColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: settings.smallCoverRadius))
                        Text(folder.name)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, CGFloat(level) * 14 + 4)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .background {
                    if store.sidebarItem == .systemFolder(folder.id) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.accentColor.opacity(0.16))
                    } else if hoveredSystemFolder == folder.id {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .onHover { hovering in
                    hoveredSystemFolder = hovering ? folder.id : (hoveredSystemFolder == folder.id ? nil : hoveredSystemFolder)
                }
                .contextMenu {
                    Button("打开文件夹") {
                        store.navigate(to: .systemFolder(folder.id))
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

    private func systemAlbumRow(_ album: SystemAlbumInfo, level: Int) -> some View {
        Button {
            store.navigate(to: .systemAlbum(album.id))
        } label: {
            HStack(spacing: 7) {
                SystemAlbumCoverView(albumID: album.id)
                Text(album.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if album.assetIDs.isEmpty {
                    Image(systemName: "tray")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, CGFloat(level) * 14 + 22)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background {
                if store.sidebarItem == .systemAlbum(album.id) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredItem == .systemAlbum(album.id) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? .systemAlbum(album.id) : (hoveredItem == .systemAlbum(album.id) ? nil : hoveredItem)
        }
        .contextMenu {
            Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
            Button("拷贝到拾光") {
                store.importSystemAlbumToLibrary(album.id)
            }
            if let path = store.systemLibraryPath {
                Button("在访达中显示图库") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
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
                PhotoThumbnailView(photo: coverPhoto, purpose: .cover(18))
            } else {
                RoundedRectangle(cornerRadius: settings.smallCoverRadius)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: settings.smallCoverRadius))
    }
}

private struct SystemAlbumCoverView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    let albumID: Int64

    private var firstPhoto: PhotoItem? {
        guard let album = store.systemAlbums.first(where: { $0.id == albumID }),
              let first = album.assetIDs.first else { return nil }
        return store.systemPhoto(id: first)
    }

    var body: some View {
        Group {
            if let firstPhoto {
                PhotoThumbnailView(photo: firstPhoto, purpose: .cover(18))
            } else {
                RoundedRectangle(cornerRadius: settings.smallCoverRadius)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: settings.smallCoverRadius))
    }
}
