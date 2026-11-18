import SwiftUI
import AppKit

/// 设置 › 影院：数据源选择、凭据配置、连接测试与批量刮削。
struct CinemaSettingsSection: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var revealKey = false
    @State private var revealCookie = false
    @State private var showAdvanced = false

    private let languages: [(id: String, title: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어")
    ]

    private var tmdbConfigured: Bool {
        !settings.cinemaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                providerPicker
                providerNote
                if settings.cinemaProvider == .tmdb {
                    tmdbConfig
                } else {
                    doubanConfig
                }
                behaviorCard
                footer
            }
            .padding(18)
        }
        .onChange(of: settings.cinemaProvider) { _, _ in
            store.cinemaConnectionResult = nil
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LumaBrand.violet.opacity(0.16))
                Image(systemName: "film.stack")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LumaBrand.violet)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("影院刮削")
                    .font(.system(size: 15, weight: .semibold))
                Text("按文件名匹配电影与剧集，补全海报、评分和简介。所有网盘共用同一套结果。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 数据源

    private var providerPicker: some View {
        HStack(spacing: 10) {
            ForEach(CinemaProvider.allCases) { provider in
                providerCard(provider)
            }
        }
    }

    private func providerCard(_ provider: CinemaProvider) -> some View {
        let selected = settings.cinemaProvider == provider
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { settings.cinemaProvider = provider }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: provider == .tmdb ? "globe.americas.fill" : "text.book.closed.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? LumaBrand.violet : Color.secondary)
                    Text(provider.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    if let badge = provider.badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(selected ? LumaBrand.violet : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(selected
                                                       ? LumaBrand.violet.opacity(0.16)
                                                       : Color.secondary.opacity(0.12)))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? LumaBrand.violet : Color.secondary.opacity(0.35))
                }
                Text(provider.tagline)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? LumaBrand.violet.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? LumaBrand.violet.opacity(0.55) : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 1.2 : 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    private var providerNote: some View {
        Text(settings.cinemaProvider == .tmdb
             ? "TMDB 是官方接口，免费申请，自带背景图，适合绝大多数电影与剧集。国内网络若访问不了，可在下方「高级」里换镜像地址。"
             : "豆瓣没有公开 API，这里读取它的公开网页接口：中文片名、国产剧命中更准，但没有背景图，也可能被限流。遇到失败可填写 Cookie 或换镜像地址。")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: TMDB 配置

    private var tmdbConfig: some View {
        card {
            sectionTitle("TMDB 配置", status: tmdbConfigured ? ("已配置", true) : ("待配置", false))

            HStack(spacing: 6) {
                Group {
                    if revealKey {
                        TextField("API Key（v3）或 Read Access Token（v4）", text: $settings.cinemaAPIKey)
                    } else {
                        SecureField("API Key（v3）或 Read Access Token（v4）", text: $settings.cinemaAPIKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))

                Button(revealKey ? "隐藏" : "显示") { revealKey.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            HStack(spacing: 6) {
                Text("刮削语言")
                    .font(.system(size: 11.5))
                Picker("", selection: $settings.cinemaLanguage) {
                    ForEach(languages, id: \.id) { item in
                        Text(item.title).tag(item.id)
                    }
                }
                .labelsHidden()
                .frame(width: 116)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("打开 TMDB 申请页") {
                    open("https://www.themoviedb.org/settings/api")
                }
                Button("粘贴剪贴板") {
                    paste(into: $settings.cinemaAPIKey)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            Divider().opacity(0.5)

            steps([
                "打开 TMDB 申请页，注册后申请免费 API Key（类型选 Developer）。",
                "复制 API Key（v3）或 Read Access Token（v4），粘贴到上面。",
                "点「测试连接」确认可用，再回影院点「刮削新视频」。"
            ])

            advanced
            testRow
        }
    }

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("接口地址").frame(width: 62, alignment: .leading)
                    TextField("https://api.themoviedb.org/3", text: $settings.cinemaAPIBase)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Text("图片地址").frame(width: 62, alignment: .leading)
                    TextField("https://image.tmdb.org/t/p", text: $settings.cinemaImageBase)
                        .textFieldStyle(.roundedBorder)
                }
                Text("访问不了 TMDB 时，可填自建反代或可用镜像的前缀。")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        } label: {
            Text("高级：接口与图片镜像")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 豆瓣配置

    private var doubanConfig: some View {
        card {
            sectionTitle("豆瓣配置", status: ("免 Key", true))

            HStack(spacing: 6) {
                Text("接口地址")
                    .font(.system(size: 11.5))
                    .frame(width: 62, alignment: .leading)
                TextField("https://movie.douban.com", text: $settings.cinemaDoubanBase)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
            }

            HStack(spacing: 6) {
                Text("Cookie")
                    .font(.system(size: 11.5))
                    .frame(width: 62, alignment: .leading)
                Group {
                    if revealCookie {
                        TextField("可选：浏览器里 movie.douban.com 的 Cookie", text: $settings.cinemaDoubanCookie)
                    } else {
                        SecureField("可选：浏览器里 movie.douban.com 的 Cookie", text: $settings.cinemaDoubanCookie)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                Button(revealCookie ? "隐藏" : "显示") { revealCookie.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            Text("Cookie 只在被限流时填写：登录豆瓣后从浏览器开发者工具复制整段 Cookie 即可。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.5)

            steps([
                "默认直连 movie.douban.com，不需要申请 Key。",
                "点「测试连接」，能搜到「流浪地球」就说明可用。",
                "被限流（403 / 418）时，换镜像地址或填写 Cookie 后重试。"
            ])

            testRow
        }
    }

    // MARK: 行为

    private var behaviorCard: some View {
        card {
            sectionTitle("行为")
            Toggle("扫描完网盘后自动刮削这个网盘的新视频", isOn: $settings.cinemaAutoScrape)
                .font(.system(size: 11.5))
            Text("刮削与播放入口在每个网盘的侧边栏「影院」里；结果和海报只属于那个网盘，互不影响。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("只读取文件名，不会读取或上传视频内容；结果只保存在本机图库。",
                  systemImage: "lock.shield")
            Label("命名越规范越容易命中：电影名.2024.2160p.mkv、剧名.S01E02.1080p.mp4。",
                  systemImage: "textformat")
            Label("换数据源后旧结果不会自动变，点「重新刮削全部」覆盖即可。",
                  systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 组件

    private var testRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.testCinemaConnection() }
            } label: {
                Label("测试连接", systemImage: "bolt.horizontal.circle")
            }
            .controlSize(.small)
            .disabled(store.cinemaConnectionTesting)

            if store.cinemaConnectionTesting {
                ProgressView().controlSize(.small)
                Text("正在连接…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else if let result = store.cinemaConnectionResult {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(result.ok ? Color.green : Color.orange)
                Text(result.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("用示例片名搜一次，确认网络与配置可用")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func sectionTitle(_ title: String, status: (text: String, ok: Bool)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            if let status {
                let color = status.ok ? Color.green : Color.orange
                Text(status.text)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(color.opacity(0.12)))
            }
            Spacer(minLength: 0)
        }
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.secondary.opacity(0.13)))
                    Text(text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func paste(into binding: Binding<String>) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        binding.wrappedValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
