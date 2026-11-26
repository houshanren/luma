import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoItem {
    /// 没有读到任何拍摄日期时 `capturedAt` 会是纪元起点（显示成 1970 年）。
    /// 顶栏用「时间未知」代替这种异常日期，避免把缺失信息伪装成真实时间。
    var hasKnownCaptureDate: Bool {
        capturedAt.timeIntervalSince1970 > 86_400
    }
}

// MARK: - 工具栏频道舱

/// 窗口工具栏里的电视「频道舱」：频道号 / 台标 / 台名 / 直播状态 + Now & Next + 节目进度 + 线路读数。
/// 独立成小视图，直接观察播放器与频道模型，节目进度与收藏状态才能随时间实时刷新。
struct TVToolbarDeck: View {
    @Bindable var store: LibraryStore
    let photo: PhotoItem
    /// 播放器：只传给音量控件；频道舱本身不再按播放时间 4Hz 重绘。
    let player: VideoPlayerModel
    /// 频道模型：节目单与收藏状态变化时刷新。
    @Bindable var tv: IPTVBrowserModel

    var body: some View {
        let channel = store.tvPlaybackChannel(for: photo.id)
        let number = channel.map { tv.channelNumber(for: $0) } ?? 0
        let now = channel.flatMap { tv.currentProgram(for: $0) }
        let lineIndex = store.tvLineIndex(for: photo.id)
        let lineCount = store.tvLineCount(for: photo.id)
        let isCatchup = channel?.isCatchUp == true
        let programTitle = isCatchup
            ? (photo.title ?? channel?.name ?? "回看")
            : now?.title

        // 单行排布：频道身份 + Now + 线路。
        // 台名 / 节目不设固定宽度，靠 layoutPriority 吃满剩余空间：
        // 台名优先完整显示，节目在后，窗口变窄时先收节目，再收台名。
        // 回看在下面多一行真正的进度条：可点、可拖，不再挤在舱底 1.5pt 的细线上。
        return VStack(spacing: 3) {
            HStack(spacing: 7) {
                // 频道号：整条舱里最重的一档，扫一眼就知道在哪个台。
                Text(String(format: "%02d", number))
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .fixedSize()

                TVLogoImage(urlString: channel?.logoURL,
                            size: CGSize(width: 38, height: 19),
                            cornerRadius: 3)
                    .fixedSize()

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 16)

                Text(channel?.name ?? "直播频道")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.01)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
                    .help(channel?.name ?? "直播频道")

                // 直播状态只留一枚信号点，不再占用「直播」两个字的宽度。
                if isCatchup {
                    tag("回看")
                } else {
                    Circle()
                        .fill(TVBrand.signal)
                        .frame(width: 5.5, height: 5.5)
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                        }
                        .shadow(color: TVBrand.signal.opacity(0.55), radius: 3)
                        .fixedSize()
                        .help("正在直播")
                }

                if let programTitle {
                    Text(programTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .help(isCatchup
                              ? programTitle
                              : programTitle + " · "
                                + Self.clock.string(from: now?.start ?? Date())
                                + "–" + Self.clock.string(from: now?.end ?? Date()))
                } else {
                    Text("暂无节目单")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if isCatchup {
                    Text(Self.catchupWhen(photo.capturedAt))
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                        .fixedSize()
                        .help("这档节目的播出时间")
                }

                Spacer(minLength: 4)

                if lineCount > 1 {
                    readout(channel: channel,
                            lineIndex: lineIndex,
                            lineCount: lineCount)
                }
                VideoInlineVolume(model: player)
            }
            if isCatchup {
                TVCatchupProgressBar(model: player, epgDuration: photo.duration ?? 0)
                    .padding(.horizontal, 2)
            }
        }
        .frame(minWidth: 480, maxWidth: 720)
        .padding(.horizontal, 8)
        .padding(.top, 3)
        .padding(.bottom, isCatchup ? 1 : 2)
        // 直播：节目进度贴在舱底；回看已经有自己那一行可拖进度条，不再叠一条细线。
        .overlay(alignment: .bottom) {
            if !isCatchup {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(TVBrand.wave.opacity(0.72))
                                .frame(width: max(0, proxy.size.width
                                                  * Self.progress(now, at: context.date)))
                        }
                        .transaction { $0.animation = nil }
                    }
                    .frame(height: 1.5)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 0.5)
            }
        }
    }

    /// 右侧读数胶囊：多线路时点「1/2」直接换线。
    /// 单线与协议文字不再常驻，把宽度让给台名与节目。
    private func readout(channel: TVChannel?,
                         lineIndex: Int,
                         lineCount: Int) -> some View {
        Menu {
            ForEach(store.tvLineGroups(for: photo.id)) { group in
                Section {
                    ForEach(group.lines) { line in
                        Button {
                            _ = store.selectTVLine(url: line.url, for: photo.id)
                        } label: {
                            let title = "\(line.title) · \(protocolLabel(of: line.url, channel: channel))"
                            Text(line.url == channel?.streamURL ? "✓ \(title)" : title)
                        }
                    }
                } header: {
                    Text(group.sourceName)
                }
            }
        } label: {
            HStack(spacing: 1.5) {
                Text("\(lineIndex + 1)/\(lineCount)")
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(Color.primary.opacity(0.80))
            .font(.system(size: 8.5, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize().layoutPriority(3)
        .help("选择播放线路 · 当前 \(lineIndex + 1)/\(lineCount)")
    }

    /// 单条线路的协议：优先用换线时记下的元数据，缺失时跟随频道当前协议。
    private func protocolLabel(of url: String, channel: TVChannel?) -> String {
        let hls = store.tvLineMetadata[url]?.isHLS ?? (channel?.isHLS ?? true)
        return hls ? "HLS" : "HTTP"
    }

    /// 台名旁的小标签（回看 / 时移等）。
    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
            .fixedSize()
    }

    /// 回看的播出时刻：「昨天 20:04」比一个光秃秃的 20:04 更好定位。
    private static func catchupWhen(_ date: Date) -> String {
        let day = DateText.relativeDayOffset(date)
            ?? date.formatted(.dateTime.month(.defaultDigits).day())
        return day + " " + clock.string(from: date)
    }

    private static func progress(_ program: TVEPGProgram?, at date: Date) -> CGFloat {
        guard let program else { return 0 }
        let span = program.end.timeIntervalSince(program.start)
        guard span > 1 else { return 0 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(program.start) / span)))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 回看进度条

/// 回看舱里唯一跟随播放器刷新的读数格式。
enum TVDeckFormat {
    /// 播放读数：不足一小时用 mm:ss，超过用 h:mm:ss。
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// 回看进度条：信息行下方独立一行，`已播 · 轨道 · 总时长`。
/// 直接复用播放页的 `VideoScrubber`——整条 16pt 都是热区，悬停加粗、拖动跟手、
/// 松手才真正落位；不再是舱底那条 1.5pt 只能看的细线。
/// 总时长优先用播放器解析出的片长，解析不出时用节目单时长兜底，避免读数停在 00:00。
struct TVCatchupProgressBar: View {
    @ObservedObject var model: VideoPlayerModel
    let epgDuration: Double

    @State private var hostWindow: NSWindow?

    private var total: Double {
        model.duration > 1 ? model.duration : max(0, epgDuration)
    }
    private var position: Double { max(0, model.currentTime) }
    private var progress: Double {
        guard total > 1 else { return 0 }
        return min(1, max(0, position / total))
    }
    private var buffered: Double {
        guard total > 1 else { return 0 }
        return min(1, max(0, model.bufferedTime / total))
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(TVDeckFormat.timecode(position))
                .foregroundStyle(TVBrand.gold.opacity(0.95))
                .frame(minWidth: 34, alignment: .trailing)

            VideoScrubber(progress: progress,
                          buffered: buffered,
                          tint: TVBrand.gold,
                          knobBorder: Color.white.opacity(0.72),
                          duration: total,
                          onPreviewChange: { fraction in
                              // 与普通视频的顶栏进度条同一套悬停预览：
                              // 回看自己没有取帧逻辑，气泡与取帧都复用播放页那一套。
                              guard AppSettings.shared.scrubPreviewEnabled else {
                                  VideoScrubPreviewCenter.shared.end()
                                  return
                              }
                              if let fraction {
                                  VideoScrubPreviewCenter.shared.hover(fraction: fraction,
                                                                       duration: total,
                                                                       player: model.player,
                                                                       window: hostWindow)
                              } else {
                                  VideoScrubPreviewCenter.shared.end()
                              }
                          },
                          onSeek: { value in
                              guard total > 1 else { return }
                              model.scrub(to: value * total)
                          },
                          onCommit: { value in
                              guard total > 1 else { return }
                              model.requestSeek(to: value * total)
                          })
                .frame(minWidth: 140, maxWidth: .infinity)
                .background {
                    WindowAccessor { window in
                        if hostWindow !== window { hostWindow = window }
                    }
                }

            Text(TVDeckFormat.timecode(total))
                .foregroundStyle(Color.primary.opacity(0.52))
                .frame(minWidth: 34, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .contentShape(Rectangle())
    }
}
