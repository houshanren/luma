import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InfoPanelView: View {
    @Environment(ViewerModel.self) private var viewer
    let photo: PhotoItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: photo.isVideo ? "video" : "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("信息")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    viewer.showInfoPanel = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                PhotoInfoContent(photo: photo)
                    .padding(18)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)
        }
        .foregroundStyle(.primary)
    }
}

/// 单张照片的完整信息分区。
/// 查看器右侧信息面板与网格浮动信息卡共用这一份实现，避免两套详情各自缺字段。
///
/// 分块原则：每块只读自己需要的数据。智能标签读分析索引、关键词读照片本身、
/// 相簿读相簿列表、其他读网盘挂载——拆成独立视图后，任何一处数据更新
/// 只重算对应那一块，不再让整张信息卡（含地图）一起重排。
struct PhotoInfoContent: View {
    let photo: PhotoItem

    @Environment(LibraryStore.self) private var store

    private var typeDescription: String {
        let ext = (photo.displayFilename as NSString).pathExtension
        var description = LibraryStore.kindTitle(photo.kind)
        if let type = UTType(filenameExtension: ext), let localized = type.localizedDescription {
            description = localized
        } else if !ext.isEmpty {
            description = ext.uppercased()
        }
        return photo.isRAWFile ? "\(description)（RAW）" : description
    }

    private var locationText: String? {
        guard photo.hasLocation, let latitude = photo.latitude, let longitude = photo.longitude else { return nil }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    private var hasCameraInfo: Bool {
        photo.make != nil || photo.model != nil || photo.lens != nil
            || photo.focalLength != nil || photo.aperture != nil
            || photo.shutterSpeed != nil || photo.iso != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            fileSection
            dateSection
            PhotoInfoOrganizeSection(photo: photo)
            if hasCameraInfo {
                cameraSection
            }
            if let locationText, photo.hasLocation {
                locationSection(locationText: locationText)
            }
            PhotoInfoSmartTagsSection(photo: photo)
            PhotoInfoKeywordSection(photo: photo)
            PhotoInfoAlbumSection(photo: photo)
            PhotoInfoOtherSection(photo: photo)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: photo.id) {
            // 图集看图里的虚拟照片：打开信息面板时按需补一次尺寸 / 体积 / EXIF。
            store.refreshCatalogGalleryMetrics(for: photo.id)
        }
    }

    // MARK: 基本

    private var fileSection: some View {
        infoSection("照片") {
            if let title = photo.title, !title.isEmpty {
                infoRow("标题", title)
            }
            infoRow("文件名", photo.originalName)
            infoRow("类型", typeDescription)
            if photo.kind != .photo {
                infoRow("分类", LibraryStore.kindTitle(photo.kind))
            }
            let hasPixels = photo.displayPixelWidth > 0 && photo.displayPixelHeight > 0
            infoRow("尺寸", hasPixels
                ? "\(photo.displayPixelWidth) × \(photo.displayPixelHeight)"
                : "—")
            infoRow("文件大小", photo.fileSize > 0 ? formatFileSize(photo.fileSize) : "—")
            if photo.isVideo, let duration = photo.duration {
                infoRow("时长", formatDuration(duration))
            }
            if photo.isLivePhoto {
                infoRow("实况照片", "是")
            }
            if photo.isBurstItem {
                infoRow("连拍项目", "是")
            }
            if photo.isSlowMotion {
                infoRow("慢动作", "是")
            }
            if photo.isScreenRecording {
                infoRow("屏幕录制", "是")
            }
            if photo.isAnimated || photo.isAnimatedFile {
                infoRow("动图", "是")
            }
            if photo.isPortraitCapture {
                infoRow("人像", "是")
            }
            if photo.isDuplicateItem {
                infoRow("重复项目", "是")
            }
            if photo.isRotated {
                infoRow("旋转", "\(photo.rotationAngle)°")
            }
        }
    }

    private var dateSection: some View {
        infoSection("拍摄时间") {
            infoRow("日期", DateText.dayFormatter.string(from: photo.capturedAt))
            infoRow("时间", DateText.secondTimeFormatter.string(from: photo.capturedAt))
            if let viewedAt = photo.viewedAt {
                infoRow("最近查看", DateText.fullFormatter.string(from: viewedAt))
            }
            if let editedAt = photo.editedAt {
                infoRow("最近编辑", DateText.fullFormatter.string(from: editedAt))
            }
        }
    }

    private var cameraSection: some View {
        infoSection("相机") {
            if let make = photo.make, let model = photo.model, !model.hasPrefix(make) {
                infoRow("相机", "\(make) \(model)")
            } else {
                infoRow("相机", photo.model ?? photo.make ?? "—")
            }
            if let lens = photo.lens { infoRow("镜头", lens) }
            if let focal = photo.focalLength { infoRow("焦距", focal) }
            if let aperture = photo.aperture { infoRow("光圈", aperture) }
            if let shutter = photo.shutterSpeed { infoRow("快门", shutter) }
            if let iso = photo.iso { infoRow("ISO", iso) }
        }
    }

    private func locationSection(locationText: String) -> some View {
        infoSection("位置") {
            // 与查看器顶栏、网格地点标签共用同一套层级与回退顺序。
            let placeTitle = photo.placeTitle
            if let placeTitle, placeTitle != locationText {
                infoRow("地点", placeTitle)
            }
            if let country = photo.placeCountry {
                infoRow("国家/地区", country)
            }
            if let province = photo.placeProvince, province != placeTitle {
                infoRow("省份", province)
            }
            if let city = photo.placeCity {
                infoRow("城市", city)
            }
            if let district = photo.placeDistrict {
                infoRow("区/县", district)
            }
            if let poi = photo.placePOI {
                infoRow("街道", poi)
            }
            infoRow("坐标", locationText)
            MiniPhotoMap(photos: [photo])
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .help("拖动平移、滚轮缩放地图")
                .padding(.top, 2)
        }
    }
}

// MARK: - 读库数据的区块

/// 整理（评分 / 旗标 / 色标）：只关心「能否编辑元数据」这一个开关。
private struct PhotoInfoOrganizeSection: View {
    @Environment(LibraryStore.self) private var store
    let photo: PhotoItem

    var body: some View {
        infoSection("整理") {
            HStack(spacing: 4) {
                Text("评分")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                ForEach(1...5, id: \.self) { value in
                    Button {
                        store.setRating(photo.starRating == value ? 0 : value, ids: [photo.id])
                    } label: {
                        Image(systemName: value <= photo.starRating ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(value <= photo.starRating ? Color.yellow : Color.secondary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("\(value) 星")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("旗标")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                ForEach(PhotoFlag.allCases) { flag in
                    Button {
                        store.setFlag(photo.pickFlag == flag ? .none : flag, ids: [photo.id])
                    } label: {
                        Image(systemName: flag.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(photo.pickFlag == flag ? flag.color : Color.secondary)
                            .frame(width: 24, height: 22)
                            .background(
                                photo.pickFlag == flag ? flag.color.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(flag.title)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("色标")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                ForEach(PhotoColorLabel.allCases) { label in
                    Button {
                        store.setColorLabel(photo.labelColor == label ? .none : label, ids: [photo.id])
                    } label: {
                        Circle()
                            .fill(label.color)
                            .frame(width: 13, height: 13)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        photo.labelColor == label ? Color.primary : Color.white.opacity(0.55),
                                        lineWidth: photo.labelColor == label ? 2 : 0.8
                                    )
                            }
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(label.title)
                    .disabled(label == .none)
                    .opacity(label == .none ? 0 : 1)
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(!store.canEditMetadataWorkflow)
    }
}

/// 智能标签：分析索引变化时只重算这一块。
private struct PhotoInfoSmartTagsSection: View {
    @Environment(LibraryStore.self) private var store
    let photo: PhotoItem

    var body: some View {
        let smartScenes = store.sceneTitles(for: photo)
        let smartTags = store.photoTagTitles(for: photo)
        let smartText = store.ocrText(for: photo.id)
        if !smartScenes.isEmpty || !smartTags.isEmpty || smartText != nil
            || (store.analysisIndex[photo.id] == nil && store.canAnalyzeIntelligence
                && !photo.isVideo && !photo.isReadOnly) {
            infoSection("智能标签") {
                if !smartTags.isEmpty {
                    infoRow("画面", smartTags.prefix(10).joined(separator: " · "))
                }
                if !smartScenes.isEmpty {
                    infoRow("场景", smartScenes.joined(separator: " · "))
                }
                if let landmark = store.landmarkName(for: photo) {
                    infoRow("地标", landmark)
                }
                if let smartText {
                    infoRow("文字", String(smartText.prefix(220)))
                }
                // 标注当前标签是哪个模型给的：关掉 SigLIP2 后标签会明显变粗，避免误以为是模型变差。
                if !photo.isReadOnly {
                    if !ModelRegistry.isEnabled(.siglip2) {
                        Text("本地图像理解未开启：以上标签来自系统 Vision 分类（少量粗粒度概念），没有 249 个中文标签与语义扩展，相似检索会退回 Vision 特征；在「设置 › 本地模型」开启后会自动补扫。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if store.analysisIndex[photo.id] != nil, store.needsReanalysis(photo.id) {
                        Text("这张还是旧版识别结果：开启本地图像理解后会自动补扫，标签会以 249 个中文标签重算。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if store.analysisIndex[photo.id] == nil, !photo.isVideo, !photo.isReadOnly {
                    Button("分析此照片") {
                        store.analyzeSinglePhoto(photo.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("在本机识别场景与照片中的文字")
                }
            }
        }
    }
}

/// 关键词：只读照片本身，不依赖库状态。
private struct PhotoInfoKeywordSection: View {
    let photo: PhotoItem

    var body: some View {
        if !photo.tags.isEmpty {
            infoSection("关键词") {
                // 用 `/` 分隔的路径按层级缩进展示；父级只作为结构，不重复写成多个标签。
                ForEach(photo.tags.sorted(), id: \.self) { path in
                    let depth = PhotoItem.keywordDepth(path)
                    let components = PhotoItem.keywordComponents(path)
                    HStack(spacing: 6) {
                        if depth > 0 {
                            Spacer()
                                .frame(width: CGFloat(depth) * 12)
                        }
                        Image(systemName: depth == 0 ? "folder" : "tag")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(PhotoItem.keywordLeaf(path))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                        if components.count > 1 {
                            Text(components.dropLast().joined(separator: " / "))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .help(path)
                }
            }
        }
    }
}

/// 所属相簿：相簿列表变化时只重算这一块。
private struct PhotoInfoAlbumSection: View {
    @Environment(LibraryStore.self) private var store
    let photo: PhotoItem

    var body: some View {
        let albums = store.albumsContaining(photo.id)
        let systemAlbumNames = photo.isSystem ? store.systemAlbumNamesContaining(photo.id) : []
        if !albums.isEmpty || !systemAlbumNames.isEmpty {
            infoSection("所属相簿") {
                ForEach(albums) { album in
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(album.name)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
                ForEach(systemAlbumNames, id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
        }
    }
}

/// 其他：来源描述要读网盘挂载，单独成块。
private struct PhotoInfoOtherSection: View {
    @Environment(LibraryStore.self) private var store
    let photo: PhotoItem

    private var sourceDescription: String {
        // 图集看图的虚拟照片：它不属于网盘挂载，直接标注为在线图集。
        if let context = store.catalogGalleryContext(for: photo.id) {
            return "网络图集 · \(context.source.name)"
        }
        if photo.isSystem { return "系统照片图库（只读）" }
        if photo.isCloud {
            let kind = store.cloudMount(for: photo.cloudMountID)?.kind.title ?? "网络存储"
            return "\(kind)（只读）"
        }
        return "本地图库"
    }

    var body: some View {
        infoSection("其他") {
            infoRow("添加日期", DateText.dayFormatter.string(from: photo.addedAt))
            infoRow("来源", sourceDescription)
            if photo.isCloud, store.catalogGalleryContext(for: photo.id) == nil {
                if let mountName = store.cloudMount(for: photo.cloudMountID)?.name {
                    infoRow("网络位置", mountName + " / " + (photo.cloudPath ?? photo.originalName))
                }
            }
            if photo.isFavorite {
                infoRow("收藏", "是")
            }
            if photo.isHidden {
                infoRow("隐藏", "是")
            }
            if let deletedAt = photo.deletedAt {
                infoRow("最近删除", DateText.fullFormatter.string(from: deletedAt))
            }
            if photo.hasEdits {
                infoRow("编辑", "已编辑")
            }
        }
    }
}

// MARK: - 分区排版

private func infoSection<Content: View>(_ title: String,
                                       @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func infoRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Text(label)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(width: 62, alignment: .leading)
        Text(value)
            .font(.system(size: 11.5))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
