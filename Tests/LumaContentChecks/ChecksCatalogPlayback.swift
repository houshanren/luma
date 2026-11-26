import Foundation
import LumaContentCore
import PlaybackCore
import TestSupport

/// 网络资源（站点影视源）的播放契约：目标映射、适配器解析、请求画像与续看进度。
/// 站点 HTML 解析仍属于适配器层；这里覆盖播放链路的公共语义。

private final class StubCatalogResolver: PlaybackResolving, @unchecked Sendable {
    var received: [PlaybackTarget] = []

    func resolve(_ target: PlaybackTarget) async throws -> ResolvedStream {
        received.append(target)
        return ResolvedStream(url: URL(string: "https://cdn.example/ep3/index.m3u8")!,
                              headers: ["Referer": "https://site.example"],
                              isHLS: true,
                              mode: target.mode)
    }
}

@MainActor
func runCatalogPlaybackChecks() async {
    let sourceUUID = UUID()
    let sourceID = SourceID.catalog(sourceUUID)
    expectEqual(sourceID.uuidValue, sourceUUID, "资源源 ID 可解析 UUID")
    expectEqual(sourceID.rawValue, "catalog:\(sourceUUID.uuidString)", "资源源 ID 命名空间")

    let itemID = "SSIS-001"
    let target = PlaybackTarget(
        storage: .provider(sourceID: sourceID, itemID: itemID, episodeID: "3"),
        mode: .vod,
        title: "示例影片",
        artworkURL: "https://cdn.example/cover.jpg"
    )
    expectEqual(target.capabilities, .vod, "资源播放默认点播能力")
    expect(target.canSeek && target.canResume && target.hasNextEpisode,
           "点播资源可拖动 / 续播 / 连播")
    expect(!target.isLive, "资源播放不是直播")

    expect(ContentCapabilities.catalog.contains([.categories, .homeFeed, .pagination,
                                                 .search, .vodPlayback, .artwork]),
           "资源能力覆盖分类 / 首页 / 分页 / 搜索 / 点播 / 封面")
    expect(!ContentCapabilities.catalog.contains(.livePlayback), "资源没有直播能力")
    expect(!ContentCapabilities.catalog.contains(.browseTree), "资源不是树状浏览")
    expect(!ContentCapabilities.catalog.contains(.photoAnalysis), "资源不做照片分析")

    let resolver = StubCatalogResolver()
    let coordinator = PlaybackCoordinator(resolver: resolver)
    do {
        let resolved = try await coordinator.prepare(target)
        expectEqual(resolved.mode, .vod, "适配器返回的流不改变点播模式")
        expect(resolved.canSeek && resolved.canResume, "解析后仍可拖动 / 续播")
        expect(!resolved.isLive, "解析后不是直播")
        expect(resolved.stream.isHLS, "资源直链识别为 HLS")
        expectEqual(resolved.stream.headers["Referer"] ?? "", "https://site.example",
                    "资源请求头随流保留")
        expectEqual(resolver.received.count, 1, "解析器只收到一次请求")
        if case .provider(let resolvedSource, let resolvedItem, let resolvedEpisode) =
            resolved.target.storage {
            expectEqual(resolvedSource, sourceID, "解析目标保留资源源")
            expectEqual(resolvedItem, itemID, "解析目标保留条目")
            expectEqual(resolvedEpisode, Optional("3"), "解析目标保留集号")
        } else {
            expect(false, "资源播放目标应保留 provider 存储")
        }
    } catch {
        expect(false, "资源播放解析失败：\(error)")
    }

    do {
        _ = try await DirectPlaybackResolver().resolve(target)
        expect(false, "未注册解析器时资源目标应报不支持")
    } catch let error as SourceError {
        expectEqual(error.kind, .unsupported, "资源缺少解析器返回 unsupported")
        expect(error.message.contains(itemID), "错误信息带上条目 ID")
        expect(error.message.contains("/3"), "错误信息带上集号")
    } catch {
        expect(false, "资源目标返回了非 SourceError：\(error)")
    }

    let profile = RequestProfile(userAgent: "LumaSite",
                                 referer: "https://site.example",
                                 headers: ["Referer": "https://cdn.example", "Cookie": "sid=1"],
                                 trustSelfSigned: true)
    let fields = profile.headerFields
    expectEqual(fields["User-Agent"] ?? "", "LumaSite", "请求画像写入 UA")
    expectEqual(fields["Referer"] ?? "", "https://site.example", "请求画像 Referer 覆盖自定义头")
    expectEqual(fields["Cookie"] ?? "", "sid=1", "其它自定义头保留")
    expect(profile.trustSelfSigned, "请求画像保留自签证书策略")

    let progress = PlaybackProgress(sourceID: sourceID, itemID: itemID, episodeID: "3",
                                    position: 30, duration: 100)
    expectEqual(progress.id, "\(sourceID.rawValue)#\(itemID)#3", "续看记录按源 / 条目 / 集号定位")
    expectClose(CGFloat(progress.fraction), 0.3, accuracy: 0.0001, "续看进度比例")
    expect(!progress.isFinished, "播放中不算看完")

    let nearEnd = PlaybackProgress(sourceID: sourceID, itemID: itemID, episodeID: "3",
                                   position: 95, duration: 100)
    expect(nearEnd.isFinished, "片尾 8 秒内视为看完")
    let overrun = PlaybackProgress(sourceID: sourceID, itemID: itemID, episodeID: "3",
                                   position: 130, duration: 100)
    expectClose(CGFloat(overrun.fraction), 1, accuracy: 0.0001, "进度上限夹到 1")
    let unknownDuration = PlaybackProgress(sourceID: sourceID, itemID: itemID, episodeID: "3",
                                           position: 10, duration: 0)
    expectEqual(unknownDuration.fraction, 0, "时长未知时进度为 0")
    expect(!unknownDuration.isFinished, "时长未知时不算看完")
}
