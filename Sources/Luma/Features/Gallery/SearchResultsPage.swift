import SwiftUI
import AppKit

/// 全局搜索结果页：只负责「标题 + 数据绑定 + 点击动作」，
/// 检索调度与结果面板都在独立搜索模块里（SearchCenter / SearchScopeBar / SearchContent）。
struct SearchResultsPage<PhotoContent: View>: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CatalogBrowserModel.self) private var catalog
    @Environment(AppSettings.self) private var settings

    let query: String
    @ViewBuilder var photoContent: () -> PhotoContent

    /// 模块关闭后，来源胶囊与结果一起消失，跨模块兜底入口也不再出现。
    /// 开关随当前图库保存，切换图库时一起变化。
    private var catalogModule: Bool { settings.moduleCatalog }
    private var cinemaModule: Bool { settings.moduleCinema }
    private var televisionModule: Bool { settings.moduleTelevision }

    @StateObject private var center: SearchCenter
    /// 从详情页「返回搜索」带回来的筛选：等本轮检索排完再套上去，
    /// 否则会被 `setQuery` 的清筛选逻辑覆盖掉。
    @State private var restoredFilters: SearchReturnSnapshot?

    init(query: String,
         store: LibraryStore,
         catalog: CatalogBrowserModel,
         tv: IPTVBrowserModel,
         scopes requestedScopes: [SearchSourceKind]? = nil,
         @ViewBuilder photoContent: @escaping () -> PhotoContent) {
        self.query = query
        self.photoContent = photoContent
        // 模块内搜索只调度这个模块自己的来源；传 nil 才走全量统一搜索。
        // 关闭的模块不参与搜索，连来源胶囊都不显示。
        // 检索本身登记成后台任务：底部任务条能看到进度，结束后进「任务记录」并可一键重搜。
        let scopes = (requestedScopes ?? AppModules.enabledSearchScopes)
            .filter { AppModules.isEnabled($0) }
        let providers = SearchProviders.makeAll(store: store, catalog: catalog, tv: tv)
        // 会话复用：点进结果看完退回来时沿用同一份结果，不再整轮重搜。
        _center = StateObject(wrappedValue: SearchSessionStore.shared.center(for: query, scopes: scopes) {
            SearchCenter(scopes: scopes, providers: providers, store: store)
        })
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            SearchScopeBar(center: center)
            SearchContent(center: center,
                          photoGrid: photoContent,
                          onOpen: open,
                          emptyView: AnyView(emptyState))
                .environment(store)
                .environment(catalog)
        }
        .task(id: query) {
            center.setQuery(query)
            applyRestoredFilters()
        }
        .onAppear {
            applyPendingScope()
            takePendingRestore()
        }
        .onChange(of: store.pendingSearchScope) { _, _ in applyPendingScope() }
        .onChange(of: store.pendingSearchRestore) { _, _ in
            takePendingRestore()
            applyRestoredFilters()
        }
        // 离开搜索页不取消检索：点进结果可以看到完整结果，回来直接复用，不重搜。
        // 真正不再需要的会话由 SearchSessionStore 在淘汰或清除时收尾。
    }

    /// 模块内搜索只预选来源，其余筛选 / 展示仍由统一搜索组件负责。
    /// 这里不清空 `store.pendingSearchScope`：结果页重建时仍要按同一个来源初始化。
    private func applyPendingScope() {
        guard let scope = store.pendingSearchScope else { return }
        center.setActiveSource(scope)
    }

    /// 从详情页「返回搜索」回来：把当时选的来源 / 类型 / 源 / 分类一起恢复。
    private func takePendingRestore() {
        guard let restore = store.pendingSearchRestore else { return }
        store.pendingSearchRestore = nil
        restoredFilters = restore
    }

    private func applyRestoredFilters() {
        guard let restore = restoredFilters else { return }
        // 只恢复一次：否则之后每次改关键词都会把上一轮的来源 / 类型 / 源 / 分类再套一遍，
        // 新结果被旧筛选条件清空。
        restoredFilters = nil
        center.activeSource = restore.source
        center.activeKind = restore.kind
        center.activeOrigin = restore.origin
        center.activeCategory = restore.category
    }

    // MARK: - 顶部

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(store.searchScope == .global ? "全局搜索" : "模块搜索")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(.secondary)
                    Text(center.scopes.map(\.title).joined(separator: " · "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Text("「\(trimmedQuery)」")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text("共 \(center.totalCount.formatted()) 项")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if center.isSearching || catalog.isGlobalSearching {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("正在联网检索…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                // 结果布局切换：列表 / 格子 / 画廊，偏好记住，下次搜索沿用。
                SearchLayoutPicker()
                Button {
                    store.searchText = ""
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("清除")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(.quaternary, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("清除搜索（Esc）")
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottom)
                RadialGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                               center: .topTrailing, startRadius: 4, endRadius: 320)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
        }
    }

    // MARK: - 点击路由

    /// 全部来源都没有命中：保留跨模块兜底入口。
    private var emptyState: some View {
        var actions: [LumaEmptyAction] = []
        // 模块内搜索只属于这个模块：不再给出跨模块搜索入口，避免把别的域的内容带进来。
        if store.searchScope == .global {
            actions.append(LumaEmptyAction(title: "在影院搜", symbol: nil) {
                store.cinemaSearchSeed = trimmedQuery
                store.cinemaSearchVisible = true
                store.navigate(to: .cinema)
            })
            if catalogModule {
                actions.append(LumaEmptyAction(title: "在网络资源搜", symbol: nil) {
                    catalog.globalQuery = trimmedQuery
                    store.navigate(to: .catalogSources)
                })
            }
            if cinemaModule {
                actions.append(LumaEmptyAction(title: "在网络影院搜", symbol: nil) {
                    store.networkCinemaSearchSeed = trimmedQuery
                    store.navigate(to: .networkCinema)
                })
            }
            if televisionModule {
                actions.append(LumaEmptyAction(title: "在网络电视搜", symbol: nil) {
                    tvModel.searchText = trimmedQuery
                    store.navigate(to: .iptv)
                })
            }
        }
        return LumaEmptyState(symbol: "magnifyingglass",
                              title: "没有找到「\(trimmedQuery)」",
                              message: "可以换个更短的关键词，或直接到各个模块里搜索。",
                              actions: actions)
    }

    private func open(_ hit: SearchHit) {
        // 照片在当前图库就地打开查看器：关掉查看器仍停在搜索页，不需要返回入口；
        // 其它命中会离开搜索页，先记下搜索现场，详情页顶栏据此一步回到搜索结果。
        if !opensInPlace(hit) {
            rememberSearch(landing: landingItem(for: hit.payload))
        }
        // 跨图库命中：先切 / 连到它所属的图库，等内容就绪后再打开条目。
        if let path = hit.libraryPath, !isCurrentLibrary(path),
           let pending = Self.pendingOpen(for: hit.payload) {
            store.openSearchResultInLibrary(path: path, pending: pending)
            return
        }
        // 打开路由放在 Store 里：助手与结果页共用同一套跳转。
        store.openSearchHit(hit)
    }

    private var tvModel: IPTVBrowserModel { store.tvModel }

    /// 记下搜索现场。
    private func rememberSearch(landing: SidebarItem?) {
        store.beginSearchReturn(SearchReturnSnapshot(
            query: trimmedQuery,
            scope: store.searchScope,
            source: center.activeSource,
            kind: center.activeKind,
            origin: center.activeOrigin,
            category: center.activeCategory,
            originItem: store.sidebarItem,
            landingItem: landing))
    }

    /// 在搜索页即可完成、不需要离开页面的命中。
    private func opensInPlace(_ hit: SearchHit) -> Bool {
        guard case .photo = hit.payload else { return false }
        if let path = hit.libraryPath, !isCurrentLibrary(path) { return false }
        return true
    }

    /// 命中跳转后停留的页面：顶栏「返回搜索」只在这个页面上出现。
    /// 影院控制台自带详情层级，返回入口另有一套，这里不留搜索返回。
    private func landingItem(for payload: SearchPayload) -> SidebarItem? {
        switch payload {
        case .photo: return nil
        case .localAlbum(let id): return .album(id)
        case .localFolder(let id): return .folder(id)
        case .systemAlbum(let id): return .systemAlbum(id)
        case .systemFolder(let id): return .systemFolder(id)
        case .localPerson: return .people
        case .systemPerson: return .systemPeople
        case .place: return store.isSystemScope ? .systemPlaces : .places
        case .scene(let id): return store.isSystemScope ? .systemScene(id) : .scene(id)
        case .cloudFile(let mountID, _, _), .cloudFolder(let mountID, _): return .cloudMount(mountID)
        case .cinema: return nil
        case .channel, .program: return .iptv
        case .catalogItem(let sourceID, _): return .catalogSource(sourceID)
        case .networkCinemaItem: return .networkCinema
        }
    }

    /// 命中所在图库是否就是当前浏览的图库。
    private func isCurrentLibrary(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let container = LibraryPaths.containerLibraryURL?.standardizedFileURL.path,
           container == standardized { return true }
        if let active = store.systemLibraryPath.map({
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }), active == standardized { return true }
        return false
    }

    /// 搜索结果负载 → 切库后要打开的目标。
    private static func pendingOpen(for payload: SearchPayload) -> LibraryPendingOpen? {
        switch payload {
        case .photo(let id): return .photo(id)
        case .localAlbum(let id): return .album(id)
        case .localFolder(let id): return .folder(id)
        case .localPerson(let id): return .person(id)
        case .systemAlbum(let id): return .systemAlbum(id)
        case .systemFolder(let id): return .systemFolder(id)
        case .systemPerson(let person): return .systemPerson(person)
        default: return nil
        }
    }
}
