import SwiftUI
import AppKit

/// 本地图库的重复项目：按文件大小 + 像素尺寸分组，可逐组合并。
struct DuplicatesView: View {
    @EnvironmentObject private var store: LibraryStore

    private var groups: [[PhotoItem]] { store.duplicateGroups }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            groupSection(group)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 8)
                    .padding(.bottom, 60)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有重复项目")
                .font(.system(size: 13, weight: .medium))
            Text("当同一张照片被重复导入时，会在这里按组显示。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    private func groupSection(_ group: [PhotoItem]) -> some View {
        let ordered = group.sorted { score($0) > score($1) }
        let best = ordered.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(group.count) 张重复")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("· 可释放 \(formatFileSize(group.reduce(0) { $0 + $1.fileSize } - (best?.fileSize ?? 0)))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let best else { return }
                    store.mergeDuplicateGroup(group, keeping: best.id)
                } label: {
                    Label("保留最佳，移除其余", systemImage: "sparkles")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("按分辨率、文件大小与收藏自动挑选最佳一张")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ordered) { photo in
                        DuplicateThumb(photo: photo,
                                       isKept: photo.id == best?.id,
                                       onKeep: {
                                           store.mergeDuplicateGroup(group, keeping: photo.id)
                                       })
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 精选评分：优先收藏，其次分辨率，再看文件大小。
    private func score(_ photo: PhotoItem) -> Double {
        var value = Double(photo.pixelWidth) * Double(photo.pixelHeight)
        value += Double(photo.fileSize) * 0.002
        if photo.isFavorite { value += 1e12 }
        return value
    }
}

private struct DuplicateThumb: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: PhotoItem
    let isKept: Bool
    let onKeep: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PhotoThumbnailView(photo: photo)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isKept ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: isKept ? 2 : 0.5)
                }
                .overlay(alignment: .topLeading) {
                    if isKept {
                        Text("最佳")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.accentColor, in: Capsule())
                            .padding(6)
                    }
                }
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.snappy(duration: 0.16), value: hovering)
                .onHover { hovering = $0 }
                .onTapGesture { store.openViewer(photo.id) }
                .contextMenu {
                    Button("打开") { store.openViewer(photo.id) }
                    if !isKept {
                        Button("保留这张，移除其余") { onKeep() }
                    }
                    Button("在访达中显示") { store.revealInFinder(photo.id) }
                }

            Text(DateText.dayFormatter.string(from: photo.addedAt))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(formatFileSize(photo.fileSize))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}
