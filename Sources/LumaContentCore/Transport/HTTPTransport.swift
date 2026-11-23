import Foundation

/// 一次 HTTP 请求：只描述业务意图，请求头 / 证书策略由 `RequestProfile` 补齐。
public struct HTTPTransportRequest: Sendable {
    public var url: URL
    public var method: String
    /// 额外的请求头，优先级高于 `RequestProfile`。
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    /// 为 false 时保留 4xx / 5xx 的响应体，交给站点适配器自己判断验证页 / 风控页。
    public var throwsOnHTTPError: Bool

    public init(url: URL,
                method: String = "GET",
                headers: [String: String] = [:],
                body: Data? = nil,
                timeout: TimeInterval = 30,
                throwsOnHTTPError: Bool = true) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.throwsOnHTTPError = throwsOnHTTPError
    }
}

/// 一次 HTTP 响应：状态码与响应头保留原样，便于适配器处理 403 验证页等情况。
public struct HTTPTransportResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]
    public var finalURL: URL?

    public init(data: Data, statusCode: Int, headers: [String: String], finalURL: URL?) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
    }

    public var text: String? {
        String(data: data, encoding: .utf8)
    }
}

/// 重试策略：只重试「网络不可达」与 5xx / 429，避免把 403 验证页当成故障反复请求。
public struct HTTPRetryPolicy: Sendable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval

    public init(maxRetries: Int = 2, baseDelay: TimeInterval = 0.4) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
    }

    public static let `default` = HTTPRetryPolicy()
    public static let none = HTTPRetryPolicy(maxRetries: 0, baseDelay: 0)

    public func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500..<600).contains(statusCode)
    }

    public func shouldRetry(error: SourceError) -> Bool {
        error.kind == .unavailable
    }

    /// 第 n 次重试前的等待时间：线性翻倍，避免固定间隔同时打满站点。
    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return baseDelay * pow(2, TimeInterval(attempt - 1))
    }
}

/// 统一 HTTP 传输：电视 M3U / EPG、在线影院与站点适配器共用一套
/// UA / Referer / Cookie / 自签证书 / 超时 / 重试策略。
public final class HTTPSourceTransport: @unchecked Sendable {
    public static let shared = HTTPSourceTransport()

    private let lock = NSLock()
    /// 自签证书策略不同的会话不能复用，按 bool 分两个会话。
    private var sessions: [Bool: URLSession] = [:]
    /// 测试用：注入 `URLProtocol` 子类，拦截真实网络。
    private let protocolClasses: [AnyClass]?

    public init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    public func send(_ request: HTTPTransportRequest,
                     profile: RequestProfile = RequestProfile(),
                     retryPolicy: HTTPRetryPolicy = .default) async throws -> HTTPTransportResponse {
        var attempt = 0
        while true {
            if Task.isCancelled {
                throw SourceError(kind: .cancelled, message: "请求已取消")
            }
            do {
                let response = try await perform(request, profile: profile)
                if attempt < retryPolicy.maxRetries,
                   retryPolicy.shouldRetry(statusCode: response.statusCode) {
                    attempt += 1
                    try await sleep(retryPolicy.delay(afterAttempt: attempt))
                    continue
                }
                if request.throwsOnHTTPError, !(200..<400).contains(response.statusCode) {
                    throw SourceError.http(response.statusCode)
                }
                return response
            } catch let error as SourceError {
                if attempt < retryPolicy.maxRetries, retryPolicy.shouldRetry(error: error) {
                    attempt += 1
                    try await sleep(retryPolicy.delay(afterAttempt: attempt))
                    continue
                }
                throw error
            }
        }
    }

    // MARK: - 发送

    private func perform(_ request: HTTPTransportRequest,
                         profile: RequestProfile) async throws -> HTTPTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = max(1, request.timeout)
        urlRequest.httpBody = request.body
        // Profile 提供默认 UA / Referer，调用方可以覆盖单项。
        for (key, value) in profile.headerFields.merging(request.headers, uniquingKeysWith: { _, new in new }) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session(trustSelfSigned: profile.trustSelfSigned)
                .data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw SourceError.parse("返回的不是 HTTP 响应")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return HTTPTransportResponse(data: data,
                                         statusCode: http.statusCode,
                                         headers: headers,
                                         finalURL: http.url)
        } catch let error as URLError {
            throw Self.map(error, url: request.url)
        }
    }

    private func session(trustSelfSigned: Bool) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[trustSelfSigned] { return existing }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        let delegate = TrustSessionDelegate(trustSelfSigned: trustSelfSigned)
        let session = URLSession(configuration: configuration,
                                 delegate: delegate,
                                 delegateQueue: nil)
        sessions[trustSelfSigned] = session
        return session
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func map(_ error: URLError, url: URL) -> SourceError {
        switch error.code {
        case .cancelled:
            return SourceError(kind: .cancelled, message: "请求已取消")
        case .serverCertificateUntrusted, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return .tls(url.host ?? "服务器")
        case .timedOut, .notConnectedToInternet, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        default:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        }
    }
}

/// 自签证书例外：只有 `trustSelfSigned` 的源才放行 server trust，
/// 其他源保持系统默认校验。
private final class TrustSessionDelegate: NSObject, URLSessionDelegate {
    private let trustSelfSigned: Bool

    init(trustSelfSigned: Bool) {
        self.trustSelfSigned = trustSelfSigned
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard trustSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
