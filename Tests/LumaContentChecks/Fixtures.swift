import Foundation
import LumaContentCore
import PlaybackCore

/// 多个检查文件共用的播放目标样本。
let liveTarget = PlaybackTarget(
    storage: .provider(sourceID: .television(UUID()), itemID: "cctv1", episodeID: nil),
    mode: .live,
    title: "CCTV-1"
)

let vodTarget = PlaybackTarget(
    storage: .localFile(path: "/tmp/a.mp4"),
    mode: .vod,
    title: "A"
)
