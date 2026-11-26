import Foundation

// MARK: - 扫码登录统一协议
//
// 阿里云盘 / 夸克 / 115 的扫码流程结构一致：生成二维码 → 轮询扫码状态 → 确认后换取凭据。
// 各网盘只需要实现「生成」与「单次轮询」，轮询节奏、过期换码、网络抖动容错
// 与「已确认但凭据未下发」的重试都由 `runQRLogin` 统一处理。

/// 扫码成功后拿到的凭据。不同网盘给 Cookie 或 refresh_token，统一放在这里。
public struct QRLoginCredential: Equatable, Sendable {
    public var cookies: String?
    public var refreshToken: String?
    public var accessToken: String?
    public var accountName: String?

    public init(cookies: String? = nil,
                refreshToken: String? = nil,
                accessToken: String? = nil,
                accountName: String? = nil) {
        self.cookies = cookies
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.accountName = accountName
    }
}

/// 单次轮询的返回值。
public enum QRLoginEvent: Equatable, Sendable {
    case waiting
    case scanned
    case confirmed(QRLoginCredential)
    /// 已确认登录，但这一轮响应里还没有凭据：按策略再问几次。
    case pendingCredential
    case expired
    case canceled
    /// 网盘明确返回失败（例如状态码异常）。
    case failed
}

/// 二维码面板需要的内容：只保留渲染与倒计时所需字段，不暴露各网盘的会话结构。
public struct QRLoginChallenge: Equatable, Sendable {
    public var codeContent: String
    public var expiresAt: Date

    public init(codeContent: String, expiresAt: Date) {
        self.codeContent = codeContent
        self.expiresAt = expiresAt
    }
}

/// 扫码登录的阶段，与界面状态一一对应。
public enum QRLoginStage: Equatable, Sendable {
    case loading
    case waiting
    case scanned
    case confirming
    case success
    case expired
    case failed
}

/// 网盘扫码接入协议：新增网盘只需实现这三个方法。
public protocol QRLoginProvider: Sendable {
    associatedtype Session: Sendable

    /// 拉取一张新的登录二维码。
    func generate() async throws -> Session
    /// 从会话里取出二维码内容与本地兜底有效期。
    func challenge(for session: Session) -> QRLoginChallenge
    /// 单次轮询；网络抖动由运行器按策略容错。
    func poll(_ session: Session) async throws -> QRLoginEvent
}

/// 各网盘的轮询节奏与容错策略。
public struct QRLoginPolicy: Sendable {
    /// 两次轮询之间的间隔（秒）。
    public var pollInterval: TimeInterval
    /// 二维码过期后停留展示的时长（秒），随后自动换一张。
    public var expiryPause: TimeInterval
    /// 连续多少次轮询报错才判定失败；1 表示不重试。
    public var pollFailureTolerance: Int
    /// 「已确认但没有凭据」最多再问几次。
    public var pendingCredentialRetries: Int
    public var pendingCredentialMessage: String
    public var failureMessage: String
    public var canceledMessage: String

    public init(pollInterval: TimeInterval = 1.6,
                expiryPause: TimeInterval = 0.9,
                pollFailureTolerance: Int = 1,
                pendingCredentialRetries: Int = 0,
                pendingCredentialMessage: String = "已确认登录，但接口没有返回登录凭据，可以重试",
                failureMessage: String = "扫码登录失败，请重试或改用凭据粘贴",
                canceledMessage: String = "已在手机上取消登录，可以重新扫码") {
        self.pollInterval = pollInterval
        self.expiryPause = expiryPause
        self.pollFailureTolerance = pollFailureTolerance
        self.pendingCredentialRetries = pendingCredentialRetries
        self.pendingCredentialMessage = pendingCredentialMessage
        self.failureMessage = failureMessage
        self.canceledMessage = canceledMessage
    }

    /// 阿里云盘：确认后令牌偶尔晚一轮下发，多问几次。
    public static let aliyun = QRLoginPolicy(
        pendingCredentialRetries: 6,
        pendingCredentialMessage: "已确认登录，但接口没有返回登录凭据。可以重试，或改用「粘贴令牌」。",
        failureMessage: "扫码登录失败，请重试或改用「粘贴令牌」",
        canceledMessage: "已在手机上取消登录，可以重新扫码"
    )

    /// 115：轮询间隔略长，偶发网络抖动不直接判失败。
    public static let pan115 = QRLoginPolicy(pollInterval: 1.8,
                                             pollFailureTolerance: 3,
                                             failureMessage: "扫码登录失败，请重试或改用 Cookie 粘贴")

    /// 夸克：默认节奏。
    public static let quark = QRLoginPolicy(failureMessage: "扫码登录失败，请重试或改用 Cookie 粘贴")
}

/// 运行一次扫码登录，直到成功、失败或被取消。
///
/// - Parameters:
///   - isActive: 每次轮询前后检查；返回 false 与取消任务等价（用于切换模式、关闭面板）。
///   - onChallenge: 拿到新二维码时回调，界面据此渲染并开始倒计时。
///   - onStage: 阶段变化回调；第二参数仅在失败时给出具体原因。
///   - onConfirmed: 确认后换取并保存凭据；返回 nil 表示成功，返回文案表示失败原因。
@MainActor
public func runQRLogin<P: QRLoginProvider>(
    _ provider: P,
    policy: QRLoginPolicy = QRLoginPolicy(),
    isActive: @escaping @MainActor () -> Bool,
    onChallenge: @escaping @MainActor (QRLoginChallenge) -> Void,
    onStage: @escaping @MainActor (QRLoginStage, String?) -> Void,
    onConfirmed: @escaping @MainActor (QRLoginCredential) async -> String?
) async {
    var lastStage: QRLoginStage?

    func emit(_ stage: QRLoginStage, message: String? = nil) {
        guard lastStage != stage || message != nil else { return }
        lastStage = stage
        onStage(stage, message)
    }

    func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    emit(.loading)

    while !Task.isCancelled, isActive() {
        do {
            let session = try await provider.generate()
            guard !Task.isCancelled, isActive() else { return }

            let challenge = provider.challenge(for: session)
            onChallenge(challenge)
            emit(.waiting)

            var needsNewCode = false
            var pendingAttempts = 0
            var failures = 0

            while !Task.isCancelled, isActive() {
                await sleep(policy.pollInterval)
                guard !Task.isCancelled, isActive() else { return }

                if Date() >= challenge.expiresAt {
                    emit(.expired)
                    await sleep(policy.expiryPause)
                    needsNewCode = true
                    break
                }

                let event: QRLoginEvent
                do {
                    event = try await provider.poll(session)
                    failures = 0
                } catch {
                    failures += 1
                    if failures >= max(1, policy.pollFailureTolerance) { throw error }
                    continue
                }
                guard !Task.isCancelled, isActive() else { return }

                switch event {
                case .waiting:
                    pendingAttempts = 0
                    emit(.waiting)
                case .scanned:
                    pendingAttempts = 0
                    emit(.scanned)
                case .confirmed(let credential):
                    emit(.confirming)
                    let failure = await onConfirmed(credential)
                    guard !Task.isCancelled, isActive() else { return }
                    if let failure {
                        emit(.failed, message: failure)
                    } else {
                        emit(.success)
                    }
                    return
                case .pendingCredential:
                    pendingAttempts += 1
                    if pendingAttempts >= policy.pendingCredentialRetries {
                        emit(.failed, message: policy.pendingCredentialMessage)
                        return
                    }
                    await sleep(0.8)
                case .expired:
                    emit(.expired)
                    await sleep(policy.expiryPause)
                    needsNewCode = true
                case .canceled:
                    emit(.failed, message: policy.canceledMessage)
                    return
                case .failed:
                    emit(.failed, message: policy.failureMessage)
                    return
                }

                if needsNewCode { break }
            }
        } catch {
            guard !Task.isCancelled, isActive() else { return }
            emit(.failed, message: error.localizedDescription)
            return
        }
    }
}
