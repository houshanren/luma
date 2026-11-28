import SwiftUI

/// 大图库自查面板：一次测量四个常用全量路径，给出毫秒数并与最慢项对比。
struct LibraryPerformanceSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var report: LibraryPerformanceReport?
    @State private var measuring = false

    private var maxMilliseconds: Double {
        report?.samples.map(\.milliseconds).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("大图库性能自查")
                        .font(.system(size: 14, weight: .semibold))
                    Text("只测量关键词、搜索、重复分组与当前范围筛选，结果写入诊断日志")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if measuring {
                    ProgressView().controlSize(.small)
                }
            }

            Divider()

            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("\(report.photoCount) 项")
                                .font(.system(size: 12, weight: .medium))
                            Text(report.verdict)
                                .font(.system(size: 10.5))
                                .foregroundStyle(verdictColor(report))
                            Spacer()
                            Text(DateText.timeFormatter.string(from: report.sampledAt))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(report.samples) { sample in
                            row(sample)
                        }
                        Text("数值偏大时优先检查：图库项目数、是否开着巨大的相簿或筛选、以及是否刚导入大量文件。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
            } else {
                Text("点「开始测量」跑一次。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button(report == nil ? "开始测量" : "重新测量") {
                    measure()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(measuring)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 500, height: 380)
        .task {
            if report == nil { measure() }
        }
    }

    private func row(_ sample: LibraryPerformanceSample) -> some View {
        let ratio = maxMilliseconds > 0 ? sample.milliseconds / maxMilliseconds : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sample.name)
                    .font(.system(size: 11.5))
                Text(sample.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int(sample.milliseconds.rounded())) ms")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(sampleColor(sample.milliseconds))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(sampleColor(sample.milliseconds))
                        .frame(width: max(2, proxy.size.width * ratio))
                }
            }
            .frame(height: 4)
        }
    }

    private func sampleColor(_ milliseconds: Double) -> Color {
        if milliseconds >= 800 { return .red }
        if milliseconds >= 300 { return .orange }
        return .green
    }

    private func verdictColor(_ report: LibraryPerformanceReport) -> Color {
        guard let slowest = report.slowest else { return .secondary }
        return sampleColor(slowest.milliseconds)
    }

    private func measure() {
        guard !measuring else { return }
        measuring = true
        // 让「测量中」先渲染出来，再跑同步的全量遍历。
        Task { @MainActor in
            await Task.yield()
            report = store.measurePerformance()
            measuring = false
        }
    }
}
