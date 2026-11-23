import SwiftUI
import LumaContentCore

/// 侧边栏底部的后台任务条：网盘扫描、影院刮削、健康检测、内容识别、导入导出等统一在这里露出进度。
/// 有任务时显示当前进度，没任务但有历史记录时显示入口；点开浮层可以看详情、取消与最近记录。
struct SourceJobStatusBar: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showDetail = false

    var body: some View {
        // 读取 revision：任务进度变化（含后台线程上报）时触发重绘。
        let _ = store.sourceJobRevision
        let jobs = store.activeSourceJobs
        let history = store.cinemaTasks
        let recentChecks = store.recentSourceJobs(kind: .connectivity)

        if let job = jobs.first {
            HStack(spacing: 8) {
                Button {
                    showDetail.toggle()
                } label: {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(job.kind.title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                // 带上来源名，网盘扫描 / 读 EXIF 在收起状态也能一眼看出是哪个网盘。
                                if let source = compactSourceName(job.sourceID) {
                                    Text(source)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let message = job.message, !message.isEmpty {
                                    Text(message)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if let fraction = job.fraction {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .frame(height: 2)
                            }
                        }
                        Spacer(minLength: 4)
                        if jobs.count > 1 {
                            Text("+\(jobs.count - 1)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看任务详情")
                .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                    SourceJobDetailPopover(isPresented: $showDetail)
                        .environmentObject(store)
                }

                if job.isCancellable {
                    Button {
                        showDetail = false
                        store.cancelSourceJob(job.jobID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("取消任务")
                }
            }
            .modifier(SourceJobBarChrome())
        } else if !history.isEmpty || !recentChecks.isEmpty {
            // 空闲态：任务中心入口保留在这里，用户仍能查看刮削历史与失败重试。
            Button {
                showDetail.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("任务记录")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let latest = history.max(by: { $0.startedAt < $1.startedAt }) {
                        Text(latest.scopeName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if let check = recentChecks.first, let name = compactSourceName(check.sourceID) {
                        Text(name)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看任务记录")
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                SourceJobDetailPopover(isPresented: $showDetail)
                    .environmentObject(store)
            }
            .modifier(SourceJobBarChrome())
        }
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
        return nil
    }
}

/// 任务条统一的边距、材质与顶部分隔线。
private struct SourceJobBarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
            }
    }
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
        let history = recentHistory
        let checks = store.recentSourceJobs(kind: .connectivity)

        VStack(alignment: .leading, spacing: 10) {
            header(activeCount: jobs.count)

            // 条目不多时按内容高度自适应；任务 / 记录较多时才固定高度并滚动。
            if jobs.count + history.count + checks.count > 5 {
                ScrollView {
                    content(jobs: jobs, checks: checks, history: history)
                }
                .frame(height: 420)
            } else {
                content(jobs: jobs, checks: checks, history: history)
            }
        }
        .padding(14)
        .frame(width: 340)
        .confirmationDialog("清空任务记录？", isPresented: $pendingClear) {
            Button("清空", role: .destructive) {
                store.clearCinemaTasks()
                store.clearFinishedSourceJobs(kind: .connectivity)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除任务记录，不影响刮削结果、影片文件与当前连接状态。")
        }
    }

    private func content(jobs: [JobProgress],
                         checks: [JobProgress],
                         history: [CinemaTaskRecord]) -> some View {
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

            if !history.isEmpty {
                Divider()
                historySection(history)
            }
        }
    }

    private var recentHistory: [CinemaTaskRecord] {
        Array(store.cinemaTasks.sorted { $0.startedAt > $1.startedAt }.prefix(6))
    }

    private func header(activeCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("后台任务")
                    .font(.system(size: 13, weight: .semibold))
                Text("ACTIVITY")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
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
                Image(systemName: symbolName(for: job.kind))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(job.kind.title)
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
                row("已扫描目录", "\(model.scanFolderCount.formatted()) 个")
                row("已发现媒体", "\(model.scanMediaCount.formatted()) 项")
                if model.scanIndexPersistedFolderCount > 0 {
                    row("已写入索引", "\(model.scanIndexPersistedFolderCount.formatted()) 个目录")
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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(7)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 最近记录（原影院任务中心）

    private func historySection(_ tasks: [CinemaTaskRecord]) -> some View {
        let stats = recentStats
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("最近记录")
                    .font(.system(size: 11, weight: .semibold))
                Text("近 7 天 \(stats.runs) 次刮削 · \(stats.matched) 个已识别")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("清空…") { pendingClear = true }
                    .controlSize(.mini)
            }

            ForEach(tasks) { task in
                historyRow(task)
            }
        }
    }

    private var recentStats: (runs: Int, matched: Int) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = store.cinemaTasks.filter { $0.startedAt >= cutoff }
        return (recent.count, recent.reduce(0) { $0 + $1.matched })
    }

    private func historyRow(_ task: CinemaTaskRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusIcon(task))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor(task))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.scopeName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(task.finishedAt == nil ? "进行中" : (task.succeeded ? "已完成" : "失败"))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(statusColor(task))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(statusColor(task).opacity(0.12)))
                    Spacer(minLength: 0)
                    Text(task.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text("共 \(task.total) 个视频 · 识别 \(task.matched) 个")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                if !task.message.isEmpty {
                    Text(task.message)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if task.finishedAt != nil, !task.succeeded {
                Button("重试") {
                    Task { await store.retryCinemaTask(task) }
                }
                .controlSize(.mini)
            }
        }
        .padding(7)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func statusIcon(_ task: CinemaTaskRecord) -> String {
        if task.finishedAt == nil { return "clock" }
        return task.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(_ task: CinemaTaskRecord) -> Color {
        if task.finishedAt == nil { return LumaBrand.amber }
        return task.succeeded ? .green : LumaBrand.coral
    }

    // MARK: 通用行

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
        if id == .catalogHub { return "网络资源总览" }
        if id.rawValue.hasPrefix("catalog:") { return "网络资源" }
        if id.rawValue.hasPrefix("tv:") { return "网络电视" }
        if id.rawValue.hasPrefix("library:") {
            let path = String(id.rawValue.dropFirst("library:".count))
            if let system = store.systemLibraryPath, path == system { return "系统图库" }
            return "本地图库"
        }
        if id.rawValue.hasPrefix("disk:") { return "本地磁盘" }
        return id.rawValue
    }
}
