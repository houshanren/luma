import SwiftUI

/// 打开中的网盘的分类入口：与拾光图库侧边栏一致 ——
/// 媒体类型 / 更多项目 / 场景 / 相簿（文件夹即相簿）。
struct CloudMountDetailView: View {
    /// 所属网盘实例：影院页也归属于它，不依赖当前 sidebarItem。
    let mountID: UUID

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    /// 与图库一致：媒体类型与场景默认收起，更多项目与相簿默认展开。
    @State private var collapsed: Set<String> = ["media", "scenes"]
    @State private var hoveredSection: String?
    @State private var hoveredScope: String?
    @State private var expandedFolders: Set<String> = []
    @State private var hoveredFolder: String?
    @State private var hoveredAllAlbums = false
    @State private var hoveredCinema = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            cinemaRow
            sectionHeader("媒体类型", key: "media", topPadding: 8,
                          onTap: { openOverview(.mediaTypes) },
                          menu: {
                              if cloud.isScanningMetadata {
                                  Button("停止读取照片信息") { store.cancelCloudMetadataScan() }
                              } else if store.cloudMetadataPendingCount > 0 {
                                  Button("读取照片信息（EXIF）…") { store.scanCloudMetadata() }
                              }
                          })
            if !collapsed.contains("media") {
                mediaRows
                metadataStatusRow
            }

            sectionHeader("更多项目", key: "more", topPadding: 12,
                          onTap: { openOverview(.moreItems) })
            if !collapsed.contains("more") {
                moreItemRows
            }

            sectionHeader("场景", key: "scenes", topPadding: 12,
                          onTap: { openOverview(.scenes) },
                          menu: {
                              if cloud.isAnalyzing {
                                  Button("停止识别") { store.cancelCloudContentAnalysis() }
                              } else if store.cloudPendingAnalysisCount > 0 {
                                  Button("识别当前列表…") { store.analyzeCloudContent() }
                              }
                          })
            if !collapsed.contains("scenes") {
                sceneBody
            }

            sectionHeader("相簿", key: "albums", topPadding: 12,
                          onTap: { openOverview(.folders) },
                          menu: {
                              Button(store.isCloudScanning ? "停止扫描" : "重新扫描网盘") {
                                  if store.isCloudScanning {
                                      store.stopCloudAlbumScan()
                                  } else {
                                      store.beginCloudAlbumScan(mountID: mountID)
                                  }
                              }
                          })
            if !collapsed.contains("albums") {
                albumRows
            }
        }
        // 分类的收起状态按网盘分别保存，下次打开同一网盘时恢复。
        .onAppear {
            collapsed = SidebarStateStorage.stringSet(collapsedKey)
        }
        .onChange(of: collapsed) { _, value in
            SidebarStateStorage.save(collapsedKey, value)
        }
    }

    private var collapsedKey: String {
        SidebarStateStorage.Key.cloudDetailSections(mountID)
    }

    /// 是否正在浏览这个网盘的列表本身。
    /// 网盘的分段 / 相簿选中状态记在共享的浏览模型里，只有当前网盘才该亮；
    /// 否则进入影院后「全部项目」仍高亮，多个实例时每个展开的树还会重复亮同一行。
    private var isBrowsingThisMount: Bool {
        store.currentCloudMountID == mountID
    }

    /// 影院与「视频 / 相簿」是并列的两个入口：在影院里点任何一个列表入口，
    /// 都要真正切回这个网盘的列表，而不是只改状态、页面仍停在影院。
    private func leaveCinemaIfNeeded() {
        if store.sidebarItem == .cloudCinema(mountID) {
            store.navigate(to: .cloudMount(mountID))
        }
    }

    private func openOverview(_ section: CloudOverviewSection) {
        leaveCinemaIfNeeded()
        store.showCloudOverview(section)
    }

    // MARK: - 影院（归属这个网盘）

    private var cinemaRow: some View {
        let scope = CinemaScope.mount(mountID)
        let isActive = store.sidebarItem == .cloudCinema(mountID)
        let count = store.cinemaMatchedCount(for: scope)
        let scraping = store.cinemaScrapeRunning && store.cinemaScrapeScope == scope

        return Button {
            store.activateCinemaScope(scope)
            store.navigate(to: .cloudCinema(mountID))
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "film.stack")
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(LumaBrand.violet)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text("影院")
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if scraping {
                    Text("\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    ProgressView()
                        .controlSize(.mini)
                } else if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: isActive, hovered: hoveredCinema)
            }
        }
        .buttonStyle(.plain)
        .onHover { hoveredCinema = $0 }
        .help("这个网盘自己的电影与剧集：海报、刮削与播放入口")
        .contextMenu {
            Button("打开影院") {
                store.activateCinemaScope(scope)
                store.navigate(to: .cloudCinema(mountID))
            }
            Divider()
            Button("刮削新视频") {
                Task { await store.scrapeCinema(for: scope) }
            }
            Button("重新刮削全部") {
                Task { await store.scrapeCinema(for: scope, force: true) }
            }
            Button("清除刮削结果", role: .destructive) {
                store.clearCinemaIndex(for: scope)
            }
        }
    }

    // MARK: - 更多项目（与图库同一套条目与顺序）

    @ViewBuilder
    private var moreItemRows: some View {
        let counts = store.cloudScopeCounts
        scopeRow(.favorites, count: counts.favorites)
        if counts.duplicates > 0 {
            scopeRow(.duplicates, count: counts.duplicates)
        }
        if counts.text > 0 {
            scopeRow(.text, count: counts.text)
        }
        scopeRow(.keywords, count: counts.keywords.count)
        scopeRow(.revisit, count: counts.revisit)
        scopeRow(.health, count: counts.health)
        scopeRow(.map, count: counts.located)
        scopeRow(.places, count: counts.located)
        scopeRow(.people, count: counts.people)
    }

    /// EXIF 读取进度：网盘照片的拍摄时间、相机与 GPS 全部来自文件头部，不下载原图。
    @ViewBuilder
    private var metadataStatusRow: some View {
        if cloud.isScanningMetadata {
            HStack(spacing: 7) {
                ProgressView(value: cloud.metadataProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
                Text("读取信息 \(Int((cloud.metadataProgress * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else if store.cloudMetadataPendingCount > 0 {
            Button {
                store.scanCloudMetadata()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "camera.metering.center.weighted")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text("读取照片信息（剩余 \(store.cloudMetadataPendingCount) 张）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("从文件头部读取拍摄时间、相机、镜头与 GPS，用于地图、位置与值得重看")
        } else if store.cloudMetadataScannedCount > 0, store.cloudLocatedCount > 0 {
            Text("已读取 \(store.cloudMetadataScannedCount) 张的拍摄信息，其中 \(store.cloudLocatedCount) 张带位置")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        }
    }

    // MARK: - 媒体类型

    @ViewBuilder
    private var mediaRows: some View {
        let counts = store.cloudScopeCounts
        scopeRow(.all, count: counts.count(for: .all))
        scopeRow(.videos, count: counts.videos)
        scopeRow(.photos, count: counts.photos)
        if counts.screenshots > 0 {
            scopeRow(.screenshots, count: counts.screenshots)
        }
        if counts.animated > 0 {
            scopeRow(.animated, count: counts.animated)
        }
        if counts.raws > 0 {
            scopeRow(.raws, count: counts.raws)
        }
    }

    // MARK: - 场景（端侧识别）

    @ViewBuilder
    private var sceneBody: some View {
        if cloud.isAnalyzing {
            HStack(spacing: 7) {
                ProgressView(value: cloud.analysisProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
                Text("识别中 \(Int((cloud.analysisProgress * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else if cloud.analysis.isEmpty {
            Button {
                store.analyzeCloudContent()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "sparkles")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text("识别内容…")
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在本机识别当前网盘列表的场景与图内文字")
            Text("识别场景与图内文字，全部在本机完成，不会上传照片")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        } else {
            let counts = store.cloudScopeCounts
            let visible = SceneCatalog.categories.filter { (counts.scenes[$0.id] ?? 0) > 0 }
            if visible.isEmpty {
                Text("未识别到常见场景")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            } else {
                ForEach(visible) { category in
                    scopeRow(.scene(category.id), count: counts.scenes[category.id] ?? 0)
                }
            }
            let pending = store.cloudPendingAnalysisCount
            if pending > 0 {
                Button {
                    store.analyzeCloudContent()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("继续识别（剩余 \(pending) 张）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("每次最多识别 120 张，避免一次读取过多网盘文件")
            }
        }
    }

    // MARK: - 相簿（文件夹）

    @ViewBuilder
    private var albumRows: some View {
        let folders = store.cloudRootFolders
        allAlbumsRow
        if folders.isEmpty {
            if cloud.scanPhase.isScanning {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在扫描网盘目录…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            } else {
                Text("扫描完成后，网盘文件夹会作为相簿出现在这里")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
        } else {
            // 侧边栏可能有一千多个目录：用 LazyVStack，只为可见行创建封面与手势。
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(folders) { node in
                    folderNode(node, level: 0)
                }
            }
        }
    }

    /// 与图库「所有相簿」同一行：回到整个网盘。
    private var allAlbumsRow: some View {
        Button {
            leaveCinemaIfNeeded()
            store.showCloudOverview(nil)
            store.selectCloudFolder(path: nil)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text("所有相簿")
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                // 根目录的高亮由网盘行承担，这里只保留悬停反馈。
                LumaRowHighlight(active: false, hovered: hoveredAllAlbums)
            }
        }
        .buttonStyle(.plain)
        .onHover { hoveredAllAlbums = $0 }
        .help("回到整个网盘")
    }

    private func folderNode(_ node: CloudFolderNode, level: Int) -> AnyView {
        let isExpanded = expandedFolders.contains(node.path)
        let isSelected = isBrowsingThisMount
            && cloud.overview == nil
            && store.cloudSelectedFolderPath == node.path
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Button {
                    withAnimation(settings.motion.layout) {
                        if isExpanded {
                            expandedFolders.remove(node.path)
                        } else {
                            expandedFolders.insert(node.path)
                        }
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
                .opacity(node.children.isEmpty ? 0 : 1)
                .disabled(node.children.isEmpty)

                Button {
                    leaveCinemaIfNeeded()
                    store.showCloudOverview(nil)
                    store.selectCloudFolder(path: node.path)
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        folderCover(node)
                        Text(node.name)
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if node.photoCount > 0 {
                            Text(node.photoCount.formatted())
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 8 + CGFloat(level) * 14)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .background {
                LumaRowHighlight(active: isSelected, hovered: hoveredFolder == node.path)
            }
            .onHover { hovering in
                if hovering {
                    hoveredFolder = node.path
                } else if hoveredFolder == node.path {
                    hoveredFolder = nil
                }
            }
            .help(node.path)

            if isExpanded {
                ForEach(node.children) { child in
                    folderNode(child, level: level + 1)
                }
            }
        })
    }

    @ViewBuilder
    private func folderCover(_ node: CloudFolderNode) -> some View {
        if let cover = node.cover {
            PhotoThumbnailView(photo: cover, purpose: .cover(20))
                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                            style: .continuous))
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                .background(Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                 style: .continuous))
        }
    }

    // MARK: - 分区头与行

    private func sectionHeader<MenuContent: View>(
        _ title: String,
        key: String,
        topPadding: CGFloat = 12,
        onTap: (() -> Void)? = nil,
        @ViewBuilder menu: () -> MenuContent = { EmptyView() }
    ) -> some View {
        let isCollapsed = collapsed.contains(key)
        let hovering = hoveredSection == key

        return HStack(spacing: 2) {
            if let onTap {
                Button(action: onTap) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开\(title)总览")
            } else {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hovering {
                Menu {
                    Button(isCollapsed ? "展开" : "收起") { toggle(key) }
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
            if hovering || isCollapsed {
                Button {
                    toggle(key)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "展开" : "收起")
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

    private func toggle(_ key: String) {
        withAnimation(settings.motion.layout) {
            if collapsed.contains(key) {
                collapsed.remove(key)
            } else {
                collapsed.insert(key)
            }
        }
    }

    private func scopeRow(_ scope: CloudScope, count: Int) -> some View {
        // 「全部项目」是网盘默认范围，高亮由网盘行承担；选中相簿时高亮留给相簿行，
        // 保证同一时刻只亮一行。
        let selected = scope != .all
            && isBrowsingThisMount
            && cloud.overview == nil
            && store.cloudSelectedFolderPath == nil
            && cloud.scope == scope
        return Button {
            leaveCinemaIfNeeded()
            store.setCloudScope(scope)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: scope.icon)
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(scope == .favorites ? Color.pink : Color.accentColor)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text(scope.title)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: selected, hovered: hoveredScope == scope.key)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredScope = scope.key
            } else if hoveredScope == scope.key {
                hoveredScope = nil
            }
        }
        .help(scope.title)
        .accessibilityLabel(scope.title)
    }
}
