import SwiftUI
import AppKit
import Foundation
import LumaContentCore

/// 海报墙的一次性聚合结果：按挂载遍历一遍，视图只读结果。
struct CloudCinemaWall {
    var mounts: [CloudMountCinemaItem] = []
    var movies: [CloudCinemaWallItem] = []
    var series: [CloudCinemaWallItem] = []
    var spotlight: CloudCinemaWallItem?
    var continueRecords: [CinemaProgressRecord] = []
    var unmatched = 0
}

/// 海报墙的一张条目：电影取单条刮削结果，剧集取合并后的整部剧。
struct CloudCinemaWallItem: Identifiable {
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

    /// 年份：电影取单条，剧集取整部剧。
    var year: Int? { entry?.year ?? series?.year }
}

/// 影院聚合页的筛选：全部 / 有海报 / 最近 30 天。
enum CinemaWallFilter: String, CaseIterable, Identifiable {
    case all, artwork, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .artwork: return "有海报"
        case .recent: return "最近 30 天"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .artwork: return "photo"
        case .recent: return "calendar"
        }
    }
}

/// 影院聚合页的排序：最近刮削 / 片名 / 年份。
enum CinemaWallSort: String, CaseIterable, Identifiable {
    case recent, title, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "最近"
        case .title: return "片名"
        case .year: return "年份"
        }
    }

    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .title: return "textformat"
        case .year: return "calendar"
        }
    }
}

/// 海报墙卡片：竖版海报 + 标题 + 副标题，悬停出播放按钮。
struct CloudCinemaPosterCard: View {
    let item: CloudCinemaWallItem
    let onOpen: () -> Void

    @State var hovering = false

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

                Image(systemName: "info.circle.fill")
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
        .help("查看「\(item.title)」详情")
    }
}

/// 接着看卡片：横版剧照 + 进度条，悬停出播放按钮。
struct CloudCinemaContinueCard: View {
    let record: CinemaProgressRecord
    let mountName: String
    let onOpen: () -> Void

    @State var hovering = false

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
struct CloudMountCinemaItem: Identifiable {
    let mount: CloudMount
    let summary: CloudCinemaSummary

    var id: UUID { mount.id }
}

/// 单个网盘影院的轻量汇总：只遍历一次条目，避免卡片里反复过滤。
struct CloudCinemaSummary {
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
