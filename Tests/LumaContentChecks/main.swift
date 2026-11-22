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

if failures > 0 {
    print("\n\(failures) 项检查失败")
    exit(1)
}
print("\n全部检查通过")
