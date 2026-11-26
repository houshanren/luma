import SwiftUI
import AppKit
import LumaContentCore

/// 频道卡片：只观察自身快照，其它频道探测或节目更新时不重绘整张卡片。
struct TVChannelTile: View, Equatable {
    let store: LibraryStore
    let tv: IPTVBrowserModel
    let channel: TVChannel
    let number: Int
    let isPlaying: Bool
    let probeState: TVProbeState
    let isFavorite: Bool
    let currentProgram: TVEPGProgram?
    let showsEPGLoading: Bool
    let sourceName: String

    init(store: LibraryStore, tv: IPTVBrowserModel, channel: TVChannel, number: Int, isPlaying: Bool) {
        self.store = store
        self.tv = tv
        self.channel = channel
        self.number = number
        self.isPlaying = isPlaying
        probeState = tv.probeState(for: channel.id)
        isFavorite = tv.isFavorite(channel)
        let current = tv.currentProgram(for: channel)
        currentProgram = current
        showsEPGLoading = current == nil && tv.isLoadingEPG
        sourceName = tv.playlistName(for: channel.playlistID)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.tv === rhs.tv && lhs.channel == rhs.channel
            && lhs.number == rhs.number && lhs.isPlaying == rhs.isPlaying
            && lhs.probeState == rhs.probeState && lhs.isFavorite == rhs.isFavorite
            && lhs.currentProgram == rhs.currentProgram && lhs.showsEPGLoading == rhs.showsEPGLoading
            && lhs.sourceName == rhs.sourceName
    }

    @State private var hovered = false
    @State private var preview: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 开启「减少动态效果」时不做悬停放大 / 浮起。
    private var lift: Bool { hovered && !reduceMotion }

    var body: some View {
        Button { store.openTVChannel(channel) } label: {
            VStack(spacing: 0) {
                panel
                footer
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovered ? TVBrand.surfaceHover : TVBrand.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .shadow(color: (hovered || isPlaying) && !reduceMotion ? TVBrand.wave.opacity(0.22) : TVBrand.shadow,
                    radius: (hovered || isPlaying) && !reduceMotion ? 14 : 8,
                    y: (hovered || isPlaying) && !reduceMotion ? 6 : 4)
            .scaleEffect(lift ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(probeState == .unavailable ? 0.74 : 1)
        .onHover { value in
            withAnimation(.easeOut(duration: 0.16)) { hovered = value }
        }
        .contextMenu {
            Button(isPlaying ? "重新打开" : "播放") { store.openTVChannel(channel) }
            Button(isFavorite ? "取消收藏" : "收藏") { tv.toggleFavorite(channel) }
            Button("重试取帧") { tv.retryPreview(for: channel) }
        }
        .help("\(channel.name) · \(sourceName)")
        .task(id: channel.id) {
            await tv.requestPreview(for: channel)
        }
        .task(id: previewKey) {
            guard probeState == .available else { return }
            if let image = await TVPreviewCache.shared.image(for: channel.id) {
                withAnimation(.easeOut(duration: 0.2)) { preview = image }
            }
        }
    }

    private var previewKey: String { "\(channel.id)#\(probeState.rawValue)" }

    private var borderColor: Color {
        if isPlaying { return TVBrand.wave }
        if probeState == .unavailable { return TVBrand.signal.opacity(hovered ? 0.85 : 0.55) }
        if hovered { return TVBrand.wave.opacity(0.55) }
        return TVBrand.stroke
    }

    private var borderWidth: CGFloat {
        if isPlaying { return 1.4 }
        if probeState == .unavailable { return 1.2 }
        return hovered ? 1 : 0.7
    }

    private var panel: some View {
        ZStack {
            LinearGradient(colors: [TVBrand.cardTop, TVBrand.cardBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let preview {
                // 抓到的实时画面铺满面板，台标缩成左下角小徽标。
                Color.clear
                    .overlay {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.42), .clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                RadialGradient(colors: [TVBrand.wave.opacity(hovered ? 0.20 : 0.10), .clear],
                               center: .top, startRadius: 4, endRadius: 220)
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 130, height: 62))
                    .shadow(color: TVBrand.logoShadow, radius: 6, y: 2)
                    .scaleEffect(hovered ? 1.03 : 1)
            }

            VStack {
                HStack(alignment: .top) {
                    TVLiveBadge()
                    Spacer(minLength: 0)
                    if isFavorite || hovered {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isFavorite ? TVBrand.gold : Color.white.opacity(0.75))
                            .shadow(color: TVBrand.gold.opacity(0.5), radius: 4)
                    }
                    if let quality = channel.qualityLabel {
                        qualityPill(quality)
                    }
                    probeBadge
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    if preview != nil {
                        TVLogoImage(urlString: channel.logoURL,
                                    size: CGSize(width: 56, height: 22))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(TVBrand.previewScrim,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Spacer(minLength: 0)
                    ZStack {
                        Circle()
                            .fill(TVBrand.wave)
                            .frame(width: 30, height: 30)
                            .shadow(color: TVBrand.wave.opacity(0.5), radius: 8)
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TVBrand.onWave)
                    }
                    .opacity(hovered || isPlaying ? 1 : 0)
                    .scaleEffect(hovered || isPlaying ? 1 : 0.85)
                }
            }
            .padding(9)

            // 不可播放时在画面正中直接给出结论，不用点开才知道。
            if probeState == .unavailable {
                Color.black.opacity(0.22)
                VStack(spacing: 5) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 19, weight: .semibold))
                    Text("信号不可用")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("点按可尝试其它线路")
                        .font(.system(size: 8.5, weight: .medium))
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.52),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(TVBrand.signal.opacity(0.55), lineWidth: 0.8)
                }
                .shadow(color: TVBrand.signal.opacity(0.35), radius: 10)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14,
                                          bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0,
                                          topTrailingRadius: 14,
                                          style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVBrand.wave)
                    .frame(minWidth: 22, alignment: .leading)
                Text(channel.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let currentProgram {
                    Text(clock(currentProgram.start))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary.opacity(hovered ? 1 : 0.55))
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                if let currentProgram {
                    Text(currentProgram.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Text("\(clock(currentProgram.start)) – \(clock(currentProgram.end))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                } else {
                    Text(showsEPGLoading ? "正在读取节目单…" : "暂无节目单")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            progressBar
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let currentProgram {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(TVBrand.hairline)
                    Capsule(style: .continuous)
                        .fill(TVBrand.wave)
                        .frame(width: max(0, proxy.size.width * programProgress(currentProgram)))
                }
            }
            .frame(height: 2)
            .padding(.top, 1)
        }
    }

    private var statusColor: Color {
        if isPlaying { return TVBrand.wave }
        switch probeState {
        case .available: return TVBrand.success
        case .probing: return TVBrand.gold
        case .unavailable: return TVBrand.signal
        case .idle: return Color.secondary.opacity(0.5)
        }
    }

    /// 卡片右上角的可播性角标：检测中 / 可播放 / 不可播放，一眼看清。
    @ViewBuilder
    private var probeBadge: some View {
        switch probeState {
        case .available:
            capsuleBadge(text: "可播放",
                         symbol: "checkmark.circle.fill",
                         tint: TVBrand.success)
        case .probing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .frame(width: 9, height: 9)
                Text("检测中")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 6.5)
            .frame(height: 18)
            .background(Color.black.opacity(0.48), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(TVBrand.gold.opacity(0.45), lineWidth: 0.6)
            }
        case .unavailable:
            capsuleBadge(text: "不可播放",
                         symbol: "exclamationmark.triangle.fill",
                         tint: TVBrand.signal,
                         emphasized: true)
        case .idle:
            EmptyView()
        }
    }

    private func capsuleBadge(text: String,
                              symbol: String,
                              tint: Color,
                              emphasized: Bool = false) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(emphasized ? Color.white : tint)
        .padding(.horizontal, 6.5)
        .frame(height: 18)
        .background {
            Capsule(style: .continuous)
                .fill(emphasized ? tint : Color.black.opacity(0.48))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(emphasized ? Color.white.opacity(0.28) : tint.opacity(0.5),
                              lineWidth: 0.6)
        }
        .shadow(color: emphasized ? tint.opacity(0.45) : .clear, radius: 6, y: 1)
    }

    private func programProgress(_ program: TVEPGProgram) -> Double {
        let total = max(1, program.duration)
        return min(max(Date().timeIntervalSince(program.start) / total, 0), 1)
    }

    private func clock(_ date: Date) -> String {
        Self.clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func qualityPill(_ quality: String) -> some View {
        let style = TVBrand.qualityStyle(quality)
        return Text(quality)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(style.fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(style.bg, in: Capsule(style: .continuous))
    }
}
