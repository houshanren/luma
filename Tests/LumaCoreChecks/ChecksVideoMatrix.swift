import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func runVideoMatrixChecks() {

    // `Tools/media_matrix.py` 的 COPYABLE_AUDIO 与内核白名单必须同源：
    // 矩阵里「remux + 音轨 copy」的结论依赖这份集合，任一边漂移都会让实测失效。
    expectEqual(AudioPlaybackPlan.copyableCodecs, Set(["aac", "alac", "ac3", "eac3"]),
                "可直通音轨白名单与媒体矩阵工具一致")

    // 21 组样片覆盖的音轨：能直通的拷贝，DTS / TrueHD 转 E-AC-3，其余转 AAC。
    let audioMatrix: [(codec: String, channels: Int, action: AudioTrackAction)] = [
        ("aac", 2, .copy),
        ("aac", 6, .copy),
        ("ac3", 6, .copy),
        ("eac3", 6, .copy),
        ("alac", 2, .copy),
        ("dts", 6, .eac3),
        ("mlp", 6, .eac3),
        ("truehd", 8, .eac3),
        ("flac", 6, .aac),
        ("opus", 6, .aac),
        ("mp3", 2, .aac),
        ("pcm_s16le", 2, .aac)
    ]
    for item in audioMatrix {
        expectEqual(AudioPlaybackPlan.action(codec: item.codec,
                                             channels: item.channels,
                                             downmix: .source,
                                             allowPassthrough: true,
                                             copiesVideo: true),
                    item.action,
                    "\(item.codec) \(item.channels)ch 的音轨策略")
    }
    expectEqual(AudioPlaybackPlan.action(codec: "AC3", channels: 6, downmix: .stereo,
                                         allowPassthrough: true, copiesVideo: true), .aac,
                "强制立体声时 AC-3 5.1 不能拷贝")
    expectEqual(AudioPlaybackPlan.action(codec: "AC3", channels: 6, downmix: .source,
                                         allowPassthrough: false, copiesVideo: true), .aac,
                "直通兜底会话一律重编码")
    expectEqual(AudioPlaybackPlan.action(codec: "AC3", channels: 6, downmix: .source,
                                         allowPassthrough: true, copiesVideo: false), .aac,
                "视频重编码时音轨策略仍按拷贝语义判定")
    expectEqual(AudioPlaybackPlan.aacBitrate(channels: 6, downmix: .source), "512k",
                "多声道 AAC 目标 512k")
    expectEqual(AudioPlaybackPlan.aacBitrate(channels: 2, downmix: .source), "256k",
                "立体声 AAC 目标 256k")
    expectEqual(AudioPlaybackPlan.aacBitrate(channels: 6, downmix: .stereo), "256k",
                "下混立体声后降到 256k")

    // 矩阵第 18 / 19 条：hev1 的 HEVC MP4 探测 isPlayable=false 但实际可播；
    // 第 20 / 21 条 hvc1 正常；第 14 条 ProRes MOV 原生可播。
    expect(VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                           codec: "HEVC", containerExtension: "m4v"),
           "hev1 HEVC M4V 放宽原生直读")
    expect(VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                           codec: "HEVC", containerExtension: "mov"),
           "hev1 HEVC MOV 放宽原生直读")
    expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                            codec: "HEVC", containerExtension: "ts"),
           "HEVC TS 不放宽原生直读")
    expect(VideoProbe.allowsNativePlayback(assetIsPlayable: true, hasVideoTrack: true,
                                           codec: "ProRes", containerExtension: "mov"),
           "ProRes MOV 原生可播")

    func makeVideoProbe(codec: String = "HEVC",
                        width: CGFloat, height: CGFloat, fps: Double) -> VideoProbe {
        var probe = VideoProbe()
        probe.hasVideoTrack = true
        probe.codec = codec
        probe.isHEVC = codec == "HEVC"
        probe.size = CGSize(width: width, height: height)
        probe.frameRate = fps
        return probe
    }
    expect(makeVideoProbe(width: 3840, height: 2160, fps: 60).requiresRecodeForHighFrameRate4K,
           "4K60 HEVC 直接重编码")
    expect(makeVideoProbe(width: 2560, height: 1440, fps: 50).requiresRecodeForHighFrameRate4K,
           "1440p50 HEVC 也直接重编码")
    expect(!makeVideoProbe(width: 3840, height: 2160, fps: 24).requiresRecodeForHighFrameRate4K,
           "4K24 HEVC 仍可转封装")
    expect(!makeVideoProbe(codec: "H.264", width: 3840, height: 2160, fps: 60)
        .requiresRecodeForHighFrameRate4K, "H.264 4K60 不套用 HEVC 规则")
    expect(!makeVideoProbe(width: 1280, height: 720, fps: 60).requiresRecodeForHighFrameRate4K,
           "720p60 HEVC 不重编码")

    // 第 04 条：H.264 MKV + AC-3 5.1 → 转封装，视频与音频都拷贝。
    var h264MKV = baseRequest()
    h264MKV.isHEVC = false
    let h264MKVArgs = StreamPlanner.arguments(for: h264MKV).joined(separator: " ")
    expect(h264MKVArgs.contains("-c:v copy"), "H.264 MKV 视频拷贝")
    expect(!h264MKVArgs.contains("-tag:v hvc1"), "H.264 不写 HEVC 标签")
    expect(h264MKVArgs.contains("-c:a copy"), "AC-3 5.1 音轨拷进 fMP4 HLS")
    expect(h264MKVArgs.contains("-hls_segment_type fmp4"), "输出 fMP4 分片")
    expect(h264MKVArgs.contains("init.mp4") && h264MKVArgs.contains("seg%05d.m4s"),
           "单音轨分片命名")
    expect(h264MKVArgs.contains("-hls_time 2") && h264MKVArgs.contains("-hls_init_time 0.5"),
           "2 秒切片 + 0.5 秒首片")
    expect(h264MKVArgs.contains("-hls_playlist_type event")
           && h264MKVArgs.contains("-hls_flags temp_file"),
           "点播事件列表 + 临时文件改名")
    expect(h264MKVArgs.contains("-max_muxing_queue_size 2048"), "放宽 mux 队列")
    expect(h264MKVArgs.contains("-map 0:a:0?"), "单音轨按 audioIndex 映射")

    // 第 07 条：HEVC 转封装必须显式写 hvc1，AVFoundation 不认 hev1。
    let hevcMKVArgs = StreamPlanner.arguments(for: baseRequest()).joined(separator: " ")
    expect(hevcMKVArgs.contains("-tag:v hvc1"), "HEVC 转封装写 hvc1 标签")

    // 第 06 / 07 条：DTS / TrueHD 家族转 E-AC-3 1536k。
    for codec in ["DTS", "MLP", "TrueHD"] {
        let joined = StreamPlanner.arguments(for: baseRequest(audioCodec: codec)).joined(separator: " ")
        expect(joined.contains("-c:a eac3") && joined.contains("-b:a 1536k")
               && joined.contains("-ac 6"),
               "\(codec) 5.1 转 E-AC-3 1536k / 6 声道")
    }

    // 第 08 / 10 / 13 条：FLAC / Opus / MP3 / PCM 一律转 AAC，码率按声道数分档。
    expect(StreamPlanner.arguments(for: baseRequest(audioCodec: "FLAC")).joined(separator: " ")
        .contains("-b:a 512k"), "FLAC 5.1 转 AAC 512k")
    expect(StreamPlanner.arguments(for: baseRequest(audioCodec: "OPUS")).joined(separator: " ")
        .contains("-b:a 512k"), "Opus 5.1 转 AAC 512k")
    var mp3Matrix = baseRequest(audioCodec: "mp3")
    mp3Matrix.audioChannels = 2
    expect(StreamPlanner.arguments(for: mp3Matrix).joined(separator: " ").contains("-b:a 256k"),
           "MP3 立体声转 AAC 256k")
    var pcmMatrix = baseRequest(audioCodec: "PCM")
    pcmMatrix.audioChannels = 2
    expect(StreamPlanner.arguments(for: pcmMatrix).joined(separator: " ").contains("-b:a 256k"),
           "PCM 立体声转 AAC 256k")

    // 第 10 / 11 / 12 / 13 条：AV1 / VP9 / MPEG-2 隔行 / MPEG-4 只能重编码。
    var av1Transcode = baseRequest(mode: .transcode, audioCodec: "OPUS")
    av1Transcode.isHEVC = false
    let av1ArgList = StreamPlanner.arguments(for: av1Transcode)
    let av1Args = av1ArgList.joined(separator: " ")
    expect(av1Args.contains("-c:v h264_videotoolbox"), "非原生编码转 H.264")
    expect(!av1Args.contains("-c:v copy"), "重编码不能拷贝视频")
    expect(av1Args.contains("-hwaccel videotoolbox"), "重编码先接硬件解码")
    if let hardware = av1ArgList.firstIndex(of: "-hwaccel"),
       let input = av1ArgList.firstIndex(of: "-i") {
        expect(hardware < input, "硬件解码参数在 -i 之前")
    }
    expect(av1Args.contains("-pix_fmt yuv420p"), "H.264 输出 8-bit")
    expect(av1Args.contains("-c:a aac"), "Opus 音轨重编码为 AAC")

    // 第 09 / 08 条：HDR10 转封装把色彩标记写回容器；HDR 退回单音轨避免 -12927。
    var hdrRemux = baseRequest(audioCodec: "AC3")
    hdrRemux.isHDR = true
    hdrRemux.color = VideoColorInfo(primaries: "bt2020", transfer: "smpte2084",
                                    matrix: "bt2020nc", range: "tv", isHDR: true)
    let hdrRemuxJoined = StreamPlanner.arguments(for: hdrRemux).joined(separator: " ")
    expect(hdrRemuxJoined.contains("-color_primaries bt2020"), "HDR 写回色域")
    expect(hdrRemuxJoined.contains("-color_trc smpte2084"), "HDR 写回传输特性")
    expect(hdrRemuxJoined.contains("-colorspace bt2020nc"), "HDR 写回矩阵")
    expect(hdrRemuxJoined.contains("-color_range tv"), "HDR 写回量化范围")
    expect(hdrRemuxJoined.contains("-c:a copy"), "HDR 下 AC-3 仍可直通")
    expect(!hdrRemuxJoined.contains("-var_stream_map"), "HDR 不用多音轨 master")

    var hdrFlac = baseRequest(audioCodec: "FLAC")
    hdrFlac.isHDR = true
    hdrFlac.color = hdrRemux.color
    let hdrFlacJoined = StreamPlanner.arguments(for: hdrFlac).joined(separator: " ")
    expect(hdrFlacJoined.contains("-c:a aac") && hdrFlacJoined.contains("-b:a 512k"),
           "HDR + FLAC 5.1 转 AAC 512k")

    // 第 19 / 21 条：4K60 需要像素率降档 + libplacebo 映射；1080p 只映射不缩放。
    var toneMap4K = baseRequest(mode: .transcode)
    toneMap4K.isHDR = true
    toneMap4K.supportsToneMapping = true
    toneMap4K.supportsLibplacebo = true
    toneMap4K.color = hdrRemux.color
    toneMap4K.sourceSize = CGSize(width: 3840, height: 2160)
    toneMap4K.frameRate = 60
    let toneMap4KJoined = StreamPlanner.arguments(for: toneMap4K).joined(separator: " ")
    expect(toneMap4KJoined.contains("-b:v 12000000"), "4K60 HDR 降到 1440p 档位")
    expect(toneMap4KJoined.contains("w=2560") && toneMap4KJoined.contains("h=1440"),
           "libplacebo 链内联降档尺寸")
    expect(toneMap4KJoined.contains("-color_primaries bt709"), "映射后写回 bt709")

    var toneMap1080 = toneMap4K
    toneMap1080.sourceSize = CGSize(width: 1920, height: 1080)
    toneMap1080.frameRate = 24
    let toneMap1080Joined = StreamPlanner.arguments(for: toneMap1080).joined(separator: " ")
    expect(toneMap1080Joined.contains("-b:v 8000000"), "1080p HDR 保持 1080p 档位")
    expect(!toneMap1080Joined.contains("w=2560"), "1080p 不需要降档尺寸")

    // HDR 屏保留 HDR：强制 HEVC 10bit，写回 HDR 色彩标记，不烘 SDR。
    var keepHDR = baseRequest(mode: .transcode)
    keepHDR.isHDR = true
    keepHDR.preserveHDR = true
    keepHDR.transcodeMode = .compatibility
    let keepHDRJoined = StreamPlanner.arguments(for: keepHDR).joined(separator: " ")
    expect(keepHDRJoined.contains("-c:v hevc_videotoolbox"), "保留 HDR 必须 HEVC 编码")
    expect(keepHDRJoined.contains("-profile:v main10") && keepHDRJoined.contains("-pix_fmt p010le"),
           "保留 HDR 输出 10-bit")
    expect(keepHDRJoined.contains("format=p010le"), "滤镜链统一 10-bit 帧")
    expect(keepHDRJoined.contains("-color_primaries bt2020")
           && keepHDRJoined.contains("-color_trc smpte2084")
           && keepHDRJoined.contains("-colorspace bt2020nc")
           && keepHDRJoined.contains("-color_range tv"),
           "缺失色彩标记时补 HDR10 默认值")
    expect(!keepHDRJoined.contains("libplacebo="), "保留 HDR 不做色调映射")

    // 杜比视界不能走「保留 HDR」：必须由 libplacebo 应用 RPU。
    var keepDV = keepHDR
    keepDV.supportsToneMapping = true
    keepDV.supportsLibplacebo = true
    keepDV.color = VideoColorInfo(primaries: "bt2020", transfer: "smpte2084",
                                  matrix: "bt2020nc", range: "tv", codecTag: "dvh1",
                                  isHDR: true, isDolbyVision: true)
    let keepDVJoined = StreamPlanner.arguments(for: keepDV).joined(separator: " ")
    expect(keepDVJoined.contains("libplacebo="), "杜比视界走 libplacebo 映射")
    expect(keepDVJoined.contains("-color_primaries bt709"), "杜比视界映射后输出 bt709")
    expect(!keepDVJoined.contains("-c:v hevc_videotoolbox"), "杜比视界保留 HDR 分支不生效")

    // 烧录 PGS：按源分辨率合成，不做降档，否则字幕位置会错。
    var pgs4K = baseRequest(mode: .transcode, burnSubtitleStream: 1)
    pgs4K.sourceSize = CGSize(width: 3840, height: 2160)
    pgs4K.frameRate = 60
    let pgs4KJoined = StreamPlanner.arguments(for: pgs4K).joined(separator: " ")
    expect(pgs4KJoined.contains("-b:v 20000000"), "烧录字幕时保持源分辨率码率")
    expect(!pgs4KJoined.contains("scale=-2:1440"), "烧录字幕不做分辨率降档")
    expect(pgs4KJoined.contains("-canvas_size 3840x2160"), "字幕画布按源尺寸")
    expect(pgs4KJoined.contains("overlay=format=auto:eof_action=pass"), "图形字幕叠加在图面上")

    // 音频延迟只能靠滤镜：必须重编码，不能用 -c:a copy。
    var delayedAudio = baseRequest(audioCodec: "AC3")
    delayedAudio.audioDelay = 0.5
    let delayedJoined = StreamPlanner.arguments(for: delayedAudio).joined(separator: " ")
    expect(delayedJoined.contains("-af adelay=delays=500:all=1"), "正延迟补静音")
    expect(delayedJoined.contains("-c:a aac") && !delayedJoined.contains("-c:a copy"),
           "有延迟时音轨必须重编码")
    var advancedAudio = baseRequest(audioCodec: "AC3")
    advancedAudio.audioDelay = -0.25
    expect(StreamPlanner.arguments(for: advancedAudio).joined(separator: " ")
        .contains("atrim=start=0.250,asetpts=PTS-STARTPTS"), "负延迟裁掉开头")

    // 第 16 条：多音轨会话的分片命名与 master。
    var multiTrack = baseRequest()
    multiTrack.audioTracks = [
        AudioTrackInfo(ordinal: 0, codec: "AAC", channels: 6, language: "eng", title: nil),
        AudioTrackInfo(ordinal: 1, codec: "AC3", channels: 6, language: "jpn", title: nil)
    ]
    let multiTrackJoined = StreamPlanner.arguments(for: multiTrack).joined(separator: " ")
    expect(multiTrackJoined.contains("init_%v.mp4")
           && multiTrackJoined.contains("seg_%v_%05d.m4s"),
           "多音轨分片按 %v 隔离")
    expect(multiTrackJoined.contains("master.m3u8")
           && multiTrackJoined.contains("live_%v.m3u8"),
           "多音轨输出 master 与各自 media playlist")

    // 直播：不限速、滑动窗口、透传请求头，断流自动重连。
    var liveRequest = baseRequest(mode: .remux, audioCodec: "AAC")
    liveRequest.isRemote = true
    liveRequest.isLive = true
    liveRequest.input = "https://example.com/live/index.m3u8"
    liveRequest.headers = ["User-Agent": "LumaTV", "Referer": "https://ref.example"]
    let liveJoined = StreamPlanner.arguments(for: liveRequest).joined(separator: " ")
    expect(!liveJoined.contains("-readrate"), "直播不做生成限速")
    expect(liveJoined.contains("-user_agent LumaTV"), "直播透传 User-Agent")
    expect(liveJoined.contains("Referer: https://ref.example"), "直播透传 Referer")
    expect(!liveJoined.contains("User-Agent: LumaTV"), "UA 不重复写进 -headers")
    expect(liveJoined.contains("-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"),
           "直播断流自动重连")
    expect(liveJoined.contains("-hls_list_size 6"), "直播只保留 6 段滑动窗口")
    expect(liveJoined.contains("-hls_flags delete_segments+temp_file"), "直播滑出窗口后删除旧段")
    expect(!liveJoined.contains("-hls_playlist_type"), "直播不使用 event 列表")
    expect(liveJoined.contains("live.m3u8"), "直播输出单 media playlist")

    // seek：转封装用请求值，重编码用关键帧对齐后的落点；无 seek 时不写时间参数。
    var transcodeSeek = baseRequest(mode: .transcode)
    transcodeSeek.startOffset = 300
    transcodeSeek.sessionStart = 297
    let transcodeSeekArgList = StreamPlanner.arguments(for: transcodeSeek)
    let transcodeSeekJoined = transcodeSeekArgList.joined(separator: " ")
    expect(transcodeSeekJoined.contains("-ss 297.000"), "重编码按对齐后的落点起流")
    expect(!transcodeSeekJoined.contains("-noaccurate_seek"),
           "重编码不需要关闭精确 seek")
    expect(transcodeSeekJoined.contains("-avoid_negative_ts make_zero"),
           "落点前的负时间戳统一平移")
    if let seekIndex = transcodeSeekArgList.firstIndex(of: "-ss"),
       let inputIndex = transcodeSeekArgList.firstIndex(of: "-i") {
        expect(seekIndex < inputIndex, "-ss 是输入选项，必须在 -i 之前")
    }
    let noSeekJoined = StreamPlanner.arguments(for: baseRequest(mode: .transcode))
        .joined(separator: " ")
    expect(!noSeekJoined.contains("-ss "), "从片头起流不写 -ss")
    expect(!noSeekJoined.contains("-avoid_negative_ts"), "没有 seek 不需要平移时间戳")

    // 单音轨序号：音轨菜单切换后重建会话时按 audioIndex 映射。
    var selectedTrack = baseRequest()
    selectedTrack.audioIndex = 2
    expect(StreamPlanner.arguments(for: selectedTrack).joined(separator: " ")
        .contains("-map 0:a:2?"), "单音轨按 audioIndex 映射")

}
