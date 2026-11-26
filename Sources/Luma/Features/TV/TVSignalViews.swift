import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

/// 信号卡：真实截帧 + 媒体参数。失败时明确写「无法截帧」并给出原因。
struct TVSignalCard: View {
    let channel: TVChannel
    let number: Int
    let report: TVProbeReport?
    let state: TVProbeState
    let isFavorite: Bool
    let isBest: Bool
    let onPlay: () -> Void
    let onProbe: () -> Void
    let onToggleFavorite: () -> Void
    let onDetail: () -> Void

    @State private var hovered = false

    private var statusColor: Color {
        switch state {
        case .available: return TVBrand.success
        case .unavailable: return TVBrand.danger
        case .probing: return TVBrand.wave
        case .idle: return Color.secondary
        }
    }

    private var metrics: String {
        guard let report else {
            return state == .probing ? "正在抓帧…" : "未探测 · \(channel.lineCount) 线路"
        }
        guard report.isSuccess else {
            return report.error ?? "无法截帧"
        }
        return "\(report.resolutionText) · \(report.bitrateText) · \(report.latencyText) · \(channel.lineCount) 线路"
    }

    var body: some View {
        ZStack(alignment: .center) {
            Button(action: onPlay) { cardBody }
                .buttonStyle(.plain)
            if hovered {
                HStack(spacing: 6) {
                    hoverAction("info.circle.fill", help: "查看信号详情", action: onDetail)
                    hoverAction("arrow.clockwise", help: "重新探测", action: onProbe)
                }
                .padding(6)
                .background(Color.black.opacity(0.46), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
                .transition(.opacity)
            }
        }
        .onHover { value in
            withAnimation(.easeOut(duration: 0.14)) { hovered = value }
        }
        .contextMenu {
            Button("播放", action: onPlay)
            Button("查看信号详情", action: onDetail)
            Button("重新探测", action: onProbe)
            Divider()
            Button(isFavorite ? "取消收藏" : "收藏频道", action: onToggleFavorite)
        }
        .help("\(channel.name) · \(metrics)")
    }

    private func hoverAction(_ symbol: String,
                             help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            thumb
            nameRow
            Text(metrics)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(report?.isSuccess == true ? Color.secondary : Color.secondary.opacity(0.65))
                .lineLimit(1)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? TVBrand.surfaceHover : TVBrand.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovered ? Color.accentColor.opacity(0.35) : TVBrand.stroke,
                              lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var thumb: some View {
        TVSignalThumb(channel: channel, report: report, state: state)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .padding(7)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
            }
            .overlay(alignment: .topTrailing) {
                if isBest {
                    Text("最稳")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(TVBrand.onGold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(TVBrand.gold, in: Capsule(style: .continuous))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let quality = channel.qualityLabel {
                    let style = TVBrand.qualityStyle(quality)
                    Text(quality)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(style.fg)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(style.bg,
                                    in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        .padding(6)
                }
            }
    }

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(String(format: "%02d", number))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(channel.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            favoriteButton
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isFavorite ? TVBrand.gold : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "取消收藏" : "收藏频道")
    }
}

/// 16:9 截帧：优先用本次探测结果，其次读 30 分钟内的缓存。
struct TVSignalThumb: View {
    let channel: TVChannel
    let report: TVProbeReport?
    let state: TVProbeState

    @State private var cached: NSImage?

    private var shown: NSImage? { report?.image ?? cached }

    var body: some View {
        ZStack {
            Rectangle().fill(TVBrand.previewScrim)

            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 5) {
                    if state == .probing {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("抓帧中")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    } else if state == .unavailable {
                        Image(systemName: "video.slash")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("无法截帧")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    } else if let logo = channel.logoURL, !logo.isEmpty {
                        TVLogoImage(urlString: logo, size: CGSize(width: 58, height: 33))
                        Text("未探测")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                        Text("未探测")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: report?.updatedAt) {
            guard report?.image == nil else {
                cached = nil
                return
            }
            cached = await TVPreviewCache.shared.image(for: channel.id)
        }
    }
}

/// 信号详情：放大截帧 + 完整参数 + 线路说明，动作只保留能真正执行的几项。
struct TVSignalDetailView: View {
    @Environment(IPTVBrowserModel.self) private var tv
    @Environment(\.dismiss) private var dismiss

    let channel: TVChannel
    let report: TVProbeReport?
    let state: TVProbeState
    let playlistName: String
    let onPlay: () -> Void
    let onProbe: () -> Void
    let onToggleFavorite: () -> Void
    let isFavorite: Bool

    @State private var copied = false

    private var number: Int { tv.channelNumber(for: channel) }

    private var statusText: String {
        if let report {
            return report.isSuccess ? "正常" : "异常"
        }
        switch state {
        case .probing: return "抓帧中"
        case .available: return "正常"
        case .unavailable: return "异常"
        case .idle: return "未探测"
        }
    }

    private var statusColor: Color {
        switch state {
        case .available: return TVBrand.success
        case .unavailable: return TVBrand.danger
        case .probing: return TVBrand.wave
        case .idle: return Color.secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 16) {
                TVSignalThumb(channel: channel, report: report, state: state)
                    .frame(width: 300)
                parameters
            }
            lineSection
            actions
        }
        .padding(18)
        .frame(width: 640)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", number))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(TVBrand.wave)
            Text(channel.name)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(statusColor.opacity(0.10), in: Capsule(style: .continuous))
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(TVBrand.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("分辨率", report?.resolutionText ?? "—")
            detailRow("码率", report?.bitrateText ?? "—")
            detailRow("首帧延迟", report?.latencyText ?? "—")
            detailRow("协议", channel.isHLS ? "HLS" : "HTTP")
            detailRow("画质标记", channel.qualityLabel ?? "—")
            detailRow("候选线路", "\(channel.lineCount) 条")
            detailRow("来源", playlistName)
            if let updated = report?.updatedAt {
                detailRow("最近探测", updated.formatted(date: .omitted, time: .standard))
            }
            detailRow("24h 可用率", availabilityText)
            if !tv.probePoints(for: channel.id).isEmpty {
                TVAvailabilityBar(points: tv.probePoints(for: channel.id))
                    .frame(height: 14)
            }
            if let error = report?.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(TVBrand.danger)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var availabilityText: String {
        guard let ratio = tv.availability(for: channel.id) else { return "—" }
        let count = tv.probePoints(for: channel.id).count
        return "\(Int((ratio * 100).rounded()))% · \(count) 次"
    }

    private var lineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("线路")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(channel.streamLines.count) 条候选")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(channel.streamLines.enumerated()), id: \.offset) { index, url in
                lineRow(index: index, url: url)
            }
            Text("锁定默认线路后，打开频道优先走这条；失败会自动顺延，全部失败才展示错误卡片。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(TVBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(TVBrand.stroke, lineWidth: 0.7))
    }

    private func lineRow(index: Int, url: String) -> some View {
        let isPreferred = tv.preferredLines[channel.id] == url
        let isCurrent = channel.streamURL == url
        return HStack(spacing: 8) {
            Text("线路 \(index + 1)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isCurrent ? TVBrand.wave : Color.secondary)
                .frame(width: 44, alignment: .leading)
            Text(lineHost(url))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isPreferred {
                Text("默认")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(TVBrand.onGold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(TVBrand.gold, in: Capsule(style: .continuous))
            } else if index == 0 {
                Text("最佳")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
            }
            Button(isPreferred ? "恢复自动" : "设为默认") {
                tv.setPreferredLine(isPreferred ? nil : url, for: channel)
            }
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isCurrent ? TVBrand.wave.opacity(0.08) : Color.clear)
        }
    }

    private func lineHost(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        return host + (parsed.path.isEmpty ? "" : parsed.path)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("播放", action: onPlay)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            Button("重新探测", action: onProbe)
                .controlSize(.regular)
            Button(isFavorite ? "取消收藏" : "收藏频道", action: onToggleFavorite)
                .controlSize(.regular)
            Button(copied ? "已复制" : "复制流地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.streamURL, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
            .controlSize(.regular)
            Spacer(minLength: 0)
            Text("截帧与参数来自最近一次探测，不做占位画面")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }
}

/// 24 小时可用率小柱：成功为绿、失败为红，按时间从左到右排列。
struct TVAvailabilityBar: View {
    let points: [TVProbePoint]

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, points.count)
            let barWidth = max(1.5, (proxy.size.width - CGFloat(count)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(point.success ? TVBrand.success.opacity(0.78)
                                            : TVBrand.danger.opacity(0.72))
                        .frame(width: barWidth,
                               height: point.success ? proxy.size.height
                                                     : proxy.size.height * 0.42)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
