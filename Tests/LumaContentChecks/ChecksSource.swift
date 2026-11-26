import Foundation
import LumaContentCore
import PlaybackCore
import TestSupport

@MainActor
func runSourceChecks() {

    expectEqual(SourceKind.library.defaultActivation, .replaceLibrarySession, "图库默认替换写入会话")
    expectEqual(SourceKind.cloudMount.defaultActivation, .browseReadOnly, "云盘默认只读浏览")
    expectEqual(SourceKind.iptv.defaultActivation, .browseReadOnly, "电视默认只读浏览")
    expect(SourceKind.library.ownsWriteSession, "只有图库拥有写入会话")

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



    expect(ContentCapabilities.television.contains(.epg), "电视带 EPG 能力")
    expect(ContentCapabilities.television.contains(.livePlayback), "电视带直播能力")
    expect(!ContentCapabilities.television.contains(.vodPlayback), "电视不以点播为主要能力")
    expect(ContentCapabilities.library.contains(.photoAnalysis), "图库带照片分析能力")
    expect(ContentCapabilities.catalog.contains(.categories), "资源带分类能力")

    expect(liveTarget.isLive, "直播目标标记为 live")
    expect(!liveTarget.canSeek, "直播不可拖动进度")
    expect(liveTarget.capabilities.contains(.liveEdge), "直播保留回到直播沿能力")
    expect(!liveTarget.capabilities.contains(.resume), "直播不续播")

    expect(vodTarget.canSeek, "点播可拖动")
    expect(vodTarget.canResume, "点播可续播")
    expect(vodTarget.hasNextEpisode, "点播默认有下一集能力")



    let authError = SourceError.unauthorized()
    expect(authError.requiresReauthorization, "未授权错误要求重新登录")
    expect(authError.recovery.contains(.reauthorize), "未授权错误提供重新登录动作")
    let httpError = SourceError.http(403)
    expect(httpError.statusCode == 403, "HTTP 错误保留状态码")
    expect(httpError.recovery.contains(.reauthorize), "403 提供重新登录动作")



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



    let mountUUID = UUID()
    expectEqual(SourceID.cloud(mountUUID).uuidValue, mountUUID, "云盘源 ID 可解析 UUID")
    expectEqual(SourceID.mountCinema(mountUUID).uuidValue, mountUUID, "网盘影院源 ID 可解析 UUID")
    expect(SourceID.catalogHub.uuidValue == nil, "聚合源没有 UUID")



    expectEqual(JobDurationText.format(0), "0 毫秒", "0 秒显示毫秒")
    expectEqual(JobDurationText.format(0.85), "850 毫秒", "不足 1 秒显示毫秒")
    expectEqual(JobDurationText.format(3.44), "3.4 秒", "10 秒内保留一位小数")
    expectEqual(JobDurationText.format(12.6), "13 秒", "分钟以下取整")
    expectEqual(JobDurationText.format(125), "2 分 05 秒", "分钟补零到两位秒")
    expectEqual(JobDurationText.format(3_780), "1 时 03 分", "小时补零到两位分")
    expectEqual(JobDurationText.format(90_000), "1 天 01 时", "超过一天显示天与时")
    expectEqual(JobDurationText.format(-5), "0 毫秒", "负耗时收敛到 0")

    let nilFractionJob = JobProgress(jobID: UUID(), sourceID: cloud.id, kind: .scan,
                                     completed: 3, total: 0)
    expect(nilFractionJob.fraction == nil, "没有总数且无显式进度时返回 nil")
    let explicitFractionJob = JobProgress(jobID: UUID(), sourceID: cloud.id, kind: .scan,
                                          completed: 0, total: 100, fractionValue: 1.7)
    expectEqual(explicitFractionJob.fraction ?? 0, 1, "显式进度上限夹到 1")
    let negativeFractionJob = JobProgress(jobID: UUID(), sourceID: cloud.id, kind: .scan,
                                          completed: 0, total: 100, fractionValue: -0.5)
    expectEqual(negativeFractionJob.fraction ?? -1, 0, "显式进度下限夹到 0")

    var cancelHit = false
    let cancelJob = SourceJob(sourceID: cloud.id, kind: .index, title: "索引")
    let cancelJobID = center.begin(cancelJob) { cancelHit = true }
    center.cancel(cancelJobID)
    expectEqual(center.progress[cancelJobID]?.phase, .cancelled, "取消后任务进入 cancelled")
    expect(cancelHit, "取消回调被触发")
    center.discard(cancelJobID)
    expect(center.progress[cancelJobID] == nil, "discard 不留下任务记录")

    let failingJobID = center.begin(SourceJob(sourceID: cloud.id, kind: .scrape, title: "刮削"))
    center.fail(failingJobID, message: "解析失败")
    expectEqual(center.progress[failingJobID]?.phase, .failed, "失败后任务进入 failed")
    expectEqual(center.progress[failingJobID]?.message, Optional("解析失败"), "失败原因被保留")



    expect(ValidationLevel.ok < ValidationLevel.warning, "通过低于警告")
    expect(ValidationLevel.warning < ValidationLevel.failed, "警告低于失败")
    expect(!ValidationLevel.warning.blocksImport, "警告不阻止接入")
    expect(ValidationLevel.failed.blocksImport, "失败阻止接入")
    var warningOnlyReport = ValidationReport()
    warningOnlyReport.append("封面缺失", level: .warning)
    expect(!warningOnlyReport.blocksImport, "只有警告时不阻止接入")
    expectEqual(warningOnlyReport.overall, ValidationLevel.warning, "整体级别取警告")
    expectEqual(warningOnlyReport.warnings.count, 1, "警告项单独可读")

    expect(SourceSessionState.ready.isReady, "ready 表示可用")
    expect(!SourceSessionState.ready.isBusy, "ready 不是忙碌")
    expect(SourceSessionState.activating.isBusy, "activating 是忙碌")
    expect(SourceSessionState.refreshing.isBusy, "refreshing 是忙碌")
    expect(SourceSessionState.idle.error == nil, "idle 没有错误")
    expectEqual(SourceSessionState.failed(.unauthorized()).error?.kind,
                SourceError.Kind.unauthorized, "失败状态带出源错误")

    expectEqual(PageCursor(page: 3).page, 3, "分页游标可解析页码")
    expect(PageCursor("next-token").page == nil, "非数字游标不当作页码")
    expect(ContentPage().isEmpty, "空页")
    let contentRef = ContentRef(sourceID: .catalogHub, itemID: "a")
    let contentCard = ContentCard(ref: contentRef, title: "A")
    expectEqual(contentCard.id, contentRef.id, "卡片 id 来自内容引用")
    expect(!ContentPage(items: [contentCard]).isEmpty, "有卡片不算空页")
    expect(!ContentPage(containers: [ContentContainer(id: "c", title: "C", kind: .folder)]).isEmpty,
           "只有容器也不算空页")

    expect(SourceError.tls("example.com").recovery.contains(.allowInsecureTLS),
           "证书错误提供放行动作")
    expect(SourceError.parse("bad json").recovery.contains(.reconfigureSource),
           "解析错误提供重配动作")
    expect(SourceError.unsupported("x").recovery.isEmpty, "不支持没有恢复动作")
    expectEqual(SourceError.http(500).recovery, [.retry], "5xx 只提供重试")
    expect(SourceError.http(401).recovery.contains(.reauthorize), "401 提供重新登录")
    expectEqual(SourceError.unauthorized().errorDescription, Optional("授权已失效，请重新登录"),
                "未授权文案")

    do {
        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(SourceRegistryState.self, from: data)
        expectEqual(decoded.activeLibraryID, registry.activeLibraryID, "源目录可编解码")
        expectEqual(decoded.sources.count, registry.sources.count, "源目录条目数量保持")
    } catch {
        expect(false, "源目录编解码失败：\(error)")
    }
}
