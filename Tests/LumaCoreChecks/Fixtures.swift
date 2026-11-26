import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func baseRequest(mode: StreamMode = .remux,
                 audioCodec: String? = "AC3",
                 burnSubtitleStream: Int? = nil,
                 audioPassthrough: Bool = true,
                 isRemote: Bool = false,
                 bufferProfile: BufferProfile = .smooth) -> StreamRequest {
    StreamRequest(input: "bluray:/Volumes/DISC",
                  isRemote: isRemote,
                  mode: mode,
                  startOffset: 0,
                  sessionStart: 0,
                  isHEVC: true,
                  isHDR: false,
                  supportsToneMapping: true,
                  supportsLibplacebo: true,
                  color: VideoColorInfo(),
                  sourceSize: CGSize(width: 1920, height: 1080),
                  frameRate: 23.976,
                  audioIndex: 0,
                  audioChannels: 6,
                  audioCodec: audioCodec,
                  audioPassthrough: audioPassthrough,
                  bufferProfile: bufferProfile,
                  burnSubtitle: nil,
                  burnSubtitleStream: burnSubtitleStream,
                  outputDirectory: URL(fileURLWithPath: "/tmp/out"))
}
