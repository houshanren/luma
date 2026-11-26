import SwiftUI
import AppKit
import LumaContentCore

// MARK: - 通用扫码登录面板（夸克 / 115 网盘共用）
//
// 两个网盘的扫码流程一致：生成二维码 → 轮询状态 → 确认后拿到 Cookie。
// 视觉、动效、覆盖层共用一套，只在品牌标识与应用名称上做区分，
// 避免每个网盘各维护一份几乎相同的卡片。

/// 扫码登录的状态机（各网盘共用）。
enum QRLoginPhase: Equatable {
    case idle
    case loading
    case waiting
    case scanned
    case confirming
    case success
    case expired
    case failed

    var symbol: String {
        switch self {
        case .idle, .loading: return "qrcode"
        case .waiting: return "qrcode.viewfinder"
        case .scanned: return "iphone.gen3.radiowaves.left.and.right"
        case .confirming: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.seal.fill"
        case .expired: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    func title(app: String) -> String {
        switch self {
        case .idle, .loading: return "正在生成登录二维码"
        case .waiting: return "打开\(app) App 扫一扫"
        case .scanned: return "已扫码，请在手机上确认"
        case .confirming: return "已确认，正在获取登录凭据"
        case .success: return "登录成功"
        case .expired: return "二维码已过期"
        case .failed: return "扫码登录失败"
        }
    }

    func subtitle(app: String) -> String {
        switch self {
        case .idle, .loading: return "正在向\(app)请求一张一次性二维码…"
        case .waiting: return "App 首页「扫一扫」，确认后会自动接入"
        case .scanned: return "在手机弹窗里点「确认登录」，不用回到电脑"
        case .confirming: return "马上就好，正在验证并保存凭据"
        case .success: return "点右下角「下一步」选择要接入的目录"
        case .expired: return "二维码有效期约两分钟，可以重新获取一张"
        case .failed: return "可以重试，或改用 Cookie 手动粘贴"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .loading, .waiting: return LumaBrand.cyan
        case .scanned: return LumaBrand.amber
        case .confirming: return Color.white
        case .success: return Color(red: 0.35, green: 0.88, blue: 0.62)
        case .expired: return LumaBrand.amber
        case .failed: return LumaBrand.coral
        }
    }

    var showsSpinner: Bool {
        self == .loading || self == .confirming
    }

    /// 把统一运行器上报的阶段映射成界面状态。
    init(stage: QRLoginStage) {
        switch stage {
        case .loading: self = .loading
        case .waiting: self = .waiting
        case .scanned: self = .scanned
        case .confirming: self = .confirming
        case .success: self = .success
        case .expired: self = .expired
        case .failed: self = .failed
        }
    }
}

/// 扫码登录卡片：深色渐变 + 柔光 + 二维码 + 状态行 + 覆盖层。
struct QRLoginPanel: View {
    let brand: CloudBrand
    /// 用于文案展示的应用名，如「夸克」「115」。
    let appName: String
    let phase: QRLoginPhase
    /// 失败时的具体原因，优先于默认副标题。
    let message: String?
    let codeContent: String?
    let expiresAt: Date?
    @Binding var sweep: Bool
    @Binding var pulse: Bool
    let onRetry: () -> Void

    static let plateSize: CGFloat = 236
    static let qrSize: CGFloat = 196

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.21),
                                              Color(red: 0.03, green: 0.06, blue: 0.13)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            // 两团柔光：左上偏品牌蓝，右下偏青色。
            Circle()
                .fill(Color(red: 0.16, green: 0.46, blue: 1.00).opacity(0.42))
                .frame(width: 250, height: 250)
                .blur(radius: 74)
                .offset(x: 170, y: -120)
            Circle()
                .fill(LumaBrand.cyan.opacity(0.20))
                .frame(width: 220, height: 220)
                .blur(radius: 64)
                .offset(x: -180, y: 130)

            VStack(spacing: 14) {
                statusRow
                plate
                footerRow
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22),
                                                      Color.white.opacity(0.04)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
    }

    // MARK: 状态行

    private var statusRow: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 28, height: 28)
                Image(systemName: phase.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(phase.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.title(app: appName))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(phase == .failed ? (message ?? phase.subtitle(app: appName))
                                      : phase.subtitle(app: appName))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if phase.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }

    // MARK: 二维码

    private var plate: some View {
        ZStack {
            // 呼吸光晕
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LumaBrand.cyan.opacity(pulse ? 0.30 : 0.12))
                .frame(width: 250, height: 250)
                .blur(radius: 26)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .frame(width: Self.plateSize, height: Self.plateSize)
                .shadow(color: .black.opacity(0.42), radius: 24, y: 12)

            qrContent
                .frame(width: Self.qrSize, height: Self.qrSize)

            // 中心品牌标识
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.16), radius: 5, y: 1)
                .overlay {
                    CloudBrandIcon(brand: brand, size: 34)
                }
                .opacity(dimsQR ? 0.25 : 1)

            if phase == .waiting || phase == .scanned {
                sweepLine
            }

            if phase == .expired { overlayExpired }
            if phase == .failed { overlayFailed }
            if phase == .loading { overlayLoading }
            if phase == .success { overlaySuccess }
        }
        .frame(height: 252)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var dimsQR: Bool { phase == .expired || phase == .failed }

    @ViewBuilder
    private var qrContent: some View {
        if let code = codeContent {
            StyledQRCode(text: code)
                .opacity(dimsQR ? 0.10 : 1)
                .blur(radius: dimsQR ? 5 : 0)
                .animation(.easeOut(duration: 0.2), value: phase)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.06))
        }
    }

    private var sweepLine: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            Rectangle()
                .fill(LinearGradient(colors: [Color.clear,
                                              LumaBrand.cyan.opacity(0.9),
                                              Color.clear],
                                     startPoint: .leading,
                                     endPoint: .trailing))
                .frame(height: 2)
                .blur(radius: 1.1)
                .offset(y: sweep ? height - 8 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        sweep = true
                    }
                }
        }
        .frame(width: Self.qrSize, height: Self.qrSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: 覆盖层

    private var overlayLoading: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在生成…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var overlayExpired: some View {
        retryOverlay(symbol: "arrow.clockwise.circle.fill",
                     title: "二维码已过期",
                     message: "重新获取一张继续扫码",
                     button: "重新获取")
    }

    private var overlayFailed: some View {
        retryOverlay(symbol: "exclamationmark.triangle.fill",
                     title: "扫码失败",
                     message: message ?? "请稍后重试",
                     button: "重试")
    }

    private func retryOverlay(symbol: String,
                              title: String,
                              message: String,
                              button: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text(message)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 170)
            Button(button) { onRetry() }
                .controlSize(.small)
                .padding(.top, 1)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private var overlaySuccess: some View {
        VStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(red: 0.28, green: 0.80, blue: 0.52))
            Text("登录成功")
                .font(.system(size: 12.5, weight: .semibold))
            Text("点「下一步」选择接入范围")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    // MARK: 底部行

    private var footerRow: some View {
        HStack(spacing: 6) {
            if let expiresAt,
               phase == .waiting || phase == .scanned {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = max(0, Int(expiresAt.timeIntervalSinceNow.rounded()))
                    HStack(spacing: 5) {
                        Image(systemName: "hourglass")
                        Text(left > 0 ? "\(left) 秒后自动换码" : "正在换码…")
                    }
                }
            } else if phase == .success {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal")
                    Text("凭据已保存")
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text("扫码后自动完成授权，不需要复制任何内容")
                }
            }
            Spacer(minLength: 4)
            Button {
                onRetry()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("换一张")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(phase == .loading ? 0.3 : 0.82))
            .disabled(phase == .loading || phase == .confirming)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.white.opacity(0.45))
    }
}

// MARK: - 模式切换胶囊（各网盘共用）

extension CloudSetupWizardView {
    /// 「扫码登录 / 粘贴 Cookie」胶囊切换器。
    func qrLoginModeSwitcher(qrActive: Bool,
                             onScan: @escaping () -> Void,
                             onPaste: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                qrModePill("扫码登录", symbol: "qrcode", active: qrActive, action: onScan)
                qrModePill("粘贴 Cookie", symbol: "doc.on.clipboard", active: !qrActive, action: onPaste)
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            Spacer(minLength: 0)
            Text("不需要开发者应用")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func qrModePill(_ title: String,
                            symbol: String,
                            active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous).fill(Color.accentColor)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
