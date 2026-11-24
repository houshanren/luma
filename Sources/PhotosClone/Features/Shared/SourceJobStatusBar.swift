import SwiftUI
import LumaContentCore

/// 侧边栏底部的后台任务条：网盘扫描、影院刮削、健康检测、内容识别、导入导出等统一在这里露出进度。
/// 默认常驻：有任务时显示进度，空闲时也留一个任务记录入口；可收起成左侧的小胶囊。
struct SourceJobStatusBar: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showDetail = false
    /// 收起后只留左侧一个小胶囊，状态跨启动保留。
    @AppStorage("sidebar.taskBar.collapsed") private var collapsed = false
    @Environment(\.colorScheme) private var scheme

    /// 任务条自己叠在侧边栏材质上：暗色模式不能直接用 .secondary / .tertiary，否则和深色背景糊在一起。
    private var secondaryInk: Color {
        scheme == .dark ? Color.white.opacity(0.80) : Color.primary.opacity(0.66)
    }
    private var tertiaryInk: Color {
        scheme == .dark ? Color.white.opacity(0.58) : Color.primary.opacity(0.45)
    }

    var body: some View {
        // 读取 revision：任务进度变化（含后台线程上报）时触发重绘。
        let _ = store.sourceJobRevision
        let jobs = store.activeSourceJobs
        let recentChecks = store.recentSourceJobs(kind: .connectivity)

        Group {
            if collapsed {
                collapsedRow(jobs)
            } else {
                expandedRow(jobs: jobs, recentChecks: recentChecks)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: collapsed)
        // 收 / 展切换时浮层身份会换一个锚点：先关掉，免得之后点不开。
        .onChange(of: collapsed) { _, _ in
            showDetail = false
        }
    }

    // MARK: 展开态

    private func expandedRow(jobs: [JobProgress],
                             recentChecks: [JobProgress]) -> some View {
        HStack(spacing: 8) {
            if let job = jobs.first {
                activeButton(job: job, count: jobs.count)
                if job.isCancellable {
                    Button {
                        showDetail = false
                        store.cancelSourceJob(job.jobID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .help("取消任务")
                }
            } else {
                idleButton(recentChecks: recentChecks)
            }
            collapseButton
        }
        .modifier(SourceJobBarChrome())
    }

    private func activeButton(job: JobProgress, count: Int) -> some View {
        Button {
            showDetail.toggle()
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    // 任务条只占一行：标题保持完整，来源与读数在剩余空间里截断。
                    HStack(spacing: 4) {
                        Text(job.title ?? job.kind.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        // 带上来源名，网盘扫描 / 读 EXIF 在收起状态也能一眼看出是哪个网盘。
                        if let source = compactSourceName(job.sourceID) {
                            Text(source)
                                .font(.system(size: 10))
                                .foregroundStyle(secondaryInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let message = job.message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 10))
                                .foregroundStyle(secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    .lineLimit(1)
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
                            .frame(height: 3)
                            .background {
                                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.24 : 0.10))
                            }
                    }
                }
                Spacer(minLength: 4)
                if count > 1 {
                    Text("+\(count - 1)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(tertiaryInk)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看任务详情")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            SourceJobDetailPopover(isPresented: $showDetail)
                .environmentObject(store)
        }
    }

    /// 空闲态：默认就在，用户随时能翻任务记录、连接检查与失败重试。
    private func idleButton(recentChecks: [JobProgress]) -> some View {
        Button {
            showDetail.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryInk)
                Text("任务记录")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryInk)
                Text(idleDetail(recentChecks: recentChecks))
                    .font(.system(size: 10))
                    .foregroundStyle(tertiaryInk)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tertiaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看任务记录")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            SourceJobDetailPopover(isPresented: $showDetail)
                .environmentObject(store)
        }
    }

    private func idleDetail(recentChecks: [JobProgress]) -> String {
        // 空闲态也给最近一条记录的线索：后台补录日历这类任务结束后也能看出跑过什么。
        if let job = store.recentFinishedSourceJobs(limit: 1).first {
            return job.title ?? compactSourceName(job.sourceID) ?? job.kind.title
        }
        if let check = recentChecks.first, let name = compactSourceName(check.sourceID) {
            return name
        }
        return "后台任务会显示在这里"
    }

    private var collapseButton: some View {
        Button {
            showDetail = false
            collapsed = true
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tertiaryInk)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("收起任务栏")
    }

    // MARK: 收起态

    /// 收起后停在左下角：一个小胶囊，有任务时显示转圈与数量。
    /// 点它先展开任务栏，再打开任务记录——浮层挂在贴窗口边缘的小胶囊上会失效。
    private func collapsedRow(_ jobs: [JobProgress]) -> some View {
        HStack(spacing: 6) {
            Button {
                collapsed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !collapsed { showDetail = true }
                }
            } label: {
                HStack(spacing: 5) {
                    if jobs.isEmpty {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                        Text("\(jobs.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    }
                }
                .foregroundStyle(jobs.isEmpty ? secondaryInk : Color.accentColor)
                .frame(height: 22)
                .padding(.horizontal, 10)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        // 暗色：ultraThinMaterial 叠在侧边栏上会发黑，补一点亮度让胶囊浮起来。
                        Capsule().fill(Color.white.opacity(scheme == .dark ? 0.10 : 0.20))
                    }
                }
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.20 : 0.10),
                                           lineWidth: 0.5)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("展开任务栏并查看任务记录")

            Button {
                collapsed = false
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tertiaryInk)
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("展开任务栏")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// 收起态只给网盘类任务补来源名：影院 / 图库任务本身含义已经清楚，避免这一行过长。
    private func compactSourceName(_ id: SourceID) -> String? {
        if id.rawValue.hasPrefix("cloud:") {
            return store.cloudMount(for: id.uuidValue)?.name
        }
        if id.rawValue.hasPrefix("cinema:mount:") {
            guard let name = store.cloudMount(for: id.uuidValue)?.name else { return nil }
            return "\(name) 影院"
        }
        // 电视画面探测：显示具体电视源，任务条上能看出在标注哪个源。
        if id.rawValue.hasPrefix("tv:") {
            guard let playlistID = id.uuidValue else { return "网络电视" }
            return store.tvModel.playlistName(for: playlistID)
        }
        if id == .search { return "全库" }
        return nil
    }
}

/// 任务条统一的边距、材质与顶部分隔线。
private struct SourceJobBarChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    // 侧边栏本身已是材质：暗色模式再叠 ultraThin 会发黑，任务条补一点亮度浮起来。
                    Rectangle().fill(Color.white.opacity(scheme == .dark ? 0.08 : 0.22))
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.08))
                    .frame(height: 0.5)
            }
    }
}

/// 任务浮层统一的记录行：刮削 / 扫描 / 识别 / 导入共用同一套字段。
private struct TaskTimelineEntry: Identifiable {
    let id: String
    let date: Date
    let title: String
    let badge: String
    /// nil = 进行中。
    let succeeded: Bool?
    let detail: String
    let message: String?
    /// 统一任务中心里的任务：失败时按种类重新发起。
    var sourceJob: JobProgress? = nil
}

/// 任务详情浮层：进行中的任务 + 最近记录（原影院任务中心），排版与影院铭牌浮层一致。
private struct SourceJobDetailPopover: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: LibraryStore
    @State private var pendingClear = false

    var body: some View {
        // 扫描计数等字段不在任务对象里，靠 revision 触发刷新。
        let _ = store.sourceJobRevision
        let jobs = store.activeSourceJobs
        let timeline = taskTimeline
        let checks = store.recentSourceJobs(kind: .connectivity)

        VStack(alignment: .leading, spacing: 10) {
            header(activeCount: jobs.count)

            // 条目不多时按内容高度自适应；任务 / 记录较多时才固定高度并滚动。
            if jobs.count + timeline.count + checks.count > 5 {
                ScrollView {
                    content(jobs: jobs, checks: checks, timeline: timeline)
                }
                .frame(height: 420)
            } else {
                content(jobs: jobs, checks: checks, timeline: timeline)
            }
        }
        .padding(14)
        .frame(width: 340)
        .confirmationDialog("清理任务记录？", isPresented: $pendingClear) {
            Button("全部清理", role: .destructive) {
                store.clearSourceJobHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除任务记录，不影响刮削结果、影片文件与当前连接状态。")
        }
    }

    /// 失败记录的重试入口：所有任务都按种类重新发起，不再单独维护影院队列。
    private func retryAction(for entry: TaskTimelineEntry) -> (() -> Void)? {
        guard let job = entry.sourceJob, job.phase == .failed else { return nil }
        switch job.kind {
        case .scrape:
            return { Task { await store.retryCinemaTask(job) } }
        case .search:
            // 统一搜索：标题形如「搜索「上海」」，点一下用同一个关键词重搜。
            if let keyword = Self.searchKeyword(from: job.title) {
                return { rerunSearch(keyword) }
            }
            // 聚合片单：标题里带片单名，按名字找到它重新聚合。
            guard let name = Self.aggregationPlaylistName(from: job.title),
                  let playlist = store.catalogModel.smartPlaylists.first(where: { $0.name == name })
            else { return nil }
            return { store.catalogModel.refreshSmartPlaylist(playlist.id) }
        case .healthCheck:
            return { store.catalogModel.checkHealth(force: true) }
        case .sync:
            guard job.title?.contains("日历") == true else { return nil }
            return { store.catalogModel.refreshCalendarToday(force: true) }
        case .epg:
            return { store.tvModel.loadEPGIfNeeded(force: true) }
        default:
            return nil
        }
    }

    /// 从「聚合片单「名称」」里取出名称。
    private static func aggregationPlaylistName(from title: String?) -> String? {
        guard let title,
              let start = title.firstIndex(of: "「"),
              let end = title.lastIndex(of: "」"),
              start < end else { return nil }
        return String(title[title.index(after: start)..<end])
    }

    /// 统一搜索任务的标题里取回关键词（「搜索「上海」」→「上海」）。
    private static func searchKeyword(from title: String?) -> String? {
        guard let title, title.hasPrefix("搜索") else { return nil }
        guard let start = title.firstIndex(of: "「"),
              let end = title.lastIndex(of: "」"), start < end else { return nil }
        let keyword = String(title[title.index(after: start)..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty ? nil : keyword
    }

    /// 用任务里记录的关键词重新发起一次全局搜索。
    private func rerunSearch(_ keyword: String) {
        store.searchScope = .global
        store.searchText = keyword
    }

    /// 已完成的搜索任务也能点「重新搜索」：同样的关键词，直接回到统一搜索结果页。
    private func rerunSearchAction(for entry: TaskTimelineEntry) -> (() -> Void)? {
        guard let job = entry.sourceJob, job.kind == .search,
              let keyword = Self.searchKeyword(from: job.title) else { return nil }
        return { rerunSearch(keyword) }
    }

    private func content(jobs: [JobProgress],
                         checks: [JobProgress],
                         timeline: [TaskTimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if jobs.isEmpty {
                Text("当前没有进行中的任务")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 0.5)
                        }
                        jobSection(job)
                    }
                }
            }

            if !checks.isEmpty {
                Divider()
                healthSection(checks)
            }

            if !timeline.isEmpty {
                Divider()
                timelineSection(timeline)
            }
        }
    }

    // MARK: 统一任务时间线

    /// 全部已结束任务合并成一条按时间排序的记录：刮削也是普通任务，不再单独一套。
    private var taskTimeline: [TaskTimelineEntry] {
        store.recentFinishedSourceJobs(limit: 60)
            .filter { $0.kind != .connectivity }
            .map { job in
                let cancelled = job.phase == .cancelled
                return TaskTimelineEntry(
                    id: "job-\(job.jobID.uuidString)",
                    date: job.updatedAt,
                    title: sourceName(job.sourceID),
                    badge: cancelled ? "已取消" : (job.phase == .finished ? "已完成" : "失败"),
                    succeeded: job.phase == .finished,
                    detail: job.title ?? job.kind.title,
                    message: job.message,
                    sourceJob: job
                )
            }
    }

    private func timelineSection(_ entries: [TaskTimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("任务记录")
                    .font(.system(size: 11, weight: .semibold))
                Text("刮削 / 扫描 / 识别 · 同一条时间线")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("清理…") { pendingClear = true }
                    .controlSize(.mini)
                    .help("清理全部任务记录")
            }
            ForEach(entries) { entry in
                timelineRow(entry)
            }
        }
    }

    /// 从「… · 跳过 N 个…」里取出跳过数量。
    private func skippedCount(in message: String?) -> Int? {
        guard let message, let range = message.range(of: "跳过 ") else { return nil }
        return Int(message[range.upperBound...].prefix { $0.isNumber })
    }

    private func timelineRow(_ entry: TaskTimelineEntry) -> some View {
        let tint: Color
        let symbol: String
        switch entry.succeeded {
        case true:
            tint = .green
            symbol = "checkmark.circle.fill"
        case false:
            tint = LumaBrand.coral
            symbol = "exclamationmark.triangle.fill"
        case nil:
            tint = .secondary
            symbol = "clock"
        }
        // 详情与结果并成一行：长文本截断而不是把整行撑高，保证每条记录高度一致。
        let subtitle: String = {
            let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let message = entry.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else { return detail }
            return detail.isEmpty ? message : "\(detail) · \(message)"
        }()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.badge)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.12)))
                    if let skipped = entry.sourceJob?.kind == .scrape ? skippedCount(in: entry.message) : nil,
                       skipped > 0 {
                        Text("跳过 \(skipped)")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Spacer(minLength: 0)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(subtitle)
            }

            if entry.succeeded == false, let retry = retryAction(for: entry) {
                Button("重试") { retry() }
                    .controlSize(.mini)
            } else if entry.succeeded == true, let rerun = rerunSearchAction(for: entry) {
                Button("重新搜索") { rerun() }
                    .controlSize(.mini)
                    .help("用这个关键词重新发起统一搜索")
            }
        }
        .frame(height: 40, alignment: .top)
        .padding(7)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func header(activeCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("后台任务")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(activeCount > 0 ? "\(activeCount) 项进行中" : "空闲")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.6), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }

    // MARK: 进行中

    private func jobSection(_ job: JobProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbolName(for: job))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(job.title ?? job.kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(sourceName(job.sourceID))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(job.phase == .pending ? "等待中" : "进行中")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            if job.kind == .scan,
               let mountID = job.sourceID.uuidValue,
               store.cloudModel.scanMountID == mountID {
                let model = store.cloudModel
                // 本次扫描摘要：条目 / 已存在 / 新增 / 耗时预估，一眼看完这一轮做了什么。
                row("本次条目", "\(model.scanMediaCount.formatted()) 条媒体")
                if model.scanBaselineMediaCount > 0 {
                    row("已存在", "\(model.scanBaselineMediaCount.formatted()) 条")
                }
                row("新增", "\(max(0, model.scanMediaCount - model.scanBaselineMediaCount).formatted()) 条")
                row("已扫描目录", "\(model.scanFolderCount.formatted()) 个")
                if model.scanIndexPersistedFolderCount > 0 {
                    row("已写入索引", "\(model.scanIndexPersistedFolderCount.formatted()) 个目录")
                }
                if let started = model.scanStartedAt {
                    let elapsed = Date().timeIntervalSince(started)
                    // ViewBuilder 里不能直接写语句，文本拼接放在闭包里算完再交给行视图。
                    let text: String = {
                        var text = durationText(elapsed)
                        if let fraction = job.fraction, fraction > 0.03, elapsed > 3 {
                            let remaining = max(0, elapsed / fraction - elapsed)
                            text += " · 预计还需 \(durationText(remaining))"
                        }
                        return text
                    }()
                    row("耗时", text)
                }
                row("扫描方式", model.scanIsDeep ? "全量扫描" : "增量扫描")
                if model.scanTruncated {
                    Text("已触及单次扫描上限，稍后再扫一次可继续补齐。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if job.kind == .analyze {
                row("识别范围", analysisScope(job.sourceID))
            } else if let message = job.message, !message.isEmpty {
                row(job.kind == .scrape ? "当前" : "状态", message)
            }

            if let total = job.total {
                row(job.kind == .analyze ? "已识别" : "已完成",
                    "\(job.completed.formatted()) / \(total.formatted())")
            } else if job.completed > 0 {
                row(job.kind == .analyze ? "已识别" : "已完成",
                    "\(job.completed.formatted())")
            }

            if let fraction = job.fraction {
                VStack(spacing: 4) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if job.phase == .running {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            if job.isCancellable {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("取消任务") {
                        store.cancelSourceJob(job.jobID)
                        isPresented = false
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: 连接检测记录

    private func healthSection(_ checks: [JobProgress]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("连接检测")
                    .font(.system(size: 11, weight: .semibold))
                Text("最近 \(checks.count) 次")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            ForEach(checks) { job in
                healthRow(job)
            }
        }
    }

    private func healthRow(_ job: JobProgress) -> some View {
        let ok = job.phase == .finished
        let tint: Color = ok ? .green : LumaBrand.coral
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(sourceName(job.sourceID))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(ok ? "在线" : "失败")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.12)))
                    Spacer(minLength: 0)
                    Text(job.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if let message = job.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(message)
                }
            }
        }
        .frame(height: 40, alignment: .top)
        .padding(7)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 通用行

    /// 秒数 → 「2 分 05 秒」；扫描摘要里的耗时 / 预计剩余共用。
    private func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return String(format: "%d 分 %02d 秒", total / 60, total % 60) }
        return String(format: "%d 时 %02d 分", total / 3600, (total % 3600) / 60)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// 任务图标：优先按任务标题区分（例如「补录更新日历」用日历图标），再退回种类。
    private func symbolName(for job: JobProgress) -> String {
        if let title = job.title {
            if title.contains("日历") { return "calendar" }
            if title.contains("健康") { return "waveform.path.ecg" }
        }
        return symbolName(for: job.kind)
    }

    private func symbolName(for kind: SourceJobKind) -> String {
        switch kind {
        case .scan: return "magnifyingglass"
        case .index: return "list.bullet.rectangle"
        case .scrape: return "film.stack"
        case .epg: return "calendar"
        case .artwork: return "photo"
        case .sync: return "arrow.triangle.2.circlepath"
        case .analyze: return "sparkles"
        case .healthCheck: return "waveform.path.ecg"
        case .connectivity: return "network"
        case .probe: return "antenna.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        case .ingest: return "square.and.arrow.down"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .backup: return "externaldrive.badge.checkmark"
        case .export: return "square.and.arrow.up"
        case .download: return "arrow.down.circle"
        case .cluster: return "person.2"
        case .dedupe: return "square.on.square"
        case .beauty: return "wand.and.stars"
        case .places: return "mappin.and.ellipse"
        case .metadata: return "doc.text.magnifyingglass"
        case .assistant: return "bubble.left.and.text.bubble.right"
        case .record: return "record.circle"
        }
    }

    /// 识别任务的适用范围：网盘 / 系统图库 / 本地图库 / 影院片头。
    private func analysisScope(_ id: SourceID) -> String {
        if id.rawValue.hasPrefix("cloud:") { return "网盘 · 场景 / 图内文字" }
        if id == .localCinema || id.rawValue.hasPrefix("cinema:") { return "影院 · 片头检测" }
        let path = id.rawValue.hasPrefix("library:")
            ? String(id.rawValue.dropFirst("library:".count))
            : ""
        if let system = store.systemLibraryPath, path == system {
            return "系统图库 · 场景 / 图内文字"
        }
        return "本地图库 · 场景 / 文字 / 二维码"
    }

    /// 源 ID → 可读名称：网盘取挂载名，影院区分本地 / 网盘。
    private func sourceName(_ id: SourceID) -> String {
        if id.rawValue.hasPrefix("cloud:") {
            return store.cloudMount(for: id.uuidValue)?.name ?? "网络云盘"
        }
        if id.rawValue.hasPrefix("cinema:mount:") {
            guard let name = store.cloudMount(for: id.uuidValue)?.name else { return "网盘影院" }
            return "\(name) 影院"
        }
        if id == .localCinema { return "本地影院" }
        if id == .networkCinema { return "网络影院" }
        if id == .catalogHub { return "网络资源总览" }
        if id.rawValue.hasPrefix("catalog:") { return "网络资源" }
        if id == .search { return "全库搜索" }
        if id.rawValue.hasPrefix("tv:") {
            guard let playlistID = id.uuidValue else { return "网络电视" }
            return "网络电视 · \(store.tvModel.playlistName(for: playlistID))"
        }
        if id.rawValue.hasPrefix("library:") {
            let path = String(id.rawValue.dropFirst("library:".count))
            if let system = store.systemLibraryPath, path == system { return "系统图库" }
            return "本地图库"
        }
        return id.rawValue
    }
}
