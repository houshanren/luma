import AppKit
import SwiftUI

/// 首次启动的建库引导：没有图库时不允许进入主界面。
/// 视觉与官网首屏对齐：真实 App 图标 + 品牌渐变光晕 + 玻璃卡片。
struct LibrarySetupView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.colorScheme) private var scheme
    @State private var migrateLocalPhotos = true

    private var hasLocalPhotos: Bool { !store.photos.isEmpty }
    /// 旧版本地库（没有图库包）残留时也可以选择迁入。
    private var canMigrateLocal: Bool { hasLocalPhotos || LibraryPaths.hasLocalLibraryData }
    private var isDark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            LumaAmbientBackground()
            brandAura

            card
                .padding(40)
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

            actions
                .padding(.top, 26)

            if canMigrateLocal {
                migrateRow
                    .padding(.top, 14)
            }

            footer
                .padding(.top, 26)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
        .frame(width: 500)
        .lumaGlassCard(cornerRadius: 32)
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
            SetupButton(title: "新建图库…", systemImage: "plus", style: .primary) {
                store.presentNewLibraryPanel(migratingLocalData: canMigrateLocal && migrateLocalPhotos)
            }
            .keyboardShortcut(.defaultAction)

            SetupButton(title: "打开已有图库…", systemImage: "folder", style: .ghost) {
                store.presentLibraryContainerPanel()
            }
        }
        .frame(width: 340)
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
        .padding(.vertical, 10)
        .frame(width: 340)
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
            Text("支持本 App 创建的图库，也可以直接打开「照片」的原始图库（只读）。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

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
