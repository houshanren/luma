import AppKit
import SwiftUI

/// 建库引导：首次启动没有图库时整屏展示；App 内点「新建图库」时复用同一套流程，
/// 以 sheet 形式直接进入「选择能力 → 选择位置并创建」，建好后立刻切到新图库。
/// 视觉与官网首屏对齐：真实 App 图标 + 品牌渐变光晕 + 玻璃卡片。
struct LibrarySetupView: View {
    /// 从「新建图库」入口以 sheet 打开：跳过品牌首屏，底部不再提供「退出拾光」。
    let creatingAdditionalLibrary: Bool

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    /// 迁入旧照片只对首次启动有意义；已有图库时新建的应该是一个空图库。
    @State private var migrateLocalPhotos = false
    /// 第二步：选择这台图库要启用哪些能力（默认全开）。
    @State private var showsModuleStep: Bool
    /// 最近删除保留天数先暂存：此刻图库还没创建，直接写会落到 UserDefaults 而不是新库。
    @State private var setupTrashDays = 30
    /// 建库 / 迁入进行中：按钮置灰，避免重复点击。
    @State private var isCreating = false
    /// 打开向导时的能力开关快照：sheet 里点「取消」要把全局开关还原。
    private let moduleSnapshot: [String: Bool]

    init(creatingAdditionalLibrary: Bool = false) {
        self.creatingAdditionalLibrary = creatingAdditionalLibrary
        _showsModuleStep = State(initialValue: creatingAdditionalLibrary)
        moduleSnapshot = Dictionary(uniqueKeysWithValues: AppModule.allCases.map {
            ($0.storageKey, AppModules.isEnabled($0))
        })
    }

    private var hasLocalPhotos: Bool { !store.photos.isEmpty }
    /// 旧版本地库（没有图库包）残留时也可以选择迁入。
    private var canMigrateLocal: Bool { hasLocalPhotos || LibraryPaths.hasLocalLibraryData }
    private var isDark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            LumaAmbientBackground()
            brandAura

            card
                .padding(creatingAdditionalLibrary ? 28 : 40)
        }
        // 引导里选外观 / 强调色即时预览整屏：点一下就能看到换肤效果。
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .animation(.easeOut(duration: 0.18), value: settings.appearance)
        .onAppear {
            // 首次启动：默认把旧版本地照片迁入新图库。
            // 从「新建图库」进来时保持不勾选——新建的应该是一个空图库。
            if !creatingAdditionalLibrary {
                migrateLocalPhotos = canMigrateLocal
            }
        }
    }

    // MARK: - 品牌光晕

    /// 官网首屏同款极光：紫 / 珊瑚 / 青三团低饱和光斑，只负责氛围。
    private var brandAura: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Circle()
                    .fill(LumaBrand.violet.opacity(isDark ? 0.20 : 0.10))
                    .frame(width: max(320, width * 0.62))
                    .blur(radius: 110)
                    .offset(x: width * 0.24, y: -height * 0.26)

                Circle()
                    .fill(LumaBrand.coral.opacity(isDark ? 0.15 : 0.08))
                    .frame(width: max(280, width * 0.52))
                    .blur(radius: 100)
                    .offset(x: -width * 0.26, y: height * 0.20)

                Circle()
                    .fill(LumaBrand.cyan.opacity(isDark ? 0.12 : 0.07))
                    .frame(width: max(240, width * 0.44))
                    .blur(radius: 100)
                    .offset(x: width * 0.04, y: height * 0.40)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(spacing: 0) {
            if showsModuleStep {
                moduleStep
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            } else {
                introStep
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .opacity))
            }

            // sheet 里创建的是另一个图库，不该再出现「退出拾光」这类首次启动的东西。
            if !creatingAdditionalLibrary {
                footer
                    .padding(.top, showsModuleStep ? 16 : 22)
            }
        }
        .padding(.horizontal, showsModuleStep ? 32 : 44)
        .padding(.vertical, showsModuleStep ? 26 : 34)
        .frame(width: showsModuleStep ? 560 : 500)
        .lumaGlassCard(cornerRadius: 32)
        .animation(.snappy(duration: 0.28), value: showsModuleStep)
    }

    /// 第一步：品牌 + 说明 + 两个入口。
    private var introStep: some View {
        VStack(spacing: 0) {
            logoLockup
                .padding(.bottom, 14)

            eyebrowChip
                .padding(.bottom, 18)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("拾光")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.02)
                Text("Luma")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .tracking(0.01)
                    .foregroundStyle(LumaBrand.textGradient(dark: isDark))
            }

            Text("十年光影，一眼看见。")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(spacing: 7) {
                Text("先创建一个图库，或打开已有图库。")
                    .font(.system(size: 13.5, weight: .medium))
                Text("照片、视频与编辑记录都保存在你选择的 .photoslibrary 图库里，\n可以放在任意文件夹或外置磁盘。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.top, 14)

            capabilities
                .padding(.top, 16)

            actions
                .padding(.top, 20)
        }
    }

    /// 第二步：五宫格能力候选，默认全开，可逐个取消。
    private var moduleStep: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.bottom, 12)

            HStack(alignment: .center, spacing: 11) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LumaBrand.gradient)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: LumaBrand.violet.opacity(0.35), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("这台图库要用哪些能力？")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.01)
                    Text("默认全部开启；只留照片也完全没问题，之后随时能在设置里改回来。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ModuleSwitchGrid(density: .setup, showsBulkActions: true)
                .padding(.top, 12)

            preferencesStrip
                .padding(.top, 10)

            if canMigrateLocal && !creatingAdditionalLibrary {
                migrateRow
                    .padding(.top, 10)
            }

            HStack(spacing: 9) {
                if creatingAdditionalLibrary {
                    SetupButton(title: "取消", systemImage: "xmark", style: .ghost) {
                        cancelCreation()
                    }
                    .frame(width: 118)
                    .disabled(isCreating)
                } else {
                    SetupButton(title: "返回", systemImage: "chevron.left", style: .ghost) {
                        showsModuleStep = false
                    }
                    .frame(width: 118)
                }

                SetupButton(title: "选择位置并创建", systemImage: "folder.badge.plus", style: .primary) {
                    createLibrary()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating)
            }
            .frame(width: 420)
            .padding(.top, 14)

            if creatingAdditionalLibrary {
                Text(isCreating
                     ? "正在创建并切换到新图库…"
                     : "创建后会立刻切换到新图库，并清空上一个图库留在内存里的内容。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - 第二步 · 外观与存储

    /// 图库级设置：最近删除保留天数（0 = 不自动清理）。
    private enum SetupTrashOption: Int, CaseIterable, Identifiable {
        case month = 30
        case quarter = 90
        case never = 0

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .month: return "30 天"
            case .quarter: return "90 天"
            case .never: return "不清理"
            }
        }
    }

    /// 空间档位：一次同时设置视频转码缓存与海报缓存的上限。
    private enum SetupSpacePreset: String, CaseIterable, Identifiable {
        case compact
        case balanced
        case roomy

        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: return "省空间"
            case .balanced: return "均衡"
            case .roomy: return "大空间"
            }
        }
        var videoGB: Int {
            switch self {
            case .compact: return 20
            case .balanced: return 50
            case .roomy: return 100
            }
        }
        var posterGB: Int {
            switch self {
            case .compact: return 5
            case .balanced: return 10
            case .roomy: return 20
            }
        }
        var help: String {
            switch self {
            case .compact: return "视频缓存 20 GB · 海报 5 GB，硬盘紧张时用"
            case .balanced: return "视频缓存 50 GB · 海报 10 GB，推荐"
            case .roomy: return "视频缓存 100 GB · 海报 20 GB，常看视频时用"
            }
        }

        static func current(videoGB: Int, posterGB: Int) -> SetupSpacePreset {
            if videoGB <= 20, posterGB <= 5 { return .compact }
            if videoGB >= 100, posterGB >= 20 { return .roomy }
            return .balanced
        }
    }

    /// 一行外观、一行存储：全部预选最优默认值，点一下就换，也可以完全不动。
    private var preferencesStrip: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                stripLabel("外观", symbol: "paintpalette", tint: LumaBrand.violet)
                ForEach(AppAppearance.allCases) { mode in
                    appearanceChip(mode)
                }
                Spacer(minLength: 8)
                accentDots
            }

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)

            HStack(spacing: 6) {
                stripLabel("删除保留", symbol: "trash", tint: LumaBrand.coral)
                ForEach(SetupTrashOption.allCases) { option in
                    choiceChip(option.title,
                               selected: setupTrashDays == option.rawValue,
                               font: 9.5) {
                        setupTrashDays = option.rawValue
                    }
                }
                Spacer(minLength: 8)
                stripLabel("空间", symbol: "internaldrive", tint: LumaBrand.cyan)
                ForEach(SetupSpacePreset.allCases) { preset in
                    choiceChip(preset.title, selected: currentSpace == preset, font: 9.5) {
                        settings.videoCacheLimitGB = preset.videoGB
                        settings.posterCacheLimitGB = preset.posterGB
                    }
                    .help(preset.help)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.05 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private var currentSpace: SetupSpacePreset {
        SetupSpacePreset.current(videoGB: settings.videoCacheLimitGB,
                                posterGB: settings.posterCacheLimitGB)
    }

    private func stripLabel(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.trailing, 1)
    }

    /// 外观三选一：深色 / 浅色 / 跟随系统，点下去整屏立刻换肤。
    private func appearanceChip(_ mode: AppAppearance) -> some View {
        let selected = settings.appearance == mode
        return Button {
            settings.appearance = mode
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(mode.compactTitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background {
                Capsule(style: .continuous)
                    .fill(selected ? AnyShapeStyle(settings.accentColor)
                                   : AnyShapeStyle(Color.primary.opacity(0.06)))
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }

    /// 强调色圆点：跟随系统用品牌渐变表示。
    private var accentDots: some View {
        HStack(spacing: 4.5) {
            ForEach(AppAccent.allCases) { item in
                let selected = settings.accent == item
                Button {
                    settings.accent = item
                } label: {
                    Circle()
                        .fill(item == .system ? AnyShapeStyle(LumaBrand.gradient)
                                              : AnyShapeStyle(item.swatch))
                        .frame(width: 12, height: 12)
                        .overlay {
                            Circle()
                                .strokeBorder(selected ? Color.primary.opacity(0.6)
                                                       : Color.primary.opacity(0.10),
                                              lineWidth: selected ? 1.6 : 0.6)
                        }
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 6, weight: .black))
                                    .foregroundStyle(.white)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .fixedSize()
    }

    /// 通用的小胶囊选项（删除保留 / 空间档位）。
    private func choiceChip(_ title: String,
                            selected: Bool,
                            font: CGFloat = 10,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: font, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.70))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background {
                    Capsule(style: .continuous)
                        .fill(selected ? AnyShapeStyle(settings.accentColor)
                                       : AnyShapeStyle(Color.primary.opacity(0.06)))
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 先把位置选好再创建；只有建库成功后才把暂存的图库级设置写进新库。
    private func createLibrary() {
        guard !isCreating else { return }
        isCreating = true
        let trashDays = setupTrashDays
        // 已有图库时新建的必须是空库：不能把当前库的照片再复制一份过去。
        let migrating = !creatingAdditionalLibrary && canMigrateLocal && migrateLocalPhotos
        Task {
            let created = await store.presentNewLibraryPanel(migratingLocalData: migrating)
            isCreating = false
            guard created else { return }
            // 建库成功后写入库级设置：此时读写的已经是新图库自己的 SQLite。
            settings.trashRetentionDays = trashDays
            // sheet 形态下建库成功已经切到新图库，关掉向导回到主界面。
            if creatingAdditionalLibrary { dismiss() }
        }
    }

    /// sheet 里取消：把能力开关还原成打开向导前的样子，避免「只是看看」也改了全局设置。
    private func cancelCreation() {
        for (key, value) in moduleSnapshot {
            UserDefaults.standard.set(value, forKey: key)
        }
        dismiss()
    }

    /// 建库的两步进度：一枚走完的圆点 + 一枚当前圆点，中间连一条细线。
    private var stepIndicator: some View {
        HStack(spacing: 7) {
            stepDot(index: 1, active: true, done: true)
            Capsule()
                .fill(LumaBrand.violet.opacity(0.45))
                .frame(width: 26, height: 1.5)
            stepDot(index: 2, active: true, done: false)
            Spacer(minLength: 0)
            Text("第 2 步 / 共 2 步")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private func stepDot(index: Int, active: Bool, done: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? LumaBrand.violet.opacity(0.85) : Color.primary.opacity(active ? 0.14 : 0.08))
                .frame(width: 15, height: 15)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(.white)
            } else {
                Text("\(index)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 应用图标 + 品牌光晕 + 一圈极细彩环，呼应官网图标。
    private var logoLockup: some View {
        ZStack {
            Circle()
                .fill(LumaBrand.gradient)
                .frame(width: 150, height: 150)
                .blur(radius: 46)
                .opacity(isDark ? 0.50 : 0.26)

            Group {
                if let logo = Self.logoImage {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LumaBrand.gradient)
                        .overlay {
                            Image(systemName: "photo.stack.fill")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.white)
                        }
                }
            }
            .frame(width: 108, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(isDark ? 0.20 : 0.55), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(isDark ? 0.50 : 0.18), radius: 22, y: 12)

            Circle()
                .strokeBorder(LumaBrand.ring, lineWidth: 1)
                .frame(width: 132, height: 132)
                .opacity(isDark ? 0.42 : 0.28)
                .rotationEffect(.degrees(-24))
        }
        .frame(height: 140)
        .accessibilityHidden(true)
    }

    /// 真实 App 图标：`swift run` 这类未打包场景再退回系统当前应用图标。
    private static var logoImage: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }

    private var eyebrowChip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(LumaBrand.gradient)
                .frame(width: 5, height: 5)
            Text("端侧智能 · 默认留在本机")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.14)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(isDark ? 0.06 : 0.04)))
        .overlay {
            Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            // 先让用户勾选这台图库要开启的能力（默认全开），再选保存位置。
            SetupButton(title: "新建图库…", systemImage: "plus", style: .primary) {
                showsModuleStep = true
            }
            .keyboardShortcut(.defaultAction)

            SetupButton(title: "打开已有图库…", systemImage: "folder", style: .ghost) {
                store.presentLibraryContainerPanel()
            }
        }
        .frame(width: 340)
    }

    /// 2.0 的能力范围：一个图库里除了照片视频，还有网络存储、影院与网络资源；
    /// 识别 / 体检这类智能始终在本机跑。
    private var capabilities: some View {
        let items: [(icon: String, title: String)] = [
            ("photo.on.rectangle.angled", "照片与视频"),
            ("externaldrive.connected.to.line.below", "网络存储"),
            ("film", "影院与资源"),
            ("wand.and.stars", "端侧智能")
        ]
        return HStack(spacing: 8) {
            ForEach(items, id: \.title) { item in
                HStack(spacing: 5) {
                    Image(systemName: item.icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(isDark ? 0.05 : 0.035))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
                }
            }
        }
    }

    private var migrateRow: some View {
        Toggle(isOn: $migrateLocalPhotos) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(hasLocalPhotos
                     ? "把现有的 \(store.photos.count.formatted()) 张照片迁入新图库"
                     : "把旧版本地照片迁入新图库")
                    .font(.system(size: 12))
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 420)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.05 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("支持本 App 创建的图库，也可以直接打开「照片」的原始图库（只读）。\n网络存储、影院与网络资源进入后再连接，配置随图库保存。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            HStack(spacing: 12) {
                Text(versionLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
                Button("退出拾光") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }

    private var versionLine: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
        return "版本 \(version) · 无账号 · 无第三方依赖"
    }
}

/// 官网同款按钮：白底胶囊主按钮 + 玻璃描边次按钮。
private struct SetupButton: View {
    enum Style {
        case primary
        case ghost
    }

    @Environment(\.colorScheme) private var scheme
    let title: String
    let systemImage: String
    var style: Style = .ghost
    let action: () -> Void

    @State private var hovered = false

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(foreground)
            .background { background }
            .scaleEffect(hovered ? 1.012 : 1)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { hovered = hovering }
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return isDark ? Color.black.opacity(0.88) : .white
        case .ghost: return .primary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Capsule(style: .continuous)
                .fill(isDark ? Color.white : Color.black.opacity(0.88))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(isDark ? 0.55 : 0.10), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(isDark ? 0.36 : 0.18), radius: 14, y: 7)
                .opacity(hovered ? 1 : 0.96)
        case .ghost:
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(hovered ? (isDark ? 0.09 : 0.06) : (isDark ? 0.05 : 0.035)))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(isDark ? 0.12 : 0.10), lineWidth: 0.7)
                }
        }
    }
}
