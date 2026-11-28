import SwiftUI

/// 作品集：按年份、分类、番号翻资料库里的作品，点击进入统一详情。
struct AtlasWorksView: View {
    @Environment(AtlasStore.self) private var atlas
    @State private var searchTask: Task<Void, Never>?

    private var keyword: String {
        atlas.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider().opacity(0.1)
            ScrollView {
                if atlas.workItems.isEmpty {
                    if atlas.isLoadingWorks {
                        ProgressView("正在翻作品集…")
                            .padding(.top, 80)
                    } else {
                        AtlasEmptyState(title: keyword.isEmpty ? "没有符合条件的作品" : "没有找到「\(keyword)」",
                                        message: keyword.isEmpty ? "换一个年份或分类再试。" : "试试番号（如 SSIS-001）或片名的一部分。",
                                        symbol: "square.grid.2x2")
                            .padding(.top, 60)
                    }
                } else {
                    VStack(spacing: 18) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 14)],
                                  spacing: 18) {
                            ForEach(atlas.workItems) { work in
                                AtlasPosterCard(work: work) { atlas.focusedWork = $0 }
                                    .onAppear { loadMoreIfNeeded(work) }
                            }
                        }
                        footer
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            if atlas.workItems.isEmpty, !atlas.isLoadingWorks {
                atlas.reloadWorks()
            }
        }
        .onChange(of: atlas.searchText) { _, _ in scheduleSearchReload() }
    }

    // MARK: 筛选条

    private var filterBar: some View {
        HStack(spacing: 8) {
            yearMenu
            genreMenu
            sortMenu
            if hasFilters {
                Button {
                    atlas.workYear = nil
                    atlas.workGenre = nil
                    atlas.workSort = .newest
                    atlas.reloadWorks()
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(keyword.isEmpty
                 ? "共 \(atlas.workTotal) 部 · 已载 \(atlas.workItems.count)"
                 : "「\(keyword)」· \(atlas.workItems.count) 部")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var hasFilters: Bool {
        atlas.workYear != nil || atlas.workGenre != nil || atlas.workSort != .newest
    }

    private var yearMenu: some View {
        Menu {
            Button("全部年份") { setYear(nil) }
            Divider()
            ForEach(atlas.years.prefix(46)) { item in
                Button {
                    setYear(item.year)
                } label: {
                    if atlas.workYear == item.year {
                        Label("\(item.year) 年 · \(item.count) 部", systemImage: "checkmark")
                    } else {
                        Text("\(item.year) 年 · \(item.count) 部")
                    }
                }
            }
        } label: {
            filterChip(atlas.workYear.map { "\($0) 年" } ?? "全部年份",
                       symbol: "calendar", active: atlas.workYear != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var genreMenu: some View {
        Menu {
            Button("全部分类") { setGenre(nil) }
            Divider()
            ForEach(atlas.genres.prefix(48)) { item in
                Button {
                    setGenre(item.name)
                } label: {
                    if atlas.workGenre == item.name {
                        Label("\(item.name) · \(item.count)", systemImage: "checkmark")
                    } else {
                        Text("\(item.name) · \(item.count)")
                    }
                }
            }
        } label: {
            filterChip(atlas.workGenre ?? "全部分类",
                       symbol: "tag", active: atlas.workGenre != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AtlasWorkSort.allCases) { sort in
                Button {
                    setSort(sort)
                } label: {
                    if atlas.workSort == sort {
                        Label(sort.title, systemImage: "checkmark")
                    } else {
                        Label(sort.title, systemImage: sort.symbol)
                    }
                }
            }
        } label: {
            filterChip(atlas.workSort.title, symbol: "arrow.up.arrow.down",
                       active: atlas.workSort != .newest)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func filterChip(_ title: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(active ? Color.white : Color.primary.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.05))
        }
        .contentShape(Capsule())
    }

    private func setYear(_ year: Int?) {
        guard atlas.workYear != year else { return }
        atlas.workYear = year
        atlas.reloadWorks()
    }

    private func setGenre(_ genre: String?) {
        guard atlas.workGenre != genre else { return }
        atlas.workGenre = genre
        atlas.reloadWorks()
    }

    private func setSort(_ sort: AtlasWorkSort) {
        guard atlas.workSort != sort else { return }
        atlas.workSort = sort
        atlas.reloadWorks()
    }

    private func scheduleSearchReload() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            atlas.reloadWorks()
        }
    }

    private func loadMoreIfNeeded(_ work: AtlasWork) {
        let threshold = atlas.workItems.suffix(12).map(\.id)
        guard let id = threshold.first, work.id == id else { return }
        atlas.loadMoreWorks()
    }

    @ViewBuilder
    private var footer: some View {
        if atlas.isLoadingWorks {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载更多…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        } else if atlas.canLoadMoreWorks {
            Button("加载更多") { atlas.loadMoreWorks() }
                .buttonStyle(.bordered)
                .padding(.vertical, 8)
        } else {
            Text("已经到底了")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 10)
        }
    }
}
