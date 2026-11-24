import SwiftUI

/// 五个可以独立开关的产品模块。
///
/// 开关属于「能力层」：关闭后侧边栏入口隐藏、全局搜索不再返回该模块的结果，
/// 但已经保存的数据不会被删除，重新打开就能回来。图库是一切内容的基础，始终开启。
///
/// 口径（1.2.1 收敛）：`cinema` 只代表「网络影院」——聚合网络影视源（苹果 CMS 系）的入口。
/// 本地磁盘 / 网盘里的影片（影院货架、AI 刮削）不属于独立模块，随「图库」与「网络存储」一起出现；
/// 因此影院模块的开关不会影响网络存储里的影片浏览与播放。
enum AppModule: String, CaseIterable, Identifiable {
    case library
    case cloud
    case catalog
    case television
    case cinema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "图库"
        case .cloud: return "网络存储"
        case .catalog: return "网络资源"
        case .television: return "网络电视"
        case .cinema: return "网络影院"
        }
    }

    /// 卡片上的一行关键词，扫一眼就知道这个模块负责什么。
    var tagline: String {
        switch self {
        case .library: return "照片 · 视频 · 相簿 · 人物"
        case .cloud: return "网盘与 NAS 直读"
        case .catalog: return "站点聚合 · 海报墙"
        case .television: return "直播 · 节目单 · 回看"
        case .cinema: return "影视源 · 追剧"
        }
    }

    /// 关闭后会发生什么：设置页里作为辅助说明。
    var detail: String {
        switch self {
        case .library: return "所有内容的基础模块，始终开启。"
        case .cloud: return "隐藏侧边栏入口，网盘文件不再出现在搜索结果里。"
        case .catalog: return "隐藏资源站点入口，资源条目不再出现在搜索结果里。"
        case .television: return "隐藏频道入口并停止拉流，频道不再出现在搜索结果里。"
        case .cinema: return "隐藏网络影院入口；影视源本身由「网络资源」管理，网盘里的影片不受影响。"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "photo.on.rectangle.angled"
        case .cloud: return "externaldrive.connected.to.line.below"
        case .catalog: return "square.stack.3d.up.fill"
        case .television: return "tv"
        case .cinema: return "film.stack"
        }
    }

    /// 卡片图标的两档渐变色。
    var tints: [Color] {
        switch self {
        case .library: return [LumaBrand.violet, LumaBrand.cyan]
        case .cloud: return [LumaBrand.cyan, LumaBrand.mint]
        case .catalog: return [LumaBrand.mint, LumaBrand.violet]
        case .television: return [Color(red: 1.00, green: 0.72, blue: 0.30), LumaBrand.coral]
        case .cinema: return [LumaBrand.coral, LumaBrand.violet]
        }
    }

    /// 基础模块不允许关闭：关掉之后没有内容可看。
    var isLocked: Bool { self == .library }

    var storageKey: String {
        switch self {
        case .library: return SettingsKeys.moduleLibraries
        case .cloud: return SettingsKeys.moduleCloud
        case .catalog: return SettingsKeys.moduleCatalog
        case .television: return SettingsKeys.showTelevision
        case .cinema: return SettingsKeys.moduleCinema
        }
    }

    /// 这个模块对应的全局搜索来源：关闭后来源胶囊与结果一起消失。
    /// 网络影院用独立的「网络影院」来源，网络资源只代表站点聚合出来的资源条目。
    var searchSource: SearchSourceKind {
        switch self {
        case .library: return .library
        case .cloud: return .cloud
        case .catalog: return .catalog
        case .television: return .television
        case .cinema: return .networkCinema
        }
    }
}

/// 模块开关的读写入口：视图用 `@AppStorage` 获得实时刷新，
/// 搜索与启动恢复这类「取一次」的地方直接用这里的静态方法。
enum AppModules {
    static func isEnabled(_ module: AppModule) -> Bool {
        guard !module.isLocked else { return true }
        return UserDefaults.standard.object(forKey: module.storageKey) as? Bool ?? true
    }

    static func isEnabled(_ source: SearchSourceKind) -> Bool {
        switch source {
        case .catalog:
            return isEnabled(AppModule.catalog)
        case .networkCinema:
            return isEnabled(AppModule.cinema)
        default:
            return isEnabled(module(for: source))
        }
    }

    static func module(for source: SearchSourceKind) -> AppModule {
        AppModule.allCases.first { $0.searchSource == source } ?? .library
    }

    /// 全局搜索允许出现的来源：模块关闭后连来源胶囊都不再显示。
    static var enabledSearchScopes: [SearchSourceKind] {
        SearchSourceKind.allCases.filter { isEnabled($0) }
    }
}

// MARK: - 五宫格开关

/// 五宫格模块开关：设置页与建库引导共用同一套卡片，只调整密度。
struct ModuleSwitchGrid: View {
    enum Density {
        /// 设置页：图标 + 标题 + 关键词 + 说明。
        case settings
        /// 建库引导：更紧凑，两行放得下。
        case setup
    }

    var density: Density = .settings
    /// 建库引导里额外的「全选 / 全不选」，默认不显示。
    var showsBulkActions = false

    /// 悬停说明单独占一行固定高度：卡片高度始终一致，不会因为说明展开而顶动整块布局。
    @State private var hintModule: AppModule?

    @AppStorage(SettingsKeys.moduleLibraries) private var libraries = true
    @AppStorage(SettingsKeys.moduleCloud) private var cloud = true
    @AppStorage(SettingsKeys.moduleCatalog) private var catalog = true
    @AppStorage(SettingsKeys.showTelevision) private var television = true
    @AppStorage(SettingsKeys.moduleCinema) private var cinema = true

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: density == .settings ? 150 : 132), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsBulkActions {
                HStack(spacing: 10) {
                    Text("默认全部开启，按需要去掉不用的")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Button("全选") { setAll(true) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                    Button("全不选") { setAll(false) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(AppModule.allCases) { module in
                    ModuleSwitchCard(module: module,
                                     isOn: binding(for: module),
                                     density: density) { hovering in
                        guard density == .settings else { return }
                        // 相邻卡片先后触发的 hover 事件交错时，只清掉自己那条说明。
                        hintModule = hovering ? module : (hintModule == module ? nil : hintModule)
                    }
                }
            }

            if density == .settings {
                Text(hintModule?.detail ?? "关闭只隐藏入口与搜索结果，已经存下的数据仍然保留。")
                    .font(.system(size: 10))
                    .foregroundStyle(hintModule == nil ? Color.secondary.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: hintModule)
            }
        }
    }

    private func binding(for module: AppModule) -> Binding<Bool> {
        switch module {
        case .library: return $libraries
        case .cloud: return $cloud
        case .catalog: return $catalog
        case .television: return $television
        case .cinema: return $cinema
        }
    }

    private func setAll(_ value: Bool) {
        libraries = true          // 基础模块保持开启
        cloud = value
        catalog = value
        television = value
        cinema = value
    }
}

/// 单个模块卡片：彩色图标 + 名称 + 关键词 + 开关；关闭时整卡降饱和。
/// 卡片高度只由图标与两行文字决定，悬停说明交给外面的固定说明行，避免整块布局跳动。
private struct ModuleSwitchCard: View {
    let module: AppModule
    @Binding var isOn: Bool
    let density: ModuleSwitchGrid.Density
    var onHover: ((Bool) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    private var isDark: Bool { scheme == .dark }
    private var isSetup: Bool { density == .setup }
    private var active: Bool { module.isLocked || isOn }

    var body: some View {
        VStack(alignment: .leading, spacing: isSetup ? 6 : 8) {
            HStack(alignment: .top, spacing: 6) {
                iconTile
                Spacer(minLength: 0)
                control
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(module.title)
                    .font(.system(size: isSetup ? 11.5 : 12.5, weight: .semibold))
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.55))
                    .lineLimit(1)
                Text(module.tagline)
                    .font(.system(size: isSetup ? 9.5 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isSetup ? 9 : 10)
        .padding(.vertical, isSetup ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(active ? (isDark ? 0.07 : 0.045) : 0.028))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active
                              ? AnyShapeStyle(LinearGradient(colors: module.tints.map { $0.opacity(isDark ? 0.55 : 0.42) },
                                                             startPoint: .topLeading,
                                                             endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.primary.opacity(0.07)),
                              lineWidth: active ? 1 : 0.6)
        }
        .opacity(active ? 1 : 0.72)
        .scaleEffect(hovered ? 1.008 : 1)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.18), value: isOn)
        .onHover { hovering in
            guard density == .settings else { return }
            hovered = hovering
            onHover?(hovering)
        }
        .help(module.detail)
        .accessibilityElement(children: .combine)
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: module.tints,
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .frame(width: isSetup ? 22 : 26, height: isSetup ? 22 : 26)
            .overlay {
                Image(systemName: module.symbol)
                    .font(.system(size: isSetup ? 10.5 : 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
            }
            .saturation(active ? 1 : 0.1)
            .shadow(color: active ? module.tints[0].opacity(0.28) : .clear, radius: 5, y: 2)
    }

    @ViewBuilder
    private var control: some View {
        if module.isLocked {
            Text("常开")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
        } else {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(module.title)
        }
    }
}
