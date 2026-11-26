import Foundation
import LumaCore
import PlaybackCore
import TestSupport

func runPlaybackRuntimeChecks() {

    var adaptation = BufferAdaptationState(cooldown: 20)
    let t0 = Date(timeIntervalSince1970: 1_000)
    func adapt(_ current: BufferProfile, _ ceiling: BufferProfile, throughput: Double,
               required: Double, lead: Double, at offset: TimeInterval) -> BufferProfile? {
        adaptation.evaluate(current: current, ceiling: ceiling,
                            throughputBps: throughput, requiredBps: required,
                            leadSeconds: lead, now: t0.addingTimeInterval(offset))
    }
    expect(adapt(.smooth, .smooth, throughput: 5_000_000, required: 20_000_000,
                 lead: 2, at: 0) == nil, "首次低吞吐只累计、不立刻降档")
    expect(adapt(.smooth, .smooth, throughput: 5_000_000, required: 20_000_000,
                 lead: 2, at: 1) == .balanced, "连续两次低吞吐降一档")
    expect(adapt(.balanced, .smooth, throughput: 5_000_000, required: 20_000_000,
                 lead: 2, at: 2) == nil, "冷却期内不再降档")
    expect(adapt(.balanced, .smooth, throughput: 80_000_000, required: 20_000_000,
                 lead: 300, at: 21) == nil, "升档需要连续三次高吞吐")
    expect(adapt(.balanced, .smooth, throughput: 80_000_000, required: 20_000_000,
                 lead: 300, at: 22) == nil, "第二次高吞吐仍不升档")
    expect(adapt(.balanced, .smooth, throughput: 80_000_000, required: 20_000_000,
                 lead: 300, at: 23) == .smooth, "连续三次高吞吐回到上限档")

    var cappedAdaptation = BufferAdaptationState(cooldown: 20)
    let cappedT0 = Date(timeIntervalSince1970: 2_000)
    for offset in [0.0, 1.0, 2.0] {
        let result = cappedAdaptation.evaluate(current: .thrifty, ceiling: .thrifty,
                                              throughputBps: 80_000_000, requiredBps: 20_000_000,
                                              leadSeconds: 300, now: cappedT0.addingTimeInterval(offset))
        expect(result == nil, "省流档不会被自适应升到更高档（\(Int(offset))）")
    }
    expect(adapt(.thrifty, .thrifty, throughput: 1_000_000, required: 20_000_000,
                 lead: 2, at: 30) == nil, "省流档已经最低，不能再降")

    let adaptiveRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("luma-adaptive-\(UUID().uuidString)", isDirectory: true)
    let adaptiveOff = PlaybackEnvironment(
        cache: PlaybackCache(root: adaptiveRoot, limitBytes: { 0 }),
        ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
        supportsToneMapping: false,
        adaptiveBuffering: { false },
        record: { _ in })
    expect(!adaptiveOff.adaptiveBuffering, "关闭弱网自适应后不再按网络降档")
    let adaptiveDefault = PlaybackEnvironment(
        cache: PlaybackCache(root: adaptiveRoot, limitBytes: { 0 }),
        ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
        supportsToneMapping: false,
        record: { _ in })
    expect(!adaptiveDefault.adaptiveBuffering, "未注入时自适应默认关闭（默认固定流畅档）")
    let adaptiveOn = PlaybackEnvironment(
        cache: PlaybackCache(root: adaptiveRoot, limitBytes: { 0 }),
        ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
        supportsToneMapping: false,
        adaptiveBuffering: { true },
        record: { _ in })
    expect(adaptiveOn.adaptiveBuffering, "选择自适应后按网络降档")

    let pgssubArgs = StreamPlanner.arguments(for: baseRequest(burnSubtitleStream: 1))
    let pgsJoined = pgssubArgs.joined(separator: " ")
    expect(!pgsJoined.contains("-c:v copy"), "图形字幕烧录强制重编码")
    expect(pgsJoined.contains("-filter_complex"), "图形字幕走 filter_complex")
    expect(pgsJoined.contains("[0:s:1]overlay"), "按字幕轨序号 overlay")
    expect(pgsJoined.contains("-canvas_size 1920x1080"), "字幕画布按源尺寸")
    expect(!StreamPlanner.copiesVideo(mode: .remux, burnSubtitle: nil, burnSubtitleStream: 1),
           "烧录图形字幕时不能拷贝视频")



    let cacheManifest = StreamCacheManifest(
        isMultiAudio: true,
        audioTracks: [
            AudioTrackInfo(ordinal: 0, codec: "aac", channels: 2, language: "chi", title: nil),
            AudioTrackInfo(ordinal: 1, codec: "ac3", channels: 6, language: "eng", title: nil)
        ],
        cacheSignature: "v2-am-keephdr",
        isHDR: true,
        isDolbyVision: true)
    if let data = try? JSONEncoder().encode(cacheManifest),
       let decoded = try? JSONDecoder().decode(StreamCacheManifest.self, from: data) {
        expect(decoded == cacheManifest, "缓存清单可完整往返音轨结构与 HDR 标记")
    } else {
        expect(false, "缓存清单编解码失败")
    }



    let policyRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("luma-policy-\(UUID().uuidString)", isDirectory: true)
    let policyEnvironment = PlaybackEnvironment(
        cache: PlaybackCache(root: policyRoot, limitBytes: { 0 }),
        ffmpeg: nil, ffmpegForToneMap: nil, ffprobe: nil,
        supportsToneMapping: true,
        supportsLibplacebo: false,
        record: { _ in })
    let policyPhoto = UUID()
    let hdrSignature = "v4-am-automatic"
    let sdrSignature = "v4-am-tonemapsdr"

    /// 造一份「播放列表完整」的缓存目录；manifest 为 false 时模拟旧版本没有清单。
    func makeCachedDirectory(photoID: UUID, signature: String,
                             isHDR: Bool, isDolbyVision: Bool = false,
                             withManifest: Bool) -> URL {
        let name = signature.isEmpty ? "\(photoID.uuidString).hls"
                                     : "\(photoID.uuidString)-\(signature).hls"
        let directory = policyRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
            .write(to: directory.appendingPathComponent("live.m3u8"))
        if withManifest {
            let info = StreamCacheManifest(isMultiAudio: false, audioTracks: [],
                                           cacheSignature: signature, isHDR: isHDR,
                                           isDolbyVision: isDolbyVision)
            if let data = try? JSONEncoder().encode(info) {
                try? data.write(to: directory.appendingPathComponent("manifest.json"))
            }
        }
        return directory
    }

    let hdrCacheDirectory = makeCachedDirectory(photoID: policyPhoto, signature: hdrSignature,
                                                isHDR: true, withManifest: true)
    expect(VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                               photoID: policyPhoto, cacheSignature: hdrSignature),
           "策略签名一致时命中完整缓存")
    expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                                photoID: policyPhoto, cacheSignature: sdrSignature),
           "换策略签名不会命中别的策略生成的缓存")
    expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                                photoID: policyPhoto, cacheSignature: ""),
           "空签名不会把带签名的缓存当成命中")
    expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                                photoID: policyPhoto, cacheSignature: hdrSignature,
                                                requiresSDR: true),
           "需要 SDR 时不命中 HDR remux 缓存")
    let dvSignature = "v4-am-dolbyvision"
    _ = makeCachedDirectory(photoID: policyPhoto, signature: dvSignature,
                            isHDR: true, isDolbyVision: true, withManifest: true)
    expect(VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                               photoID: policyPhoto, cacheSignature: dvSignature,
                                               requiresSDR: true, supportsLibplacebo: false),
           "没有 libplacebo 时杜比视界无法映射，HDR 缓存仍可复用")
    expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                                photoID: policyPhoto, cacheSignature: dvSignature,
                                                requiresSDR: true, supportsLibplacebo: true),
           "有 libplacebo 时要求映射，不能再复用 HDR 缓存")
    expect(VideoStreamSession.cachedManifest(environment: policyEnvironment, photoID: policyPhoto,
                                             cacheSignature: hdrSignature)?.isHDR == true,
           "命中缓存能读回 HDR 标记")
    expect(VideoStreamSession.cachedManifest(environment: policyEnvironment, photoID: policyPhoto,
                                             cacheSignature: sdrSignature) == nil,
           "签名不一致读不到别人的缓存清单")

    // 旧版本目录没有清单：即使播放列表完整，也不能被当前策略命中。
    _ = makeCachedDirectory(photoID: policyPhoto, signature: "v4-as-automatic",
                            isHDR: false, withManifest: false)
    expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                                photoID: policyPhoto, cacheSignature: "v4-as-automatic"),
           "缺少策略清单的旧缓存不算命中")

    // 无签名目录（`<photoID>.hls`）不再命中，启动清理会把它删掉。
    let legacyCacheDirectory = makeCachedDirectory(photoID: policyPhoto, signature: "",
                                                   isHDR: false, withManifest: true)
    let legacyTranscodeFile = policyRoot.appendingPathComponent("\(policyPhoto.uuidString).mp4")
    FileManager.default.createFile(atPath: legacyTranscodeFile.path,
                                   contents: Data(repeating: 0x41, count: 64))
    expect(!VideoStreamSession.hasCompleteCache(environment: policyEnvironment,
                                                photoID: policyPhoto, cacheSignature: ""),
           "旧的无签名缓存目录不再命中")
    policyEnvironment.cache.cleanupOrphans(maxAge: 0)
    expect(!FileManager.default.fileExists(atPath: legacyCacheDirectory.path),
           "启动清理删除无策略签名的旧缓存")
    expect(!FileManager.default.fileExists(atPath: legacyTranscodeFile.path),
           "启动清理删除旧版整片转码 mp4")
    expect(FileManager.default.fileExists(atPath: hdrCacheDirectory.path),
           "启动清理保留带策略签名的新缓存")
    try? FileManager.default.removeItem(at: policyRoot)



    let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("luma-cache-\(UUID().uuidString)", isDirectory: true)
    let activeCache = cacheRoot.appendingPathComponent("\(UUID().uuidString).hls", isDirectory: true)
    try? FileManager.default.createDirectory(at: activeCache, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: activeCache.appendingPathComponent("live.m3u8").path,
                                   contents: Data(repeating: 0x41, count: 4096))
    let cache = PlaybackCache(root: cacheRoot, limitBytes: { 1 })
    cache.markActive(activeCache)
    cache.trimIfNeeded()
    expect(FileManager.default.fileExists(atPath: activeCache.path),
           "正在播放的完整缓存不会被容量清理删除")
    cache.markInactive(activeCache)
    cache.trimIfNeeded()
    expect(!FileManager.default.fileExists(atPath: activeCache.path),
           "取消使用标记后重新参与清理")
    try? FileManager.default.removeItem(at: cacheRoot)



    var aRetryState = TVLiveLineRetryState(lines: ["A", "B", "C"], startURL: "A")
    var aRetryAttempts: [String] = []
    var aRetryResults: [TVLiveLineRetryFailure] = []
    for attempt in 0..<9 {
        if let currentURL = aRetryState.currentURL {
            aRetryAttempts.append(currentURL)
        }
        aRetryResults.append(aRetryState.recordFailure(token: "A-token-\(attempt)"))
    }
    expectEqual(aRetryAttempts,
                ["A", "B", "C", "A", "B", "C", "A", "B", "C"],
                "A 起九次尝试按原固定目录循环")
    expectEqual(aRetryResults,
                [.next(URL: "B"), .next(URL: "C"), .next(URL: "A"),
                 .next(URL: "B"), .next(URL: "C"), .next(URL: "A"),
                 .next(URL: "B"), .next(URL: "C"), .exhausted],
                "A 起前八次失败推进线路且第九次耗尽")
    expectEqual(aRetryState.failureCount, 9, "A 起九次有效失败全部计数")
    expect(aRetryState.currentURL == nil, "A 起耗尽后没有当前应尝试线路")
    expectEqual(aRetryState.recordFailure(token: "A-token-extra"),
                .exhausted,
                "耗尽后不得再产生下一次 URL")
    expectEqual(aRetryState.failureCount, 9, "耗尽后的回调不增加失败次数")

    var bRetryState = TVLiveLineRetryState(lines: ["A", "B", "C"], startURL: "B")
    var bRetryAttempts: [String] = []
    var bRetryResults: [TVLiveLineRetryFailure] = []
    for attempt in 0..<9 {
        if let currentURL = bRetryState.currentURL {
            bRetryAttempts.append(currentURL)
        }
        bRetryResults.append(bRetryState.recordFailure(token: "B-token-\(attempt)"))
    }
    expectEqual(bRetryAttempts,
                ["B", "C", "A", "B", "C", "A", "B", "C", "A"],
                "B 起九次尝试仍按原固定目录循环")
    expectEqual(bRetryResults[8], .exhausted, "B 起第九次有效失败耗尽")

    var singleRetryState = TVLiveLineRetryState(lines: ["single"])
    var singleRetryAttempts: [String] = []
    var singleRetryResults: [TVLiveLineRetryFailure] = []
    for attempt in 0..<3 {
        if let currentURL = singleRetryState.currentURL {
            singleRetryAttempts.append(currentURL)
        }
        singleRetryResults.append(singleRetryState.recordFailure(token: "single-token-\(attempt)"))
    }
    expectEqual(singleRetryAttempts,
                ["single", "single", "single"],
                "单线路总共尝试三次而非首次加三次重试")
    expectEqual(singleRetryResults,
                [.next(URL: "single"), .next(URL: "single"), .exhausted],
                "单线路第三次有效失败耗尽")
    expectEqual(singleRetryState.failureCount, 3, "单线路有效失败次数为三次")

    var invalidStartState = TVLiveLineRetryState(lines: ["A", "B", "C"], startURL: "missing")
    expect(invalidStartState.currentURL == "A", "首选线路不在目录时回退到首条线路")
    expectEqual(invalidStartState.recordFailure(token: "invalid-start"),
                .next(URL: "B"),
                "无效首选回退后仍按原目录推进")
    let nilStartState = TVLiveLineRetryState(lines: ["A", "B", "C"], startURL: nil)
    expect(nilStartState.currentURL == "A", "首选线路为 nil 时从首条线路开始")

    var duplicateURLState = TVLiveLineRetryState(lines: ["A", "B", "A", "C", "B"], maxRounds: 1)
    expectEqual(duplicateURLState.lines, ["A", "B", "C"], "输入线路按出现顺序去重")
    expectEqual(duplicateURLState.recordFailure(token: "dedup-token-1"),
                .next(URL: "B"),
                "重复 URL 不参与线路推进")
    _ = duplicateURLState.recordFailure(token: "dedup-token-2")
    expectEqual(duplicateURLState.recordFailure(token: "dedup-token-3"),
                .exhausted,
                "总尝试次数按去重后的线路数计算")

    var duplicateTokenState = TVLiveLineRetryState(lines: ["A", "B", "C"])
    expectEqual(duplicateTokenState.recordFailure(token: "load-1"),
                .next(URL: "B"),
                "首个装片 token 的失败正常推进线路")
    expectEqual(duplicateTokenState.failureCount, 1, "首个有效失败计入失败次数")
    expect(duplicateTokenState.lastFailureToken == "load-1", "记录最近有效失败的装片 token")
    expectEqual(duplicateTokenState.recordFailure(token: "load-1"),
                .ignored,
                "相同 token 的重复失败回调被忽略")
    expectEqual(duplicateTokenState.failureCount, 1, "重复 token 不增加失败次数")
    expect(duplicateTokenState.currentURL == "B", "重复 token 不推进当前线路")
    expect(duplicateTokenState.lastFailureToken == "load-1", "重复 token 不改写最近失败记录")
    expectEqual(duplicateTokenState.recordFailure(token: "load-2"),
                .next(URL: "C"),
                "新 token 的失败在重复回调后继续推进")
    expectEqual(duplicateTokenState.failureCount, 2, "新 token 再次计入有效失败次数")



    expectEqual(BufferProfile.thrifty.rank, 0, "省流档最低")
    expectEqual(BufferProfile.balanced.rank, 1, "均衡档居中")
    expectEqual(BufferProfile.smooth.rank, 2, "流畅档最高")
    expect(BufferProfile.thrifty.downgraded() == nil, "省流档不能再降")
    expectEqual(BufferProfile.smooth.downgraded(), BufferProfile.balanced, "流畅降一档到均衡")
    expectEqual(BufferProfile.thrifty.upgraded(), BufferProfile.balanced, "省流升一档到均衡")
    expect(BufferProfile.smooth.upgraded() == nil, "流畅档不能再升")
    expectEqual(BufferProfile.balanced.forwardBufferDuration, 8, "均衡档前向缓冲 8 秒")
    expectEqual(BufferProfile.balanced.remoteReadRate, 6, "均衡档远端 6×")
    expectEqual(BufferProfile.balanced.prefetchWindow, 6, "均衡档预取窗口 6 块")
    expectEqual(BufferProfile.thrifty.retainedChunks, 4, "省流档只保留 4 块")
    expectEqual(BufferProfile.smooth.maxParallelChunks, 8, "流畅档最多 8 路并行")
    expectEqual(BufferProfile.smooth.chunkSize, 16 * 1024 * 1024, "流畅档分块 16MB")

    expectEqual(SeekPlanner.decide(target: 30, retainedStart: 20, generatedEnd: 60,
                                   isCompleteCache: true),
                .inSession, "完整缓存任何位置都直接 seek")
    expectEqual(SeekPlanner.decide(target: 18, retainedStart: 20, generatedEnd: 60,
                                   isCompleteCache: false),
                .restart, "早于保留窗口需要重建流")
    expectEqual(SeekPlanner.decide(target: 19, retainedStart: 20, generatedEnd: 60,
                                   isCompleteCache: false),
                .inSession, "回退 1 秒容差内直接 seek")
    expectEqual(SeekPlanner.decide(target: 68, retainedStart: 20, generatedEnd: 60,
                                   isCompleteCache: false),
                .inSession, "前向 8 秒容差内直接 seek")
    expectEqual(SeekPlanner.decide(target: 69, retainedStart: 20, generatedEnd: 60,
                                   isCompleteCache: false),
                .restart, "超出已生成末尾需要重建流")
    expectEqual(SeekPlanner.decide(target: 15, retainedStart: 20, generatedEnd: 60,
                                   isCompleteCache: false, backwardSlack: 10),
                .inSession, "自定义回退容差生效")

    let timeline = PlaybackTimeline(sessionStart: 120)
    expectEqual(timeline.absolute(local: 0), 120, "会话 0 点对应片源起流点")
    expectEqual(timeline.absolute(local: 30), 150, "会话内时间换算到完整时间轴")
    expectEqual(timeline.local(absolute: 150), 30, "完整时间轴换算回会话内时间")
    expectEqual(timeline.local(absolute: 60), 0, "早于会话起点收敛到 0")
    expectEqual(timeline.clamp(100, duration: 600), 120, "低于会话起点时夹到起点")
    expectEqual(timeline.clamp(700, duration: 600), 600, "超过总时长夹到片尾")
    expectEqual(timeline.clamp(.nan, duration: 600), 120, "NaN 回落到会话起点")
    expectEqual(PlaybackTimeline(sessionStart: -5).sessionStart, 0, "会话起点不能为负")
    expectEqual(PlaybackTimeline().clamp(50, duration: 0), 50, "时长未知时不夹上界")

    expect(PlaybackCapabilities.vod.contains([.seek, .resume, .nextEpisode, .subtitles]),
           "点播提供拖动 / 续播 / 下一集 / 字幕")
    expect(!PlaybackCapabilities.vod.contains(.liveEdge), "点播没有直播沿")
    expectEqual(PlaybackCapabilities.live, [.liveEdge], "直播只保留回到直播沿")
    let catchupCapabilities: PlaybackCapabilities = [.liveEdge, .catchup]
    if let data = try? JSONEncoder().encode(catchupCapabilities),
       let decoded = try? JSONDecoder().decode(PlaybackCapabilities.self, from: data) {
        expectEqual(decoded, catchupCapabilities, "播放能力位可编解码")
    } else {
        expect(false, "播放能力位编解码失败")
    }
    expect(PlaybackMode.live.isLive, "直播模式标记正确")
    expect(!PlaybackMode.vod.isLive, "点播模式不是直播")

    expect(VideoColorInfo().remuxCodecTag == nil, "非杜比视界不写 DV 标签")
    expectEqual(VideoColorInfo(isDolbyVision: true).remuxCodecTag, Optional("dvh1"),
                "杜比视界缺 tag 时补 dvh1")
    expectEqual(VideoColorInfo(codecTag: "dvhe", isDolbyVision: true).remuxCodecTag,
                Optional("dvhe"), "杜比视界保留原 dvhe 标签")
    expectEqual(VideoColorInfo(codecTag: "hvc1", isDolbyVision: true).remuxCodecTag,
                Optional("dvh1"), "hvc1 的杜比视界补 dvh1")
    expect(VideoColorInfo().isEmpty, "空色彩信息")
    expect(!VideoColorInfo(isHDR: true).isEmpty, "含 HDR 标记不算空")

    expectEqual(AudioTrackInfo(ordinal: 0, codec: "AC3", channels: 6,
                               language: "eng", title: nil).displayName,
                "eng · 5.1 · AC3", "音轨展示名：语言 / 声道 / 编码")
    expectEqual(AudioTrackInfo(ordinal: 0, codec: "DTS", channels: 8,
                               language: "und", title: "主音轨").displayName,
                "主音轨 · 7.1 · DTS", "音轨展示名跳过 und 语言")
    expectEqual(AudioTrackInfo(ordinal: 0, codec: "AAC", channels: 2,
                               language: "chi", title: nil).displayName,
                "chi · 立体声 · AAC", "双声道显示立体声")
    expectEqual(AudioTrackInfo(ordinal: 0, codec: "AAC", channels: 3,
                               language: nil, title: nil).displayName,
                "3 声道 · AAC", "其他声道数原样显示")
    expectEqual(SubtitleTrackInfo(ordinal: 0, codec: "", language: nil, title: nil,
                                  isImage: false).displayName,
                "字幕 1", "空字幕轨回退到序号")
    expectEqual(SubtitleTrackInfo(ordinal: 1, codec: "PGS", language: "chi", title: nil,
                                  isImage: true, isForced: true).displayName,
                "chi · PGS · 图形 · 强制", "图形 / 强制字幕带标记")

}
