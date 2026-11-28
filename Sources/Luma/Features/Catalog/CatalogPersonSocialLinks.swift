import AppKit
import SwiftUI

/// 人物资料的「社媒检索」入口。
///
/// 星图资料库里只有出生、身高、三围、简介这些字段，没有各平台的账号。
/// 这里不编造账号：按资料库标准名（以及别名）打开平台的公开搜索，
/// 装了对应客户端就优先走 App 深链，没装就回退到网页版。
enum CatalogSocialPlatform: String, CaseIterable, Identifiable {
    case weibo
    case douyin
    case xiaohongshu
    case bilibili

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weibo: return "微博"
        case .douyin: return "抖音"
        case .xiaohongshu: return "小红书"
        case .bilibili: return "B站"
        }
    }

    var symbol: String {
        switch self {
        case .weibo: return "bubble.left.and.bubble.right.fill"
        case .douyin: return "music.note"
        case .xiaohongshu: return "book.closed.fill"
        case .bilibili: return "play.rectangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .weibo: return Color(red: 0.93, green: 0.24, blue: 0.27)
        case .douyin: return Color(red: 0.98, green: 0.36, blue: 0.60)
        case .xiaohongshu: return Color(red: 1.00, green: 0.18, blue: 0.26)
        case .bilibili: return Color(red: 0.00, green: 0.63, blue: 0.84)
        }
    }

    private func encoded(_ query: String) -> String {
        query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
    }

    /// 客户端深链；未安装时 `urlForApplication` 判不出来，直接回退网页。
    func appURL(query: String) -> URL? {
        let q = encoded(query)
        switch self {
        case .weibo:
            return URL(string: "weibo://searchall?containerid=100103type%3D1%26q%3D\(q)")
        case .douyin:
            return URL(string: "snssdk1128://search?keyword=\(q)")
        case .xiaohongshu:
            return URL(string: "xhsdiscover://search/result?keyword=\(q)")
        case .bilibili:
            return URL(string: "bilibili://search?keyword=\(q)")
        }
    }

    func webURL(query: String) -> URL? {
        let q = encoded(query)
        switch self {
        case .weibo:
            return URL(string: "https://s.weibo.com/weibo?q=\(q)")
        case .douyin:
            return URL(string: "https://www.douyin.com/search/\(q)")
        case .xiaohongshu:
            return URL(string: "https://www.xiaohongshu.com/search_result?keyword=\(q)")
        case .bilibili:
            return URL(string: "https://search.bilibili.com/all?keyword=\(q)")
        }
    }

    func open(query: String) {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let app = appURL(query: name),
           NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
            return
        }
        if let web = webURL(query: name) {
            NSWorkspace.shared.open(web)
        }
    }
}

/// 完整档案页里的社媒检索条：可点击跳转，也可一键复制名字去别处粘。
struct CatalogPersonSocialStrip: View {
    let name: String
    var aliases: [String] = []

    @State private var copied = false

    private var searchTerms: [String] {
        var terms: [String] = []
        for term in [name] + aliases {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { continue }
            terms.append(trimmed)
        }
        return terms
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LumaBrand.violet)
                Text("社媒主页")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.8))
                Text("按名字搜公开主页")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                copyButton
            }

            HStack(spacing: 8) {
                ForEach(CatalogSocialPlatform.allCases) { platform in
                    CatalogSocialChip(platform: platform,
                                      term: searchTerms.first ?? name,
                                      terms: searchTerms)
                }
            }
            Text("检索的是平台公开搜索结果，不一定是本人账号。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var copyButton: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(name, forType: .string)
            withAnimation(.easeOut(duration: 0.16)) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                Text(copied ? "已复制" : "复制名字")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(copied ? LumaBrand.mint : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("复制「\(name)」，方便粘到任意平台搜索")
    }
}

/// 可点击的平台胶囊：悬停时提亮描边，右键可按别名重新搜。
private struct CatalogSocialChip: View {
    let platform: CatalogSocialPlatform
    let term: String
    let terms: [String]

    @State private var hovering = false

    var body: some View {
        Button {
            platform.open(query: term)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: platform.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(platform.tint)
                    .frame(width: 20, height: 20)
                    .background(platform.tint.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(platform.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.86))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(platform.tint.opacity(hovering ? 0.95 : 0.45))
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(platform.tint.opacity(hovering ? 0.13 : 0.07),
                        in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(platform.tint.opacity(hovering ? 0.42 : 0.18), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .help("在\(platform.title)搜索「\(term)」")
        .contextMenu {
            ForEach(terms, id: \.self) { keyword in
                Button("按「\(keyword)」搜\(platform.title)") {
                    platform.open(query: keyword)
                }
            }
        }
    }
}

/// 悬停档案卡里的社媒提示：那张卡本身不接收点击（避免吞掉筛选点击），
/// 所以这里只做展示，真正的跳转在完整档案页。
struct CatalogPersonSocialHints: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(CatalogSocialPlatform.allCases) { platform in
                HStack(spacing: 3) {
                    Image(systemName: platform.symbol)
                        .font(.system(size: 7.5, weight: .bold))
                    Text(platform.title)
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(platform.tint.opacity(0.95))
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(platform.tint.opacity(0.13), in: Capsule(style: .continuous))
            }
            Text("按名字去搜")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.34))
        }
        .help("打开完整档案后，可按名字直接去\(CatalogSocialPlatform.allCases.map(\.title).joined(separator: " / "))搜索「\(name)」")
    }
}
