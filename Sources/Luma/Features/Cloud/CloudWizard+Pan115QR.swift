import SwiftUI
import AppKit
import LumaContentCore

// MARK: - 115 网盘扫码登录（向导内）
//
// 面板与动效由 QRLoginPanel 统一提供，这里只负责模式切换与扫码状态机。

extension CloudSetupWizardView {
    // MARK: 模式切换

    var pan115LoginModeSwitcher: some View {
        qrLoginModeSwitcher(qrActive: pan115QRMode) {
            guard !pan115QRMode else { return }
            pan115QRMode = true
            startPan115QRLogin()
        } onPaste: {
            guard pan115QRMode else { return }
            pan115QRMode = false
            stopPan115QRLogin()
        }
    }

    // MARK: 扫码面板

    var pan115QRLoginPanel: some View {
        QRLoginPanel(brand: .pan115,
                     appName: "115",
                     phase: pan115QRPhase,
                     message: pan115QRMessage,
                     codeContent: pan115QRSession?.codeContent,
                     expiresAt: pan115QRSession?.expiresAt,
                     sweep: $pan115QRSweep,
                     pulse: $pan115QRPulse) {
            startPan115QRLogin()
        }
        .onAppear {
            if pan115QRMode, pan115QRPhase == .idle {
                startPan115QRLogin()
            }
        }
        .onDisappear { stopPan115QRLogin() }
    }

    // MARK: 扫码状态机

    func startPan115QRLogin() {
        stopPan115QRLogin()
        let run = UUID()
        pan115QRRunID = run
        pan115QRPhase = .loading
        pan115QRMessage = nil
        pan115QRSession = nil
        cookieVerified = false
        pan115QRTask = Task { @MainActor in
            await runQRLogin(Pan115QRProvider(),
                             policy: .pan115,
                             isActive: { pan115QRRunID == run },
                             onChallenge: { pan115QRSession = $0 },
                             onStage: { stage, message in
                                 pan115QRPhase = QRLoginPhase(stage: stage)
                                 pan115QRMessage = message
                             },
                             onConfirmed: { credential in
                                 guard let cookie = credential.cookies else {
                                     return "接口没有返回登录 Cookie，可以重试或改用粘贴 Cookie"
                                 }
                                 // 115 扫码直接拿到完整 Cookie，测试连通性后即完成。
                                 cookieText = cookie
                                 let result = await store.testPan115Cookie(cookie)
                                 guard result.ok else { return result.message }
                                 cookieVerified = true
                                 return nil
                             })
        }
    }

    func stopPan115QRLogin() {
        pan115QRTask?.cancel()
        pan115QRTask = nil
        pan115QRRunID = UUID()
    }
}
