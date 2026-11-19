import Foundation
import Darwin

/// 把网盘远端文件代理成本机可 Range 读取的 HTTP 源。
///
/// 之前的做法是用 URLSession 顺序拉流灌进 ffmpeg stdin，整部片子只能从头读；
/// 这里改成本机回环 HTTP 服务：ffmpeg 需要哪个字节区间就取哪个区间，
/// 顺带把下过的 8MB 分块留在本地缓存里，回退 / 重读不必再走网络。
/// 请求头、302 跟随、自签名证书策略仍由 App 的 URLSession 统一处理。
final class RemoteRangeSource {
    private enum UpstreamMode {
        /// 上游支持 Range，并给出文件总长度。
        case ranged(Int64)
        /// 上游忽略 Range（或长度未知）：只能从头顺序转发。
        case sequential
    }

    private var upstream: URL
    private var headers: [String: String]
    private let trustSelfSigned: Bool
    private let cacheDirectory: URL
    /// 分块大小：太小会放大请求数，太大首段等待变长。
    private let chunkSize: Int64 = 8 * 1024 * 1024
    /// 单次响应上限：避免 ffmpeg 发 `bytes=0-` 时一次性读进几十 GB。
    private let maxResponseBytes: Int64 = 16 * 1024 * 1024
    /// 只保留最近若干块，避免把整部影片（几十 GB）落在磁盘上。
    private let retainedChunks: Int64 = 8

    private let downloadQueue = DispatchQueue(label: "luma.remote.range.download")
    private let resolveLock = NSLock()
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var session: URLSession?
    private var resolvedMode: UpstreamMode?
    private var cachedContentType: String?
    private var completedChunks = Set<Int64>()
    private var failure: String?
    private var closed = false

    private(set) var port: UInt16 = 0
    /// 网络 / 鉴权层失败：调用方据此判断"不是编码问题，别再尝试转码兜底"。
    var onFailure: ((String) -> Void)?
    /// 云盘直链过期时重新解析地址（返回新的 URL 与请求头）。
    var onAuthFailure: (() -> (URL, [String: String])?)?

    init(upstream: URL, headers: [String: String], trustSelfSigned: Bool, cacheDirectory: URL) {
        self.upstream = upstream
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
        self.cacheDirectory = cacheDirectory
    }

    deinit {
        stop()
    }

    /// 绑定 127.0.0.1 的随机端口，返回可直接交给 ffmpeg 的地址。
    func start() throws -> URL {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let delegate = SessionBehaviour(headers: headers, trustSelfSigned: trustSelfSigned)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VideoError.transcodeUnavailable }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw VideoError.transcodeUnavailable
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        stateLock.lock()
        listenFD = fd
        stateLock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        guard let url = URL(string: "http://127.0.0.1:\(port)/stream") else {
            throw VideoError.transcodeUnavailable
        }
        return url
    }

    func stop() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func record(_ message: String) {
        stateLock.lock()
        if failure == nil { failure = message }
        stateLock.unlock()
        onFailure?(message)
    }

    // MARK: - 接收

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenFD
            stateLock.unlock()
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        // 客户端提前断开时不要用 SIGPIPE 杀掉整个进程。
        var noPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe,
                   socklen_t(MemoryLayout<Int32>.size))

        guard let head = readRequest(client) else {
            close(client)
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            send(client, status: "400 Bad Request", headers: [:], body: Data())
            close(client)
            return
        }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(client, status: "405 Method Not Allowed", headers: [:], body: Data())
            close(client)
            return
        }
        guard let mode = resolveUpstream() else {
            send(client, status: "502 Bad Gateway", headers: [:], body: Data())
            close(client)
            return
        }

        switch mode {
        case .sequential:
            if method == "HEAD" {
                send(client, status: "200 OK",
                     headers: ["Content-Type": contentType(), "Accept-Ranges": "none"],
                     body: Data())
                close(client)
            } else {
                // 连接所有权交给转发器，由它在结束时关闭。
                forwardSequentially(client)
            }
        case .ranged(let total):
            let rangeLine = lines.first { $0.lowercased().hasPrefix("range:") }
            if method == "HEAD" {
                send(client, status: "200 OK",
                     headers: ["Content-Type": contentType(),
                               "Content-Length": "\(total)",
                               "Accept-Ranges": "bytes"],
                     body: Data())
                close(client)
                return
            }
            let requested = Self.parseRange(rangeLine)
            let start = requested?.start ?? 0
            guard start < total else {
                send(client, status: "416 Range Not Satisfiable", headers: [:], body: Data())
                close(client)
                return
            }
            // 客户端给了明确终点：一次返回这一段（单次上限 16MB）。
            if let end = requested?.end {
                let upper = min(end, total - 1, start + maxResponseBytes - 1)
                guard let data = readChunks(from: start, to: upper, total: total) else {
                    send(client, status: "502 Bad Gateway", headers: [:], body: Data())
                    close(client)
                    return
                }
                send(client, status: "206 Partial Content",
                     headers: ["Content-Type": contentType(),
                               "Content-Length": "\(data.count)",
                               "Accept-Ranges": "bytes",
                               "Content-Range": "bytes \(start)-\(upper)/\(total)"],
                     body: data)
                close(client)
                return
            }
            // 开放式请求（bytes=X- 或未带 Range）：按 Content-Length 流式写完剩余全部内容，
            // 不能只回一小段，否则 ffmpeg 会把 16MB 处当文件结尾。
            let remaining = total - start
            var header = "HTTP/1.1 \(requested == nil ? "200 OK" : "206 Partial Content")\r\n"
            header += "Content-Type: \(contentType())\r\n"
            header += "Content-Length: \(remaining)\r\n"
            header += "Accept-Ranges: bytes\r\n"
            if requested != nil {
                header += "Content-Range: bytes \(start)-\(total - 1)/\(total)\r\n"
            }
            header += "Connection: close\r\n\r\n"
            guard writeAll(client, Data(header.utf8)) else {
                close(client)
                return
            }
            let ok = streamChunks(to: client, from: start, to: total - 1, total: total)
            if !ok {
                Diagnostics.record("网盘分段流中断：\(start)-\(total - 1)")
            }
            close(client)
        }
    }

    private func readRequest(_ client: Int32) -> String? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return nil }
            request.append(buffer, count: count)
            if request.count > 64 * 1024 { return nil }
        }
        return String(decoding: request, as: UTF8.self)
    }

    private func send(_ client: Int32, status: String, headers: [String: String], body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { header += "\(key): \(value)\r\n" }
        header += "Connection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        _ = writeAll(client, packet)
    }

    @discardableResult
    private func writeAll(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private func contentType() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedContentType ?? "application/octet-stream"
    }

    // MARK: - 上游元数据

    private func resolveUpstream() -> UpstreamMode? {
        resolveLock.lock()
        defer { resolveLock.unlock() }
        if let resolvedMode { return resolvedMode }

        // 先用 HEAD 拿元数据：不要对有 Range 的请求直接 GET，否则上游忽略 Range 时会把整部片子拉下来。
        var response = probe(method: "HEAD", range: nil)
        if response == nil || !(200...299).contains(response?.statusCode ?? 0) {
            // 少数网盘不支持 HEAD（405/403）：只探测 2 个字节，拿到响应头就取消，不下载正文。
            response = probe(method: "GET", range: 0...1)
        }
        guard let response else {
            record("网盘没有返回有效响应")
            return nil
        }
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("text/html") || type.contains("application/json") {
            record("网盘返回的是网页/JSON（HTTP \(response.statusCode)），可能鉴权失败或路径不存在")
            return nil
        }
        guard (200...299).contains(response.statusCode) else {
            record("网盘返回 HTTP \(response.statusCode)")
            return nil
        }

        var mode: UpstreamMode = .sequential
        let acceptsRange = (response.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) }) {
            mode = .ranged(total)
        } else if response.statusCode == 206,
                  let text = response.value(forHTTPHeaderField: "Content-Length"),
                  let total = Int64(text) {
            // 206 但没有 Content-Range：总长度不可靠，退化为顺序转发。
            mode = total > 0 ? .ranged(total) : .sequential
        } else if acceptsRange,
                  let text = response.value(forHTTPHeaderField: "Content-Length"),
                  let total = Int64(text), total > 0 {
            mode = .ranged(total)
        } else if let text = response.value(forHTTPHeaderField: "Content-Length"),
                  let total = Int64(text), total > 0 {
            // HEAD 没声明 Accept-Ranges 不代表不支持：用 2 字节的 Range 请求验证一次。
            if let verify = probe(method: "GET", range: 0...1), verify.statusCode == 206 {
                mode = .ranged(total)
            }
        }

        stateLock.lock()
        resolvedMode = mode
        cachedContentType = response.value(forHTTPHeaderField: "Content-Type")
        stateLock.unlock()
        return mode
    }

    /// 只拿响应头，不读取正文：用于 HEAD / Range 能力探测。
    private func probe(method: String, range: ClosedRange<Int64>?,
                       allowRefresh: Bool = true) -> HTTPURLResponse? {
        guard let session else { return nil }
        let (url, headerFields) = credentials()
        var request = URLRequest(url: url)
        for (key, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",
                             forHTTPHeaderField: "Range")
        }
        request.httpMethod = method
        let delegate = ProbeDelegate(headers: headerFields, trustSelfSigned: trustSelfSigned)
        let probeSession = URLSession(configuration: session.configuration,
                                      delegate: delegate, delegateQueue: nil)
        let task = probeSession.dataTask(with: request)
        task.resume()
        let finished = delegate.semaphore.wait(timeout: .now() + 20) != .timedOut
        task.cancel()
        probeSession.invalidateAndCancel()
        let response = finished ? delegate.response : nil
        if allowRefresh, let status = response?.statusCode, status == 401 || status == 403,
           refreshCredentials() {
            Diagnostics.record("网盘地址已过期（HTTP \(status)），重新解析后重试")
            return probe(method: method, range: range, allowRefresh: false)
        }
        return response
    }

    private func credentials() -> (URL, [String: String]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (upstream, headers)
    }

    private func refreshCredentials() -> Bool {
        guard let refreshed = onAuthFailure?() else { return false }
        stateLock.lock()
        upstream = refreshed.0
        headers = refreshed.1
        stateLock.unlock()
        return true
    }

    /// 取一段字节。上游对 Range 请求返回 200 时立即取消，避免整文件下载。
    private func fetch(range: ClosedRange<Int64>, timeout: TimeInterval,
                       allowRefresh: Bool = true) -> (Data, HTTPURLResponse)? {
        guard let session else { return nil }
        let (url, headerFields) = credentials()
        var request = URLRequest(url: url)
        for (key, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",
                         forHTTPHeaderField: "Range")
        let delegate = ChunkDataDelegate(headers: headerFields, trustSelfSigned: trustSelfSigned)
        let fetchSession = URLSession(configuration: session.configuration,
                                      delegate: delegate, delegateQueue: nil)
        let task = fetchSession.dataTask(with: request)
        task.resume()
        let finished = delegate.semaphore.wait(timeout: .now() + timeout) != .timedOut
        if !finished { task.cancel() }
        fetchSession.finishTasksAndInvalidate()
        guard finished, delegate.failure == nil,
              let response = delegate.response,
              response.statusCode == 206,
              !delegate.payload.isEmpty else {
            let status = delegate.response?.statusCode
            if allowRefresh, let status, status == 401 || status == 403, refreshCredentials() {
                Diagnostics.record("网盘地址已过期（HTTP \(status)），重新解析后重试分块")
                return fetch(range: range, timeout: timeout, allowRefresh: false)
            }
            if let message = delegate.failure {
                record(message)
            } else if finished {
                record("网盘未按 Range 返回数据")
            } else {
                record("读取网盘数据超时")
            }
            return nil
        }
        return (delegate.payload, response)
    }

    /// 返回请求起点与可选终点；终点为 nil 表示开放式请求（bytes=X-）。
    private static func parseRange(_ line: String?) -> (start: Int64, end: Int64?)? {
        guard let line, let spec = line.split(separator: "=").last else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int64(bounds.first ?? "0"), start >= 0 else { return nil }
        let end = bounds.count > 1 ? Int64(bounds[1]) : nil
        return (start, end)
    }

    // MARK: - 分块缓存

    private func chunkFile(_ index: Int64) -> URL {
        cacheDirectory.appendingPathComponent("\(index).chunk")
    }

    private func ensureChunk(_ index: Int64, total: Int64) -> Bool {
        downloadQueue.sync { downloadChunk(index, total: total) }
    }

    /// 必须在 downloadQueue 上调用。
    private func downloadChunk(_ index: Int64, total: Int64) -> Bool {
        stateLock.lock()
        let already = completedChunks.contains(index)
        let isClosed = closed
        stateLock.unlock()
        if isClosed { return false }
        if already { return true }
        if FileManager.default.fileExists(atPath: chunkFile(index).path) {
            stateLock.lock()
            completedChunks.insert(index)
            stateLock.unlock()
            return true
        }
        let start = index * chunkSize
        let end = min(start + chunkSize - 1, total - 1)
        guard let (data, _) = fetch(range: start...end, timeout: 120), !data.isEmpty else {
            return false
        }
        do {
            try data.write(to: chunkFile(index), options: .atomic)
        } catch {
            record("写入分块缓存失败：\(error.localizedDescription)")
            return false
        }
        stateLock.lock()
        completedChunks.insert(index)
        let stale = completedChunks.filter { $0 < index - retainedChunks }
        for old in stale {
            completedChunks.remove(old)
            try? FileManager.default.removeItem(at: chunkFile(old))
        }
        stateLock.unlock()
        return !closed
    }

    /// 预取下一块：顺序播放时不必等请求到达才开始下载。
    private func prefetch(_ index: Int64, total: Int64) {
        guard index * chunkSize < total else { return }
        downloadQueue.async { [weak self] in
            _ = self?.downloadChunk(index, total: total)
        }
    }

    /// 边取边写：开放式请求体量可能几十 GB，不能先读进内存。
    private func streamChunks(to client: Int32, from lower: Int64, to upper: Int64,
                              total: Int64) -> Bool {
        let firstIndex = lower / chunkSize
        let lastIndex = upper / chunkSize
        for index in firstIndex...lastIndex {
            guard ensureChunk(index, total: total) else { return false }
            let chunkStart = index * chunkSize
            let from = max(lower, chunkStart) - chunkStart
            let to = min(upper, chunkStart + chunkSize - 1) - chunkStart
            let wrote: Bool = {
                guard let handle = try? FileHandle(forReadingFrom: chunkFile(index)) else { return false }
                defer { try? handle.close() }
                if from > 0 { try? handle.seek(toOffset: UInt64(from)) }
                var remaining = Int(to - from + 1)
                while remaining > 0 {
                    let slice = min(remaining, 512 * 1024)
                    guard let data = try? handle.read(upToCount: slice), !data.isEmpty else { return false }
                    guard writeAll(client, data) else { return false }
                    remaining -= data.count
                }
                return true
            }()
            guard wrote else { return false }
            prefetch(index + 1, total: total)
        }
        return true
    }

    private func readChunks(from lower: Int64, to upper: Int64, total: Int64) -> Data? {
        let clampedUpper = min(upper, total - 1)
        guard lower <= clampedUpper else { return nil }
        let firstIndex = lower / chunkSize
        let lastIndex = clampedUpper / chunkSize
        var output = Data()
        output.reserveCapacity(Int(min(clampedUpper - lower + 1, maxResponseBytes)))
        for index in firstIndex...lastIndex {
            guard ensureChunk(index, total: total) else { return nil }
            let chunkStart = index * chunkSize
            let from = max(lower, chunkStart) - chunkStart
            let to = min(clampedUpper, chunkStart + chunkSize - 1) - chunkStart
            guard let handle = try? FileHandle(forReadingFrom: chunkFile(index)) else { return nil }
            defer { try? handle.close() }
            if from > 0 { try? handle.seek(toOffset: UInt64(from)) }
            let length = Int(to - from + 1)
            if let data = try? handle.read(upToCount: length) {
                output.append(data)
            }
        }
        prefetch(lastIndex + 1, total: total)
        return output
    }

    // MARK: - 无 Range 时的顺序转发

    private func forwardSequentially(_ client: Int32) {
        guard let session else {
            close(client)
            return
        }
        let (url, headerFields) = credentials()
        var request = URLRequest(url: url)
        for (key, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let delegate = ForwardDelegate(client: client, headers: headerFields,
                                       trustSelfSigned: trustSelfSigned)
        let forwardSession = URLSession(configuration: session.configuration,
                                        delegate: delegate, delegateQueue: nil)
        delegate.session = forwardSession
        forwardSession.dataTask(with: request).resume()
    }
}

// MARK: - URLSession 委托

/// 公共的会话行为：302 时重新带上鉴权头，按挂载设置放行自签名证书。
private class SessionBehaviour: NSObject, URLSessionTaskDelegate {
    let headers: [String: String]
    let trustSelfSigned: Bool

    init(headers: [String: String], trustSelfSigned: Bool) {
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        for (key, value) in headers {
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
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

/// 只取响应头：一拿到响应就取消，避免触发整文件下载。
private final class ProbeDelegate: SessionBehaviour, URLSessionDataDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    private(set) var response: HTTPURLResponse?
    private var signalled = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.cancel)
        signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        signal()
    }

    private func signal() {
        guard !signalled else { return }
        signalled = true
        semaphore.signal()
    }
}

/// 接收一段 Range 数据；上游返回 200（忽略 Range）时立即取消。
private final class ChunkDataDelegate: SessionBehaviour, URLSessionDataDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    private(set) var response: HTTPURLResponse?
    private(set) var payload = Data()
    private(set) var failure: String?
    private var signalled = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = "网盘没有返回有效响应"
            completionHandler(.cancel)
            signal()
            return
        }
        self.response = http
        guard http.statusCode == 206 else {
            failure = "网盘未按 Range 返回数据（HTTP \(http.statusCode)）"
            completionHandler(.cancel)
            signal()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        payload.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        signal()
    }

    private func signal() {
        guard !signalled else { return }
        signalled = true
        semaphore.signal()
    }
}

/// 上游忽略 Range 时，按 200 顺序把数据转发给 ffmpeg。
private final class ForwardDelegate: SessionBehaviour, URLSessionDataDelegate {
    private let client: Int32
    private var sentHeader = false
    private var finished = false
    var session: URLSession?

    init(client: Int32, headers: [String: String], trustSelfSigned: Bool) {
        self.client = client
        super.init(headers: headers, trustSelfSigned: trustSelfSigned)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish()
            return
        }
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")\r\n"
        header += "Connection: close\r\n\r\n"
        write(Data(header.utf8))
        sentHeader = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, sentHeader else { return }
        write(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard sent > 0 else {
                    finished = true
                    return
                }
                offset += sent
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        close(client)
    }
}
