import SwiftUI
import AppKit
import LumaContentCore

// MARK: - 阿里云盘扫码登录（向导内）
//
// 状态机与轮询由 LumaContentCore 的 `runQRLogin` 统一驱动，
// 这里只保留阿里云盘自己的面板视觉与「确认后换取网页令牌」的处理。

extension CloudSetupWizardView {
    // MARK: 模式切换

    var aliyunLoginModeSwitcher: some View {
        HStack(spacing: 2) {
            aliyunModePill("扫码登录", symbol: "qrcode", active: aliyunQRMode) {
                guard !aliyunQRMode else { return }
                aliyunQRMode = true
                startAliyunQRLogin()
            }
            aliyunModePill("粘贴令牌", symbol: "doc.on.clipboard", active: !aliyunQRMode) {
                guard aliyunQRMode else { return }
                aliyunQRMode = false
                stopAliyunQRLogin()
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .fixedSize()
    }

    private func aliyunModePill(_ title: String,
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

    // MARK: 扫码面板

    var aliyunQRLoginPanel: some View {
        qrCard
            .onAppear {
                if aliyunQRMode, aliyunQRPhase == .idle {
                    startAliyunQRLogin()
                }
            }
            .onDisappear { stopAliyunQRLogin() }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.21),
                                              Color(red: 0.03, green: 0.06, blue: 0.13)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            // 两团柔光：左上偏品牌蓝，右下偏青色，给深色卡片一点体积感。
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
                qrStatusRow
                qrPlate
                qrFooterRow
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(height: 404)
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

    private var qrStatusRow: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 28, height: 28)
                Image(systemName: aliyunQRPhase.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(aliyunQRPhase.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(aliyunQRPhase.title(app: "阿里云盘"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(aliyunQRPhase == .failed ? (aliyunQRMessage ?? aliyunQRPhase.subtitle(app: "阿里云盘"))
                                              : aliyunQRPhase.subtitle(app: "阿里云盘"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if aliyunQRPhase.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }

    private var qrPlate: some View {
        ZStack {
            // 呼吸光晕：让二维码像一块被托起来的玻璃片。
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LumaBrand.cyan.opacity(aliyunQRPulse ? 0.30 : 0.12))
                .frame(width: 250, height: 250)
                .blur(radius: 26)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .frame(width: 236, height: 236)
                .shadow(color: .black.opacity(0.42), radius: 24, y: 12)

            qrContent
                .frame(width: 196, height: 196)

            // 中心品牌标识：四角留空不影响识别（纠错级别 H）。
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.16), radius: 5, y: 1)
                .overlay {
                    CloudBrandIcon(brand: .aliyun, size: 34)
                }
                .opacity(aliyunQRPhase == .expired || aliyunQRPhase == .failed ? 0.25 : 1)

            if aliyunQRPhase == .waiting || aliyunQRPhase == .scanned {
                qrSweepLine
            }

            if aliyunQRPhase == .expired { qrOverlayExpired }
            if aliyunQRPhase == .failed { qrOverlayFailed }
            if aliyunQRPhase == .loading { qrOverlayLoading }
            if aliyunQRPhase == .success { qrOverlaySuccess }
        }
        .frame(height: 252)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                aliyunQRPulse = true
            }
        }
    }

    @ViewBuilder
    private var qrContent: some View {
        if let code = aliyunQRSession?.codeContent {
            StyledQRCode(text: code)
                .opacity(aliyunQRPhase == .expired || aliyunQRPhase == .failed ? 0.10 : 1)
                .blur(radius: aliyunQRPhase == .expired || aliyunQRPhase == .failed ? 5 : 0)
                .animation(.easeOut(duration: 0.2), value: aliyunQRPhase)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.06))
        }
    }

    private var qrSweepLine: some View {
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
                .offset(y: aliyunQRSweep ? height - 8 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        aliyunQRSweep = true
                    }
                }
        }
        .frame(width: 196, height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
    }

    private var qrOverlayLoading: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在生成…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var qrOverlayExpired: some View {
        qrRetryOverlay(symbol: "arrow.clockwise.circle.fill",
                       title: "二维码已过期",
                       message: "重新获取一张继续扫码",
                       button: "重新获取")
    }

    private var qrOverlayFailed: some View {
        qrRetryOverlay(symbol: "exclamationmark.triangle.fill",
                       title: "扫码失败",
                       message: aliyunQRMessage ?? "请稍后重试",
                       button: "重试")
    }

    private func qrRetryOverlay(symbol: String,
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
            Button(button) { startAliyunQRLogin() }
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

    private var qrOverlaySuccess: some View {
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

    private var qrFooterRow: some View {
        HStack(spacing: 6) {
            if aliyunQRSession != nil,
               aliyunQRPhase == .waiting || aliyunQRPhase == .scanned {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = max(0, Int((aliyunQRSession?.expiresAt ?? Date())
                        .timeIntervalSinceNow.rounded()))
                    HStack(spacing: 5) {
                        Image(systemName: "hourglass")
                        Text(left > 0 ? "\(left) 秒后自动换码" : "正在换码…")
                    }
                }
            } else if aliyunQRPhase == .success {
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
                startAliyunQRLogin()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("换一张")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(aliyunQRPhase == .loading ? 0.3 : 0.82))
            .disabled(aliyunQRPhase == .loading || aliyunQRPhase == .confirming)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.white.opacity(0.45))
    }

    // MARK: 扫码状态机

    func startAliyunQRLogin() {
        stopAliyunQRLogin()
        let run = UUID()
        aliyunQRRunID = run
        aliyunQRPhase = .loading
        aliyunQRMessage = nil
        aliyunQRSession = nil
        cookieVerified = false
        aliyunQRTask = Task { @MainActor in
            await runQRLogin(AliyunQRProvider(),
                             policy: .aliyun,
                             isActive: { aliyunQRRunID == run },
                             onChallenge: { aliyunQRSession = $0 },
                             onStage: { stage, message in
                                 aliyunQRPhase = QRLoginPhase(stage: stage)
                                 aliyunQRMessage = message
                             },
                             onConfirmed: { credential in
                                 guard let refreshToken = credential.refreshToken else {
                                     return "接口没有返回登录凭据，可以重试或改用「粘贴令牌」"
                                 }
                                 return await finishAliyunQRLogin(refreshToken: refreshToken)
                             })
        }
    }

    func stopAliyunQRLogin() {
        aliyunQRTask?.cancel()
        aliyunQRTask = nil
        aliyunQRRunID = UUID()
    }

    /// 确认登录后：用拿到的 refresh_token 换一次网页令牌并读根目录校验，
    /// 通过后 `cookieVerified` 置位，底部「下一步」就可以直接选接入范围。
    /// 返回 nil 表示成功，返回文案表示失败原因。
    private func finishAliyunQRLogin(refreshToken: String) async -> String? {
        let result = await store.validateAliyunWebCredential(refreshToken: refreshToken)
        if result.ok, let token = result.token {
            cookieText = refreshToken
            cookieVerified = true
            aliyunWebToken = token
            status = result.message
            statusIsError = false
            return nil
        } else {
            status = result.message
            statusIsError = true
            return result.message
        }
    }
}
