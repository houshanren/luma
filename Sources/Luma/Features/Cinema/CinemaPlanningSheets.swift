import SwiftUI

// MARK: - 缺集报告

/// 只读报告：剧集按季缺集 + 电影系列未入库的部件。不提供自动下载，只负责把缺口说清楚。
struct CinemaGapSheet: View {
    let scope: CinemaScope

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var movieGaps: [CinemaGapGroup] = []
    @State private var loadingMovies = true

    private var tvGaps: [CinemaGapGroup] {
        store.cinemaEpisodeGaps(for: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.badge.minus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("缺集报告")
                        .font(.system(size: 14, weight: .semibold))
                    Text("剧集按季统计缺集；电影系列只查前几个 TMDB 合集")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(title: "剧集缺集",
                            detail: "\(tvGaps.count) 部有缺口",
                            gaps: tvGaps,
                            empty: "当前影院没有发现缺集。")
                    section(title: "电影系列未入库",
                            detail: loadingMovies ? "读取中…" : "\(movieGaps.count) 个系列不完整",
                            gaps: movieGaps,
                            empty: loadingMovies ? "正在读取 TMDB 合集…" : "没有发现缺片，或合集信息不完整。")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("只列出缺口，不会自动下载或修改文件。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 560, height: 470)
        .task {
            movieGaps = await store.cinemaMovieCollectionGaps(for: scope)
            loadingMovies = false
        }
    }

    private func section(title: String,
                         detail: String,
                         gaps: [CinemaGapGroup],
                         empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if gaps.isEmpty {
                Text(empty)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(gaps) { gap in
                    gapRow(gap)
                }
            }
        }
    }

    private func gapRow(_ gap: CinemaGapGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: gap.kind == .tv ? "tv" : "film")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(gap.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(gap.owned)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(gap.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            chipWrap(gap.missing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func chipWrap(_ items: [String]) -> some View {
        let shown = items.prefix(18)
        let rest = items.count - shown.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                if rest > 0 {
                    Text("+\(rest)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - 观影计划

struct CinemaWatchPlanSheet: View {
    let scope: CinemaScope

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 90
    @State private var mood: CinemaPlanMood = .any

    private let minuteOptions: [(value: Int, title: String)] = [
        (0, "不限"), (60, "1 小时"), (90, "1.5 小时"), (120, "2 小时"), (180, "3 小时")
    ]

    private var plan: CinemaWatchPlan {
        store.cinemaWatchPlan(scope: scope, minutes: minutes, mood: mood)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "popcorn")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("观影计划")
                        .font(.system(size: 14, weight: .semibold))
                    Text("按可用时长与心情挑片；优先未看完与收藏，不联网")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Text("时长")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ForEach(minuteOptions, id: \.value) { option in
                    chip(option.title, active: minutes == option.value) {
                        minutes = option.value
                    }
                }
            }

            HStack(spacing: 6) {
                Text("心情")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ForEach(CinemaPlanMood.allCases) { option in
                    chip(option.title, active: mood == option, symbol: option.symbol) {
                        mood = option
                    }
                }
            }

            Divider()

            Text(plan.note)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    if plan.items.isEmpty {
                        Text("当前影院还没有可排片的电影。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ForEach(plan.items) { item in
                            row(item)
                        }
                    }
                }
            }

            Divider()

            HStack {
                if !plan.items.isEmpty {
                    Text("共 \(plan.totalMinutes) 分钟")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 540, height: 450)
    }

    private func chip(_ title: String,
                      active: Bool,
                      symbol: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(active ? Color.accentColor : Color.primary.opacity(0.06),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: CinemaPlanItem) -> some View {
        Button {
            dismiss()
            store.openCinema(item.entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.entry.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        if let year = item.entry.year {
                            Text(String(year))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(item.reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(CinemaWatchPlan.runtime(of: item.entry)) 分钟")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
