import Foundation
import Darwin

/// 边下载边转封装：ffmpeg 把远端（或本地）MKV 实时封成 fMP4 分片 HLS，
/// 由本机回环 HTTP 服务交给 AVPlayer。首段生成即可开播，不必等整部文件下载完。
/// 已完整转换过的结果留在图库 transcodes 目录，下次打开同一视频直接复用。
///
/// 网盘直链不走 ffmpeg 自带的 HTTP 客户端：改由 App 的 URLSession 下载后灌进 ffmpeg stdin，
/// 复用网盘已验证过的请求头、302 跟随与证书策略（夸克 / 百度的 CDN 对第三方客户端的限制较多）。
final class VideoStreamSession {
    /// 完整转换结果的缓存目录（只有带 EXT-X-ENDLIST 的播放列表才会放进来）。
    private let cacheDirectory: URL
    /// 本次播放独占的工作目录：避免同一视频的两个会话互删中间文件。
    private let workDirectory: URL
    private let source: URL
    private let headers: [String: String]
    /// 挂载点勾选了「信任自签名证书」：URLSession 需要放行 NAS 的自签名证书。
    private let trustSelfSigned: Bool
    private var process: Process?
    private var server: LocalHLSServer?
    private var pump: HTTPStreamPump?
    private var stdinHandle: FileHandle?
    private var logURL: URL?
    private let stateLock = NSLock()
    private var pumpFailure: String?
    /// 主动关闭会话时置位：ffmpeg 因收到 SIGTERM 退出属于预期行为，不再记录为转换失败。
    private var stopping = false
    /// 实际提供给播放器的目录：命中缓存时是缓存目录，否则是工作目录。
    private var servingDirectory: URL
    private var usesCache = false

    init(photoID: UUID, source: URL, headers: [String: String], trustSelfSigned: Bool = false) {
        let base = LibraryPaths.transcodes
        self.cacheDirectory = base.appendingPathComponent(photoID.uuidString + ".hls", isDirectory: true)
        self.workDirectory = base.appendingPathComponent(photoID.uuidString + "-" + UUID().uuidString + ".hls",
                                                         isDirectory: true)
        self.servingDirectory = workDirectory
        self.source = source
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
    }

    private var playlistPath: URL {
        servingDirectory.appendingPathComponent("live.m3u8")
    }

    /// 启动本地服务并返回可播放的 m3u8 地址；首次播放会等第一段分片就绪。
    func start() async throws -> URL {
        if Self.isComplete(cacheDirectory) {
            usesCache = true
            servingDirectory = cacheDirectory
        } else {
            // 上次中断留下的缓存不完整，清掉重新生成。
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: workDirectory)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        }

        let server = LocalHLSServer(directory: servingDirectory)
        let port = try server.start()
        self.server = server
        if !usesCache {
            try launch()
            try await waitForPlaylist()
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/live.m3u8") else {
            stop()
            throw VideoError.transcodeUnavailable
        }
        return url
    }

    func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
        if !usesCache, process != nil, !FileManager.default.fileExists(atPath: playlistPath.path) {
            Diagnostics.record("边下边播会话提前结束（首段未生成）")
        }
        pump?.cancel()
        pump = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process?.terminate()
        process = nil
        server?.stop()
        server = nil
        if let logURL {
            try? FileManager.default.removeItem(at: logURL)
            self.logURL = nil
        }
        guard !usesCache else { return }
        if Self.isComplete(workDirectory) {
            // 已经转完：整目录挪到缓存位置，下次直接回放。
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.moveItem(at: workDirectory, to: cacheDirectory)
        } else {
            // 没转完的中间产物留着也没法播，直接清掉。
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    // MARK: - 内部

    private static func isComplete(_ directory: URL) -> Bool {
        let playlist = directory.appendingPathComponent("live.m3u8")
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return false }
        return text.contains("#EXT-X-ENDLIST")
    }

    private func launch() throws {
        guard let ffmpeg = FFmpeg.executable else { throw VideoError.transcodeUnavailable }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        // 远端由 URLSession 喂 stdin；本地文件直接给路径。
        let isRemote = !source.isFileURL
        var arguments = ["-y", "-v", "error"]
        if !isRemote, !headers.isEmpty {
            arguments += ["-headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined()]
        }
        // 只看开头几个 MB 就足够判断流信息，缩短首段等待。
        arguments += ["-probesize", "4M",
                      "-analyzeduration", "4M",
                      "-i", isRemote ? "pipe:0" : source.path,
                      "-map", "0:v:0", "-map", "0:a:0?",
                      "-c:v", "copy",
                      "-c:a", "aac", "-b:a", "192k", "-ac", "2",
                      "-f", "hls",
                      "-hls_time", "2",
                      "-hls_init_time", "1",
                      "-hls_list_size", "0",
                      "-hls_playlist_type", "event",
                      "-hls_segment_type", "fmp4",
                      "-hls_fmp4_init_filename", "init.mp4",
                      "-hls_segment_filename", workDirectory.appendingPathComponent("seg%05d.m4s").path,
                      workDirectory.appendingPathComponent("live.m3u8").path]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardOutput = Pipe()
        // stderr 落到临时文件：失败时把最后几行写进诊断日志，便于定位 401 / 编码不支持。
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-ffmpeg-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardError = logHandle ?? Pipe()
        self.logURL = logURL

        var stdinHandle: FileHandle?
        if isRemote {
            let input = Pipe()
            // ffmpeg 提前退出时继续写管道会触发 SIGPIPE 直接杀进程。
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = input
            stdinHandle = input.fileHandleForWriting
        }
        self.stdinHandle = stdinHandle

        process.terminationHandler = { [weak self] finished in
            try? logHandle?.close()
            guard let self else { return }
            self.stateLock.lock()
            let intentional = self.stopping
            self.stateLock.unlock()
            guard !intentional,
                  finished.terminationReason == .exit,
                  finished.terminationStatus != 0 else { return }
            let tail = Self.tail(of: logURL)
            Diagnostics.record("边下边播转换异常结束 status=\(finished.terminationStatus)：\(tail)")
            self.recordPumpFailure(tail)
        }
        try process.run()
        self.process = process

        if isRemote, let stdinHandle {
            let pump = HTTPStreamPump(url: source,
                                      headers: headers,
                                      trustSelfSigned: trustSelfSigned,
                                      sink: stdinHandle) { [weak self] message in
                if let message { self?.recordPumpFailure(message) }
            }
            self.pump = pump
            pump.start()
        }
    }

    private func recordPumpFailure(_ message: String) {
        stateLock.lock()
        if pumpFailure == nil { pumpFailure = message }
        stateLock.unlock()
        Diagnostics.record("边下边播失败：\(message)")
    }

    private var currentPumpFailure: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pumpFailure
    }

    /// 等 ffmpeg 写出第一版播放列表（第一段分片完成后才会写）。
    /// 网盘限速时 4K 视频的首段可能要几十秒，这里每 5 秒记一次已写入字节，便于排查卡在下载还是卡在封装。
    private func waitForPlaylist() async throws {
        for index in 0..<1200 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: playlistPath.path) { return }
            if let process, !process.isRunning {
                let reason = currentPumpFailure ?? Self.tail(of: logURL)
                throw VideoError.transcodeFailedMessage(reason)
            }
            if index % 50 == 0 {
                let size = Self.directorySize(workDirectory)
                Diagnostics.record("边下边播等待首段：已写入 \(size / 1024) KB")
            }
            // 取消时直接抛出，避免 try? 吞掉 CancellationError 后空转。
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let size = Self.directorySize(workDirectory)
        let extra = currentPumpFailure.map { "：\($0)" } ?? ""
        throw VideoError.transcodeFailedMessage("等待首段超时，已写入 \(size / 1024 / 1024) MB\(extra)")
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return items.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    private static func tail(of url: URL?) -> String {
        guard let url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "无输出" }
        let lines = text.split(separator: "\n").suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.isEmpty ? "无输出" : lines.joined(separator: " | ")
    }
}

/// 用 App 的 URLSession 把网盘文件读出来，按块写进 ffmpeg 的 stdin。
/// 走 URLSession 可以复用请求头 / 302 跟随 / 自签名证书策略，并且天然带背压（管道写满即阻塞）。
private final class HTTPStreamPump: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let url: URL
    private let headers: [String: String]
    private let trustSelfSigned: Bool
    private let sink: FileHandle
    private let onFinish: (String?) -> Void
    private let queue = DispatchQueue(label: "luma.video.pump")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var closed = false
    private var validatedPayload = false

    init(url: URL, headers: [String: String], trustSelfSigned: Bool, sink: FileHandle,
         onFinish: @escaping (String?) -> Void) {
        self.url = url
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
        self.sink = sink
        self.onFinish = onFinish
        super.init()
    }

    func start() {
        queue.async {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 3600
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 1
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = self.queue
            let session = URLSession(configuration: configuration,
                                     delegate: self,
                                     delegateQueue: delegateQueue)
            self.session = session
            var request = URLRequest(url: self.url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 60)
            for (key, value) in self.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        queue.async {
            self.task?.cancel()
            self.session?.invalidateAndCancel()
            self.finish(nil)
        }
    }

    // MARK: - URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish("网盘没有返回有效响应")
            return
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
        let length = http.value(forHTTPHeaderField: "Content-Length") ?? "-"
        let decodedPath = url.path.removingPercentEncoding ?? url.path
        Diagnostics.record("边下边播请求 host=\(url.host ?? "-"):\(url.port.map(String.init) ?? "-") "
                           + "path=\(decodedPath) status=\(http.statusCode) type=\(type) length=\(length)")
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish("网盘返回 HTTP \(http.statusCode)")
            return
        }
        let lowered = type.lowercased()
        if lowered.contains("text/html") || lowered.contains("application/json") {
            completionHandler(.cancel)
            finish("网盘返回的是网页/JSON（HTTP \(http.statusCode)），可能鉴权失败或路径不存在")
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !closed else { return }
        if !validatedPayload {
            validatedPayload = true
            guard Self.looksLikeMedia(data) else {
                let preview = String(data: data.prefix(160), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                finish("网盘返回的数据不是视频（开头：\(preview)）")
                return
            }
        }
        do {
            try sink.write(contentsOf: data)
        } catch {
            finish("写入本地管道失败：\(error.localizedDescription)")
        }
    }

    /// 只认常见的视频容器魔数，避免把登录页 / 错误页当成视频喂给 ffmpeg。
    private static func looksLikeMedia(_ data: Data) -> Bool {
        guard data.count >= 8 else { return true }
        let prefix = [UInt8](data.prefix(12))
        if prefix.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return true }          // Matroska / WebM
        if prefix.count >= 8,
           String(bytes: prefix[4..<8], encoding: .ascii) == "ftyp" { return true } // MP4 / MOV
        if prefix[0] == 0x47 { return true }                                       // MPEG-TS
        if String(bytes: prefix.prefix(4), encoding: .ascii) == "RIFF" { return true } // AVI
        if String(bytes: prefix.prefix(3), encoding: .ascii) == "FLV" { return true }
        return false
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            finish("读取网盘数据失败：\(error.localizedDescription)")
        } else {
            finish(nil)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        for (key, value) in headers {
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
    }

    /// NAS 常是自签名证书：只有挂载点明确勾选「信任自签名证书」时才放行。
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        acceptSelfSigned(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        acceptSelfSigned(challenge, completionHandler)
    }

    private func acceptSelfSigned(_ challenge: URLAuthenticationChallenge,
                                  _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard trustSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: - 收尾

    private func finish(_ message: String?) {
        guard !closed else { return }
        closed = true
        try? sink.close()
        session?.finishTasksAndInvalidate()
        session = nil
        onFinish(message)
    }
}
