import SwiftUI
import AppKit
import LumaContentCore

// MARK: - 夸克网盘扫码登录（向导内）
//
// 面板与动效由 QRLoginPanel 统一提供，这里只负责模式切换与扫码状态机。

extension CloudSetupWizardView {
    // MARK: 模式切换

    var quarkLoginModeSwitcher: some View {
        qrLoginModeSwitcher(qrActive: quarkQRMode) {
            guard !quarkQRMode else { return }
            quarkQRMode = true
            startQuarkQRLogin()
        } onPaste: {
            guard quarkQRMode else { return }
            quarkQRMode = false
            stopQuarkQRLogin()
        }
    }

    // MARK: 扫码面板

    var quarkQRLoginPanel: some View {
        QRLoginPanel(brand: .quark,
                     appName: "夸克",
                     phase: quarkQRPhase,
                     message: quarkQRMessage,
                     codeContent: quarkQRSession?.codeContent,
                     expiresAt: quarkQRSession?.expiresAt,
                     sweep: $quarkQRSweep,
                     pulse: $quarkQRPulse) {
            startQuarkQRLogin()
        }
        .onAppear {
            if quarkQRMode, quarkQRPhase == .idle {
                startQuarkQRLogin()
            }
        }
        .onDisappear { stopQuarkQRLogin() }
    }

    // MARK: 扫码状态机

    func startQuarkQRLogin() {
        stopQuarkQRLogin()
        let run = UUID()
        quarkQRRunID = run
        quarkQRPhase = .loading
        quarkQRMessage = nil
        quarkQRSession = nil
        cookieVerified = false
        quarkQRTask = Task { @MainActor in
            await runQRLogin(QuarkQRProvider(),
                             policy: .quark,
                             isActive: { quarkQRRunID == run },
                             onChallenge: { quarkQRSession = $0 },
                             onStage: { stage, message in
                                 quarkQRPhase = QRLoginPhase(stage: stage)
                                 quarkQRMessage = message
                             },
                             onConfirmed: { credential in
                                 guard let cookie = credential.cookies else {
                                     return "接口没有返回登录 Cookie，可以重试或改用粘贴 Cookie"
                                 }
                                 // 夸克扫码直接拿到完整 Cookie，测试连通性后即完成。
                                 cookieText = cookie
                                 let result = await store.testQuarkCookie(cookie)
                                 guard result.ok else { return result.message }
                                 cookieVerified = true
                                 return nil
                             })
        }
    }

    func stopQuarkQRLogin() {
        quarkQRTask?.cancel()
        quarkQRTask = nil
        quarkQRRunID = UUID()
    }
}
