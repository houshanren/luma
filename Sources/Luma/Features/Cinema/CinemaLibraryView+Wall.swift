import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院页的海报墙：分段网格、统计条与字母索引。

extension CinemaLibraryView {
    // MARK: 海报墙

    /// 列宽交给网格自适应，卡片按列宽铺满（不再固定 156 塞进更宽的格子，
    /// 否则每张卡右边会多出一条空白，看着像缩略图没铺满）。
    var wallColumns: [GridItem] {
        [GridItem(.adaptive(minimum: wallDensity.minimumColumnWidth), spacing: 16, alignment: .top)]
    }

    @ViewBuilder
    var wallContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .all:
            if !series.isEmpty {
                wallSection("电视剧", count: series.count) {
                    ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                        wallSeriesCard(item)
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
                        wallSeriesCard(item)
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
                            wallSeriesCard(item)
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
                        wallSeriesCard(item)
                            .onAppear { prefetchSeriesArtwork(series, around: index) }
                    }
                }
            }
        }
    }

    /// 滚动预取：某张卡出现时，把紧接着的几张海报提前解好，快速滚动不再追帧。
    func prefetchPosters(_ entries: [CinemaEntry], around index: Int, peeking: Int = 8) {
        let upper = min(entries.count, index + peeking)
        guard index < upper else { return }
        CinemaArtworkCache.shared.prefetch(entries[index..<upper].compactMap(\.posterURL))
    }

    func prefetchSeriesArtwork(_ items: [CinemaSeries], around index: Int, peeking: Int = 8) {
        let upper = min(items.count, index + peeking)
        guard index < upper else { return }
        CinemaArtworkCache.shared.prefetch(items[index..<upper].compactMap(\.artworkURL))
    }

    func posterCard(_ entry: CinemaEntry, fillWidth: Bool = false) -> some View {
        CinemaPosterCard(entry: entry,
                         versionCount: aggregate.versionCounts[store.cinemaVersionKey(for: entry)] ?? 0,
                         fillWidth: fillWidth,
                         isCursor: isWallCursor(entry),
                         onOpen: { openDetail(entry) },
                         onPlay: { store.openCinema(entry, queue: aggregate.allEntries) },
                         onDetail: { openDetail(entry) })
            .id(entry.id)
    }

    func wallSeriesCard(_ item: CinemaSeries) -> some View {
        CinemaSeriesCard(series: item,
                         fillWidth: true,
                         isCursor: isWallCursor(item)) {
            detailTarget = .series(item)
        }
        .id(item.id)
    }

    // MARK: 海报墙键盘游标

    func isWallCursor(_ entry: CinemaEntry) -> Bool {
        store.cinemaViewMode == .wall && wallCursorKey == "m:\(entry.id.uuidString)"
    }

    func isWallCursor(_ item: CinemaSeries) -> Bool {
        store.cinemaViewMode == .wall && wallCursorKey == "s:\(item.id)"
    }

    /// 海报墙的视觉顺序：和 `wallContent` 的分段顺序保持一致，
    /// 方向键才能按「一行一行」走，而不是在剧集 / 影片之间乱跳。
    var wallCursorKeys: [String] {
        guard store.cinemaViewMode == .wall, store.cinemaTab != .folder else { return [] }
        switch store.cinemaTab {
        case .all:
            var keys = series.map { "s:\($0.id)" } + movies.map { "m:\($0.id.uuidString)" }
            if !isFilteringCinema {
                keys += unmatchedSeries.map { "s:\($0.id)" }
                keys += unmatchedMovies.map { "m:\($0.id.uuidString)" }
            }
            return keys
        case .movies:
            return movies.map { "m:\($0.id.uuidString)" }
        case .shows:
            return (series.isEmpty ? unmatchedSeries : series).map { "s:\($0.id)" }
        case .folder:
            return []
        }
    }

    /// 回车 / 空格：打开游标所在的影片详情或剧集详情。
    func openWallCursor(_ key: String) {
        if key.hasPrefix("s:") {
            let id = String(key.dropFirst(2))
            if let item = (series + unmatchedSeries).first(where: { $0.id == id }) {
                detailTarget = .series(item)
            }
        } else if key.hasPrefix("m:"),
                  let uuid = UUID(uuidString: String(key.dropFirst(2))),
                  let entry = (movies + unmatchedMovies).first(where: { $0.id == uuid }) {
            openDetail(entry)
        }
    }

    /// 滚到游标所在的卡片：剧集用字符串 id，影片用 UUID，沿用卡片原本的 `.id`。
    func wallScrollTarget(_ key: String?) -> AnyHashable? {
        guard let key else { return nil }
        if key.hasPrefix("s:") { return AnyHashable(String(key.dropFirst(2))) }
        if key.hasPrefix("m:"),
           let uuid = UUID(uuidString: String(key.dropFirst(2))) {
            return AnyHashable(uuid)
        }
        return nil
    }

    func wallSection<Content: View>(_ title: String,
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

    // MARK: 海报墙统计 / 字母索引

    /// 统计条：规格分布 + 已看，回答「这个库有什么、看了多少」。
    var wallStatsBar: some View {
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

    func statChip(_ title: String, _ value: Int, tint: Color = LumaBrand.amber) -> some View {
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
            Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: LumaControlMetrics.hairline)
        }
    }

    var wallItemCount: Int { aggregate.wallItemCount }

    /// 每部作品取首字符作为索引字母；中文片名直接用首字。
    var wallLetterEntries: [CinemaLetterEntry] { aggregate.letters }

    /// 大库专用：条目超过 200 才出现字母索引。
    @ViewBuilder
    func wallLetterRail(_ proxy: ScrollViewProxy) -> some View {
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
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
            }
            .padding(.trailing, 6)
        }
    }

    func tabEmptyState(_ text: String) -> some View {
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
}
