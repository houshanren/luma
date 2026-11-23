import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院详情 / 面板统一深色底：避免跟随系统浅色外观出现白底。
private let cinemaSheetBackground = Color(red: 0.055, green: 0.06, blue: 0.075)

/// 影片 / 剧集 / 演职员详情页的主题色，跟随系统外观：
/// 深色下保持原来的影院暗色，浅色下切成与海报墙一致的浅灰，
/// 文字、玻璃底板与描边一起翻转，不再整页固定在暗色里。
private enum CinemaDetailTone {
    /// 页面底色：浅色直接吃窗口底色，与海报墙无缝衔接。
    static let page = dynamic(dark: NSColor(calibratedRed: 0.055, green: 0.06, blue: 0.075, alpha: 1),
                              light: .windowBackgroundColor)
    /// 前景：深色下是白，浅色下是近黑的墨色；透明度沿用原来的层次。
    static let ink = dynamic(dark: .white, light: NSColor(calibratedWhite: 0.10, alpha: 1))
    /// 浮层卡片的实色底板（悬停档案）：深色下是深面板，浅色下是近白面板。
    static let plate = dynamic(dark: NSColor(calibratedRed: 0.075, green: 0.08, blue: 0.095, alpha: 1),
                               light: NSColor(calibratedWhite: 0.99, alpha: 1))
    /// 强调色前景：深色下是品牌琥珀，浅色下压深一档，小字号在浅底上也能读清。
    static let accent = dynamic(dark: NSColor(calibratedRed: 1.00, green: 0.77, blue: 0.42, alpha: 1),
                                light: NSColor(calibratedRed: 0.70, green: 0.43, blue: 0.02, alpha: 1))

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// 卡片投影：浅色外观下整体减淡，避免浅底上出现一圈脏影。
    static func shadow(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.black.withAlphaComponent(dark ? opacity : opacity * 0.35)
        })
    }
}

/// 影院详情面板尽量吃满窗口：大屏更大，小屏也不会溢出。
private var cinemaDetailWindowSize: CGSize {
    let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    return CGSize(width: min(1480, max(1000, visible.width - 120)),
                  height: min(980, max(720, visible.height - 100)))
}

// MARK: - 规格角标

/// 角标流式布局：一行放不下自动换行，窄卡也能完整显示 4K / DV / Atmos / 类型。
private struct CinemaBadgeFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                width = max(width, lineWidth)
                height += lineHeight + lineSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 集卡在网格里的位置：悬停时把完整档案浮在该集旁边，而不是覆盖卡片本身。
private struct CinemaEpisodeAnchorKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>],
                       nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 人物页作品卡的锚点：悬停时把作品档案浮在这张卡旁边。
private struct CinemaWorkAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 规格角标组：4K / DV / HDR10+ / 10bit / Atmos / DTS-HD / 60fps / 类型。
private struct CinemaSpecBadges: View {
    let tags: [String]
    var fontSize: CGFloat = 8.5
    var tint: Color = .white
    var background: Color = .black.opacity(0.5)

    var body: some View {
        CinemaBadgeFlow(spacing: max(3, fontSize * 0.45),
                        lineSpacing: max(2, fontSize * 0.35)) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.94))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, max(4, fontSize * 0.62))
                    .padding(.vertical, max(1.5, fontSize * 0.3))
                    .background(background, in: Capsule())
            }
        }
    }
}

/// 卡片角标：只挑最重要的 1–2 个 —— 分辨率 > HDR 规格 > 音质，不铺满海报。
private func cinemaBadgeTags(_ file: CinemaFile?, limit: Int = 2) -> [String] {
    guard let file else { return [] }
    let tags = file.displayTags
    let resolution = ["4K", "2K", "1080P"]
    let dynamicRange = ["DV", "HDR10+", "HDR10", "HDR", "HLG"]
    let audio = ["Atmos", "DTS:X", "TrueHD", "DTS-HD", "DTS"]
    var picked: [String] = []
    if let value = resolution.first(where: { tags.contains($0) }) { picked.append(value) }
    if let value = dynamicRange.first(where: { tags.contains($0) }) { picked.append(value) }
    if let value = audio.first(where: { tags.contains($0) }) { picked.append(value) }
    // 没有分辨率 / 音画标记时退回其他标记（10bit / 60fps 等），但不铺满。
    if picked.isEmpty { picked = tags }
    return Array(picked.prefix(limit))
}

// MARK: - 详情页共用的小工具

/// 可展开的长简介：超过 6 行才出现「展开全文」。
private struct CinemaSynopsis: View {
    let text: String

    @State private var expanded = false

    private var isLong: Bool { text.count > 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 12.8))
                .foregroundStyle(.secondary)
                .lineSpacing(6)
                .lineLimit(expanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isLong {
                Button(expanded ? "收起" : "展开全文") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        }
    }
}

/// 2026-11-20 → 2026 年 11 月 20 日
private func cinemaDateText(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let parts = raw.split(separator: "-")
    guard parts.count >= 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
        return raw
    }
    return "\(year) 年 \(month) 月 \(day) 日"
}

private func cinemaMinutesText(_ minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) 分钟" }
    return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
}

private func cinemaStatusText(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw {
    case "Released": return "已上映"
    case "Returning Series": return "连载中"
    case "Ended": return "已完结"
    case "Canceled", "Cancelled": return "已取消"
    case "In Production": return "制作中"
    case "Post Production": return "后期制作"
    case "Planned": return "已计划"
    case "Rumored": return "传闻中"
    default: return raw
    }
}

private func cinemaLanguageName(_ code: String?) -> String? {
    guard let code, !code.isEmpty else { return nil }
    let names: [String: String] = [
        "zh": "汉语", "cn": "汉语", "en": "英语", "ja": "日语", "ko": "韩语",
        "fr": "法语", "de": "德语", "es": "西班牙语", "it": "意大利语",
        "ru": "俄语", "hi": "印地语", "th": "泰语", "pt": "葡萄牙语",
        "sv": "瑞典语", "da": "丹麦语", "nl": "荷兰语", "pl": "波兰语"
    ]
    return names[code.lowercased()] ?? code.uppercased()
}

/// TMDB 国家名是英文：资料卡里换成中文，常见国家之外的保留原文。
private func cinemaCountryName(_ raw: String) -> String {
    let names: [String: String] = [
        "China": "中国", "Hong Kong": "中国香港", "Taiwan": "中国台湾",
        "Japan": "日本", "South Korea": "韩国", "Korea": "韩国",
        "United States of America": "美国", "United States": "美国",
        "United Kingdom": "英国", "France": "法国", "Germany": "德国",
        "Italy": "意大利", "Spain": "西班牙", "India": "印度",
        "Thailand": "泰国", "Canada": "加拿大", "Australia": "澳大利亚",
        "Russia": "俄罗斯", "Singapore": "新加坡", "Malaysia": "马来西亚"
    ]
    return names[raw] ?? raw
}

private func cinemaMoneyText(_ value: Int64?) -> String? {
    guard let value, value > 0 else { return nil }
    if value >= 100_000_000 {
        return String(format: "约 %.2f 亿美元", Double(value) / 100_000_000)
    }
    return String(format: "约 %.0f 万美元", Double(value) / 10_000)
}

// MARK: - 影院库（刮削后的电影 / 电视剧）

/// 影院里的详情目标：剧集 / 影片详情在页面内展示，其余面板仍用 sheet。
private enum CinemaDetailTarget: Identifiable {
    case series(CinemaSeries)
    case entry(CinemaEntry)
    case newList
    case search
    case history
    case notifications
    case pin
    case folder(CinemaFolder)
    case folderMatch(CinemaFolder)
    case match(CinemaEntry)

    var id: String {
        switch self {
        case .series(let series): return "series-\(series.id)"
        case .entry(let entry): return "entry-\(entry.id.uuidString)"
        case .newList: return "new-list"
        case .search: return "search"
        case .history: return "history"
        case .notifications: return "notifications"
        case .pin: return "pin"
        case .folder(let folder): return "folder-\(folder.id)"
        case .folderMatch(let folder): return "folder-match-\(folder.id)"
        case .match(let entry): return "match-\(entry.id.uuidString)"
        }
    }
}

struct CinemaLibraryView: View {
    /// nil 表示本地图库的影院；有值表示某一个网盘实例自己的影院。
    let mountID: UUID?

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewer: ViewerModel
    @Environment(\.openSettings) private var openSettings
    /// 打开设置时直接落在「影院」分页。
    @AppStorage(SettingsKeys.selectedTab) private var settingsTab: SettingsTab = .general

    /// 当前打开的详情（剧集 / 影片）：直接在页面内展示，不再单独弹窗。
    @State private var detailTarget: CinemaDetailTarget?
    /// 搜索 / 观看记录 / 任务等辅助面板仍走 sheet，和详情分开存，互不覆盖。
    @State private var panelTarget: CinemaDetailTarget?
    /// 列表模式的选中行：单击选中、双击详情、空格播放。
    @State private var selectedListEntryID: UUID?
    @State private var selectedListSeriesID: String?
    /// 列表行右键「更换海报 / 背景」：候选面板由整页统一承载。
    @State private var artworkRequest: CinemaArtworkPickerRequest?
    @FocusState private var listFocus: Bool
    /// 文件夹视图的聚合结果：按目录分组，匹配后显示影片 / 剧集名。
    @State private var folders: [CinemaFolder] = []
    @State private var foldersLoaded = false
    @State private var hoveredFolderID: String?
    @State private var scrapingFolderIDs: Set<String> = []
    /// 当前钻进到哪一层（nil 表示顶层）；可以一直点下去。
    @State private var selectedFolderPath: String?
    /// 默认单击进详情，播放交给详情页里的「播放」按钮；设置里仍可改回单击直接播放。
    @AppStorage("cinema_open_detail_on_click") private var openDetailOnClick = true
    /// 海报墙密度：紧凑 / 标准 / 大图，设置里可改，立即生效。
    @AppStorage("cinema_wall_density") private var wallDensity: CinemaWallDensity = .normal
    /// 列表表头的升降序：再次点击同一列时反转，只影响列表呈现。
    @State private var listSortReversed = false
    /// F5 首次建库：用户点过「稍后再说」或已有片源后不再出现。
    @AppStorage("cinema_first_run_dismissed") private var firstRunDismissed = false

    init(mountID: UUID? = nil) {
        self.mountID = mountID
    }

    private var scope: CinemaScope { mountID.map { .mount($0) } ?? .local }

    /// 文件夹只在切到该分段时重算；匹配 / 刮削后靠 Store 的刷新信号重新聚合。
    private var folderRefreshKey: String {
        "\(store.cinemaTab.rawValue)|\(LibraryStore.cinemaScopeKey(scope))"
            + "|\(store.cinemaFolderRefreshToken)|\(store.cinemaEntries(for: scope).count)"
    }

    /// 页面所有派生数据都来自 Store 的一次性聚合快照：
    /// 只有刮削索引 / 筛选 / 排序变化时才重算，body 里反复读取只是取缓存。
    private var aggregate: CinemaAggregate {
        store.cinemaAggregate(for: scope)
    }

    /// 这个链接下所有刮削过的条目（含未识别的），页面上要能看到「有视频」。
    private var allEntries: [CinemaEntry] { aggregate.allEntries }
    private var entries: [CinemaEntry] { aggregate.entries }
    private var unmatched: [CinemaEntry] { aggregate.unmatched }
    private var movies: [CinemaEntry] { aggregate.movies }
    /// 未识别的剧同样聚合成一张卡，避免一集一张铺满整行。
    private var unmatchedSeries: [CinemaSeries] { aggregate.unmatchedSeries }
    private var unmatchedMovies: [CinemaEntry] { aggregate.unmatchedMovies }
    /// 同一部剧的多集合并成一张卡片；筛选条件与条目列表保持一致。
    private var series: [CinemaSeries] { aggregate.series }

    /// 列表模式下的显示顺序：表头再次点击时反转，不改变海报墙与卡片。
    private var listedMovies: [CinemaEntry] {
        listSortReversed ? Array(movies.reversed()) : movies
    }

    private var listedSeries: [CinemaSeries] {
        listSortReversed ? Array(series.reversed()) : series
    }

    /// 自动归组：同一 belongs_to_collection 的电影聚成合集，至少 2 部才展示。
    private var cinemaCollections: [CinemaCollectionGroup] { aggregate.collections }

    @ViewBuilder
    private var collectionShelves: some View {
        if !cinemaCollections.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(cinemaCollections) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(group.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(group.entries.count) 部")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(group.entries) { entry in
                                    posterCard(entry)
                                        .frame(width: 132)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
        }
    }

    /// 是否启用了顶栏筛选（年代 / 类型 / 分辨率 / 观看状态 / 智能 / 收藏 / 清单）。
    private var isFilteringCinema: Bool {
        store.cinemaHasAttributeFilters
            || store.cinemaFavoritesOnly
            || store.cinemaActiveListID != nil
    }

    private var needsConfig: Bool {
        store.cinemaNeedsConfiguration
    }

    /// 先把分页写成「影院」，再打开设置窗口，保证一进来就是影院设置。
    private func openCinemaSettings() {
        settingsTab = .cinema
        openSettings()
    }

    var body: some View {
        ZStack {
            // 列表放进 overlay：它只负责显示，不参与整页尺寸推导。
            // 否则海报墙 / 横向滚动的理想宽度会把窗口的最小宽度撑大，详情页也跟着超宽。
            Color.clear
                .overlay {
                    libraryContent
                        .opacity(detailTarget == nil ? 1 : 0)
                        .allowsHitTesting(detailTarget == nil)
                }
            if let target = detailTarget {
                inlineDetail(target)
                    // 详情之间直接切换（例如合集里的下一部）时重建状态，
                    // 否则 TMDB 补全结果会停在上一个条目上。
                    .id(target.id)
                    .transition(.opacity)
            }
        }
        // 影院控制台直接铺在窗口标题栏上：不走 NSToolbar 项，
        // 窗口怎么缩都不会被系统整条收进溢出菜单。
        .background {
            if ProcessInfo.processInfo.environment["LUMA_NO_CONSOLE_HOST"] == nil {
                CinemaTitlebarConsoleHost(store: store,
                                          settings: settings,
                                          viewer: viewer,
                                          openSettingsAction: { openSettings() })
            }
        }
        .animation(.easeOut(duration: 0.16), value: detailTarget?.id)
        // 列表留在下层，但它仍持有键盘焦点：进详情时交出去，
        // 否则空格 / 回车会被看不见的海报墙截走。
        .onChange(of: detailTarget?.id) { _, current in
            store.cinemaDetailOpen = current != nil
            if current == nil {
                if store.cinemaViewMode == .list { listFocus = true }
            } else {
                listFocus = false
            }
        }
        // 文件夹钻取也复用顶栏的「返回」：进入目录时把深度报给控制台。
        .onChange(of: selectedFolderPath) { _, path in
            store.cinemaFolderDepth = path == nil ? 0 : breadcrumbPaths.count
        }
        .onChange(of: store.cinemaFolderCloseTick) { _, _ in
            guard selectedFolderPath != nil else { return }
            goUp()
        }
        // 切离「文件夹」分段时收起当前目录，否则顶栏会一直停在「返回」形态。
        .onChange(of: store.cinemaTab) { _, tab in
            if tab != .folder, selectedFolderPath != nil { selectedFolderPath = nil }
        }
        // 播放器打开期间把键盘焦点交出去：否则回车 / 空格会被看不见的海报墙截走。
        .onChange(of: store.viewerID) { _, viewing in
            if viewing != nil {
                listFocus = false
            } else if detailTarget == nil, store.cinemaViewMode == .list {
                listFocus = true
            }
        }
        // 顶栏「返回」由详情页自己逐层消费（演职员 → 详情 → 列表）。
        .onDisappear {
            store.cinemaDetailOpen = false
            store.cinemaFolderDepth = 0
        }
    }

    /// 内嵌的剧集 / 影片详情：铺满影院页面，返回后回到原来的列表位置。
    @ViewBuilder
    private func inlineDetail(_ target: CinemaDetailTarget) -> some View {
        switch target {
        case .series(let item):
            CinemaSeriesDetailView(
                series: item,
                onPlay: { entry in
                    store.openCinema(entry, queue: seriesQueue(for: item))
                },
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environmentObject(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        case .entry(let entry):
            CinemaDetailView(
                entry: entry,
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environmentObject(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        default:
            EmptyView()
        }
    }

    /// 统一错误卡的恢复动作：重试刮削 / 去设置里改刮削源。
    private func handleCinemaRecovery(_ action: RecoveryAction) {
        switch action {
        case .retry:
            store.startCinemaScrape(for: scope, force: true)
        case .reconfigureSource, .reauthorize:
            settingsTab = .cinema
            openSettings()
        case .openInBrowser(let address):
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        case .openSystemSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(url)
            }
        case .allowInsecureTLS:
            break
        }
    }

    /// 书架 / 海报墙 / 列表本体：详情打开时留在下层，关掉后滚动位置不丢。
    private var libraryContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if needsConfig {
                        setupBanner
                    }
                    if store.cinemaScrapeRunning, store.cinemaScrapeScope == scope {
                        progressBar
                    } else if let sourceError = store.cinemaSourceError {
                        SourceErrorView(error: sourceError) { action in
                            handleCinemaRecovery(action)
                        }
                    } else if let message = store.cinemaScrapeMessage {
                        statusBanner(message)
                    }
                    content
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .topTrailing) {
                CinemaToastStack()
                    .environmentObject(store)
            }
            .overlay(alignment: .trailing) {
                wallLetterRail(proxy)
            }
        .task(id: scope) {
            // 换片源时收掉详情，避免显示上一个来源的剧集 / 影片。
            detailTarget = nil
            // 兜底：播放失败可能留下「viewerID 有值、但照片已找不到」的幽灵查看器，
            // 它会让顶栏整体让位给查看器，导致影院控制台消失。
            if store.viewerPhoto == nil, store.viewerID != nil {
                store.viewerID = nil
            }
            // 视频全屏标记若在退出系统全屏时没被复位，也会让整个窗口工具栏消失；
            // 回到影院说明已不在全屏，顺手复位。
            if store.viewerModel.videoImmersiveFullScreen,
               NSApp.keyWindow?.styleMask.contains(.fullScreen) != true {
                store.viewerModel.videoImmersiveFullScreen = false
            }
            // 只切换影院的作用域，不顺带刮削：影院和「视频」是两个入口，
            // 打开影院不应该等于把这个链接下的视频扫一遍，刮削只由显式点击触发。
            store.activateCinemaScope(scope)
        }
        .task(id: folderRefreshKey) {
            guard store.cinemaTab == .folder else { return }
            foldersLoaded = false
            await Task.yield()
            folders = store.cinemaFolders(for: scope)
            foldersLoaded = true
            syncFolderSelection()
        }
        // 只有面板走 sheet；剧集 / 影片详情已经改成页面内展示。
        .sheet(item: $panelTarget) { target in
            switch target {
            case .newList:
                CinemaNewListSheet { name in
                    store.createCinemaList(named: name)
                    panelTarget = nil
                } onCancel: {
                    panelTarget = nil
                }
                .environmentObject(store)
            case .search:
                CinemaSearchPanel { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        openDetail(entry)
                    }
                } onOpenSeries: { item in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        detailTarget = .series(item)
                    }
                } onPlay: { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        store.openCinema(entry)
                    }
                }
                .environmentObject(store)
            case .history:
                CinemaHistoryPanel(scope: scope) { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        store.openCinema(entry)
                    }
                }
                .environmentObject(store)
            case .notifications:
                CinemaNotificationSheet()
                    .environmentObject(store)
            case .pin:
                CinemaPINPromptSheet()
                    .environmentObject(store)
            case .folder(let folder):
                CinemaFolderDetailView(folder: folder,
                                       scope: scope,
                                       onPlay: { entry in
                                           panelTarget = nil
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                               store.openCinema(entry)
                                           }
                                       },
                                       onOpenEntry: { entry in
                                           panelTarget = nil
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                               detailTarget = .entry(entry)
                                           }
                                       })
                .environmentObject(store)
            case .folderMatch(let folder):
                CinemaMatchSheet(photos: folder.subtreePhotos, folderHint: folder.hint) {
                    panelTarget = nil
                    refreshFolders()
                }
                .environmentObject(store)
            case .match(let entry):
                CinemaMatchSheet(entry: entry) {
                    panelTarget = nil
                    refreshFolders()
                }
                .environmentObject(store)
            case .series, .entry:
                // 详情页不再走弹窗，这里只是让 switch 保持穷尽。
                EmptyView()
            }
        }
        // 列表行右键换封面：和详情页共用同一个候选面板。
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
        // 顶栏按钮通过 Store 旗标请求面板；这里统一转成单 sheet，避免多个 sheet 互相覆盖。
        .onChange(of: store.cinemaSearchVisible) { _, visible in
            guard visible else { return }
            store.cinemaSearchVisible = false
            panelTarget = .search
        }
        .onChange(of: store.cinemaHistoryVisible) { _, visible in
            guard visible else { return }
            store.cinemaHistoryVisible = false
            panelTarget = .history
        }
        .onChange(of: store.cinemaNewListVisible) { _, visible in
            guard visible else { return }
            store.cinemaNewListVisible = false
            panelTarget = .newList
        }
        .onChange(of: store.cinemaNotificationsVisible) { _, visible in
            guard visible else { return }
            store.cinemaNotificationsVisible = false
            panelTarget = .notifications
        }
        .onChange(of: store.cinemaPINPromptVisible) { _, visible in
            guard visible else { return }
            store.cinemaPINPromptVisible = false
            panelTarget = .pin
        }
        }
    }

    // MARK: 空状态 / 进度

    private var setupBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 20))
                .foregroundStyle(LumaBrand.violet)
            VStack(alignment: .leading, spacing: 5) {
                Text("先填写 TMDB API Key，再开始刮削")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("影院会用文件名匹配电影 / 剧集，自动补上海报、背景图、年份与简介。TMDB 需要一个免费 Key；也可以切成豆瓣数据源，免 Key 直接刮。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("打开设置 › 影院", action: openCinemaSettings)
                    Button("打开 TMDB 申请页") {
                        open("https://www.themoviedb.org/settings/api")
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(LumaBrand.violet.opacity(0.10)))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(LumaBrand.violet.opacity(0.22))
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在刮削这个链接下的视频  \(store.cinemaScrapeDone) / \(store.cinemaScrapeTotal)")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("取消") {
                    store.cancelCinemaScrape()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .help("取消刮削（已完成的结果会保留）")
                Text("\(Int(store.cinemaScrapeProgress * 100))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: store.cinemaScrapeProgress)
                .controlSize(.small)
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if store.cinemaTab == .folder {
            folderContent
        } else if allEntries.isEmpty {
            if !store.cinemaIndexLoaded {
                // 索引还在读：先给骨架屏，别让人以为影院是空的。
                skeletonGrid
            } else if showFirstRun {
                firstRunView
            } else {
                emptyState
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if store.cinemaActiveListID != nil {
                    activeListBanner
                }
                if store.cinemaViewMode == .wall {
                    wallStatsBar
                        .padding(.top, -6)
                }
                switch store.cinemaViewMode {
                case .shelf:
                    shelfContent
                case .wall:
                    wallContent
                case .card:
                    cardContent
                case .list:
                    listContent
                }
            }
        }
    }

    /// 索引读取期间的骨架屏：按当前海报墙列宽铺一屏占位卡。
    private var skeletonGrid: some View {
        LazyVGrid(columns: wallColumns, alignment: .leading, spacing: 16) {
            ForEach(0..<12, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    CinemaShimmer()
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    CinemaShimmer()
                        .frame(height: 10)
                        .clipShape(Capsule())
                    CinemaShimmer()
                        .frame(width: 64, height: 8)
                        .clipShape(Capsule())
                }
            }
        }
        .opacity(0.7)
    }

    @ViewBuilder
    private var activeListBanner: some View {
        if let list = store.cinemaList(store.cinemaActiveListID) {
            HStack(spacing: 8) {
                Image(systemName: list.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("清单 · \(list.name)")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(list.count) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("清除筛选") {
                    store.cinemaActiveListID = nil
                }
                .controlSize(.small)
                Button("删除清单", role: .destructive) {
                    store.deleteCinemaList(list.id)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(LumaBrand.amber.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.8)
            }
        }
    }

    // MARK: 书架

    @ViewBuilder
    private var shelfContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .all:
            // 按类型浏览时「继续观看」不属于这个类型，先收起来，避免混进无关影片。
            if store.cinemaTypeFilterID == nil, !store.cinemaContinueRecords(for: scope).isEmpty {
                continueShelf
            }
            categoryRow
            if !movies.isEmpty {
                shelf("最近添加", Array(movies.prefix(18)))
                shelf("高分电影", Array(movies.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(18)))
            }
            if !series.isEmpty {
                seriesShelf("剧集", series)
            }
            collectionShelves
            if !store.cinemaLists.isEmpty {
                myListsShelf
            }
            if series.isEmpty, movies.isEmpty, isFilteringCinema {
                filterEmptyState
            }
            // 没匹配上的也摆出来，否则「有 67 个视频但影院是空的」看起来像刮削没跑。
            // 筛选生效时它们没有年份 / 类型可比，先收起来。
            if !isFilteringCinema, !unmatched.isEmpty {
                unmatchedShelf
            }
        case .movies:
            if movies.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电影")
                }
            } else {
                hero(entries: movies)
                collectionShelves
                shelf("最近添加", Array(movies.prefix(18)))
                shelf("高分电影", Array(movies.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(18)))
            }
        case .shows:
            if series.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatchedSeries.isEmpty {
                    // 一集都没识别上时也按剧聚合展示，而不是给一张空页。
                    unmatchedShelf
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电视剧")
                }
            } else {
                seriesHero()
                seriesShelf("全部剧集", series)
                if !isFilteringCinema, !unmatchedSeries.isEmpty {
                    unmatchedShelf
                }
            }
        }
    }

    // MARK: 分类行

    /// 首页分类总览：上半是全部 / 收藏 / 最近 / 高分快捷条件，下半把所有内容类型平铺出来。
    /// 「全部」页因此能直接看到每个类型有多少条，不用再展开顶栏的类型弹层。
    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("分类")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    categoryChip("全部",
                                 icon: "square.grid.2x2.fill",
                                 count: allEntries.count,
                                 active: !store.cinemaHasAttributeFilters
                                     && !store.cinemaFavoritesOnly
                                     && store.cinemaActiveListID == nil) {
                        store.resetCinemaFilters()
                    }
                    categoryChip("收藏",
                                 icon: "heart.fill",
                                 count: categoryFavoriteCount,
                                 active: store.cinemaFavoritesOnly) {
                        store.cinemaFavoritesOnly.toggle()
                    }
                    categoryChip("最近 30 天",
                                 icon: "clock.fill",
                                 count: categoryRecentCount,
                                 active: store.cinemaSmartRecent) {
                        store.cinemaSmartRecent.toggle()
                    }
                    categoryChip("高分 8+",
                                 icon: "star.fill",
                                 count: categoryHighRatedCount,
                                 active: store.cinemaSmartHighRated) {
                        store.cinemaSmartHighRated.toggle()
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            if !aggregate.types.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("类型")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(aggregate.types.count) 个")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(aggregate.types) { bucket in
                                typeChip(bucket)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    /// 类型胶囊：点一下就按这个类型筛选，再点取消；条目数来自未筛选的全量统计。
    private func typeChip(_ bucket: CinemaTypeBucket) -> some View {
        let selected = store.cinemaTypeFilterID == bucket.id
        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                if selected {
                    store.cinemaTypeFilterID = nil
                } else {
                    store.cinemaTypeFilterID = bucket.id
                    store.cinemaTab = .all
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: bucket.type.icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(bucket.type.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(bucket.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.6)
            }
            .foregroundStyle(selected ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? LumaBrand.amber.opacity(0.16) : Color.primary.opacity(0.05),
                        in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(selected ? LumaBrand.amber.opacity(0.45) : Color.clear,
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(bucket.type.title) · \(bucket.count) 部")
    }

    private var categoryFavoriteCount: Int { aggregate.favoriteCount }

    private var categoryRecentCount: Int { aggregate.recentCount }

    private var categoryHighRatedCount: Int { aggregate.highRatedCount }

    private func categoryChip(_ title: String,
                              icon: String,
                              count: Int,
                              active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(active ? LumaBrand.amber.opacity(0.18) : Color.primary.opacity(0.05))
                    Circle()
                        .strokeBorder(active ? LumaBrand.amber.opacity(0.5) : Color.primary.opacity(0.08),
                                      lineWidth: 0.8)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                }
                .frame(width: 48, height: 48)
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) · \(count) 部")
    }

    // MARK: 文件夹

    private var folderColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16, alignment: .top)]
    }

    private var folderVideoColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 158, maximum: 194), spacing: 12, alignment: .top)]
    }

    /// 整棵文件夹树按路径索引：钻取、面包屑和刷新后的兜底都靠它。
    private var folderIndex: [String: CinemaFolder] {
        var result: [String: CinemaFolder] = [:]
        func walk(_ folder: CinemaFolder) {
            result[folder.path] = folder
            for child in folder.children { walk(child) }
        }
        folders.forEach(walk)
        return result
    }

    private var currentFolder: CinemaFolder? {
        selectedFolderPath.flatMap { folderIndex[$0] }
    }

    private var visibleFolders: [CinemaFolder] {
        currentFolder?.children ?? folders
    }

    /// 从顶层到当前目录的路径链，用于面包屑。
    private var breadcrumbPaths: [String] {
        guard let selected = selectedFolderPath else { return [] }
        let index = folderIndex
        var paths: [String] = []
        var cursor: String? = selected
        while let current = cursor, let folder = index[current] {
            paths.append(current)
            cursor = folder.parentPath
        }
        return paths.reversed()
    }

    @ViewBuilder
    private var folderContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            folderHeader

            if !foldersLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理文件夹…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if folders.isEmpty {
                folderPlaceholder("还没有可聚合的文件夹",
                                  detail: "先在相簿里扫描这个网盘，或点击顶栏「刮削」生成影院条目。")
            } else if selectedFolderPath != nil, currentFolder == nil {
                folderPlaceholder("这个目录已不存在",
                                  detail: "可能刚被删除或重新扫描过了。")
                Button("返回顶层") { goToRoot() }
                    .controlSize(.small)
            } else {
                folderLevel
            }
        }
    }

    @ViewBuilder
    private var folderLevel: some View {
        if !visibleFolders.isEmpty {
            LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 16) {
                ForEach(visibleFolders) { folder in
                    folderCard(folder)
                }
            }
        } else if let currentFolder, currentFolder.photos.isEmpty {
            folderPlaceholder("这个目录里没有视频",
                              detail: "换一层看看，或回到顶层重新扫描。")
        }

        if let currentFolder, !currentFolder.photos.isEmpty {
            folderVideosSection(currentFolder)
        }
    }

    private func folderPlaceholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 返回统一收进顶栏控制台（铭牌换成「返回」），这里不再放一枚小箭头：
                // 两处返回并存既难点击，也和顶栏重复。
                Text(currentFolder?.displayTitle ?? "文件夹")
                    .font(.system(size: 15, weight: .semibold))
                Text(folderHeadline)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("按目录聚合 · 点进文件夹可一直往下钻")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                if let currentFolder {
                    if scrapingFolderIDs.contains(currentFolder.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            quickScrapeFolder(currentFolder)
                        } label: {
                            Label("刮削本目录", systemImage: "wand.and.stars")
                        }
                        .controlSize(.small)
                        .disabled(currentFolder.subtreePhotos.isEmpty)
                        Button {
                            panelTarget = .folderMatch(currentFolder)
                        } label: {
                            Label("匹配…", systemImage: "magnifyingglass")
                        }
                        .controlSize(.small)
                        .disabled(currentFolder.subtreePhotos.isEmpty)
                    }
                }
                Button {
                    refreshFolders()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            breadcrumb
        }
    }

    private var folderHeadline: String {
        if let currentFolder {
            return "\(currentFolder.photos.count) 个视频 · \(currentFolder.children.count) 个子目录"
        }
        return "\(folders.count) 个顶层目录"
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if currentFolder != nil {
            HStack(spacing: 5) {
                Button("全部文件夹") { goToRoot() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(breadcrumbPaths, id: \.self) { path in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Button(folderIndex[path]?.name ?? LibraryStore.cinemaFolderName(of: path)) {
                        selectedFolderPath = path
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: path == selectedFolderPath ? .semibold : .medium))
                    .foregroundStyle(path == selectedFolderPath ? LumaBrand.amber : Color.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let path = currentFolder?.displayPath {
                    Text(path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: Capsule())
        }
    }

    private func folderCard(_ folder: CinemaFolder) -> some View {
        let hovered = hoveredFolderID == folder.id
        let scraping = scrapingFolderIDs.contains(folder.id)

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = folder.backdropURL ?? folder.posterURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else if let photo = folder.firstPhoto {
                        PhotoThumbnailView(photo: photo, purpose: .cover(420))
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 158)
                .clipped()

                LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.30), .black.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text(folder.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if folder.hasChildren {
                            Text("\(folder.children.count) 个子文件夹")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        if let kind = folder.kind {
                            Text(kind == .tv ? "剧集" : "电影")
                                .font(.system(size: 8.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))

                    Text(folder.displayTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(folderStatusText(folder))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            Text(folder.hasChildren ? "进入" : "查看")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if scraping {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .padding(6)
                            .background(.black.opacity(0.35), in: Circle())
                    } else {
                        folderActionButton("wand.and.stars", help: "刮削这个目录（含子目录）") {
                            quickScrapeFolder(folder)
                        }
                        folderActionButton("magnifyingglass", help: "手动匹配这个目录") {
                            panelTarget = .folderMatch(folder)
                        }
                    }
                }
                .padding(8)
                .opacity(hovered ? 1 : 0.55)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(folder.isMatched ? LumaBrand.amber : Color.secondary.opacity(0.6))
                    .frame(width: 4, height: 4)
                Text(folder.matchedCount > 0 ? "\(folder.matchedCount) 已识别" : "未识别")
                    .foregroundStyle(folder.isMatched ? LumaBrand.amber : Color.secondary)
                if folder.unmatchedCount > 0 {
                    Text("· \(folder.unmatchedCount) 未识别")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(folder.totalCount) 个视频")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.primary.opacity(0.08),
                              lineWidth: hovered ? 1 : 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            enterFolder(folder)
        }
        .onHover { hovering in
            if hovering {
                hoveredFolderID = folder.id
            } else if hoveredFolderID == folder.id {
                hoveredFolderID = nil
            }
        }
        .contextMenu {
            Button("进入文件夹") { enterFolder(folder) }
            Button("目录详情…") { panelTarget = .folder(folder) }
            Divider()
            Button(folder.subtreePhotos.isEmpty
                   ? "刮削此目录"
                   : "刮削此目录（\(folder.subtreePhotos.count) 个视频）") {
                quickScrapeFolder(folder)
            }
            Button("手动匹配此目录…") { panelTarget = .folderMatch(folder) }
            Divider()
            Button("在影院中查看") {
                if let mountID = folder.mountID {
                    store.navigate(to: .cloudCinema(mountID))
                } else {
                    store.navigate(to: .cinema)
                }
            }
        }
        .help(folder.displayPath)
    }

    /// 当前目录直属的视频：钻到最里层时直接平铺，不用再开面板。
    private func folderVideosSection(_ folder: CinemaFolder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("本目录视频")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(folder.photos.count) 个")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: folderVideoColumns, alignment: .leading, spacing: 12) {
                ForEach(folder.photos) { photo in
                    folderVideoTile(photo)
                }
            }
        }
    }

    private func folderVideoTile(_ photo: PhotoItem) -> some View {
        let entry = store.cinemaEntries(for: scope)[photo.id]
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = entry?.gridArtworkURL ?? entry?.artworkURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        PhotoThumbnailView(photo: photo, purpose: .cover(190))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .clipped()

                LinearGradient(colors: [.black.opacity(0.42), .clear],
                               startPoint: .bottom, endPoint: .top)
                Text(entry?.matched == true ? "已识别" : "未识别")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background((entry?.matched == true ? LumaBrand.amber : Color.black).opacity(0.85),
                                in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(entry?.title ?? photo.displayFilename)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(photo.displayFilename)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let entry {
                detailTarget = .entry(entry)
            } else {
                store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: [photo])
            }
        }
        .contextMenu {
            if let entry {
                Button("播放") { store.openCinema(entry) }
                Button("详情") { detailTarget = .entry(entry) }
                Divider()
            }
            Button("手动匹配…") {
                store.cinemaQuickMatch = CinemaQuickMatchRequest(photos: [photo])
            }
            Button(entry == nil ? "刮削" : "重新刮削") {
                Task { await store.scrapeCinemaPhotos([photo]) }
            }
        }
        .help(photo.displayFilename)
    }

    private func folderActionButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.42), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func folderStatusText(_ folder: CinemaFolder) -> String {
        var parts: [String] = [folder.displayPath]
        if folder.hasChildren {
            parts.append("\(folder.children.count) 个子目录")
        }
        return parts.joined(separator: " · ")
    }

    private func quickScrapeFolder(_ folder: CinemaFolder) {
        guard !scrapingFolderIDs.contains(folder.id) else { return }
        scrapingFolderIDs.insert(folder.id)
        Task {
            await store.scrapeCinemaFolder(folder, scope: scope)
            refreshFolders()
            scrapingFolderIDs.remove(folder.id)
        }
    }

    private func refreshFolders() {
        foldersLoaded = false
        folders = store.cinemaFolders(for: scope)
        foldersLoaded = true
        syncFolderSelection()
    }

    /// 刷新后如果当前目录已不存在（重扫 / 换盘），回到顶层。
    private func syncFolderSelection() {
        guard let selected = selectedFolderPath else { return }
        if folderIndex[selected] == nil {
            selectedFolderPath = nil
        }
    }

    private func enterFolder(_ folder: CinemaFolder) {
        selectedFolderPath = folder.path
    }

    private func goUp() {
        guard let current = currentFolder else { return }
        selectedFolderPath = current.parentPath.flatMap { folderIndex[$0] }?.path
    }

    private func goToRoot() {
        selectedFolderPath = nil
    }

    // MARK: 海报墙

    /// 列宽交给网格自适应，卡片按列宽铺满（不再固定 156 塞进更宽的格子，
    /// 否则每张卡右边会多出一条空白，看着像缩略图没铺满）。
    private var wallColumns: [GridItem] {
        [GridItem(.adaptive(minimum: wallDensity.minimumColumnWidth), spacing: 16, alignment: .top)]
    }

    @ViewBuilder
    private var wallContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .all:
            if !series.isEmpty {
                wallSection("电视剧", count: series.count) {
                    ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                        CinemaSeriesCard(series: item, fillWidth: true) {
                            detailTarget = .series(item)
                        }
                        .onAppear { prefetchSeriesArtwork(series, around: index) }
                    }
                }
            }
            if !movies.isEmpty {
                wallSection("电影", count: movies.count) {
                    ForEach(Array(movies.enumerated()), id: \.element.id) { index, entry in
                        posterCard(entry, fillWidth: true)
                            .onAppear { prefetchPosters(movies, around: index) }
                    }
                }
            }
            if series.isEmpty, movies.isEmpty, isFilteringCinema {
                filterEmptyState
            }
            if !isFilteringCinema, !unmatched.isEmpty {
                wallSection("未识别 · 可右键重新刮削",
                            count: unmatchedSeries.count + unmatchedMovies.count) {
                    ForEach(unmatchedSeries) { item in
                        CinemaSeriesCard(series: item, fillWidth: true) {
                            detailTarget = .series(item)
                        }
                    }
                    ForEach(unmatchedMovies) { entry in
                        posterCard(entry, fillWidth: true)
                    }
                }
            }
        case .movies:
            if movies.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电影")
                }
            } else {
                wallSection("电影", count: movies.count) {
                    ForEach(Array(movies.enumerated()), id: \.element.id) { index, entry in
                        posterCard(entry, fillWidth: true)
                            .onAppear { prefetchPosters(movies, around: index) }
                    }
                }
            }
        case .shows:
            if series.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatchedSeries.isEmpty {
                    wallSection("未识别 · 可右键重新刮削", count: unmatchedSeries.count) {
                        ForEach(unmatchedSeries) { item in
                            CinemaSeriesCard(series: item, fillWidth: true) {
                                detailTarget = .series(item)
                            }
                        }
                    }
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电视剧")
                }
            } else {
                wallSection("全部剧集", count: series.count) {
                    ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                        CinemaSeriesCard(series: item, fillWidth: true) {
                            detailTarget = .series(item)
                        }
                        .onAppear { prefetchSeriesArtwork(series, around: index) }
                    }
                }
            }
        }
    }

    /// 滚动预取：某张卡出现时，把紧接着的几张海报提前解好，快速滚动不再追帧。
    private func prefetchPosters(_ entries: [CinemaEntry], around index: Int, peeking: Int = 8) {
        let upper = min(entries.count, index + peeking)
        guard index < upper else { return }
        CinemaArtworkCache.shared.prefetch(entries[index..<upper].compactMap(\.posterURL))
    }

    private func prefetchSeriesArtwork(_ items: [CinemaSeries], around index: Int, peeking: Int = 8) {
        let upper = min(items.count, index + peeking)
        guard index < upper else { return }
        CinemaArtworkCache.shared.prefetch(items[index..<upper].compactMap(\.artworkURL))
    }

    private func posterCard(_ entry: CinemaEntry, fillWidth: Bool = false) -> some View {
        CinemaPosterCard(entry: entry,
                         versionCount: aggregate.versionCounts[store.cinemaVersionKey(for: entry)] ?? 0,
                         fillWidth: fillWidth,
                         onOpen: {
                             if openDetailOnClick {
                                 openDetail(entry)
                             } else {
                                 store.openCinema(entry, queue: aggregate.allEntries)
                             }
                         },
                         onPlay: { store.openCinema(entry, queue: aggregate.allEntries) },
                         onDetail: { openDetail(entry) })
            .id(entry.id)
    }

    private func wallSection<Content: View>(_ title: String,
                                            count: Int,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: wallColumns, alignment: .leading, spacing: 18) {
                content()
            }
        }
    }

    // MARK: 卡片模式

    /// 卡片模式：16:9 宽幅卡按网格竖向铺开，几百部也只是往下滚，
    /// 不再是「一部主卡 + 一条横向长胶片」那种横向无限延伸的浏览方式。
    @ViewBuilder
    private var cardContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .movies:
            if movies.isEmpty {
                if isFilteringCinema { filterEmptyState } else { tabEmptyState("还没有识别到电影") }
            } else {
                cardGrid(movies: movies, series: [])
            }
        case .shows:
            if series.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatchedSeries.isEmpty {
                    cardGrid(movies: [], series: unmatchedSeries)
                } else {
                    tabEmptyState("还没有识别到电视剧")
                }
            } else {
                cardGrid(movies: [], series: series)
            }
        case .all:
            if movies.isEmpty, series.isEmpty {
                if isFilteringCinema { filterEmptyState } else { tabEmptyState("还没有可展示的影片") }
            } else {
                cardGrid(movies: movies, series: series)
            }
        }
    }

    /// 自适应列宽：窗口越宽一行放越多，卡片始终铺满可用宽度。
    private var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: wallDensity.minimumCardWidth), spacing: 16, alignment: .top)]
    }

    private func cardGrid(movies: [CinemaEntry], series: [CinemaSeries]) -> some View {
        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
            ForEach(series) { item in
                seriesCard(item)
            }
            ForEach(movies) { entry in
                movieCard(entry)
            }
        }
    }

    private func movieCard(_ entry: CinemaEntry) -> some View {
        let progress = store.cinemaProgress[entry.id]
        return CinemaWideCard(title: entry.title,
                              meta: cardMeta(year: entry.year, genres: entry.genres),
                              artworkURL: entry.backdropURL ?? entry.posterURL,
                              fallbackPhoto: entry.file.photoItem,
                              rating: entry.rating,
                              badges: cardBadges(for: entry),
                              progressFraction: progress?.fraction,
                              progressText: progress.map { "已看 \(Int($0.fraction * 100))%" },
                              onOpen: {
                                  if openDetailOnClick { openDetail(entry) } else { store.openCinema(entry, queue: aggregate.allEntries) }
                              },
                              onPlay: { store.openCinema(entry, queue: aggregate.allEntries) })
            .id(entry.id)
    }

    private func seriesCard(_ item: CinemaSeries) -> some View {
        let watched = watchedEpisodeCount(item)
        let resume = resumeEpisode(for: item)
        let progressText: String? = resumeSubtitle(for: item)
            ?? (watched > 0 ? "已看 \(watched)/\(item.episodeCount) 集" : nil)
        let fraction = item.episodeCount > 0 ? Double(watched) / Double(item.episodeCount) : nil
        return CinemaWideCard(title: item.title,
                              meta: cardMeta(year: item.year, genres: item.genres),
                              artworkURL: item.backdropURL ?? item.posterURL,
                              fallbackPhoto: item.latestEpisode?.file.photoItem,
                              rating: item.rating,
                              badges: ["\(item.episodeCount) 集"] + (watched > 0 ? ["已看 \(watched)"] : []),
                              progressFraction: fraction,
                              progressText: progressText,
                              onOpen: { detailTarget = .series(item) },
                              onPlay: { if let resume { store.openCinema(resume, queue: seriesQueue(for: item)) } })
            .id(item.id)
    }

    private func cardMeta(year: Int?, genres: [String]?) -> String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let genres, !genres.isEmpty {
            parts.append(contentsOf: genres.prefix(2))
        }
        return parts.joined(separator: " · ")
    }

    /// 卡片规格角标：优先取文件标记，没有就按分辨率兜底。
    private func cardBadges(for entry: CinemaEntry) -> [String] {
        var tags = Array(entry.file.displayTags.prefix(2))
        if tags.isEmpty {
            let width = entry.file.pixelWidth
            if width >= 3000 { tags.append("4K") }
            else if width >= 1800 { tags.append("1080P") }
            else if width > 0 { tags.append("720P") }
        }
        let versions = store.cinemaVersionCount(for: entry)
        if versions > 1 { tags.append("\(versions) 版本") }
        return Array(tags.prefix(3))
    }

    // MARK: 列表

    @ViewBuilder
    private var listContent: some View {
        // 上千行时只构建视口内的行，滚动才继续实例化。
        LazyVStack(spacing: 0) {
            listHeader
            Divider().opacity(0.5)
            switch store.cinemaTab {
            case .folder:
                EmptyView()
            case .all:
                if !series.isEmpty {
                    ForEach(listedSeries) { item in
                        seriesListRow(item, badge: "剧集")
                    }
                    Divider().opacity(0.4)
                }
                if !movies.isEmpty {
                    ForEach(listedMovies) { entry in
                        entryListRow(entry)
                    }
                }
                if series.isEmpty, movies.isEmpty, isFilteringCinema {
                    filterEmptyState
                }
                if !isFilteringCinema, !unmatched.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(unmatchedSeries) { item in
                        seriesListRow(item, badge: "未识别")
                    }
                    ForEach(unmatchedMovies) { entry in
                        entryListRow(entry)
                    }
                }
            case .movies:
                if movies.isEmpty {
                    if isFilteringCinema {
                        filterEmptyState
                    } else {
                        tabEmptyState("还没有识别到电影")
                    }
                } else {
                    ForEach(listedMovies) { entry in
                        entryListRow(entry)
                    }
                }
            case .shows:
                if series.isEmpty {
                    if isFilteringCinema {
                        filterEmptyState
                    } else if !unmatchedSeries.isEmpty {
                        ForEach(unmatchedSeries) { item in
                            seriesListRow(item, badge: "未识别")
                        }
                    } else {
                        tabEmptyState("还没有识别到电视剧")
                    }
                } else {
                    ForEach(listedSeries) { item in
                        seriesListRow(item, badge: "剧集")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable()
        .focused($listFocus)
        // 去掉系统默认的蓝色焦点描边：它会把整张列表框成一圈，和影院的暗色面板冲突。
        .focusEffectDisabled()
        .onAppear { listFocus = true }
        .onKeyPress(.space) {
            guard store.viewerID == nil else { return .ignored }
            playSelectedListRow()
            return .handled
        }
        .onKeyPress(.return) {
            guard store.viewerID == nil else { return .ignored }
            openSelectedListRow()
            return .handled
        }
    }

    private func seriesListRow(_ item: CinemaSeries, badge: String) -> some View {
        let watched = watchedEpisodeCount(item)
        return CinemaListRow(artworkURL: item.artworkURL,
                      fallbackPhoto: item.latestEpisode?.file.photoItem,
                      title: item.title,
                      subtitle: resumeSubtitle(for: item) ?? item.subtitle,
                      year: item.year.map(String.init) ?? "—",
                      rating: item.rating,
                      genres: item.latestEpisode?.genres?.joined(separator: " / ") ?? "—",
                      spec: watched > 0 ? "\(watched)/\(item.episodeCount) 集" : "\(item.episodeCount) 集",
                      badge: badge,
                      progress: nil,
                      onOpen: { detailTarget = .series(item) },
                      selected: selectedListSeriesID == item.id,
                      onSelect: {
                          selectedListEntryID = nil
                          selectedListSeriesID = item.id
                      },
                      onPlay: { if let target = resumeEpisode(for: item) { store.openCinema(target, queue: seriesQueue(for: item)) } },
                      singleClickOpensDetail: openDetailOnClick)
            .contextMenu {
                Button("播放") {
                    if let target = resumeEpisode(for: item) {
                        store.openCinema(target, queue: seriesQueue(for: item))
                    }
                }
                Button("查看详情") { detailTarget = .series(item) }
                Divider()
                Button("选择海报…") { requestArtwork(.poster, for: item) }
                Button("选择背景…") { requestArtwork(.backdrop, for: item) }
            }
    }

    /// 列表行右键换封面：取这部剧里已匹配的一集，交给统一候选面板。
    private func requestArtwork(_ kind: CinemaArtworkKind, for item: CinemaSeries) {
        guard let sample = item.episodes.first(where: { $0.matched && $0.tmdbID != nil }) else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        // 菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
        }
    }

    /// 影片列表行 / 卡片右键换封面。
    private func requestArtwork(_ kind: CinemaArtworkKind, for entry: CinemaEntry) {
        guard entry.matched, entry.tmdbID != nil else {
            store.showToast("先匹配这部片，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: entry)
        }
    }

    /// 上次播放优先：进行中的一集 → 最后看完的下一集 → 第一集。
    private func resumeEpisode(for item: CinemaSeries) -> CinemaEntry? {
        let ordered = item.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
        if let inProgress = ordered.first(where: { store.cinemaWatchState(for: $0) == .inProgress }) {
            return inProgress
        }
        if let last = ordered.lastIndex(where: { store.cinemaWatchState(for: $0) == .finished }),
           last + 1 < ordered.count {
            return ordered[last + 1]
        }
        return ordered.first ?? item.latestEpisode
    }

    private func watchedEpisodeCount(_ item: CinemaSeries) -> Int {
        item.episodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
    }

    /// 列表副标题：有进行中的一集时优先显示「上次看到 SxxExx · 已看 yy%」。
    private func resumeSubtitle(for item: CinemaSeries) -> String? {
        guard let target = resumeEpisode(for: item),
              let progress = store.cinemaProgress[target.id],
              progress.fraction > 0.01, !progress.isFinished else { return nil }
        let label: String
        if let season = target.season, let episode = target.episode {
            label = String(format: "S%02dE%02d", season, episode)
        } else if let episode = target.episode {
            label = "第 \(episode) 集"
        } else {
            label = "上次"
        }
        return "上次看到 \(label) · 已看 \(Int(progress.fraction * 100))%"
    }

    private func selectedListSeries() -> CinemaSeries? {
        guard let id = selectedListSeriesID else { return nil }
        return (series + unmatchedSeries).first(where: { $0.id == id })
    }

    private func selectedListEntry() -> CinemaEntry? {
        guard let id = selectedListEntryID else { return nil }
        return (movies + unmatchedMovies).first(where: { $0.id == id })
    }

    private func playSelectedListRow() {
        if let entry = selectedListEntry() {
            store.openCinema(entry, queue: aggregate.allEntries)
        } else if let item = selectedListSeries(), let target = resumeEpisode(for: item) {
            store.openCinema(target, queue: seriesQueue(for: item))
        }
    }

    private func openSelectedListRow() {
        if let entry = selectedListEntry() {
            openDetail(entry)
        } else if let item = selectedListSeries() {
            detailTarget = .series(item)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 44, height: 1)
            sortHeader("片名", sort: .title)
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            sortHeader("年份", sort: .year)
                .frame(width: 56, alignment: .leading)
            sortHeader("评分", sort: .rating)
                .frame(width: 56, alignment: .leading)
            Text("类型")
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text("规格")
                .frame(width: 150, alignment: .leading)
            HStack(spacing: 4) {
                Text("状态")
                Button {
                    store.cinemaSort = .recent
                    listSortReversed = false
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(store.cinemaSort == .recent ? LumaBrand.amber : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("按最近添加排序")
            }
            .frame(width: 104, alignment: .trailing)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 表头点击排序：只切排序字段，再次点击同一列反转方向。
    private func sortHeader(_ title: String, sort: CinemaSort) -> some View {
        Button {
            if store.cinemaSort == sort {
                listSortReversed.toggle()
            } else {
                store.cinemaSort = sort
                listSortReversed = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if store.cinemaSort == sort {
                    Image(systemName: sortArrow(sort))
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(store.cinemaSort == sort ? LumaBrand.amber : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    private func sortArrow(_ sort: CinemaSort) -> String {
        let naturalAscending = sort == .title
        let ascending = listSortReversed ? !naturalAscending : naturalAscending
        return ascending ? "chevron.up" : "chevron.down"
    }

    private func entryListRow(_ entry: CinemaEntry) -> some View {
        CinemaListRow(artworkURL: entry.artworkURL,
                      fallbackPhoto: entry.file.photoItem,
                      title: entry.title,
                      subtitle: entry.file.filename,
                      year: entry.year.map(String.init) ?? "—",
                      rating: entry.rating,
                      genres: entry.genres?.joined(separator: " / ") ?? "—",
                      spec: entrySpec(entry),
                      badge: entry.matched ? (entry.kind == .movie ? "电影" : "剧集") : "未识别",
                      progress: store.cinemaProgress[entry.id],
                      onOpen: { openDetail(entry) },
                      selected: selectedListEntryID == entry.id,
                      onSelect: {
                          selectedListSeriesID = nil
                          selectedListEntryID = entry.id
                      },
                      onPlay: { store.openCinema(entry, queue: aggregate.allEntries) },
                      singleClickOpensDetail: openDetailOnClick)
            .contextMenu {
                Button("播放") { store.openCinema(entry, queue: aggregate.allEntries) }
                Button("查看详情") { openDetail(entry) }
                Divider()
                Button("选择海报…") { requestArtwork(.poster, for: entry) }
                Button("选择背景…") { requestArtwork(.backdrop, for: entry) }
                Divider()
                Button(store.cinemaProgress[entry.id]?.isFinished == true ? "标记为未看" : "标记为已看") {
                    let watched = store.cinemaProgress[entry.id]?.isFinished != true
                    store.setCinemaWatched(entry, watched: watched)
                }
                Button("复制文件路径") {
                    let text = entry.file.cloudPath ?? entry.file.filename
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.showToast("已复制路径")
                }
            }
    }

    /// 整部剧按季、集排好，作为播放队列：播完自动下一集，顶栏「下一集」也能用。
    private func seriesQueue(for item: CinemaSeries) -> [CinemaEntry] {
        item.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
    }

    private func entrySpec(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if entry.file.pixelWidth > 0, entry.file.pixelHeight > 0 {
            parts.append("\(entry.file.pixelWidth)×\(entry.file.pixelHeight)")
        }
        if let codec = entry.file.videoCodec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        parts.append(contentsOf: entry.file.displayTags.prefix(2))
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: 详情入口

    private func openDetail(_ entry: CinemaEntry) {
        withAnimation(.easeOut(duration: 0.2)) {
            if entry.kind == .tv,
               let item = store.cinemaSeries(for: scope, matched: entry.matched)
                .first(where: { series in
                    series.episodes.contains(where: { $0.id == entry.id })
                }) {
                detailTarget = .series(item)
                return
            }
            detailTarget = .entry(entry)
        }
    }

    /// 筛选把当前分页筛空：告诉用户是筛选而不是刮削没结果，并提供一键复位。
    private var filterEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("没有符合筛选条件的影片")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(filterSummary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("清除筛选") {
                withAnimation(.snappy(duration: 0.16)) {
                    store.resetCinemaFilters()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// 顶栏筛选条件的可读描述，例如「2024 · 科幻 · 4K · 进行中」。
    private var filterSummary: String {
        var parts: [String] = []
        if let typeID = store.cinemaTypeFilterID {
            parts.append(CinemaContentType.descriptor(id: typeID).title)
        }
        if !store.cinemaKindFilters.isEmpty {
            parts.append(store.cinemaKindFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaYears.isEmpty {
            parts.append(store.cinemaYears.sorted(by: >).map(String.init).joined(separator: "/"))
        }
        if !store.cinemaGenres.isEmpty {
            parts.append(store.cinemaGenres.sorted().joined(separator: "/"))
        }
        if !store.cinemaCountries.isEmpty {
            parts.append(store.cinemaCountries.sorted().joined(separator: "/"))
        }
        if !store.cinemaLanguages.isEmpty {
            parts.append(store.cinemaLanguages.sorted()
                .map(CinemaLanguageCatalog.title)
                .joined(separator: "/"))
        }
        if !store.cinemaResolutions.isEmpty {
            parts.append(store.cinemaResolutions.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaSpecFilters.isEmpty {
            parts.append(store.cinemaSpecFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaRuntimeFilters.isEmpty {
            parts.append(store.cinemaRuntimeFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaRatingFilters.isEmpty {
            parts.append(store.cinemaRatingFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaWatchFilters.isEmpty {
            parts.append(store.cinemaWatchFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if store.cinemaSmartHighRated { parts.append("高分 8+") }
        if store.cinemaSmartRecent { parts.append("最近 30 天") }
        if store.cinemaFavoritesOnly { parts.append("收藏") }
        if let list = store.cinemaList(store.cinemaActiveListID) { parts.append(list.name) }
        return parts.joined(separator: " · ")
    }

    // MARK: 海报墙统计 / 字母索引

    /// 统计条：规格分布 + 已看，回答「这个库有什么、看了多少」。
    private var wallStatsBar: some View {
        let stats = aggregate.stats
        return HStack(spacing: 7) {
            statChip("4K", stats.uhd)
            statChip("1080P", stats.hd)
            statChip("720P 及以下", stats.sd)
            statChip("已看", stats.watched)
            statChip("未识别", unmatched.count, tint: LumaBrand.coral)
            Spacer(minLength: 0)
            Text("\(stats.matched) 个已识别文件")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func statChip(_ title: String, _ value: Int, tint: Color = LumaBrand.amber) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(value > 0 ? tint : Color.secondary)
        }
        .font(.system(size: 9.5))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private var wallItemCount: Int { aggregate.wallItemCount }

    /// 每部作品取首字符作为索引字母；中文片名直接用首字。
    private var wallLetterEntries: [CinemaLetterEntry] { aggregate.letters }

    /// 大库专用：条目超过 200 才出现字母索引。
    @ViewBuilder
    private func wallLetterRail(_ proxy: ScrollViewProxy) -> some View {
        if store.cinemaViewMode == .wall,
           store.cinemaTab != .folder,
           wallItemCount > 200,
           !wallLetterEntries.isEmpty {
            VStack(spacing: 1) {
                ForEach(wallLetterEntries) { item in
                    Button(item.letter) {
                        withAnimation(.snappy(duration: 0.22)) {
                            proxy.scrollTo(item.target, anchor: .top)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                    .frame(width: 18, height: 13)
                    .help("跳到 \(item.letter)")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
            }
            .padding(.trailing, 6)
        }
    }

    private func tabEmptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("已刮削但没匹配上的视频都在「全部」的未识别里，可以右键重新刮削。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// 文档约定 D4：未识别空态给命名示例 + 一个「去匹配」主行动，不写「暂无数据」。
    private var unmatchedEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("\(unmatched.count) 条影片未识别")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("命名不规范会导致匹配失败。试试「片名.年份.分辨率」，或手动搜索片名。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if let entry = unmatched.first {
                Button("去匹配") { panelTarget = .match(entry) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    private var showFirstRun: Bool {
        allEntries.isEmpty && store.cloudMounts.isEmpty && !firstRunDismissed
    }

    /// F5 首次建库：一项主行动 + 三步说明，允许跳过。
    private var firstRunView: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: index == 1
                                             ? [LumaBrand.violet.opacity(0.55), Color.black.opacity(0.35)]
                                             : [LumaBrand.amber.opacity(0.45), Color.black.opacity(0.30)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 96, height: 144)
                        .overlay {
                            Image(systemName: index == 2 ? "tv" : "film")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                }
            }
            .opacity(0.34)
            .padding(.trailing, 34)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("LUMA CINEMA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(LumaBrand.amber)
                    Text("把影片放进来，\n剩下的交给影院")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .lineSpacing(3)
                    Text("选择一个目录或网盘，Luma 会扫描视频、自动匹配电影与剧集、生成海报墙。不需要转码，也不复制文件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .frame(maxWidth: 520, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 18) {
                    firstRunStep("STEP 1", title: "选择来源", detail: "本地目录、夸克、阿里、WebDAV、SMB")
                    firstRunStep("STEP 2", title: "确认扫描规则", detail: "刮削源、NFO、跳过目录")
                    firstRunStep("STEP 3", title: "坐下看片", detail: "继续观看、海报墙、剧集聚合")
                }

                HStack(spacing: 10) {
                    Button {
                        store.presentCloudWizard()
                    } label: {
                        Label("添加片源", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("稍后再说") {
                        firstRunDismissed = true
                    }
                    .controlSize(.large)
                }

                HStack(spacing: 6) {
                    ForEach(["本地目录", "夸克", "阿里云盘", "百度网盘", "WebDAV", "SMB", "AList"], id: \.self) { name in
                        Text(name)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                            .overlay {
                                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                            }
                    }
                }
            }
            .padding(34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [LumaBrand.amber.opacity(0.06), Color.primary.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
    }

    private func firstRunStep(_ index: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(index)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(LumaBrand.amber.opacity(0.85))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 168, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(mountID == nil ? "影院库还是空的" : "这个网盘的影院还是空的")
                .font(.system(size: 16, weight: .semibold))
            Text(needsConfig
                 ? "先在设置里填写 TMDB API Key，或切换成免 Key 的豆瓣数据源，再回到这里刮削。"
                 : (mountID == nil
                    ? "点击顶部的「刮削」按钮开始。会扫描本地视频，按文件名匹配海报、类型与简介。"
                    : "点击顶部的「刮削」按钮会把当前网盘扫描到的视频逐个匹配海报与简介；匹配不上的会放进「未识别」，仍然可以播放。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !needsConfig {
                Button("开始刮削") {
                    store.startCinemaScrape(for: scope)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(store.cinemaScrapeRunning)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: 主视觉

    @ViewBuilder
    private func hero(entries: [CinemaEntry]? = nil) -> some View {
        let pool = entries ?? self.entries
        if let entry = pool.first(where: { $0.backdropURL != nil }) ?? pool.first {
            CinemaHeroCard(entry: entry,
                           onPlay: { store.openCinema(entry) },
                           onDetail: { openDetail(entry) })
        }
    }

    private func shelf(_ title: String, _ list: [CinemaEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(list) { entry in
                        posterCard(entry)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 继续观看

    @ViewBuilder
    private var continueShelf: some View {
        let records = store.cinemaContinueRecords(for: scope)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("继续观看")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(records.count) 部待续播")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(records.prefix(12)) { record in
                            CinemaContinueCard(record: record) {
                                openContinue(record)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func openContinue(_ record: CinemaProgressRecord) {
        guard let entry = store.cinemaEntries(for: scope)[record.photoID] else { return }
        store.openCinema(entry)
    }

    // MARK: 我的清单

    private var myListsShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("我的清单")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(store.cinemaLists.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    panelTarget = .newList
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumaBrand.amber)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(store.cinemaLists) { list in
                        cinemaListCard(list)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func cinemaListCard(_ list: CinemaListRecord) -> some View {
        let active = store.cinemaActiveListID == list.id
        return Button {
            store.cinemaActiveListID = active ? nil : list.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: list.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(list.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(list.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(active ? "已筛选" : "点击筛选")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .padding(11)
            .frame(width: 172, height: 82, alignment: .leading)
            .background(active ? LumaBrand.amber.opacity(0.12)
                               : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? LumaBrand.amber.opacity(0.45)
                                         : Color.primary.opacity(0.06),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除清单", role: .destructive) {
                store.deleteCinemaList(list.id)
            }
        }
    }

    // MARK: 剧集（多集 → 一张卡）

    @ViewBuilder
    private func seriesHero() -> some View {
        if let item = series.first(where: { $0.backdropURL != nil }) ?? series.first {
            CinemaSeriesHeroCard(series: item,
                                 onPlay: {
                                     if let target = resumeEpisode(for: item) {
                                         store.openCinema(target, queue: seriesQueue(for: item))
                                     }
                                 },
                                 onOpen: { detailTarget = .series(item) })
        }
    }

    private func seriesShelf(_ title: String, _ list: [CinemaSeries]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(list) { item in
                        CinemaSeriesCard(series: item) {
                            detailTarget = .series(item)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 未识别同样按剧聚合：一部剧一张卡，电影仍是一条一张。
    private var unmatchedShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("未识别 · 可右键重新刮削")
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(unmatchedSeries) { item in
                        CinemaSeriesCard(series: item) {
                            detailTarget = .series(item)
                        }
                    }
                    ForEach(unmatchedMovies.prefix(18)) { entry in
                        posterCard(entry)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func open(_ raw: String) {
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }
}


/// 海报卡尺寸：海报墙里跟随网格列宽（按 2:3 由宽度推高），书架里固定 156×234。
/// 尺寸用透明底板锁定、卡片内容放 overlay：角标 / 长标题的最小宽高不会再反过来
/// 把卡片撑大，同一行每张卡始终是同一个 2:3 矩形。
private struct CinemaWallCardSizing: ViewModifier {
    let fillWidth: Bool

    func body(content: Content) -> some View {
        if fillWidth {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { content }
        } else {
            content.frame(width: 156, height: 234)
        }
    }
}

/// 演职员头像：悬停时头像微微抬起、琥珀渐变描边加光晕，右上角弹出「打开」角标，
/// 名字跟着变琥珀色，一眼就知道点头像能进人物页。
private struct CinemaCastTile: View {
    let member: CinemaCastMember
    let onOpen: () -> Void
    /// 右键「在网络影院搜索 TA」。
    let onSearchOnline: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 5) {
                ZStack {
                    if let url = member.profileURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.18))
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(hovered
                                          ? AnyShapeStyle(AngularGradient(colors: [LumaBrand.amber,
                                                                                   LumaBrand.coral,
                                                                                   LumaBrand.amber],
                                                                          center: .center))
                                          : AnyShapeStyle(Color.primary.opacity(0.10)),
                                          lineWidth: hovered ? 1.6 : 0.6)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 17, height: 17)
                        .background(LumaBrand.amber, in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5) }
                        .scaleEffect(hovered ? 1 : 0.4)
                        .opacity(hovered ? 1 : 0)
                        .offset(x: 1.5, y: 1.5)
                }
                .shadow(color: LumaBrand.amber.opacity(hovered ? 0.42 : 0),
                        radius: hovered ? 9 : 0, y: 2)
                .scaleEffect(hovered ? 1.06 : 1)
                .offset(y: hovered ? -2 : 0)

                Text(member.name)
                    .font(.system(size: 11, weight: hovered ? .semibold : .medium))
                    .foregroundStyle(hovered ? LumaBrand.amber : Color.primary)
                    .lineLimit(1)
                Text(member.character ?? " ")
                    .font(.system(size: 10))
                    .foregroundStyle(hovered ? Color.primary.opacity(0.82) : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovered)
        .contextMenu {
            Button("网络影院搜索 \(member.name)（即将上线）") { onSearchOnline() }
        }
        .help("查看 \(member.name) 的人物页；右键可在网络影院搜索（即将上线）")
    }
}

private struct CinemaSeriesCard: View {
    let series: CinemaSeries
    /// 海报墙里跟随网格列宽（外框和海报永远同宽）；书架里固定 156×234。
    var fillWidth: Bool = false
    let onOpen: () -> Void

    @EnvironmentObject private var store: LibraryStore
    /// 悬停状态留在卡片内部：只有这张卡重绘，不会带着整页聚合一起重算。
    @State private var hovered = false
    /// 右键「手动刮削」打开的选片面板。
    @State private var showMatchSheet = false
    /// 右键「更换海报 / 背景」的候选面板。
    @State private var artworkRequest: CinemaArtworkPickerRequest?

    /// 单独声明，避免 body 里的表达式类型检查超时。
    private var overlayGradient: LinearGradient {
        LinearGradient(colors: [Color.clear,
                                Color.black.opacity(0.10),
                                Color.black.opacity(0.72)],
                       startPoint: .center,
                       endPoint: .bottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if series.artworkURL != nil {
                        CinemaArtwork(urlString: series.artworkURL, contentMode: .fill)
                    } else if let latest = series.latestEpisode {
                        PhotoThumbnailView(photo: latest.file.photoItem, purpose: .cover(156))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                overlayGradient

                VStack(alignment: .leading, spacing: 3) {
                    Text(series.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(series.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                // 底部片名 / 副标题整体上移，避免被卡片下沿和海报自带的片名压住。
                .padding(.horizontal, 9)
                .padding(.top, 9)
                .padding(.bottom, 16)

                VStack {
                    // 157pt 的竖版卡：左上只放最重要的 1–2 个音画角标，右上留评分。
                    // 左角标用 maxWidth：窄卡片时优先压缩角标，右侧评分始终留在卡内。
                    HStack(alignment: .top, spacing: 5) {
                        CinemaSpecBadges(tags: cinemaBadgeTags(series.latestEpisode?.file),
                                         fontSize: 8)
                            .frame(maxWidth: 102, alignment: .leading)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            if !series.isMatched {
                                Text("未识别")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(.black.opacity(0.48), in: Capsule())
                            } else if let rating = series.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
            }
            .modifier(CinemaWallCardSizing(fillWidth: fillWidth))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: hovered ? 1.2 : 0.5)
            }
            // 悬停只加深描边与投影，不再放大卡片：放大后描边会溢出格子，外框和海报对不齐。
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .animation(.easeOut(duration: 0.16), value: hovered)
        }
        .frame(maxWidth: fillWidth ? .infinity : 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("\(series.title) · \(series.subtitle)")
        .contextMenu {
            Button("查看 \(series.episodeCount) 集") { onOpen() }
            Button("手动刮削…") {
                // 右键菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showMatchSheet = true }
            }
            Button("选择海报…") { requestArtwork(.poster) }
            Button("选择背景…") { requestArtwork(.backdrop) }
            Button(series.latestEpisode.flatMap { store.cinemaProgress[$0.id]?.isFinished } == true ? "标记为未看" : "标记为已看") {
                guard let sample = series.latestEpisode else { return }
                let watched = store.cinemaProgress[sample.id]?.isFinished != true
                store.setCinemaWatched(sample, watched: watched)
            }
            if let sample = series.latestEpisode {
                Button("复制文件路径") {
                    let text = sample.file.cloudPath ?? sample.file.filename
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.showToast("已复制路径")
                }
            }
            Divider()
            Button("忽略整部剧（以后不刮削）") {
                store.ignoreCinemaSeries(series)
            }
            Button("删除整部剧文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries(series.episodes, title: series.title)
            }
        }
        .sheet(isPresented: $showMatchSheet) {
            // 整部剧一起手动匹配：面板里可以统一选剧并按文件名排季集。
            CinemaMatchSheet(photos: series.episodes.map(\.file.photoItem),
                             folderHint: series.episodes.first?.folderHint) {
                showMatchSheet = false
            }
            .environmentObject(store)
        }
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
        .id("series-\(series.id)")
    }

    /// 换封面：用剧里一集已匹配的条目做代理，写回时 `applyCinemaArtwork` 会同步整部剧。
    private func requestArtwork(_ kind: CinemaArtworkKind) {
        guard let sample = series.episodes.first(where: { $0.matched && $0.tmdbID != nil }) else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
        }
    }
}

// MARK: - 剧集主视觉

private struct CinemaSeriesHeroCard: View {
    let series: CinemaSeries
    var onPlay: (() -> Void)? = nil
    let onOpen: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @State private var hover = false
    @State private var showMatchSheet = false
    @State private var artworkRequest: CinemaArtworkPickerRequest?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: series.backdropURL ?? series.posterURL, contentMode: .fill)
                .frame(height: 260)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.30), .black.opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(series.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(series.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    if let rating = series.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                }
                let heroTags = cinemaBadgeTags(series.latestEpisode?.file)
                if !heroTags.isEmpty {
                    CinemaSpecBadges(tags: heroTags,
                                     fontSize: 10.5,
                                     background: .white.opacity(0.16))
                        .frame(maxWidth: 620, alignment: .leading)
                }
                if let overview = series.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                Button(action: onOpen) {
                    Label("查看 \(series.episodeCount) 集", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white.opacity(hover ? 0.95 : 0.88), in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .padding(.top, 2)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("查看 \(series.episodeCount) 集") { onOpen() }
            if let onPlay {
                Button("继续播放") { onPlay() }
            }
            Button("手动刮削…") {
                // 菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showMatchSheet = true }
            }
            Button("选择海报…") { requestArtwork(.poster) }
            Button("选择背景…") { requestArtwork(.backdrop) }
            if let sample = series.latestEpisode {
                Button(store.cinemaProgress[sample.id]?.isFinished == true ? "标记为未看" : "标记为已看") {
                    let watched = store.cinemaProgress[sample.id]?.isFinished != true
                    store.setCinemaWatched(sample, watched: watched)
                }
                Button("复制文件路径") {
                    let text = sample.file.cloudPath ?? sample.file.filename
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.showToast("已复制路径")
                }
            }
            Divider()
            Button("忽略整部剧（以后不刮削）") {
                store.ignoreCinemaSeries(series)
            }
        }
        .sheet(isPresented: $showMatchSheet) {
            CinemaMatchSheet(photos: series.episodes.map(\.file.photoItem),
                             folderHint: series.episodes.first?.folderHint) {
                showMatchSheet = false
            }
            .environmentObject(store)
        }
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
    }

    /// 换封面：取剧里一集已匹配的条目做代理，写回时同步整部剧。
    private func requestArtwork(_ kind: CinemaArtworkKind) {
        guard let sample = series.episodes.first(where: { $0.matched && $0.tmdbID != nil }) else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
        }
    }
}

// MARK: - 剧集分集

private struct CinemaSeriesDetailView: View {
    let series: CinemaSeries
    let onPlay: (CinemaEntry) -> Void
    /// 演职员页里点开另一部作品：交给上层替换详情目标。
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    /// 顶栏「返回」：没有二级页时关闭整个详情。
    var onClose: () -> Void = {}

    @EnvironmentObject private var store: LibraryStore
    @State private var hoveredEpisode: UUID?
    /// 键盘方向键游标：只服务键盘切集，鼠标点击不再有「选中」这一步。
    @State private var keyboardEpisodeID: UUID?
    @State private var enriched: CinemaEntry?
    /// 推荐分组：猜你喜欢 / 豆瓣 / 同系列 / 同导演 / 同演员。
    @State private var recommendationGroups: [CinemaRecommendationGroup] = []
    /// 手动挑过封面后先在本页覆盖，不必等上层快照刷新。
    @State private var artworkPosterOverride: String?
    @State private var artworkBackdropOverride: String?
    @State private var artworkRequest: CinemaArtworkPickerRequest?
    /// 恢复上次查看的季时，不要顺手清掉选中集。
    @State private var suppressSeasonReset = false
    /// 滚动偏移：滚过档案卡后浮出紧凑标题条。
    @State private var scrollOffset: CGFloat = 0
    /// 各季的单集标题 / 简介 / 剧照（TMDB 按季拉取，季 → 集号 → 信息）。
    @State private var episodeInfos: [Int: [Int: CinemaEpisodeInfo]] = [:]
    /// 当前查看的季；nil 时默认落在最新一季（标签栏最左）。
    @State private var selectedSeason: Int?
    /// 演职员 → 人物页。
    @State private var personTarget: CinemaCastMember?
    /// 预告片：页面内播放层，不打开浏览器。
    @State private var showTrailer = false
    /// 档案卡里的长简介：默认收 5 行。
    @State private var dossierExpanded = false
    /// 片头尾自动识别进行中。
    @State private var detectingIntro = false
    /// 片头设置范围：整部剧默认值，或只覆盖某一集。
    @State private var introScope: IntroScope = .series
    /// 跳过片头尾的调节面板。
    @State private var showIntroPanel = false
    /// 剧集网格的键盘焦点：方向键选择、空格播放，和图库网格一致。
    @FocusState private var episodeGridFocus: Bool
    /// 当前内容列宽度：网格列数与键盘跨行都按它推导，窗口变化时同步更新。
    @State private var contentWidth: CGFloat = 0
    /// 悬停档案实际高度：贴到底部时把面板整体上移，内容不会被裁掉。
    @State private var hoverPanelHeight: CGFloat = 340
    /// 悬停档案的延迟关闭：鼠标在卡片之间快速移动时不会闪一下。
    @State private var hoverDismissTask: DispatchWorkItem?

    private enum IntroScope: Hashable {
        case series
        case episode
    }

    /// 集卡列数：完全由外面量到的可视宽度决定，列数确定后卡片只在这条宽度里均分。
    /// 不用 `.adaptive`：它在某些测量阶段会按「所有卡片排成一行」反推理想宽度，
    /// 结果反过来把整页 / 窗口的最小宽度撑大。
    private func episodeColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 16
        let count = max(1, GridLayout.columns(contentWidth: max(1, width),
                                              targetSize: 210,
                                              spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 140, maximum: 340), spacing: spacing),
                     count: count)
    }

    /// 资料项列数：按档案卡右列的实际宽度算，窗口变宽就多排一列。
    private func factsColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 12
        let width = width > 0 ? width : 620
        let count = max(1, GridLayout.columns(contentWidth: width, targetSize: 210, spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 120), spacing: spacing), count: count)
    }

    var body: some View {
        ZStack {
            pageContent
                .opacity(personTarget == nil ? 1 : 0)
                .allowsHitTesting(personTarget == nil)
            if let member = personTarget {
                // 演职员改成页面内二级页：不弹窗，顶栏「返回」逐层后退。
                CinemaPersonDetailView(
                    member: member,
                    onOpenEntry: { entry in
                        personTarget = nil
                        onOpenEntry(entry)
                    },
                    onPlay: onPlay
                )
                .id(member.id)
                .transition(.opacity)
            }
            if showTrailer, let request = trailerRequest {
                // 预告片在页面内播放：不打开浏览器。
                CinemaTrailerOverlay(request: request) {
                    showTrailer = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: personTarget?.id)
        .animation(.easeOut(duration: 0.16), value: showTrailer)
        // 悬停档案挂在整个详情页最上层（在 ScrollView 之外）：贴着集卡显示，
        // 但会被收进窗口可视范围，卡片在边缘时也不会被裁掉。
        .overlayPreferenceValue(CinemaEpisodeAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if personTarget == nil, !showTrailer,
                   // 窄窗口下浮层会盖住大半网格：直接不显示，信息仍在卡片与档案里。
                   proxy.size.width >= 820,
                   let episode = hoverPanelEpisode,
                   let anchor = anchors[episode.id] {
                    let rect = proxy[anchor]
                    let margin: CGFloat = 12
                    let gap: CGFloat = 14
                    let width = min(380, max(260, proxy.size.width * 0.36))
                    let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                    let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                    let x = min(max(margin, rawX), max(margin, proxy.size.width - width - margin))
                    let y = min(max(margin, rect.minY),
                                max(margin, proxy.size.height - hoverPanelHeight - margin))
                    episodeHoverCard(episode)
                        .frame(width: width)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { hoverPanelHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { _, height in
                                        hoverPanelHeight = height
                                    }
                            }
                        }
                        .offset(x: x, y: y)
                        // 换集时换成新的身份：面板就地淡入淡出，不会从上一张卡横着滑过来。
                        .id(episode.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                            removal: .opacity))
                        // 面板不吃鼠标事件：鼠标可以直接穿过它去选别的集卡，不会被挡住。
                        // 需要读完简介时，停在那一集上不动即可（停住不会触发别的卡片）。
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: hoverPanelEpisode?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaDetailTone.page)
        .task {
            let sample = series.episodes.first(where: { $0.backdropURL != nil })
                ?? series.episodes.first
            guard let sample else { return }
            enriched = await store.enrichCinemaEntry(sample)
            recommendationGroups = await store.cinemaRecommendationGroups(for: enriched ?? sample)
            // 打开详情时顺手补一次在线片头片尾：没设置过的剧集自动填上。
            await store.ensureCinemaIntroMark(for: series)
        }
        .task(id: seasonInfoKey) {
            // 切季 / 换剧后旧的键盘游标已经不在当前列表里；恢复上次位置时保留。
            if suppressSeasonReset {
                suppressSeasonReset = false
            } else {
                keyboardEpisodeID = nil
                hoveredEpisode = nil
            }
            await loadEpisodeInfos()
        }
        // 顶栏返回：先关预告片，再退演职员页，最后退剧集详情。
        .onChange(of: store.cinemaDetailCloseTick) { _, _ in
            if showTrailer {
                showTrailer = false
            } else if personTarget != nil {
                personTarget = nil
            } else {
                onClose()
            }
        }
        // 进播放器时把键盘交出去，回来后还给剧集网格。
        .onChange(of: store.viewerID) { _, viewing in
            episodeGridFocus = viewing == nil
        }
        .onChange(of: showTrailer) { _, showing in
            if !showing { episodeGridFocus = true }
        }
        .onChange(of: personTarget?.id) { _, current in
            if current == nil { episodeGridFocus = true }
        }
    }

    private var pageTopAnchor: String { "cinema-series-detail-top" }

    /// 详情页默认从顶部开始：不沿用上一部剧 / 上次浏览留下的滚动位置。
    private func scrollToPageTop(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(pageTopAnchor, anchor: .top)
        }
    }

    private var pageContent: some View {
        // 底图只能挂 background：它是 aspect-fill 的远程剧照，只锁了高度，
        // 图片加载完会带出「自然宽度」（760pt 高约等于 1350pt 宽）。
        // 一旦作为 ZStack 兄弟节点参与布局，整页就会被撑得比窗口更宽，
        // 表现为「先是占满，图片一出来就超过 100%，拖窗口也缩不回去」。
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // 顶部锚点：进入详情 / 切换到另一部剧时回到这里。
                        Color.clear
                            .frame(height: 0)
                            .id(pageTopAnchor)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(key: CinemaScrollOffsetKey.self,
                                                           value: geo.frame(in: .named("cinemaSeriesScroll")).minY)
                                }
                            }
                        dossierSection(width: width)
                        episodesSection(width: width)
                        let recommendGroups = visibleRecommendationGroups
                        if !recommendGroups.isEmpty {
                            CinemaRecommendationShelf(
                                groups: recommendGroups,
                                isLocal: { store.cinemaEntry(tmdbID: $0.tmdbID, kind: $0.kind) != nil },
                                onOpen: { recom in
                                    if let doubanID = recom.doubanID {
                                        store.openDoubanPage(doubanID: doubanID)
                                    } else if let local = store.cinemaEntry(tmdbID: recom.tmdbID,
                                                                           kind: recom.kind) {
                                        onOpenEntry(local)
                                    } else {
                                        searchOnlineCinema(recom)
                                    }
                                },
                                onSearchOnline: { searchOnlineCinema($0) },
                                onOpenExternal: { recom in
                                    if let doubanID = recom.doubanID {
                                        store.openDoubanPage(doubanID: doubanID)
                                    } else {
                                        searchOnlineCinema(recom)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, horizontal)
                    .padding(.bottom, 36)
                    // 只填满可视宽度，不能用固定 width：固定宽度会变成窗口的最小宽度，
                    // 窗口一缩就由「上一次的宽度」反推回来，拖到多大就再也缩不回去。
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .coordinateSpace(name: "cinemaSeriesScroll")
                .onPreferenceChange(CinemaScrollOffsetKey.self) { scrollOffset = $0 }
                // 键盘上下跨行要知道当前列数：跟着容器宽度一起更新。
                .onAppear {
                    contentWidth = width
                    restoreDetailState(scrollProxy)
                }
                .onChange(of: width) { _, newValue in contentWidth = newValue }
                .onChange(of: series.id) { _, _ in restoreDetailState(scrollProxy) }
                .onChange(of: currentSeason) { _, _ in saveDetailMemory() }
                .onChange(of: keyboardEpisodeID) { _, _ in saveDetailMemory() }
            }
        }
        .background(alignment: .top) { ambientBackground }
        .overlay(alignment: .top) { compactHeader }
        .animation(.easeOut(duration: 0.18), value: scrollOffset < -140)
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
                if request.kind == .poster {
                    artworkPosterOverride = url
                } else {
                    artworkBackdropOverride = url
                }
            }
        }
    }

    /// 剧集详情用剧照虚化铺底：贴着 Hero 往下渐隐到页面底色，
    /// 不再用固定高度硬切，避免中间出现一条突兀的亮色横带。
    private var ambientBackground: some View {
        ZStack(alignment: .top) {
            CinemaDetailTone.page
            CinemaArtwork(urlString: artworkBackdropOverride ?? series.backdropURL ?? series.posterURL,
                          contentMode: .fill,
                          maxPixelSize: 1100)
                .frame(height: 760)
                .blur(radius: 90, opaque: true)
                .opacity(0.20)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.80), location: 0.38),
                        .init(color: .black.opacity(0.28), location: 0.72),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// 滚过档案卡后浮出的紧凑标题条：片名 / 年份 / 评分，一直跟着滚动。
    @ViewBuilder
    private var compactHeader: some View {
        if scrollOffset < -140 {
            HStack(spacing: 8) {
                Text(series.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .lineLimit(1)
                if let year = series.year {
                    Text(String(year))
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                Spacer(minLength: 0)
                if let rating = seriesRating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.10))
                    .frame(height: 0.5)
            }
            .transition(.opacity)
        }
    }

    /// 换封面用的样本条目：优先已补全的那一集，其次任意已匹配的剧集。
    private var artworkSample: CinemaEntry? {
        enriched ?? series.episodes.first(where: { $0.matched && $0.tmdbID != nil })
    }

    /// 推荐分组：优先本次拉到的，其次条目缓存；旧数据只有 TMDB 列表时兜底成一个 tab。
    private var visibleRecommendationGroups: [CinemaRecommendationGroup] {
        if !recommendationGroups.isEmpty { return recommendationGroups }
        if let cached = enriched?.recommendationGroups, !cached.isEmpty { return cached }
        if let recs = enriched?.recommendations, !recs.isEmpty {
            return [CinemaRecommendationGroup(source: .tmdb, title: "猜你喜欢", items: recs)]
        }
        return []
    }

    /// 推荐条目本库没有时：网络影院还没上线，先给占位提示。
    private func searchOnlineCinema(_ recom: CinemaRecommendation) {
        store.searchOnlineCinema(recom.title)
    }

    private func loadArtwork(_ kind: CinemaArtworkKind) {
        guard let sample = artworkSample else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        // 候选由面板自己拉，这里只负责把请求递过去。
        artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
    }

    /// 返回详情时恢复上次看的季与选中集；没有记忆就回到顶部。
    private func restoreDetailState(_ proxy: ScrollViewProxy) {
        guard let memory = store.cinemaSeriesMemory[series.id] else {
            scrollToPageTop(proxy)
            return
        }
        if let season = memory.season, season != currentSeason {
            suppressSeasonReset = true
            selectedSeason = season
        }
        keyboardEpisodeID = memory.episodeID
        hoveredEpisode = memory.episodeID
        guard let id = memory.episodeID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private func saveDetailMemory() {
        store.cinemaSeriesMemory[series.id] = CinemaSeriesMemory(season: currentSeason,
                                                                 episodeID: keyboardEpisodeID)
    }

    private var seasonInfoKey: String {
        guard currentSeason > 0,
              let tvID = series.episodes.first(where: { $0.tmdbID != nil && $0.provider == .tmdb })?.tmdbID else { return "" }
        return "\(tvID)-\(currentSeason)"
    }

    /// 每集标题 / 简介 / 剧照：按当前标签页的季读取，切回其他季时直接用已缓存结果。
    private func loadEpisodeInfos() async {
        guard currentSeason > 0,
              let tvID = series.episodes.first(where: { $0.tmdbID != nil && $0.provider == .tmdb })?.tmdbID else { return }
        let season = currentSeason
        if let cached = store.cachedCinemaEpisodeInfos(tvID: tvID, season: season) {
            episodeInfos[season] = cached.infos
            if cached.fresh { return }
        }
        guard let refreshed = await store.refreshCinemaEpisodeInfos(tvID: tvID, season: season) else { return }
        guard !Task.isCancelled else { return }
        episodeInfos[season] = refreshed
    }

    // MARK: 季与下一集

    private var orderedEpisodes: [CinemaEntry] {
        series.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
    }

    /// 季标签：最新一季在最左（降序），打开页面默认就是它。
    private var seasons: [Int] {
        Array(Set(orderedEpisodes.map { $0.season ?? 0 })).sorted(by: >)
    }

    private var currentSeason: Int {
        selectedSeason ?? seasons.first ?? 0
    }

    private var visibleEpisodes: [CinemaEntry] {
        guard seasons.count > 1 else { return orderedEpisodes }
        return orderedEpisodes.filter { ($0.season ?? 0) == currentSeason }
    }

    /// 单集信息按「季 + 集号」取，切换季标签时不会串到别的季。
    private func episodeInfo(_ episode: CinemaEntry) -> CinemaEpisodeInfo? {
        guard let number = episode.episode else { return nil }
        return episodeInfos[episode.season ?? 0]?[number]
    }

    /// 悬停档案跟随哪一集：鼠标悬停和键盘选中共用同一个状态，
    /// 键盘切换时由 moveEpisodeCursor 把悬停集同步过来，档案才会跟着焦点走。
    private var hoverPanelEpisode: CinemaEntry? {
        guard let id = hoveredEpisode else { return nil }
        return visibleEpisodes.first(where: { $0.id == id })
    }

    /// 鼠标进入集卡或档案面板：取消待关闭，并把档案锁到这一集。
    private func holdHoverPanel(_ id: UUID) {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        if hoveredEpisode != id {
            hoveredEpisode = id
        }
    }

    /// 离开集卡：留一小段时间再收起，避免鼠标划过间隙时面板闪烁。
    private func scheduleHoverDismiss() {
        hoverDismissTask?.cancel()
        let work = DispatchWorkItem {
            hoveredEpisode = nil
        }
        hoverDismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 优先正在看的一集；否则接在最后看完的一集后面；全部看完返回 nil。
    private var nextEpisode: CinemaEntry? {
        let ordered = orderedEpisodes
        guard !ordered.isEmpty else { return nil }
        if let inProgress = ordered.first(where: { store.cinemaWatchState(for: $0) == .inProgress }) {
            return inProgress
        }
        if let lastFinished = ordered.lastIndex(where: { store.cinemaWatchState(for: $0) == .finished }) {
            let next = lastFinished + 1
            guard next < ordered.count else { return nil }
            return ordered[next]
        }
        return ordered.first
    }

    /// 跳过片头尾：和「继续播放 / 预告片」同高的胶囊，点开是滑杆面板。
    private var introSkipControl: some View {
        let mark = activeIntroMark
        return Button {
            showIntroPanel.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "scissors")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(LumaBrand.amber.opacity(mark.isEnabled ? 1 : 0.55))

                Text("跳过片头尾")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.94))

                Text(introSummaryText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(mark.isEnabled ? LumaBrand.amber.opacity(0.95)
                                                    : CinemaDetailTone.ink.opacity(0.45))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 170)
            .background {
                Capsule()
                    .fill(mark.isEnabled ? LumaBrand.amber.opacity(0.16)
                                         : CinemaDetailTone.ink.opacity(0.14))
            }
            .overlay {
                Capsule()
                    .strokeBorder(mark.isEnabled ? LumaBrand.amber.opacity(0.42)
                                                 : CinemaDetailTone.ink.opacity(0.10),
                                  lineWidth: 0.7)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showIntroPanel, arrowEdge: .bottom) {
            introSkipPanel
        }
        .help("设置片头 / 片尾跳过的秒数；可以按整部剧或只对当前集生效")
    }

    private var introSummaryText: String {
        let mark = activeIntroMark
        guard mark.isEnabled else { return "未设置" }
        var parts: [String] = []
        if mark.introSeconds > 0 { parts.append("片头 \(mark.introSeconds)s") }
        if mark.outroSeconds > 0 { parts.append("片尾 \(mark.outroSeconds)s") }
        return parts.joined(separator: " · ")
    }

    /// 调节面板：滑杆直接改秒数，自动识别、范围与清除都在这一处。
    private var introSkipPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "scissors")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LumaBrand.amber)
                Text("跳过片头片尾")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                Circle()
                    .fill(activeIntroMark.isEnabled ? LumaBrand.mint : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(activeIntroMark.isEnabled ? "已启用" : "已关闭")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text("开播时自动跳到片头结束；进入片尾区间时直接跳到结尾。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            introSliderRow(title: "片头", seconds: introSecondsBinding)
            introSliderRow(title: "片尾", seconds: outroSecondsBinding)

            HStack(spacing: 8) {
                Text("作用范围")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $introScope) {
                    Text("整部剧").tag(IntroScope.series)
                    Text(introTargetEpisode.map { "本集 \(episodeLabel($0))" } ?? "本集")
                        .tag(IntroScope.episode)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Spacer(minLength: 0)
            }
            if introScope == .episode {
                Text(activeIntroIsOverride
                     ? "本集使用单独设置，修改只影响这一集。"
                     : "本集尚未单独设置，修改后自动成为本集设置。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Button {
                    Task { await runIntroAutoDetect() }
                } label: {
                    Label(detectingIntro ? "识别中…" : "自动识别", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(detectingIntro)

                if canClearIntro {
                    Button("清除") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if introScope == .episode, let episode = introTargetEpisode {
                                store.clearCinemaEpisodeIntroMark(for: episode)
                            } else {
                                store.setCinemaIntroMark(CinemaIntroMark(), forSeriesKey: series.id)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func introSliderRow(title: String, seconds: Binding<Int>) -> some View {
        let value = Binding<Double>(
            get: { Double(seconds.wrappedValue) },
            set: { seconds.wrappedValue = Int($0.rounded()) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 0)
                Text(seconds.wrappedValue > 0 ? "\(seconds.wrappedValue) 秒" : "关闭")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(seconds.wrappedValue > 0 ? LumaBrand.amber : Color.secondary)
            }
            Slider(value: value, in: 0...300, step: 15)
                .tint(LumaBrand.amber)
                .controlSize(.small)
        }
    }

    /// 单集覆盖的目标：优先「当前集（下一集）」，否则第一集。
    private var introTargetEpisode: CinemaEntry? {
        nextEpisode ?? orderedEpisodes.first
    }

    private var activeIntroMark: CinemaIntroMark {
        if introScope == .episode, let episode = introTargetEpisode {
            return store.cinemaIntroMark(for: episode)
        }
        return store.cinemaIntroMark(forSeriesKey: series.id)
    }

    private var activeIntroIsOverride: Bool {
        guard introScope == .episode, let episode = introTargetEpisode else { return false }
        return store.hasCinemaEpisodeIntroMark(for: episode)
    }

    private var canClearIntro: Bool {
        if introScope == .episode, let episode = introTargetEpisode {
            return store.hasCinemaEpisodeIntroMark(for: episode)
        }
        return store.cinemaIntroMark(forSeriesKey: series.id).isEnabled
    }

    private func applyIntroMark(_ mark: CinemaIntroMark) {
        if introScope == .episode, let episode = introTargetEpisode {
            store.setCinemaIntroMark(mark, for: episode)
        } else {
            store.setCinemaIntroMark(mark, forSeriesKey: series.id)
        }
    }

    /// 自动识别：整部剧取第一集，本集取当前这一集；在线库优先，本地静音检测兜底。
    private func runIntroAutoDetect() async {
        guard !detectingIntro else { return }
        detectingIntro = true
        // 本地静音检测要跑几十秒：登记进任务中心，切换页面后仍能看到进度。
        let jobID = store.beginSourceJob(
            SourceJob(sourceID: store.sourceID(for: store.cinemaActiveScope),
                      kind: .analyze,
                      title: "片头自动识别",
                      isCancellable: false)
        )
        defer {
            detectingIntro = false
            store.finishSourceJob(jobID, message: "片头识别完成")
        }
        let episode = introScope == .episode ? introTargetEpisode : nil
        let detection: LibraryStore.CinemaIntroDetection?
        if let episode {
            detection = await store.detectCinemaIntro(for: episode)
        } else {
            detection = await store.detectCinemaIntro(for: series)
        }
        guard let detection else {
            store.showToast(episode == nil
                            ? "在线库没有这部剧的记录，且没有可分析的本地分集；可手动设置"
                            : "在线库没有这一集的记录，且不是可分析的本地文件；可手动设置")
            return
        }
        let mark = detection.mark
        if let episode {
            store.setCinemaIntroMark(mark, for: episode)
        } else {
            store.setCinemaIntroMark(mark, forSeriesKey: series.id)
        }
        let intro = mark.introSeconds > 0 ? "片头 \(mark.introSeconds) 秒" : "片头未识别"
        let outro = mark.outroSeconds > 0 ? "片尾 \(mark.outroSeconds) 秒" : "片尾未识别"
        let source = detection.online ? "在线库" : "本地静音检测"
        let scope = episode.map { " · \(episodeLabel($0))" } ?? ""
        store.showToast("自动识别完成（\(source)\(scope)）：\(intro) · \(outro)")
    }

    private var introSecondsBinding: Binding<Int> {
        Binding(
            get: { activeIntroMark.introSeconds },
            set: { value in
                var mark = activeIntroMark
                mark.introSeconds = value
                applyIntroMark(mark)
            }
        )
    }

    private var outroSecondsBinding: Binding<Int> {
        Binding(
            get: { activeIntroMark.outroSeconds },
            set: { value in
                var mark = activeIntroMark
                mark.outroSeconds = value
                applyIntroMark(mark)
            }
        )
    }

    /// 预告片按整部剧找：用详情补全后的条目，没有就退回本剧第一条已识别分集。
    private var trailerRequest: CinemaTrailerRequest? {
        let sample = enriched
            ?? series.episodes.first(where: { $0.backdropURL != nil })
            ?? series.episodes.first
        guard let sample, sample.matched else { return nil }
        return CinemaTrailerRequest(title: sample.title,
                                    originalTitle: sample.originalTitle,
                                    year: sample.year ?? series.year,
                                    isTV: sample.kind == .tv)
    }

    private func castStrip(_ cast: [CinemaCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                if let directors = enriched?.directors, !directors.isEmpty {
                    Text("导演 " + directors.prefix(2).joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        CinemaCastTile(member: member,
                                       onOpen: { personTarget = member },
                                       onSearchOnline: { store.searchOnlineCinema(member.name) })
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func posterCard(width: CGFloat, height: CGFloat) -> some View {
        let radius: CGFloat = width > 100 ? 10 : 5
        return ZStack {
            if let url = artworkPosterOverride ?? series.posterURL {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let first = series.episodes.first {
                PhotoThumbnailView(photo: first.file.photoItem, purpose: .cover(240))
            } else {
                CinemaDetailTone.ink.opacity(0.06)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.26), lineWidth: 1)
        }
        .contextMenu {
            Button("选择海报…") { loadArtwork(.poster) }
            Button("选择背景…") { loadArtwork(.backdrop) }
        }
        .shadow(color: CinemaDetailTone.shadow(0.5),
                radius: width > 100 ? 18 : 8,
                y: width > 100 ? 8 : 3)
    }

    private var actions: some View {
        // 一行放不下时自动换行：窄窗口下「跳过片头尾」不会和「预告片」叠在一起。
        CinemaBadgeFlow(spacing: 9, lineSpacing: 9) {
            if let next = nextEpisode {
                Button {
                    onPlay(next)
                } label: {
                    Label(playLabel(for: next), systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(LumaBrand.amber, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if let first = orderedEpisodes.first, first.id != nextEpisode?.id {
                Button {
                    onPlay(first)
                } label: {
                    Label("从第 1 集开始", systemImage: "backward.end.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(0.16), in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.94))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if trailerRequest != nil {
                Button {
                    showTrailer = true
                } label: {
                    Label("预告片", systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(0.14), in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if !orderedEpisodes.isEmpty {
                // 跳过片头尾和预告片同一行：点开就是滑杆面板，不需要记菜单层级。
                introSkipControl
            }
        }
    }

    private func playLabel(for episode: CinemaEntry) -> String {
        if let progress = store.cinemaProgress[episode.id],
           progress.fraction > 0.01, !progress.isFinished {
            return "继续播放 \(episodeLabel(episode))"
        }
        return "开始观看 \(episodeLabel(episode))"
    }

    /// 季标签栏：最新一季在最左；每枚标签带集数与观看进度，横排可滚动。
    private var seasonTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.self) { season in
                    seasonTab(season)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func seasonTab(_ season: Int) -> some View {
        let episodes = orderedEpisodes.filter { ($0.season ?? 0) == season }
        let watched = episodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
        let fraction = episodes.isEmpty ? 0 : Double(watched) / Double(episodes.count)
        let active = season == currentSeason
        let isLatest = season == seasons.first
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { selectedSeason = season }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(season == 0 ? "未标季" : "第 \(season) 季")
                        .font(.system(size: 12, weight: .semibold))
                    if isLatest, season > 0 {
                        Text("最新")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.black.opacity(0.78))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(LumaBrand.amber, in: Capsule())
                    }
                    Text("\(episodes.count) 集")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(active ? LumaBrand.amber.opacity(0.95) : .secondary)
                }
                // 细进度线：一眼看出哪一季看到哪。
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(CinemaDetailTone.ink.opacity(0.12))
                        if fraction > 0 {
                            Capsule()
                                .fill(LumaBrand.amber.opacity(active ? 1 : 0.6))
                                .frame(width: max(2, geo.size.width * fraction))
                        }
                    }
                }
                .frame(height: 2.5)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(active ? LumaBrand.amber.opacity(0.16) : CinemaDetailTone.ink.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(active ? LumaBrand.amber.opacity(0.55)
                                         : CinemaDetailTone.ink.opacity(0.07),
                                  lineWidth: active ? 1 : 0.6)
            }
            .foregroundStyle(active ? LumaBrand.amber : CinemaDetailTone.ink.opacity(0.86))
        }
        .buttonStyle(.plain)
        .help(season == 0 ? "未标季" : "切换到第 \(season) 季")
    }

    private func episodesSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题与季标签同一行：最新一季在最左，切换只影响下方网格。
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("剧集")
                    .font(.system(size: 15, weight: .semibold))
                if seasons.count > 1 {
                    seasonTabBar
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let season = seasons.first {
                    Text(season == 0 ? "未标季" : "第 \(season) 季")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                    Text("\(visibleEpisodes.count) 集")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                }
                if hoveredEpisode == nil, contentWidth >= 760 {
                    Text("方向键切集 · 空格播放")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            ScrollViewReader { scrollProxy in
                LazyVGrid(columns: episodeColumns(width: width), alignment: .leading, spacing: 18) {
                    ForEach(visibleEpisodes) { episode in
                        episodeCard(episode)
                            .anchorPreference(key: CinemaEpisodeAnchorKey.self, value: .bounds) {
                                [episode.id: $0]
                            }
                            .id(episode.id)
                    }
                }
                // 和图库网格一致的键盘操作：← → 逐集，↑ ↓ 跨一行，空格 / 回车播放。
                .focusable()
                .focused($episodeGridFocus)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) {
                    moveEpisodeCursor(-1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    moveEpisodeCursor(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveEpisodeCursor(-episodeColumnCount)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveEpisodeCursor(episodeColumnCount)
                    return .handled
                }
                .onKeyPress(.space) {
                    playFocusedEpisode()
                    return .handled
                }
                .onKeyPress(.return) {
                    playFocusedEpisode()
                    return .handled
                }
                .onChange(of: keyboardEpisodeID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollProxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async { episodeGridFocus = true }
                }
                // 切季后把视口带回该季第一集，别停在上一季的滚动位置。
                .onChange(of: currentSeason) { _, _ in
                    guard let first = visibleEpisodes.first else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrollProxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            Diagnostics.record("影院剧集网格 width=\(Int(width)) "
                               + "列数=\(episodeColumns(width: width).count) "
                               + "集=\(visibleEpisodes.count)")
        }
    }

    /// 方向键跨一行要跳几列：和外层量到的宽度保持同一套列数规则。
    private var episodeColumnCount: Int {
        episodeColumns(width: contentWidth).count
    }

    private func moveEpisodeCursor(_ delta: Int) {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        let list = visibleEpisodes
        guard !list.isEmpty else { return }
        guard let id = keyboardEpisodeID,
              let current = list.firstIndex(where: { $0.id == id }) else {
            // 还没有游标：先从「下一集」开始。
            let target = nextEpisode ?? list[0]
            keyboardEpisodeID = target.id
            hoveredEpisode = target.id
            return
        }
        let next = min(max(current + delta, 0), list.count - 1)
        keyboardEpisodeID = list[next].id
        // 键盘切换时把悬停指针一起挪过去，档案面板跟着焦点走而不是停在鼠标下面。
        hoveredEpisode = list[next].id
    }

    private func playFocusedEpisode() {
        guard store.viewerID == nil else { return }
        let list = visibleEpisodes
        guard !list.isEmpty else { return }
        if let id = keyboardEpisodeID, let episode = list.first(where: { $0.id == id }) {
            onPlay(episode)
        } else if let target = nextEpisode ?? list.first {
            onPlay(target)
        }
    }

    // MARK: 剧集档案

    /// 剧集档案：把海报、简介、资料与演职员收进同一张卡片。
    /// 海报作视觉锚点，右侧按「原名 / 宣传语 → 简介 → 带图标的资料网格」排，
    /// 底部接演职员，不再让三块内容各占一整行。
    private func dossierSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 窄窗口把海报与资料改成上下排列，文字列不会被压成一条缝。
            if width < 760 {
                VStack(alignment: .leading, spacing: 18) {
                    dossierPosterColumn
                    dossierInfoColumn(width: max(280, width - 44))
                }
                .padding(22)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    dossierPosterColumn
                    dossierInfoColumn(width: width - 22 * 2 - 156 - 24)
                }
                .padding(22)
            }

            if let cast = enriched?.cast, !cast.isEmpty {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                castStrip(cast)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
        }
        .background { dossierPlate }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            CinemaDetailTone.ink.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 档案卡右侧信息列：标题、简介与资料网格共用，窄窗口时也可单独铺满整行。
    private func dossierInfoColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            dossierKicker
            dossierTitleBlock
            dossierSynopsis
            dossierFactsGrid(width: width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 档案卡底板：玻璃底 + 左上角一层很淡的琥珀光，和海报的暖色调衔接。
    private var dossierPlate: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.062),
                                          CinemaDetailTone.ink.opacity(0.022)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
    }

    /// 海报 + 评分牌 + 整剧观看进度：三者共用一列，宽度和海报对齐。
    private var dossierPosterColumn: some View {
        VStack(spacing: 9) {
            posterCard(width: 156, height: 234)
                .shadow(color: LumaBrand.amber.opacity(0.18), radius: 22, y: 10)

            if let rating = seriesRating {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(CinemaDetailTone.ink)
                    if let votes = enriched?.voteCount, votes > 0 {
                        Text("· \(voteCountText(votes))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
                }
            }

            if watchedCount > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: Double(watchedCount),
                                 total: Double(max(1, orderedEpisodes.count)))
                        .progressViewStyle(.linear)
                        .tint(LumaBrand.amber)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    Text("已看 \(watchedCount) / \(orderedEpisodes.count) 集")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                .frame(width: 156)
            }
        }
        .frame(width: 156, alignment: .top)
    }

    /// 档案抬头：琥珀刻字标签 + 年份 / 季 / 集 + 播出状态。
    private var dossierKicker: some View {
        HStack(spacing: 8) {
            Text("剧集档案")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(CinemaDetailTone.accent.opacity(0.92))
            Rectangle()
                .fill(LumaBrand.amber.opacity(0.35))
                .frame(width: 24, height: 0.8)
            Text(dossierMetaLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
            dossierStatusPill
        }
    }

    /// 片名 / 原名 / 宣传语 / 播放动作：去掉大幅剧照后，这一块承担页面标题。
    private var dossierTitleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(series.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(CinemaDetailTone.ink)
                .lineLimit(2)
                .textSelection(.enabled)

            if let original = enriched?.originalTitle,
               !original.isEmpty,
               original.caseInsensitiveCompare(series.title) != .orderedSame {
                Text(original.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                    .lineLimit(1)
            }

            if let tagline = enriched?.tagline, !tagline.isEmpty {
                Text("「\(tagline)」")
                    .font(.system(size: 12, weight: .medium))
                    .italic()
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
                    .lineLimit(2)
            }

            actions
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var dossierStatusPill: some View {
        if let status = cinemaStatusText(enriched?.status) {
            let running = enriched?.status == "Returning Series"
                || enriched?.status == "In Production"
                || enriched?.status == "Planned"
            HStack(spacing: 5) {
                Circle()
                    .fill(running ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.32))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(running ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.72))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CinemaDetailTone.ink.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
        }
    }

    /// 简介：默认收 5 行，长简介可展开；没有简介时提示换数据源。
    @ViewBuilder
    private var dossierSynopsis: some View {
        let overview = enriched?.overview ?? series.overview ?? ""
        if overview.isEmpty {
            Text("暂无剧情简介。可以在顶栏面板里「重新匹配」换一个数据源，通常会补全简介与演职员。")
                .font(.system(size: 12))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(overview)
                    .font(.system(size: 12.8))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.78))
                    .lineSpacing(6)
                    .lineLimit(dossierExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if overview.count > 180 {
                    Button(dossierExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            dossierExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        }
    }

    /// 资料网格：每项一枚琥珀小图标 + 标签 / 值，和海报卡同一张底板上。
    private func dossierFactsGrid(width: CGFloat) -> some View {
        LazyVGrid(columns: factsColumns(width: width),
                  alignment: .leading, spacing: 12) {
            ForEach(dossierFacts) { fact in
                HStack(spacing: 9) {
                    Image(systemName: fact.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.accent.opacity(0.90))
                        .frame(width: 24, height: 24)
                        .background(LumaBrand.amber.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.38))
                        Text(fact.value)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.82))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
        // 资料网格跟随可用宽度重排列数：宽窗口多排几列，不会只挤在左边。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct DossierFact: Identifiable {
        let icon: String
        let label: String
        let value: String
        var id: String { label + "|" + value }
    }

    /// 本地与 TMDB 能拿到的资料项都在这里，缺哪项就不占位。
    private var dossierFacts: [DossierFact] {
        var items: [DossierFact] = []
        if let value = cinemaDateText(enriched?.releaseDate) ?? series.year.map({ "\($0) 年" }) {
            items.append(DossierFact(icon: "calendar", label: "首播", value: value))
        }
        if let value = seasonCountText {
            items.append(DossierFact(icon: "rectangle.stack", label: "季数", value: value))
        }
        if let value = episodeCountText {
            items.append(DossierFact(icon: "list.number", label: "集数", value: value))
        }
        if let value = cinemaMinutesText(enriched?.runtime) {
            items.append(DossierFact(icon: "clock", label: "单集", value: value))
        }
        let sampleFile = enriched?.file ?? series.episodes.first?.file
        if let value = sampleFile?.displayTags.first(where: { $0 == "DV" || $0.hasPrefix("HDR") }) {
            items.append(DossierFact(icon: "sparkles.tv",
                                     label: "HDR",
                                     value: value == "DV" ? "Dolby Vision" : value))
        }
        if sampleFile?.displayTags.contains("Atmos") == true {
            items.append(DossierFact(icon: "hifispeaker.2", label: "音轨", value: "Dolby Atmos"))
        }
        if let fps = sampleFile?.parsedFrameRate {
            items.append(DossierFact(icon: "speedometer", label: "帧率", value: "\(fps) fps"))
        }
        if let value = enriched?.genres?.prefix(4).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "theatermasks", label: "类型", value: value))
        }
        if let value = enriched?.certification, !value.isEmpty {
            items.append(DossierFact(icon: "shield.lefthalf.filled", label: "分级", value: value))
        }
        if let value = cinemaLanguageName(enriched?.originalLanguage) {
            items.append(DossierFact(icon: "character.bubble", label: "语言", value: value))
        }
        if let countries = enriched?.countries, !countries.isEmpty {
            let value = countries.prefix(2).map(cinemaCountryName).joined(separator: " / ")
            items.append(DossierFact(icon: "globe.asia.australia", label: "国家", value: value))
        }
        if let value = enriched?.networks?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "antenna.radiowaves.left.and.right", label: "平台", value: value))
        }
        if let value = enriched?.companies?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "building.2", label: "制作", value: value))
        }
        if let value = enriched?.collectionName, !value.isEmpty {
            items.append(DossierFact(icon: "square.stack.3d.up", label: "合集", value: value))
        }
        if let id = enriched?.tmdbID {
            let label = enriched?.provider == .tvdb ? "TVDB" : "TMDB"
            items.append(DossierFact(icon: "number", label: label, value: "\(id)"))
        }
        return items
    }

    private var dossierMetaLine: String {
        var parts: [String] = []
        if let year = enriched?.year ?? series.year, year > 0 {
            parts.append("\(year)")
        }
        if let seasons = seasonCountText {
            parts.append(seasons)
        }
        if let episodes = episodeCountText {
            parts.append(episodes)
        }
        return parts.joined(separator: " · ")
    }

    private var seriesRating: Double? {
        let rating = enriched?.rating ?? series.rating
        guard let rating, rating > 0 else { return nil }
        return rating
    }

    private var watchedCount: Int {
        orderedEpisodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
    }

    private func voteCountText(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f 万人评分", Double(votes) / 10_000)
        }
        return "\(votes) 人评分"
    }

    private var seasonCountText: String? {
        let count = enriched?.seasonCount ?? (seasons.filter { $0 > 0 }.isEmpty ? nil : seasons.filter { $0 > 0 }.count)
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 季" : "\(count) 季"
    }

    private var episodeCountText: String? {
        let total = enriched?.episodeTotal ?? series.episodeCount
        return total > 0 ? "\(total) 集" : nil
    }

    private func minutesText(_ duration: Double?) -> String? {
        guard let duration, duration > 0 else { return nil }
        let minutes = Int((duration / 60).rounded())
        return minutes > 0 ? "\(minutes) 分钟" : nil
    }

    private func episodeCard(_ episode: CinemaEntry) -> some View {
        let watchState = store.cinemaWatchState(for: episode)
        let progress = store.cinemaProgress[episode.id]
        let hovered = hoveredEpisode == episode.id
        // 文档约定：当前集用琥珀描边标出，不靠 hover 才看得出「接着看哪一集」。
        let isCurrent = nextEpisode?.id == episode.id
        let info = episodeInfo(episode)
        // 单集剧照优先：TMDB 季接口给的 still 比整部剧的 backdrop 更能区分每一集。
        let artworkURL = info?.stillURL ?? episode.gridArtworkURL
        // 观看状态压在画面里，卡片下面不再重复一行「集号 + 未看」。
        let statusText: String = {
            if watchState == .finished { return "已看完" }
            if let progress, progress.fraction > 0.01 { return "上次看到 \(Int(progress.fraction * 100))%" }
            return isCurrent ? "当前集" : "未看"
        }()
        return Button {
            // 悬停即出现播放按钮，单击直接开播。
            onPlay(episode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            Group {
                                if let artworkURL {
                                    CinemaArtwork(urlString: artworkURL, contentMode: .fill)
                                } else {
                                    PhotoThumbnailView(photo: episode.file.photoItem, purpose: .cover(300))
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .opacity(watchState == .finished ? 0.70 : 1)

                    Text(episodeShortLabel(episode))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                }
                .overlay(alignment: .topLeading) {
                    // 状态标记从卡片下方挪进画面：未看 / 上次看到 N% / 已看完 / 当前集。
                    Text(statusText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(watchState == .finished ? LumaBrand.mint
                                         : (isCurrent || (progress?.fraction ?? 0) > 0.01
                                            ? LumaBrand.amber : Color.white.opacity(0.88)))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            if let progress, progress.fraction > 0.01 {
                                Rectangle()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(2.0, geo.size.width * progress.fraction))
                            }
                        }
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                }
                .overlay(alignment: .center) {
                    if hovered {
                        episodePlayBadge()
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            hovered ? LumaBrand.amber.opacity(0.7)
                                : (isCurrent ? LumaBrand.amber.opacity(0.85)
                                             : Color.primary.opacity(0.08)),
                            lineWidth: hovered ? 1.2 : (isCurrent ? 1.6 : 0.6))
                }
                .shadow(color: hovered ? LumaBrand.amber.opacity(0.25) : .clear,
                        radius: 10, y: 2)

                Text(episodeTitleText(episode, info: info))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovering in
            if hovering {
                holdHoverPanel(episode.id)
            } else if hoveredEpisode == episode.id {
                scheduleHoverDismiss()
            }
        }
        .help("播放 \(episodeLabel(episode))")
        .modifier(CinemaFocusRing(active: keyboardEpisodeID == episode.id))
        .contextMenu {
            Button("播放") { onPlay(episode) }
            Button(store.cinemaProgress[episode.id]?.isFinished == true ? "标记为未看" : "标记为已看") {
                let watched = store.cinemaProgress[episode.id]?.isFinished != true
                store.setCinemaWatched(episode, watched: watched)
            }
            Button("忽略（以后不刮削）") { store.ignoreCinemaEntry(episode) }
            Divider()
            Button("删除视频文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries([episode], title: episodeLabel(episode))
            }
        }
    }

    /// 集卡中央的播放按钮：悬停时出现，单击直接开播。
    private func episodePlayBadge() -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.44))
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white)
                .offset(x: 1)
        }
        .frame(width: 42, height: 42)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private func episodeTitleText(_ episode: CinemaEntry, info: CinemaEpisodeInfo?) -> String {
        if let title = info?.title, !title.isEmpty { return title }
        if let number = episode.episode { return "第 \(number) 集" }
        return "未命名单集"
    }

    private func episodeLabel(_ episode: CinemaEntry) -> String {
        if let season = episode.season, let number = episode.episode {
            if let end = episode.episodeEnd, end > number {
                return String(format: "S%02dE%02d-E%02d", season, number, end)
            }
            return String(format: "S%02dE%02d", season, number)
        }
        if let number = episode.episode { return String(format: "EP%02d", number) }
        return "EP"
    }

    /// 集卡角标：季已经由标签栏标明，卡片上只写「第 N 集」。
    private func episodeShortLabel(_ episode: CinemaEntry) -> String {
        guard let number = episode.episode else { return "EP" }
        if let end = episode.episodeEnd, end > number {
            return "第 \(number)–\(end) 集"
        }
        return "第 \(number) 集"
    }

    // MARK: 悬停档案

    /// 悬停集卡时弹出的完整档案：剧照、完整简介、进度、规格与文件名一次看全。
    /// 宽度固定、浮在卡片侧边，鼠标本身仍在集卡上，所以不做交互（避免遮挡点击）。
    private func episodeHoverCard(_ episode: CinemaEntry) -> some View {
        let info = episodeInfo(episode)
        let progress = store.cinemaProgress[episode.id]
        let artworkURL = info?.stillURL ?? episode.gridArtworkURL
        let tags = cinemaBadgeTags(episode.file, limit: 4)
        let overview = info?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            // 剧照上只留标签，不再压标题：标题挪到正文区，靠深底提升可读性。
            Group {
                if let artworkURL {
                    CinemaArtwork(urlString: artworkURL, contentMode: .fill)
                } else {
                    PhotoThumbnailView(photo: episode.file.photoItem, purpose: .cover(480))
                }
            }
            .frame(height: 158)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 62)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(episodeShortLabel(episode))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(LumaBrand.amber, in: Capsule())
                    if let progress, progress.isFinished {
                        hoverChip("已看完", tint: LumaBrand.mint, darkText: true)
                    } else if let progress, progress.fraction > 0.01 {
                        hoverChip("上次看到 \(Int(progress.fraction * 100))%")
                    } else {
                        hoverChip("未看")
                    }
                }
                .padding(11)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(episodeTitleText(episode, info: info))
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress, progress.fraction > 0.01 {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(CinemaDetailTone.ink.opacity(0.14))
                                Capsule()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(3, geo.size.width * progress.fraction))
                            }
                        }
                        .frame(height: 3)
                        HStack(spacing: 6) {
                            Text(progress.isFinished ? "已看完整集" : "已看 \(Int(progress.fraction * 100))%")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(LumaBrand.amber)
                            Spacer(minLength: 0)
                            if !progress.isFinished,
                               let remaining = minutesText(progress.remainingSeconds) {
                                Text("剩余 \(remaining)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
                            }
                        }
                    }
                }

                if overview.isEmpty {
                    Text("暂无单集简介")
                        .font(.system(size: 12.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                } else {
                    // 正文按阅读习惯排版：字号 12.5、行距 6.5、颜色更亮，长段落更好读。
                    Text(overview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                        .lineSpacing(6.5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tags.isEmpty {
                    CinemaSpecBadges(tags: tags, fontSize: 9, tint: CinemaDetailTone.ink,
                                     background: CinemaDetailTone.ink.opacity(0.10))
                }

                HStack(spacing: 12) {
                    if let minutes = minutesText(episode.file.duration) {
                        hoverFact("clock", minutes)
                    }
                    if episode.file.fileSize > 0 {
                        hoverFact("internaldrive",
                                  ByteCountFormatter.string(fromByteCount: episode.file.fileSize,
                                                            countStyle: .file))
                    }
                    hoverFact(episode.file.isCloud ? "cloud" : "folder",
                              episode.file.isCloud ? "网盘" : "本地")
                    Spacer(minLength: 0)
                }

                let techFacts = hoverTechFacts(episode.file)
                if !techFacts.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(techFacts, id: \.text) { fact in
                            hoverFact(fact.icon, fact.text)
                        }
                        Spacer(minLength: 0)
                    }
                }

                // 路径用「来源胶囊 + 目录链」展示：中间省略，可选中复制。
                if let location = hoverFileLocation(episode) {
                    HStack(spacing: 6) {
                        Image(systemName: location.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber.opacity(0.82))
                        Text(location.source)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.88))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(CinemaDetailTone.ink.opacity(0.10), in: Capsule())
                        Text(location.path)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.58))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(CinemaDetailTone.ink.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.6)
                    .padding(.top, 1)

                HStack(spacing: 5) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 9, weight: .semibold))
                    Text("点一下选中 · 再点一下播放")
                        .font(.system(size: 10))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.48))

                Text(episode.file.filename)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.28))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 14)
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(CinemaDetailTone.plate)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.06),
                                                      CinemaDetailTone.ink.opacity(0.015)],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.26), lineWidth: 0.8)
        }
        .shadow(color: CinemaDetailTone.shadow(0.58), radius: 26, y: 13)
    }

    private func hoverChip(_ text: String, tint: Color = .white, darkText: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(darkText ? Color.black : tint.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(darkText ? 1 : 0.18), in: Capsule())
    }

    private func hoverFact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(LumaBrand.amber.opacity(0.75))
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
        }
    }

    /// 悬停档案的技术信息：分辨率 / 编码 / 码率（按文件大小与时长估算）。
    private func hoverTechFacts(_ file: CinemaFile) -> [(icon: String, text: String)] {
        var facts: [(icon: String, text: String)] = []
        if file.pixelWidth > 0, file.pixelHeight > 0 {
            facts.append(("rectangle.inset.filled", "\(file.pixelWidth)×\(file.pixelHeight)"))
        }
        if let codec = file.videoCodec, !codec.isEmpty {
            facts.append(("film", codec.uppercased()))
        }
        if let duration = file.duration, duration > 1, file.fileSize > 0 {
            let mbps = Double(file.fileSize) * 8 / duration / 1_000_000
            facts.append(("speedometer", String(format: "≈ %.0f Mbps", mbps)))
        }
        return facts
    }

    /// 悬停档案的存放位置：网盘名 + 目录链；本地用刮削时的目录提示。
    private func hoverFileLocation(_ episode: CinemaEntry) -> (icon: String, source: String, path: String)? {
        let file = episode.file
        if let mountID = file.cloudMountID {
            let name = store.cloudMounts.first(where: { $0.id == mountID })?.name ?? "网盘"
            let raw = file.cloudPath ?? ""
            let folder = (raw as NSString).deletingLastPathComponent
            let path = folder.isEmpty ? (episode.folderHint ?? raw) : folder
            return ("cloud", name, path.isEmpty ? "/" : path)
        }
        if let hint = episode.folderHint, !hint.isEmpty {
            return ("folder", "本地", hint)
        }
        return ("folder", "本地", "图库")
    }
}

// MARK: - 主视觉卡片

private struct CinemaHeroCard: View {
    let entry: CinemaEntry
    let onPlay: () -> Void
    let onDetail: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: entry.backdropURL ?? entry.posterURL, contentMode: .fill)
                .frame(height: 260)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.30), .black.opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    if let rating = entry.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                    if entry.kind == .tv {
                        Text("剧集")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                let heroTags = cinemaBadgeTags(entry.file)
                if !heroTags.isEmpty {
                    CinemaSpecBadges(tags: heroTags,
                                     fontSize: 10.5,
                                     background: .white.opacity(0.16))
                        .frame(maxWidth: 620, alignment: .leading)
                }
                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.white.opacity(hover ? 0.95 : 0.88), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .onHover { hover = $0 }

                    Button(action: onDetail) {
                        Label("详情", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onDetail)
    }
}

// MARK: - 海报卡片

private struct CinemaPosterCard: View {
    let entry: CinemaEntry
    /// 同版本文件数：由聚合快照算好传入，卡片不再自己扫描整个影院索引。
    let versionCount: Int
    /// 海报墙里跟随网格列宽；书架里固定 156×234。
    var fillWidth: Bool = false
    let onOpen: () -> Void
    var onPlay: (() -> Void)? = nil
    var onDetail: (() -> Void)? = nil

    @EnvironmentObject private var store: LibraryStore
    @AppStorage("cinema_show_rating_badge") private var showRatingBadge = true
    @AppStorage("cinema_show_format_badge") private var showFormatBadge = true
    /// 悬停状态留在卡片内部：只有这张卡重绘，不会带着整页聚合一起重算。
    @State private var hovered = false
    /// 右键「手动刮削」打开的选片面板。
    @State private var showMatchSheet = false
    /// 右键「更换海报 / 背景」的候选面板。
    @State private var artworkRequest: CinemaArtworkPickerRequest?

    private var badgeTags: [String] {
        cinemaBadgeTags(entry.file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if entry.artworkURL != nil {
                        CinemaArtwork(urlString: entry.artworkURL, contentMode: .fill)
                    } else {
                        // 没匹配到海报时先显示视频自己的缩略图，至少能看见内容。
                        PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(156))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.10), .black.opacity(0.72)],
                               startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                // 底部片名 / 副标题整体上移，避免被卡片下沿和海报自带的片名压住。
                .padding(.horizontal, 9)
                .padding(.top, 9)
                .padding(.bottom, 16)

                VStack {
                    // 左上铺满画质 / 音质 / 类型角标（可换行），右上只留评分与版本。
                    // 左角标用 maxWidth 而不是定宽：窄卡片时先压缩它，评分 / 未识别角标不会被挤出卡片。
                    HStack(alignment: .top, spacing: 5) {
                        if showFormatBadge {
                            CinemaSpecBadges(tags: badgeTags, fontSize: 8)
                                .frame(maxWidth: 102, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            if versionCount > 1 {
                                Text("\(versionCount) 版本")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                            if !entry.matched {
                                Text("未识别")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.48), in: Capsule())
                            } else if showRatingBadge, let rating = entry.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.48), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
            }
            .modifier(CinemaWallCardSizing(fillWidth: fillWidth))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: hovered ? 1.2 : 0.5)
            }
            // 悬停只加深描边与投影，不放大：放大后描边溢出格子，外框和海报内容对不齐。
            .shadow(color: .black.opacity(hovered ? 0.26 : 0.14),
                    radius: hovered ? 12 : 6, y: hovered ? 7 : 3)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .overlay(alignment: .bottomTrailing) {
                if hovered {
                    HStack(spacing: 5) {
                        if let onPlay {
                            Button(action: onPlay) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 22, height: 22)
                                    .background(LumaBrand.amber, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("播放")
                        }
                        if let onDetail {
                            Button(action: onDetail) {
                                Image(systemName: "info")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("详情")
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: fillWidth ? .infinity : 156, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) {
            if let onDetail { onDetail() } else { onOpen() }
        }
        .onTapGesture(perform: onOpen)
        .help(entry.file.filename)
        .contextMenu {
            Button("播放") {
                if let onPlay {
                    onPlay()
                } else {
                    onOpen()
                }
            }
            Button("查看详情") {
                if let onDetail { onDetail() } else { onOpen() }
            }
            Button(store.cinemaUserState(for: entry.id).favorite ? "取消收藏" : "收藏") {
                store.toggleCinemaFavorite(entry.id)
            }
            Button(store.cinemaUserState(for: entry.id).watchlist ? "移出想看" : "加入想看") {
                store.toggleCinemaWatchlist(entry.id)
            }
            if !store.cinemaLists.isEmpty {
                Menu("加入清单") {
                    ForEach(store.cinemaLists) { list in
                        Button(list.name) {
                            store.addToCinemaList(list.id, entryID: entry.id)
                        }
                    }
                }
            }
            Button("重新刮削") {
                Task { await store.rescrapeCinema(entry) }
            }
            Button("手动刮削…") {
                // 右键菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showMatchSheet = true }
            }
            Button("选择海报…") { requestArtwork(.poster) }
            Button("选择背景…") { requestArtwork(.backdrop) }
            Button(store.cinemaProgress[entry.id]?.isFinished == true ? "标记为未看" : "标记为已看") {
                let watched = store.cinemaProgress[entry.id]?.isFinished != true
                store.setCinemaWatched(entry, watched: watched)
            }
            Button("复制文件路径") {
                let text = entry.file.cloudPath ?? entry.file.filename
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                store.showToast("已复制路径")
            }
            Divider()
            Button("忽略（以后不刮削）") {
                store.ignoreCinemaEntry(entry)
            }
            Button("删除视频文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries([entry], title: entry.title)
            }
            if store.cinemaEntries[entry.id]?.file.isCloud == true {
                Button("在资料库中显示") {
                    if let mountID = entry.file.cloudMountID {
                        store.navigate(to: .cloudMount(mountID))
                    }
                }
            }
        }
        .sheet(isPresented: $showMatchSheet) {
            CinemaMatchSheet(entry: entry) { showMatchSheet = false }
                .environmentObject(store)
        }
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
    }

    /// 换封面：候选面板自己去拉图，这里只负责递请求。
    private func requestArtwork(_ kind: CinemaArtworkKind) {
        guard entry.matched, entry.tmdbID != nil else {
            store.showToast("先匹配这部片，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: entry)
        }
    }
}

// MARK: - 列表行

private struct CinemaListRow: View {
    let artworkURL: String?
    let fallbackPhoto: PhotoItem?
    let title: String
    let subtitle: String
    let year: String
    let rating: Double?
    let genres: String
    let spec: String
    let badge: String
    let progress: CinemaProgressRecord?
    let onOpen: () -> Void
    /// 单击先选中；默认同时进详情，关掉后单击只选中、双击才进详情。
    var selected = false
    var onSelect: (() -> Void)?
    var onPlay: (() -> Void)?
    var singleClickOpensDetail = true

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            poster

            titleColumn
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

            Text(year)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            ratingView
                .frame(width: 56, alignment: .leading)

            Text(genres == "—" ? "" : genres)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            Text(spec == "—" ? "" : spec)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            statusView
                .frame(width: 104, alignment: .trailing)

            playKey
                .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? LumaBrand.amber.opacity(0.10)
                             : (hovered ? Color.primary.opacity(0.045) : Color.clear))
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(LumaBrand.amber)
                    .frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.055))
                .frame(height: 0.5)
                .padding(.leading, 12)
        }
        .contentShape(Rectangle())
        .modifier(CinemaFocusRing(active: selected))
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture {
            onSelect?()
            if singleClickOpensDetail || onSelect == nil {
                onOpen()
            }
        }
        .help(subtitle)
    }

    private var poster: some View {
        ZStack {
            if let artworkURL {
                CinemaArtwork(urlString: artworkURL, contentMode: .fill)
            } else if let fallbackPhoto {
                PhotoThumbnailView(photo: fallbackPhoto, purpose: .cover(70))
            }
        }
        .frame(width: 44, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(hovered ? 0.18 : 0.06), radius: 4, y: 2)
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(hovered ? 1 : 0.92))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let progress, progress.fraction > 0.01, !progress.isFinished {
                HStack(spacing: 6) {
                    progressBar(progress.fraction)
                        .frame(maxWidth: 160)
                    Text("已看 \(Int(progress.fraction * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LumaBrand.amber)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 2)
    }

    @ViewBuilder
    private var ratingView: some View {
        if let rating, rating > 0 {
            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(LumaBrand.amber)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private var statusView: some View {
        HStack(spacing: 5) {
            // 文档约定：状态点只在列表出现：绿=已看、琥珀=有进度、红=未识别。
            Circle()
                .fill(statusDotColor)
                .frame(width: 5, height: 5)
            Text(statusText)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(statusTextColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusDotColor.opacity(0.10), in: Capsule())
    }

    private var statusText: String {
        if badge == "未识别" { return "未识别" }
        guard let progress else { return badge }
        if progress.isFinished { return "已看完" }
        if progress.fraction > 0.01 { return "\(Int(progress.fraction * 100))%" }
        return badge
    }

    private var statusTextColor: Color {
        if badge == "未识别" { return LumaBrand.coral }
        guard let progress else { return .secondary }
        if progress.isFinished { return .green }
        return progress.fraction > 0.01 ? LumaBrand.amber : .secondary
    }

    @ViewBuilder
    private var playKey: some View {
        if let onPlay, hovered {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(LumaBrand.amber, in: Circle())
            }
            .buttonStyle(.plain)
            .help("播放")
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.45))
        }
    }

    private var statusDotColor: Color {
        if badge == "未识别" { return LumaBrand.coral }
        guard let progress else { return Color.secondary.opacity(0.35) }
        if progress.isFinished { return .green }
        return progress.fraction > 0.01 ? LumaBrand.amber : Color.secondary.opacity(0.35)
    }
}

// MARK: - 卡片模式宽幅卡

/// 卡片模式的宽幅卡：16:9 背景图 + 底部信息层。
/// 悬停浮起并出现播放键；信息层只保留片名、年份 / 类型、评分、规格与进度。
private struct CinemaWideCard: View {
    let title: String
    let meta: String
    let artworkURL: String?
    let fallbackPhoto: PhotoItem?
    let rating: Double?
    let badges: [String]
    let progressFraction: Double?
    let progressText: String?
    let onOpen: () -> Void
    let onPlay: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork

            LinearGradient(colors: [.clear, .black.opacity(0.20), .black.opacity(0.82)],
                           startPoint: .center, endPoint: .bottom)

            info
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovered ? LumaBrand.amber.opacity(0.45) : Color.white.opacity(0.08),
                              lineWidth: hovered ? 1 : 0.8)
        }
        .overlay(alignment: .topLeading) { badgeRow }
        .overlay(alignment: .topTrailing) { playKey }
        .shadow(color: .black.opacity(hovered ? 0.26 : 0.10),
                radius: hovered ? 16 : 8,
                y: hovered ? 8 : 4)
        .scaleEffect(hovered ? 1.012 : 1)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .help(meta.isEmpty ? title : "\(title) · \(meta)")
    }

    private var artwork: some View {
        ZStack {
            Color.black.opacity(0.30)
            if let artworkURL {
                CinemaArtwork(urlString: artworkURL, contentMode: .fill)
            } else if let fallbackPhoto {
                PhotoThumbnailView(photo: fallbackPhoto, purpose: .cover(600))
            } else {
                LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            HStack(spacing: 8) {
                if let rating, rating > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8.5))
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(LumaBrand.amber)
                }
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let progressText {
                    Text(progressText)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
            }
            if let progressFraction, progressFraction > 0.01 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.20))
                        Capsule()
                            .fill(LumaBrand.amber)
                            .frame(width: max(2, geo.size.width * min(1, progressFraction)))
                    }
                }
                .frame(height: 2.5)
                .padding(.top, 1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var badgeRow: some View {
        HStack(spacing: 5) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.42), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                    }
            }
        }
        .padding(12)
    }

    private var playKey: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(LumaBrand.amber.opacity(hovered ? 1 : 0), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(hovered ? 0 : 0.16), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(hovered ? 0.28 : 0), radius: 8, y: 3)
                .opacity(hovered ? 1 : 0)
                .scaleEffect(hovered ? 1 : 0.86)
                .animation(.easeOut(duration: 0.14), value: hovered)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .allowsHitTesting(hovered)
        .help("播放")
    }
}

// MARK: - 影片详情

private enum CinemaDetailSheet: String, Identifiable {
    case match
    case newList

    var id: String { rawValue }
}

private struct CinemaDetailView: View {
    let entry: CinemaEntry
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    /// 顶栏「返回」：没有二级页时关闭整个详情。
    var onClose: () -> Void = {}

    @EnvironmentObject private var store: LibraryStore
    @State private var activeSheet: CinemaDetailSheet?
    /// TMDB 详情补全后的条目（合集 / 演职员 / 预告 / 分级）。
    @State private var enriched: CinemaEntry?
    /// 推荐分组：猜你喜欢 / 豆瓣 / 同系列 / 同导演 / 同演员。
    @State private var recommendationGroups: [CinemaRecommendationGroup] = []
    /// 演职员 → 人物页；合集 → 独立合集页。
    @State private var personTarget: CinemaCastMember?
    @State private var showCollection = false
    /// 预告片：页面内播放层，不打开浏览器。
    @State private var showTrailer = false
    /// 档案卡里的长简介：默认收 5 行。
    @State private var dossierExpanded = false
    /// 手动换封面：海报 / 背景候选面板。
    @State private var artworkRequest: CinemaArtworkPickerRequest?
    /// 滚动偏移：滚过档案卡后浮出紧凑标题条。
    @State private var scrollOffset: CGFloat = 0

    private var current: CinemaEntry {
        enriched ?? store.cinemaEntry(for: entry.id) ?? entry
    }

    private var progress: CinemaProgressRecord? {
        store.cinemaProgress[entry.id]
    }

    private var userState: CinemaUserState {
        store.cinemaUserState(for: entry.id)
    }

    private var versions: [CinemaEntry] {
        store.cinemaVersions(for: entry)
    }

    /// 已识别的影片 / 剧集才去豆瓣找预告片。
    private var trailerRequest: CinemaTrailerRequest? {
        guard current.matched else { return nil }
        return CinemaTrailerRequest(title: current.title,
                                    originalTitle: current.originalTitle,
                                    year: current.year,
                                    isTV: current.kind == .tv)
    }

    var body: some View {
        ZStack {
            pageContent
                .opacity(personTarget == nil ? 1 : 0)
                .allowsHitTesting(personTarget == nil)
            if let member = personTarget {
                // 演职员改成页面内二级页：不弹窗，顶栏「返回」逐层后退。
                CinemaPersonDetailView(
                    member: member,
                    onOpenEntry: { other in
                        personTarget = nil
                        onOpenEntry(other)
                    },
                    onPlay: { other in store.openCinema(other) }
                )
                .id(member.id)
                .transition(.opacity)
            }
            if showTrailer, let request = trailerRequest {
                // 预告片在页面内播放：不打开浏览器。
                CinemaTrailerOverlay(request: request) {
                    showTrailer = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: personTarget?.id)
        .animation(.easeOut(duration: 0.16), value: showTrailer)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaDetailTone.page)
        .task {
            if let updated = await store.enrichCinemaEntry(entry) {
                enriched = updated
            }
            recommendationGroups = await store.cinemaRecommendationGroups(for: enriched ?? entry)
        }
        // 顶栏返回：先关预告片，再退演职员页，最后退影片详情。
        .onChange(of: store.cinemaDetailCloseTick) { _, _ in
            if showTrailer {
                showTrailer = false
            } else if personTarget != nil {
                personTarget = nil
            } else {
                onClose()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .match:
                CinemaMatchSheet(entry: entry) {
                    activeSheet = nil
                }
                .environmentObject(store)
                // 面板本身仍是影院暗色底，单独锁深色，避免浅色外观下白字压在深底上。
                .environment(\.colorScheme, .dark)
            case .newList:
                CinemaNewListSheet { name in
                    let list = store.createCinemaList(named: name)
                    store.addToCinemaList(list.id, entryID: entry.id)
                    activeSheet = nil
                } onCancel: {
                    activeSheet = nil
                }
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $showCollection) {
            CinemaCollectionSheet(collectionID: current.collectionID ?? 0,
                                  name: current.collectionName ?? "合集") { other in
                showCollection = false
                onOpenEntry(other)
            }
            .environmentObject(store)
            .environment(\.colorScheme, .dark)
        }
    }

    private var pageTopAnchor: String { "cinema-movie-detail-top" }

    /// 详情页默认从顶部开始：不沿用上一部片 / 上次浏览留下的滚动位置。
    private func scrollToPageTop(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(pageTopAnchor, anchor: .top)
        }
    }

    private var pageContent: some View {
        // 底图只能挂 background：aspect-fill 的远程剧照只锁了高度，
        // 图片加载完会带出自然宽度，作为 ZStack 兄弟节点会把整页撑得比窗口更宽。
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // 顶部锚点：进入详情 / 切换到另一部片时回到这里。
                        Color.clear
                            .frame(height: 0)
                            .id(pageTopAnchor)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(key: CinemaScrollOffsetKey.self,
                                                           value: geo.frame(in: .named("cinemaMovieScroll")).minY)
                                }
                            }
                        dossierSection(width: width)
                        if !collectionEntries.isEmpty {
                            collectionSection
                        }
                        if versions.count > 1 {
                            versionsSection
                        }
                        technicalSection
                        let recommendGroups = visibleRecommendationGroups
                        if !recommendGroups.isEmpty {
                            CinemaRecommendationShelf(
                                groups: recommendGroups,
                                isLocal: { store.cinemaEntry(tmdbID: $0.tmdbID, kind: $0.kind) != nil },
                                onOpen: { recom in
                                    if let doubanID = recom.doubanID {
                                        store.openDoubanPage(doubanID: doubanID)
                                    } else if let local = store.cinemaEntry(tmdbID: recom.tmdbID,
                                                                           kind: recom.kind) {
                                        onOpenEntry(local)
                                    } else {
                                        searchOnlineCinema(recom)
                                    }
                                },
                                onSearchOnline: { searchOnlineCinema($0) },
                                onOpenExternal: { recom in
                                    if let doubanID = recom.doubanID {
                                        store.openDoubanPage(doubanID: doubanID)
                                    } else {
                                        searchOnlineCinema(recom)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, horizontal)
                    .padding(.bottom, 36)
                    // 只填满可视宽度：固定 width 会变成窗口最小宽度，缩下去就回不来。
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .coordinateSpace(name: "cinemaMovieScroll")
                .onPreferenceChange(CinemaScrollOffsetKey.self) { scrollOffset = $0 }
                .onAppear { scrollToPageTop(scrollProxy) }
                .onChange(of: entry.id) { _, _ in scrollToPageTop(scrollProxy) }
            }
        }
        .background(alignment: .top) { ambientBackground }
        .overlay(alignment: .top) { compactHeader }
        .animation(.easeOut(duration: 0.18), value: scrollOffset < -140)
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
    }

    /// 滚过档案卡后浮出的紧凑标题条。
    @ViewBuilder
    private var compactHeader: some View {
        if scrollOffset < -140 {
            HStack(spacing: 8) {
                Text(current.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .lineLimit(1)
                if let year = current.year {
                    Text(String(year))
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                Spacer(minLength: 0)
                if let rating = current.rating, rating > 0 {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.10))
                    .frame(height: 0.5)
            }
            .transition(.opacity)
        }
    }

    /// 换封面：候选由面板自己拉，这里只负责把请求递过去。
    private func loadArtwork(_ kind: CinemaArtworkKind) {
        guard current.matched, current.tmdbID != nil else {
            store.showToast("先匹配这部片，才能更换封面")
            return
        }
        artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: current)
    }

    /// 推荐条目本库没有时：网络影院还没上线，先给占位提示。
    private func searchOnlineCinema(_ recom: CinemaRecommendation) {
        store.searchOnlineCinema(recom.title)
    }

    /// 推荐分组：优先本次拉到的，其次条目缓存；旧数据只有 TMDB 列表时兜底成一个 tab。
    private var visibleRecommendationGroups: [CinemaRecommendationGroup] {
        if !recommendationGroups.isEmpty { return recommendationGroups }
        if let cached = enriched?.recommendationGroups, !cached.isEmpty { return cached }
        if let recs = enriched?.recommendations, !recs.isEmpty {
            return [CinemaRecommendationGroup(source: .tmdb, title: "猜你喜欢", items: recs)]
        }
        return []
    }
    private var ambientBackground: some View {
        ZStack(alignment: .top) {
            CinemaDetailTone.page
            CinemaArtwork(urlString: entry.backdropURL ?? entry.posterURL,
                          contentMode: .fill,
                          maxPixelSize: 1100)
                .frame(height: 720)
                .blur(radius: 90, opaque: true)
                .opacity(0.20)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.80), location: 0.38),
                        .init(color: .black.opacity(0.28), location: 0.72),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: 影片档案

    /// 与剧集详情同一套版式：海报作视觉锚点，右侧按「抬头 / 片名 / 简介 / 资料网格」排，
    /// 底部接演职员，整块收进一张深色玻璃卡，不再拆成几张独立小卡。
    private func dossierSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 窄窗口把海报与资料改成上下排列，文字列不会被压成一条缝。
            if width < 760 {
                VStack(alignment: .leading, spacing: 18) {
                    dossierPosterColumn
                    dossierInfoColumn(width: max(280, width - 44))
                }
                .padding(22)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    dossierPosterColumn
                    dossierInfoColumn(width: width - 22 * 2 - 156 - 24)
                }
                .padding(22)
            }

            // 播放进度并进档案卡：电影页同样不再单独占一条。
            if let progress, progress.fraction > 0.01 {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                resumeBar(progress)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }

            if let cast = current.cast, !cast.isEmpty {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                castStrip(cast)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
        }
        .background { dossierPlate }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            CinemaDetailTone.ink.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 档案卡底板：玻璃底 + 左上角一层很淡的琥珀光，和海报的暖色调衔接。
    private var dossierPlate: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.062),
                                          CinemaDetailTone.ink.opacity(0.022)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
    }

    /// 海报 + 评分牌 + 个人评分 + 观看进度：共用一列，宽度和海报对齐。
    private var dossierPosterColumn: some View {
        VStack(spacing: 9) {
            posterCard(width: 156, height: 234)
                .shadow(color: LumaBrand.amber.opacity(0.18), radius: 22, y: 10)

            if let rating = current.rating, rating > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(CinemaDetailTone.ink)
                    if let votes = current.voteCount, votes > 0 {
                        Text("· \(voteCountText(votes))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
                }
            }

            if let rating = userState.rating {
                Text("我的评分 " + String(repeating: "★", count: rating))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                    .frame(width: 156)
            }

            if let progress, progress.fraction > 0.01 {
                VStack(spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(LumaBrand.amber)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    Text(progress.isFinished ? "已看完" : "已看 \(Int(progress.fraction * 100))%")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                .frame(width: 156)
            }
        }
        .frame(width: 156, alignment: .top)
    }

    /// 档案抬头：琥珀刻字标签 + 年份 / 片长 / 规格 + 上映状态。
    private var dossierKicker: some View {
        HStack(spacing: 8) {
            Text("影片档案")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(CinemaDetailTone.accent.opacity(0.92))
            Rectangle()
                .fill(LumaBrand.amber.opacity(0.35))
                .frame(width: 24, height: 0.8)
            Text(dossierMetaLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
            dossierStatusPill
        }
    }

    /// 片名 / 原名 / 宣传语 / 播放动作：整页的标题区。
    private var dossierTitleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(displayTitle)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(CinemaDetailTone.ink)
                .lineLimit(2)
                .textSelection(.enabled)

            if let original = current.originalTitle,
               !original.isEmpty,
               original.caseInsensitiveCompare(displayTitle) != .orderedSame {
                Text(original.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                    .lineLimit(1)
            }

            if let tagline = current.tagline, !tagline.isEmpty {
                Text("「\(tagline)」")
                    .font(.system(size: 12, weight: .medium))
                    .italic()
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
                    .lineLimit(2)
            }

            actions
                .padding(.top, 2)
        }
    }

    private var displayTitle: String {
        let title = current.title
        return title.isEmpty ? entry.title : title
    }

    @ViewBuilder
    private var dossierStatusPill: some View {
        if let status = cinemaStatusText(current.status) {
            let released = current.status == "Released"
            HStack(spacing: 5) {
                Circle()
                    .fill(released ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.32))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(released ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.72))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CinemaDetailTone.ink.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
        }
    }

    /// 简介：默认收 5 行，长简介可展开；没有简介时提示换数据源。
    @ViewBuilder
    private var dossierSynopsis: some View {
        let overview = current.overview ?? ""
        if overview.isEmpty {
            Text("暂无剧情简介。可以在顶栏面板里「重新匹配」换一个数据源，通常会补全简介与演职员。")
                .font(.system(size: 12))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(overview)
                    .font(.system(size: 12.8))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.78))
                    .lineSpacing(6)
                    .lineLimit(dossierExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if overview.count > 180 {
                    Button(dossierExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            dossierExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        }
    }

    /// 档案卡右侧信息列：标题、简介与资料网格共用，窄窗口时也可单独铺满整行。
    private func dossierInfoColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            dossierKicker
            dossierTitleBlock
            dossierSynopsis
            dossierFactsGrid(width: width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 资料项列数：按档案卡右列的实际宽度算，宽窗口自动多排一列。
    private func factsColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 12
        let width = width > 0 ? width : 620
        let count = max(1, GridLayout.columns(contentWidth: width, targetSize: 210, spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 120), spacing: spacing), count: count)
    }

    /// 资料网格：每项一枚琥珀小图标 + 标签 / 值，缺哪项就不占位。
    private func dossierFactsGrid(width: CGFloat) -> some View {
        LazyVGrid(columns: factsColumns(width: width),
                  alignment: .leading, spacing: 12) {
            ForEach(dossierFacts) { fact in
                HStack(spacing: 9) {
                    Image(systemName: fact.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.accent.opacity(0.90))
                        .frame(width: 24, height: 24)
                        .background(LumaBrand.amber.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.38))
                        Text(fact.value)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.82))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
        // 资料网格跟随可用宽度重排列数：宽窗口多排几列，不会只挤在左边。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct DossierFact: Identifiable {
        let icon: String
        let label: String
        let value: String
        var id: String { label + "|" + value }
    }

    /// 本地与 TMDB 能拿到的资料项都在这里，缺哪项就不占位。
    private var dossierFacts: [DossierFact] {
        var items: [DossierFact] = []
        if let value = cinemaDateText(current.releaseDate) ?? current.year.map({ "\($0) 年" }) {
            items.append(DossierFact(icon: "calendar", label: "上映", value: value))
        }
        if let value = cinemaMinutesText(current.runtime) {
            items.append(DossierFact(icon: "clock", label: "片长", value: value))
        }
        if let value = current.file.displayTags.first(where: { $0 == "DV" || $0.hasPrefix("HDR") }) {
            items.append(DossierFact(icon: "sparkles.tv",
                                     label: "HDR",
                                     value: value == "DV" ? "Dolby Vision" : value))
        }
        if current.file.displayTags.contains("Atmos") {
            items.append(DossierFact(icon: "hifispeaker.2", label: "音轨", value: "Dolby Atmos"))
        }
        if let fps = current.file.parsedFrameRate {
            items.append(DossierFact(icon: "speedometer", label: "帧率", value: "\(fps) fps"))
        }
        if let value = current.genres?.prefix(4).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "theatermasks", label: "类型", value: value))
        }
        if let value = current.certification, !value.isEmpty {
            items.append(DossierFact(icon: "shield.lefthalf.filled", label: "分级", value: value))
        }
        if let value = cinemaLanguageName(current.originalLanguage) {
            items.append(DossierFact(icon: "character.bubble", label: "语言", value: value))
        }
        if let countries = current.countries, !countries.isEmpty {
            let value = countries.prefix(2).map(cinemaCountryName).joined(separator: " / ")
            items.append(DossierFact(icon: "globe.asia.australia", label: "国家", value: value))
        }
        if let value = current.companies?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "building.2", label: "制作", value: value))
        }
        if let value = ratingDetailText {
            items.append(DossierFact(icon: "star", label: "评分", value: value))
        }
        if let value = cinemaMoneyText(current.budget) {
            items.append(DossierFact(icon: "banknote", label: "预算", value: value))
        }
        if let value = cinemaMoneyText(current.revenue) {
            items.append(DossierFact(icon: "chart.line.uptrend.xyaxis", label: "票房", value: value))
        }
        if let value = current.collectionName, !value.isEmpty {
            items.append(DossierFact(icon: "square.stack.3d.up", label: "合集", value: value))
        }
        if let id = current.tmdbID {
            let label = current.provider == .tvdb ? "TVDB" : "TMDB"
            items.append(DossierFact(icon: "number", label: label, value: "\(id)"))
        }
        return items
    }

    private var dossierMetaLine: String {
        var parts: [String] = []
        if let year = current.year, year > 0 {
            parts.append("\(year)")
        }
        if let runtime = current.runtime, runtime > 0 {
            parts.append("\(runtime) 分钟")
        }
        parts.append(resolutionText)
        return parts.joined(separator: " · ")
    }

    private func voteCountText(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f 万人评分", Double(votes) / 10_000)
        }
        return "\(votes) 人评分"
    }

    private func posterCard(width: CGFloat, height: CGFloat) -> some View {
        let radius: CGFloat = width > 100 ? 10 : 5
        return ZStack {
            if let url = current.posterURL ?? entry.posterURL {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else {
                PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(240))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.26), lineWidth: 1)
        }
        .contextMenu {
            Button("选择海报…") { loadArtwork(.poster) }
            Button("选择背景…") { loadArtwork(.backdrop) }
        }
    }

    private var actions: some View {
        // 一行放不下时自动换行：窄窗口下动作按钮不会挤出档案卡。
        CinemaBadgeFlow(spacing: 9, lineSpacing: 9) {
            Button(action: play) {
                Label(progress == nil ? "播放" : "继续播放", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(LumaBrand.amber, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .fixedSize()

            if trailerRequest != nil {
                Button {
                    showTrailer = true
                } label: {
                    Label("预告片", systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(0.14), in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            Button {
                activeSheet = .match
            } label: {
                Label(entry.matched ? "重新匹配" : "手动匹配", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(CinemaDetailTone.ink.opacity(0.16), in: Capsule())
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.94))
            }
            .buttonStyle(.plain)
            .fixedSize()

            circleButton(userState.favorite ? "heart.fill" : "heart",
                         active: userState.favorite,
                         help: userState.favorite ? "取消收藏" : "收藏") {
                store.toggleCinemaFavorite(entry.id)
            }

            circleButton(userState.watchlist ? "bookmark.fill" : "bookmark",
                         active: userState.watchlist,
                         activeColor: LumaBrand.amber,
                         help: userState.watchlist ? "移出想看" : "加入想看") {
                store.toggleCinemaWatchlist(entry.id)
            }

            ratingMenu
            listMenu
            moreMenu
        }
    }

    private func circleButton(_ icon: String,
                              active: Bool,
                              activeColor: Color = LumaBrand.coral,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? activeColor : CinemaDetailTone.ink.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(CinemaDetailTone.ink.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var ratingMenu: some View {
        Menu {
            ForEach(1...5, id: \.self) { star in
                Button(String(repeating: "★", count: star)) {
                    store.setCinemaRating(star, for: entry.id)
                }
            }
            Divider()
            Button("清除评分") {
                store.setCinemaRating(nil, for: entry.id)
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                if let rating = userState.rating {
                    Text("\(rating)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(userState.rating == nil ? CinemaDetailTone.ink.opacity(0.90)
                                                     : LumaBrand.amber)
            .frame(width: 34, height: 34)
            .background(CinemaDetailTone.ink.opacity(0.16), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("个人评分")
    }

    private var listMenu: some View {
        Menu {
            if store.cinemaLists.isEmpty {
                Button("新建清单…") { activeSheet = .newList }
            } else {
                ForEach(store.cinemaLists) { list in
                    Button(list.name) {
                        store.addToCinemaList(list.id, entryID: entry.id)
                    }
                }
                Divider()
                Button("新建清单…") { activeSheet = .newList }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(CinemaDetailTone.ink.opacity(0.16), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("加入清单")
    }

    private var moreMenu: some View {
        Menu {
            Button("按文件名重新刮削") {
                Task { await store.rescrapeCinema(entry) }
            }
            if let mountID = entry.file.cloudMountID {
                Button("在资料库中显示") {
                    store.cinemaDetailCloseTick += 1
                    store.navigate(to: .cloudMount(mountID))
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                .frame(width: 34, height: 34)
                .background(CinemaDetailTone.ink.opacity(0.14), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    private func play() {
        play(entry)
    }

    private func play(_ version: CinemaEntry) {
        // 详情留在页面下层，播放器关掉后回到原位。
        store.openCinema(version)
    }

    // MARK: 合集 / 演职员

    private var collectionEntries: [CinemaEntry] {
        guard let id = current.collectionID else { return [] }
        return store.cinemaCollection(collectionID: id).filter { $0.id != entry.id }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle(current.collectionName ?? "同一合集",
                             detail: "\(collectionEntries.count + 1) 部")
                Button("查看合集 ›") {
                    showCollection = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
                .help("打开合集详情：按上映顺序播放与合集统计")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(collectionEntries) { other in
                        Button {
                            onOpenEntry(other)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ZStack {
                                    if let url = other.posterURL {
                                        CinemaArtwork(urlString: url, contentMode: .fill)
                                    } else {
                                        PhotoThumbnailView(photo: other.file.photoItem, purpose: .cover(120))
                                    }
                                }
                                .frame(width: 96, height: 144)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(CinemaDetailTone.ink.opacity(0.12),
                                                      lineWidth: 0.6)
                                }
                                Text(other.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                                    .lineLimit(1)
                                    .frame(width: 96, alignment: .leading)
                                Text(other.year.map(String.init) ?? " ")
                                    .font(.system(size: 10))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                                    .frame(width: 96, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(other.title)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .background(CinemaDetailTone.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.07), lineWidth: 0.6)
        }
    }

    /// 演职员条：和剧集详情同款，收在档案卡底部。
    private func castStrip(_ cast: [CinemaCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                if let directors = current.directors, !directors.isEmpty {
                    Text("导演 " + directors.prefix(2).joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        CinemaCastTile(member: member,
                                       onOpen: { personTarget = member },
                                       onSearchOnline: { store.searchOnlineCinema(member.name) })
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 版本

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("版本", detail: "\(versions.count) 个文件")
            ForEach(versions) { version in
                versionRow(version)
            }
        }
        .padding(16)
        .background(CinemaDetailTone.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.07), lineWidth: 0.6)
        }
    }

    private func versionRow(_ version: CinemaEntry) -> some View {
        let current = version.id == entry.id
        return Button {
            play(version)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(current ? LumaBrand.amber
                                             : CinemaDetailTone.ink.opacity(0.40))

                VStack(alignment: .leading, spacing: 2) {
                    Text(version.file.filename)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(resolutionText(version.file)) · \(byteText(version.file)) · \(durationText(version.file))")
                        .font(.system(size: 10))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.50))
                }

                Spacer(minLength: 0)

                Text(current ? "当前" : "播放")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(current ? LumaBrand.amber
                                             : CinemaDetailTone.ink.opacity(0.55))
            }
            .padding(8)
            .background(current ? LumaBrand.amber.opacity(0.10)
                                : CinemaDetailTone.ink.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(current ? LumaBrand.amber.opacity(0.35)
                                          : CinemaDetailTone.ink.opacity(0.08),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 进度 / 技术信息

    /// 有观看进度时置顶一条「继续播放」，和剧集详情的下一集条同一套样式。
    private func resumeBar(_ progress: CinemaProgressRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: progress.isFinished ? "checkmark.circle.fill" : "play.circle.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.isFinished ? "已看完" : "继续观看")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(timeText(progress.position)) / \(timeText(progress.duration)) · 还剩 \(remainingText(progress))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: play) {
                Label(progress.isFinished ? "重看" : "继续播放", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(LumaBrand.amber, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(LumaBrand.amber.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.8)
        }
    }

    /// 技术规格 + 文件信息收进同一张卡：上面是规格 chips，下面是可复制的路径与匹配状态。
    private var technicalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("文件与技术信息", detail: entry.file.filename)
            // 规格胶囊按实际宽度流式换行：窄窗口不会把最后几枚挤出可视区。
            CinemaBadgeFlow(spacing: 8, lineSpacing: 8) {
                chip(resolutionText)
                if let codec = entry.file.videoCodec, !codec.isEmpty {
                    chip(codec.uppercased())
                }
                chip(fileExtension)
                chip(byteText)
                chip(durationText)
                ForEach(Array(current.file.displayTags.prefix(3)), id: \.self) { tag in
                    chip(tag)
                }
            }
            VStack(spacing: 0) {
                infoRow("文件名", entry.file.filename)
                Divider().opacity(0.4)
                infoRow("路径", filePathText)
                Divider().opacity(0.4)
                infoRow("大小", byteText)
                Divider().opacity(0.4)
                infoRow("时长", durationText)
                Divider().opacity(0.4)
                infoRow("添加时间", entry.file.capturedAt.formatted(date: .numeric, time: .shortened))
                Divider().opacity(0.4)
                infoRow("匹配", entry.matched
                        ? (entry.tmdbID.map { "已匹配 · \(entry.provider?.title ?? "TMDB") \($0)" } ?? "已匹配")
                        : "未识别")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(CinemaDetailTone.ink.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CinemaDetailTone.ink.opacity(0.07), lineWidth: 0.6)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
            .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
    }

    private func sectionTitle(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LumaBrand.amber)
                .frame(width: 3, height: 13)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var ratingDetailText: String? {
        guard let rating = current.rating, rating > 0 else { return nil }
        var text = String(format: "%.1f", rating)
        if let votes = current.voteCount, votes > 0 {
            text += " · \(votes) 人评分"
        }
        return text
    }

    /// 网盘（尤其夸克）的 cloudPath 是文件 ID，不是人类可读路径：
    /// 有目录链时优先拼成「目录/文件名」，否则再退回原始路径。
    private var filePathText: String {
        let name = entry.file.filename
        if let hint = entry.folderHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            return hint.hasSuffix("/") ? hint + name : hint + "/" + name
        }
        if let raw = entry.file.cloudPath,
           !raw.isEmpty,
           !LibraryStore.cinemaPathLooksLikeID(raw) {
            return raw
        }
        return name
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    // MARK: 格式化

    private var resolutionText: String {
        resolutionText(entry.file)
    }

    private func resolutionText(_ file: CinemaFile) -> String {
        let width = file.pixelWidth
        let height = file.pixelHeight
        if width >= 3000 { return "4K" }
        if width >= 1800 { return "2K" }
        if width >= 1200 { return "1080P" }
        if width > 0, height > 0 { return "\(width)×\(height)" }
        return "分辨率未知"
    }

    private var fileExtension: String {
        let ext = (entry.file.filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : ext
    }

    private var byteText: String {
        byteText(entry.file)
    }

    private func byteText(_ file: CinemaFile) -> String {
        guard file.fileSize > 0 else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
    }

    private var durationText: String {
        durationText(entry.file)
    }

    private func durationText(_ file: CinemaFile) -> String {
        guard let duration = file.duration, duration > 0 else { return "时长未知" }
        let minutes = Int(duration / 60)
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(minutes) 分钟"
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func remainingText(_ progress: CinemaProgressRecord) -> String {
        let minutes = Int(progress.remainingSeconds / 60)
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(max(1, minutes)) 分钟"
    }
}

// MARK: - 新建清单

private struct CinemaNewListSheet: View {
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建清单")
                .font(.system(size: 16, weight: .bold))
            Text("手动选片，只在本机保存，不写回网盘。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("清单名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}

// MARK: - 手动匹配

struct CinemaMatchSheet: View {
    let entry: CinemaEntry?
    let photos: [PhotoItem]
    /// 来自文件夹匹配时的目录链：用来补季 / 剧名，比单个文件更可靠。
    let folderHint: String?
    let onApplied: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// 两步：先选片，再给剧集排季集（参考芝杜的批量匹配流程）。
    private enum Step { case search, episodes }

    /// 手动匹配的来源：可以只查某一个，也可以全部一起查。
    private enum MatchSource: String, CaseIterable, Identifiable {
        case all
        case tmdb
        case douban
        case tvdb

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .tmdb: return "TMDB"
            case .douban: return "豆瓣"
            case .tvdb: return "TVDB"
            }
        }

        var providers: [CinemaProvider]? {
            switch self {
            case .all: return nil
            case .tmdb: return [.tmdb]
            case .douban: return [.douban]
            case .tvdb: return [.tvdb]
            }
        }
    }

    /// 集号来源：文件名里的数字，或按顺序编号（同名多版本共用一集）。
    private enum EpisodeMode: String, CaseIterable, Identifiable {
        case fileName
        case sequential

        var id: String { rawValue }
        var title: String {
            switch self {
            case .fileName: return "文件名数字"
            case .sequential: return "按顺序"
            }
        }
    }

    private struct EpisodeRow: Identifiable {
        let photo: PhotoItem
        var text: String
        /// 从 SxxExx / 纯数字文件名里解析出的原始编号。
        var detected: Int?
        var detectedSeason: Int?
        /// 去掉清晰度 / 版本标记后的文件名主干，用来把 4K 与普通版认成同一集。
        var normalizedName: String

        var id: UUID { photo.id }
    }

    @State private var query: String
    @State private var isTV: Bool
    @State private var yearText: String
    @State private var results: [CinemaMatch] = []
    /// 匹配来源：默认全部一起查，也可以只查某一个。
    @AppStorage("cinema_match_source") private var matchSource: MatchSource = .all
    @State private var selectedKey: String?
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var step: Step = .search
    @State private var chosenMatch: CinemaMatch?
    @State private var season = 1
    /// 同目录同名（4K / 1080p 等）一次套用，省得逐个版本点。
    @State private var matchSiblings = true
    @State private var episodeMode: EpisodeMode = .fileName
    /// 集号 = 文件名数字 + 偏移；顺序模式下等于「起始集 - 1」。
    @State private var episodeOffset = 0
    @State private var rows: [EpisodeRow] = []
    /// 智能助手：补充要求、运行状态与回填结果。
    @State private var aiNote = ""
    @State private var showAIPanel = false
    @State private var aiRunning = false
    @State private var aiMessage: String?
    @State private var aiError: String?
    /// 静默自动匹配：不打开助手面板，跑完直接回填；期间整页锁住，可手动解锁。
    @State private var aiLocked = false
    @State private var aiTask: Task<Void, Never>?
    /// 应用助手结果时不要触发「按模式重算」，否则会覆盖模型给的集号。
    @State private var suppressAutoRefresh = false

    init(entry: CinemaEntry, onApplied: @escaping () -> Void) {
        self.entry = entry
        self.photos = []
        self.folderHint = entry.folderHint
        self.onApplied = onApplied
        _query = State(initialValue: entry.title)
        _isTV = State(initialValue: entry.kind == .tv)
        _yearText = State(initialValue: entry.year.map(String.init) ?? "")
    }

    /// 相簿 / 网格直接手动匹配：不必先进入影院，也不必已经刮削过。
    /// `folderHint` 传入所在目录链后，纯数字文件名也能正确补季。
    init(photos: [PhotoItem], folderHint: String? = nil, onApplied: @escaping () -> Void = {}) {
        self.entry = nil
        self.photos = photos
        self.folderHint = folderHint
        self.onApplied = onApplied
        let first = photos.first
        let parsed = CinemaScraper.parse(filename: first?.displayFilename ?? "")
        _query = State(initialValue: parsed.title)
        _isTV = State(initialValue: parsed.isTV)
        _yearText = State(initialValue: parsed.year.map(String.init) ?? "")
    }

    private var targetFilename: String {
        if let entry { return entry.file.filename }
        if photos.count > 1 {
            return "\(photos.count) 个视频 · 各自按文件名解析季集"
        }
        return photos.first?.displayFilename ?? ""
    }

    var body: some View {
        ZStack {
            Group {
                switch step {
                case .search:
                    searchStep
                case .episodes:
                    episodeStep
                }
            }
            // 静默匹配期间整页不可操作，只留「手动解锁」一个出口。
            .disabled(aiLocked)

            if aiLocked {
                Color.black.opacity(0.30)
                lockCard
            }
        }
        .padding(18)
        .frame(width: step == .episodes ? 760 : 680, height: 540)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(aiLocked)
        .task {
            if !hasSearched {
                await search()
            }
        }
    }

    /// 静默匹配的锁定卡片：进度 + 解锁出口。
    private var lockCard: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("智能助手正在排 \(rows.count) 个文件的季集…")
                .font(.system(size: 11.5, weight: .semibold))
            Text("完成后自动回填集号；也可以现在手动解锁，助手的结果将不再写入。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("手动解锁") { unlockAIMatching() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var searchStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchBar
            Divider()
            resultList
            Divider()
            footer
        }
    }

    // MARK: 季集映射

    private var episodeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            episodeHeader
            episodeControls
            Divider()
            episodeList
            Divider()
            episodeFooter
        }
    }

    private var episodeHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                if let url = chosenMatch?.posterURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .frame(width: 40, height: 60)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("季集映射")
                    .font(.system(size: 16, weight: .bold))
                Text(episodeSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("换个匹配") { step = .search }
                .controlSize(.small)
        }
    }

    private var episodeSubtitle: String {
        var parts: [String] = []
        if let match = chosenMatch {
            parts.append(match.title)
            if let year = match.year { parts.append(String(year)) }
        }
        parts.append("\(photos.count) 个视频")
        parts.append("预填自文件名，可逐条改")
        return parts.joined(separator: " · ")
    }

    private var episodeControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                Stepper(value: $season, in: 1...99) {
                    Text("第 \(season) 季")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                }
                .controlSize(.small)

                Picker("", selection: $episodeMode) {
                    ForEach(EpisodeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: episodeMode) { _, _ in
                    guard !suppressAutoRefresh else { return }
                    refreshAssignments()
                }

                Stepper(value: $episodeOffset, in: -99...99) {
                    Text(episodeOffset == 0
                         ? "偏移 0"
                         : "偏移 \(episodeOffset > 0 ? "+" : "")\(episodeOffset)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                }
                .controlSize(.small)
                .onChange(of: episodeOffset) { _, _ in
                    guard !suppressAutoRefresh else { return }
                    refreshAssignments()
                }

                if episodeMode == .fileName, let minNumber = detectedNumberRange.min, minNumber > 1 {
                    Button("把 \(minNumber) 当作第 1 集") {
                        episodeOffset = 1 - minNumber
                        refreshAssignments()
                    }
                    .controlSize(.small)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(assignmentSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("季与集号会写进影院条目，之后详情页按季集排序、自动接下一集。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                // 静默自动匹配：不打开助手面板，模型排完直接回填。
                Button {
                    runSilentAIPlan()
                } label: {
                    Label(aiLocked ? "自动匹配中…" : "智能助手自动匹配",
                          systemImage: "sparkles")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(LumaBrand.amber)
                .disabled(aiRunning || rows.isEmpty)
                .help("静默交给智能助手：不打开界面，排好后自动回填集号；过程中可手动解锁")

                Button {
                    showAIPanel = true
                } label: {
                    Label(aiRunning ? "助手排集中…" : "交给助手", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(aiRunning || rows.isEmpty)
                .popover(isPresented: $showAIPanel, arrowEdge: .bottom) {
                    aiPanel
                }
                .help("把剧名、季、文件和补充要求交给大模型，由它调用工具回填集号")

                Button {
                    prepareEpisodes(resetSeason: false)
                } label: {
                    Label("按文件名重新识别", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)

                Button {
                    sortRowsByEpisode()
                } label: {
                    Label("按集号排序", systemImage: "arrow.up.arrow.down")
                }
                .controlSize(.small)
            }

            if aiRunning || aiMessage != nil || aiError != nil {
                HStack(spacing: 6) {
                    if aiRunning {
                        ProgressView().controlSize(.mini)
                    }
                    if let aiMessage {
                        Text(aiMessage)
                            .foregroundStyle(LumaBrand.amber)
                    }
                    if let aiError {
                        Text(aiError)
                            .foregroundStyle(LumaBrand.coral)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detectedNumberRange: (min: Int?, max: Int?) {
        let values = rows.compactMap(\.detected)
        return (values.min(), values.max())
    }

    /// 多少集、多少文件、有多少文件是同集多版本。
    private var assignmentSummary: String {
        let assigned = rows.filter { (Int($0.text.trimmingCharacters(in: .whitespaces)) ?? 0) > 0 }
        let groups = Dictionary(grouping: assigned, by: { $0.text }).count
        var summary = "\(groups) 集 · \(rows.count) 个文件"
        if rows.count > groups, groups > 0 {
            summary += " · \(rows.count - groups) 个同集多版本"
        }
        return summary
    }

    // MARK: 智能助手

    /// 把剧名、季、文件事实与用户要求交给大模型；模型通过工具回填集号。
    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(LumaBrand.amber)
                Text("交给智能助手")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("把剧名、第 \(season) 季、\(rows.count) 个文件和你下面的要求交给 \(store.aiConfig.model.isEmpty ? "大模型" : store.aiConfig.model)，由它调用工具回填集号。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("补充要求，例如「11 当作第 1 集」「13 之后缺一集」",
                      text: $aiNote,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            if let aiError {
                Text(aiError)
                    .font(.system(size: 10))
                    .foregroundStyle(LumaBrand.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if aiRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在核对 \(rows.count) 个文件…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("取消") { showAIPanel = false }
                    .controlSize(.small)
                Button("开始匹配") { runAIPlan() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .disabled(aiRunning || rows.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func runAIPlan() {
        guard !aiRunning, !rows.isEmpty else { return }
        aiRunning = true
        aiError = nil
        aiMessage = nil
        showAIPanel = false
        let snapshot = rows
        let request = aiMatchRequest()
        Task { @MainActor in
            do {
                let plan = try await store.aiPlanEpisodeMapping(request)
                applyAIPlan(plan, snapshot: snapshot)
            } catch {
                aiError = error.localizedDescription
            }
            aiRunning = false
        }
    }

    /// 静默自动匹配：不打开助手面板，跑完直接把集号回填到列表；
    /// 期间整页锁住，只留「手动解锁」——解锁后到达的结果直接丢弃。
    private func runSilentAIPlan() {
        guard !aiRunning, !rows.isEmpty else { return }
        aiRunning = true
        aiLocked = true
        aiError = nil
        aiMessage = nil
        let snapshot = rows
        let request = aiMatchRequest()
        aiTask = Task { @MainActor in
            defer {
                aiRunning = false
                aiLocked = false
                aiTask = nil
            }
            do {
                let plan = try await store.aiPlanEpisodeMapping(request)
                guard !Task.isCancelled else { return }
                applyAIPlan(plan, snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                aiError = error.localizedDescription
            }
        }
    }

    /// 手动解锁：取消静默匹配，之后返回的结果不再写入。
    private func unlockAIMatching() {
        aiTask?.cancel()
        aiTask = nil
        aiLocked = false
        aiRunning = false
        aiMessage = "已手动解锁，助手结果已丢弃"
    }

    /// 静默与弹窗两条路径共用同一份请求：剧名、季、文件事实与补充要求。
    private func aiMatchRequest() -> CinemaAIMatchRequest {
        let note = aiNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return CinemaAIMatchRequest(
            title: chosenMatch?.title ?? query,
            year: chosenMatch?.year ?? Int(yearText.trimmingCharacters(in: .whitespaces)),
            season: season,
            files: rows.enumerated().map { index, row in
                CinemaAIMatchFile(index: index + 1,
                                  filename: row.photo.displayFilename,
                                  detectedEpisode: row.detected,
                                  durationSeconds: row.photo.duration,
                                  sizeBytes: row.photo.fileSize)
            },
            note: note.isEmpty ? nil : note
        )
    }

    private func applyAIPlan(_ plan: CinemaAIMatchPlan, snapshot: [EpisodeRow]) {
        suppressAutoRefresh = true
        if let mode = plan.mode {
            episodeMode = mode == "sequential" ? .sequential : .fileName
        }
        if let offset = plan.offset {
            episodeOffset = max(-99, min(99, offset))
        }
        var applied = 0
        for (index, episode) in plan.assignments {
            guard index >= 1, index <= snapshot.count else { continue }
            let id = snapshot[index - 1].photo.id
            if let rowIndex = rows.firstIndex(where: { $0.id == id }) {
                rows[rowIndex].text = String(episode)
                applied += 1
            }
        }
        sortRowsByEpisode()
        let episodeCount = Set(plan.assignments.values).count
        var message = "助手已排好 \(episodeCount) 集 · \(applied) 个文件"
        if applied < rows.count {
            message += "（\(rows.count - applied) 个未给集号）"
        }
        if let note = plan.note, !note.isEmpty {
            message += " · \(note)"
        }
        aiMessage = message
        // 等 onChange 走完再恢复，避免模式 / 偏移把模型给的集号重算掉。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            suppressAutoRefresh = false
        }
    }

    private var episodeList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    episodeRow(index: index, row: row)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func episodeRow(index: Int, row: EpisodeRow) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            PhotoThumbnailView(photo: row.photo, purpose: .cover(80))
                .frame(width: 64, height: 36)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.photo.displayFilename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rowSourceText(row))
                    .font(.system(size: 9))
                    .foregroundStyle(row.detected == nil && episodeMode == .fileName
                                     ? Color.secondary
                                     : LumaBrand.amber.opacity(0.85))
            }

            Spacer(minLength: 0)

            if episodeShareCount(row) > 1 {
                Text("×\(episodeShareCount(row))")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            Text("E")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("", text: episodeBinding(row.id))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.center)

            Text(episodeBadge(row))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(LumaBrand.amber)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(7)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var episodeFooter: some View {
        HStack(spacing: 10) {
            Text("已分配 \(assignedCount)/\(rows.count) 个文件 · \(assignmentSummary) · 第 \(season) 季")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("返回") { step = .search }
                .controlSize(.small)
            Button("取消") { dismiss() }
                .controlSize(.small)
            Button("应用 \(rows.count) 个文件") { applyEpisodes() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(LumaBrand.amber)
                .disabled(assignedCount == 0)
        }
    }

    private func rowSourceText(_ row: EpisodeRow) -> String {
        if episodeMode == .fileName {
            if let detected = row.detected { return "文件名数字 \(detected)" }
            return "缺号 · 已顺序补齐"
        }
        return "按顺序编号 · 同名版本共用集号"
    }

    private func episodeShareCount(_ row: EpisodeRow) -> Int {
        let text = row.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 1 }
        return rows.filter { $0.text.trimmingCharacters(in: .whitespaces) == text }.count
    }

    private func episodeBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { rows.first(where: { $0.id == id })?.text ?? "" },
            set: { value in
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    rows[index].text = value
                }
            }
        )
    }

    private func episodeBadge(_ row: EpisodeRow) -> String {
        let episode = Int(row.text.trimmingCharacters(in: .whitespaces)) ?? 0
        guard episode > 0 else { return "S\(pad(season))E—" }
        return "S\(pad(season))E\(pad(episode))"
    }

    private func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    private var assignedCount: Int {
        rows.filter { (Int($0.text.trimmingCharacters(in: .whitespaces)) ?? 0) > 0 }.count
    }

    /// 进映射页：先按文件名自然顺序排，再尝试从 SxxExx 或纯数字文件名取集号。
    /// 文件名就是数字（11.mkv / 13 4K.mkv）时按数字识别；完全没数字才退回顺序编号。
    private func prepareEpisodes(resetSeason: Bool = true) {
        let sorted = photos.sorted {
            $0.displayFilename.localizedStandardCompare($1.displayFilename) == .orderedAscending
        }
        let newRows = sorted.map { photo -> EpisodeRow in
            let parsed = parseFilename(photo)
            let loose = looseEpisodeNumber(photo.displayFilename)
            return EpisodeRow(photo: photo,
                              text: "",
                              detected: parsed.episode ?? loose,
                              detectedSeason: parsed.season,
                              normalizedName: normalizedStem(photo.displayFilename))
        }
        if resetSeason {
            season = newRows.compactMap(\.detectedSeason).first ?? 1
        }
        rows = newRows
        episodeMode = newRows.contains(where: { $0.detected != nil }) ? .fileName : .sequential
        episodeOffset = 0
        refreshAssignments()
    }

    /// 按当前模式重新分配集号；同名多版本永远落到同一集。
    private func refreshAssignments() {
        guard !rows.isEmpty else { return }
        if episodeMode == .fileName, rows.contains(where: { $0.detected != nil }) {
            for index in rows.indices {
                if let detected = rows[index].detected {
                    rows[index].text = String(max(1, detected + episodeOffset))
                } else {
                    rows[index].text = ""
                }
            }
            // 少数没带编号的文件：接在已有最大值之后顺序补齐。
            var next = rows.compactMap { Int($0.text) }.max() ?? 0
            for index in rows.indices where rows[index].text.isEmpty {
                next += 1
                rows[index].text = String(next)
            }
        } else {
            // 顺序模式：按文件名主干分组，4K / 1080P 等版本共用一集。
            var assigned: [String: Int] = [:]
            var next = max(1, 1 + episodeOffset)
            for index in rows.indices {
                let fallback = rows[index].photo.id.uuidString
                let key = rows[index].normalizedName.isEmpty ? fallback : rows[index].normalizedName
                if let existing = assigned[key] {
                    rows[index].text = String(existing)
                } else {
                    assigned[key] = next
                    rows[index].text = String(next)
                    next += 1
                }
            }
        }
        sortRowsByEpisode()
    }

    private func sortRowsByEpisode() {
        rows.sort { lhs, rhs in
            let left = Int(lhs.text.trimmingCharacters(in: .whitespaces)) ?? Int.max
            let right = Int(rhs.text.trimmingCharacters(in: .whitespaces)) ?? Int.max
            if left != right { return left < right }
            return lhs.photo.displayFilename.localizedStandardCompare(rhs.photo.displayFilename)
                == .orderedAscending
        }
    }

    /// 去掉 4K / HDR / 编码 / 音轨等版本标记，得到用于「同名多版本」判断的主干。
    private func normalizedStem(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let pattern = #"(?i)(?<![a-z0-9])(4k|8k|2160p|1080p|720p|480p|hdr10\+?|hdr|dv|dolby[ .]?vision|remux|web[- .]?dl|webrip|bluray|bdrip|x265|x264|h[ .]?265|h[ .]?264|hevc|avc|aac|ddp?[ .]?\d(?:[ .]\d)?|atmos|truehd|dts(?:-hd)?(?:[ .]?ma)?|\d{2,3}fps|高码版?|国语|国粤|双语|中字|中文字幕|简繁|英字幕)(?![a-z0-9])"#
        let stripped = base.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        let collapsed = stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return collapsed.isEmpty ? base.lowercased() : collapsed
    }

    /// `11.mkv`、`13 4K.mkv`、`谷雨 11.mkv` 这类把结尾数字当集号。
    private func looseEpisodeNumber(_ filename: String) -> Int? {
        let stem = normalizedStem(filename)
        guard !stem.isEmpty else { return nil }
        if stem.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil {
            return Int(stem)
        }
        if stem.range(of: #"^.+[\s\-_\.]\d{1,3}$"#, options: .regularExpression) != nil,
           let tail = stem.split(whereSeparator: { " -_.".contains($0) }).last,
           let value = Int(tail) {
            return value
        }
        return nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("手动匹配")
                .font(.system(size: 16, weight: .bold))
            Text(targetFilename)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let folderHint, !folderHint.isEmpty {
                Text("目录：\(folderHint)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let entry {
                Text(entry.matched
                     ? "当前匹配：\(entry.title)\(entry.year.map { "（\($0)）" } ?? "")"
                     : "当前未识别 · 选择候选项后只改写这一批文件")
                    .font(.system(size: 9.5))
                    .foregroundStyle(entry.matched ? LumaBrand.amber.opacity(0.85) : LumaBrand.coral)
                    .lineLimit(1)
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入片名 / 剧名", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await search() }
                    }

                Picker("", selection: $isTV) {
                    Text("电影").tag(false)
                    Text("剧集").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 118)

                TextField("年份", text: $yearText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)

                Button {
                    Task { await search() }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).count < 2)
            }

            HStack(spacing: 8) {
                Text("匹配来源")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $matchSource) {
                    ForEach(MatchSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .onChange(of: matchSource) { _, _ in
                    guard hasSearched else { return }
                    Task { await search() }
                }
                Spacer(minLength: 0)
                Text(matchSource == .all
                     ? "同时查全部已配置的数据源"
                     : "只查 \(matchSource.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if isSearching {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在搜索…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text(hasSearched ? (errorMessage ?? "没有找到候选") : "输入片名后搜索")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let errorMessage, hasSearched {
                    Text(errorMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("试试英文名、去掉季集号，或把年份清空。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(results, id: \.sourceKey) { match in
                        matchRow(match)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func matchRow(_ match: CinemaMatch) -> some View {
        Button {
            selectedKey = match.sourceKey
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let url = match.posterURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.06)
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(match.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let original = match.originalTitle, !original.isEmpty {
                        Text(original)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let year = match.year {
                            Text(String(year))
                        }
                        if let rating = match.rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(LumaBrand.amber)
                        }
                        if !match.genres.isEmpty {
                            Text(Array(match.genres.prefix(3)).joined(separator: " / "))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let provider = match.provider {
                    Text(provider.title)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(provider == .tmdb ? LumaBrand.violet : LumaBrand.amber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((provider == .tmdb ? LumaBrand.violet : LumaBrand.amber).opacity(0.12)))
                }

                Image(systemName: selectedKey == match.sourceKey ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selectedKey == match.sourceKey ? LumaBrand.amber : Color.secondary)
            }
            .padding(8)
            .background(selectedKey == match.sourceKey ? LumaBrand.amber.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selectedKey == match.sourceKey ? LumaBrand.amber.opacity(0.5)
                                                                 : Color.primary.opacity(0.06),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorMessage, !results.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !results.isEmpty {
                Text("共 \(results.count) 个候选 · \(targetCountText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Toggle("同目录同名一起匹配", isOn: $matchSiblings)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 10.5))
            }
            Spacer(minLength: 0)
            Button("取消") { dismiss() }
                .controlSize(.small)
            Button(needsEpisodeMapping ? "下一步：季集" : "应用匹配") {
                advance()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(LumaBrand.amber)
            .disabled(selectedKey == nil || isSearching)
        }
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        hasSearched = true
        errorMessage = nil
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let outcome = await store.cinemaSearchCandidates(query: query, isTV: isTV, year: year,
                                                         providers: matchSource.providers,
                                                         combineAll: matchSource == .all)
        results = outcome.matches
        errorMessage = outcome.error
        if selectedKey == nil || !results.contains(where: { $0.sourceKey == selectedKey }) {
            selectedKey = results.first?.sourceKey
        }
        isSearching = false
    }

    private var targetCountText: String {
        if entry != nil || photos.count <= 1 { return "只改当前这一条" }
        if needsEpisodeMapping { return "\(photos.count) 个视频 · 下一步确认季集" }
        return "应用到 \(photos.count) 个视频"
    }

    /// 带目录链解析：文件夹名里的「Season 02 / 第 3 季」也能补进预填结果。
    private func parseFilename(_ photo: PhotoItem) -> CinemaParsedName {
        let scope = store.cinemaScope(for: photo)
        let hint = store.cinemaEntries(for: scope)[photo.id]?.folderHint ?? folderHint
        return CinemaScraper.parse(filename: photo.displayFilename, folderHint: hint)
    }

    /// 多选视频 + 剧集：先选剧，再进季集映射页逐集确认。
    /// 单集只有文件名解析不出集号时才走映射页，避免每次都要多点一步。
    private var needsEpisodeMapping: Bool {
        guard entry == nil,
              let match = results.first(where: { $0.sourceKey == selectedKey }),
              match.isTV else { return false }
        if photos.count > 1 { return true }
        guard let photo = photos.first else { return false }
        return parseFilename(photo).episode == nil
    }

    private func advance() {
        guard let match = results.first(where: { $0.sourceKey == selectedKey }) else { return }
        if needsEpisodeMapping {
            chosenMatch = match
            prepareEpisodes()
            step = .episodes
        } else {
            applyMatch(match)
        }
    }

    private func applyMatch(_ match: CinemaMatch) {
        if let entry {
            store.applyCinemaMatch(match, to: entry)
            applySiblingsIfNeeded(match, photos: [entry.file.photoItem])
        } else if photos.count > 1 {
            store.applyCinemaMatch(match, to: photos, season: nil, episodes: [:])
        } else if let photo = photos.first {
            store.applyCinemaMatch(match, to: photo)
            applySiblingsIfNeeded(match, photos: [photo])
        }
        onApplied()
        dismiss()
    }

    private func applyEpisodes() {
        guard let match = chosenMatch else { return }
        var mapping: [UUID: Int] = [:]
        for row in rows {
            if let episode = Int(row.text.trimmingCharacters(in: .whitespaces)), episode > 0 {
                mapping[row.photo.id] = episode
            }
        }
        store.applyCinemaMatch(match, to: rows.map(\.photo), season: season, episodes: mapping)
        applySiblingsIfNeeded(match, photos: rows.map(\.photo))
        onApplied()
        dismiss()
    }

    /// 同目录同名多版本 / 同剧其它集：一次套用同一个候选，已匹配的不重复处理。
    private func applySiblingsIfNeeded(_ match: CinemaMatch, photos: [PhotoItem]) {
        guard matchSiblings else { return }
        var extras: [PhotoItem] = []
        var seen: Set<UUID> = []
        for photo in photos {
            for sibling in store.cinemaMatchSiblings(of: photo) where seen.insert(sibling.id).inserted {
                extras.append(sibling)
            }
        }
        guard !extras.isEmpty else { return }
        store.applyCinemaMatch(match, to: extras, season: nil, episodes: [:])
    }
}

// MARK: - 继续观看卡片

private struct CinemaContinueCard: View {
    let record: CinemaProgressRecord
    let onOpen: () -> Void

    @State private var hovered = false

    private var remainingText: String {
        let minutes = Int(record.remainingSeconds / 60)
        if minutes >= 60 {
            return "还剩 \(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "还剩 \(max(1, minutes)) 分钟"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                CinemaArtwork(urlString: record.artworkURL, contentMode: .fill)
                    .frame(width: 236, height: 133)
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.78)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Text(record.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 12)

                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.94)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .opacity(hovered ? 1 : 0.92)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule()
                            .fill(LumaBrand.amber)
                            .frame(width: max(3, geo.size.width * record.fraction))
                    }
                }
                .frame(height: 3)
            }
            .frame(width: 236, height: 133)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.85)
                                          : Color.white.opacity(0.10),
                                  lineWidth: 1)
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .animation(.easeOut(duration: 0.16), value: hovered)

            HStack(spacing: 6) {
                Text(remainingText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(Int(record.fraction * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 236)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("继续播放 \(record.title)")
    }
}

// MARK: - 远程海报

private struct CinemaArtwork: View {
    let urlString: String?
    var contentMode: ContentMode = .fill
    /// 解码上限（像素）：卡片按列宽量级取图，详情底图再取大一点，避免整张原图常驻内存。
    var maxPixelSize: Int = 800
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.20),
                                        Color(nsColor: .quaternaryLabelColor).opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            } else {
                CinemaShimmer()
            }
        }
        .task(id: "\(urlString ?? "")|\(maxPixelSize)") {
            guard let urlString else {
                image = nil
                failed = true
                return
            }
            let loaded = await CinemaArtworkCache.shared.image(for: urlString, maxPixelSize: maxPixelSize)
            if let loaded {
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            } else {
                failed = true
            }
        }
    }
}

/// 海报占位流光：加载中不显示一块死灰，而是缓慢扫过一道高光。
struct CinemaShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                                        Color(nsColor: .quaternaryLabelColor).opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.clear, .white.opacity(0.16), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(40, proxy.size.width * 0.5))
                    .offset(x: phase * proxy.size.width)
            }
            .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}

// MARK: - 相似推荐

/// 相似推荐横条：只展示，点击回本库找同 tmdbID 的条目。
private struct CinemaRecommendationShelf: View {
    let groups: [CinemaRecommendationGroup]
    /// 本库是否已有这部：悬停时给出「本库已有 / 未入库」提示。
    let isLocal: (CinemaRecommendation) -> Bool
    let onOpen: (CinemaRecommendation) -> Void
    let onSearchOnline: (CinemaRecommendation) -> Void
    /// 豆瓣条目：只能外部打开。
    let onOpenExternal: (CinemaRecommendation) -> Void

    /// 悬停项：与演职员头像一致的抬起、琥珀描边、右上角 ↗ 角标。
    @State private var hovered: String?
    @State private var activeSource: CinemaRecommendationGroup.Source?

    private var activeGroup: CinemaRecommendationGroup? {
        if let activeSource,
           let group = groups.first(where: { $0.source == activeSource }) {
            return group
        }
        return groups.first
    }

    @ViewBuilder
    var body: some View {
        if let group = activeGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(LumaBrand.amber)
                        .frame(width: 3, height: 14)
                    Text("相似推荐")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(group.items.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(group.items) { item in
                            card(item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(groups) { group in
                let active = group.source == activeGroup?.source
                Button {
                    activeSource = group.source
                } label: {
                    Text("\(group.title) \(group.items.count)")
                        .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? .black : Color.white.opacity(0.72))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(active ? LumaBrand.amber : Color.white.opacity(0.10),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func card(_ item: CinemaRecommendation) -> some View {
        let active = hovered == item.id
        let local = isLocal(item)
        return Button {
            onOpen(item)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                CinemaArtwork(urlString: item.posterURL, contentMode: .fill, maxPixelSize: 420)
                    .frame(width: 108, height: 162)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(active ? LumaBrand.amber.opacity(0.85) : .white.opacity(0.10),
                                          lineWidth: active ? 1.4 : 0.6)
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 17, height: 17)
                            .background(LumaBrand.amber, in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5) }
                            .padding(6)
                            .scaleEffect(active ? 1 : 0.4)
                            .opacity(active ? 1 : 0)
                            .offset(x: 1.5, y: 1.5)
                    }
                Text(item.title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? LumaBrand.amber : .white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(item.kind == .tv ? "剧集" : "电影")
                        .foregroundStyle(.white.opacity(0.45))
                    if let year = item.year {
                        Text(String(year))
                    }
                    if let rating = item.rating, rating > 0 {
                        Text(String(format: "★ %.1f", rating))
                            .foregroundStyle(LumaBrand.amber.opacity(0.9))
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(active ? .white.opacity(0.72) : .secondary)
                // 悬停时补一行状态：本库已有直接进详情，未入库去网络影院。
                // 常驻占位，悬停时高度不跳。
                Text(local ? "本库已有 · 点击查看" : "未入库 · 点击去网络影院")
                    .font(.system(size: 9))
                    .foregroundStyle(local ? LumaBrand.mint : LumaBrand.amber.opacity(0.9))
                    .lineLimit(1)
                    .opacity(active ? 1 : 0)
            }
            .frame(width: 108, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(active ? 1.03 : 1)
        .offset(y: active ? -2 : 0)
        .shadow(color: LumaBrand.amber.opacity(active ? 0.35 : 0), radius: 9, y: 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: active)
        .onHover { inside in
            if inside {
                hovered = item.id
            } else if hovered == item.id {
                hovered = nil
            }
        }
        .contextMenu {
            if item.doubanID != nil {
                Button("在豆瓣打开「\(item.title)」") { onOpenExternal(item) }
            } else {
                Button("网络影院搜索「\(item.title)」（即将上线）") { onSearchOnline(item) }
            }
        }
        .help("点击查看；右键可在网络影院搜索（即将上线）")
    }
}

// MARK: - 焦点环

/// 详情页滚动偏移：用顶部锚点在滚动坐标系里的位置判断是否滚过档案卡。
private struct CinemaScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 统一的键盘焦点环：列表行、集卡都用同一套描边与柔光，避免各处风格不一。
private struct CinemaFocusRing: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.9), lineWidth: 2)
                    .shadow(color: LumaBrand.amber.opacity(0.35), radius: 6)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 手动选封面

private enum CinemaArtworkKind: String, Identifiable {
    case poster
    case backdrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .poster: return "海报"
        case .backdrop: return "背景"
        }
    }
}

private struct CinemaArtworkPickerRequest: Identifiable {
    let id = UUID()
    let kind: CinemaArtworkKind
    let entry: CinemaEntry
}

/// 封面候选面板：打开时自己去拉候选，详情页 / 卡片 / 列表行共用同一份实现。
private struct CinemaArtworkPickerSheet: View {
    let kind: CinemaArtworkKind
    let entry: CinemaEntry
    let onPick: (String) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [CinemaArtworkCandidate] = []
    @State private var loading = true
    /// 没匹配 / 拉不到图时直接写在面板里，不再弹完再提示。
    @State private var message: String?

    private var tileSize: CGSize {
        kind == .poster ? CGSize(width: 130, height: 195) : CGSize(width: 240, height: 135)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("选择\(kind.title)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                Text(loading ? "加载中…" : "\(candidates.count) 张")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                Spacer(minLength: 0)
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaBrand.amber)
            }
            .padding(16)

            Divider().opacity(0.25)

            Group {
                if loading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在获取\(kind.title)…")
                            .font(.system(size: 11))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.35))
                        Text(message ?? "没有找到可用的\(kind.title)")
                            .font(.system(size: 12))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize.width), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(candidates) { candidate in
                                Button {
                                    onPick(candidate.url)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        CinemaArtwork(urlString: candidate.url,
                                                      contentMode: .fill,
                                                      maxPixelSize: 520)
                                            .frame(width: tileSize.width, height: tileSize.height)
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .strokeBorder(CinemaDetailTone.ink.opacity(0.16), lineWidth: 0.8)
                                            }
                                        HStack(spacing: 6) {
                                            Text(candidate.language ?? "原版")
                                            if let rating = candidate.rating, rating > 0 {
                                                Text(String(format: "★ %.1f", rating))
                                                    .foregroundStyle(LumaBrand.amber.opacity(0.9))
                                            }
                                        }
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(CinemaDetailTone.page)
        .task { await load() }
    }

    private func load() async {
        guard entry.matched, entry.tmdbID != nil else {
            loading = false
            message = "先匹配这部片，才能更换\(kind.title)"
            return
        }
        let result = await store.cinemaArtworkCandidates(for: entry)
        candidates = kind == .poster ? result.posters : result.backdrops
        if candidates.isEmpty { message = "没有找到可用的\(kind.title)" }
        loading = false
    }
}

// MARK: - 影院内搜索

private struct CinemaSearchPanel: View {
    let onOpen: (CinemaEntry) -> Void
    let onOpenSeries: (CinemaSeries) -> Void
    let onPlay: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// 搜索范围：默认只看已入库，可切到含未识别文件名。
    @State private var includeUnmatched = false
    @State private var personTarget: CinemaCastMember?
    @FocusState private var focused: Bool
    /// 键盘游标：↑↓ 在电影 / 剧集 / 人物三组之间移动，⏎ 详情、⌘⏎ 播放。
    @State private var cursor = 0
    @State private var keyMonitor: Any?

    /// 把三组结果拍平，便于键盘顺序选择。
    private enum SearchRow: Equatable {
        case entry(UUID)
        case series(String)
        case person(String)
    }

    private var flatRows: [SearchRow] {
        results.entries.map { .entry($0.id) }
            + results.series.map { .series($0.id) }
            + results.people.map { .person($0.name) }
    }

    private var results: (entries: [CinemaEntry], series: [CinemaSeries], people: [CinemaCastMember]) {
        store.cinemaSearchResults(query, includeUnmatched: includeUnmatched)
    }

    private var totalCount: Int {
        results.entries.count + results.series.count + results.people.count
    }
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            scopeBar
            Divider()
            content
        }
        .frame(width: 660, height: 560)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { _, _ in cursor = 0 }
        .sheet(item: $personTarget) { member in
            CinemaPersonSheet(member: member)
                .environmentObject(store)
        }
    }

    // MARK: 键盘

    /// 搜索框聚焦时，SwiftUI 的 ↑↓ 会被文本编辑器吃掉；用本地监听保证结果之间能顺着选。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 人物页弹出时把键盘交还给那个 sheet。
            guard personTarget == nil else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 125:   // ↓
                guard !modifiers.contains(.command) else { return event }
                moveCursor(1)
                return nil
            case 126:   // ↑
                guard !modifiers.contains(.command) else { return event }
                moveCursor(-1)
                return nil
            case 36, 76: // Return / 小键盘 Enter
                guard isSearching, !flatRows.isEmpty else { return event }
                if modifiers.contains(.command) {
                    playCursorRow()
                } else {
                    openCursorRow()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func moveCursor(_ delta: Int) {
        let count = flatRows.count
        guard count > 0 else { return }
        cursor = min(max(cursor + delta, 0), count - 1)
    }

    private func cursorRow() -> SearchRow? {
        let rows = flatRows
        guard rows.indices.contains(cursor) else { return nil }
        return rows[cursor]
    }

    private func openCursorRow() {
        guard let row = cursorRow() else { return }
        switch row {
        case .entry(let id):
            if let entry = results.entries.first(where: { $0.id == id }) { onOpen(entry) }
        case .series(let id):
            if let item = results.series.first(where: { $0.id == id }) { onOpenSeries(item) }
        case .person(let name):
            if let person = results.people.first(where: { $0.name == name }) { personTarget = person }
        }
    }

    private func playCursorRow() {
        guard let row = cursorRow() else { return }
        switch row {
        case .entry(let id):
            if let entry = results.entries.first(where: { $0.id == id }) { onPlay(entry) }
        case .series(let id):
            if let item = results.series.first(where: { $0.id == id }),
               let latest = item.latestEpisode {
                onPlay(latest)
            }
        case .person:
            break
        }
    }

    /// 范围说明：让用户知道搜的是本库还是包含未识别文件名。
    private var scopeBar: some View {
        HStack(spacing: 6) {
            Text("范围")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            scopeChip("仅本库", active: !includeUnmatched) {
                includeUnmatched = false
            }
            scopeChip("含未识别文件名", active: includeUnmatched) {
                includeUnmatched = true
            }
            Spacer(minLength: 0)
            Text("↑↓ 选择 · ⏎ 详情 · ⌘⏎ 播放")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text("在「\(store.cinemaScopeName(store.cinemaActiveScope))」里检索")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func scopeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(active ? LumaBrand.amber.opacity(0.14)
                                                  : Color.primary.opacity(0.05)))
                .overlay {
                    Capsule().strokeBorder(active ? LumaBrand.amber.opacity(0.32)
                                                  : Color.primary.opacity(0.08), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索片名、演员、导演、类型或文件名", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
            Divider().frame(height: 16)
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if !isSearching {
            VStack(alignment: .leading, spacing: 8) {
                Text("在「\(store.cinemaScopeName(store.cinemaActiveScope))」里检索")
                    .font(.system(size: 12, weight: .medium))
                Text("支持片名、原名、文件名、类型，以及补全后的演员与导演。示例：诺兰、科幻、S01E02.mkv。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.cinemaParentalLocked {
                    Label("家长控制已启用，受限分级内容不会出现在结果里。",
                          systemImage: "lock.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LumaBrand.coral)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if totalCount == 0 {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("没有找到匹配内容")
                    .font(.system(size: 12, weight: .medium))
                Text("试试更短的关键词，或先在详情页重新匹配 / 补全演职员。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !results.entries.isEmpty {
                        sectionTitle("电影", count: results.entries.count)
                        ForEach(Array(results.entries.enumerated()), id: \.element.id) { index, entry in
                            movieRow(entry, highlighted: cursor == index)
                        }
                    }
                    if !results.series.isEmpty {
                        sectionTitle("剧集", count: results.series.count)
                        let offset = results.entries.count
                        ForEach(Array(results.series.enumerated()), id: \.element.id) { index, item in
                            seriesRow(item, highlighted: cursor == offset + index)
                        }
                    }
                    if !results.people.isEmpty {
                        sectionTitle("人物", count: results.people.count)
                        let offset = results.entries.count + results.series.count
                        ForEach(Array(results.people.enumerated()), id: \.offset) { index, person in
                            personRow(person, highlighted: cursor == offset + index)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func movieRow(_ entry: CinemaEntry, highlighted: Bool = false) -> some View {
        HStack(spacing: 10) {
            Button {
                onOpen(entry)
            } label: {
                HStack(spacing: 10) {
                    poster(url: entry.posterURL, photo: entry.file.photoItem, width: 44, height: 66)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if let original = entry.originalTitle, !original.isEmpty {
                            Text(original)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(detailLine(entry))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(sourceLabel(entry))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

            Button {
                onPlay(entry)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(LumaBrand.amber, in: Circle())
            }
            .buttonStyle(.plain)
            .help("播放 \(entry.title)")
        }
        .padding(8)
        .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear, lineWidth: 0.8)
        }
    }

    private func seriesRow(_ item: CinemaSeries, highlighted: Bool = false) -> some View {
        Button {
            onOpenSeries(item)
        } label: {
            HStack(spacing: 10) {
                poster(url: item.posterURL, photo: item.episodes.first?.file.photoItem, width: 44, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let genres = item.episodes.first?.genres, !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: " / "))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(sourceLabel(item.episodes.first))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear,
                                  lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func personRow(_ person: CinemaCastMember, highlighted: Bool = false) -> some View {
        Button {
            personTarget = person
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let url = person.profileURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.18))
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(person.character ?? "演职员")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("人物页 ›")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear,
                                  lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func poster(url: String?, photo: PhotoItem?, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let url {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(height * 2))
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// 结果来源：本地图库标「本库」，网盘标挂载名。
    private func sourceLabel(_ entry: CinemaEntry?) -> String {
        guard let entry, let id = entry.file.cloudMountID else { return "本库" }
        return store.cloudMounts.first { $0.id == id }?.name ?? "网盘"
    }

    private func detailLine(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        if let genres = entry.genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: " / "))
        }
        if let cast = entry.cast, let first = cast.first {
            parts.append(first.name)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 观看记录

private struct CinemaHistoryPanel: View {
    let scope: CinemaScope
    let onResume: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingClear = false
    @State private var pendingRemoval: CinemaProgressRecord?
    /// 文档约定：观看记录可按「全部 / 进行中 / 已看完」分段，并按今天 / 本周 / 更早分组。
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, inProgress, finished
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .inProgress: return "进行中"
            case .finished: return "已看完"
            }
        }
    }

    private var records: [CinemaProgressRecord] {
        store.cinemaHistory(for: scope)
    }

    private var filteredRecords: [CinemaProgressRecord] {
        switch filter {
        case .all: return records
        case .inProgress: return records.filter { !$0.isFinished }
        case .finished: return records.filter(\.isFinished)
        }
    }

    /// 今天 / 本周 / 更早三段；空段不显示。
    private var groupedRecords: [(title: String, records: [CinemaProgressRecord])] {
        let calendar = Calendar.current
        let now = Date()
        var today: [CinemaProgressRecord] = []
        var week: [CinemaProgressRecord] = []
        var earlier: [CinemaProgressRecord] = []
        for record in filteredRecords {
            if calendar.isDateInToday(record.updatedAt) {
                today.append(record)
            } else if calendar.isDate(record.updatedAt, equalTo: now, toGranularity: .weekOfYear) {
                week.append(record)
            } else {
                earlier.append(record)
            }
        }
        return [("今天", today), ("本周", week), ("更早", earlier)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, records: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有观看记录")
                        .font(.system(size: 12, weight: .medium))
                    Text("从影院播放任意影片后，进度会出现在这里。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: filter == .finished ? "checkmark.circle" : "play.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(filter == .finished ? "还没有看完的影片" : "没有进行中的影片")
                        .font(.system(size: 12, weight: .medium))
                    Button("查看全部") { filter = .all }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedRecords, id: \.title) { group in
                            HStack(spacing: 6) {
                                Text(group.title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("\(group.records.count)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 4)
                            ForEach(group.records) { record in
                                row(record)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("清除全部观看记录？", isPresented: $pendingClear) {
            Button("清除", role: .destructive) { store.clearCinemaProgress() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空继续观看与所有进度，影片文件不受影响。")
        }
        .confirmationDialog("移出这条观看记录？",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { record in
            Button("移出记录", role: .destructive) {
                store.removeCinemaProgress(record.id)
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: { record in
            Text("「\(record.title)」的进度会被移除，影片文件不受影响。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("观看记录")
                .font(.system(size: 15, weight: .semibold))
            Text("\(filteredRecords.count) 条")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            Spacer(minLength: 0)
            if !records.isEmpty {
                Button("清除全部…") { pendingClear = true }
                    .controlSize(.small)
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func row(_ record: CinemaProgressRecord) -> some View {
        let entry = store.cinemaEntries(for: scope)[record.photoID]
        return HStack(spacing: 10) {
            ZStack {
                if let url = record.artworkURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else if let entry {
                    PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(120))
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 96, height: 54)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                    }
                    Text(record.isFinished ? "已看完" : "剩余 \(remainingText(record))")
                        .foregroundStyle(record.isFinished ? Color.secondary : LumaBrand.amber)
                }
                .font(.system(size: 10))
                .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(record.isFinished ? Color.secondary.opacity(0.5) : LumaBrand.amber)
                            .frame(width: max(3.0, geo.size.width * record.fraction))
                    }
                }
                .frame(height: 3)
            }

            Spacer(minLength: 0)

            if let entry {
                if !record.isFinished {
                    Button {
                        onResume(entry)
                    } label: {
                        Label("继续", systemImage: "play.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .controlSize(.small)
                }
                Button {
                    pendingRemoval = record
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
                .help("移出观看记录")
            } else {
                Text("文件已不在影院")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func remainingText(_ record: CinemaProgressRecord) -> String {
        let minutes = Int((record.remainingSeconds / 60).rounded())
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(max(1, minutes)) 分钟"
    }
}


// MARK: - 右上角 Toast 栈（F4）

private struct CinemaToastStack: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.cinemaToasts) { toast in
                card(toast)
            }
        }
        .frame(width: 340, alignment: .trailing)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(.snappy(duration: 0.2), value: store.cinemaToasts.map(\.id))
    }

    private func card(_ toast: CinemaToast) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(toast.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint(toast.kind))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    store.dismissCinemaToast(toast.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            }

            Button {
                store.dismissCinemaToast(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tint(toast.kind).opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func icon(_ kind: CinemaToastKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .progress: return "arrow.down.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func tint(_ kind: CinemaToastKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return LumaBrand.coral
        case .progress: return LumaBrand.amber
        case .info: return LumaBrand.violet
        }
    }
}

// MARK: - 人物页（B4）

/// 演职员页：作为影院详情里的二级页铺满内容区（不弹窗），
/// 版式和「剧集档案」同一套：深色玻璃卡 + 琥珀渐变描边 + 大头像作视觉锚点。
private struct CinemaPersonDetailView: View {
    let member: CinemaCastMember
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    var onPlay: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore

    private enum Lane: String, CaseIterable, Identifiable {
        case library = "本库已有"
        case all = "全部作品"
        var id: String { rawValue }
    }

    @State private var lane: Lane = .library
    @State private var profile: CinemaPersonProfile?
    @State private var loading = true
    @State private var bioExpanded = false
    /// 悬停作品：key 是本库条目 UUID 或 TMDB credit id。
    @State private var hoveredWorkKey: String?
    @State private var workHoverHeight: CGFloat = 300
    /// 未入库作品悬停时按需补的 TMDB 详情（简介 / 评分 / 类型 / 片长）。
    @State private var creditDetails: [String: CinemaDetails] = [:]
    @State private var creditDetailLoading: Set<String> = []

    /// 默认按最新排序：年份新的在前，没有年份的排最后。
    private var works: [CinemaEntry] {
        store.cinemaPersonWorks(named: member.name)
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    private var credits: [CinemaPersonCredit] {
        (profile?.credits ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    var body: some View {
        // 和剧集 / 影片详情同一套结构：底图挂 background，不参与页面尺寸推导。
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileCard
                    worksSection(width: width)
                }
                .padding(.horizontal, horizontal)
                .padding(.bottom, 36)
                // 只填满可视宽度：固定 width 会变成窗口最小宽度，缩下去就回不来。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(alignment: .top) { ambient }
        // 悬停作品档案：挂在页面最上层，贴着卡片显示，又不会被滚动区裁掉。
        .overlayPreferenceValue(CinemaWorkAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let key = hoveredWorkKey, let anchor = anchors[key] {
                    let rect = proxy[anchor]
                    let margin: CGFloat = 12
                    let gap: CGFloat = 14
                    let width = min(340, max(240, proxy.size.width - margin * 2))
                    let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                    let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                    let x = min(max(margin, rawX), max(margin, proxy.size.width - width - margin))
                    let y = min(max(margin, rect.minY),
                                max(margin, proxy.size.height - workHoverHeight - margin))
                    workHoverCard(key)
                        .frame(width: width)
                        // GeometryReader 会把整个浮层高度提给子视图，卡片必须按内容自适应，
                        // 否则里面的 Spacer 会把简介顶到面板底部，中间空出一大块。
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { workHoverHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { _, height in
                                        workHoverHeight = height
                                    }
                            }
                        }
                        .offset(x: x, y: y)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: hoveredWorkKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaDetailTone.page)
        .task {
            if member.tmdbID != nil {
                profile = await store.cinemaPersonProfile(for: member)
            }
            loading = false
        }
    }

    /// 用本库作品的海报虚化铺底：和影院其他详情页一致的氛围层。
    private var ambient: some View {
        ZStack(alignment: .top) {
            CinemaDetailTone.page
            CinemaArtwork(urlString: works.first?.backdropURL ?? works.first?.posterURL,
                          contentMode: .fill)
                .frame(height: 720)
                .blur(radius: 90, opaque: true)
                .opacity(0.16)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.72), location: 0.34),
                        .init(color: .black.opacity(0.22), location: 0.70),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }


    // MARK: 档案卡

    /// 大头像 + 姓名 / 角色 / 生卒地 / 简介：和「剧集档案」同一张玻璃卡。
    private var profileCard: some View {
        HStack(alignment: .top, spacing: 26) {
            avatarColumn
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("演职员档案")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(CinemaDetailTone.accent.opacity(0.92))
                    Rectangle()
                        .fill(LumaBrand.amber.opacity(0.35))
                        .frame(width: 24, height: 0.8)
                    Text(departmentText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(member.name)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .textSelection(.enabled)

                if let character = member.character, !character.isEmpty {
                    Text("饰 \(character)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }

                chipRow

                Button {
                    store.searchOnlineCinema(member.name)
                } label: {
                    Label("网络影院搜索 · 即将上线", systemImage: "globe")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(LumaBrand.amber.opacity(0.14), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(LumaBrand.amber.opacity(0.35), lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .help("网络影院还没上线，先用 TA 的名字占个位置")

                bioBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.062),
                                              CinemaDetailTone.ink.opacity(0.022)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            CinemaDetailTone.ink.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
    }

    /// 头像 + 本库作品数：圆形头像带琥珀细环和外圈留白，像一张档案照。
    private var avatarColumn: some View {
        VStack(spacing: 12) {
            ZStack {
                if let url = profile?.profileURL ?? member.profileURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    Circle().fill(CinemaDetailTone.ink.opacity(0.06))
                    Image(systemName: "person.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.35))
                }
            }
            .frame(width: 172, height: 172)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(LumaBrand.amber.opacity(0.30), lineWidth: 1.2)
            }
            .overlay {
                Circle().strokeBorder(CinemaDetailTone.ink.opacity(0.06), lineWidth: 0.8)
                    .padding(-7)
            }
            .shadow(color: LumaBrand.amber.opacity(0.16), radius: 26, y: 12)

            HStack(spacing: 5) {
                Image(systemName: "film.stack")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("本库 \(works.count) 部")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.80))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
        }
        .frame(width: 172, alignment: .top)
    }

    private var chipRow: some View {
        HStack(spacing: 7) {
            chip("本库 \(works.count) 部", highlight: true)
            chip("全部 \(credits.isEmpty ? "—" : "\(credits.count)") 部")
            if let birthday = profile?.birthday, !birthday.isEmpty {
                chip(birthday)
            }
            if let place = profile?.placeOfBirth, !place.isEmpty {
                chip(place)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var bioBlock: some View {
        if let bio = profile?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(bio)
                    .font(.system(size: 12.5))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.76))
                    .lineSpacing(6)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if bio.count > 160 {
                    Button(bioExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            bioExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        } else if loading {
            ProgressView().controlSize(.mini)
        } else {
            Text(works.isEmpty
                 ? "本库还没有这位参与的作品，重新刮削后可看到更多资料。"
                 : "本库已收录 \(works.count) 部，可直接播放。")
                .font(.system(size: 11.5))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
        }
    }

    private var departmentText: String {
        guard let department = profile?.department, !department.isEmpty else { return "演职员" }
        switch department {
        case "Acting": return "演员"
        case "Directing": return "导演"
        case "Writing": return "编剧"
        case "Production": return "制片"
        case "Camera": return "摄影"
        case "Art": return "美术"
        case "Sound": return "音效"
        case "Editing": return "剪辑"
        case "Costume & Make-Up": return "造型"
        case "Visual Effects": return "视效"
        default: return department
        }
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(highlight ? LumaBrand.amber.opacity(0.12)
                                                 : Color.primary.opacity(0.06)))
            .overlay {
                Capsule().strokeBorder(highlight ? LumaBrand.amber.opacity(0.30)
                                                 : Color.primary.opacity(0.08), lineWidth: 0.6)
            }
    }

    /// 作品区：标题行 + 本库 / 全部切换 + 海报网格。
    private func worksSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("作品")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(lane == .library ? works.count : credits.count) 部")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                Spacer(minLength: 0)
                laneSwitch
            }
            content(width: width)
        }
    }

    private var laneSwitch: some View {
        HStack(spacing: 4) {
            ForEach(Lane.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.16)) { lane = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(lane == item ? LumaBrand.amber.opacity(0.16)
                                                   : CinemaDetailTone.ink.opacity(0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(lane == item ? LumaBrand.amber.opacity(0.35)
                                                           : CinemaDetailTone.ink.opacity(0.07),
                                              lineWidth: 0.7)
                        }
                        .foregroundStyle(lane == item ? LumaBrand.amber
                                                      : CinemaDetailTone.ink.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
            if loading {
                ProgressView().controlSize(.mini).padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch lane {
        case .library:
            if works.isEmpty {
                emptyHint("本库暂时没有这位参与的作品",
                          detail: "到海报墙右键影片重新刮削，补全演职员后这里会自动出现。")
            } else {
                grid(width: width) {
                    ForEach(works) { entry in
                        workTile(entry)
                            .anchorPreference(key: CinemaWorkAnchorKey.self, value: .bounds) {
                                [entry.id.uuidString: $0]
                            }
                    }
                }
            }
        case .all:
            if loading {
                ProgressView("正在读取 TMDB 作品…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if profile == nil {
                emptyHint("没有可用的 TMDB 人物资料",
                          detail: "重新刮削这部影片后会补上人物 ID，就能看到全部作品。")
            } else if credits.isEmpty {
                emptyHint("TMDB 没有收录这位的作品", detail: "可以试试搜索片名或导演。")
            } else {
                grid(width: width) {
                    ForEach(credits) { credit in
                        creditTile(credit)
                            .anchorPreference(key: CinemaWorkAnchorKey.self, value: .bounds) {
                                [credit.id: $0]
                            }
                    }
                }
            }
        }
    }

    /// 海报列数按内容列宽推导：窗口变宽就多排一列，卡片宽度平分剩余空间。
    private func workColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 16
        let width = width > 0 ? width : 900
        let count = max(2, GridLayout.columns(contentWidth: width, targetSize: 190, spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 150), spacing: spacing), count: count)
    }

    private func grid<Content: View>(width: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: workColumns(width: width),
                  alignment: .leading, spacing: 18) {
            content()
        }
    }

    private func workTile(_ entry: CinemaEntry) -> some View {
        Button {
            play(entry)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                poster(url: entry.artworkURL, photo: entry.file.photoItem)
                    .overlay(alignment: .topLeading) {
                        ownedBadge
                    }
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.kind == .tv ? "剧集 · \(entry.year.map(String.init) ?? "—")"
                                       : (entry.year.map(String.init) ?? "—"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("查看详情") { openDetail(entry) }
            Button("直接播放") { play(entry) }
        }
        .onHover { hovering in
            if hovering {
                hoveredWorkKey = entry.id.uuidString
            } else if hoveredWorkKey == entry.id.uuidString {
                hoveredWorkKey = nil
            }
        }
        .animation(.easeOut(duration: 0.14), value: hoveredWorkKey)
        .help("点击播放")
    }

    private func creditTile(_ credit: CinemaPersonCredit) -> some View {
        let owned = store.cinemaEntry(forCredit: credit)
        return Button {
            if let owned { play(owned) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                poster(url: credit.posterURL, photo: nil)
                    .overlay(alignment: .topLeading) {
                        if owned != nil { ownedBadge }
                    }
                Text(credit.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle(for: credit))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 未入库的卡片整体压暗，鼠标移上来恢复原色。
            .opacity(owned == nil && hoveredWorkKey != credit.id ? 0.55 : 1)
            .animation(.easeOut(duration: 0.16), value: hoveredWorkKey)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredWorkKey = credit.id
                Task { await loadCreditDetails(credit) }
            } else if hoveredWorkKey == credit.id {
                hoveredWorkKey = nil
            }
        }
        .help(owned == nil ? "未入库，只做展示" : "点击播放")
    }

    /// 悬停时按需补一次 TMDB 详情，失败就保持基础信息。
    private func loadCreditDetails(_ credit: CinemaPersonCredit) async {
        guard creditDetails[credit.id] == nil, !creditDetailLoading.contains(credit.id) else { return }
        creditDetailLoading.insert(credit.id)
        if let details = await store.cinemaCreditDetails(for: credit) {
            creditDetails[credit.id] = details
        }
        creditDetailLoading.remove(credit.id)
    }

    private func subtitle(for credit: CinemaPersonCredit) -> String {
        var parts: [String] = []
        parts.append(credit.isTV ? "剧集" : "电影")
        if let year = credit.year { parts.append(String(year)) }
        if let job = credit.job, !job.isEmpty { parts.append(job) }
        else if let character = credit.character, !character.isEmpty { parts.append(character) }
        return parts.joined(separator: " · ")
    }

    // MARK: 作品悬停档案

    @ViewBuilder
    private func workHoverCard(_ key: String) -> some View {
        if let entry = works.first(where: { $0.id.uuidString == key }) {
            workHoverCard(entry: entry)
        } else if let credit = credits.first(where: { $0.id == key }) {
            workHoverCard(credit: credit)
        }
    }

    /// 本库作品：海报 + 评分 / 类型 + 简介 + 规格与观看进度。
    private func workHoverCard(entry: CinemaEntry) -> some View {
        let tags = cinemaBadgeTags(entry.file, limit: 4)
        let progress = store.cinemaProgress[entry.id]
        let overview = entry.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hoverShell {
            HStack(alignment: .top, spacing: 12) {
                hoverPoster(url: entry.artworkURL, photo: entry.file.photoItem)
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let rating = entry.rating, rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            if let votes = entry.voteCount, votes > 0 {
                                Text("· \(voteText(votes))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                            }
                        }
                        .foregroundStyle(LumaBrand.amber)
                    }
                    Text(entryMeta(entry))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(2)
                    hoverLibraryChip(inLibrary: true)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            if !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 12))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.88))
                    .lineSpacing(5.5)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            if !tags.isEmpty {
                CinemaSpecBadges(tags: tags, fontSize: 9, tint: CinemaDetailTone.ink,
                                 background: CinemaDetailTone.ink.opacity(0.10))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            if let progress, progress.fraction > 0.01 {
                HStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(CinemaDetailTone.ink.opacity(0.14))
                            Capsule()
                                .fill(LumaBrand.amber)
                                .frame(width: max(3, geo.size.width * progress.fraction))
                        }
                    }
                    .frame(height: 3)
                    Text(progress.isFinished ? "已看完" : "已看 \(Int(progress.fraction * 100))%")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumaBrand.amber)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            hoverFooter("点击播放 · 右键查看详情")
        }
    }

    /// 未入库作品：基础资料 + 悬停时补来的 TMDB 简介 / 评分 / 类型 / 片长。
    private func workHoverCard(credit: CinemaPersonCredit) -> some View {
        let owned = store.cinemaEntry(forCredit: credit)
        let details = creditDetails[credit.id]
        let loadingDetails = creditDetailLoading.contains(credit.id)
        let role = credit.character.flatMap { $0.isEmpty ? nil : $0 } ?? credit.job
        let overview = details?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hoverShell {
            HStack(alignment: .top, spacing: 12) {
                hoverPoster(url: credit.posterURL, photo: nil)
                VStack(alignment: .leading, spacing: 7) {
                    Text(credit.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let rating = details?.rating, rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            if let votes = details?.voteCount, votes > 0 {
                                Text("· \(voteText(votes))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                            }
                        }
                        .foregroundStyle(LumaBrand.amber)
                    }

                    Text(creditMeta(credit, details: details))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(2)

                    if let role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
                            .lineLimit(2)
                    }

                    if let genres = details?.genres, !genres.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(genres.prefix(3), id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 9))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.76))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(CinemaDetailTone.ink.opacity(0.10), in: Capsule())
                            }
                        }
                    }

                    hoverLibraryChip(inLibrary: owned != nil)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            if !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 12))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.88))
                    .lineSpacing(5.5)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else if loadingDetails {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在读取简介…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            if owned == nil {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("TMDB 收录的作品，本库暂未收录，只在演职员页做展示。")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.62))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            hoverFooter(owned == nil ? "未入库 · 仅展示" : "点击播放")
        }
    }

    /// 未入库作品的元信息：类型 / 年份 / 片长或季集 / 上映日期。
    private func creditMeta(_ credit: CinemaPersonCredit, details: CinemaDetails?) -> String {
        var parts: [String] = [credit.isTV ? "剧集" : "电影"]
        if let year = credit.year { parts.append(String(year)) }
        if let details {
            if let runtime = details.runtime, runtime > 0 {
                parts.append(credit.isTV ? "每集 \(runtime) 分钟" : "\(runtime) 分钟")
            }
            if credit.isTV,
               let seasons = details.seasonCount,
               let episodes = details.episodeCount {
                parts.append("\(seasons) 季 · \(episodes) 集")
            }
            if let release = details.releaseDate, !release.isEmpty {
                parts.append(credit.isTV ? "首播 \(release)" : "上映 \(release)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func hoverShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(CinemaDetailTone.plate)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.26), lineWidth: 0.8)
        }
        .shadow(color: CinemaDetailTone.shadow(0.58), radius: 26, y: 13)
    }

    private func hoverPoster(url: String?, photo: PhotoItem?) -> some View {
        Group {
            if let url {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(200))
            } else {
                CinemaDetailTone.ink.opacity(0.06)
            }
        }
        .frame(width: 74, height: 111)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.10), lineWidth: 0.6)
        }
    }

    private func hoverLibraryChip(inLibrary: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(inLibrary ? LumaBrand.amber : CinemaDetailTone.ink.opacity(0.35))
                .frame(width: 4, height: 4)
            Text(inLibrary ? "在库 · 可直接播放" : "未入库 · 仅展示")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(inLibrary ? LumaBrand.amber
                                           : CinemaDetailTone.ink.opacity(0.58))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((inLibrary ? LumaBrand.amber : CinemaDetailTone.ink)
                        .opacity(inLibrary ? 0.14 : 0.08),
                    in: Capsule())
    }

    private func hoverFooter(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.tap")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(CinemaDetailTone.ink.opacity(0.48))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CinemaDetailTone.ink.opacity(0.035))
    }

    private func entryMeta(_ entry: CinemaEntry) -> String {
        var parts: [String] = [entry.kind == .tv ? "剧集" : "电影"]
        if let year = entry.year { parts.append(String(year)) }
        if let genres = entry.genres, !genres.isEmpty {
            parts.append(genres.prefix(3).joined(separator: " / "))
        }
        return parts.joined(separator: " · ")
    }

    private func voteText(_ count: Int) -> String {
        if count >= 10000 { return String(format: "%.1f 万", Double(count) / 10000) }
        return "\(count)"
    }

    private var ownedBadge: some View {
        Text("在库")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(LumaBrand.amber)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.62)))
            .padding(6)
    }

    /// 作品海报：宽度由网格列宽决定，高度按 2:3 海报比例跟随，窗口变化时不变形。
    private func poster(url: String?, photo: PhotoItem?) -> some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                ZStack {
                    if let url {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else if let photo {
                        PhotoThumbnailView(photo: photo, purpose: .cover(240))
                    } else {
                        Rectangle().fill(CinemaDetailTone.ink.opacity(0.06))
                        Image(systemName: "film")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CinemaDetailTone.ink.opacity(0.10), lineWidth: 0.6)
            }
    }

    private func emptyHint(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func play(_ entry: CinemaEntry) {
        onPlay(entry)
    }

    private func openDetail(_ entry: CinemaEntry) {
        onOpenEntry(entry)
    }
}

/// 搜索面板本身是 sheet：里面点开人物仍用弹窗承载同一套人物页。
private struct CinemaPersonSheet: View {
    let member: CinemaCastMember
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CinemaPersonDetailView(
            member: member,
            onOpenEntry: { entry in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onOpenEntry(entry) }
            },
            onPlay: { entry in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.openCinema(entry) }
            }
        )
        .frame(width: min(1220, cinemaDetailWindowSize.width),
               height: min(880, cinemaDetailWindowSize.height))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(14)
            .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - 合集详情页（B3）

private struct CinemaCollectionSheet: View {
    let collectionID: Int
    let name: String
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var info: CinemaCollectionInfo?

    private var entries: [CinemaEntry] {
        store.cinemaCollection(collectionID: collectionID)
    }

    private var versionCount: Int {
        entries.reduce(0) { $0 + max(1, store.cinemaVersions(for: $1).count) }
    }

    private var watchedCount: Int {
        entries.filter { store.cinemaProgress[$0.id]?.isFinished == true }.count
    }

    private var nextEntry: CinemaEntry? {
        entries.first { !(store.cinemaProgress[$0.id]?.isFinished ?? false) }
    }

    private var totalHours: String {
        let seconds = entries.reduce(0.0) { $0 + ($1.file.duration ?? 0) }
        guard seconds > 0 else { return "—" }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    /// 未入库的下一部：只提示，不生成空条目。
    private var missingPart: CinemaCollectionPart? {
        guard let info, !info.parts.isEmpty else { return nil }
        // 合集 ID 都是 TMDB 的，只拿 TMDB 条目的 ID 判重。
        let owned = Set(entries.filter { $0.provider == .tmdb }.compactMap(\.tmdbID))
        let pending = info.parts.filter { !owned.contains($0.tmdbID) }
        guard !pending.isEmpty else { return nil }
        let lastYear = entries.last?.year ?? 0
        return pending.first { ($0.year ?? 0) >= lastYear } ?? pending.first
    }

    var body: some View {
        ZStack {
            cinemaSheetBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    posterRow
                    columns
                    fileNote
                }
                .padding(.horizontal, 28)
                .padding(.top, 54)
                .padding(.bottom, 32)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: min(1220, cinemaDetailWindowSize.width),
               height: min(880, cinemaDetailWindowSize.height))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(14)
            .keyboardShortcut(.cancelAction)
        }
        .task {
            info = await store.cinemaCollectionInfo(collectionID: collectionID)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("合集 · COLLECTION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(LumaBrand.amber.opacity(0.9))
                Text(name)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                Text("\(entries.count) 部 · \(versionCount) 个版本 · 已看 \(watchedCount) / \(entries.count) · 总时长 \(totalHours)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    playAll()
                } label: {
                    Label("按上映顺序播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(entries.isEmpty)
                Button("关闭") { dismiss() }
                    .controlSize(.regular)
            }
        }
    }

    private var posterRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                if let url = entry.artworkURL {
                                    CinemaArtwork(urlString: url, contentMode: .fill)
                                } else {
                                    PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(240))
                                }
                            }
                            .frame(width: 118, height: 174)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                            }
                            .overlay(alignment: .topLeading) {
                                if store.cinemaProgress[entry.id]?.isFinished == true {
                                    Text("已看")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(LumaBrand.amber)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.black.opacity(0.62)))
                                        .padding(6)
                                }
                            }
                            Text(entry.year.map(String.init) ?? "—")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(entry.title)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                collectionSectionTitle("合集简介")
                if let overview = info?.overview, !overview.isEmpty {
                    CinemaSynopsis(text: overview)
                } else {
                    Text("TMDB 没有提供合集简介。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack(spacing: 7) {
                    chip("自动合集", highlight: true)
                    chip("TMDB 归属")
                    chip("按年份排序")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                collectionSectionTitle("合集统计")
                VStack(spacing: 0) {
                    statRow("影片", "\(entries.count) 部")
                    statRow("版本", "\(versionCount) 个")
                    statRow("已看", "\(watchedCount) 部")
                    if let missingPart {
                        statRow("下一部", "\(missingPart.title)（\(missingPart.year.map(String.init) ?? "未定") 未入库）",
                                highlight: true)
                    } else if let nextEntry {
                        statRow("下一部", nextEntry.title, highlight: true)
                    } else if !entries.isEmpty {
                        statRow("下一部", "全部看完", highlight: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
                }
            }
            .frame(width: 340)
        }
    }

    private var fileNote: some View {
        Text("同一部片的多版本在合集里折叠为一个海报，播放前可在详情页选版本。未入库的续集只做提示，不生成空条目。")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func collectionSectionTitle(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LumaBrand.amber)
                .frame(width: 3, height: 13)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    private func statRow(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: highlight ? .semibold : .regular))
                .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(highlight ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(highlight ? LumaBrand.amber.opacity(0.12)
                                                 : Color.primary.opacity(0.06)))
            .overlay {
                Capsule().strokeBorder(highlight ? LumaBrand.amber.opacity(0.30)
                                                 : Color.primary.opacity(0.08), lineWidth: 0.6)
            }
    }

    private func playAll() {
        guard let entry = nextEntry ?? entries.first else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.openCinema(entry)
        }
    }

    private func open(_ entry: CinemaEntry) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onOpenEntry(entry)
        }
    }
}

// MARK: - 通知中心（F4）

private struct CinemaNotificationSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var groups: [(String, [CinemaNotification])] {
        let calendar = Calendar.current
        var today: [CinemaNotification] = []
        var week: [CinemaNotification] = []
        var older: [CinemaNotification] = []
        for item in store.cinemaNotifications {
            if calendar.isDateInToday(item.date) {
                today.append(item)
            } else if let days = calendar.dateComponents([.day], from: item.date, to: Date()).day,
                      days < 7 {
                week.append(item)
            } else {
                older.append(item)
            }
        }
        return [("今天", today), ("本周", week), ("更早", older)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if store.cinemaNotifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.0) { group in
                            Text(group.0)
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(.tertiary)
                            ForEach(group.1) { item in
                                row(item)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 620, height: 560)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("通知")
                    .font(.system(size: 14, weight: .semibold))
                Text("仅保留最近 30 天")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if store.cinemaUnreadNotificationCount > 0 {
                Text("\(store.cinemaUnreadNotificationCount) 未读")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(LumaBrand.coral)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(LumaBrand.coral.opacity(0.14)))
            }
            Spacer(minLength: 0)
            Button("全部已读") {
                store.markAllCinemaNotificationsRead()
            }
            .controlSize(.small)
            Button("清空") {
                store.clearCinemaNotifications()
            }
            .controlSize(.small)
            Button("完成") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有通知")
                .font(.system(size: 12.5, weight: .medium))
            Text("刮削完成、匹配失败和字幕下载都会归档到这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: CinemaNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint(item.kind))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: item.read ? .regular : .semibold))
                    .foregroundStyle(item.read ? Color.secondary : Color.primary)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(timeText(item.date))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let action = item.action {
                Button(action) {
                    handle(action, item)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(item.read ? Color.primary.opacity(0.025) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(item.read ? Color.white.opacity(0.04) : Color.white.opacity(0.09),
                              lineWidth: 0.6)
        }
        .onTapGesture {
            markRead(item)
        }
    }

    private func handle(_ action: String, _ item: CinemaNotification) {
        markRead(item)
        if action == "重试", let key = item.scopeKey {
            dismiss()
            Task { await store.retryCinemaScope(key: key) }
        } else {
            store.postCinemaToast(.info, title: "已标记为处理", detail: item.title)
        }
    }

    private func markRead(_ item: CinemaNotification) {
        guard let index = store.cinemaNotifications.firstIndex(where: { $0.id == item.id }),
              !store.cinemaNotifications[index].read else { return }
        store.cinemaNotifications[index].read = true
        store.persistCinemaNotifications()
    }

    private func tint(_ kind: CinemaNotificationKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return LumaBrand.coral
        case .progress: return LumaBrand.amber
        case .info: return LumaBrand.violet
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 文件夹详情

private struct CinemaFolderDetailView: View {
    let scope: CinemaScope
    let onPlay: (CinemaEntry) -> Void
    let onOpenEntry: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var folder: CinemaFolder
    /// 已经钻过的目录链，用来返回上一级。
    @State private var trail: [String]
    @State private var scraping = false
    @State private var matchRequest: CinemaQuickMatchRequest?

    init(folder: CinemaFolder,
         scope: CinemaScope,
         onPlay: @escaping (CinemaEntry) -> Void,
         onOpenEntry: @escaping (CinemaEntry) -> Void) {
        self.scope = scope
        self.onPlay = onPlay
        self.onOpenEntry = onOpenEntry
        _folder = State(initialValue: folder)
        _trail = State(initialValue: [folder.path])
    }

    private var entriesByID: [UUID: CinemaEntry] {
        Dictionary(folder.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var sortedPhotos: [PhotoItem] {
        folder.photos.sorted { lhs, rhs in
            let left = CinemaScraper.parse(filename: lhs.displayFilename, folderHint: folder.hint)
            let right = CinemaScraper.parse(filename: rhs.displayFilename, folderHint: folder.hint)
            if (left.season ?? 0) != (right.season ?? 0) {
                return (left.season ?? 0) < (right.season ?? 0)
            }
            if (left.episode ?? 0) != (right.episode ?? 0) {
                return (left.episode ?? 0) < (right.episode ?? 0)
            }
            return lhs.displayFilename.localizedStandardCompare(rhs.displayFilename) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(folder.children) { child in
                        childRow(child)
                    }
                    if !folder.children.isEmpty, !sortedPhotos.isEmpty {
                        sectionLabel("本目录视频 · \(sortedPhotos.count)")
                    }
                    ForEach(sortedPhotos) { photo in
                        row(photo)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 760, height: 580)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .onChange(of: store.cinemaFolderRefreshToken) { _, _ in
            refresh()
        }
        .sheet(item: $matchRequest) { request in
            CinemaMatchSheet(photos: request.photos, folderHint: folder.hint) {
                matchRequest = nil
                refresh()
            }
            .environmentObject(store)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 7) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func childRow(_ child: CinemaFolder) -> some View {
        Button {
            trail.append(child.path)
            folder = child
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = child.posterURL ?? child.backdropURL {
                            CinemaArtwork(urlString: url, contentMode: .fill)
                        } else if let photo = child.firstPhoto {
                            PhotoThumbnailView(photo: photo, purpose: .cover(120))
                        } else {
                            Color.secondary.opacity(0.12)
                        }
                    }
                    .frame(width: 96, height: 54)
                    .clipped()

                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(child.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(child.matchedCount)/\(child.totalCount) 已识别")
                            .foregroundStyle(child.isMatched ? LumaBrand.amber : Color.secondary)
                        Text(child.displayPath)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 9.5))
                }

                Spacer(minLength: 0)

                if child.hasChildren {
                    Text("\(child.children.count) 个子目录")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text("\(child.photos.count) 个视频")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if trail.count > 1 {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("返回上一级")
                .padding(.top, 32)
            }

            ZStack {
                if let url = folder.posterURL ?? folder.backdropURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else if let photo = folder.firstPhoto {
                    PhotoThumbnailView(photo: photo, purpose: .cover(160))
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 60, height: 90)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.displayTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(folder.displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(folder.matchedCount)/\(folder.totalCount) 已识别")
                        .foregroundStyle(folder.isMatched ? LumaBrand.amber : Color.secondary)
                    if folder.episodeCount > 0 {
                        Text("\(folder.episodeCount) 集")
                            .foregroundStyle(.secondary)
                    }
                    Text("本目录 \(folder.photos.count) · 共 \(folder.totalCount) 个视频")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium))
            }

            Spacer(minLength: 0)

            if scraping {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("刮削中…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("手动匹配…") {
                    matchRequest = CinemaQuickMatchRequest(photos: folder.subtreePhotos)
                }
                .controlSize(.small)
                Button {
                    scrape()
                } label: {
                    Label("刮削此目录", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ photo: PhotoItem) -> some View {
        let entry = entriesByID[photo.id]
        return HStack(spacing: 10) {
            ZStack {
                if let url = entry?.gridArtworkURL ?? entry?.artworkURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    PhotoThumbnailView(photo: photo, purpose: .cover(120))
                }
            }
            .frame(width: 96, height: 54)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.title ?? photo.displayFilename)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let subtitle = entry?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    Text(photo.displayFilename)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 9.5))
            }

            Spacer(minLength: 0)

            Text(entry == nil ? "未刮削" : (entry?.matched == true ? "已识别" : "未识别"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(entry?.matched == true ? LumaBrand.amber : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(entry?.matched == true
                                           ? LumaBrand.amber.opacity(0.14)
                                           : Color.secondary.opacity(0.12)))

            if let entry, entry.matched {
                Button("播放") { onPlay(entry) }
                    .controlSize(.small)
            }
            if let entry {
                Button("详情") { onOpenEntry(entry) }
                    .controlSize(.small)
            }
            if entry?.matched != true {
                Button("匹配") {
                    matchRequest = CinemaQuickMatchRequest(photos: [photo])
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func scrape() {
        guard !scraping else { return }
        scraping = true
        Task {
            await store.scrapeCinemaFolder(folder, scope: scope)
            refresh()
            scraping = false
        }
    }

    private func refresh() {
        if let updated = store.cinemaFolder(path: folder.path, scope: scope) {
            folder = updated
        }
    }

    private func goBack() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        guard let path = trail.last,
              let updated = store.cinemaFolder(path: path, scope: scope) else { return }
        folder = updated
    }
}

// MARK: - 家长控制解锁

private struct CinemaPINPromptSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var hasPIN: Bool {
        CinemaKeychain.has(.parentalPIN)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(LumaBrand.coral)
                Text("家长控制")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(hasPIN
                 ? "输入 4 位 PIN 解锁本次会话；退出应用后会重新上锁。"
                 : "还没有设置 PIN。可直接解锁，建议到 设置 › 影院 › 家长控制 里设置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(unlock)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LumaBrand.coral)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("解锁") { unlock() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func unlock() {
        if store.unlockCinemaParental(pin: pin) {
            dismiss()
        } else {
            errorMessage = "PIN 不正确，请重试。"
            pin = ""
        }
    }
}
