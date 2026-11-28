import SwiftUI

/// 成果物库：把对话产出的相簿、片单、清单、报告与回忆影片集中起来。
/// 只管理「记录」，删除不会动相簿或本地文件。
struct AIArtifactSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var kindFilter: AIArtifactKind?

    private var kinds: [AIArtifactKind] {
        let present = Set(store.aiArtifactLibrary.map(\.kind))
        let order: [AIArtifactKind] = [.album, .playlist, .cleanupList,
                                       .report, .memoryMovie, .cinemaReport, .unknown]
        return order.filter { present.contains($0) }
    }

    private var filtered: [AIArtifact] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.aiArtifactLibrary
            .filter { artifact in
                (kindFilter == nil || artifact.kind == kindFilter)
                    && (keyword.isEmpty
                        || artifact.title.lowercased().contains(keyword)
                        || artifact.detail.lowercased().contains(keyword))
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    filters
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 640)
        .background(.regularMaterial)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("成果物库")
                    .font(.system(size: 14, weight: .semibold))
                Text("对话产出的相簿、片单、清单与报告，都留在这里")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
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

    private var hero: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(store.aiArtifactLibrary.count)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("个成果物 · 按图库保存")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ForEach(kinds, id: \.self) { kind in
                VStack(spacing: 3) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("\(store.aiArtifactLibrary.filter { $0.kind == kind }.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(kind.title)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 52)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.10),
                                              Color.accentColor.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var filters: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("搜索成果物", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: 200)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip("全部", active: kindFilter == nil) { kindFilter = nil }
                    ForEach(kinds, id: \.self) { kind in
                        filterChip(kind.title, active: kindFilter == kind) {
                            kindFilter = kindFilter == kind ? nil : kind
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(active ? .white : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? Color.accentColor : Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            ForEach(filtered) { artifact in
                card(artifact)
            }
        }
    }

    private func card(_ artifact: AIArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: artifact.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(artifact.kind.title)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        if artifact.count > 0 {
                            Text("\(artifact.count) 项")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                        }
                        Text(Self.dateFormatter.string(from: artifact.createdAt))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            if !artifact.detail.isEmpty {
                Text(artifact.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("打开") {
                    store.openAIArtifact(artifact)
                    dismiss()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                Button {
                    store.removeAIArtifact(artifact)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .controlSize(.small)
                .help("只从成果物库移除，不删除相簿或文件")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.aiArtifactLibrary.isEmpty ? "还没有成果物" : "没有匹配的成果物")
                .font(.system(size: 12, weight: .medium))
            Text(store.aiArtifactLibrary.isEmpty
                 ? "让助手建相簿、生成清单或报告后，结果会自动收进这里。"
                 : "换个关键词或类型试试。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("成果物随图库保存；在这里移除只会删掉这条记录，不会删除相簿或本地文件。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
