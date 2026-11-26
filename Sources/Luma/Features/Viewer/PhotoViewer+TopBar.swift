import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoViewerView {
    // MARK: - 顶栏照片信息

    // MARK: - 顶栏视频控件

    /// 顶栏融合是否生效：窗口内浏览视频，且设置里选了「顶栏融合」。
    var showsVideoToolbarControls: Bool {
        embedded && settings.videoControlPlacement == .topIntegrated && (photo?.isVideo ?? false)
    }

    /// 顶栏播放舱：上行是拍摄信息与序号，下行是进度与时间。
    /// 宽度固定、高度压到两行最紧凑的一档：翻页时胶囊尺寸不变，画面也不会被工具栏遮住太多。
    /// 直播没有可拖动的时间轴，顶栏只保留一行换台信息，避免内容顶出胶囊。
    @ViewBuilder
    func videoToolbarDeck(_ photo: PhotoItem) -> some View {
        if store.tvPlaybackChannel(for: photo.id) != nil {
            TVToolbarDeck(store: store, photo: photo, player: videoModel, tv: store.tvModel)
        } else if let entry = cinemaEntry(for: photo) {
            // 影视播放：顶栏改成「正在放映」舱，不再显示文件拍摄时间。
            // 宽度跟随工具栏可用空间（上限 600），并把实测宽度交给信息行做分级收放。
            HStack(alignment: .center, spacing: 8) {
                CinemaArtwork(urlString: entry.posterURL ?? entry.backdropURL,
                              contentMode: .fill,
                              maxPixelSize: 160)
                    .frame(width: 20, height: 27)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.6)
                    }
                    .fixedSize()

                VStack(spacing: 1) {
                    // 工具栏给的实际宽度只有 GeometryReader 拿得到（偏好值传不出 ToolbarItem），
                    // 用它驱动信息行的分级收放，宽窄判断才真实可靠。
                    GeometryReader { proxy in
                        cinemaToolbarInfoLine(entry, width: proxy.size.width)
                            .frame(width: proxy.size.width, height: 18, alignment: .leading)
                    }
                    .frame(height: 18)
                    HStack(spacing: 6) {
                        VideoToolbarProgress(model: videoModel,
                                             session: viewer.playbackSession,
                                             showsRemaining: $videoShowsRemainingTime,
                                             chapterFractions: toolbarChapterFractions)
                            .frame(maxWidth: .infinity)
                        VideoInlineVolume(model: videoModel)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 0)
            .frame(minWidth: 520, maxWidth: 640).offset(y: -3)
        } else if let context = catalogContext(for: photo) {
            // 网络资源（网页源）：海报 + 片名 + 来源站点 + 分集号 + 队列 / 下一集，
            // 与直播舱、影院舱共用同一套信息语言与分级收放规则。
            HStack(alignment: .center, spacing: 8) {
                CatalogArtworkImage(source: context.source,
                                    urlString: catalogCoverURL(context),
                                    cornerRadius: 3)
                    .frame(width: 20, height: 27)
                    .fixedSize()

                VStack(spacing: 1) {
                    GeometryReader { proxy in
                        catalogToolbarInfoLine(context, photo: photo, width: proxy.size.width)
                            .frame(width: proxy.size.width, height: 18, alignment: .leading)
                    }
                    .frame(height: 18)
                    HStack(spacing: 6) {
                        VideoToolbarProgress(model: videoModel,
                                             session: viewer.playbackSession,
                                             showsRemaining: $videoShowsRemainingTime,
                                             chapterFractions: toolbarChapterFractions)
                            .frame(maxWidth: .infinity)
                        VideoInlineVolume(model: videoModel)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 0)
            .frame(minWidth: 520, maxWidth: 640).offset(y: -3)
        } else {
            // 工具栏本身已经有一层玻璃胶囊：这里不再叠自己的背景，只保留内容。
            VStack(spacing: 0) {
                videoToolbarInfoLine(photo)
                HStack(spacing: 6) {
                    VideoToolbarProgress(model: videoModel,
                                         session: viewer.playbackSession,
                                         showsRemaining: $videoShowsRemainingTime,
                                         chapterFractions: toolbarChapterFractions)
                        .frame(maxWidth: .infinity)
                    // 音量收在进度右端：移入图标向左展开一条可拖动的小轨道，不占常驻宽度。
                    VideoInlineVolume(model: videoModel)
                }
            }
            .padding(.horizontal, 12)
            // 两行内容贴住胶囊上沿时会被切掉：顶部留出一点余量，底部相应收紧，整体高度不变。
            .padding(.top, 5)
            .padding(.bottom, 0)
            // 固定宽度：尽量容下标题 / 时间 / 地点 / 序号，翻页时不再左右跳动。
            .frame(width: 560)
        }
    }

    /// 当前播放项是否来自影院（且与查看器里的条目对得上）。
    func cinemaEntry(for photo: PhotoItem) -> CinemaEntry? {
        guard let entry = store.cinemaPlaybackEntry, entry.file.photoID == photo.id else { return nil }
        return entry
    }

    /// 影院信息行：只保留「正在放映」的必要信息，并随舱宽分级收放。
    /// 宽：片名 + 类型年份 + 季集号 + 评分 + 画质；中：去类型与画质；
    /// 窄：只留片名 + 季集号；队列位置与「下一集」始终靠右，窄舱下按钮退化成图标。
    func cinemaToolbarInfoLine(_ entry: CinemaEntry, width: CGFloat) -> some View {
        let wide = width >= 560
        let regular = width >= 470
        let specs = wide ? cinemaBadgeTags(entry.file, limit: 1) : []
        let episode = cinemaEpisodeCode(entry)
        let next = entry.kind == .tv ? store.cinemaQueueNeighbor(of: entry.id, delta: 1) : nil
        return HStack(spacing: 5) {
            // 左右各留一段可伸缩空白：片名与标签整体居中，光标不用去最左边找。
            Spacer(minLength: 6)
            Text(entry.title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.01)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(cinemaTitleHelp(entry))

            if wide {
                let kindText = entry.kind == .tv ? "剧集" : "电影"
                Text(entry.year.map { "\(kindText) · \($0)" } ?? kindText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.52))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    .fixedSize()
                    .help(entry.year.map { "\(kindText) · \($0) 年" } ?? kindText)
            }

            if let episode {
                Text(episode)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                    }
                    .fixedSize()
                    .help(cinemaEpisodeHelp(entry))
            }

            if regular, let rating = entry.rating ?? entry.doubanRating, rating > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7.5))
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(LumaBrand.amber)
                .fixedSize()
                .help("评分 \(String(format: "%.1f", rating))")
            }

            ForEach(specs, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.50))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    .fixedSize()
            }

            Spacer(minLength: 4)

            if let currentIndex, regular {
                Text("\(currentIndex + 1)/\(totalCount)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.48))
                    .lineLimit(1)
                    .fixedSize()
                    .help(entry.kind == .tv
                          ? "队列位置：第 \(currentIndex + 1) / \(totalCount) 集"
                          : "队列位置：第 \(currentIndex + 1) / \(totalCount) 部")
            }

            if let next {
                Button {
                    _ = store.stepCinemaQueue(1)
                } label: {
                    HStack(spacing: 3) {
                        if wide || regular { Text("下一集") }
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.horizontal, wide || regular ? 6 : 4)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("下一集：\(cinemaNextEpisodeHelp(next))")
            }

            // 音轨 / 字幕 / 比例入口按真实宽度占位，不再浮在文字上方。
            VideoMediaMenuButtons(ui: videoUI, model: videoModel, style: .toolbar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    func cinemaTitleHelp(_ entry: CinemaEntry) -> String {
        guard let original = entry.originalTitle,
              !original.isEmpty,
              original != entry.title else { return entry.title }
        return "\(entry.title)（\(original)）"
    }

    /// 季集号：第1季·第1集；一次包含多集时写成第1季·第1-3集。
    func cinemaEpisodeCode(_ entry: CinemaEntry) -> String? {
        guard entry.kind == .tv else { return nil }
        if let season = entry.season, let episode = entry.episode {
            if let end = entry.episodeEnd, end > episode {
                return "第\(season)季·第\(episode)-\(end)集"
            }
            return "第\(season)季·第\(episode)集"
        }
        if let episode = entry.episode {
            if let end = entry.episodeEnd, end > episode {
                return "第\(episode)-\(end)集"
            }
            return "第\(episode)集"
        }
        return nil
    }

    func cinemaEpisodeHelp(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let season = entry.season { parts.append("第 \(season) 季") }
        if let episode = entry.episode {
            if let end = entry.episodeEnd, end > episode {
                parts.append("第 \(episode)–\(end) 集")
            } else {
                parts.append("第 \(episode) 集")
            }
        }
        return parts.isEmpty ? "剧集" : parts.joined(separator: " · ")
    }

    func cinemaNextEpisodeHelp(_ entry: CinemaEntry) -> String {
        let code = cinemaEpisodeCode(entry)
        return code.map { "\($0) · \(entry.title)" } ?? entry.title
    }
}
