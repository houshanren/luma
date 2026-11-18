import Foundation
import Darwin

/// 仅监听 127.0.0.1 的极简静态文件服务：把 ffmpeg 边写边生成的 HLS 目录交给 AVPlayer。
/// AVPlayer 无法直接读取自定义 scheme 的 HLS，但可以正常播放本机回环地址上的 m3u8。
/// 这里直接用 BSD socket：Network.framework 的 NWListener 在部分系统上创建会失败。
final class LocalHLSServer {
    private let directory: URL
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0

    init(directory: URL) {
        self.directory = directory
    }

    /// 绑定 127.0.0.1 的随机端口并启动接收线程。
    func start() throws -> UInt16 {
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
        lock.lock()
        listenFD = fd
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return port
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    // MARK: - 接收

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return }
            request.append(buffer, count: count)
            if request.count > 128 * 1024 { return }
        }
        let head = String(decoding: request, as: UTF8.self)
        let response = makeResponse(for: head)
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    // MARK: - 响应

    private func makeResponse(for head: String) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else {
            return Self.build(status: "400 Bad Request", body: Data(), contentType: "text/plain")
        }
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.contains(".."),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            return Self.build(status: "404 Not Found", body: Data(), contentType: "text/plain")
        }

        let isPlaylist = name.hasSuffix(".m3u8")
        var body = data
        var status = "200 OK"
        var extra: [String] = []
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = rangeLine.split(separator: "=").last {
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds.first ?? "0") ?? 0
            let requestedEnd = bounds.count > 1 ? Int(bounds[1]) : nil
            let upper = min(requestedEnd ?? (data.count - 1), data.count - 1)
            if start >= 0, start <= upper, start < data.count {
                body = data.subdata(in: start..<(upper + 1))
                status = "206 Partial Content"
                extra.append("Content-Range: bytes \(start)-\(upper)/\(data.count)")
            }
        }
        return Self.build(status: status,
                          body: body,
                          contentType: isPlaylist ? "application/vnd.apple.mpegurl" : "video/mp4",
                          noCache: isPlaylist,
                          extra: extra)
    }

    private static func build(status: String, body: Data, contentType: String,
                              noCache: Bool = false, extra: [String] = []) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Connection: close\r\n"
        if noCache { header += "Cache-Control: no-cache, no-store\r\n" }
        for line in extra { header += line + "\r\n" }
        header += "\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        return packet
    }
}
