import AppKit
import SwiftUI
import LumaContentCore

/// 「衣着 / 身材 / 玩法」这类纯标签分组：每个标签用这一类的**真实内容缩略图**当门面。
///
/// 标签本身没有配图，画图标永远只是近似——「黑絲」「巨乳」用一条腿、一个心形根本不对味。
/// 这里改成取该分类第一页的第一张封面铺成 2:3 小海报：看到的是真东西，
/// 名字压在底部暗角上；同一屏里还能顺手预览这一类长什么样。
struct CatalogTagEmblemPanel: View {
    let groupTitle: String
    let source: CatalogSource?
    let categories: [CatalogCategory]
    let activeID: String?
    let allActive: Bool
    let onShowAll: () -> Void
    let onOpen: (CatalogCategory) -> Void

    @State private var hoveringID: String?

    private var covers: CatalogCategoryCoverStore { .shared }

    /// 只接管这三个语义分组，其余分类仍走普通胶囊。
    static func groupKind(_ title: String?) -> String? {
        guard let title else { return nil }
        if title.contains("衣著") || title.contains("衣着") { return "衣着" }
        if title.contains("身材") { return "身材" }
        if title.contains("玩法") { return "玩法" }
        return nil
    }

    private var kind: CatalogTagEmblemStyle.Kind { .init(groupTitle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            CatalogFlowLayout(spacing: 8, lineSpacing: 12) {
                tile(id: nil,
                     title: "全部",
                     imageURLs: categories.prefix(4).flatMap { coverURLs(for: $0) },
                     active: allActive,
                     action: onShowAll)
                ForEach(categories) { category in
                    tile(id: category.id,
                         title: category.title,
                         imageURLs: coverURLs(for: category),
                         active: activeID == category.id,
                         action: { onOpen(category) })
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
        .task(id: prefetchToken) {
            guard let source else { return }
            covers.prefetch(source: source, categories: categories)
        }
    }

    /// 分组或分类变了才重新补图；同一批分类重复渲染不再发起请求。
    private var prefetchToken: String {
        "\(source?.id.uuidString ?? "-")|\(categories.map(\.id).joined(separator: ","))"
    }

    private func coverURLs(for category: CatalogCategory) -> [String] {
        guard let source,
              let cover = covers.cover(sourceID: source.id, categoryID: category.id) else { return [] }
        return [cover]
    }

    /// 标题行：这一组“在挑什么”，右侧给出标签数。
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(groupTitle)
                .font(.system(size: 11, weight: .semibold))
            Text(kind.tagline)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(categories.count) 种")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// 一个标签 = 一张 2:3 内容小海报；悬停放大、选中描边发光。
    private func tile(id: String?, title: String, imageURLs: [String],
                      active: Bool, action: @escaping () -> Void) -> some View {
        let key = id ?? "__all"
        let hovering = hoveringID == key
        return Button(action: action) {
            poster(title: title, imageURLs: imageURLs)
                .frame(width: 78, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(active ? kind.tint : Color.white.opacity(0.16),
                                      lineWidth: active ? 2.4 : 0.8)
                }
                .overlay(alignment: .topTrailing) {
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(kind.tint, in: Circle())
                            .padding(5)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.16),
                        radius: hovering ? 10 : 5, y: 2)
                .shadow(color: kind.tint.opacity(active ? 0.5 : 0), radius: 10)
                .scaleEffect(hovering && !active ? 1.04 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveringID = key
            } else if hoveringID == key {
                hoveringID = nil
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: active)
        .help(title)
    }

    /// 封面 + 底部暗角 + 名字；没有封面时退回本组配色的渐变，不会出现抽象图标。
    private func poster(title: String, imageURLs: [String]) -> some View {
        ZStack {
            if let source, !imageURLs.isEmpty {
                if imageURLs.count > 1 {
                    collage(imageURLs, source: source)
                } else {
                    CatalogArtworkImage(source: source,
                                        urlString: imageURLs[0],
                                        cornerRadius: 0,
                                        placeholderSymbol: "photo")
                }
            } else {
                LinearGradient(colors: [kind.tint.opacity(0.6), kind.tint.opacity(0.2)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.78)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 54)
                .overlay(alignment: .bottom) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.82)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 6)
                }
                .allowsHitTesting(false)
        }
    }

    /// 「全部」用已有封面拼一张 2×2：一眼看出这是整组的总览。
    private func collage(_ urls: [String], source: CatalogSource) -> some View {
        let shots = (0..<4).map { urls[$0 % urls.count] }
        return VStack(spacing: 1) {
            HStack(spacing: 1) {
                CatalogArtworkImage(source: source, urlString: shots[0], cornerRadius: 0,
                                    placeholderSymbol: "photo")
                CatalogArtworkImage(source: source, urlString: shots[1], cornerRadius: 0,
                                    placeholderSymbol: "photo")
            }
            HStack(spacing: 1) {
                CatalogArtworkImage(source: source, urlString: shots[2], cornerRadius: 0,
                                    placeholderSymbol: "photo")
                CatalogArtworkImage(source: source, urlString: shots[3], cornerRadius: 0,
                                    placeholderSymbol: "photo")
            }
        }
    }
}

/// 分组自己的语义（标题、配色、未出图时的渐变色）。
enum CatalogTagEmblemStyle {
    enum Kind {
        case outfit, figure, play

        init(_ title: String) {
            if title.contains("身材") {
                self = .figure
            } else if title.contains("玩法") {
                self = .play
            } else {
                self = .outfit
            }
        }

        var tint: Color {
            switch self {
            case .outfit: return LumaBrand.pink
            case .figure: return LumaBrand.mint
            case .play: return LumaBrand.coral
            }
        }

        var symbol: String {
            switch self {
            case .outfit: return "tshirt.fill"
            case .figure: return "figure.stand"
            case .play: return "flame.fill"
            }
        }

        var tagline: String {
            switch self {
            case .outfit: return "穿什么"
            case .figure: return "什么型"
            case .play: return "怎么玩"
            }
        }
    }
}
