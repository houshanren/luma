import SwiftUI
import AppKit

/// 起播阶段：只用来告诉用户「现在卡在哪一步」，不作为业务状态。
enum VideoWaitingStage: Equatable {
    case preparing
    case resolving
    case probing
    case starting
    case connecting

    var label: String {
        switch self {
        case .preparing: return "正在准备"
        case .resolving: return "正在解析播放地址"
        case .probing: return "正在探测片源"
        case .starting: return "正在建立首段"
        case .connecting: return "正在连接频道"
        }
    }
}

/// 等待层展示所需的全部信息，由播放器按来源计算好再传进来。
struct VideoWaitingInfo {
    var title: String
    var subtitle: String?
    var stage: VideoWaitingStage
    var badges: [String]
    /// 起播底图：本地真实帧或海报，没有时退回品牌渐变。
    var image: NSImage?
}

/// 起播等待层：信息优先。
/// - 有底图就按「适应屏幕」完整呈现，比例与正片画面一致，不裁切、不放大铺满；
/// - 没有底图时用品牌渐变 + 片名 + 阶段进度 + 技术徽标兜底。
struct VideoWaitingLayer: View {
    let info: VideoWaitingInfo

    var body: some View {
        ZStack {
            animatedGradient

            if let image = info.image {
                // 等比缩放到画面内：和播放器的 resizeAspect 口径一致，整图可见。
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)

                // 底部渐隐：亮画面上标题与阶段文字依然读得清。
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 5) {
                    Text(info.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if let subtitle = info.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    stageRow
                    if !info.badges.isEmpty { badgesRow }
                }
                .padding(26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                VStack(spacing: 14) {
                    VStack(spacing: 5) {
                        Text(info.title)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        if let subtitle = info.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    stageRow
                    if !info.badges.isEmpty { badgesRow }
                }
                .padding(.horizontal, 40)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// 零素材的兜底：暗色底 + 缓慢漂移的品牌色光晕，比一张糊图体面。
    private var animatedGradient: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Color(white: 0.05)
                RadialGradient(colors: [LumaBrand.cyan.opacity(0.15), .clear],
                               center: UnitPoint(x: 0.5 + 0.22 * sin(t / 7),
                                                 y: 0.42 + 0.16 * cos(t / 9)),
                               startRadius: 0,
                               endRadius: 640)
                RadialGradient(colors: [Color.accentColor.opacity(0.13), .clear],
                               center: UnitPoint(x: 0.5 - 0.20 * cos(t / 8),
                                                 y: 0.58 + 0.14 * sin(t / 11)),
                               startRadius: 0,
                               endRadius: 700)
            }
        }
    }

    private var stageRow: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.85))
            Text(info.stage.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var badgesRow: some View {
        HStack(spacing: 6) {
            ForEach(info.badges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
        }
    }
}
