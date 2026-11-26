import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func runVideoPlanningChecks() {

    let uhd24 = TranscodeProfile.make(sourceSize: CGSize(width: 3840, height: 2160), frameRate: 23.976)
    expect(uhd24.outputSize == nil, "4K24 像素率够低，保持原分辨率")
    expectEqual(uhd24.bitrate, 20_000_000, "4K 档位码率 20M")

    let uhd60 = TranscodeProfile.make(sourceSize: CGSize(width: 3840, height: 2160), frameRate: 60)
    expectEqual(uhd60.outputSize, CGSize(width: 2560, height: 1440), "4K60 降到 1440p")
    expectEqual(uhd60.bitrate, 12_000_000, "1440p 档位码率 12M")

    let scope60 = TranscodeProfile.make(sourceSize: CGSize(width: 3840, height: 1608), frameRate: 60)
    expectEqual(scope60.outputSize, CGSize(width: 2866, height: 1200), "4K 宽银幕 60fps 降到 1200p")

    let hd60 = TranscodeProfile.make(sourceSize: CGSize(width: 1920, height: 1080), frameRate: 60)
    expect(hd60.outputSize == nil, "1080p60 不降档")
    expectEqual(hd60.bitrate, 8_000_000, "1080p 档位码率 8M")

    expectEqual(TranscodeProfile.make(sourceSize: .zero, frameRate: 60).bitrate, 8_000_000,
                "尺寸未知时退到 1080p 档位")



    let scaledChain = PlaybackFilters.toneMapChain(dolbyVision: true, supportsLibplacebo: true,
                                                   outputWidth: 2560, outputHeight: 1440) ?? ""
    expect(scaledChain.contains("w=2560") && scaledChain.contains("h=1440"),
           "libplacebo 链内联输出尺寸")
    expect(scaledChain.contains("apply_dolbyvision=1"), "libplacebo 链应用 DOVI RPU")
    expect(PlaybackFilters.toneMapChain(dolbyVision: true, supportsLibplacebo: false) == nil,
           "杜比视界没有 libplacebo 时返回 nil，不烘错颜色")
    let zscaleChain = PlaybackFilters.toneMapChain(dolbyVision: false, supportsLibplacebo: false,
                                                   outputHeight: 1440) ?? ""
    expect(zscaleChain.hasPrefix("scale=-2:1440,"), "zscale 路径前置缩放")
    let hdrColor = VideoColorInfo(primaries: "bt2020", transfer: "smpte2084",
                                  matrix: "bt2020nc", range: "tv")
    let coloredChain = PlaybackFilters.toneMapChain(dolbyVision: false, supportsLibplacebo: false,
                                                    outputHeight: 1440, inputColor: hdrColor) ?? ""
    expect(coloredChain.hasPrefix("setparams=color_primaries=bt2020:color_trc=smpte2084:"
                                  + "colorspace=bt2020nc:range=tv,scale=-2:1440,"),
           "zscale 前用 setparams 写回帧色彩元数据")




    let remuxArgs = StreamPlanner.arguments(for: baseRequest())
    expect(remuxArgs.contains("copy"), "HEVC 蓝光走视频拷贝")
    expect(remuxArgs.joined(separator: " ").contains("-c:a copy"), "AC-3 音轨直通")

    // seek 起流：实测去掉 copyts 后时间轴仍从 0 起，首片快约 2.7×。
    var seekRequest = baseRequest()
    seekRequest.startOffset = 300
    seekRequest.sessionStart = 297
    let seekJoinedArgs = StreamPlanner.arguments(for: seekRequest).joined(separator: " ")
    expect(seekJoinedArgs.contains("-noaccurate_seek -ss 300.000"),
           "seek 起流不精确 seek，音频与视频落在同一关键帧")
    expect(!seekJoinedArgs.contains("-copyts"),
           "seek 起流不再保留原始时间戳（首片快约 2.7×）")
    expect(seekJoinedArgs.contains("-avoid_negative_ts make_zero"), "落点前的负时间戳统一平移")



    expectEqual(BufferProfile.defaultProfile, .smooth, "默认缓冲档为流畅")
    expectEqual(BufferProfile.thrifty.forwardBufferDuration, 4, "省流档缓冲 4 秒")
    expectEqual(BufferProfile.smooth.forwardBufferDuration, 16, "流畅档缓冲 16 秒")
    expectEqual(BufferProfile.smooth.remoteReadRate, 10, "流畅档远端 10×")
    let thriftyRemote = StreamPlanner.arguments(for: baseRequest(isRemote: true, bufferProfile: .thrifty))
        .joined(separator: " ")
    expect(thriftyRemote.contains("-readrate 3"), "省流档远端 readrate 3")
    let smoothRemote = StreamPlanner.arguments(for: baseRequest(isRemote: true, bufferProfile: .smooth))
        .joined(separator: " ")
    expect(smoothRemote.contains("-readrate 10"), "流畅档远端 readrate 10")



    let dtsJoined = StreamPlanner.arguments(for: baseRequest(audioCodec: "DTS")).joined(separator: " ")
    expect(dtsJoined.contains("-c:a eac3"), "DTS 5.1 重编码成 E-AC-3")
    expect(dtsJoined.contains("-ac 6"), "E-AC-3 下混到 5.1")
    expect(dtsJoined.contains("-b:a 1536k"), "E-AC-3 码率 1536k（高音质）")

    let fallbackJoined = StreamPlanner.arguments(for: baseRequest(audioPassthrough: false))
        .joined(separator: " ")
    expect(!fallbackJoined.contains("-c:a copy"), "直通兜底会话不拷贝音频")
    expect(fallbackJoined.contains("-c:a aac"), "直通兜底会话重编码为 AAC")

    // ALAC 5.1 实测：remux 后 AVPlayer 的 item.tracks 里有 soun:alac 且起播 rate=1，
    // 因此 6 声道不能成为拒绝直通的理由（白名单按 codec 判定，不按声道数）。
    let alacJoined = StreamPlanner.arguments(for: baseRequest(audioCodec: "ALAC"))
        .joined(separator: " ")
    expect(alacJoined.contains("-c:a copy"), "ALAC 6 声道可以直通 fMP4 HLS")

    var multiAudioRequest = baseRequest()
    multiAudioRequest.audioTracks = [
        AudioTrackInfo(ordinal: 0, codec: "AC3", channels: 6, language: "eng", title: nil),
        AudioTrackInfo(ordinal: 1, codec: "EAC3", channels: 6, language: "jpn", title: nil)
    ]
    expect(StreamPlanner.usesMultipleAudioTracks(for: multiAudioRequest),
           "AC-3 / E-AC-3 多音轨一次装进同一会话")
    let multiNames = StreamPlanner.arguments(for: multiAudioRequest).joined(separator: " ")
    expect(multiNames.contains("name:eng-1") && multiNames.contains("name:jpn-2"),
           "多音轨的分片名带序号，避免 %v 冲突")
    expect(multiNames.contains("language:eng") && multiNames.contains("language:jpn"),
           "多音轨写入 LANGUAGE，AVPlayer 菜单才显示语言名而不是 Unknown / audio_2")

    var sameLanguageRequest = baseRequest()
    sameLanguageRequest.audioTracks = [
        AudioTrackInfo(ordinal: 0, codec: "AAC", channels: 2, language: "chi", title: nil),
        AudioTrackInfo(ordinal: 1, codec: "EAC3", channels: 6, language: "chi", title: nil)
    ]
    let sameLanguageNames = StreamPlanner.arguments(for: sameLanguageRequest).joined(separator: " ")
    expect(sameLanguageNames.contains("name:chi-1") && sameLanguageNames.contains("name:chi-2"),
           "同语言多音轨也生成互不覆盖的分片名")
    multiAudioRequest.audioPassthrough = false
    expect(!StreamPlanner.usesMultipleAudioTracks(for: multiAudioRequest),
           "直通兜底会话退回单音轨重编码")
    multiAudioRequest.audioPassthrough = true
    multiAudioRequest.isHDR = true
    expect(!StreamPlanner.usesMultipleAudioTracks(for: multiAudioRequest),
           "HDR 片源退回单音轨：多音轨 master 没有 VIDEO-RANGE，AVPlayer 会报 -12927")

    expect(StreamPlanner.prefersEAC3(codec: "TRUEHD", channels: 8), "TrueHD 7.1 转 E-AC-3 5.1")
    expect(StreamPlanner.prefersEAC3(codec: "dts", channels: 6), "DTS 5.1 转 E-AC-3 5.1")
    expect(!StreamPlanner.prefersEAC3(codec: "DTS", channels: 2), "双声道 DTS 保持 AAC")



    let unloadableFailure = PlaybackFailure(
        error: NSError(domain: "AVFoundationErrorDomain", code: -11829),
        fallback: "-")
    expect(unloadableFailure.isIncompatibleAsset, "媒体数据加载失败也走兼容转码兜底")
    expect(unloadableFailure.message.contains("11829"), "失败文案带具体错误码")
    let incompatibleFailure = PlaybackFailure(
        error: NSError(domain: "CoreMediaErrorDomain", code: -12927),
        fallback: "-")
    expect(incompatibleFailure.isIncompatibleAsset, "CoreMedia -12927 识别为不兼容码流")

    var deinterlaceRequest = baseRequest(mode: .transcode)
    deinterlaceRequest.isInterlaced = true
    let deinterlaceArgs = StreamPlanner.arguments(for: deinterlaceRequest).joined(separator: " ")
    expect(deinterlaceArgs.contains("bwdif=mode=send_frame"), "隔行源重编码时插入去隔行滤镜")



    expect(VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                           codec: "HEVC", containerExtension: "mp4"),
           "hev1 的 HEVC MP4 实际可播，不能被 isPlayable=false 判死")
    expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                            codec: "ProRes", containerExtension: "mov"),
           "ProRes 的 isPlayable=false 视为真实失败，不盲目放宽")
    expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                            codec: "HEVC", containerExtension: "mp4",
                                            audioDecodable: false),
           "音轨不可解码时不放宽原生直读，避免有画面没声音")
    expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                            codec: "HEVC", containerExtension: "mkv"),
           "MKV 不因 hev1 放宽原生直读")
    expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: true,
                                            codec: "AV1", containerExtension: "mp4"),
           "AV1 即使容器是 MP4 也不放宽")
    expect(!VideoProbe.allowsNativePlayback(assetIsPlayable: false, hasVideoTrack: false,
                                            codec: "HEVC", containerExtension: "mp4"),
           "没有视频轨时不允许直读")

    expectEqual(HTTPByteRange.parse("bytes=100-199", total: 1000),
                HTTPByteRange(start: 100, end: 199), "普通闭区间")
    expectEqual(HTTPByteRange.parse("Range: bytes=900-", total: 1000),
                HTTPByteRange(start: 900, end: nil), "开放式区间")
    expectEqual(HTTPByteRange.parse("bytes=-100", total: 1000),
                HTTPByteRange(start: 900, end: 999, isSuffix: true), "后缀区间取最后 N 字节")
    expectEqual(HTTPByteRange.parse("bytes=900-5000", total: 1000),
                HTTPByteRange(start: 900, end: 999), "终点越界收敛到文件末尾")
    expect(HTTPByteRange.parse("bytes=1000-", total: 1000) == nil, "起点越界返回 nil")
    expect(HTTPByteRange.parse("bytes=200-100", total: 1000) == nil, "倒置区间返回 nil")
    expect(HTTPByteRange.parse("bytes=0-1,5-6", total: 1000) == HTTPByteRange(start: 0, end: 1),
           "多段 Range 只取第一段")



    expectEqual(AudioPlaybackPlan.action(codec: "aac", channels: 2, downmix: .source,
                                         allowPassthrough: true, copiesVideo: true), .copy,
                "AAC 立体声直通")
    expectEqual(AudioPlaybackPlan.action(codec: "ac3", channels: 6, downmix: .source,
                                         allowPassthrough: true, copiesVideo: true), .copy,
                "AC-3 5.1 直通")
    expectEqual(AudioPlaybackPlan.action(codec: "dts", channels: 6, downmix: .source,
                                         allowPassthrough: true, copiesVideo: true), .eac3,
                "DTS 5.1 转 E-AC-3")
    expectEqual(AudioPlaybackPlan.action(codec: "dts", channels: 6, downmix: .stereo,
                                         allowPassthrough: true, copiesVideo: true), .aac,
                "强制立体声时必须重编码")
    expectEqual(AudioPlaybackPlan.action(codec: "flac", channels: 2, downmix: .source,
                                         allowPassthrough: true, copiesVideo: true), .aac,
                "FLAC 转 AAC")
    expectEqual(AudioPlaybackPlan.action(codec: "ac3", channels: 6, downmix: .source,
                                         allowPassthrough: false, copiesVideo: true), .aac,
                "关闭直通后一律 AAC")

    var mixedRequest = baseRequest()
    mixedRequest.audioTracks = [
        AudioTrackInfo(ordinal: 0, codec: "AC3", channels: 6, language: "eng", title: nil),
        AudioTrackInfo(ordinal: 1, codec: "DTS", channels: 6, language: "chi", title: nil)
    ]
    let mixedJoined = StreamPlanner.arguments(for: mixedRequest).joined(separator: " ")
    expect(StreamPlanner.usesMultipleAudioTracks(for: mixedRequest), "混合编码也走多音轨会话")
    expect(mixedJoined.contains("-c:a:0 copy"), "第一条可直通音轨仍拷贝")
    expect(mixedJoined.contains("-c:a:1 eac3"), "第二条 DTS 单独转 E-AC-3")
    expect(mixedJoined.contains("-ac:a:1 6"), "DTS 转 E-AC-3 固定 6 声道")
    expect(mixedJoined.contains("-var_stream_map"), "混合编码仍生成多音轨 master")

    var stereoRequest = baseRequest(audioCodec: "AAC")
    stereoRequest.audioDownmix = .stereo
    let stereoJoined = StreamPlanner.arguments(for: stereoRequest).joined(separator: " ")
    expect(stereoJoined.contains("-c:a aac"), "强制立体声的多声道 AAC 必须重编码")
    expect(stereoJoined.contains("-ac 2"), "强制立体声输出 2 声道")
    expect(!stereoJoined.contains("-c:a copy"), "强制立体声不能走拷贝")

    var efficiencyRequest = baseRequest(mode: .transcode)
    efficiencyRequest.transcodeMode = .efficiency
    let efficiencyJoined = StreamPlanner.arguments(for: efficiencyRequest).joined(separator: " ")
    expect(efficiencyJoined.contains("-c:v hevc_videotoolbox"), "高效档使用 HEVC 编码")
    expect(efficiencyJoined.contains("-tag:v hvc1"), "HEVC 输出写 hvc1 标签")
    expect(efficiencyJoined.contains("-pix_fmt p010le"), "HEVC 输出 10-bit 像素格式")
    expect(!efficiencyJoined.contains("-pix_fmt yuv420p"), "HEVC 输出不能退回 8-bit")

    var lowPowerRequest = baseRequest(mode: .transcode)
    lowPowerRequest.transcodeMode = .lowPower
    let lowPowerJoined = StreamPlanner.arguments(for: lowPowerRequest).joined(separator: " ")
    expect(lowPowerJoined.contains("-power_efficient 1 -prio_speed 1"), "低功耗档开启省电编码")

    var compatibilityRequest = baseRequest(mode: .transcode)
    compatibilityRequest.transcodeMode = .compatibility
    let compatibilityJoined = StreamPlanner.arguments(for: compatibilityRequest).joined(separator: " ")
    expect(compatibilityJoined.contains("-c:v h264_videotoolbox"), "兼容档仍使用 H.264")
    expect(compatibilityJoined.contains("-pix_fmt yuv420p"), "H.264 输出 8-bit 4:2:0")
    expectEqual(TranscodeProfile.make(sourceSize: CGSize(width: 1920, height: 1080),
                                      frameRate: 60,
                                      transcodeMode: .efficiency).codec, .hevc,
                "高效档的转码档位带 HEVC")



    let fitLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                                naturalSize: CGSize(width: 1600, height: 900),
                                                quarterTurns: 0,
                                                mode: .fit,
                                                preset: .source,
                                                pan: .zero)
    expectClose(fitLayout.boxSize.width, 1000, accuracy: 0.01, "源比例裁剪框就是舞台")
    expectClose(fitLayout.preRotationContentSize.width, 1000, accuracy: 0.01, "适应模式宽度撑满")
    expectClose(fitLayout.preRotationContentSize.height, 562.5, accuracy: 0.01, "适应模式高度按片源比例")
    expectClose(fitLayout.panOffset.width, 0, accuracy: 0.01, "适应模式没有可平移的余量")

    let fillLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                                 naturalSize: CGSize(width: 1600, height: 900),
                                                 quarterTurns: 0,
                                                 mode: .fill,
                                                 preset: .source,
                                                 pan: CGSize(width: 1, height: 0))
    expectClose(fillLayout.preRotationContentSize.height, 1000, accuracy: 0.01, "填充模式高度撑满")
    expectClose(fillLayout.preRotationContentSize.width, 1777.78, accuracy: 0.05, "填充模式按比例放大")
    expectClose(fillLayout.panOffset.width, 388.89, accuracy: 0.05, "右移画面用满左右余量")

    let stretchLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 800),
                                                    naturalSize: CGSize(width: 1600, height: 900),
                                                    quarterTurns: 0,
                                                    mode: .stretch,
                                                    preset: .source,
                                                    pan: .zero)
    expectClose(stretchLayout.preRotationContentSize.width, 1000, accuracy: 0.01, "拉伸模式宽度等于舞台")
    expectClose(stretchLayout.preRotationContentSize.height, 800, accuracy: 0.01, "拉伸模式高度等于舞台")

    let actualLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 800),
                                                   naturalSize: CGSize(width: 1600, height: 900),
                                                   quarterTurns: 0,
                                                   mode: .actualSize,
                                                   preset: .source,
                                                   pan: CGSize(width: 1, height: 1))
    expectClose(actualLayout.preRotationContentSize.width, 1600, accuracy: 0.01, "原始像素保持片源宽度")
    expectClose(actualLayout.preRotationContentSize.height, 900, accuracy: 0.01, "原始像素保持片源高度")
    expectClose(actualLayout.panOffset.width, 300, accuracy: 0.01, "原始像素可左右平移超出部分")
    expectClose(actualLayout.panOffset.height, 50, accuracy: 0.01, "原始像素可上下平移超出部分")

    let widePreset = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                                 naturalSize: CGSize(width: 1600, height: 900),
                                                 quarterTurns: 0,
                                                 mode: .fit,
                                                 preset: .widescreen,
                                                 pan: .zero)
    expectClose(widePreset.boxSize.width, 1000, accuracy: 0.01, "16:9 裁剪框宽度")
    expectClose(widePreset.boxSize.height, 562.5, accuracy: 0.01, "16:9 裁剪框高度")

    let classicPreset = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 800),
                                                    naturalSize: CGSize(width: 1600, height: 900),
                                                    quarterTurns: 0,
                                                    mode: .fit,
                                                    preset: .classic,
                                                    pan: .zero)
    expectClose(classicPreset.boxSize.width, 1000, accuracy: 0.01, "4:3 裁剪框宽度")
    expectClose(classicPreset.boxSize.height, 750, accuracy: 0.01, "4:3 裁剪框高度")

    let rotatedLayout = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 600),
                                                    naturalSize: CGSize(width: 1920, height: 1080),
                                                    quarterTurns: 1,
                                                    mode: .fit,
                                                    preset: .source,
                                                    pan: .zero)
    expectClose(rotatedLayout.preRotationContentSize.width, 600, accuracy: 0.01, "旋转 90° 后预旋转宽度取屏幕高度")
    expectClose(rotatedLayout.preRotationContentSize.height, 337.5, accuracy: 0.01, "旋转 90° 后预旋转高度按竖屏比例")

    let clampedPan = VideoFramingGeometry.layout(stage: CGSize(width: 1000, height: 1000),
                                                 naturalSize: CGSize(width: 1600, height: 900),
                                                 quarterTurns: 0,
                                                 mode: .fill,
                                                 preset: .source,
                                                 pan: CGSize(width: 5, height: -5))
    expectClose(clampedPan.panOffset.width, 388.89, accuracy: 0.05, "平移量上限收敛到 1")
    expectClose(clampedPan.panOffset.height, 0, accuracy: 0.01, "没有纵向余量时纵向不平移")

    expectEqual(VideoFramingMode.fill.gravity, .resizeAspectFill, "填充模式用 AVPlayerLayer 填充重力")
    expectEqual(VideoFramingMode.stretch.gravity, .resize, "拉伸模式用 AVPlayerLayer 拉伸重力")
    expectEqual(VideoFramingMode.actualSize.gravity, .resizeAspect, "原始像素仍按比例缩放后再由布局定尺寸")

}
