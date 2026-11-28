import AppKit
import SwiftUI

// MARK: - 视觉工具

enum AtlasLook {
    static func regionColor(_ region: String) -> Color {
        switch region {
        case "china": return Color(red: 0.98, green: 0.46, blue: 0.40)
        case "taiwan": return Color(red: 0.98, green: 0.66, blue: 0.30)
        case "hongkong": return Color(red: 0.42, green: 0.82, blue: 0.62)
        case "korea": return Color(red: 0.95, green: 0.52, blue: 0.72)
        case "western": return Color(red: 0.68, green: 0.56, blue: 0.98)
        default: return Color(red: 0.42, green: 0.72, blue: 0.98)
        }
    }

    static func gradient(seed: Int) -> LinearGradient {
        let palettes: [(Color, Color)] = [
            (Color(red: 0.16, green: 0.20, blue: 0.34), Color(red: 0.36, green: 0.24, blue: 0.46)),
            (Color(red: 0.12, green: 0.24, blue: 0.30), Color(red: 0.18, green: 0.38, blue: 0.42)),
            (Color(red: 0.28, green: 0.18, blue: 0.24), Color(red: 0.42, green: 0.24, blue: 0.30)),
            (Color(red: 0.14, green: 0.22, blue: 0.26), Color(red: 0.26, green: 0.34, blue: 0.30))
        ]
        let pair = palettes[abs(seed) % palettes.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func shortDate(_ text: String?) -> String {
        guard let text, text.count >= 10 else { return text ?? "" }
        return String(text.prefix(10))
    }

    static func compact(_ value: Int) -> String {
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// 玻璃卡片：星图里所有浮层共用。
struct AtlasGlass: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

extension View {
    func atlasGlass(radius: CGFloat = 18, padding: CGFloat = 14) -> some View {
        modifier(AtlasGlass(radius: radius, padding: padding))
    }
}

// MARK: - 远程封面

/// 资料库封面（pics.dmm.co.jp 等）：内存缓存 + 系统 URLCache，失败保留渐变占位。
struct AtlasRemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fill
    var seed: Int = 0

    @State private var image: NSImage?
    @State private var failed = false

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 400
        return cache
    }()

    var body: some View {
        ZStack {
            AtlasLook.gradient(seed: seed)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .opacity(0.5)
            }
        }
        .clipped()
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let urlString, let url = URL(string: urlString), !urlString.isEmpty else {
            failed = true
            return
        }
        let key = urlString as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let decoded = NSImage(data: data) else {
                failed = true
                return
            }
            Self.cache.setObject(decoded, forKey: key, cost: data.count)
            withAnimation(.easeOut(duration: 0.25)) { image = decoded }
        } catch {
            failed = true
        }
    }
}

// MARK: - 分页胶囊

struct AtlasModeBar: View {
    @Binding var mode: AtlasMode
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AtlasMode.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { mode = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(mode == item ? Color.white : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background {
                        if mode == item {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor)
                                .matchedGeometryEffect(id: "atlas-mode", in: namespace)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(item.subtitle)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - 作品卡

struct AtlasWorkCard: View {
    let work: AtlasWork
    var width: CGFloat = 148
    var onOpen: (AtlasWork) -> Void = { _ in }

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onOpen(work)
            } label: {
                AtlasRemoteImage(urlString: work.coverURL ?? work.thumbURL, seed: Int(work.id))
                    .frame(width: width, height: width * 1.42)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if work.trailerURL != nil {
                            Label("试看", systemImage: "play.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(hovering ? 0.28 : 0.10),
                                          lineWidth: hovering ? 1 : 0.6)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.34 : 0.18),
                            radius: hovering ? 16 : 8, y: hovering ? 9 : 4)
                    .scaleEffect(hovering ? 1.035 : 1)
                    .rotation3DEffect(.degrees(hovering ? -5 : 0), axis: (x: 1, y: 0, z: 0))
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            Text(work.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary.opacity(0.92))
                .frame(width: width, alignment: .leading)

            HStack(spacing: 4) {
                Text(work.dvdID)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(AtlasLook.shortDate(work.releaseDate))
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: width)
        }
        .frame(width: width)
    }
}

// MARK: - 人物头像

struct AtlasAvatar: View {
    let person: AtlasPerson
    var size: CGFloat = 40

    var body: some View {
        CatalogAvatarView(name: person.name,
                          base64: CatalogAvatarStore.personBase64(person.id),
                          size: size,
                          ringColor: AtlasLook.regionColor(person.region))
    }
}

// MARK: - 空状态

struct AtlasEmptyState: View {
    let title: String
    let message: String
    var symbol = "sparkles"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 区块标题

/// 各视图统一的区块头：大标题 + 一行说明 + 右侧操作。
struct AtlasSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .serif))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Rectangle()
                .fill(LinearGradient(colors: [Color.primary.opacity(0.14), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            trailing()
        }
    }
}

// MARK: - 作品海报卡

/// 作品集网格用的大海报：悬停浮出番号、分类与试看角标。
struct AtlasPosterCard: View {
    let work: AtlasWork
    var onOpen: (AtlasWork) -> Void = { _ in }

    @State private var hovering = false

    var body: some View {
        Button {
            onOpen(work)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                AtlasRemoteImage(urlString: work.thumbURL ?? work.coverURL, seed: Int(work.id))
                    .aspectRatio(2.0 / 3.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.white.opacity(hovering ? 0.30 : 0.08),
                                          lineWidth: hovering ? 1.1 : 0.6)
                    }
                    .overlay(alignment: .bottom) {
                        if hovering {
                            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                           startPoint: .center, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        if !work.genres.isEmpty {
                                            Text(work.genres.prefix(2).joined(separator: " · "))
                                                .font(.system(size: 8.5))
                                                .foregroundStyle(.white.opacity(0.7))
                                                .lineLimit(1)
                                        }
                                        HStack(spacing: 5) {
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .font(.system(size: 8, weight: .bold))
                                            Text(work.dvdID)
                                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        }
                                        .foregroundStyle(.white)
                                    }
                                    .padding(8)
                                }
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if work.trailerURL != nil {
                            Label("试看", systemImage: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
                    .shadow(color: .black.opacity(hovering ? 0.32 : 0.14),
                            radius: hovering ? 16 : 8, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.015 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)

                Text(work.displayTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary.opacity(0.9))
                HStack(spacing: 5) {
                    Text(work.dvdID)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(AtlasLook.shortDate(work.releaseDate))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(work.title)
    }
}

// MARK: - 在线条目卡

/// 网络资源条目：视频 / 图集用同一张卡，封面来自站点图床（带 Referer 与缓存）。
struct AtlasOnlineCard: View {
    let entry: AtlasOnlineEntry
    var source: CatalogSource?
    var width: CGFloat = 152
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onOpen) {
                ZStack(alignment: .topLeading) {
                    cover
                        .frame(width: width, height: width * 1.3)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(hovering ? 0.3 : 0.08),
                                              lineWidth: hovering ? 1 : 0.6)
                        }
                        .overlay(alignment: .bottomLeading) {
                            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                           startPoint: .center, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Text(entry.sourceName)
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                        .padding(7)
                                }
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: entry.isGallery ? "photo.stack.fill" : "play.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(5)
                                .background(.black.opacity(0.35), in: Circle())
                                .padding(6)
                        }
                        .shadow(color: .black.opacity(hovering ? 0.3 : 0.14),
                                radius: hovering ? 14 : 7, y: hovering ? 7 : 3)
                        .scaleEffect(hovering ? 1.02 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            Text(entry.item.title)
                .font(.system(size: 10))
                .lineLimit(2)
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: width, alignment: .leading)

            HStack(spacing: 5) {
                if let code = entry.code {
                    Text(code)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(entry.isGallery ? "图集" : "视频")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: width)
        }
        .frame(width: width)
        .help(entry.item.title)
    }

    @ViewBuilder
    private var cover: some View {
        if let source, !entry.item.coverURL.isEmpty {
            CatalogArtworkImage(source: source, urlString: entry.item.coverURL,
                                cornerRadius: 10, quality: .thumbnail)
        } else {
            AtlasLook.gradient(seed: entry.item.title.count)
                .overlay {
                    Image(systemName: entry.isGallery ? "photo.stack" : "play.rectangle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                }
        }
    }
}
