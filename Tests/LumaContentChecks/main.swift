import Foundation
import LumaContentCore
import PlaybackCore

/// 内容契约层的最小断言集：`swift run LumaContentChecks`。
private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    expect(lhs == rhs, "\(message)（实际 \(lhs)，期望 \(rhs)）")
}

// MARK: - 源语义

expectEqual(SourceKind.library.defaultActivation, .replaceLibrarySession, "图库默认替换写入会话")
expectEqual(SourceKind.cloudMount.defaultActivation, .browseReadOnly, "云盘默认只读浏览")
expectEqual(SourceKind.iptv.defaultActivation, .browseReadOnly, "电视默认只读浏览")
expect(SourceKind.library.ownsWriteSession, "只有图库拥有写入会话")
expect(!SourceKind.localDisk.ownsWriteSession, "本地磁盘不默认拥有写入会话")

let activeLibrary = SourceDescriptor(
    id: .library("/tmp/A.photoslibrary"),
    kind: .library,
    name: "A",
    content: .library,
    write: .managedLibrary,
    sortIndex: 0
)
let linkedLibrary = SourceDescriptor(
    id: .linkedLibrary("/tmp/B.photoslibrary"),
    kind: .library,
    name: "B",
    content: .library,
    write: .readOnly,
    sortIndex: 10
)
let cloud = SourceDescriptor(
    id: .cloud(UUID()),
    kind: .cloudMount,
    name: "NAS",
    content: .cloud,
    sortIndex: 100
)

expect(activeLibrary.canWrite(.importMedia), "当前图库可导入")
expect(!linkedLibrary.canWrite(.importMedia), "非活动链接图库不可导入")
expect(!cloud.canWrite(.importMedia), "云盘不可写图库")
expect(cloud.can(.vodPlayback), "云盘支持点播")
expect(!cloud.can(.livePlayback), "云盘不支持直播")

var registry = SourceRegistryState(sources: [activeLibrary, linkedLibrary, cloud],
                                   activeLibraryID: activeLibrary.id,
                                   activeBrowseSourceID: activeLibrary.id)
expectEqual(registry.linkedLibraries.count, 1, "链接图库只统计非活动 library")
expectEqual(registry.linkedSources.count, 1, "只读源统计云盘 / 资源 / 影院 / 电视 / 磁盘")
expectEqual(registry.sources(of: .library).count, 2, "同一 kind 可包含当前库与链接库")

registry.browse(cloud.id)
expectEqual(registry.activeLibraryID, activeLibrary.id, "浏览云盘不改变当前图库")
expectEqual(registry.activeBrowseSourceID, cloud.id, "浏览云盘切换右侧内容源")

registry.browse(linkedLibrary.id)
expectEqual(registry.activeLibraryID, linkedLibrary.id, "点击链接图库替换当前图库")
expectEqual(registry.activeBrowseSourceID, linkedLibrary.id, "替换后浏览源跟随当前图库")

// MARK: - 内容能力与播放目标

expect(ContentCapabilities.television.contains(.epg), "电视带 EPG 能力")
expect(ContentCapabilities.television.contains(.livePlayback), "电视带直播能力")
expect(!ContentCapabilities.television.contains(.vodPlayback), "电视不以点播为主要能力")
expect(ContentCapabilities.library.contains(.photoAnalysis), "图库带照片分析能力")
expect(ContentCapabilities.catalog.contains(.categories), "资源带分类能力")

let liveTarget = PlaybackTarget(
    storage: .provider(sourceID: .television(UUID()), itemID: "cctv1", episodeID: nil),
    mode: .live,
    title: "CCTV-1"
)
expect(liveTarget.isLive, "直播目标标记为 live")
expect(!liveTarget.canSeek, "直播不可拖动进度")
expect(liveTarget.capabilities.contains(.liveEdge), "直播保留回到直播沿能力")
expect(!liveTarget.capabilities.contains(.resume), "直播不续播")

let vodTarget = PlaybackTarget(
    storage: .localFile(path: "/tmp/a.mp4"),
    mode: .vod,
    title: "A"
)
expect(vodTarget.canSeek, "点播可拖动")
expect(vodTarget.canResume, "点播可续播")
expect(vodTarget.hasNextEpisode, "点播默认有下一集能力")

// MARK: - 错误恢复

let authError = SourceError.unauthorized()
expect(authError.requiresReauthorization, "未授权错误要求重新登录")
expect(authError.recovery.contains(.reauthorize), "未授权错误提供重新登录动作")
let httpError = SourceError.http(403)
expect(httpError.statusCode == 403, "HTTP 错误保留状态码")
expect(httpError.recovery.contains(.reauthorize), "403 提供重新登录动作")

// MARK: - 任务中心

let center = SourceJobCenter()
let job = SourceJob(sourceID: cloud.id, kind: .scan, title: "扫描 NAS")
let jobID = center.begin(job)
expectEqual(center.progress[jobID]?.phase, .running, "任务开始后为 running")
center.update(jobID, completed: 40, total: 100)
expectEqual(center.progress[jobID]?.completed, 40, "任务进度可更新")
expectEqual(center.progress[jobID]?.fraction ?? 0, 0.4, "任务进度比例正确")
center.finish(jobID)
expectEqual(center.progress[jobID]?.phase, .finished, "任务完成后为 finished")
expectEqual(center.activeJobs(sourceID: cloud.id).count, 0, "完成后不再算活动任务")

// MARK: - 编解码

do {
    let data = try JSONEncoder().encode(registry)
    let decoded = try JSONDecoder().decode(SourceRegistryState.self, from: data)
    expectEqual(decoded.activeLibraryID, registry.activeLibraryID, "源目录可编解码")
    expectEqual(decoded.sources.count, registry.sources.count, "源目录条目数量保持")
} catch {
    expect(false, "源目录编解码失败：\(error)")
}

// MARK: - 播放协调器

let coordinator = PlaybackCoordinator(resolver: DirectPlaybackResolver())
do {
    let liveRemote = PlaybackTarget(
        storage: .remote(url: "https://example.com/live/index.m3u8",
                         profile: RequestProfile(userAgent: "Luma", referer: "https://example.com")),
        mode: .live,
        title: "频道"
    )
    let session = try await coordinator.prepare(liveRemote)
    expect(session.stream.isHLS, "远端 m3u8 识别为 HLS")
    expectEqual(session.mode, .live, "会话继承直播模式")
    expect(!session.canSeek, "直播会话不可拖动")
    expect(!session.canResume, "直播会话不续播")
    expectEqual(session.stream.headers["User-Agent"] ?? "", "Luma", "请求画像 UA 写入播放头")
    expectEqual(session.stream.headers["Referer"] ?? "", "https://example.com", "请求画像 Referer 写入播放头")
} catch {
    expect(false, "远端播放解析失败：\(error)")
}

let vodSession = coordinator.session(
    for: vodTarget,
    stream: ResolvedStream(url: URL(fileURLWithPath: "/tmp/a.mp4"), mode: .live)
)
expectEqual(vodSession.mode, .vod, "会话模式以 PlaybackTarget 为准")
expect(vodSession.canResume, "点播会话可续播")

do {
    _ = try await coordinator.prepare(liveTarget)
    expect(false, "未注册播放解析器的 provider 源应报不支持")
} catch {
    expect(error is SourceError, "provider 解析失败返回 SourceError")
}

// MARK: - 内容仓库占位

let unavailableRepository = UnavailableContentRepository(message: "暂无仓库")
do {
    _ = try await unavailableRepository.page(ContentQuery())
    expect(false, "占位仓库应返回 unsupported")
} catch let error as SourceError {
    expectEqual(error.kind, .unsupported, "占位仓库返回 unsupported")
} catch {
    expect(false, "占位仓库返回了非 SourceError：\(error)")
}

// MARK: - 源 ID 解析

let mountUUID = UUID()
expectEqual(SourceID.cloud(mountUUID).uuidValue, mountUUID, "云盘源 ID 可解析 UUID")
expectEqual(SourceID.mountCinema(mountUUID).uuidValue, mountUUID, "网盘影院源 ID 可解析 UUID")
expect(SourceID.catalogHub.uuidValue == nil, "聚合源没有 UUID")

// MARK: - HTTP 传输策略

let retryPolicy = HTTPRetryPolicy.default
expect(retryPolicy.shouldRetry(statusCode: 503), "5xx 可重试")
expect(retryPolicy.shouldRetry(statusCode: 429), "429 可重试")
expect(!retryPolicy.shouldRetry(statusCode: 403), "403 不重试")
expect(retryPolicy.shouldRetry(error: .unavailable("断网")), "网络不可达可重试")
expect(!retryPolicy.shouldRetry(error: .unauthorized()), "未授权不重试")
expect(retryPolicy.delay(afterAttempt: 2) > retryPolicy.delay(afterAttempt: 1), "重试间隔递增")

// MARK: - HTTP 传输（本地 Mock）

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

// MARK: - 快照与修订号

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

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}
print("\n全部检查通过")
