import Foundation
import PlaybackCore

/// 把现有本地 / 云盘 / 网络资源三种片源收敛成一个解析入口。
/// 播放器只消费 `ResolvedStream`，后续影院在线源与电视直播源在这里追加即可。
extension LibraryStore {
    func resolvePlaybackStream(for photo: PhotoItem) async throws -> ResolvedStream {
        // 网络资源：按虚拟分集取当前集的播放直链。
        if let context = catalogPlaybackContext(for: photo.id) {
            let stream = try await catalog.stream(source: context.source, episode: context.episode)
            return ResolvedStream(url: stream.url,
                                  headers: stream.headers,
                                  isHLS: stream.isHLS,
                                  mode: .vod)
        }

        // 云盘：官方转码可能返回 HLS，其他情况返回直链或代理地址。
        if photo.isCloud {
            let stream = try await cloudStreamOrThrow(for: photo)
            let mount = cloudMount(for: photo.cloudMountID)
            return ResolvedStream(url: stream.url,
                                  headers: stream.headers,
                                  isHLS: stream.isHLS,
                                  mode: .vod,
                                  trustSelfSigned: mount?.trustSelfSigned ?? false)
        }

        // 本地文件：图库 originals / 外置路径。
        return ResolvedStream(url: LibraryPaths.sourceURL(for: photo),
                              headers: [:],
                              isHLS: false,
                              mode: .vod)
    }
}
