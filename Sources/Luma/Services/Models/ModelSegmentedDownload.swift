import Foundation

/// 分片并发下载。
///
/// 跨境链路上单连接通常只有几十 KB/s，把一个文件切成若干段同时拉，
/// 多源时再按段轮换，带宽可以叠加到 1 MB/s 以上。
/// 分片文件留在 `.segs` 目录里，失败 / 取消后重试能从已下载的字节继续。
///
/// 注意：URLSession 的数据回调只能由「带 delegate 的 session」收到。
/// 之前用无 delegate 的共享 session 建 `dataTask`，回调永远不触发，
/// 表现就是进度一直 0%、磁盘上一个字节都没有。
final class SegmentedDownload: NSObject {
    enum Failure: LocalizedError {
        case rangeUnsupported
        case sizeMismatch
        case segmentFailed(Int)

        var errorDescription: String? {
            switch self {
            case .rangeUnsupported: return "下载源不支持分段下载"
            case .sizeMismatch: return "下载文件大小与清单不一致"
            case .segmentFailed(let index): return "第 \(index + 1) 段多次重试仍失败"
            }
        }
    }

    /// 同时并发的分片数：再多对跨境链路收益有限，反而更容易被限流。
    static let maxSegments = 12
    /// 单段最小体积，避免小文件切得太碎。
    private static let minSegmentBytes: Int64 = 3 << 20

    private final class Segment {
        let index: Int
        let start: Int64
        let end: Int64
        let fileURL: URL
        var existing: Int64
        var sourceIndex: Int
        var attempts = 0
        var task: URLSessionDataTask?
        var handle: FileHandle?
        var done = false

        var expectedLength: Int64 { end - start + 1 }

        init(index: Int, start: Int64, end: Int64, fileURL: URL, existing: Int64, sourceIndex: Int) {
            self.index = index
            self.start = start
            self.end = end
            self.fileURL = fileURL
            self.existing = existing
            self.sourceIndex = sourceIndex
        }
    }

    private let sources: [URL]
    private let destination: URL
    private let expectedSize: Int64
    private let workDir: URL
    private let configuration: URLSessionConfiguration
    private let progress: (Int64, Int64) -> Void
    private let completion: (Result<Void, Error>) -> Void

    private var session: URLSession!
    private var segments: [Segment] = []
    private var segmentsByTask: [Int: Segment] = [:]
    private var received: Int64 = 0
    private var completedCount = 0
    private var finished = false
    private var cancelled = false

    init?(sources: [URL],
          destination: URL,
          expectedSize: Int64,
          configuration: URLSessionConfiguration,
          workDir: URL,
          progress: @escaping (Int64, Int64) -> Void,
          completion: @escaping (Result<Void, Error>) -> Void) {
        guard expectedSize > 0, !sources.isEmpty else { return nil }
        self.sources = sources
        self.destination = destination
        self.expectedSize = expectedSize
        self.configuration = configuration
        self.workDir = workDir
        self.progress = progress
        self.completion = completion
        super.init()
        // 复制一份配置再抬高单主机并发数：默认 6 条，12 个分片会被排成两轮。
        let config = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        config.httpMaximumConnectionsPerHost = Self.maxSegments
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - 启动

    func start() {
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            finish(.failure(error))
            return
        }

        let count = min(Self.maxSegments,
                        max(1, Int(expectedSize / Self.minSegmentBytes)))
        let length = expectedSize / Int64(count)
        for index in 0..<count {
            let start = Int64(index) * length
            let end = index == count - 1 ? expectedSize - 1 : start + length - 1
            let url = workDir.appendingPathComponent("seg-\(index)")
            let existing = min(Self.fileSize(url), end - start + 1)
            let segment = Segment(index: index,
                                  start: start,
                                  end: end,
                                  fileURL: url,
                                  existing: existing,
                                  sourceIndex: index % sources.count)
            segments.append(segment)
            received += existing
        }
        progress(min(received, expectedSize), expectedSize)

        for segment in segments {
            if segment.existing == segment.expectedLength {
                complete(segment)
            } else {
                launch(segment)
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        for segment in segments {
            segment.task?.cancel()
            segment.task = nil
            try? segment.handle?.close()
            segment.handle = nil
        }
        session.invalidateAndCancel()
        finish(.failure(URLError(.cancelled)))
    }

    // MARK: - 单个分片

    private func launch(_ segment: Segment) {
        guard !finished, !cancelled else { return }
        let source = sources[segment.sourceIndex % sources.count]
        var request = URLRequest(url: source)
        // 已经下过的字节直接用 Range 续上；不同源的内容一致，可以跨源续传。
        let from = segment.start + segment.existing
        request.setValue("bytes=\(from)-\(segment.end)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60

        let task = session.dataTask(with: request)
        segment.task = task
        segmentsByTask[task.taskIdentifier] = segment
        task.resume()
    }

    private func segment(for task: URLSessionTask) -> Segment? {
        segmentsByTask[task.taskIdentifier]
    }

    private func finishSegment(_ segment: Segment, _ result: Result<Void, Error>) {
        guard !segment.done else { return }
        segment.task = nil
        try? segment.handle?.close()
        segment.handle = nil
        segmentsByTask = segmentsByTask.filter { $0.value !== segment }

        guard !finished, !cancelled else { return }
        switch result {
        case .success:
            if segment.existing == segment.expectedLength {
                complete(segment)
            } else if segment.existing > segment.expectedLength {
                finish(.failure(Failure.sizeMismatch))
            } else {
                retry(segment)
            }
        case .failure(let error):
            if case Failure.rangeUnsupported = error {
                // 源忽略了 Range，分段写入会错位：整段作废，交给单连接兜底。
                finish(.failure(error))
            } else {
                retry(segment)
            }
        }
    }

    private func retry(_ segment: Segment) {
        segment.attempts += 1
        guard segment.attempts <= max(4, sources.count * 3) else {
            finish(.failure(Failure.segmentFailed(segment.index)))
            return
        }
        // 换下一个源，并从已写入的字节继续。
        segment.sourceIndex += 1
        launch(segment)
    }

    private func complete(_ segment: Segment) {
        guard !segment.done else { return }
        segment.done = true
        completedCount += 1
        guard completedCount == segments.count else { return }
        assemble()
    }

    // MARK: - 合并与收尾

    private func assemble() {
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw Failure.sizeMismatch
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            for segment in segments.sorted(by: { $0.index < $1.index }) {
                let input = try FileHandle(forReadingFrom: segment.fileURL)
                defer { try? input.close() }
                while true {
                    let chunk = try input.read(upToCount: 4 << 20) ?? Data()
                    if chunk.isEmpty { break }
                    try output.write(contentsOf: chunk)
                }
            }
            guard Self.fileSize(destination) == expectedSize else {
                try? fileManager.removeItem(at: destination)
                throw Failure.sizeMismatch
            }
            for segment in segments {
                try? fileManager.removeItem(at: segment.fileURL)
            }
            try? fileManager.removeItem(at: workDir)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        for segment in segments {
            segment.task?.cancel()
            segment.task = nil
            try? segment.handle?.close()
            segment.handle = nil
        }
        session.invalidateAndCancel()
        completion(result)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

// MARK: - 数据回调

extension SegmentedDownload: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let segment = segment(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            finishSegment(segment, .failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            break
        case 200:
            finishSegment(segment, .failure(Failure.rangeUnsupported))
            completionHandler(.cancel)
            return
        case 416:
            // 请求的区间已经在文件里（之前下完了）。
            finishSegment(segment, .success(()))
            completionHandler(.cancel)
            return
        default:
            finishSegment(segment, .failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: segment.fileURL.path) {
            fileManager.createFile(atPath: segment.fileURL.path, contents: nil)
        }
        segment.handle = try? FileHandle(forWritingTo: segment.fileURL)
        segment.handle?.seekToEndOfFile()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let segment = segment(for: dataTask) else { return }
        guard let handle = segment.handle else { return }
        try? handle.write(contentsOf: data)
        segment.existing += Int64(data.count)
        received = min(expectedSize, received + Int64(data.count))
        progress(received, expectedSize)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let segment = segment(for: task) else { return }
        if let error {
            finishSegment(segment, .failure(error))
        } else {
            finishSegment(segment, .success(()))
        }
    }
}
