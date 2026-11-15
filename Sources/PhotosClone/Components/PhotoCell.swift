import SwiftUI
import AppKit

struct PhotoCell: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selectionModel: SelectionModel
    let photo: PhotoItem
    let width: CGFloat
    let height: CGFloat
    /// 指定圆角；瀑布流等卡片式布局会传更大的半径。
    var cornerRadius: CGFloat?
    /// 常驻投影：让卡片从背景里浮起来（瀑布流使用）。
    var elevated: Bool = false
    /// 悬停放大倍率；瀑布流会放大得更明显，突出当前卡片。
    var hoverScale: CGFloat?
    @State private var image: NSImage?
    @State private var didLoad = false
    @State private var isHovering = false

    private var isSelected: Bool { selectionModel.ids.contains(photo.id) }

    /// 读屏也播报视频时长（网格角标只是视觉提示）。
    private var accessibilityValueText: String {
        var parts = [DateText.dayFormatter.string(from: photo.capturedAt)]
        if photo.isVideo, settings.metadata.duration, let duration = photo.duration, duration > 0 {
            parts.append(formatDuration(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// 网格单元格跟随设置里的小封面圆角，和侧边栏缩略图保持同一套半径。
    private var corner: CGFloat { cornerRadius ?? settings.smallCoverRadius }

    /// 网格加载键：只有格子尺寸档位变化时才重新解码缩略图。
    private var gridLoadKey: String {
        "\(photo.cacheKey)|\(ImageLoader.pixelBucket(for: max(width, height) * 2))"
    }

    private var actionIDs: Set<UUID> {
        selectionModel.ids.contains(photo.id) && !selectionModel.ids.isEmpty ? selectionModel.ids : [photo.id]
    }

    /// 按设置打开：查看器 / 编辑器 / 系统默认应用。
    private func openPhotoBySettings() {
        store.openPhoto(photo.id, by: settings.photoOpenMode)
    }

    // MARK: 元数据浮层

    private var metadata: MetadataOptions { settings.metadata }

    private var metadataChips: [PhotoMetadataChip] {
        var chips: [PhotoMetadataChip] = []
        if metadata.edited, photo.hasEdits {
            chips.append(PhotoMetadataChip(id: "edited", icon: "slider.horizontal.3", text: "已编辑"))
        }
        if metadata.fileType {
            let ext = (photo.displayFilename as NSString).pathExtension.uppercased()
            chips.append(PhotoMetadataChip(id: "type", icon: nil,
                                           text: ext.isEmpty ? (photo.isVideo ? "视频" : "照片") : ext))
        }
        if metadata.fileType, photo.isLivePhoto {
            chips.append(PhotoMetadataChip(id: "live", icon: "livephoto", text: "实况"))
        }
        if metadata.resolution, photo.pixelWidth > 0, photo.pixelHeight > 0 {
            chips.append(PhotoMetadataChip(id: "size",
                                           icon: nil,
                                           text: "\(photo.pixelWidth)×\(photo.pixelHeight)"))
        }
        if metadata.fileSize, photo.fileSize > 0 {
            chips.append(PhotoMetadataChip(id: "bytes",
                                           icon: nil,
                                           text: formatFileSize(photo.fileSize)))
        }
        if metadata.camera, let camera = photo.model ?? photo.make {
            chips.append(PhotoMetadataChip(id: "camera", icon: "camera", text: camera))
        }
        if metadata.location, photo.hasLocation {
            chips.append(PhotoMetadataChip(id: "place",
                                           icon: "mappin.and.ellipse",
                                           text: PlaceClusterBuilder.key(for: photo).title))
        }
        if metadata.capturedDate {
            chips.append(PhotoMetadataChip(id: "date",
                                           icon: nil,
                                           text: DateText.dayFormatter.string(from: photo.capturedAt)))
        }
        if metadata.keywords, let tags = photo.keywords, !tags.isEmpty {
            chips.append(PhotoMetadataChip(id: "tags",
                                           icon: "tag",
                                           text: tags.prefix(2).map { "#\($0)" }.joined(separator: " ")))
        }
        if metadata.source {
            let source: String
            if photo.isSystem {
                source = "引用文件"
            } else if photo.isCloud {
                source = "云端"
            } else {
                source = "本地"
            }
            chips.append(PhotoMetadataChip(id: "source", icon: "externaldrive", text: source))
        }
        return chips
    }

    private var metadataOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            if metadata.title {
                Text(photo.displayTitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.65), radius: 2, y: 0.5)
                    .padding(.leading, isSelected || isHovering ? 22 : 0)
            }
            Spacer(minLength: 0)
            if width >= 110 {
                let chips = metadataChips
                if !chips.isEmpty {
                    metadataChipRow(Array(chips.prefix(3)))
                    if chips.count > 3 {
                        metadataChipRow(Array(chips.dropFirst(3).prefix(3)))
                    }
                }
            }
        }
        .padding(7)
        .padding(.bottom, photo.isVideo ? 18 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.08), .black.opacity(0.62)],
                           startPoint: .center,
                           endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private func metadataChipRow(_ chips: [PhotoMetadataChip]) -> some View {
        HStack(spacing: 3) {
            ForEach(chips) { chip in
                HStack(spacing: 2) {
                    if let icon = chip.icon {
                        Image(systemName: icon)
                            .font(.system(size: 7, weight: .semibold))
                    }
                    Text(chip.text)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.8)
                .background(.black.opacity(0.42), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    var body: some View {
        ZStack {
            // 占位：柔和的灰阶渐变，避免加载时出现一整块死灰。
            LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.22),
                                    Color(nsColor: .quaternaryLabelColor).opacity(0.10)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            if let image {
                // 必须把图片约束在单元格尺寸内：aspectRatio(.fill) 会让图片按自身比例撑大
                // ZStack，导致右下角的时长角标被外层裁掉（正方形网格尤其明显）。
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .transition(.opacity)
            } else if didLoad {
                Image(systemName: photo.isVideo ? "video" : "photo")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            }

            if settings.metadata.hasTextOverlay {
                metadataOverlay
            }

            // 视频角标：始终显示，让视频在网格里一眼可辨；右下角对齐系统「照片」。
            if photo.isVideo {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 3) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8, weight: .semibold))
                            if settings.metadata.duration, let duration = photo.duration, duration > 0 {
                                Text(formatDuration(duration))
                                    .font(.system(size: 9, weight: .semibold))
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.42), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                    .padding(6)
                }
                .allowsHitTesting(false)
            }

            if photo.isFavorite, settings.metadata.favorite {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "heart.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.32), in: Circle())
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    Spacer()
                }
                .padding(6)
                .allowsHitTesting(false)
            }

            // 选中态已由强调色描边表达，这里只在悬停时给一个可选中的提示圆。
            if isHovering && !isSelected {
                VStack {
                    HStack {
                        Circle()
                            .fill(Color.white.opacity(0.78))
                            .frame(width: 20, height: 20)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.8)
                            }
                            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .overlay {
            if isSelected {
                // 内圈白色细线让彩色描边在亮色照片上也能看清。
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .inset(by: 1.5)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
            }
        }
        .scaleEffect(isHovering && settings.hoverLift ? (hoverScale ?? settings.motion.hoverScale) : 1)
        .modifier(PhotoCellShadow(hovered: isHovering && settings.hoverLift,
                                  selected: isSelected,
                                  elevated: elevated))
        .animation(settings.motion.hover, value: isHovering)
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .contentShape(Rectangle())
        .onDrag {
            PhotoDrag.provider(for: actionIDs)
        } preview: {
            PhotoDragPreview(image: image, count: actionIDs.count)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            openPhotoBySettings()
        }
        .onTapGesture {
            // 单击只负责选择；打开走双击（或键盘回车），避免点选时被查看器打断。
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) || flags.contains(.shift) {
                store.handleTap(photo.id)
            } else if selectionModel.ids.contains(photo.id), selectionModel.ids.count > 1 {
                // 在多选中再次单击其中一项：保留多选，只更新锚点。
                store.selectionAnchorID = photo.id
            } else {
                store.handleTap(photo.id)
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers, location in
            guard let albumID = store.currentAlbumID else { return false }
            PhotoDrag.loadIDs(from: providers) { ids in
                guard let draggedID = ids.first, draggedID != photo.id else { return }
                Task { @MainActor in
                    store.moveAlbumPhotos(albumID: albumID,
                                          moving: Set(ids),
                                          targetID: photo.id,
                                          after: location.x > width / 2)
                }
            }
            return true
        }
        .contextMenu {
            PhotoContextMenu(photo: photo, actionIDs: actionIDs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.displayTitle)
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint("单击打开；按住 ⌘ 或 ⇧ 单击可多选")
        .task(id: gridLoadKey) {
            didLoad = false
            let loaded = await PhotoThumbnailLoader.load(photo: photo,
                                                         purpose: .grid(maxPixel: max(width, height) * 2),
                                                         store: store) { quick in
                // 快速层先出图；滑出视野时任务被取消，目标档位不会再覆盖。
                image = quick
                didLoad = true
            }
            guard !Task.isCancelled else { return }
            if let loaded { image = loaded }
            didLoad = true
        }
        .help(photo.originalName)
    }

}

/// 网格与列表共用的照片右键菜单。
struct PhotoContextMenu: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var selectionModel: SelectionModel
    let photo: PhotoItem
    let actionIDs: Set<UUID>

    var body: some View {
        if photo.isSystem {
            Button("打开") {
                store.openViewer(photo.id)
            }
            // 当前图库就是官方「照片」图库时，拾光可以补充元数据（只写拾光数据库）。
            if store.canEditNativeOverlay {
                Button(photo.isFavorite ? "取消收藏" : "收藏") {
                    selectionModel.ids = [photo.id]
                    store.toggleFavoriteSelection()
                }
                Button(photo.isHidden ? "取消隐藏" : "隐藏") {
                    selectionModel.ids = [photo.id]
                    store.setHidden([photo.id], hidden: !photo.isHidden)
                }
                Button("添加关键词…") {
                    selectionModel.ids = [photo.id]
                    store.showKeywordManager = true
                }
            }
            Button("导出…") {
                store.export(photo.id)
            }
            Button("在访达中显示") {
                store.revealInFinder(photo.id)
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Divider()
            Button("导入到我的图库") {
                selectionModel.ids = [photo.id]
                store.importSystemSelectionToLibrary()
            }
        } else if photo.isCloud {
            Button("打开") {
                store.openViewer(photo.id)
            }
            Button(photo.isFavorite ? "取消收藏" : "收藏") {
                store.toggleFavorite(photo.id)
            }
            if store.isCurrentCloudWritable {
                Button("重命名…") {
                    store.requestCloudRename(photo.id)
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    selectionModel.ids = actionIDs
                    store.presentBatchExport()
                }
            } else {
                Button("导出…") {
                    store.export(photo.id)
                }
            }
            Button("幻灯片播放") {
                selectionModel.ids = actionIDs
                store.presentSlideshow()
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Button("打印…") {
                selectionModel.ids = actionIDs
                store.printCommand()
            }
            if store.isCurrentCloudSMB {
                Button("在访达中显示") {
                    store.revealInFinder(photo.id)
                }
            }
            Divider()
            Button("复制文件地址") {
                Task {
                    guard let url = await store.cloudStream(for: photo)?.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if store.isCurrentCloudWritable {
                Divider()
                Button("从云端删除…", role: .destructive) {
                    store.confirmDeleteCloud([photo.id])
                }
            }
        } else if photo.isDeleted {
            Button("恢复") {
                store.restore([photo.id])
            }
            Button("永久删除…", role: .destructive) {
                store.confirmPermanentDelete([photo.id])
            }
        } else {
            Button("打开") {
                store.openViewer(photo.id)
            }
            if !photo.isVideo {
                Button("查找相似照片") {
                    store.findSimilarPhotos(to: photo.id)
                }
            }
            Button(photo.isFavorite ? "取消收藏" : "收藏") {
                store.toggleFavorite(photo.id)
            }
            Menu("添加到相簿") {
                ForEach(store.albumsSorted) { album in
                    Button(album.name) {
                        store.addToAlbum(album.id, photoIDs: [photo.id])
                    }
                }
                if store.albums.isEmpty {
                    Text("暂无相簿")
                } else {
                    Divider()
                }
                Button("新建相簿…") {
                    store.showNewAlbumSheet = true
                }
            }
            if let albumID = store.currentAlbumID {
                if store.currentAlbumCoverID == photo.id {
                    Button("恢复自动封面") {
                        store.setAlbumCover(nil, for: albumID)
                    }
                } else {
                    Button("设为相册封面") {
                        store.setAlbumCover(photo.id, for: albumID)
                    }
                }
            }
            Button(photo.isHidden ? "取消隐藏" : "隐藏") {
                store.setHidden([photo.id], hidden: !photo.isHidden)
            }
            Button("添加关键词…") {
                selectionModel.ids = [photo.id]
                store.showKeywordManager = true
            }
            if !photo.isVideo {
                Button("压缩…") {
                    store.presentCompression(for: actionIDs)
                }
                if PhotoCompressor.hasBackup(for: photo) {
                    Button("还原压缩前的原图") {
                        store.revertCompression(photo.id)
                    }
                }
            }
            if actionIDs.count > 1 {
                Button("导出所选到文件夹…") {
                    store.presentBatchExport()
                }
            }
            if !photo.isReadOnly {
                Button("批量更改…") {
                    selectionModel.ids = actionIDs
                    store.presentBatchChange()
                }
            }
            Divider()
            if !photo.isVideo {
                Button("编辑…") {
                    store.openEditor(photo.id)
                }
                if photo.hasEdits {
                    Button("复制编辑点") {
                        store.copyEdits(photo.id)
                    }
                }
                if store.copiedEditRecipe != nil {
                    Button("粘贴编辑点") {
                        store.pasteEdits(photo.id)
                    }
                }
                Menu("旋转") {
                    Button("向右旋转") {
                        selectionModel.ids = actionIDs
                        store.rotateCommand(clockwise: true)
                    }
                    Button("向左旋转") {
                        selectionModel.ids = actionIDs
                        store.rotateCommand(clockwise: false)
                    }
                }
            }
            Button("复制照片") {
                selectionModel.ids = actionIDs
                store.duplicateCommand()
            }
            Button("打印…") {
                selectionModel.ids = actionIDs
                store.printCommand()
            }
            Button("幻灯片播放") {
                selectionModel.ids = actionIDs
                store.presentSlideshow()
            }
            Button("导出…") {
                store.export(photo.id)
            }
            Button("在访达中显示") {
                store.revealInFinder(photo.id)
            }
            if !photo.isVideo {
                Button("设为桌面背景") {
                    store.setAsDesktopBackground(photo.id)
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                store.delete([photo.id])
            }
        }
    }
}

/// 网格中只在悬停/选中时添加阴影；瀑布流卡片（`elevated`）常驻一层轻投影，
/// 让卡片从背景里浮起来，可见数量由 Lazy 容器限制，不会整库离屏合成。
private struct PhotoCellShadow: ViewModifier {
    let hovered: Bool
    let selected: Bool
    var elevated: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if hovered || selected || elevated {
            content
                .shadow(color: .black.opacity(hovered ? 0.18 : (elevated ? 0.12 : 0)),
                        radius: hovered ? 8 : 6,
                        y: hovered ? 3 : 2)
                .shadow(color: selected ? Color.accentColor.opacity(0.28) : .clear, radius: 6, y: 1)
        } else {
            content
        }
    }
}

struct PhotoMetadataChip: Identifiable {
    let id: String
    let icon: String?
    let text: String
}

/// 收集网格中每个单元格的位置，用于框选命中判断。
struct PhotoFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 框选用的单元格位置缓存。用引用类型保存，更新时不触发视图重排。
final class PhotoFrameCache {
    var frames: [UUID: CGRect] = [:]
}
