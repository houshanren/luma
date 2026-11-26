import SwiftUI
import AppKit
import Foundation
import LumaContentCore

// MARK: - 通用组件

/// 页头：与网络资源各分页保持同一套字号与留白。
struct CloudHubPageHeader: View {
    let title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 27, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 磨砂面板：统一内边距与圆角，五个分页共用。
struct CloudHubPanel<Content: View>: View {
    var spacing: CGFloat
    var content: Content

    init(spacing: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaGlassCard(cornerRadius: 20)
    }
}

/// 读数块：图标 + 标题 + 大号读数 + 说明。
struct CloudHubStatPod: View {
    let title: String
    let value: String
    var unit: String? = nil
    var detail: String? = nil
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 0.7)
        }
    }
}

/// 小胶囊标签：状态、类型与数量。
struct CloudHubTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
            }
    }
}

/// 胶囊动作按钮：普通态用淡色底，主操作直接铺强调色。
struct CloudHubCapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .accentColor
    var prominent = false
    let action: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                Capsule(style: .continuous)
                    .fill(prominent
                          ? AnyShapeStyle(tint)
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(prominent ? Color.white.opacity(0.20) : tint.opacity(0.22),
                                  lineWidth: 0.7)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 品牌标识：官方网盘用产品图标，其余用协议渐变 + 系统符号。
struct CloudMountBadge: View {
    let mount: CloudMount
    var size: CGFloat = 38

    var tint: Color { mount.kind.hubTint }

    var body: some View {
        Group {
            if let brand = mount.kind.brand {
                CloudBrandIcon(brand: brand, size: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: mount.kind.symbolName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                }
            }
        }
        .shadow(color: tint.opacity(0.26), radius: 7, y: 3)
    }
}

/// 远端海报：复用影院的内存缓存，不在总览里另起一套下载。
struct CloudHubArtwork: View {
    let urlString: String?
    var cornerRadius: CGFloat = 8
    @State var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
        }
        .task(id: urlString) {
            guard let urlString else { image = nil; return }
            image = await CinemaArtworkCache.shared.image(for: urlString)
        }
    }
}

/// 体量条：索引分布与播放进度共用，宽度按比例铺满。
struct CloudHubVolumeBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// 播放进度条：比体量条更细，带一点内高光。
struct CloudHubProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                    .overlay {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: 1)
                            .padding(.horizontal, 3)
                    }
            }
        }
        .frame(height: height)
    }
}

// MARK: - 格式化

enum CloudHubFormat {
    /// 相对时间：总览里只关心「刚刚 / N 分钟前 / N 天前」，超过一个月回到月份。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        DateText.relativeMoment(date, now: now)
    }

    /// 剩余时长：按小时 / 分钟粗粒度展示，避免出现「还剩 4872 秒」。
    static func remaining(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "还剩 \(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "还剩 \(minutes) 分钟" }
        return "还剩不到 1 分钟"
    }

    /// 总时长：续播页的「剩余时长」读数。
    static func hours(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours >= 1 { return String(format: "%.1f", hours) }
        return "\(max(0, Int((seconds / 60).rounded())))"
    }
}

// MARK: - 协议配色

extension CloudKind {
    /// 总览分页里的协议配色：与侧边栏、卡片保持同一套色相。
    var hubTint: Color {
        switch self {
        case .webdav: return Color(red: 0.32, green: 0.74, blue: 0.82)
        case .smb: return Color(red: 0.52, green: 0.58, blue: 0.96)
        case .aliyun: return Color(red: 1.00, green: 0.60, blue: 0.30)
        case .baidu: return Color(red: 0.26, green: 0.54, blue: 0.98)
        case .quark: return Color(red: 0.44, green: 0.50, blue: 1.00)
        case .pan115: return Color(red: 0.18, green: 0.56, blue: 0.96)
        }
    }
}
