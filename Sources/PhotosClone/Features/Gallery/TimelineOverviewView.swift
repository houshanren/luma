import AppKit
import SwiftUI

/// 总览卡片的拼图底板：1～4 张照片铺满卡片。
private struct TimelineMosaic: View {
    let photos: [PhotoItem]

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
        PhotoThumbnailView(photo: photo)
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
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    private var corner: CGFloat { max(10, settings.cardRadius) }
    private var titleSize: CGFloat { min(34, max(17, height * 0.115)) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                TimelineMosaic(photos: photos)

                LinearGradient(colors: [Color.black.opacity(0.62),
                                        Color.black.opacity(0.22),
                                        Color.black.opacity(0)],
                               startPoint: .top,
                               endPoint: .center)
                    .allowsHitTesting(false)

                // 底部压暗，保证卡片底部的数量与悬停提示始终可读。
                LinearGradient(colors: [.clear, Color.black.opacity(0.42)],
                               startPoint: .center,
                               endPoint: .bottom)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: titleSize, weight: .bold, design: .rounded))
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
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(14)
                    .opacity(hovering ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.88)
                    .animation(settings.motion.hover, value: hovering)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                                  lineWidth: hovering ? 1 : 0.5)
            }
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.14),
                    radius: hovering ? 16 : 7,
                    y: hovering ? 9 : 3)
            .scaleEffect(hovering && settings.hoverLift ? 1.012 : 1)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
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
    @EnvironmentObject private var store: LibraryStore
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

struct DayOverviewGroup: Identifiable {
    let id: String
    let title: String
    let photos: [PhotoItem]
}

/// 「月」分组：按月分段，段内按天展示拼图卡片，点击回到所有照片并定位到那天。
struct MonthOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if store.usesSQLOverview {
                        ForEach(store.monthGroups) { month in
                            Section {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TimelineMetrics.gap),
                                                         count: columns),
                                          spacing: TimelineMetrics.gap) {
                                    ForEach(month.days) { day in
                                        TimelineCard(photos: Array(day.photos.prefix(4)),
                                                     title: day.title,
                                                     subtitle: "\(day.count) 张",
                                                     width: cardWidth,
                                                     height: cardHeight) {
                                            if let first = day.photos.first {
                                                store.openAllPhotos(at: first.id)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(.horizontal, TimelineMetrics.horizontal)
                                .padding(.bottom, 26)
                            } header: {
                                SectionHeaderView(title: month.title, count: month.count)
                            }
                            .id(month.id)
                        }
                    } else {
                        ForEach(store.sections) { section in
                            Section {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TimelineMetrics.gap),
                                                         count: columns),
                                          spacing: TimelineMetrics.gap) {
                                    ForEach(dayGroups(in: section.photos)) { group in
                                        TimelineCard(photos: Array(group.photos.prefix(4)),
                                                     title: group.title,
                                                     subtitle: "\(group.photos.count) 张",
                                                     width: cardWidth,
                                                     height: cardHeight) {
                                            if let first = group.photos.first {
                                                store.openAllPhotos(at: first.id)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(.horizontal, TimelineMetrics.horizontal)
                                .padding(.bottom, 26)
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

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = store.scrollTargetSection else { return }
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(target, anchor: .top)
            }
            store.scrollTargetSection = nil
        }
    }

    private func dayGroups(in photos: [PhotoItem]) -> [DayOverviewGroup] {
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
            return DayOverviewGroup(id: key, title: title, photos: items)
        }
    }
}
