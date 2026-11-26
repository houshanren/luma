import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoViewerView {
    // MARK: - 网络资源播放舱

    /// 当前播放项是否来自网络资源（网页源分集）。
    func catalogContext(for photo: PhotoItem) -> CatalogPlaybackContext? {
        store.catalogPlaybackContext(for: photo.id)
    }

    func catalogCoverURL(_ context: CatalogPlaybackContext) -> String {
        context.episode.coverURL.isEmpty ? context.item.coverURL : context.episode.coverURL
    }

    /// 站点备注里的评分：`更新至 7 集 · 8.1 分` → 8.1。
    func catalogRating(from remark: String) -> Double? {
        for part in remark.split(separator: "·") {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard text.hasSuffix("分"),
                  let value = Double(text.dropLast().trimmingCharacters(in: .whitespaces)) else { continue }
            return value
        }
        return nil
    }

    /// 网络资源信息行：片名 / 来源站点 / 分集号 / 站点评分，右端是队列位置与「下一集」。
    /// 来源站点用它的强调色圆点标记，相当于直播里的台标身份。
    func catalogToolbarInfoLine(_ context: CatalogPlaybackContext,
                                        photo: PhotoItem,
                                        width: CGFloat) -> some View {
        let wide = width >= 560
        let regular = width >= 470
        let remark = context.item.remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let rating = catalogRating(from: remark)
        let hasNext = store.hasAdjacentVideo(from: photo.id, delta: 1)
        return HStack(spacing: 5) {
            // 左右各留一段可伸缩空白：片名与来源 / 分集整体居中。
            Spacer(minLength: 6)
            Text(context.item.title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.01)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(context.item.title)

            // 来源站点：颜色圆点常驻，名称在常规宽度以上出现。
            HStack(spacing: 3) {
                Circle()
                    .fill(context.source.kind.sidebarTint)
                    .frame(width: 5, height: 5)
                if wide || regular {
                    Text(context.source.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.52))
                        .lineLimit(1)
                        .frame(maxWidth: 72, alignment: .leading)
                }
            }
            .fixedSize()
            .help("来源：\(context.source.name)")

            Text(context.episode.title)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                }
                .fixedSize()
                .help(context.episode.title)

            if regular, let rating {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7.5))
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(LumaBrand.amber)
                .fixedSize()
                .help("站点评分 \(String(format: "%.1f", rating))")
            } else if wide, !remark.isEmpty, rating == nil {
                // 没有评分时退回站点自己的更新备注，只露出一小段，悬停看全文。
                Text(remark.count > 12 ? String(remark.prefix(12)) + "…" : remark)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.46))
                    .lineLimit(1)
                    .fixedSize()
                    .help(remark)
            }

            Spacer(minLength: 4)

            if let currentIndex, regular {
                Text("\(currentIndex + 1)/\(totalCount)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.48))
                    .lineLimit(1)
                    .fixedSize()
                    .help("播放列表位置：\(currentIndex + 1) / \(totalCount)")
            }

            if hasNext {
                Button {
                    store.viewerStepVideo(1)
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
                .help("播放下一集")
            }

            VideoMediaMenuButtons(ui: videoUI, model: videoModel, style: .toolbar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// 播放舱第一行：与原先顶栏信息一致，标题 / 实况 / 日期时间 / 地点 / 圆环与序号全部保留。
    func videoToolbarInfoLine(_ photo: PhotoItem) -> some View {
        let tvName = tvChannelName(for: photo)
        let title = burstTitle ?? tvName ?? infoTitle(for: photo)
        let showsLead = title != nil || photo.isLivePhoto
        return HStack(spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.01)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            if photo.isLivePhoto {
                liveTag
            }

            if showsLead {
                infoSeparator
            }

            if tvName == nil {
                if photo.hasKnownCaptureDate {
                    captureStamp(photo.capturedAt, size: 11)
                } else {
                    Text("时间未知")
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
            }

            if let place = infoPlaceLine(for: photo) {
                infoSeparator
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(place)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
            }

            if let currentIndex {
                infoSeparator
                progressRing
                // 与照片模式的序号写法一致：当前序号 + 总数，播放舱变宽后不再省略总数。
                HStack(spacing: 2) {
                    Text("\((currentIndex + 1).formatted())")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    Text("/ \(totalCount.formatted())")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                .lineLimit(1)
                .fixedSize()
            }

        }
        // 信息行整体居中，音轨 / 字幕按钮浮在右端，避免把信息拽到左侧。
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            // 音轨 / 字幕入口：与画面内控制条、顶栏保持同一份状态。
            VideoMediaMenuButtons(ui: videoUI, model: videoModel, style: .toolbar)
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// 播放舱进度条的章节刻度：与画面内进度条同一份章节数据。
    var toolbarChapterFractions: [Double] {
        guard videoModel.duration > 0 else { return [] }
        return videoUI.chapters
            .map { min(1, max(0, $0.start / videoModel.duration)) }
            .filter { $0 > 0.01 && $0 < 0.99 }
    }

    func rotateVideoPlayer() {
        store.rotateVideoDisplayCommand()
    }

    func toggleVideoFullScreen() {
        store.toggleVideoFullScreenCommand()
    }

    /// 保存当前帧：与画面朝向一致，由查看器统一保存（顶栏与画面内控制条共用）。
    func captureVideoFrame() {
        store.saveVideoFrameCommand()
    }
}
