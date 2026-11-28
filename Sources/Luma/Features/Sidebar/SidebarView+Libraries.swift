import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaContentCore

extension SidebarView {
    // MARK: - System libraries

    /// 媒体类型数量：与系统「照片」一致，数量为 0 的类型不显示入口。
    var mediaTypeCounts: [MediaTypeKey: Int] {
        store.mediaTypeSummary.counts
    }

    // MARK: - Libraries

    /// 统一的「图库」分区：当前图库与已连接图库都是这里的实例。
    /// 展开分区看到图库实例，展开实例才看到它自己的左侧树；
    /// 结构跟「网络存储 / 网络资源 / 网络电视」完全对齐。
    @ViewBuilder
    var librariesSection: some View {
        sectionHeader("图库", key: "library", topPadding: 4, isModule: true,
                      navigateTo: .systemLibraries) {
            if store.isNativeContainer {
                Button("在「照片」中打开图库") { store.openContainerInPhotos() }
                Button("重新读取") { store.reloadSystemLibrary() }
                Button("在访达中显示图库") { store.revealSystemLibraryInFinder() }
                Divider()
            }
            Button("打开其他图库…") { store.presentLibraryContainerPanel() }
            Button("新建图库…") { store.beginNewLibraryFlow() }
            if let url = LibraryPaths.containerLibraryURL {
                Divider()
                Button("断开当前图库…", role: .destructive) {
                    store.confirmDisconnectLibrary(
                        path: url.path,
                        name: url.deletingPathExtension().lastPathComponent)
                }
            }
        }

        if !isCollapsed("library") {
            currentLibraryRow

            // 当前图库的树紧跟在自己的行下面：放在别的图库之后会看起来像挂到了别人身上。
            if expandedLinkedLibraryPath == nil, !isCollapsed("library.current") {
                // 树整体比图库行再缩进一级：图标列与图库行的图标列错开，层级一眼能看出。
                if store.isNativeContainer {
                    systemLibraryDetail
                        .padding(.leading, SidebarTreeMetrics.childIndent)
                } else {
                    lumaLibraryTree
                        .padding(.leading, SidebarTreeMetrics.childIndent)
                }
            }

            // 其他打开过的图库：默认图库排最前，其余平铺，不会因为新建图库而消失。
            ForEach(otherKnownLibraries) { ref in
                knownLibraryRow(ref)
            }

            // 其他已连接图库：同一时间只展开当前正在浏览的那个。
            ForEach(store.systemLibraries) { ref in
                let isExpanded = (store.systemLibraryPath.map {
                    store.isSameSystemLibraryPath($0, ref.path)
                } ?? false) && !collapsedSystemLibraries.contains(ref.path)
                systemLibraryRefRow(ref, isExpanded: isExpanded)
                if isExpanded {
                    systemLibraryDetail
                        .padding(.leading, SidebarTreeMetrics.childIndent)
                }
            }

            if store.systemLibraries.isEmpty {
                Button {
                    store.presentSystemLibraryPanel()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("连接其他图库…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 「图库」下的当前实例：始终显示图库自己的名字。
    var currentLibraryRow: some View {
        let currentPath = LibraryPaths.containerLibraryURL?.path ?? ""
        let name = libraryDisplayName(appContainerLibraryName, path: currentPath)
        let isDefault = store.isDefaultLibrary(currentPath)
        let isExplicitDefault = store.isExplicitDefaultLibrary(currentPath)
        let expanded = !isCollapsed("library.current")
        let isActive = currentLibraryIsActive

        return HStack(spacing: 2) {
            Button {
                if expanded {
                    withAnimation(settings.motion.layout) {
                        setSectionCollapsed("library.current", true)
                    }
                    persistExpansionState()
                } else {
                    activateCurrentLibrary()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .help(expanded ? "收起" : "展开")

            Button {
                activateCurrentLibrary()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(name)
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    libraryKindBadge(isDefault: isDefault)
                }
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExplicitDefault
                  ? "默认图库：启动时自动打开"
                  : (isDefault ? "上次打开的图库：下次启动会继续打开它" : name))
            .contextMenu {
                Button("打开图库") { activateCurrentLibrary() }
                if store.isNativeContainer {
                    Button("在「照片」中打开图库") { store.openContainerInPhotos() }
                }
                if let url = LibraryPaths.containerLibraryURL {
                    Button("在访达中显示图库") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    if store.isNativeContainer {
                        Button("重新检测写入目标") {
                            store.refreshSystemWriteTargetState(announce: true)
                        }
                        .help("只有「照片」正在使用的官方图库才能新建 / 重命名 / 删除相簿")
                        if store.systemWriteTargetState == .mismatch {
                            Button("重新启动拾光以启用编辑") {
                                store.relaunchForLibraryWrite()
                            }
                            .help("在「照片」里切换图库后，PhotoKit 需要重启拾光才会指向新库")
                        }
                    }
                    Divider()
                    Button("断开连接…", role: .destructive) {
                        store.confirmDisconnectLibrary(path: url.path, name: name)
                    }
                    .help("退出当前图库并回到「创建或打开图库」；磁盘上的图库文件保留")
                }
            }
        }
        .background {
            LumaRowHighlight(active: isActive, hovered: hoveredCurrentLibrary)
        }
        .onHover { hovering in
            hoveredCurrentLibrary = hovering
        }
    }

    /// 其他打开过的图库（不含当前图库与已连接的图库）：默认图库排最前。
    var otherKnownLibraries: [SystemLibraryRef] {
        let currentPath = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
        return store.knownLibraries
            .filter { ref in
                if let currentPath,
                   store.isSameSystemLibraryPath(ref.path, currentPath) { return false }
                if store.systemLibraries.contains(where: {
                    store.isSameSystemLibraryPath($0.path, ref.path)
                }) { return false }
                return true
            }
            .sorted { lhs, rhs in
                let leftDefault = store.isDefaultLibrary(lhs.path)
                let rightDefault = store.isDefaultLibrary(rhs.path)
                if leftDefault != rightDefault { return leftDefault }
                return false
            }
    }

    /// 一个打开过的图库：点一下切换过去；默认图库带锁且不能移除。
    func knownLibraryRow(_ ref: SystemLibraryRef) -> some View {
        let isDefault = store.isDefaultLibrary(ref.path)
        let isExplicitDefault = store.isExplicitDefaultLibrary(ref.path)
        let name = libraryDisplayName(ref.name, path: ref.path)
        let exists = LibraryPaths.exists(atPath: ref.path)
        return HStack(spacing: 2) {
            // 与带展开箭头的图库行左对齐。
            Spacer()
                .frame(width: 20)

            Button {
                guard exists else {
                    store.showToast("找不到「\(name)」，可能已被移动或删除")
                    return
                }
                store.activateLibrary(URL(fileURLWithPath: ref.path))
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: isDefault ? "internaldrive.fill" : "externaldrive.fill")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(.secondary)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(name)
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .foregroundStyle(exists ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    libraryKindBadge(isDefault: isDefault)
                }
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExplicitDefault
                  ? "默认图库：启动时自动打开"
                  : (isDefault ? "上次打开的图库：下次启动会继续打开它"
                               : (exists ? "点击切换到这个图库"
                                         : "图库不存在：可能已被移动、删除，或外置盘未连接")))
            .contextMenu {
                Button("打开此图库") {
                    store.activateLibrary(URL(fileURLWithPath: ref.path))
                }
                .disabled(!exists)
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
                }
                if exists, !isExplicitDefault {
                    Button("设为默认图库") { store.setDefaultLibrary(ref.path) }
                }
                Divider()
                Button("断开连接…", role: .destructive) {
                    store.confirmDisconnectLibrary(path: ref.path, name: name)
                }
                .help("从「全部图库」移除；如果是当前图库，会回到「创建或打开图库」")
            }
        }
    }

    /// 图库标签：只有「默认」（启动时会打开的那个）才显示。
    /// 用行尾灰色小字，不再用强调色胶囊，避免和选中态抢注意力。
    @ViewBuilder
    func libraryKindBadge(isDefault: Bool) -> some View {
        if isDefault {
            Text("默认")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("默认图库：启动时自动打开")
        }
    }

    /// App 自己图库的名字：始终取容器名，不能跟着「当前连接的系统图库」改名。
    var appContainerLibraryName: String {
        guard let url = LibraryPaths.containerLibraryURL else { return "图库" }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "图库" : name
    }

    /// 当前图库的树是否正渲染在它的行下面。渲染时高亮交给树里更具体的那一行，
    /// 父级图库行让位，避免父行与子行同时点亮。
    var currentLibraryTreeVisible: Bool {
        expandedLinkedLibraryPath == nil && !isCollapsed("library.current")
    }

    /// 当前图库行是否处于高亮：外接 B 时 A 必须让出高亮，避免两行同时选中。
    var currentLibraryIsActive: Bool {
        // 「图库资源」是跨图库总览：不点亮任何图库行。
        if store.sidebarItem == .systemLibraries { return false }
        // 树展开时，选中的是树里的某一具体页面，高亮由那一行承担。
        if currentLibraryTreeVisible { return false }
        if !store.isSystemScope { return true }
        return store.isNativeContainer && store.isBrowsingContainerSystemLibrary
    }

    /// 同名图库用上级目录区分，避免两行看起来一模一样。
    /// 当前图库、打开过的图库与已连接的图库一起统计，同名的两条才会加后缀。
    func libraryDisplayName(_ name: String, path: String) -> String {
        var paths = Set<String>()
        if appContainerLibraryName == name,
           let current = LibraryPaths.containerLibraryURL?.standardizedFileURL.path {
            paths.insert(current)
        }
        for ref in store.knownLibraries where ref.name == name {
            paths.insert(URL(fileURLWithPath: ref.path).standardizedFileURL.path)
        }
        for ref in store.systemLibraries where ref.name == name {
            paths.insert(URL(fileURLWithPath: ref.path).standardizedFileURL.path)
        }
        guard paths.count > 1 else { return name }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? name : "\(name) · \(parent)"
    }

    /// 点当前图库：展开它自己的树，并切回 App 自己的图库（外接 B 时也能回到 A）。
    func activateCurrentLibrary() {
        withAnimation(settings.motion.layout) {
            collapsedSystemLibraries.formUnion(store.systemLibraries.map(\.path))
            setSectionCollapsed("library.current", false)
        }
        persistExpansionState()
        if store.isNativeContainer, let url = LibraryPaths.containerLibraryURL {
            store.connectSystemLibrary(url)
        } else {
            store.navigate(to: .library)
        }
    }

    /// 当前真正展开着的外接图库（只有一个）。它展开时当前图库的树不再渲染。
    var expandedLinkedLibraryPath: String? {
        guard let active = store.systemLibraryPath,
              let match = store.systemLibraries.first(where: {
                  store.isSameSystemLibraryPath($0.path, active)
              }),
              !collapsedSystemLibraries.contains(match.path) else { return nil }
        return match.path
    }

    /// 点外接图库：只展开这一棵，当前图库那棵同时合上。
    func activateLinkedLibrary(_ ref: SystemLibraryRef) {
        withAnimation(settings.motion.layout) {
            collapsedSystemLibraries.remove(ref.path)
            setSectionCollapsed("library.current", true)
        }
        persistExpansionState()
        store.sourceHub.activate(.linkedLibrary(ref.path))
    }

    func setSectionCollapsed(_ key: String, _ collapsed: Bool) {
        if collapsed {
            collapsedSections.insert(key)
            expandedSections.remove(key)
        } else {
            collapsedSections.remove(key)
            expandedSections.insert(key)
        }
    }

    /// 拾光自己图库的左侧树：作为「图库」实例展开后的内容。
    @ViewBuilder
    var lumaLibraryTree: some View {
        sidebarRow(.library, icon: "photo.stack", title: "图库")
        sidebarRow(.collections, icon: "square.stack.3d.up", title: "精选集")

        sectionHeader("固定", key: "luma.fixed", topPadding: 14, indent: 0)
        if !isCollapsed("luma.fixed") {
            pinnedRows(system: false)
        }

        let mediaTypes = visibleMediaTypes(system: false)
        if !mediaTypes.isEmpty {
            sectionHeader("媒体类型", key: "luma.media", topPadding: 14, indent: 0, navigateTo: .mediaTypes)
            if !isCollapsed("luma.media") {
                ForEach(mediaTypes) { key in
                    sidebarRow(key.item(system: false), icon: key.icon, title: key.title,
                               pinKey: key.rawValue)
                }
            }
        }

        let moreItems = visibleMoreItemKeys(system: false)
        if !moreItems.isEmpty {
            sectionHeader("更多项目", key: "luma.more", topPadding: 14, indent: 0, navigateTo: .moreItems)
            if !isCollapsed("luma.more") {
                ForEach(moreItems, id: \.self) { key in
                    if let info = pinnedSystemInfo(for: key, system: false) {
                        sidebarRow(info.item, icon: info.icon, title: info.title,
                                   color: info.color, pinKey: key)
                    }
                }
            }
        }

        // 场景全部被固定后整段隐藏，避免只剩一个空标题。
        if hasUnpinnedScenes {
            sectionHeader("场景", key: "luma.scenes", topPadding: 14, indent: 0, navigateTo: .scenes) {
                // 识别中的状态与进度只在任务中心展示，侧边栏不再出现「停止分析」这类状态项。
                Button(store.analyzedCount > 0 ? "分析新照片与视频…" : "分析照片与视频内容…") {
                    store.analyzeIntelligence()
                }
                if store.analyzedCount > 0 {
                    Button("重新分析全部照片与视频…") {
                        store.reanalyzeIntelligence()
                    }
                    Button("重置（清空结果）…", role: .destructive) {
                        showResetAnalysisConfirm = true
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
        }

        sectionHeader("相簿", key: "luma.albums", topPadding: 14, indent: 0,
                      navigateTo: .allAlbums,
                      // 展开时下面有「所有相簿」行，高亮让给它；收起时才落在标题上。
                      active: store.sidebarItem == .allAlbums && isCollapsed("luma.albums")) {
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
            sectionHeader("智能相簿", key: "luma.smart", topPadding: 14, indent: 0) {
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
    }

    /// 已连接的系统图库列表；同一时间只有一个处于连接/展开状态。
    func systemLibraryRefRow(_ ref: SystemLibraryRef, isExpanded: Bool) -> some View {
        let isActive = store.systemLibraryPath.map { store.isSameSystemLibraryPath($0, ref.path) } ?? false
        // 图库资源总览不属于某一个图库；树展开时高亮同样交给下面的具体行。
        let isHighlighted = isActive && store.isSystemScope
            && store.sidebarItem != .systemLibraries
            && !isExpanded
        let isHovered = hoveredSystemLibraryPath == ref.path
        let isDefault = store.isDefaultLibrary(ref.path)

        return HStack(spacing: 2) {
            Button {
                if isActive {
                    withAnimation(settings.motion.layout) {
                        if isExpanded {
                            collapsedSystemLibraries.insert(ref.path)
                            persistExpansionState()
                        } else {
                            activateLinkedLibrary(ref)
                        }
                    }
                } else {
                    activateLinkedLibrary(ref)
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
                activateLinkedLibrary(ref)
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(libraryDisplayName(ref.name, path: ref.path))
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    libraryKindBadge(isDefault: isDefault)
                    // 图库行不再显示照片个数：长名字会被挤压成「李…」，统一在「图库资源」里看体量。
                    if isActive, store.isLoadingSystemLibrary {
                        ProgressView()
                            .controlSize(.mini)
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
                    store.connectSystemLibrary(URL(fileURLWithPath: ref.path), forceRefresh: true)
                }
                Button("在访达中显示图库") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
                }
                Button("选择其他图库…") { store.presentSystemLibraryPanel() }
                Button("新建图库…") { store.beginNewLibraryFlow() }
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
    var systemLibraryDetail: some View {
        // 不套内层 LazyVStack：所有行直接进入侧边栏最外层的 LazyVStack，
        // 展开成千上万个相簿时也只实例化可见行（对标系统「照片」的侧边栏）。
        Group {
            // 与「拾光」分区一致：最上面是系统图库自己的「图库」与「精选集」。
            sidebarRow(.systemLibrary, icon: "photo.stack", title: "图库")
            sidebarRow(.systemCollections, icon: "square.stack.3d.up", title: "精选集")

            sectionHeader("固定", key: "sys.fixed", topPadding: 14)
            if !isCollapsed("sys.fixed") {
                pinnedRows(system: true)
            }

            let mediaTypeRows = visibleMediaTypes(system: true)
            if !mediaTypeRows.isEmpty {
                sectionHeader("媒体类型", key: "sys.media", topPadding: 14, navigateTo: .systemMediaTypes)
                if !isCollapsed("sys.media") {
                    ForEach(mediaTypeRows) { key in
                        sidebarRow(key.item(system: true), icon: key.icon, title: key.title,
                                   pinKey: key.rawValue)
                    }
                }
            }

            let moreItems = visibleMoreItemKeys(system: true)
            if !moreItems.isEmpty {
                sectionHeader("更多项目", key: "sys.more", topPadding: 14, navigateTo: .systemMoreItems)
                if !isCollapsed("sys.more") {
                    ForEach(moreItems, id: \.self) { key in
                        if let info = pinnedSystemInfo(for: key, system: true) {
                            sidebarRow(info.item, icon: info.icon, title: info.title,
                                       color: info.color, pinKey: key)
                        }
                    }
                }
            }

            // 场景全部被固定后整段隐藏，避免只剩一个空标题。
            if hasUnpinnedSystemScenes {
                sectionHeader("场景", key: "sys.scenes", topPadding: 14, navigateTo: .systemScenes) {
                    // 同本地图库：识别状态与进度交给任务中心，侧边栏只保留常规入口。
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
                if !isCollapsed("sys.scenes") {
                    systemSceneSectionBody
                }
            }

            // 载入进度只在任务中心（底部任务条 / 任务记录）里展示，侧边栏不再重复一行文字。
            if let error = store.systemLibraryError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }

            // 可写的原生图库即使还没有相簿也保留分区入口，否则无法新建第一个相簿。
            if !store.systemFolders.isEmpty || !store.systemAlbums.isEmpty || store.canManageSystemAlbums {
                sectionHeader("相簿", key: "sys.albums", topPadding: 14, navigateTo: .systemAlbums) {
                    if store.canManageSystemAlbums {
                        Button("新建相簿…") {
                            store.namePrompt = .newSystemAlbum()
                        }
                        Button("新建文件夹…") {
                            store.namePrompt = .newSystemFolder()
                        }
                        Divider()
                        Button("清理空相簿与空文件夹…") {
                            store.presentEmptyCollectionsCleanup()
                        }
                    } else {
                        Text("挂载的图库只读，无法新建相簿或文件夹")
                            .disabled(true)
                    }
                }
            }
            if !isCollapsed("sys.albums") {
                let rows = store.systemFlatRows(expanded: expandedSystemFolders,
                                                expansionRevision: systemExpansionRevision)
                ForEach(rows) { row in
                    systemFlatRow(row.entry, level: row.level)
                }
            }
        }
    }
}
