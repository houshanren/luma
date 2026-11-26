import Foundation
import LumaContentCore
import PlaybackCore
import TestSupport

@MainActor
func runTransportChecks() async {

    let retryPolicy = HTTPRetryPolicy.default
    expect(retryPolicy.shouldRetry(statusCode: 503), "5xx 可重试")
    expect(retryPolicy.shouldRetry(statusCode: 429), "429 可重试")
    expect(!retryPolicy.shouldRetry(statusCode: 403), "403 不重试")
    expect(retryPolicy.shouldRetry(error: .unavailable("断网")), "网络不可达可重试")
    expect(!retryPolicy.shouldRetry(error: .unauthorized()), "未授权不重试")
    expect(retryPolicy.delay(afterAttempt: 2) > retryPolicy.delay(afterAttempt: 1), "重试间隔递增")



    /// 拦截 URLSession，验证请求头合并、重试与非 2xx 行为，不访问真实网络。
    final class MockURLProtocol: URLProtocol {
        struct Stub {
            var status: Int
            var body: Data
            var headers: [String: String] = [:]
        }

        private static let lock = NSLock()
        private static var stubs: [Stub] = []
        private static var requests: [URLRequest] = []

        static func reset(_ newStubs: [Stub]) {
            lock.lock()
            stubs = newStubs
            requests = []
            lock.unlock()
        }

        static var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }

        static var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests.last
        }

        static func nextStub(_ request: URLRequest) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            if stubs.count > 1 { return stubs.removeFirst() }
            return stubs.first
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let stub = Self.nextStub(request), let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = HTTPURLResponse(url: url,
                                           statusCode: stub.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    let testTransport = HTTPSourceTransport(protocolClasses: [MockURLProtocol.self])
    let testURL = URL(string: "https://example.com/page")!

    MockURLProtocol.reset([.init(status: 200, body: Data("ok".utf8))])
    do {
        let response = try await testTransport.send(
            HTTPTransportRequest(url: testURL, headers: ["X-Extra": "1"]),
            profile: RequestProfile(userAgent: "LumaTest",
                                    referer: "https://ref.example",
                                    headers: ["Accept-Language": "zh-CN"]),
            retryPolicy: .none
        )
        expectEqual(response.statusCode, 200, "Mock 请求返回 200")
        expectEqual(response.text ?? "", "ok", "Mock 响应正文正确")
        let headers = MockURLProtocol.lastRequest?.allHTTPHeaderFields ?? [:]
        expectEqual(headers["User-Agent"] ?? "", "LumaTest", "RequestProfile UA 生效")
        expectEqual(headers["Referer"] ?? "", "https://ref.example", "RequestProfile Referer 生效")
        expectEqual(headers["X-Extra"] ?? "", "1", "请求级额外头生效")
        expectEqual(headers["Accept-Language"] ?? "", "zh-CN", "Profile 自定义头生效")
    } catch {
        expect(false, "Mock 请求失败：\(error)")
    }

    MockURLProtocol.reset([.init(status: 500, body: Data()),
                           .init(status: 200, body: Data("retried".utf8))])
    do {
        let response = try await testTransport.send(
            HTTPTransportRequest(url: testURL),
            retryPolicy: HTTPRetryPolicy(maxRetries: 1, baseDelay: 0)
        )
        expectEqual(response.statusCode, 200, "5xx 重试后成功")
        expectEqual(response.text ?? "", "retried", "重试返回第二次响应")
        expectEqual(MockURLProtocol.requestCount, 2, "5xx 只重试一次")
    } catch {
        expect(false, "5xx 重试失败：\(error)")
    }

    MockURLProtocol.reset([.init(status: 403, body: Data("verify".utf8))])
    do {
        _ = try await testTransport.send(HTTPTransportRequest(url: testURL),
                                         retryPolicy: HTTPRetryPolicy(maxRetries: 3, baseDelay: 0))
        expect(false, "403 应抛出 SourceError")
    } catch let error as SourceError {
        expectEqual(error.kind, .http, "403 映射为 HTTP 错误")
        expectEqual(error.statusCode ?? 0, 403, "403 状态码保留")
        expectEqual(MockURLProtocol.requestCount, 1, "403 不重试")
    } catch {
        expect(false, "403 返回了非 SourceError：\(error)")
    }

    MockURLProtocol.reset([.init(status: 403, body: Data("verify".utf8))])
    do {
        let response = try await testTransport.send(
            HTTPTransportRequest(url: testURL, throwsOnHTTPError: false),
            retryPolicy: .none
        )
        expectEqual(response.statusCode, 403, "保留验证页状态码")
        expectEqual(response.text ?? "", "verify", "保留验证页正文")
    } catch {
        expect(false, "非抛出模式失败：\(error)")
    }



    let snapshotDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("luma-snapshot-check-\(UUID().uuidString)", isDirectory: true)
    let snapshotSource = SourceID.television(UUID())
    let snapshotPage = ContentPage(
        items: [ContentCard(ref: ContentRef(sourceID: snapshotSource, itemID: "cctv1"),
                            title: "CCTV-1")],
        next: PageCursor(page: 2),
        totalHint: 10
    )
    let snapshotStore = FileContentSnapshotStore(directory: snapshotDirectory)
    snapshotStore.save(ContentPageSnapshot(sourceID: snapshotSource, page: snapshotPage))
    expectEqual(snapshotStore.count, 1, "快照保存成功")

    let reloadedSnapshotStore = FileContentSnapshotStore(directory: snapshotDirectory)
    expectEqual(reloadedSnapshotStore.snapshot(sourceID: snapshotSource,
                                               containerID: nil,
                                               search: nil)?.page.items.count ?? 0,
                1,
                "快照可跨实例读取")

    snapshotStore.save(ContentPageSnapshot(sourceID: snapshotSource,
                                           search: "新闻",
                                           page: ContentPage()))
    expectEqual(snapshotStore.count, 2, "不同搜索条件的快照独立存储")
    expectEqual(snapshotStore.prune(olderThan: 3600, keeping: 1), 1, "快照按数量裁剪")
    expectEqual(snapshotStore.count, 1, "裁剪后只保留一条")
    try? FileManager.default.removeItem(at: snapshotDirectory)

    let revisions = SourceRevisionTracker()
    expectEqual(revisions.revision(for: snapshotSource).value, 0, "修订号从 0 开始")
    _ = revisions.bump(snapshotSource)
    expectEqual(revisions.revision(for: snapshotSource).value, 1, "修订号可自增")
    revisions.reset(snapshotSource)
    expectEqual(revisions.revision(for: snapshotSource).value, 0, "修订号可重置")

}
