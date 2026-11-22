import Foundation
import LumaContentCore

/// 把各模块自己的错误收敛成 `SourceError`，界面只需要一套错误卡与恢复动作。
/// 现有错误类型不删除，避免一次性改所有抛错点；新界面优先读取 `SourceError`。
enum SourceErrorMapper {
    static func map(_ error: Error) -> SourceError {
        if let sourceError = error as? SourceError {
            return sourceError
        }
        if let error = error as? CloudOAuthError {
            return mapCloud(error)
        }
        if let error = error as? CatalogError {
            return mapCatalog(error)
        }
        if let error = error as? WebDAVError {
            return mapWebDAV(error)
        }
        if let error = error as? SMBError {
            return mapSMB(error)
        }
        if let error = error as? URLError {
            return mapURL(error)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return mapURL(URLError(URLError.Code(rawValue: nsError.code)))
        }
        return SourceError(kind: .unavailable,
                           message: error.localizedDescription,
                           recovery: [.retry])
    }

    private static func mapCloud(_ error: CloudOAuthError) -> SourceError {
        switch error {
        case .missingCredentials, .unsupportedProvider:
            return SourceError(kind: .unsupported,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .notAuthorized:
            return .unauthorized(error.localizedDescription)
        case .keychainDenied:
            return SourceError(kind: .keychainDenied,
                               message: error.localizedDescription,
                               recovery: [.reauthorize, .openSystemSettings])
        case .invalidCallback, .stateMismatch:
            return SourceError(kind: .unauthorized,
                               message: error.localizedDescription,
                               recovery: [.reauthorize, .retry])
        case .cancelled:
            return SourceError(kind: .cancelled, message: error.localizedDescription)
        case .timeout:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .token(_), .api(_):
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry, .reauthorize])
        }
    }

    private static func mapCatalog(_ error: CatalogError) -> SourceError {
        switch error {
        case .unsupportedProvider:
            return .unsupported(error.localizedDescription)
        case .invalidConfig(_):
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .http(let status):
            return .http(status, message: error.localizedDescription)
        case .parse(_):
            return .parse(error.localizedDescription)
        case .decryption:
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource, .retry])
        case .tls(let host):
            return .tls(host)
        case .unavailable:
            return .unavailable(error.localizedDescription)
        }
    }

    private static func mapWebDAV(_ error: WebDAVError) -> SourceError {
        switch error {
        case .invalidURL:
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .unauthorized, .forbidden:
            return .unauthorized(error.localizedDescription)
        case .notFound:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [])
        case .unsupported:
            return .unsupported(error.localizedDescription)
        case .exists:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [])
        case .status(let code):
            return .http(code, message: error.localizedDescription)
        case .transport(_):
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .invalidResponse:
            return .parse(error.localizedDescription)
        }
    }

    private static func mapSMB(_ error: SMBError) -> SourceError {
        switch error {
        case .invalidAddress:
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .unreachable(_):
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .mountFailed(_):
            return SourceError(kind: .unauthorized,
                               message: error.localizedDescription,
                               recovery: [.reauthorize, .reconfigureSource])
        case .listFailed(_):
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        }
    }

    private static func mapURL(_ error: URLError) -> SourceError {
        switch error.code {
        case .cancelled:
            return SourceError(kind: .cancelled, message: "请求已取消")
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .unauthorized(error.localizedDescription)
        case .serverCertificateUntrusted, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return SourceError(kind: .tlsUntrusted,
                               message: error.localizedDescription,
                               recovery: [.allowInsecureTLS, .retry])
        default:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        }
    }
}
