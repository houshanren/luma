import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaContentCore

extension SidebarView {
    // MARK: - Network storage

    /// 侧边栏的源行统一由注册表驱动：新增 kind 只加注册表条目，不再在这里铺数组。
    var cloudSourceDescriptors: [SourceDescriptor] {
        store.sourceRegistryState.sources(of: .cloudMount)
    }

    /// 影视源只在「网络影院」出现，网络资源分区只列网页资源站。
    var catalogSourceDescriptors: [SourceDescriptor] {
        let cinemaIDs = catalog.cinemaSourceIDs
        return store.sourceRegistryState.sources(of: .catalogSite).filter { descriptor in
            guard let id = descriptor.id.uuidValue else { return true }
            return !cinemaIDs.contains(id)
        }
    }

    @ViewBuilder
    var cloudSection: some View {
        sectionHeader("网络存储", key: "cloud", topPadding: 8, isModule: true,
                      navigateTo: .cloudStorages) {
            Button("网盘接入向导…") {
                store.presentCloudWizard()
            }
        }

        if !isCollapsed("cloud") {
            if cloudSourceDescriptors.isEmpty {
                Button {
                    store.presentCloudWizard()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
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
                ForEach(cloudSourceDescriptors) { descriptor in
                    if let mountID = descriptor.id.uuidValue,
                       let mount = cloud.mounts.first(where: { $0.id == mountID }) {
                        CloudMountSidebarRow(mount: mount,
                                             expandedMountID: $expandedCloudMountID)
                    }
                }
            }
        }
    }

    // MARK: - Network resources (catalog)

    @ViewBuilder
    var catalogSection: some View {
        sectionHeader("网络资源", key: "catalog", topPadding: 8, isModule: true,
                      navigateTo: .catalogSources) {
            Button("接入资源…") {
                store.presentCatalogWizard()
            }
            Button("导出资源…") {
                store.exportSourceConfig(scope: .catalogResource,
                                         count: catalog.resourceSources.count,
                                         data: { catalog.exportSourceBundle(domain: .networkResource) })
            }
            .disabled(catalog.resourceSources.isEmpty)
            Button("清除全部海报缓存") {
                catalog.clearAllArtwork()
            }
        }

        if !isCollapsed("catalog") {
            if catalogSourceDescriptors.isEmpty {
                Button {
                    store.presentCatalogWizard()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("接入网络资源…")
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
                // 不再保留「全部资源」这个聚合入口：分区本身就是资源总览，
                // 展开后直接列各个源，和「图库 / 网络存储 / 网络电视」保持一致。
                ForEach(catalogSourceDescriptors) { descriptor in
                    if let sourceID = descriptor.id.uuidValue,
                       let source = catalog.sources.first(where: { $0.id == sourceID }) {
                        CatalogSidebarRow(source: source,
                                          isDropTarget: catalogDropTargetID == source.id)
                            .onDrop(of: [catalogSourceDragType],
                                    delegate: CatalogSourceReorderDropDelegate(
                                        target: source.id,
                                        catalog: catalog,
                                        onTargeted: { targeted in
                                            if targeted {
                                                catalogDropTargetID = source.id
                                            } else if catalogDropTargetID == source.id {
                                                catalogDropTargetID = nil
                                            }
                                        }))
                    }
                }
                // 拖到列表末尾 → 排到最后，顺序同样作用于跨源搜索与聚合。
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [catalogSourceDragType],
                            delegate: CatalogSourceEndDropDelegate(catalog: catalog))
            }
        }
    }

    // MARK: - 网络影院

    /// 网络影院：独立于「网络存储 › 影院」，只聚合网络影视源。
    /// 与「网络资源」一致，展开后只列一级源行；分页（影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注）在页面工具栏里切换。
    @ViewBuilder
    var networkCinemaSection: some View {
        sectionHeader("网络影院", key: "netcinema", topPadding: 8, isModule: true,
                      navigateTo: .networkCinema,
                      beforeNavigate: {
                          store.networkCinemaSourceID = nil
                      }) {
            Button("接入影视源…") {
                store.presentCatalogWizard(domain: .networkCinema)
            }
            Button("导出影视源…") {
                store.exportSourceConfig(scope: .networkCinema,
                                         count: catalog.cinemaSources.count,
                                         data: { catalog.exportSourceBundle(domain: .networkCinema) })
            }
            .disabled(catalog.cinemaSources.isEmpty)
        }

        if !isCollapsed("netcinema") {
            if enabledMovieSources.isEmpty {
                Button {
                    store.presentCatalogWizard(domain: .networkCinema)
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "popcorn")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("接入影视源…")
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
                ForEach(enabledMovieSources) { source in
                    NetworkCinemaSidebarRow(source: source,
                                            isDropTarget: catalogDropTargetID == source.id)
                        .onDrop(of: [catalogSourceDragType],
                                delegate: CatalogSourceReorderDropDelegate(
                                    target: source.id,
                                    catalog: catalog,
                                    onTargeted: { targeted in
                                        if targeted {
                                            catalogDropTargetID = source.id
                                        } else if catalogDropTargetID == source.id {
                                            catalogDropTargetID = nil
                                        }
                                    }))
                }
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [catalogSourceDragType],
                            delegate: CatalogSourceEndDropDelegate(catalog: catalog))
            }
        }
    }

    var enabledMovieSources: [CatalogSource] {
        catalog.enabledCinemaSources
    }

    // MARK: - 网络电视

    @ViewBuilder
    var tvSection: some View {
        // 点分区标题直接进「全频直播 · 聚合」：不沿用上次聚焦的某个源，
        // 否则会像点开 APTV 一样停在单个源上。
        sectionHeader("网络电视", key: "tv", topPadding: 8, isModule: true,
                      navigateTo: .iptv,
                      beforeNavigate: {
                          tv.focusAllSources()
                          tv.setHubTab(.channels)
                      }) {
            Button("刷新频道") { tv.refresh() }
                .disabled(!tv.enabled)
            Button("检测全部源") { tv.checkAllSources() }
                .disabled(!tv.enabled || tv.isChecking)
            Divider()
            Button("接入电视源…") { tv.showWizard = true }
            Button("导出电视源…") {
                store.exportSourceConfig(scope: .television,
                                         count: tv.playlists.count,
                                         data: { tv.exportPlaylistBundle() })
            }
            .disabled(tv.playlists.isEmpty)
        }

        if !isCollapsed("tv") {
            if tv.playlists.isEmpty {
                // 一个电视源都没有：显示「接入电视源…」，接入后换成源列表（与网络影院一致）。
                Button {
                    tv.showWizard = true
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "tv")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("接入电视源…")
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
                // 「收藏频道 / 最近观看」不再放在侧边栏：这两个入口已收进网络电视主页。
                // 电视源默认全部收起，不在侧边栏铺开频道分类，避免把整段撑得很长。
                ForEach(tv.playlists) { playlist in
                    let categories = tv.categoryGroups(for: playlist.id)
                    tvSourceRow(playlist, categories: categories)
                        .onDrop(of: [tvSourceDragType],
                                delegate: TVSourceReorderDropDelegate(
                                    target: playlist.id,
                                    tv: tv,
                                    onTargeted: { targeted in
                                        if targeted {
                                            tvDropTargetID = playlist.id
                                        } else if tvDropTargetID == playlist.id {
                                            tvDropTargetID = nil
                                        }
                                    }))
                    if expandedTVSources.contains(playlist.id) {
                        ForEach(categories) { category in
                            tvCategoryRow(category, playlistID: playlist.id)
                        }
                    }
                }
                // 拖到列表末尾 → 排到最后，顺序同样落进电视库。
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [tvSourceDragType],
                            delegate: TVSourceEndDropDelegate(tv: tv))
            }
        }
    }

    /// 电视源健康：按最近一次检测结果给行尾状态点，未检测 / 已停用保持安静。
    func tvSourceHealth(_ playlist: TVPlaylist) -> SourceHealth? {
        guard playlist.isEnabled else { return nil }
        if let error = playlist.lastError {
            return SourceHealth(state: .offline,
                                checkedAt: playlist.lastCheckedAt,
                                message: error)
        }
        if let latency = playlist.lastLatencyMilliseconds, latency > 2500 {
            return SourceHealth(state: .degraded,
                                checkedAt: playlist.lastCheckedAt,
                                message: "延迟偏高")
        }
        return store.sourceHub.health(for: .television(playlist.id))
    }

    func tvSourceRow(_ playlist: TVPlaylist, categories: [TVCategory]) -> some View {
        SourceSidebarRow(
            model: SourceRowModel(
                title: playlist.name,
                subtitle: nil,
                // 与「网络资源 / 网络存储」的源行一致：单行标题 + 行尾数量，不再用第二行副标题。
                badge: nil,
                countText: playlist.isEnabled ? playlist.lastChannelCount.map { "\($0)" } : nil,
                isCurrent: store.sidebarItem == .iptv
                    && tv.focusedPlaylistID == playlist.id
                    && tv.groupFilter == nil,
                isEnabled: playlist.isEnabled,
                isLoading: tv.isChecking,
                health: tvSourceHealth(playlist)
            ),
            isExpanded: expandedTVSources.contains(playlist.id),
            showsToggle: !categories.isEmpty,
            isDropTarget: tvDropTargetID == playlist.id,
            onOpen: { openTV(playlist.id) },
            onToggle: {
                if expandedTVSources.contains(playlist.id) {
                    expandedTVSources.remove(playlist.id)
                } else {
                    expandedTVSources.insert(playlist.id)
                }
            },
            onRetry: { tv.enqueueConnectionChecks([playlist.id]) },
            dragProvider: { tvSourceDragProvider(playlist.id) }
        ) { hovered in
            // 封面与其他源行同一套语言：渐变底 + 白色粗图标 + 描边与悬停微缩放。
            ZStack {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.95),
                                                  Color.accentColor.opacity(0.60)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image(systemName: playlist.isEnabled
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .frame(width: LumaMetrics.sidebarCoverSize,
                   height: LumaMetrics.sidebarCoverSize)
            .overlay {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered ? 0.34 : 0.20), lineWidth: 0.6)
            }
            .shadow(color: Color.accentColor.opacity(hovered ? 0.45 : 0.26),
                    radius: hovered ? 6 : 3, y: 1.5)
            .scaleEffect(hovered ? 1.06 : 1)
            .opacity(playlist.isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.16), value: hovered)
        } menu: {
            Button("打开频道") { openTV(playlist.id) }
            Button("连接检测") { tv.enqueueConnectionChecks([playlist.id]) }
                .disabled(!playlist.isEnabled || tv.isChecking)
            Divider()
            Button("上移") { tv.movePlaylist(playlist.id, by: -1) }
                .disabled(tv.playlists.first?.id == playlist.id)
            Button("下移") { tv.movePlaylist(playlist.id, by: 1) }
                .disabled(tv.playlists.last?.id == playlist.id)
            Divider()
            Button(playlist.isEnabled ? "停用这个源" : "启用这个源") {
                tv.setPlaylistEnabled(playlist.id, enabled: !playlist.isEnabled)
            }
            Divider()
            Button("删除这个源", role: .destructive) { tv.removePlaylist(playlist.id) }
        }
    }

    /// 源下面的二级分类：点进去只显示该分类的频道。
    func tvCategoryRow(_ category: TVCategory, playlistID: UUID) -> some View {
        SidebarCategoryRow(
            icon: "circle.fill",
            title: category.group,
            count: category.count,
            isActive: store.sidebarItem == .iptv
                && tv.focusedPlaylistID == playlistID
                && tv.groupFilter == category.group,
            helpText: "查看「\(category.group)」频道",
            leadingIndent: 30,
            iconSize: 5,
            action: { openTVGroup(category.group, in: playlistID) }
        )
    }

    func openTVGroup(_ group: String, in playlistID: UUID) {
        if !tv.enabled { tv.setEnabled(true) }
        tv.focusGroup(group, in: playlistID)
        tv.setHubTab(.channels)
        store.navigate(to: .iptv)
    }

    func openTV(_ playlistID: UUID) {
        // 电视源也走统一源入口：激活策略、会话与健康状态由 sourceHub 决定。
        store.sourceHub.activate(.television(playlistID))
    }

    func toggleSystemFolder(_ id: Int64) {
        withAnimation(settings.motion.layout) {
            if expandedSystemFolders.contains(id) {
                expandedSystemFolders.remove(id)
            } else {
                expandedSystemFolders.insert(id)
            }
        }
        systemExpansionRevision &+= 1
        persistExpansionState()
    }

    /// 侧边栏系统树的「拍平行」：只画这一行，子节点由拍平数组负责（惰性渲染）。
    @ViewBuilder
    func systemFlatRow(_ entry: SystemSidebarEntry, level: Int) -> some View {
        switch entry {
        case .folder(let folder):
            systemFolderRow(folder, level: level)
        case .album(let album):
            systemAlbumRow(album, level: level)
        }
    }

    /// 「固定」区里的文件夹：行 + 展开的子节点（数量很少，保留递归即可）。
    func systemFolderNode(_ folder: SystemFolderInfo, level: Int, scope: String = "system") -> AnyView {
        let isExpanded = expandedSystemFolders.contains(folder.id)
        let children = store.systemChildren(of: folder.id)
        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                systemFolderRow(folder, level: level, scope: scope)
                if isExpanded {
                    ForEach(children) { child in
                        systemNode(child, level: level + 1)
                    }
                }
            }
        )
    }

    func systemFolderRow(_ folder: SystemFolderInfo, level: Int, scope: String = "system") -> some View {
        let isExpanded = expandedSystemFolders.contains(folder.id)
        let hasChildren = !store.systemChildren(of: folder.id).isEmpty

        return HoverRowHighlight(active: store.sidebarItem == .systemFolder(folder.id)) {
            HStack(spacing: Self.folderChevronGap) {
                Button {
                    toggleSystemFolder(folder.id)
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
            .overlay {
                // 把相簿拖到这个文件夹上时给一个落点提示，松手即移动。
                if systemFolderDropTarget == folder.id {
                    RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay {
                            RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [systemSidebarDragType], isTargeted: Binding(
                get: { systemFolderDropTarget == folder.id },
                set: { targeted in
                    if targeted {
                        systemFolderDropTarget = folder.id
                    } else if systemFolderDropTarget == folder.id {
                        systemFolderDropTarget = nil
                    }
                }
            )) { providers in
                handleSystemAlbumDrop(providers, into: folder.id)
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
                if store.isNativeContainer {
                    // 官方图库先给出完整的管理入口；真正的写目标是「照片」当前库，
                    // 点击时再校验，失败会说明原因，避免菜单看起来像功能缺失。
                    Divider()
                    Button("在此文件夹中新建相簿…") {
                        store.namePrompt = .newSystemAlbum(folderID: folder.id)
                    }
                    Button("新建子文件夹…") {
                        store.namePrompt = .newSystemFolder(parentID: folder.id)
                    }
                    Divider()
                    Button("提取子目录相簿到当前文件夹") {
                        store.requestExtractSystemFolderAlbums(folder.id)
                    }
                    .help("把这个文件夹及其所有子目录里的相簿提取到这一层，子目录里的相簿会移到当前文件夹")
                    Button("重命名文件夹…") {
                        store.namePrompt = .renameSystemFolder(folder.id, current: folder.name)
                    }
                    Button("删除文件夹…", role: .destructive) {
                        store.presentDeleteSystemFolder(folder.id)
                    }
                    if store.systemWriteTargetState == .mismatch {
                        Divider()
                        Button("在「照片」中打开此图库…") {
                            store.openCurrentLibraryInPhotosForImport()
                        }
                        Button("重新检测写入目标") {
                            store.refreshSystemWriteTargetState(announce: true)
                        }
                        Button("重新启动拾光以启用编辑") {
                            store.relaunchForLibraryWrite()
                        }
                        .help("在「照片」里切换图库后，PhotoKit 需要重启拾光才会指向新库")
                    }
                }
            }
        }
    }

    /// 侧边栏相簿拖到文件夹：解析拖拽载荷里的相簿主键，经 PhotoKit 移到该文件夹。
    func handleSystemAlbumDrop(_ providers: [NSItemProvider], into folderID: Int64) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: systemSidebarDragType.identifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  let albumID = Int64(raw) else { return }
            Task { @MainActor in
                store.moveSystemAlbums([albumID], toFolder: folderID)
            }
        }
        return true
    }

    /// 系统相簿的拖拽载荷：只带相簿主键，类型独立于照片拖拽。
    func systemAlbumDragProvider(_ album: SystemAlbumInfo) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data("\(album.id)".utf8)
        provider.registerDataRepresentation(forTypeIdentifier: systemSidebarDragType.identifier,
                                            visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    /// 文件夹与相簿按图库原始顺序混排渲染。
    @ViewBuilder
    func systemNode(_ entry: SystemSidebarEntry, level: Int) -> some View {
        switch entry {
        case .folder(let folder):
            systemFolderNode(folder, level: level)
        case .album(let album):
            systemAlbumRow(album, level: level)
        }
    }

    func systemAlbumRow(_ album: SystemAlbumInfo, level: Int, scope: String = "system") -> some View {
        HoverRowHighlight(active: store.sidebarItem == .systemAlbum(album.id)) {
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
            }
            .buttonStyle(.plain)
            // 可写的原生图库才允许拖动：拖到侧边栏的文件夹上即移动过去。
            .modifier(SidebarAlbumDragModifier(enabled: store.canManageSystemAlbums) {
                systemAlbumDragProvider(album)
            })
            .contextMenu {
            Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
            Button(store.isPinned(.systemAlbum(album.id)) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.systemAlbum(album.id))
            }
            Button("拷贝到拾光") {
                store.importSystemAlbumToLibrary(album.id)
            }
            if store.isNativeContainer {
                Divider()
                Button("移动到文件夹…") {
                    store.presentMoveSystemAlbumsToFolder(album.id)
                }
                Button("重命名相簿…") {
                    store.namePrompt = .renameSystemAlbum(album.id, current: album.name)
                }
                Button("删除相簿", role: .destructive) {
                    store.deleteSystemAlbum(album.id)
                }
                if store.systemWriteTargetState == .mismatch {
                    Divider()
                    Button("在「照片」中打开此图库…") {
                        store.openCurrentLibraryInPhotosForImport()
                    }
                    Button("重新检测写入目标") {
                        store.refreshSystemWriteTargetState(announce: true)
                    }
                    Button("重新启动拾光以启用编辑") {
                        store.relaunchForLibraryWrite()
                    }
                    .help("在「照片」里切换图库后，PhotoKit 需要重启拾光才会指向新库")
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
}
