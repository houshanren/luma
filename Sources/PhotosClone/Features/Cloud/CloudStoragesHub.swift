import SwiftUI
import AppKit
import Foundation

// MARK: - 分页

/// 网络存储总览的顶层分页：存储 / 总览 / 影院 / 续播 / 管理。
/// 与「网络资源」一致，切换入口放在窗口工具栏里，内容区不再叠一条控制栏。
/// 总览汇总图库、视频与网络存储三源读数；索引与维护合并为同一页「管理」。
enum CloudStoragesHubTab: String, CaseIterable, Identifiable, Hashable {
    case storages
    case overview
    case cinema
    case resume
    case manage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storages: return "存储"
        case .overview: return "总览"
        case .cinema: return "影院"
        case .resume: return "续播"
        case .manage: return "管理"
        }
    }

    var symbol: String {
        switch self {
        case .storages: return "square.grid.2x2.fill"
        case .overview: return "chart.pie.fill"
        case .cinema: return "film.stack"
        case .resume: return "play.circle.fill"
        case .manage: return "slider.horizontal.3"
        }
    }

    static let storageKey = "cloud.storages.hubTab.v1"

    /// 上次停留的分页：重开应用后仍停在同一页；没有记录时落在「存储」。
    /// 旧的「索引 / 维护」两个分页合并成「管理」，读到时直接落到新分页。
    static var persisted: CloudStoragesHubTab {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .storages }
        switch raw {
        case "index", "maintenance": return .manage
        default: return CloudStoragesHubTab(rawValue: raw) ?? .storages
        }
    }
}

// MARK: - Hub

/// 网络存储区：五个分页共用一层容器，具体内容各自滚动。
struct CloudStoragesHubView: View {
    @EnvironmentObject private var cloud: CloudBrowserModel

    var body: some View {
        Group {
            switch cloud.storagesTab {
            case .overview:
                CloudStoragesSnapshotView()
            case .storages:
                CloudStoragesOverviewView()
            case .cinema:
                CloudStoragesCinemaView()
            case .resume:
                CloudStoragesResumeView()
            case .manage:
                CloudStoragesManageView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 工具栏中区的分页胶囊：总览 / 存储 / 影院 / 续播 / 管理。
struct CloudStoragesHubTabs: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CloudStoragesHubTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(_ tab: CloudStoragesHubTab) -> some View {
        let active = cloud.storagesTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                cloud.setStoragesTab(tab)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .fixedSize()
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let badge = badge(for: tab), badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(active ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(active ? Color.white.opacity(0.92)
                                           : Color.primary.opacity(0.08),
                                    in: Capsule(style: .continuous))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "cloud-storage-tab", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }

    private func badge(for tab: CloudStoragesHubTab) -> Int? {
        switch tab {
        case .storages:
            return cloud.mounts.count
        case .resume:
            return store.cloudMountContinueRecords.count
        case .overview, .cinema, .manage:
            return nil
        }
    }
}

// MARK: - 总览页

/// 总览页：把图库、视频与网络存储三源放到同一屏。
/// 所有读数都来自本机索引（图库统计 / 网盘索引 / 影院刮削 / 续播记录），不做联网统计。
struct CloudStoragesSnapshotView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    @State private var indexStates: [UUID: MetadataStore.CloudIndexState] = [:]

    // MARK: 图库
    private var library: LibraryStore.LibraryStats { store.libraryStats }

    // MARK: 网络
    private var indexedMounts: Int { indexStates.values.filter { $0.mediaCount > 0 }.count }
    private var totalIndexMedia: Int { indexStates.values.reduce(0) { $0 + $1.mediaCount } }
    private var totalIndexFolders: Int { indexStates.values.reduce(0) { $0 + $1.folderCount } }
    private var maxIndexMedia: Int { max(1, indexStates.values.map(\.mediaCount).max() ?? 0) }

    private var latestScan: (mount: CloudMount, state: MetadataStore.CloudIndexState)? {
        cloud.mounts
            .compactMap { mount in
                indexStates[mount.id].map { (mount: mount, state: $0) }
            }
            .max { $0.state.updatedAt < $1.state.updatedAt }
    }

    // MARK: 影院
    private var cinemaItems: [CloudMountCinemaItem] {
        cloud.mounts.map { mount in
            let entries = Array(store.cinemaEntries(for: .mount(mount.id)).values)
            return CloudMountCinemaItem(mount: mount,
                                        summary: CloudCinemaSummary(entries: entries))
        }
    }

    private var totalMatched: Int { cinemaItems.reduce(0) { $0 + $1.summary.matched } }
    private var totalMovies: Int { cinemaItems.reduce(0) { $0 + $1.summary.movies } }
    private var totalShows: Int { cinemaItems.reduce(0) { $0 + $1.summary.shows } }

    private var latestScraped: (mount: CloudMount, matched: Int, date: Date)? {
        cinemaItems
            .compactMap { item in
                item.summary.lastScrapedAt.map { (mount: item.mount, matched: item.summary.matched, date: $0) }
            }
            .max { $0.date < $1.date }
    }

    // MARK: 续播
    private var continueRecords: [CinemaProgressRecord] { store.cloudMountContinueRecords }
    private var finishedCount: Int { store.cloudMountFinishedRecords.count }
    private var remainingSeconds: Double { continueRecords.reduce(0) { $0 + $1.remainingSeconds } }
    private var involvedMounts: Int { Set(continueRecords.compactMap(\.mountID)).count }

    private var remainingText: String {
        let hours = remainingSeconds / 3600
        if hours >= 1 { return String(format: "%.1f 小时", hours) }
        return "\(max(0, Int((remainingSeconds / 60).rounded()))) 分钟"
    }

    private var hasAnything: Bool {
        !cloud.mounts.isEmpty || library.photos > 0 || library.videos > 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if !hasAnything {
                    CloudHubEmptyState(symbol: "chart.pie",
                                       title: "还没有可汇总的内容",
                                       message: "导入照片或接入网络存储后，图库、视频与网盘的读数会汇总到这里。",
                                       actionTitle: "接入存储") {
                        store.presentCloudWizard()
                    }
                } else {
                    heroPanel
                    compositionPanel
                    if !cloud.mounts.isEmpty {
                        volumePanel
                    }
                    activityPanel
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { indexStates = store.cloudIndexStates() }
        .onChange(of: cloud.mounts.count) { _, _ in indexStates = store.cloudIndexStates() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("网络总览")
                    .font(.system(size: 27, weight: .bold))
                Text("图库 · 视频 · 网络存储 的跨源读数 · 只读本机索引")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                store.presentCloudWizard()
            } label: {
                Label("接入存储", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.8)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("通过向导接入 WebDAV、SMB 共享或网盘")
        }
    }

    /// 四个跨源读数：图库、网络索引、影院识别、待续播。
    private var heroPanel: some View {
        CloudHubPanel {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 10)],
                      alignment: .leading,
                      spacing: 10) {
                CloudHubStatPod(title: "图库项目",
                                value: (library.photos + library.videos).formatted(),
                                unit: "项",
                                detail: "照片 \(library.photos.formatted()) · 视频 \(library.videos.formatted())",
                                symbol: "photo.stack.fill",
                                tint: LumaBrand.violet)
                CloudHubStatPod(title: "网络索引",
                                value: totalIndexMedia.formatted(),
                                unit: "项",
                                detail: "\(indexedMounts)/\(cloud.mounts.count) 个存储已建索引",
                                symbol: "externaldrive.fill.badge.icloud",
                                tint: LumaBrand.cyan)
                CloudHubStatPod(title: "影院识别",
                                value: totalMatched.formatted(),
                                unit: "部",
                                detail: "电影 \(totalMovies.formatted()) · 剧集 \(totalShows.formatted())",
                                symbol: "film.fill",
                                tint: LumaBrand.mint)
                CloudHubStatPod(title: "待续播",
                                value: continueRecords.count.formatted(),
                                unit: "条",
                                detail: continueRecords.isEmpty
                                    ? "没有未看完的视频"
                                    : "\(involvedMounts) 个存储 · 剩 \(remainingText)",
                                symbol: "play.circle.fill",
                                tint: LumaBrand.coral)
            }
        }
    }

    /// 三源构成：图库照片 / 图库视频 / 网络媒体共用一条比例条，影院识别作为网络子集单列。
    private var compositionPanel: some View {
        let sources = [
            SnapshotSource(id: "photo", title: "图库照片", value: library.photos, tint: LumaBrand.violet),
            SnapshotSource(id: "video", title: "图库视频", value: library.videos, tint: LumaBrand.cyan),
            SnapshotSource(id: "cloud", title: "网络媒体", value: totalIndexMedia, tint: LumaBrand.amber)
        ]
        let shown = sources.filter { $0.value > 0 }
        let total = sources.reduce(0) { $0 + $1.value }

        return CloudHubPanel(spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("三源构成")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Text("共 \(total.formatted()) 项")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if total > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        ForEach(shown) { source in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(LinearGradient(colors: [source.tint, source.tint.opacity(0.60)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, (proxy.size.width - CGFloat(shown.count - 1) * 3)
                                                        * CGFloat(source.value) / CGFloat(total)))
                        }
                    }
                }
                .frame(height: 14)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 8)],
                      alignment: .leading,
                      spacing: 8) {
                ForEach(sources) { source in
                    sourceLegend(source, total: total)
                }
            }

            if totalMatched > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LumaBrand.mint)
                    Text("其中影院已识别 \(totalMatched.formatted()) 部 · 电影 \(totalMovies.formatted()) / 剧集 \(totalShows.formatted())")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func sourceLegend(_ source: SnapshotSource, total: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(source.tint)
                .frame(width: 7, height: 7)
            Text(source.title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(source.value.formatted())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if total > 0 {
                Text("\(Int((Double(source.value) / Double(total) * 100).rounded()))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 存储体量：每个已建索引的存储一行，用比例条对比媒体条目数。
    private var volumePanel: some View {
        let indexed = cloud.mounts.filter { (indexStates[$0.id]?.mediaCount ?? 0) > 0 }
        return CloudHubPanel(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("存储体量")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(totalIndexFolders.formatted()) 个目录")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if indexed.isEmpty {
                Text("还没有索引清单 · 到「管理」里重新扫描后，这里会按存储对比体量。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(indexed) { mount in
                    let media = indexStates[mount.id]?.mediaCount ?? 0
                    HStack(spacing: 10) {
                        Text(mount.name)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 118, alignment: .leading)
                        CloudHubVolumeBar(fraction: Double(media) / Double(maxIndexMedia),
                                          tint: mount.kind.hubTint)
                        Text("\(media.formatted()) 项")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// 最近动态：观看 / 刮削 / 扫描 / 接入，全部只取本机记录。
    private var activityPanel: some View {
        let moments = activities
        return CloudHubPanel(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("最近动态")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Text(finishedCount > 0 ? "已看完 \(finishedCount) 条" : "按时间排序")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)

            if moments.isEmpty {
                Text("还没有观看、刮削或扫描记录。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(moments.indices, id: \.self) { index in
                    momentRow(moments[index])
                    if index < moments.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 42)
                    }
                }
            }

            Text("读数来自本机索引与播放进度，不统计云端未扫描的内容。")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
                .padding(.top, 10)
        }
    }

    private var activities: [SnapshotMoment] {
        var items: [SnapshotMoment] = []

        if let record = continueRecords.first {
            items.append(SnapshotMoment(id: "watch",
                                        symbol: "play.circle.fill",
                                        title: "最近观看 · \(record.title)",
                                        detail: "\(mountName(for: record)) · \(CloudHubFormat.remaining(record.remainingSeconds))",
                                        date: record.updatedAt,
                                        tint: LumaBrand.coral))
        }
        if let scraped = latestScraped {
            items.append(SnapshotMoment(id: "scrape",
                                        symbol: "wand.and.stars",
                                        title: "最近刮削 · \(scraped.mount.name)",
                                        detail: "已识别 \(scraped.matched.formatted()) 部",
                                        date: scraped.date,
                                        tint: LumaBrand.mint))
        }
        if let scan = latestScan {
            items.append(SnapshotMoment(id: "scan",
                                        symbol: "arrow.triangle.2.circlepath",
                                        title: "最近扫描 · \(scan.mount.name)",
                                        detail: "\(scan.state.mediaCount.formatted()) 项 · \(scan.state.folderCount.formatted()) 目录",
                                        date: scan.state.updatedAt,
                                        tint: LumaBrand.cyan))
        }
        if let recent = cloud.mounts.max(by: { $0.createdAt < $1.createdAt }) {
            items.append(SnapshotMoment(id: "mount",
                                        symbol: "externaldrive.fill.badge.plus",
                                        title: "最近接入 · \(recent.name)",
                                        detail: "\(recent.kind.title) · \(DateText.monthFormatter.string(from: recent.createdAt))",
                                        date: recent.createdAt,
                                        tint: LumaBrand.amber))
        }
        return items.sorted { $0.date > $1.date }
    }

    private func momentRow(_ item: SnapshotMoment) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(CloudHubFormat.relative(item.date))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return cloud.mounts.first { $0.id == mountID }?.name ?? "网络存储"
    }
}

/// 三源构成的一段：图库照片 / 图库视频 / 网络媒体。
private struct SnapshotSource: Identifiable {
    let id: String
    let title: String
    let value: Int
    let tint: Color
}

/// 最近动态的一条：符号、标题、说明与时间。
private struct SnapshotMoment: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let date: Date
    let tint: Color
}

// MARK: - 影院页

/// 影院页：把所有网盘的刮削结果汇成一面真实海报墙。
/// 先看「最近刮削」与「接着看」，再按电影 / 剧集浏览；点海报直接开播，底部保留每个存储的刮削入口。
struct CloudStoragesCinemaView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    var body: some View {
        let wall = buildWall()

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CloudHubPageHeader(title: "存储影院",
                                   subtitle: "所有网盘的刮削结果汇成一面海报墙 · 点海报直接开播")

                if cloud.mounts.isEmpty {
                    CloudHubEmptyState(symbol: "film.stack",
                                       title: "还没有存储影院",
                                       message: "接入网络存储并打开影院后，视频会被识别成电影与剧集，汇总到这里。",
                                       actionTitle: "接入存储") {
                        store.presentCloudWizard()
                    }
                } else {
                    summaryPanel(wall)

                    if let spotlight = wall.spotlight {
                        spotlightCard(spotlight)
                    }

                    if !wall.continueRecords.isEmpty {
                        continueShelf(wall.continueRecords)
                    }

                    if wall.movies.isEmpty && wall.series.isEmpty {
                        scrapeHint
                    } else {
                        if !wall.movies.isEmpty {
                            posterSection(title: "电影", symbol: "film.fill",
                                          tint: LumaBrand.violet, items: wall.movies)
                        }
                        if !wall.series.isEmpty {
                            posterSection(title: "剧集", symbol: "tv.fill",
                                          tint: LumaBrand.cyan, items: wall.series)
                        }
                    }

                    mountSection(wall.mounts)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 汇总读数

    private func summaryPanel(_ wall: CloudCinemaWall) -> some View {
        CloudHubPanel {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 10)],
                      alignment: .leading,
                      spacing: 10) {
                CloudHubStatPod(title: "已识别",
                                value: (wall.movies.count + wall.series.count).formatted(),
                                unit: "部",
                                detail: "\(wall.mounts.count) 个存储合并后",
                                symbol: "checkmark.seal.fill",
                                tint: LumaBrand.mint)
                CloudHubStatPod(title: "电影",
                                value: wall.movies.count.formatted(),
                                unit: "部",
                                detail: "海报墙里的长片",
                                symbol: "film.fill",
                                tint: LumaBrand.violet)
                CloudHubStatPod(title: "剧集",
                                value: wall.series.count.formatted(),
                                unit: "部",
                                detail: "同剧分集已合并",
                                symbol: "tv.fill",
                                tint: LumaBrand.cyan)
                CloudHubStatPod(title: "待识别",
                                value: wall.unmatched.formatted(),
                                unit: "项",
                                detail: "还没有匹配到资料",
                                symbol: "questionmark.circle.fill",
                                tint: LumaBrand.amber)
                CloudHubStatPod(title: "续看",
                                value: wall.continueRecords.count.formatted(),
                                unit: "条",
                                detail: "跨存储未看完",
                                symbol: "play.circle.fill",
                                tint: LumaBrand.coral)
            }
        }
    }

    // MARK: 最近刮削

    private func spotlightCard(_ item: CloudCinemaWallItem) -> some View {
        Button { open(item) } label: {
            ZStack(alignment: .bottomLeading) {
                CloudHubArtwork(urlString: item.backdropURL ?? item.artworkURL, cornerRadius: 20)
                    .frame(maxWidth: .infinity)
                    .frame(height: 232)

                LinearGradient(colors: [.black.opacity(0.02),
                                        .black.opacity(0.34),
                                        .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("最近刮削")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(.white.opacity(0.18), in: Capsule(style: .continuous))
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text(item.mountName)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.78))
                    }
                    Text(item.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(item.series == nil ? "播放" : "继续播放")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 13)
                        .frame(height: 27)
                        .background(.white.opacity(0.95), in: Capsule(style: .continuous))

                        Text("刮削于 \(CloudHubFormat.relative(item.date))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .padding(.top, 2)
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 232)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .help("播放 \(item.title)")
        .contextMenu {
            Button("播放") { open(item) }
            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
        }
    }

    // MARK: 接着看

    private func continueShelf(_ records: [CinemaProgressRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("接着看", count: records.count, unit: "条",
                         symbol: "play.circle.fill", tint: LumaBrand.coral)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(records.prefix(12))) { record in
                        CloudCinemaContinueCard(record: record,
                                                mountName: mountName(for: record)) {
                            resume(record)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 海报墙

    private func posterSection(title: String,
                               symbol: String,
                               tint: Color,
                               items: [CloudCinemaWallItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, count: items.count, unit: "部", symbol: symbol, tint: tint)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 106, maximum: 132), spacing: 14)],
                      alignment: .leading,
                      spacing: 16) {
                ForEach(items) { item in
                    CloudCinemaPosterCard(item: item) { open(item) }
                        .contextMenu {
                            Button("播放") { open(item) }
                            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
                        }
                }
            }
        }
    }

    private var scrapeHint: some View {
        CloudHubPanel {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LumaBrand.amber.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有刮削出海报")
                        .font(.system(size: 12, weight: .semibold))
                    Text("在下面的存储行里点「刮削」，识别出的电影与剧集会出现在这面墙上。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
        }
    }

    // MARK: 按存储

    private func mountSection(_ items: [CloudMountCinemaItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("按存储", count: items.count, unit: "个",
                         symbol: "externaldrive.fill", tint: LumaBrand.amber)
            CloudHubPanel(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    mountRow(items[index])
                    if index < items.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 56)
                    }
                }
            }
        }
    }

    private func mountRow(_ item: CloudMountCinemaItem) -> some View {
        let scope = CinemaScope.mount(item.mount.id)
        let scraping = store.cinemaScrapeRunning && store.cinemaScrapeScope == scope
        let tint = item.mount.kind.hubTint
        let continueCount = store.cinemaContinueRecords(for: scope).count

        return HStack(spacing: 12) {
            CloudMountBadge(mount: item.mount, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.mount.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    CloudHubTag(text: item.summary.matched > 0 ? "已识别 \(item.summary.matched)" : "未刮削",
                                tint: item.summary.matched > 0 ? LumaBrand.mint : Color.secondary)
                }
                HStack(spacing: 10) {
                    Text("电影 \(item.summary.movies)")
                    Text("剧集 \(item.summary.shows)")
                    Text("续看 \(continueCount)")
                    if let scraped = item.summary.lastScrapedAt {
                        Text("刮削于 \(CloudHubFormat.relative(scraped))")
                    }
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 10)

            if scraping {
                ProgressView().controlSize(.mini)
                Text("\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            CloudHubCapsuleButton(title: "刮削", symbol: "wand.and.stars", tint: tint) {
                store.startCinemaScrape(for: scope)
            }
            CloudHubCapsuleButton(title: "进入影院", symbol: "arrow.up.right",
                                  tint: tint, prominent: true) {
                enterCinema(mountID: item.mount.id)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sectionTitle(_ title: String,
                              count: Int,
                              unit: String,
                              symbol: String,
                              tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text("\(count) \(unit)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: 数据

    private func buildWall() -> CloudCinemaWall {
        var wall = CloudCinemaWall()
        wall.continueRecords = store.cloudMountContinueRecords

        for mount in cloud.mounts {
            let entries = Array(store.cinemaEntries(for: .mount(mount.id)).values)
            let summary = CloudCinemaSummary(entries: entries)
            wall.mounts.append(CloudMountCinemaItem(mount: mount, summary: summary))
            wall.unmatched += summary.unmatched

            for entry in entries where entry.matched && entry.kind == .movie {
                wall.movies.append(CloudCinemaWallItem(
                    id: "movie-\(mount.id)-\(entry.id)",
                    mountID: mount.id,
                    mountName: mount.name,
                    title: entry.title,
                    detail: movieDetail(entry),
                    artworkURL: entry.posterURL ?? entry.backdropURL,
                    backdropURL: entry.backdropURL,
                    date: entry.scrapedAt,
                    entry: entry,
                    series: nil))
            }

            for series in store.cinemaSeries(for: .mount(mount.id)) {
                wall.series.append(CloudCinemaWallItem(
                    id: "series-\(mount.id)-\(series.id)",
                    mountID: mount.id,
                    mountName: mount.name,
                    title: series.title,
                    detail: series.subtitle,
                    artworkURL: series.posterURL ?? series.backdropURL,
                    backdropURL: series.backdropURL,
                    date: series.latestEpisode?.scrapedAt ?? .distantPast,
                    entry: nil,
                    series: series))
            }
        }

        wall.movies.sort { $0.date > $1.date }
        wall.series.sort { $0.date > $1.date }

        let all = wall.movies + wall.series
        wall.spotlight = all.filter { $0.backdropURL != nil }.max { $0.date < $1.date }
            ?? all.max { $0.date < $1.date }
        return wall
    }

    private func movieDetail(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        parts.append("电影")
        if let runtime = entry.runtime, runtime > 0 { parts.append("\(runtime) 分钟") }
        return parts.joined(separator: " · ")
    }

    private func open(_ item: CloudCinemaWallItem) {
        if let entry = item.entry {
            store.openCinema(entry)
            return
        }
        guard let series = item.series else { return }
        // 有进度就看那一集，否则从第一集开始。
        let watched = Set(store.cloudMountContinueRecords.map(\.photoID))
        if let resume = series.episodes.first(where: { watched.contains($0.file.photoID) }) {
            store.openCinema(resume)
        } else if let first = series.episodes.first {
            store.openCinema(first)
        }
    }

    private func resume(_ record: CinemaProgressRecord) {
        guard let mountID = record.mountID else { return }
        store.activateCinemaScope(.mount(mountID))
        if let entry = store.cinemaIndexes[.mount(mountID)]?[record.photoID] {
            store.openCinema(entry)
        } else {
            store.navigate(to: .cloudCinema(mountID))
        }
    }

    private func enterCinema(mountID: UUID) {
        store.activateCinemaScope(.mount(mountID))
        store.navigate(to: .cloudCinema(mountID))
    }

    private func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return cloud.mounts.first { $0.id == mountID }?.name ?? "网络存储"
    }
}

/// 海报墙的一次性聚合结果：按挂载遍历一遍，视图只读结果。
private struct CloudCinemaWall {
    var mounts: [CloudMountCinemaItem] = []
    var movies: [CloudCinemaWallItem] = []
    var series: [CloudCinemaWallItem] = []
    var spotlight: CloudCinemaWallItem?
    var continueRecords: [CinemaProgressRecord] = []
    var unmatched = 0
}

/// 海报墙的一张条目：电影取单条刮削结果，剧集取合并后的整部剧。
private struct CloudCinemaWallItem: Identifiable {
    let id: String
    let mountID: UUID
    let mountName: String
    let title: String
    let detail: String
    let artworkURL: String?
    let backdropURL: String?
    let date: Date
    let entry: CinemaEntry?
    let series: CinemaSeries?
}

/// 海报墙卡片：竖版海报 + 标题 + 副标题，悬停出播放按钮。
private struct CloudCinemaPosterCard: View {
    let item: CloudCinemaWallItem
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CloudHubArtwork(urlString: item.artworkURL, cornerRadius: 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 168)

                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.55)],
                               startPoint: .center,
                               endPoint: .bottom)

                HStack(spacing: 4) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                    Text(item.mountName)
                        .font(.system(size: 8.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.35), in: Capsule(style: .continuous))
                .padding(8)

                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.95)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? LumaBrand.amber.opacity(0.80)
                                          : Color.white.opacity(0.10),
                                  lineWidth: 1)
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)

            Text(item.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Text(item.detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("播放 \(item.title)")
    }
}

/// 接着看卡片：横版剧照 + 进度条，悬停出播放按钮。
private struct CloudCinemaContinueCard: View {
    let record: CinemaProgressRecord
    let mountName: String
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 10)
                .frame(width: 208, height: 117)

            LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.74)],
                           startPoint: .top,
                           endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(mountName) · \(CloudHubFormat.remaining(record.remainingSeconds))")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(10)

            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black.opacity(0.82))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.96)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: 208, height: 117)
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.26))
                    Capsule()
                        .fill(LumaBrand.coral)
                        .frame(width: max(3, proxy.size.width * min(1, max(0, record.fraction))))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? LumaBrand.coral.opacity(0.85)
                                      : Color.white.opacity(0.10),
                              lineWidth: 1)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("继续播放 \(record.title)")
    }
}

/// 影院卡片的一行数据：挂载 + 汇总。
private struct CloudMountCinemaItem: Identifiable {
    let mount: CloudMount
    let summary: CloudCinemaSummary

    var id: UUID { mount.id }
}

/// 单个网盘影院的轻量汇总：只遍历一次条目，避免卡片里反复过滤。
private struct CloudCinemaSummary {
    var total = 0
    var matched = 0
    var movies = 0
    var shows = 0
    var unmatched = 0
    var lastScrapedAt: Date?

    init(entries: [CinemaEntry]) {
        total = entries.count
        let matchedEntries = entries.filter(\.matched)
        matched = matchedEntries.count
        unmatched = entries.count - matched
        movies = matchedEntries.filter { $0.kind == .movie }.count
        shows = matchedEntries.filter { $0.kind == .tv }.count
        lastScrapedAt = entries.map(\.scrapedAt).max()
    }
}

// MARK: - 续播页

/// 续播页：跨存储汇总未看完的视频，按最近观看排序；底部保留刚看完的记录。
struct CloudStoragesResumeView: View {
    @EnvironmentObject private var store: LibraryStore

    private var continueRecords: [CinemaProgressRecord] { store.cloudMountContinueRecords }
    private var finishedRecords: [CinemaProgressRecord] { Array(store.cloudMountFinishedRecords.prefix(6)) }

    private var remainingTotal: Double {
        continueRecords.reduce(0) { $0 + $1.remainingSeconds }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CloudHubPageHeader(title: "存储续播",
                                   subtitle: "所有网络存储里没看完的视频 · 进度只记录在本机")

                if continueRecords.isEmpty {
                    CloudHubEmptyState(symbol: "play.circle",
                                       title: "还没有未看完的视频",
                                       message: "在任意网盘的影院里播放视频后，进度会出现在这里，可以直接接着看。")
                } else {
                    summaryPanel
                    CloudHubPanel(spacing: 0) {
                        ForEach(continueRecords.indices, id: \.self) { index in
                            resumeRow(continueRecords[index])
                            if index < continueRecords.count - 1 {
                                Divider().opacity(0.35).padding(.leading, 142)
                            }
                        }
                    }
                }

                if !finishedRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LumaBrand.mint)
                            Text("最近看完")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(store.cloudMountFinishedRecords.count) 条")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        CloudHubPanel(spacing: 0) {
                            ForEach(finishedRecords.indices, id: \.self) { index in
                                finishedRow(finishedRecords[index])
                                if index < finishedRecords.count - 1 {
                                    Divider().opacity(0.35).padding(.leading, 112)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryPanel: some View {
        CloudHubPanel {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 10)],
                      alignment: .leading,
                      spacing: 10) {
                CloudHubStatPod(title: "未看完",
                                value: continueRecords.count.formatted(),
                                unit: "条",
                                detail: "跨存储汇总",
                                symbol: "play.circle.fill",
                                tint: LumaBrand.coral)
                CloudHubStatPod(title: "剩余时长",
                                value: CloudHubFormat.hours(remainingTotal),
                                detail: "全部续看加总",
                                symbol: "hourglass",
                                tint: LumaBrand.amber)
                CloudHubStatPod(title: "涉及存储",
                                value: Set(continueRecords.compactMap(\.mountID)).count.formatted(),
                                unit: "个",
                                detail: "有未看完视频的网盘",
                                symbol: "externaldrive.fill.badge.icloud",
                                tint: LumaBrand.violet)
                CloudHubStatPod(title: "最近观看",
                                value: continueRecords.first.map { CloudHubFormat.relative($0.updatedAt) } ?? "—",
                                detail: "按观看时间排序",
                                symbol: "clock.arrow.circlepath",
                                tint: LumaBrand.cyan)
            }
        }
    }

    private func resumeRow(_ record: CinemaProgressRecord) -> some View {
        let mountName = mountName(for: record)
        return HStack(alignment: .center, spacing: 16) {
            // 刮削封面优先取横版剧照（backdrop），按 16:10 裁切才不会把人像挤没。
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 9)
                .frame(width: 108, height: 66)

            VStack(alignment: .leading, spacing: 8) {
                Text(record.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.quaternary)
                    }
                    Text(mountName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                CloudHubProgressBar(fraction: record.fraction, tint: LumaBrand.coral)
                    .frame(maxWidth: 360)
                HStack(spacing: 7) {
                    Text(CloudHubFormat.remaining(record.remainingSeconds))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(Int((record.fraction * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumaBrand.coral)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text(CloudHubFormat.relative(record.updatedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 16)

            CloudHubCapsuleButton(title: "继续观看", symbol: "play.fill",
                                  tint: LumaBrand.coral, prominent: true) {
                resume(record)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { resume(record) }
        .contextMenu {
            Button("继续观看") { resume(record) }
            if let mountID = record.mountID {
                Button("打开这个存储的影院") {
                    store.activateCinemaScope(.mount(mountID))
                    store.navigate(to: .cloudCinema(mountID))
                }
            }
        }
    }

    private func finishedRow(_ record: CinemaProgressRecord) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 7)
                .frame(width: 80, height: 50)
                .opacity(0.72)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(mountName(for: record))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text("看完于 \(CloudHubFormat.relative(record.updatedAt))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 16)
            CloudHubTag(text: "已看完", tint: LumaBrand.mint)
            CloudHubCapsuleButton(title: "重看", symbol: "arrow.counterclockwise",
                                  tint: LumaBrand.mint) {
                resume(record)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return store.cloudMounts.first { $0.id == mountID }?.name ?? "网络存储"
    }

    private func resume(_ record: CinemaProgressRecord) {
        guard let mountID = record.mountID else { return }
        store.activateCinemaScope(.mount(mountID))
        if let entry = store.cinemaIndexes[.mount(mountID)]?[record.photoID] {
            store.openCinema(entry)
        } else {
            // 刮削索引被清掉时仍能回到该网盘影院，续播记录不会丢。
            store.navigate(to: .cloudCinema(mountID))
        }
    }
}

// MARK: - 管理页

/// 管理页：索引状态、连接方式、接入范围与扫描动作集中在这里。
/// 索引与维护原来是两个分页，但它们服务同一件事「让本地索引与远端保持一致」，合并后按存储逐条核对。
struct CloudStoragesManageView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @State private var indexStates: [UUID: MetadataStore.CloudIndexState] = [:]
    @State private var renamingMount: CloudMount?
    @State private var renameText = ""

    private var totalMedia: Int {
        indexStates.values.reduce(0) { $0 + $1.mediaCount }
    }

    private var totalFolders: Int {
        indexStates.values.reduce(0) { $0 + $1.folderCount }
    }

    private var indexedMounts: Int {
        indexStates.values.filter { $0.mediaCount > 0 }.count
    }

    private var latestScan: Date? {
        indexStates.values.map(\.updatedAt).max()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CloudHubPageHeader(title: "存储管理",
                                   subtitle: "索引体量、连接方式与接入范围 · 修改只作用于本机配置")

                if cloud.mounts.isEmpty {
                    CloudHubEmptyState(symbol: "wrench.and.screwdriver",
                                       title: "还没有需要管理的存储",
                                       message: "接入存储后，这里会列出每个连接的鉴权方式、读写权限、索引体量与新鲜度。",
                                       actionTitle: "接入存储") {
                        store.presentCloudWizard()
                    }
                } else {
                    manageSummary
                    safetyNote
                    VStack(spacing: 12) {
                        ForEach(cloud.mounts) { mount in
                            maintenanceCard(mount)
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: cloud.mounts.count) { indexStates = store.cloudIndexStates() }
        .alert("重命名网络存储", isPresented: renamePresented) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingMount = nil }
            Button("保存") {
                if let mount = renamingMount {
                    store.renameCloudMount(mount.id, to: renameText)
                }
                renamingMount = nil
            }
        } message: {
            Text("只修改显示名称，不会影响网盘上的内容。")
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renamingMount != nil },
                set: { if !$0 { renamingMount = nil } })
    }

    /// 索引体量：把原「索引」页的读数并进来，看维护动作时不必再切分页。
    private var manageSummary: some View {
        CloudHubPanel(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 10)],
                      alignment: .leading,
                      spacing: 10) {
                CloudHubStatPod(title: "媒体总数",
                                value: totalMedia.formatted(),
                                unit: "项",
                                detail: "所有存储的索引条目",
                                symbol: "photo.on.rectangle.angled",
                                tint: LumaBrand.cyan)
                CloudHubStatPod(title: "目录总数",
                                value: totalFolders.formatted(),
                                unit: "个",
                                detail: "扫描到的文件夹",
                                symbol: "folder.fill",
                                tint: LumaBrand.amber)
                CloudHubStatPod(title: "已建索引",
                                value: "\(indexedMounts)/\(cloud.mounts.count)",
                                detail: "有媒体清单的存储",
                                symbol: "internaldrive.fill",
                                tint: LumaBrand.violet)
                CloudHubStatPod(title: "最近扫描",
                                value: latestScan.map { CloudHubFormat.relative($0) } ?? "—",
                                detail: latestScan == nil ? "还没有扫描记录" : "索引更新时间",
                                symbol: "clock.arrow.circlepath",
                                tint: LumaBrand.mint)
            }
        }
    }

    private var safetyNote: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LumaBrand.mint.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaBrand.mint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("只读优先，派生数据留在本机")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("除 WebDAV 外均为只读；收藏、关键词、评分、续播与索引都存在当前图库，不会写回网盘。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
        }
        .padding(14)
        .lumaGlassCard(cornerRadius: 16, shadow: false)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LumaBrand.mint.opacity(0.18), lineWidth: 0.7)
        }
    }

    private func maintenanceCard(_ mount: CloudMount) -> some View {
        let state = indexStates[mount.id]
        let tint = mount.kind.hubTint

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CloudMountBadge(mount: mount, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mount.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                    Text(address(for: mount))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                CloudHubTag(text: mount.kind.supportsWrite ? "可写" : "只读",
                            tint: mount.kind.supportsWrite ? LumaBrand.mint : LumaBrand.violet)
                CloudHubTag(text: mount.kind.title, tint: tint)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                      alignment: .leading,
                      spacing: 8) {
                infoCell("鉴权方式", authText(for: mount))
                infoCell("接入范围", scopeText(for: mount))
                infoCell("权限", mount.kind.supportsWrite ? "可写入 WebDAV" : "只读浏览")
                infoCell("索引", indexText(state))
                infoCell("接入时间", DateText.monthFormatter.string(from: mount.createdAt))
            }

            if let deep = store.cloudDeepScanDate(mount.id) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .medium))
                    Text("上次深度扫描 \(CloudHubFormat.relative(deep))")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                CloudHubCapsuleButton(title: "打开", symbol: "arrow.up.right", tint: tint) {
                    store.navigate(to: .cloudMount(mount.id))
                }
                CloudHubCapsuleButton(title: "重新扫描", symbol: "arrow.clockwise", tint: tint) {
                    store.navigate(to: .cloudMount(mount.id))
                    store.refreshCloudDirectory()
                }
                if mount.kind.supportsAccessScope {
                    CloudHubCapsuleButton(title: "接入范围", symbol: "scope", tint: tint) {
                        store.presentCloudWizard(editing: mount)
                    }
                }
                CloudHubCapsuleButton(title: connectionActionTitle(for: mount),
                                      symbol: "key.horizontal", tint: tint) {
                    if mount.kind == .webdav || mount.kind == .smb {
                        store.presentCloudSheet(mount)
                    } else {
                        store.presentCloudWizard(flow: mount.kind.wizardFlow)
                    }
                }
                CloudHubCapsuleButton(title: "重命名", symbol: "pencil", tint: tint) {
                    renameText = mount.name
                    renamingMount = mount
                }
                Spacer(minLength: 4)
                Button {
                    store.confirmRemoveCloudMount(mount.id)
                } label: {
                    Text("断开连接")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LumaBrand.coral)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(LumaBrand.coral.opacity(0.10), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaGlassCard(cornerRadius: 18)
    }

    private func infoCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.quaternary)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func authText(for mount: CloudMount) -> String {
        switch mount.kind {
        case .smb, .webdav: return "账号密码"
        case .quark, .aliyun, .pan115: return "浏览器 Cookie"
        case .baidu: return mount.authMode == .oauth ? "OAuth 令牌" : "浏览器 Cookie"
        }
    }

    private func scopeText(for mount: CloudMount) -> String {
        var parts: [String] = []
        if mount.scanAll { parts.append("整个共享") }
        if mount.scopeRoots.isEmpty {
            parts.append("整个网盘")
        } else {
            parts.append("\(mount.scopeRoots.count) 个目录")
        }
        if !mount.excludedRoots.isEmpty {
            parts.append("排除 \(mount.excludedRoots.count)")
        }
        return parts.joined(separator: " · ")
    }

    private func indexText(_ state: MetadataStore.CloudIndexState?) -> String {
        guard let state else { return "尚未建立" }
        let base = "\(state.mediaCount.formatted()) 项 · \(state.folderCount.formatted()) 目录"
        return state.complete ? base : base + " · 未完成"
    }

    private func address(for mount: CloudMount) -> String {
        let detail = (mount.baseURL.isEmpty ? mount.lastPath : mount.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "点击进入浏览云端目录" : detail
    }

    private func connectionActionTitle(for mount: CloudMount) -> String {
        switch mount.kind {
        case .webdav, .smb: return "编辑连接"
        case .quark, .aliyun, .pan115: return "更新 Cookie"
        case .baidu: return "重新授权"
        }
    }
}

// MARK: - 通用组件

/// 页头：与网络资源各分页保持同一套字号与留白。
struct CloudHubPageHeader: View {
    let title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 27, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 磨砂面板：统一内边距与圆角，五个分页共用。
struct CloudHubPanel<Content: View>: View {
    var spacing: CGFloat
    var content: Content

    init(spacing: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaGlassCard(cornerRadius: 20)
    }
}

/// 读数块：图标 + 标题 + 大号读数 + 说明。
struct CloudHubStatPod: View {
    let title: String
    let value: String
    var unit: String? = nil
    var detail: String? = nil
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 0.7)
        }
    }
}

/// 小胶囊标签：状态、类型与数量。
struct CloudHubTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
            }
    }
}

/// 胶囊动作按钮：普通态用淡色底，主操作直接铺强调色。
struct CloudHubCapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .accentColor
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                Capsule(style: .continuous)
                    .fill(prominent
                          ? AnyShapeStyle(tint)
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(prominent ? Color.white.opacity(0.20) : tint.opacity(0.22),
                                  lineWidth: 0.7)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 品牌标识：官方网盘用产品图标，其余用协议渐变 + 系统符号。
struct CloudMountBadge: View {
    let mount: CloudMount
    var size: CGFloat = 38

    private var tint: Color { mount.kind.hubTint }

    var body: some View {
        Group {
            if let brand = mount.kind.brand {
                CloudBrandIcon(brand: brand, size: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: mount.kind.symbolName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                }
            }
        }
        .shadow(color: tint.opacity(0.26), radius: 7, y: 3)
    }
}

/// 远端海报：复用影院的内存缓存，不在总览里另起一套下载。
struct CloudHubArtwork: View {
    let urlString: String?
    var cornerRadius: CGFloat = 8
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
        }
        .task(id: urlString) {
            guard let urlString else { image = nil; return }
            image = await CinemaArtworkCache.shared.image(for: urlString)
        }
    }
}

/// 体量条：索引分布与播放进度共用，宽度按比例铺满。
struct CloudHubVolumeBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// 播放进度条：比体量条更细，带一点内高光。
struct CloudHubProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                    .overlay {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: 1)
                            .padding(.horizontal, 3)
                    }
            }
        }
        .frame(height: height)
    }
}

/// 空态卡片：图标 + 标题 + 说明，可附带一个接入动作。
struct CloudHubEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 74, height: 74)
                Image(systemName: symbol)
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.8)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .padding(.horizontal, 24)
        .lumaGlassCard(cornerRadius: 22)
    }
}

// MARK: - 格式化

enum CloudHubFormat {
    /// 相对时间：总览里只关心「刚刚 / N 分钟前 / N 天前」，超过一个月回到月份。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400)) 天前" }
        return DateText.monthFormatter.string(from: date)
    }

    /// 剩余时长：按小时 / 分钟粗粒度展示，避免出现「还剩 4872 秒」。
    static func remaining(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "还剩 \(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "还剩 \(minutes) 分钟" }
        return "还剩不到 1 分钟"
    }

    /// 总时长：续播页的「剩余时长」读数。
    static func hours(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours >= 1 { return String(format: "%.1f", hours) }
        return "\(max(0, Int((seconds / 60).rounded())))"
    }
}

// MARK: - 协议配色

extension CloudKind {
    /// 总览分页里的协议配色：与侧边栏、卡片保持同一套色相。
    var hubTint: Color {
        switch self {
        case .webdav: return Color(red: 0.32, green: 0.74, blue: 0.82)
        case .smb: return Color(red: 0.52, green: 0.58, blue: 0.96)
        case .aliyun: return Color(red: 1.00, green: 0.60, blue: 0.30)
        case .baidu: return Color(red: 0.26, green: 0.54, blue: 0.98)
        case .quark: return Color(red: 0.44, green: 0.50, blue: 1.00)
        case .pan115: return Color(red: 0.18, green: 0.56, blue: 0.96)
        }
    }
}
