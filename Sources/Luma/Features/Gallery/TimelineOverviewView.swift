import AppKit
import SwiftUI

/// 总览卡片的拼图底板：1～4 张照片铺满卡片。
private struct TimelineMosaic: View {
    let photos: [PhotoItem]
    /// 卡片实际尺寸（pt）：决定解码档位，大卡不再用 220pt 的封面图放大到糊。
    var pixelSide: CGFloat = 220

    private let gap: CGFloat = 3

    var body: some View {
        let items = Array(photos.prefix(4))
        Group {
            switch items.count {
            case 0:
                Color(nsColor: .quaternaryLabelColor).opacity(0.25)
            case 1:
                cell(items[0])
            case 2:
                HStack(spacing: gap) {
                    cell(items[0])
                    cell(items[1])
                }
            case 3:
                HStack(spacing: gap) {
                    cell(items[0])
                    VStack(spacing: gap) {
                        cell(items[1])
                        cell(items[2])
                    }
                }
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        cell(items[0])
                        cell(items[1])
                    }
                    HStack(spacing: gap) {
                        cell(items[2])
                        cell(items[3])
                    }
                }
            }
        }
    }

    private func cell(_ photo: PhotoItem) -> some View {
        PhotoThumbnailView(photo: photo, purpose: .cover(pixelSide))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 年/月总览里的一张卡片。
private struct TimelineCard: View {
    let photos: [PhotoItem]
    let title: String
    let subtitle: String
    let width: CGFloat
    let height: CGFloat
    /// 月视图里的「某日」卡片：日期小标签贴在左上角，不随卡片放大。
    var compactTitle = false
    /// 卡片封面解码档位（pt）。
    var thumbnailSide: CGFloat = 220
    let action: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    private var corner: CGFloat { max(10, settings.cardRadius) }
    private var titleSize: CGFloat {
        compactTitle ? 14 : min(34, max(17, height * 0.115))
    }
    private var titleWeight: Font.Weight { compactTitle ? .semibold : .bold }

    /// 卡片上的日期角标：日卡片用高对比胶囊，年卡片用大标题。
    @ViewBuilder
    private var titleOverlay: some View {
        if compactTitle {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .monospacedDigit()
            .contentTransition(.numericText())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.34), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .padding(.horizontal, 10)
            .padding(.top, 10)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: titleSize, weight: titleWeight, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
    }

    var body: some View {
        // 只把拼图放进 Button；压暗层与日期角标放在 Button 外层叠加，
        // 否则 macOS 的按钮只绘制第一个子视图，标签会整条消失。
        Button(action: action) {
            TimelineMosaic(photos: photos, pixelSide: thumbnailSide)
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .overlay {
            LinearGradient(colors: [Color.black.opacity(0.62),
                                    Color.black.opacity(0.22),
                                    Color.black.opacity(0)],
                           startPoint: .top,
                           endPoint: .center)
                .allowsHitTesting(false)
        }
        .overlay {
            LinearGradient(colors: [.clear, Color.black.opacity(0.42)],
                           startPoint: .center,
                           endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .overlay {
            if hovering {
                // 悬停玻璃反光：卡片不缩放、不位移，只加一层很轻的受光。
                LinearGradient(colors: [Color.white.opacity(0.14),
                                        .clear,
                                        Color.black.opacity(0.06)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .blendMode(.softLight)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) { titleOverlay }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: compactTitle ? 15 : 18))
                .foregroundStyle(.white.opacity(0.78))
                .padding(compactTitle ? 10 : 14)
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.88)
                .animation(settings.motion.hover, value: hovering)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                              lineWidth: hovering ? 1 : 0.5)
        }
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.14),
                radius: hovering ? 16 : 7,
                y: hovering ? 9 : 3)
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onHover { hovering = $0 }
        .animation(settings.motion.hover, value: hovering)
        .help(title)
    }
}

private enum TimelineMetrics {
    static let gap: CGFloat = 14
    static let horizontal: CGFloat = 20

    static func columns(contentWidth: CGFloat, minCardWidth: CGFloat) -> Int {
        max(2, Int((contentWidth + gap) / (minCardWidth + gap)))
    }

    static func cardWidth(contentWidth: CGFloat, columns: Int) -> CGFloat {
        max(80, (contentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns))
    }
}

/// 「年」分组：每年一张拼图卡片，点击进入该年的月总览。
struct YearOverviewView: View {
    @Environment(LibraryStore.self) private var store
    let width: CGFloat

    private var contentWidth: CGFloat { max(280, width - TimelineMetrics.horizontal * 2) }
    private var columns: Int {
        TimelineMetrics.columns(contentWidth: contentWidth, minCardWidth: 340)
    }
    private var cardWidth: CGFloat {
        TimelineMetrics.cardWidth(contentWidth: contentWidth, columns: columns)
    }
    private var cardHeight: CGFloat {
        let zoom = min(2.0, max(0.55, CGFloat(store.thumbSize) / 132))
        return min(520, max(150, cardWidth * 0.64 * zoom))
    }

    var body: some View {
        ScrollView {
            if store.usesSQLOverview {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TimelineMetrics.gap),
                                         count: columns),
                          spacing: TimelineMetrics.gap) {
                    ForEach(store.yearBuckets) { bucket in
                        TimelineCard(photos: Array(bucket.photos.prefix(4)),
                                     title: bucket.title,
                                     subtitle: "\(bucket.count.formatted()) 个项目",
                                     width: cardWidth,
                                     height: cardHeight) {
                            if let year = Int(bucket.id) {
                                store.openMonths(of: year)
                            }
                        }
                        .id(bucket.id)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, TimelineMetrics.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 28)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TimelineMetrics.gap),
                                         count: columns),
                          spacing: TimelineMetrics.gap) {
                    ForEach(store.sections) { section in
                        if !section.photos.isEmpty {
                            TimelineCard(photos: Array(section.photos.prefix(4)),
                                         title: section.title ?? "\(section.id)年",
                                         subtitle: "\(section.photos.count.formatted()) 个项目",
                                         width: cardWidth,
                                         height: cardHeight) {
                                if let year = Int(section.id) {
                                    store.openMonths(of: year)
                                }
                            }
                            .id(section.id)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, TimelineMetrics.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .scrollIndicators(.automatic)
        .task(id: store.overviewKey) { store.reloadOverviewIfNeeded() }
        .overlay {
            if store.usesSQLOverview, store.isOverviewLoading, store.yearBuckets.isEmpty {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }
}

/// 「月」总览里的一天：样本最多 4 张，`count` 是当天真实总数。
private struct MonthDay: Identifiable {
    let id: String
    let title: String
    let count: Int
    let photos: [PhotoItem]
}

/// 月拼贴里的一行：把连续几天按「当天照片数」的权重凑成一行。
private struct DayCollageRow: Identifiable {
    let id: String
    let days: [MonthDay]
}

/// 「月」分组：按月分段，段内把每一天拼贴成大小不一的卡片——
/// 照片多的一天占更宽的大卡，照片少的两三天并排或堆叠，像系统「照片」的月视图一样
/// 每行都是不同组合；点击某天会切回「所有照片」并定位到那一天。
struct MonthOverviewView: View {
    @Environment(LibraryStore.self) private var store
    let width: CGFloat

    private var contentWidth: CGFloat { max(280, width - TimelineMetrics.horizontal * 2) }
    private var columns: Int {
        TimelineMetrics.columns(contentWidth: contentWidth, minCardWidth: 300)
    }
    private var cardWidth: CGFloat {
        TimelineMetrics.cardWidth(contentWidth: contentWidth, columns: columns)
    }
    private var cardHeight: CGFloat {
        let zoom = min(2.0, max(0.55, CGFloat(store.thumbSize) / 132))
        return min(480, max(140, cardWidth * 0.72 * zoom))
    }
    private var gap: CGFloat { TimelineMetrics.gap }
    /// 宽屏时用拼贴排版；窄屏退回等宽网格，避免每行只剩一两张时卡片被拉得过大。
    private var usesMosaic: Bool { contentWidth >= 560 }

    /// 一行按几个「单位」排：窗口越宽一行放越多天，卡片尺寸仍可控。
    private var unitsPerRow: Int {
        min(6, max(4, Int((contentWidth / 280).rounded())))
    }
    /// 一个单位的宽度（一行排满 `unitsPerRow` 个最小卡片的宽度）。
    private var unitWidth: CGFloat {
        (contentWidth - gap * CGFloat(unitsPerRow - 1)) / CGFloat(unitsPerRow)
    }
    /// 缩放档位：和网格缩放滑杆联动，拼贴卡片跟着整体放大 / 缩小。
    private var mosaicZoom: CGFloat {
        min(2.0, max(0.55, CGFloat(store.thumbSize) / 132))
    }

    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gap), count: columns)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if store.usesSQLOverview, store.isDirectSystemIndex {
                        directMonthGrid
                    } else if store.usesSQLOverview {
                        ForEach(store.monthGroups) { month in
                            Section {
                                monthBody(month.days.map {
                                    MonthDay(id: $0.id, title: $0.title, count: $0.count, photos: $0.photos)
                                })
                            } header: {
                                SectionHeaderView(title: month.title, count: month.count)
                            }
                            .id(month.id)
                        }
                    } else {
                        ForEach(store.sections) { section in
                            Section {
                                monthBody(dayGroups(in: section.photos))
                            } header: {
                                if let title = section.title {
                                    SectionHeaderView(title: title, count: section.photos.count)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 76)
                }
            }
            .scrollIndicators(.automatic)
            .onAppear { scrollToTarget(proxy) }
            .onChange(of: store.scrollTargetSection) { _, _ in scrollToTarget(proxy) }
            .onChange(of: store.monthGroups.count) { _, _ in scrollToTarget(proxy) }
            .task(id: store.overviewKey) { store.reloadOverviewIfNeeded() }
            .overlay {
                if store.usesSQLOverview, store.isOverviewLoading, store.monthGroups.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                }
            }
        }
    }

    /// 直连模式同样按「天」拼贴：每个月的 Section 出现时才查这一个月的逐天分组，
    /// 数据到达前先用该月大卡占位，到达后替换成拼贴（不会整页等待）。
    @ViewBuilder
    private var directMonthGrid: some View {
        ForEach(store.monthGroups) { month in
            Section {
                Group {
                    if let days = store.directMonthDays(monthID: month.id), !days.isEmpty {
                        monthBody(days.map {
                            MonthDay(id: $0.id, title: $0.title, count: $0.count, photos: $0.photos)
                        })
                    } else {
                        monthPlaceholderCard(month)
                    }
                }
                .task { store.ensureDirectMonthDays(monthID: month.id) }
            } header: {
                SectionHeaderView(title: month.title, count: month.count)
            }
            .id(month.id)
        }
    }

    /// 逐天数据还没到时的占位：整月一张大卡。
    private func monthPlaceholderCard(_ month: PhotoMonthGroup) -> some View {
        TimelineCard(photos: Array(month.samples.prefix(4)),
                     title: month.title,
                     subtitle: "\(month.count.formatted()) 个项目",
                     width: contentWidth,
                     height: min(360, max(180, contentWidth * 0.3 * mosaicZoom)),
                     compactTitle: true) {
            if let first = month.samples.first {
                store.openAllPhotos(at: first.id)
            }
        }
        .padding(.horizontal, TimelineMetrics.horizontal)
        .padding(.bottom, 26)
    }

    @ViewBuilder
    private func monthBody(_ days: [MonthDay]) -> some View {
        if usesMosaic {
            VStack(spacing: gap) {
                ForEach(collageRows(days)) { row in
                    collageRow(row)
                }
            }
            .padding(.horizontal, TimelineMetrics.horizontal)
            .padding(.bottom, 26)
        } else {
            LazyVGrid(columns: gridItems, spacing: gap) {
                ForEach(days) { day in
                    dayCard(day, width: cardWidth, height: cardHeight)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, TimelineMetrics.horizontal)
            .padding(.bottom, 26)
        }
    }

    // MARK: - 拼贴

    /// 当天在拼贴里占几个单位：照片越多，卡片越宽（12 张以上占 3 格）。
    private func collageWeight(_ day: MonthDay) -> Int {
        if day.count >= 12 { return 3 }
        if day.count >= 4 { return 2 }
        return 1
    }

    /// 把连续若干天凑成一行：按权重累加到 `unitsPerRow` 换行，日期顺序保持不变。
    private func collageRows(_ days: [MonthDay]) -> [DayCollageRow] {
        let target = unitsPerRow
        var rows: [DayCollageRow] = []
        var current: [MonthDay] = []
        var units = 0
        func flush() {
            guard let first = current.first else { return }
            rows.append(DayCollageRow(id: first.id, days: current))
            current.removeAll(keepingCapacity: true)
            units = 0
        }
        for day in days {
            let weight = collageWeight(day)
            if !current.isEmpty, units + weight > target { flush() }
            current.append(day)
            units += weight
            if units >= target { flush() }
        }
        flush()
        return rows
    }

    /// 大卡 + 右侧两张堆叠：首日照片多、后两天各一张时启用（系统「照片」的经典组合）。
    private func isHeroStack(_ row: DayCollageRow) -> Bool {
        row.days.count == 3
            && collageWeight(row.days[0]) >= 2
            && collageWeight(row.days[1]) == 1
            && collageWeight(row.days[2]) == 1
    }

    /// 各行高度不同，拼起来才是「拼贴」而不是等距网格。
    private func collageRowHeight(_ row: DayCollageRow, unit: CGFloat) -> CGFloat {
        let height: CGFloat
        if isHeroStack(row) {
            height = unit * 1.30
        } else {
            switch row.days.count {
            case 1: height = unit * 2.00
            case 2: height = unit * 1.35
            case 3: height = unit * 1.15
            case 4: height = unit * 0.95
            default: height = unit * 0.82
            }
        }
        return min(620, max(120, height)) * mosaicZoom
    }

    private func collageRow(_ row: DayCollageRow) -> some View {
        let unit = unitWidth
        let height = collageRowHeight(row, unit: unit)
        return HStack(alignment: .top, spacing: gap) {
            if isHeroStack(row) {
                let available = contentWidth - gap
                let stackWidth = max(140, available * 0.36)
                let heroWidth = available - stackWidth
                let stackHeight = max(60, (height - gap) / 2)
                dayCard(row.days[0], width: heroWidth, height: height)
                VStack(spacing: gap) {
                    dayCard(row.days[1], width: stackWidth, height: stackHeight)
                    dayCard(row.days[2], width: stackWidth, height: stackHeight)
                }
            } else if row.days.count == 1 {
                dayCard(row.days[0], width: contentWidth, height: height)
            } else {
                let available = contentWidth - gap * CGFloat(row.days.count - 1)
                let total = CGFloat(row.days.reduce(0) { $0 + collageWeight($1) })
                ForEach(row.days) { day in
                    dayCard(day,
                            width: available * CGFloat(collageWeight(day)) / total,
                            height: height)
                }
            }
        }
    }

    private func dayCard(_ day: MonthDay, width: CGFloat, height: CGFloat) -> some View {
        // 一天一张卡、只展示当天的一张代表照片（系统「照片」的月视图也是这样分开展示）；
        // 月份已由分区标题给出，卡片角标只显示「日」。
        return TimelineCard(photos: Array(day.photos.prefix(1)),
                            title: day.title,
                            subtitle: "\(day.count) 张",
                            width: width,
                            height: height,
                            compactTitle: true,
                            thumbnailSide: max(260, min(width, height) * 1.2)) {
            if let first = day.photos.first {
                store.openAllPhotos(at: first.id)
            }
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = store.scrollTargetSection else { return }
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(target, anchor: .top)
            }
            store.scrollTargetSection = nil
        }
    }

    private func dayGroups(in photos: [PhotoItem]) -> [MonthDay] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        var titles: [String: String] = [:]
        for photo in photos {
            let parts = calendar.dateComponents([.year, .month, .day], from: photo.capturedAt)
            let key = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
                titles[key] = "\(parts.day ?? 0)日"
            }
            buckets[key]?.append(photo)
        }
        return order.compactMap { key in
            guard let items = buckets[key], let title = titles[key] else { return nil }
            return MonthDay(id: key, title: title, count: items.count, photos: items)
        }
    }
}
