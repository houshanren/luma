import SwiftUI
import LumaContentCore

extension SearchSourceKind {
    var tint: Color {
        switch self {
        case .library: return Color(red: 0.36, green: 0.62, blue: 1.00)
        case .cloud: return Color(red: 0.30, green: 0.78, blue: 0.76)
        case .cinema: return Color(red: 0.98, green: 0.67, blue: 0.30)
        case .networkCinema: return Color(red: 0.96, green: 0.45, blue: 0.58)
        case .television: return Color(red: 0.36, green: 0.85, blue: 0.96)
        case .catalog: return Color(red: 0.72, green: 0.55, blue: 0.98)
        }
    }
}

// MARK: - 布局

/// 搜索结果的展示布局：紧凑列表 / 封面格子 / 大图画廊。
/// 偏好持久化在 UserDefaults，全部来源与单来源两套视图共用同一选择。
enum SearchResultLayout: String, CaseIterable, Identifiable {
    case list
    case grid
    case gallery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表"
        case .grid: return "格子"
        case .gallery: return "画廊"
        }
    }

    var symbol: String {
        switch self {
        case .list: return "line.3.horizontal"
        case .grid: return "square.grid.2x2"
        case .gallery: return "rectangle.grid.1x2"
        }
    }

    var help: String {
        switch self {
        case .list: return "紧凑列表：每行一条，信息密度最高"
        case .grid: return "封面格子：缩略图铺开的卡片墙"
        case .gallery: return "大图画廊：封面大图 + 底部渐变标题"
        }
    }
}

/// 布局切换器：三枚图标按钮收进一个胶囊分段控件，跟在搜索结果标题旁。
/// 当前项高亮主题色；切换带短动画，结果区随之重排。
struct SearchLayoutPicker: View {
    @AppStorage(SettingsKeys.searchResultsLayout) private var raw = SearchResultLayout.gallery.rawValue

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SearchResultLayout.allCases) { layout in
                let active = layout.rawValue == raw
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        raw = layout.rawValue
                    }
                } label: {
                    Image(systemName: layout.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 26, height: 22)
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .background {
                            Capsule(style: .continuous)
                                .fill(active ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(Color.clear))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layout.help)
            }
        }
        .padding(2.5)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }
}

// MARK: - 来源胶囊

/// 来源切换条：只展示 `center.scopes` 里配置过的来源。
/// 全局搜索传全部来源；模块内搜索只传自己需要的来源，出现的就是单个 / 少量胶囊。
struct SearchScopeBar: View {
    @ObservedObject var center: SearchCenter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if center.scopes.count > 1 {
                    chip(title: "全部",
                         icon: "sparkle.magnifyingglass",
                         count: center.totalCount,
                         tint: Color.accentColor,
                         active: center.activeSource == nil,
                         loading: center.isSearching) {
                        withAnimation(.snappy(duration: 0.18)) {
                            center.setActiveSource(nil)
                        }
                    }
                }
                ForEach(center.scopes) { source in
                    chip(title: source.title,
                         icon: source.icon,
                         count: center.count(for: source),
                         tint: source.tint,
                         active: center.activeSource == source,
                         loading: center.searchingSources.contains(source)) {
                        withAnimation(.snappy(duration: 0.18)) {
                            center.setActiveSource(source)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
        }
    }

    private func chip(title: String, icon: String, count: Int, tint: Color,
                      active: Bool, loading: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(active ? Color.white : tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                if loading {
                    // 正在检索这个来源：给一个小转圈，比一直显示旧计数更直观。
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else if count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(active ? Color.white.opacity(0.82) : Color.secondary)
                }
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? AnyShapeStyle(tint)
                                 : AnyShapeStyle(Color.primary.opacity(0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : Color.primary.opacity(0.07),
                                  lineWidth: 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("只看\(title)")
    }
}

// MARK: - 结果面板

/// 搜索结果面板：既服务「全部来源」的聚合视图，也服务单个来源的完整列表。
/// 图库照片支持注入宿主自己的网格（分页、选择、查看器都沿用原实现）。
struct SearchContent<PhotoGrid: View>: View {
    @ObservedObject var center: SearchCenter
    @ViewBuilder var photoGrid: () -> PhotoGrid
    let onOpen: (SearchHit) -> Void
    /// 全部来源都为空时展示的提示（宿主可自定义）。
    var emptyView: AnyView? = nil

    /// 结果布局与顶部的切换器共用同一个 UserDefaults 键：改一处，两处同步。
    /// 默认「画廊」：搜索结果以封面大图为主，比紧凑列表更容易一眼认出内容。
    @AppStorage(SettingsKeys.searchResultsLayout) private var layoutRaw = SearchResultLayout.gallery.rawValue

    private var layout: SearchResultLayout {
        SearchResultLayout(rawValue: layoutRaw) ?? .gallery
    }

    var body: some View {
        if let source = center.activeSource {
            sourceContent(source)
        } else {
            allContent
        }
    }

    // MARK: 全部来源

    private var allContent: some View {
        ScrollView {
            // 外层必须用普通 VStack：格子 / 画廊布局时分区行里是 LazyVGrid 或
            // 横向 LazyHStack，Lazy 容器直接套 Lazy 容器会让后续增量更新丢失
            // （首个分区之后的 sections / searchingSources 发布全部不再落地，
            // 表现为检索完成后「全部」一直停在第一个分区的快照）。
            // 全部页最多 7 个分区 × 8 条预览，普通 VStack 没有性能压力。
            VStack(alignment: .leading, spacing: 26) {
                if center.sections.isEmpty {
                    if center.isSearching {
                        loadingHint("正在检索各来源…")
                    } else {
                        emptyView ?? AnyView(defaultEmpty)
                    }
                } else {
                    ForEach(center.sections) { section in
                        sectionPreview(section)
                    }
                    ForEach(center.scopes.filter { center.searchingSources.contains($0) }) { source in
                        loadingHint("正在检索\(source.title)…")
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 44)
        }
    }

    private func sectionPreview(_ section: SearchSection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SearchSectionHeader(source: section.source,
                                count: section.total,
                                kindSummary: section.orderedKinds.compactMap { kind in
                                    let count = section.kindCounts[kind] ?? 0
                                    return count > 0 ? (kind.title, count) : nil
                                },
                                showsMore: true) {
                withAnimation(.snappy(duration: 0.18)) {
                    center.setActiveSource(section.source)
                }
            }
            if section.hits.isEmpty {
                Text("没有匹配的\(section.source.title)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                // 全部来源页的画廊布局用横向滚动条：像内容中心的轨道一样一条条铺开，
                // 每个来源一排，右侧自然引向「查看全部」。
                hitCollection(previewHits(section), horizontalGallery: true)
            }
        }
    }

    /// 「全部来源」里的预览条数：每种类型先各取一条，再补到上限。
    /// 电视频道动辄几十条，直接取前几条会把排在后面的节目单整个挤掉；
    /// 相簿 / 人物 / 场景也有同样问题。
    private func previewHits(_ section: SearchSection, limit: Int = 8) -> [SearchHit] {
        guard section.hits.count > limit else { return section.hits }
        var picked: [SearchHit] = []
        var used = Set<String>()
        for kind in section.orderedKinds {
            guard let hit = section.hits.first(where: { $0.kind == kind }),
                  used.insert(hit.id).inserted else { continue }
            picked.append(hit)
        }
        if picked.count > limit {
            picked = Array(picked.prefix(limit))
        }
        for hit in section.hits where picked.count < limit {
            guard used.insert(hit.id).inserted else { continue }
            picked.append(hit)
        }
        return picked
    }

    /// 一组命中按当前布局渲染：列表 → 行；格子 → 自适应封面卡；
    /// 画廊 → 大图卡（默认纵向网格，`horizontalGallery` 时改横向滚动轨道）。
    @ViewBuilder
    private func hitCollection(_ hits: [SearchHit], horizontalGallery: Bool = false) -> some View {
        switch layout {
        case .list:
            ForEach(hits) { hit in
                SearchHitRow(hit: hit, onOpen: onOpen)
            }

        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(hits) { hit in
                    SearchHitCard(hit: hit, style: .compact, onOpen: onOpen)
                }
            }

        case .gallery:
            if horizontalGallery {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(hits) { hit in
                            SearchHitCard(hit: hit, style: .feature, onOpen: onOpen)
                                .frame(width: 236)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(hits) { hit in
                        SearchHitCard(hit: hit, style: .feature, onOpen: onOpen)
                    }
                }
            }
        }
    }

    // MARK: 单个来源

    @ViewBuilder
    private func sourceContent(_ source: SearchSourceKind) -> some View {
        let section = center.section(for: source)
        VStack(spacing: 0) {
            if let section {
                if source == .library {
                    // 图库固定露出 图片 / 视频 / 相簿 / 文件夹 / 人物 / 场景 / 位置：
                    // 某一类这次没有命中也要显示 0，用户才知道该去哪个类型看结果。
                    libraryKindBar(section)
                } else if source == .television {
                    // 电视固定露出「直播 / 节目」两个 tab：没有节目也保留入口，
                    // 用户能明确知道节目单也在搜，而不是只有频道列表。
                    televisionKindBar(section)
                } else if section.orderedKinds.count > 1 {
                    kindBar(section)
                }
                // 电视 / 资源 / 影院 / 网盘：先按「源」筛，再按源下面的「分类」筛。
                originBar(section)
                categoryBar(section)
            }
            if source == .library, let section,
               showsLibraryGrid(section) {
                photoGrid()
            } else {
                ScrollView {
                    // 同 allContent：行内 hitCollection 在格子 / 画廊布局下是
                    // LazyVGrid / LazyHStack，外层再用 LazyVStack 会丢更新，
                    // 切换类型 / 源 / 分类筛选后列表可能不再刷新。
                    // 单来源命中上限是 limit（40 条），普通 VStack 足够。
                    VStack(alignment: .leading, spacing: 8) {
                        if let section {
                            let hits = filteredHits(section)
                            if hits.isEmpty {
                                emptyHint(center.activeKind.map { "没有匹配的\($0.title)" }
                                          ?? "没有匹配的\(source.title)")
                            } else {
                                hitCollection(hits)
                            }
                        } else if center.searchingSources.contains(source) {
                            loadingHint("正在检索\(source.title)…")
                        } else {
                            emptyHint("没有匹配的\(source.title)")
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                    .padding(.bottom, 44)
                }
            }
        }
    }

    private var isShowingPhotos: Bool {
        center.activeKind == nil || center.activeKind == .photo
    }

    /// 只有当前图库的命中才用宿主的照片墙：一旦有其它图库的照片 / 视频，
    /// 改走结果行，跨库内容才不会因为网格只覆盖当前库而消失。
    private func isShowingLibraryGrid(_ section: SearchSection) -> Bool {
        !section.hits.contains {
            $0.isOtherLibrary && ($0.kind == .photo || $0.kind == .video)
        }
    }

    /// 图库「全部」只有命中全是图片 / 视频时才用宿主的照片墙；
    /// 一旦还有场景 / 地点 / 人物 / 相簿 / 文件夹，照片墙只会显示图片视频，
    /// 把这几类结果整个吞掉（界面看上去「一条都没有」），改用结果行全部列出。
    private func showsLibraryGrid(_ section: SearchSection) -> Bool {
        guard isShowingPhotos, isShowingLibraryGrid(section) else { return false }
        if center.activeKind == .photo || center.activeKind == .video { return true }
        return section.kindCounts.allSatisfy {
            $0.value == 0 || $0.key == .photo || $0.key == .video
        }
    }

    private func filteredHits(_ section: SearchSection) -> [SearchHit] {
        var hits = section.hits
        // 会话恢复 / 换库后可能还带着上一轮的「源」「分类」筛选。
        // 当前结果里已经没有这个值时就忽略，否则整类结果会被一个不存在的条件清空
        // （胶囊上有计数，列表却是空的）。
        if let origin = center.activeOrigin,
           section.origins.contains(where: { $0.title == origin }) {
            hits = hits.filter { $0.origin == origin }
        }
        if let category = center.activeCategory,
           section.categories(under: center.activeOrigin).contains(where: { $0.title == category }) {
            hits = hits.filter { $0.category == category }
        }
        guard let kind = center.activeKind else { return hits }
        if kind == .photo, section.source == .library, isShowingLibraryGrid(section) {
            // 图片与视频由宿主的网格展示，这里不再重复列行。
            return hits.filter { $0.kind != .photo && $0.kind != .video }
        }
        return hits.filter { $0.kind == kind }
    }

    /// 「源」筛选：网盘 / 影院范围 / 电视播放列表 / 资源站点，只有多于一个源时出现。
    @ViewBuilder
    private func originBar(_ section: SearchSection) -> some View {
        let origins = section.origins
        if origins.count > 1 {
            filterStrip(title: "源",
                        options: origins,
                        active: center.activeOrigin,
                        tint: section.source.tint,
                        allLabel: "全部源",
                        allCount: nil) { origin in
                center.activeOrigin = origin
                // 换源后原来的分类多半已经不存在，直接回到全部分类。
                center.activeCategory = nil
            }
        }
    }

    /// 「分类」筛选：电视频道分组、资源分类、网盘目录等。
    @ViewBuilder
    private func categoryBar(_ section: SearchSection) -> some View {
        let categories = section.categories(under: center.activeOrigin)
        if categories.count > 1 {
            filterStrip(title: "分类",
                        options: categories,
                        active: center.activeCategory,
                        tint: section.source.tint,
                        allLabel: "全部分类",
                        allCount: nil) { category in
                center.activeCategory = category
            }
        }
    }

    private func filterStrip(title: String,
                             options: [(title: String, count: Int)],
                             active: String?,
                             tint: Color,
                             allLabel: String,
                             allCount: Int?,
                             action: @escaping (String?) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.tertiary)
                kindChip(allLabel,
                         count: allCount ?? options.reduce(0) { $0 + $1.count },
                         active: active == nil,
                         tint: tint) {
                    withAnimation(.snappy(duration: 0.18)) { action(nil) }
                }
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    kindChip(option.title,
                             count: option.count,
                             active: active == option.title,
                             tint: tint) {
                        withAnimation(.snappy(duration: 0.18)) { action(option.title) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 9)
        }
    }

    /// 图库的固定类型条：即使某一类本次没有命中，也保留入口与 0 计数。
    private var libraryKinds: [SearchHitKind] {
        [.photo, .video, .album, .folder, .person, .scene, .place]
    }

    private func libraryKindBar(_ section: SearchSection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kindChip("全部", count: section.total, active: center.activeKind == nil,
                         tint: section.source.tint) {
                    withAnimation(.snappy(duration: 0.18)) { center.activeKind = nil }
                }
                ForEach(libraryKinds, id: \.self) { kind in
                    kindChip(kind.title,
                             count: section.kindCounts[kind] ?? 0,
                             active: center.activeKind == kind,
                             tint: section.source.tint) {
                        withAnimation(.snappy(duration: 0.18)) { center.activeKind = kind }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
    }

    /// 电视的固定类型条：直播 / 节目两个 tab 始终在场，节目为 0 也保留入口。
    private var televisionKinds: [SearchHitKind] {
        [.channel, .program]
    }

    private func televisionKindBar(_ section: SearchSection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kindChip("全部", count: section.total, active: center.activeKind == nil,
                         tint: section.source.tint) {
                    withAnimation(.snappy(duration: 0.18)) { center.activeKind = nil }
                }
                ForEach(televisionKinds, id: \.self) { kind in
                    kindChip(kind.title,
                             count: section.kindCounts[kind] ?? 0,
                             active: center.activeKind == kind,
                             tint: section.source.tint) {
                        withAnimation(.snappy(duration: 0.18)) { center.activeKind = kind }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
    }

    private func kindBar(_ section: SearchSection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kindChip("全部", count: section.total, active: center.activeKind == nil,
                         tint: section.source.tint) {
                    withAnimation(.snappy(duration: 0.18)) { center.activeKind = nil }
                }
                ForEach(section.orderedKinds, id: \.self) { kind in
                    kindChip(kind.title,
                             count: section.kindCounts[kind] ?? 0,
                             active: center.activeKind == kind,
                             tint: section.source.tint) {
                        withAnimation(.snappy(duration: 0.18)) { center.activeKind = kind }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
    }

    private func kindChip(_ title: String, count: Int, active: Bool, tint: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                Text(count.formatted())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(active ? tint : Color.secondary)
            }
            .foregroundStyle(active ? tint : Color.primary.opacity(0.72))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? tint.opacity(0.14) : Color.primary.opacity(0.045))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.45) : Color.primary.opacity(0.07),
                                  lineWidth: 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 通用提示

    private func loadingHint(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
    }

    private var defaultEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有找到「\(center.query)」")
                .font(.system(size: 13, weight: .semibold))
            Text("换个更短的关键词再试一次。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - 分区标题

struct SearchSectionHeader: View {
    let source: SearchSourceKind
    let count: Int
    /// 各类型的命中数：全部来源页用它把「节目 / 相簿」等被预览挤掉的类型也说清楚。
    var kindSummary: [(title: String, count: Int)] = []
    var showsMore: Bool = false
    var onMore: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(source.tint.opacity(0.15))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: source.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(source.tint)
                }
            Text(source.title)
                .font(.system(size: 14, weight: .semibold))
            Text(count.formatted())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            if kindSummary.count > 1 {
                Text(kindSummary.prefix(5)
                    .map { "\($0.title) \($0.count)" }
                    .joined(separator: " · "))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if showsMore, let onMore {
                Button(action: onMore) {
                    HStack(spacing: 3) {
                        Text("查看全部")
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(source.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 命中行

struct SearchHitRow: View {
    @Environment(CatalogBrowserModel.self) private var catalog

    let hit: SearchHit
    let onOpen: (SearchHit) -> Void

    var body: some View {
        HStack(spacing: 11) {
            visual
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if !hit.subtitle.isEmpty {
                    Text(hit.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let badge = hit.badge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hit.source.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(hit.source.tint.opacity(0.12), in: Capsule(style: .continuous))
            }
            Image(systemName: trailingSymbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hit.source.tint)
                .frame(width: 22, height: 22)
                .background(hit.source.tint.opacity(0.12), in: Circle())
        }
        .searchRowChrome()
        .onTapGesture { onOpen(hit) }
        // 右键可直接收藏，不必先打开详情页。
        .searchHitFavoriteMenu(hit)
        .help(hit.title)
    }

    private var trailingSymbol: String {
        switch hit.kind {
        case .movie, .series, .channel, .program: return "play.fill"
        default: return "chevron.right"
        }
    }

    @ViewBuilder
    private var visual: some View {
        switch hit.visual {
        case .photo(let photo):
            PhotoThumbnailView(photo: photo, purpose: .cover(64))
                .frame(width: 50, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                }
        case .albumCover(let photo, let style):
            AlbumCoverImage(photo: photo, side: 120, style: style)
                .frame(width: 46, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .avatar(let data, let isPet):
            ZStack {
                Circle().fill(hit.source.tint.opacity(0.18))
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: isPet ? "pawprint.fill" : "person.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(hit.source.tint)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
        case .place:
            iconPlate("mappin.and.ellipse")
        case .scene:
            iconPlate("sparkles")
        case .cloudFile(let isVideo):
            iconPlate(isVideo ? "video.fill" : "photo.fill")
        case .cloudFolder:
            iconPlate("folder.fill")
        case .cinemaPoster(let url, let kind):
            CinemaSearchPoster(urlString: url, kind: kind)
        case .channelLogo(let url):
            TVLogoImage(urlString: url,
                        size: CGSize(width: 52, height: 30),
                        cornerRadius: 7)
                .background(Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .catalogCover(let sourceID, let url):
            if let source = catalog.sources.first(where: { $0.id == sourceID }) {
                CatalogArtworkImage(source: source,
                                    urlString: url,
                                    cornerRadius: 7,
                                    quality: .thumbnail)
                    .frame(width: 42, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                iconPlate("safari.fill")
            }
        }
    }

    private func iconPlate(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(hit.source.tint.opacity(0.13))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hit.source.tint)
            }
    }
}

// MARK: - 命中卡片

/// 格子 / 画廊布局的命中卡片。
/// `compact`：封面在上、标题在下的紧凑格子；
/// `feature`：封面大图铺满 + 底部渐变字幕，悬停浮出播放按钮。
struct SearchHitCard: View {
    @Environment(CatalogBrowserModel.self) private var catalog

    enum Style {
        case compact
        case feature

        var visualHeight: CGFloat {
            self == .compact ? 86 : 132
        }

        /// 封面解码的目标像素：按显示尺寸取图，画廊卡给更大一档。
        var imageSide: CGFloat {
            self == .compact ? 180 : 340
        }
    }

    let hit: SearchHit
    let style: Style
    let onOpen: (SearchHit) -> Void

    @State private var hovering = false

    private var cornerRadius: CGFloat {
        style == .compact ? 13 : 14
    }

    var body: some View {
        Group {
            if style == .compact { compactBody } else { featureBody }
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture { onOpen(hit) }
        .onHover { hovering = $0 }
        .searchHitFavoriteMenu(hit)
        .help(hit.title)
    }

    // MARK: 紧凑格子

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchCardVisual(visual: hit.visual,
                             tint: hit.source.tint,
                             side: style.imageSide,
                             height: style.visualHeight)
                .frame(height: style.visualHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let badge = hit.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.45), in: Capsule(style: .continuous))
                            .padding(5)
                    }
                }
                .overlay {
                    Image(systemName: playSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .opacity(hovering && isPlayable ? 1 : 0)
                        .scaleEffect(hovering && isPlayable ? 1 : 0.6)
                }

            VStack(alignment: .leading, spacing: 1.5) {
                Text(hit.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                if !hit.subtitle.isEmpty {
                    Text(hit.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 1)
        }
        .padding(7)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.075 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hovering ? hit.source.tint.opacity(0.45)
                                       : Color.primary.opacity(0.06),
                              lineWidth: hovering ? 1 : 0.6)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: hovering)
    }

    // MARK: 画廊大卡

    private var featureBody: some View {
        ZStack(alignment: .bottom) {
            SearchCardVisual(visual: hit.visual,
                             tint: hit.source.tint,
                             side: style.imageSide,
                             height: style.visualHeight)
                .frame(height: style.visualHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // 底部字幕：深色渐变压住封面，白字在任何封面上都可读。
            LinearGradient(colors: [.clear, .black.opacity(0.24), .black.opacity(0.78)],
                           startPoint: .center, endPoint: .bottom)
                .frame(height: style.visualHeight * 0.62)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !hit.subtitle.isEmpty {
                        Text(hit.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: trailingSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .padding(11)
        }
        .overlay(alignment: .topLeading) {
            // 画廊卡左上角挂来源徽标：大图上没有它就分不清是哪个模块的命中。
            HStack(spacing: 4) {
                Image(systemName: hit.source.icon)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(hit.source.title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.38), in: Capsule(style: .continuous))
            .padding(9)
        }
        .overlay {
            if isPlayable {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .opacity(hovering ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hovering ? hit.source.tint.opacity(0.55)
                                       : Color.primary.opacity(0.08),
                              lineWidth: hovering ? 1.2 : 0.7)
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: hovering)
    }

    private var isPlayable: Bool {
        switch hit.kind {
        case .movie, .series, .channel, .program, .video, .cloudVideo, .catalogItem:
            return true
        default:
            return false
        }
    }

    private var playSymbol: String { "play.fill" }

    private var trailingSymbol: String {
        isPlayable ? "play.fill" : "chevron.right"
    }
}

// MARK: - 卡片封面

/// 卡片封面：铺满给定的封面区。
/// 图片类按卡面尺寸取图；图标类换成来源色大图标色板，保证格子整体不花。
struct SearchCardVisual: View {
    @Environment(CatalogBrowserModel.self) private var catalog

    let visual: SearchVisual
    let tint: Color
    /// 缩略图解码的目标像素边长。
    var side: CGFloat
    /// 封面区高度：电视台标等固定尺寸组件按它排版。
    var height: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.17), tint.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            content
        }
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch visual {
        case .photo(let photo):
            PhotoThumbnailView(photo: photo, purpose: .cover(side))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .albumCover(let photo, let style):
            AlbumCoverImage(photo: photo, side: side, style: style)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .avatar(let data, let isPet):
            ZStack {
                Circle().fill(tint.opacity(0.18))
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: isPet ? "pawprint.fill" : "person.fill")
                        .font(.system(size: min(side, height) * 0.28, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: avatarSide, height: avatarSide)
            .clipShape(Circle())

        case .place:
            bigIcon("mappin.and.ellipse")
        case .scene:
            bigIcon("sparkles")
        case .cloudFile(let isVideo):
            bigIcon(isVideo ? "video.fill" : "photo.fill")
        case .cloudFolder:
            bigIcon("folder.fill")

        case .cinemaPoster(let url, let kind):
            // 海报 / 台标是固定 frame 的组件：尺寸必须取卡片实际可用区域，
            // 不能用解码像素（180 / 340）当宽度，否则比列宽还宽、压到相邻卡片上。
            GeometryReader { proxy in
                CinemaSearchPoster(urlString: url, kind: kind,
                                   width: proxy.size.width,
                                   height: proxy.size.height)
            }

        case .channelLogo(let url):
            GeometryReader { proxy in
                TVLogoImage(urlString: url, size: proxy.size, cornerRadius: 9)
            }

        case .catalogCover(let sourceID, let url):
            if let source = catalog.sources.first(where: { $0.id == sourceID }) {
                CatalogArtworkImage(source: source,
                                    urlString: url,
                                    cornerRadius: 9,
                                    quality: .thumbnail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                bigIcon("safari.fill")
            }
        }
    }

    private var avatarSide: CGFloat {
        min(min(side, height), 74)
    }

    private func bigIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: min(side, height * 1.6) * 0.2, weight: .medium))
            .foregroundStyle(tint.opacity(0.75))
    }
}

/// 影院海报：优先缓存里的封面，没有时用类型色块占位。
/// 行内小图用默认 42×58；卡片封面按传入尺寸铺满。
struct CinemaSearchPoster: View {
    let urlString: String?
    let kind: CinemaMediaKind
    var width: CGFloat = 42
    var height: CGFloat = 58

    @State private var image: NSImage?

    private var cornerRadius: CGFloat {
        min(width, height) * 0.18
    }

    /// 海报解码像素随显示尺寸走：卡片大图取 480px，行内小图维持 200px。
    private var decodePixels: Int {
        max(Int(max(width, height)), 200)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.30, green: 0.22, blue: 0.16),
                                    Color(red: 0.18, green: 0.14, blue: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
            } else {
                Image(systemName: kind == .movie ? "film" : "tv")
                    .font(.system(size: min(width, height) * 0.26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        }
        .task(id: urlString) {
            guard let urlString, !urlString.isEmpty else { return }
            if let cached = await CinemaArtworkCache.shared.image(for: urlString,
                                                                  maxPixelSize: decodePixels) {
                image = cached
            }
        }
    }
}

// MARK: - 行样式

private struct SearchRowChrome: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.075 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.22)
                                          : Color.primary.opacity(0.06),
                                  lineWidth: hovering ? 0.9 : 0.6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .animation(.easeOut(duration: 0.13), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func searchRowChrome() -> some View { modifier(SearchRowChrome()) }
}

// MARK: - 右键收藏

/// 搜索结果条目的右键菜单：收藏 / 稍后看。
/// 四类来源各自落到自己的收藏存储：图库照片写照片标记，网盘文件写当前图库的本地收藏，
/// 网络影院 / 网络资源条目写条目的「稍后看」表。其它来源（相簿、频道、节目等）不挂菜单。
private struct SearchHitFavoriteMenu: ViewModifier {
    @Environment(LibraryStore.self) private var store
    @Environment(CatalogBrowserModel.self) private var catalog

    let hit: SearchHit

    func body(content: Content) -> some View {
        if let action = favoriteAction {
            content.contextMenu {
                Button {
                    action.toggle()
                } label: {
                    Text(action.title)
                }
            }
        } else {
            content
        }
    }

    private struct FavoriteAction {
        let title: String
        let toggle: () -> Void
    }

    private var favoriteAction: FavoriteAction? {
        switch hit.payload {
        case .photo(let id):
            // 跨图库的照片不在当前图库里，收藏要先切库，这里不提供。
            guard let photo = store.anyPhoto(id: id) else { return nil }
            return FavoriteAction(title: photo.isFavorite ? "取消收藏" : "收藏") {
                store.toggleFavorite(id)
            }

        case .cloudFile(let mountID, _, let path):
            let key = LibraryStore.cloudFavoriteKey(mountID: mountID, path: path)
            return FavoriteAction(title: store.cloudFavorites.contains(key) ? "取消收藏" : "收藏") {
                store.toggleCloudFavorite(mountID: mountID, path: path)
            }

        case .catalogItem(let sourceID, let item):
            guard let source = catalog.sources.first(where: { $0.id == sourceID }) else { return nil }
            let favorited = catalog.isFavorite(sourceID: sourceID, itemID: item.id)
            return FavoriteAction(title: favorited ? "移出稍后看" : "稍后看") {
                catalog.toggleFavorite(source: source, item: item)
            }

        case .networkCinemaItem(let sourceID, let item, _):
            guard let source = catalog.sources.first(where: { $0.id == sourceID }) else { return nil }
            let favorited = catalog.isFavorite(sourceID: sourceID, itemID: item.id)
            return FavoriteAction(title: favorited ? "取消收藏" : "收藏") {
                catalog.toggleFavorite(source: source, item: item)
            }

        default:
            return nil
        }
    }
}

extension View {
    /// 搜索结果右键：收藏 / 取消收藏（不支持收藏的来源不出现菜单）。
    func searchHitFavoriteMenu(_ hit: SearchHit) -> some View {
        modifier(SearchHitFavoriteMenu(hit: hit))
    }
}
