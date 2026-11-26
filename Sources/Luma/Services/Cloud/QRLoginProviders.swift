import Foundation
import LumaContentCore

// MARK: - 各网盘扫码适配器
//
// 网络细节仍留在各自的 QRLogin 服务里；这里只把它们的会话与状态
// 映射成统一的二维码内容与轮询事件，供 `runQRLogin` 驱动。

struct AliyunQRProvider: QRLoginProvider {
    func generate() async throws -> AliyunQRLogin.Session {
        try await AliyunQRLogin.generate()
    }

    func challenge(for session: AliyunQRLogin.Session) -> QRLoginChallenge {
        QRLoginChallenge(codeContent: session.codeContent, expiresAt: session.expiresAt)
    }

    func poll(_ session: AliyunQRLogin.Session) async throws -> QRLoginEvent {
        switch try await AliyunQRLogin.poll(session) {
        case .waiting:
            return .waiting
        case .scanned:
            return .scanned
        case .confirmed(let refreshToken, let accessToken):
            return .confirmed(QRLoginCredential(refreshToken: refreshToken,
                                                accessToken: accessToken))
        case .confirmedWithoutCredential:
            return .pendingCredential
        case .expired:
            return .expired
        case .canceled:
            return .canceled
        }
    }
}

struct QuarkQRProvider: QRLoginProvider {
    func generate() async throws -> QuarkQRLogin.Session {
        try await QuarkQRLogin.generate()
    }

    func challenge(for session: QuarkQRLogin.Session) -> QRLoginChallenge {
        QRLoginChallenge(codeContent: session.codeContent, expiresAt: session.expiresAt)
    }

    func poll(_ session: QuarkQRLogin.Session) async throws -> QRLoginEvent {
        switch try await QuarkQRLogin.poll(token: session.token) {
        case .waiting:
            return .waiting
        case .confirmed(let cookie):
            return .confirmed(QRLoginCredential(cookies: cookie))
        case .expired:
            return .expired
        case .failed:
            return .failed
        }
    }
}

struct Pan115QRProvider: QRLoginProvider {
    func generate() async throws -> Pan115QRLogin.Session {
        try await Pan115QRLogin.generate()
    }

    func challenge(for session: Pan115QRLogin.Session) -> QRLoginChallenge {
        QRLoginChallenge(codeContent: session.codeContent, expiresAt: session.expiresAt)
    }

    func poll(_ session: Pan115QRLogin.Session) async throws -> QRLoginEvent {
        switch try await Pan115QRLogin.poll(session) {
        case .waiting:
            return .waiting
        case .scanned:
            return .scanned
        case .confirmed(let cookie):
            return .confirmed(QRLoginCredential(cookies: cookie))
        case .expired:
            return .expired
        case .failed:
            return .failed
        }
    }
}
