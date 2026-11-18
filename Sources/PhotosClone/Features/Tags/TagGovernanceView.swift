import SwiftUI

/// 标签治理：重复 / 相似 / 可归入标准标签三类建议，逐条确认后生效。
/// 所有改动都走图库撤销栈，⌘Z 可以回退。
struct TagGovernanceView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var report = TagGovernanceService.Report()
    @State private var ignored: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !store.supportsTagGovernance {
                    unsupported
                } else if visibleIssues.isEmpty {
                    emptyState
                } else {
                    ForEach(TagIssueKind.allCases, id: \.self) { kind in
                        let issues = visibleIssues.filter { $0.kind == kind }
                        if !issues.isEmpty {
                            section(kind: kind, issues: issues)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { rescan() }
    }

    private var visibleIssues: [TagIssue] {
        report.issues.filter { !ignored.contains($0.id) }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("标签治理")
                    .font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 12)
                Button {
                    rescan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Text("扫描 \(report.scannedTags) 个关键词，发现 \(visibleIssues.count) 条可处理的建议。所有改动都可以用 ⌘Z 撤销。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !report.usedVector {
                Text("安装「图像理解（SigLIP2）」后，相似标签还会参考语义向量判断。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var unsupported: some View {
        card {
            Label("标签治理只支持拾光本地图库", systemImage: "info.circle")
                .font(.system(size: 12, weight: .medium))
            Text("系统「照片」图库与网络存储的关键词属于补充元数据，请在对应图库的关键词页里管理。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        card {
            Label(report.issues.isEmpty ? "没有发现需要处理的标签" : "建议都已处理", systemImage: "checkmark.seal")
                .font(.system(size: 13, weight: .medium))
            Text(report.issues.isEmpty
                 ? "重复、拼写差异和可归入标准标签的词会在这里出现。"
                 : "还有 \(report.issues.count - visibleIssues.count) 条建议被忽略，重新扫描可以恢复。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !ignored.isEmpty {
                Button("恢复忽略的建议") { ignored.removeAll() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: - 分组

    private func section(kind: TagIssueKind, issues: [TagIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: kind))
                    .foregroundStyle(.secondary)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(issues.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(kind.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(issues) { issue in
                    row(issue)
                }
            }
        }
    }

    private func row(_ issue: TagIssue) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(issue.tags[0])
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(issue.kind == .nearDuplicate, color: .secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(issue.tags.count > 1 ? issue.tags[1] : "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text("影响 \(issue.count) 张照片")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(primaryTitle(for: issue)) {
                apply(issue)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Button("忽略") {
                ignored.insert(issue.id)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 行为

    private func rescan() {
        report = TagGovernanceService.analyze(store: store)
        // 已处理掉的建议自然消失；保留用户主动忽略的条目，直到重新进入页面。
        ignored = ignored.filter { id in report.issues.contains { $0.id == id } }
    }

    private func apply(_ issue: TagIssue) {
        store.applyTagFix(issue)
        report = TagGovernanceService.analyze(store: store)
    }

    private func primaryTitle(for issue: TagIssue) -> String {
        switch issue.fix {
        case .merge: return "合并"
        case .rename: return "统一"
        case .delete: return "删除"
        }
    }

    private func icon(for kind: TagIssueKind) -> String {
        switch kind {
        case .duplicate: return "doc.on.doc"
        case .nearDuplicate: return "character.cursor.ibeam"
        case .unmapped: return "tag"
        }
    }
}
