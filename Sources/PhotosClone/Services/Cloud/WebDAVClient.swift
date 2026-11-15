import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS

// MARK: - WebDAV 错误

enum WebDAVError: LocalizedError {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case unsupported
    case exists
    case status(Int)
    case transport(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .unauthorized: return "认证失败（401），请检查账号或密码"
        case .forbidden: return "没有访问权限（403）"
        case .notFound: return "路径不存在（404）"
        case .unsupported: return "该地址不是可用的 WebDAV 服务"
        case .exists: return "目标位置已存在同名项目"
        case .status(let code): return "服务器返回 HTTP \(code)"
        case .transport(let message): return message
        case .invalidResponse: return "服务器响应无法解析"
        }
    }
}

// MARK: - WebDAV 客户端

struct WebDAVClient {
    let baseURL: URL
    let username: String
    let password: String

    init?(baseURLString: String, username: String, password: String) {
        guard let url = Self.normalizedBaseURL(baseURLString) else { return nil }
        self.baseURL = url
        self.username = username
        self.password = password
    }

    /// 补全协议、去掉查询参数，并确保路径以「/」结尾。
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if !path.hasSuffix("/") { path += "/" }
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var requestHeaders: [String: String] {
        guard !username.isEmpty || !password.isEmpty,
              let data = "\(username):\(password)".data(using: .utf8) else { return [:] }
        return ["Authorization": "Basic " + data.base64EncodedString()]
    }

    func fileURL(path: String) -> URL? {
        url(for: path, isDirectory: false)
    }

    func folderURL(path: String) -> URL? {
        url(for: path, isDirectory: true)
    }

    private func url(for path: String, isDirectory: Bool) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let escaped = path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var encodedPath = components.percentEncodedPath
        if !encodedPath.hasSuffix("/") { encodedPath += "/" }
        encodedPath += escaped
        if isDirectory && !escaped.isEmpty && !encodedPath.hasSuffix("/") {
            encodedPath += "/"
        }
        components.percentEncodedPath = encodedPath
        return components.url
    }

    func list(path: String) async throws -> [CloudEntry] {
        guard let url = folderURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw WebDAVError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        switch http.statusCode {
        case 207:
            break
        case 401:
            throw WebDAVError.unauthorized
        case 403:
            throw WebDAVError.forbidden
        case 404:
            throw WebDAVError.notFound
        case 405, 501:
            throw WebDAVError.unsupported
        default:
            throw WebDAVError.status(http.statusCode)
        }

        let parsed = WebDAVMultistatusParser.parse(data)
        let basePath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let decodedBase = basePath.removingPercentEncoding ?? basePath
        let requestedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var entries: [CloudEntry] = []
        for item in parsed {
            guard !item.href.isEmpty else { continue }
            let encodedPath = URL(string: item.href)?.path(percentEncoded: true) ?? item.href
            let decoded = encodedPath.removingPercentEncoding ?? encodedPath
            var relative = decoded
            if relative.hasPrefix(decodedBase) {
                relative = String(relative.dropFirst(decodedBase.count))
            }
            relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty, relative != requestedPath else { continue }
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }

            let name = relative.split(separator: "/").last.map(String.init) ?? relative
            entries.append(CloudEntry(path: relative,
                                      name: name,
                                      isDirectory: item.isCollection,
                                      size: item.size,
                                      modifiedAt: item.modifiedAt,
                                      contentType: item.contentType))
        }
        return entries
    }

    func data(path: String) async throws -> Data {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response)
        return data
    }

    /// 只读取指定字节区间。partial 为 false 表示服务器忽略了 Range（或文件本身就比区间小）。
    func data(path: String, byteRange: ClosedRange<Int>) async throws -> (data: Data, partial: Bool) {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound)", forHTTPHeaderField: "Range")
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return (data, status == 206)
    }

    func download(path: String, to destination: URL) async throws {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (temp, response) = try await Self.session.download(for: request)
        try Self.validate(response)
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temp, to: destination)
    }

    // MARK: - 写操作

    func createFolder(path: String) async throws {
        guard let url = folderURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "MKCOL"
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let http = try await Self.perform(request)
        switch http.statusCode {
        case 200, 201:
            return
        case 405:
            throw WebDAVError.exists
        default:
            try Self.validate(http)
        }
    }

    func delete(path: String) async throws {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let http = try await Self.perform(request)
        switch http.statusCode {
        case 200, 202, 204:
            return
        default:
            try Self.validate(http)
        }
    }

    func move(from path: String, to destinationPath: String) async throws {
        guard let url = fileURL(path: path),
              let destination = fileURL(path: destinationPath) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "MOVE"
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let http = try await Self.perform(request)
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 412:
            throw WebDAVError.exists
        default:
            try Self.validate(http)
        }
    }

    func upload(path: String, from localURL: URL) async throws {
        guard let url = fileURL(path: path) else { throw WebDAVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await Self.session.upload(for: request, fromFile: localURL)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 412:
            throw WebDAVError.exists
        default:
            try Self.validate(http)
        }
    }

    private static func perform(_ request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        return http
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        switch http.statusCode {
        case 200, 206:
            return
        case 401:
            throw WebDAVError.unauthorized
        case 403:
            throw WebDAVError.forbidden
        case 404:
            throw WebDAVError.notFound
        default:
            throw WebDAVError.status(http.statusCode)
        }
    }

    private static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getlastmodified/>
            <D:getcontenttype/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8)

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

// MARK: - PROPFIND 解析

final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    struct Item {
        var href: String = ""
        var size: Int64 = 0
        var modifiedAt: Date?
        var contentType: String?
        var isCollection = false
    }

    private var items: [Item] = []
    private var current: Item?
    private var text = ""
    private var inResponse = false

    static func parse(_ data: Data) -> [Item] {
        let parser = WebDAVMultistatusParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        text = ""
        if name == "response" {
            inResponse = true
            current = Item()
        } else if name == "collection", inResponse {
            current?.isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        if inResponse, var item = current {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href":
                if item.href.isEmpty { item.href = value }
            case "getcontentlength":
                item.size = Int64(value) ?? 0
            case "getlastmodified":
                item.modifiedAt = Self.parseDate(value)
            case "getcontenttype":
                item.contentType = value.isEmpty ? nil : value
            case "response":
                items.append(item)
                current = nil
                inResponse = false
                text = ""
                return
            default:
                break
            }
            current = item
        }
        text = ""
    }

    private func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return dateFormatter.date(from: value)
    }
}
