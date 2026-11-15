import SwiftUI
import AppKit
import LumaCore

struct SectionHeaderView: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count) 张照片")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

struct SquarePhotoGrid: View {
    @EnvironmentObject private var store: LibraryStore
    let photos: [PhotoItem]
    let availableWidth: CGFloat

    private let spacing: CGFloat = 4

    var body: some View {
        let contentWidth = max(120, availableWidth - 40)
        let target = CGFloat(store.thumbSize)
        let columns = GridLayout.columns(contentWidth: contentWidth, targetSize: target, spacing: spacing)
        let cell = GridLayout.squareCellWidth(contentWidth: contentWidth, columns: columns, spacing: spacing)
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: columns),
            spacing: spacing
        ) {
            ForEach(photos) { photo in
                PhotoCell(photo: photo, width: cell, height: cell)
                    .id(photo.id)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: PhotoFramePreferenceKey.self,
                                value: [photo.id: geo.frame(in: .named("galleryGrid"))]
                            )
                        }
                    )
            }
        }
    }
}

struct JustifiedRowEntry: Identifiable {
    let photo: PhotoItem
    let width: CGFloat
    let height: CGFloat
    var id: UUID { photo.id }
}

struct JustifiedPhotoGrid: View {
    let photos: [PhotoItem]
    let availableWidth: CGFloat
    let targetHeight: CGFloat

    private let spacing: CGFloat = 8

    var body: some View {
        let contentWidth = max(120, availableWidth - 40)
        let rows = Self.buildRows(photos: photos, width: contentWidth,
                                  targetHeight: max(60, targetHeight), spacing: spacing)
        // 完整宽高比模式：每张缩略图保持原始比例，行高统一，文件名居中显示在下方（与系统「照片」一致）。
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[index]) { entry in
                        VStack(spacing: 6) {
                            PhotoCell(photo: entry.photo, width: entry.width, height: entry.height)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: PhotoFramePreferenceKey.self,
                                            value: [entry.photo.id: geo.frame(in: .named("galleryGrid"))]
                                        )
                                    }
                                )
                            Text(entry.photo.displayFilename)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: entry.width)
                        }
                        .frame(width: entry.width)
                        .id(entry.photo.id)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    static func buildRows(photos: [PhotoItem], width: CGFloat,
                          targetHeight: CGFloat, spacing: CGFloat) -> [[JustifiedRowEntry]] {
        let aspects = photos.map(\.aspectRatio)
        return GridLayout.justifiedRows(aspects: aspects,
                                        width: width,
                                        targetHeight: targetHeight,
                                        spacing: spacing).map { row in
            row.map { item in
                JustifiedRowEntry(photo: photos[item.index],
                                  width: item.width,
                                  height: item.height)
            }
        }
    }
}

/// 瀑布流：等宽多列、每列高度自适应，保留原始宽高比，竖图横图混排也不留空洞。
/// 卡片比其它网格更大，并常驻投影 + 更强的悬停放大，让照片从背景里浮出来。
struct MasonryPhotoGrid: View {
    @EnvironmentObject private var settings: AppSettings
    let photos: [PhotoItem]
    let availableWidth: CGFloat
    let targetWidth: CGFloat

    private let spacing: CGFloat = 14
    private let maxColumns = 6

    /// 瀑布流卡片比正方形网格大 1.5 倍，减少列数、放大单张，观感更接近「瀑布」。
    private var cardWidth: CGFloat { max(180, targetWidth * 1.5) }

    var body: some View {
        let contentWidth = max(120, availableWidth - 40)
        let columns = min(maxColumns,
                          GridLayout.columns(contentWidth: contentWidth,
                                             targetSize: cardWidth,
                                             spacing: spacing))
        let columnWidth = GridLayout.squareCellWidth(contentWidth: contentWidth,
                                                     columns: columns,
                                                     spacing: spacing)
        let buckets = GridLayout.masonryColumns(aspects: photos.map(\.aspectRatio),
                                                columns: columns)
        HStack(alignment: .top, spacing: spacing) {
            ForEach(buckets.indices, id: \.self) { column in
                LazyVStack(spacing: spacing) {
                    ForEach(buckets[column], id: \.self) { index in
                        let photo = photos[index]
                        PhotoCell(photo: photo,
                                  width: columnWidth,
                                  height: Self.cellHeight(for: photo, width: columnWidth),
                                  cornerRadius: settings.cardRadius,
                                  elevated: true,
                                  hoverScale: 1.02)
                            .id(photo.id)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: PhotoFramePreferenceKey.self,
                                        value: [photo.id: geo.frame(in: .named("galleryGrid"))]
                                    )
                                }
                            )
                    }
                }
                .frame(width: columnWidth)
            }
            Spacer(minLength: 0)
        }
    }

    /// 单元格高度按原始宽高比换算；超宽 / 超高素材收敛到可读范围。
    private static func cellHeight(for photo: PhotoItem, width: CGFloat) -> CGFloat {
        let aspect = min(4, max(0.25, photo.aspectRatio))
        return max(64, width / aspect)
    }
}

/// 列表：一行一项，缩略图 + 文件名 + 拍摄日期 / 尺寸 / 大小，适合快速查找与核对元数据。
struct PhotoListView: View {
    @EnvironmentObject private var store: LibraryStore
    let photos: [PhotoItem]
    let availableWidth: CGFloat

    /// 列表缩略图跟随工具栏缩放（56…360 → 28…96）。
    private var thumbSide: CGFloat { min(96, max(28, CGFloat(store.thumbSize) * 0.34)) }
    private var showsResolution: Bool { availableWidth >= 820 }
    private var showsFileSize: Bool { availableWidth >= 700 }

    var body: some View {
        LazyVStack(spacing: 0) {
            header
            ForEach(photos) { photo in
                PhotoListRow(photo: photo,
                             thumbSide: thumbSide,
                             showsResolution: showsResolution,
                             showsFileSize: showsFileSize)
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, 20 + thumbSide + 12)
                    .padding(.trailing, 20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: thumbSide, height: 1)
            Text("名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("拍摄日期")
                .frame(width: 120, alignment: .leading)
            if showsResolution {
                Text("尺寸")
                    .frame(width: 104, alignment: .leading)
            }
            if showsFileSize {
                Text("大小")
                    .frame(width: 82, alignment: .trailing)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

private struct PhotoListRow: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selectionModel: SelectionModel
    let photo: PhotoItem
    let thumbSide: CGFloat
    let showsResolution: Bool
    let showsFileSize: Bool

    @State private var isHovering = false

    private var isSelected: Bool { selectionModel.ids.contains(photo.id) }

    private var actionIDs: Set<UUID> {
        selectionModel.ids.contains(photo.id) && !selectionModel.ids.isEmpty ? selectionModel.ids : [photo.id]
    }

    private var kindText: String {
        if photo.isVideo {
            if let duration = photo.duration, duration > 0 {
                return "视频 · \(formatDuration(duration))"
            }
            return "视频"
        }
        return photo.isLivePhoto ? "实况照片" : "照片"
    }

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnailView(photo: photo, purpose: .cover(thumbSide))
                .frame(width: thumbSide, height: thumbSide)
                .clipShape(RoundedRectangle(cornerRadius: settings.smallCoverRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(photo.displayFilename)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if photo.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.pink)
                    }
                }
                Text(kindText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(DateText.dayFormatter.string(from: photo.capturedAt))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            if showsResolution {
                Text(photo.pixelWidth > 0 && photo.pixelHeight > 0
                     ? "\(photo.pixelWidth) × \(photo.pixelHeight)" : "—")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .leading)
            }

            if showsFileSize {
                Text(photo.fileSize > 0 ? formatFileSize(photo.fileSize) : "—")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.16)
                      : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
                .padding(.horizontal, 10)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PhotoFramePreferenceKey.self,
                    value: [photo.id: geo.frame(in: .named("galleryGrid"))]
                )
            }
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onDrag {
            PhotoDrag.provider(for: actionIDs)
        }
        .onTapGesture(count: 2) {
            store.openPhoto(photo.id, by: settings.photoOpenMode)
        }
        .onTapGesture {
            // 与网格一致：单击只负责选择，⌘ / ⇧ 单击多选，双击打开。
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) || flags.contains(.shift) {
                store.handleTap(photo.id)
            } else if selectionModel.ids.contains(photo.id), selectionModel.ids.count > 1 {
                store.selectionAnchorID = photo.id
            } else {
                store.handleTap(photo.id)
            }
        }
        .contextMenu {
            PhotoContextMenu(photo: photo, actionIDs: actionIDs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.displayTitle)
        .accessibilityValue("\(kindText) · \(DateText.dayFormatter.string(from: photo.capturedAt))")
        .help(photo.originalName)
    }
}
