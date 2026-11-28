import AppKit
import SwiftUI
import LumaDomain

/// 会员视频占位：站点不向游客下发播放地址时，详情页仍然保留「视频」版面，
/// 用封面 + 会员提示说明原因，并给出在浏览器打开的入口。
struct CatalogVideoLockedSection: View {
    let detail: CatalogDetail
    var source: CatalogSource?

    /// 各站点给的说法不同（VIP 专享 / 暢遊會員），详情 facts 里有就沿用。
    private var badge: String {
        detail.facts.first { $0.label == "视频" }?.value ?? "会员专享"
    }

    private var link: URL? {
        guard let source else { return nil }
        let base = source.baseURL.hasSuffix("/") ? String(source.baseURL.dropLast()) : source.baseURL
        return URL(string: "\(base)/thread-\(detail.item.id)-1-1.html")
            ?? URL(string: source.baseURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("视频")
                    .font(.system(size: 15, weight: .semibold))
                Text(badge)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let link {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("在浏览器打开")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.10),
                                    in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            ZStack {
                if let source {
                    CatalogArtworkImage(source: source,
                                        urlString: detail.item.coverURL,
                                        cornerRadius: 14,
                                        fit: true,
                                        quality: .full,
                                        placeholderSymbol: "play.rectangle")
                }
                LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(spacing: 8) {
                    Image(systemName: "play.slash.fill")
                        .font(.system(size: 24, weight: .semibold))
                    Text("需要站点会员才能播放")
                        .font(.system(size: 13, weight: .semibold))
                    Text("当前只能看到封面；登录会员后重新解析，或到站点观看。")
                        .font(.system(size: 10.5))
                        .opacity(0.78)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(16)
            }
            .frame(maxWidth: 560)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
        .padding(.horizontal, 26)
    }
}
