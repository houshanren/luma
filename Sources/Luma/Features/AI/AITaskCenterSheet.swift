import SwiftUI

/// 任务中心：关闭助手界面后，仍能看到「正在跑什么、刚跑完什么」。
/// 记录只存在内存里，跨重启的任务队列不在这一版范围内。
struct AITaskCenterSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private var running: [AITaskRecord] {
        store.aiTaskRecords.filter { $0.status == .running }
    }

    private var finished: [AITaskRecord] {
        store.aiTaskRecords.filter { $0.status != .running }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    metricsCard
                    if store.aiTaskRecords.isEmpty {
                        emptyState
                    } else {
                        if !running.isEmpty {
                            section("运行中", records: running, live: true)
                        }
                        if !finished.isEmpty {
                            section("最近任务", records: finished, live: false)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .background(.regularMaterial)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("任务中心")
                    .font(.system(size: 14, weight: .semibold))
                Text("关闭界面不会中断任务；这里能看到进度与结果")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !finished.isEmpty {
                Button("清除已结束") {
                    store.clearFinishedAITaskRecords()
                }
                .controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var metricsCard: some View {
        let summary = store.aiTaskMetricsSummary
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("验收")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(summary.total) 个已结束任务")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("明细写入 ai/metrics.jsonl")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 0) {
                metricCell("任务成功率",
                           summary.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                           target: "≥ 85%")
                Divider().frame(height: 26)
                metricCell("首字中位",
                           summary.medianFirstTokenMs.map { String(format: "%.2fs", Double($0) / 1000) } ?? "—",
                           target: "< 1.5s")
                Divider().frame(height: 26)
                metricCell("审批 / 任务",
                           summary.averageApprovals.map { String(format: "%.1f", $0) } ?? "—",
                           target: "≤ 1.2")
                Divider().frame(height: 26)
                metricCell("平均 token",
                           summary.averageTokens.map { "\(Int($0))" } ?? "—",
                           target: "端点返回才有")
            }
            if let saving = store.aiToolSchemaSaving {
                Text("本轮工具 schema 相对全量节省 \(Int(saving * 100))% · 本轮暴露 \(store.aiLastToolCount) / \(store.aiToolDefinitionCount) 个")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(Color.accentColor.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 1)
        )
    }

    private func metricCell(_ title: String, _ value: String, target: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(target)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func section(_ title: String, records: [AITaskRecord], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(records.count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                ForEach(records) { record in
                    row(record, live: live)
                    if record.id != records.last?.id {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private func row(_ record: AITaskRecord, live: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: record.status.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint(for: record.status))
                .frame(width: 20, height: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.status.title)
                        .foregroundStyle(tint(for: record.status))
                    if record.isBackground {
                        Text("定时")
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    Text(Self.timeFormatter.string(from: record.startedAt))
                    if let duration = record.duration {
                        Text(String(format: "%.1fs", duration))
                    } else if live {
                        Text("进行中")
                    }
                    if record.toolSteps > 0 {
                        Text("\(record.toolSteps) 步")
                    }
                    if record.approvalCount > 0 {
                        Text("审批 \(record.approvalCount)")
                    }
                    if record.totalTokens > 0 {
                        Text("\(record.totalTokens) tok")
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                if let error = record.errorText, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if record.status == .running {
                TimelineView(.periodic(from: record.startedAt, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(record.startedAt)))
                    Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m\(seconds % 60)s")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func tint(for status: AITaskRecord.Status) -> Color {
        switch status {
        case .running: return Color.accentColor
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有任务")
                .font(.system(size: 12, weight: .medium))
            Text("在助手输入一句话后，这里会记录任务状态；关闭面板也不会中断。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("任务记录只保留本次运行；关闭助手只收界面，长任务会继续。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("回到对话") {
                store.presentAIWorkspace()
                dismiss()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
