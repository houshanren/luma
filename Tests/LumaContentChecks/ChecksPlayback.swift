import Foundation
import LumaContentCore
import PlaybackCore
import TestSupport

@MainActor
func runPlaybackChecks() async {

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



    let unavailableRepository = UnavailableContentRepository(message: "暂无仓库")
    do {
        _ = try await unavailableRepository.page(ContentQuery())
        expect(false, "占位仓库应返回 unsupported")
    } catch let error as SourceError {
        expectEqual(error.kind, .unsupported, "占位仓库返回 unsupported")
    } catch {
        expect(false, "占位仓库返回了非 SourceError：\(error)")
    }

}
