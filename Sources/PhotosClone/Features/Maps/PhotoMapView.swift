import SwiftUI
import MapKit

enum PhotoMapRegion {
    static func region(for photos: [PhotoItem]) -> MKCoordinateRegion {
        let latitudes = photos.compactMap { $0.latitude }
        let longitudes = photos.compactMap { $0.longitude }
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                                      span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let latSpan = max((maxLat - minLat) * 1.6, 0.012)
        let lonSpan = max((maxLon - minLon) * 1.6, 0.012)
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
    }
}

private func coordinate(_ photo: PhotoItem) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: photo.latitude ?? 0, longitude: photo.longitude ?? 0)
}

struct PhotoMapView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var camera = MapCameraController()
    @State private var showKeySheet = false
    @State private var keyDraft = ""
    @State private var showFootprint = false
    @AppStorage("map.style") private var styleRaw = MapStyleMode.map.rawValue
    @AppStorage("map.provider") private var providerRaw = MapProvider.apple.rawValue
    @AppStorage("map.baiduAccessKey") private var baiduKey = ""

    private var style: MapStyleMode { MapStyleMode(rawValue: styleRaw) ?? .map }
    private var provider: MapProvider { MapProvider(rawValue: providerRaw) ?? .apple }

    private var photos: [PhotoItem] { store.geoPhotos }
    private var clusters: [PlaceCluster] { store.placeClusters }

    var body: some View {
        Group {
            if photos.isEmpty {
                EmptyStateView()
            } else {
                ZStack {
                    if style == .grid {
                        GeometryReader { proxy in
                            MapPlaceGridView(photos: photos, availableWidth: proxy.size.width)
                        }
                        .background(Color(nsColor: .windowBackgroundColor))
                        .transition(.opacity)
                    } else {
                        MapCanvasView(clusters: clusters,
                                      provider: provider,
                                      style: style,
                                      baiduKey: baiduKey,
                                      controller: camera) { id in
                            store.openViewer(id)
                        }
                        .ignoresSafeArea()
                    }

                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            legendBadge
                            if style != .grid {
                                footprintButton
                            }
                            Spacer(minLength: 8)
                            styleSwitcher
                            Spacer(minLength: 8)
                            providerMenu
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 14)

                        Spacer(minLength: 0)

                        HStack(alignment: .bottom) {
                            if provider == .baidu && baiduKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                baiduHint
                            }
                            Spacer(minLength: 8)
                            zoomControls
                        }
                        .padding(18)
                    }

                    if showFootprint {
                        FootprintPlaybackView(photos: photos) {
                            showFootprint = false
                        }
                        .transition(.opacity)
                        .zIndex(6)
                    }
                }
                .sheet(isPresented: $showKeySheet) {
                    baiduKeySheet
                }
                .onAppear {
                    // 「网格」是一次性的浏览方式：重新进入地图页时回到默认的地图底图。
                    if style == .grid {
                        styleRaw = MapStyleMode.map.rawValue
                    }
                    store.resolveMissingPlacesIfNeeded()
                }
            }
        }
    }

    // MARK: - 浮层

    private var legendBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: style == .grid ? "mappin.circle" : "mappin.and.ellipse")
                .font(.system(size: 11))
            Text("\(clusters.count) 个地点 · \(photos.count.formatted()) 张照片")
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private var footprintButton: some View {
        Button {
            showFootprint = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.circle")
                    .font(.system(size: 11))
                Text("足迹回放")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("按时间顺序把照片地点播成一条足迹")
    }

    private var styleSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(MapStyleMode.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { styleRaw = mode.rawValue }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: style == mode ? .semibold : .regular))
                        .foregroundStyle(style == mode ? .primary : .secondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background {
                            if style == mode {
                                Capsule().fill(Color.primary.opacity(0.16))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var providerMenu: some View {
        Menu {
            ForEach(MapProvider.allCases) { item in
                Button {
                    providerRaw = item.rawValue
                    if item == .baidu && baiduKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        keyDraft = baiduKey
                        showKeySheet = true
                    }
                } label: {
                    if provider == item {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
            Divider()
            Button("填写百度地图 AK…") {
                keyDraft = baiduKey
                showKeySheet = true
            }
            if !baiduKey.isEmpty {
                Button("清除百度 AK") { baiduKey = "" }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10.5, weight: .medium))
                Text(provider.shortTitle)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var zoomControls: some View {
        VStack(spacing: 1) {
            if style == .grid {
                gridSizeButton(icon: "plus", help: "放大网格", delta: 16)
                Divider().frame(width: 18)
                gridSizeButton(icon: "minus", help: "缩小网格", delta: -16)
                Divider().frame(width: 18)
                Button {
                    withAnimation(settings.motion.layout) { store.thumbSize = 132 }
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("恢复默认网格大小")
            } else {
                Button { camera.zoom(factor: 0.55) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("放大")

                Divider().frame(width: 18)

                Button { camera.zoom(factor: 1.8) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("缩小")

                Divider().frame(width: 18)

                Button { camera.fit(clusters) } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("显示全部位置")
            }
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    /// 网格模式下的缩放按钮：调整缩略图档位，范围与工具栏滑杆一致。
    private func gridSizeButton(icon: String, help: String, delta: Double) -> some View {
        Button {
            withAnimation(settings.motion.layout) {
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                      max(LibraryStore.thumbSizeRange.lowerBound,
                                          store.thumbSize + delta))
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var baiduHint: some View {
        Button {
            keyDraft = baiduKey
            showKeySheet = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 11))
                Text("百度底图需要 AK，点此填写")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var baiduKeySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("百度地图 AK")
                .font(.system(size: 16, weight: .semibold))
            Text("百度底图使用百度自有瓦片编号，需要地图开放平台申请的 AK；目前仅提供街道图。高德与苹果底图无需 AK。若底图空白，请确认 AK 是否有效。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("请输入 AK", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { showKeySheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    baiduKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    showKeySheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}


struct MiniPhotoMap: View {
    let photos: [PhotoItem]

    /// 地图身份：一组照片变化时重建，让镜头重新对准新的位置；同一组内保留用户缩放/平移。
    private var identity: String {
        photos.prefix(60).map(\.id.uuidString).joined(separator: ",")
    }

    var body: some View {
        Map(initialPosition: .region(PhotoMapRegion.region(for: photos)),
            interactionModes: [.pan, .zoom]) {
            ForEach(photos.prefix(60)) { photo in
                Annotation("", coordinate: coordinate(photo), anchor: .bottom) {
                    marker(single: photos.count == 1)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .id(identity)
    }

    /// 单张照片用大号坐标图钉，多张照片用紧凑图钉避免互相遮挡。
    private func marker(single: Bool) -> some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: single ? 22 : 14, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.accentColor, Color.white)
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
    }
}

struct LibraryInfoView: View {
    @EnvironmentObject private var store: LibraryStore

    private var geoPhotos: [PhotoItem] { store.geoPhotos }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: "photo.stack")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("照片图库")
                        .font(.system(size: 14, weight: .semibold))
                    Text(store.containerLibraryName ?? "本地照片库")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 3) {
                if let range = store.libraryDateRange {
                    Text(range)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("\(max(0, store.totalLibraryCount - store.videoCount).formatted()) 张照片，\(store.videoCount.formatted()) 个视频")
                    .font(.system(size: 12.5, weight: .medium))
                Text(formatFileSize(store.libraryTotalBytes))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if let description = store.storageLocationDescription {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if store.hasContainerLibrary {
                Button {
                    store.openContainerInPhotos()
                } label: {
                    Label("在「照片」中打开图库", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.link)
            }

            Divider()

            Text(geoPhotos.count > 1 ? "多个位置" : "位置")
                .font(.system(size: 12.5, weight: .semibold))

            if geoPhotos.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 11))
                    Text("没有带位置信息的照片")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                MiniPhotoMap(photos: geoPhotos)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
            }
        }
        .padding(18)
        .frame(width: 372)
    }
}

struct SystemLibraryInfoView: View {
    @EnvironmentObject private var store: LibraryStore

    private var visiblePhotos: [PhotoItem] {
        store.systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden }
    }

    private var geoPhotos: [PhotoItem] {
        visiblePhotos.filter { $0.latitude != nil && $0.longitude != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: "photo.stack")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.systemLibraryName ?? "系统照片图库")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("系统照片图库 · 只读")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let path = store.systemLibraryPath {
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let range = store.systemLibraryDateRange {
                    Text(range)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("\((visiblePhotos.count - visiblePhotos.filter { $0.isVideo }.count).formatted()) 张照片，\(visiblePhotos.filter { $0.isVideo }.count.formatted()) 个视频")
                    .font(.system(size: 12.5, weight: .medium))
                Text(formatFileSize(store.systemLibraryTotalBytes))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(geoPhotos.count > 1 ? "多个位置" : "位置")
                .font(.system(size: 12.5, weight: .semibold))

            if geoPhotos.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 11))
                    Text("没有带位置信息的照片")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                MiniPhotoMap(photos: geoPhotos)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
            }
        }
        .padding(18)
        .frame(width: 372)
    }
}

/// 网格浮动信息卡里的单张照片详情：头部缩略图 + 状态徽标，正文复用查看器信息面板的完整分区。
struct PhotoQuickInfoView: View {
    let photo: PhotoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                PhotoThumbnailView(photo: photo)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(DateText.fullFormatter.string(from: photo.capturedAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    statusBadges
                }
                Spacer(minLength: 0)
            }

            Divider()

            PhotoInfoContent(photo: photo)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusBadges: some View {
        HStack(spacing: 6) {
            if photo.isVideo {
                badge("video.fill", "视频")
            }
            if photo.isLivePhoto {
                badge("livephoto", "实况照片")
            }
            if photo.isFavorite {
                badge("heart.fill", "已收藏", tint: Color.accentColor)
            }
            if photo.hasEdits {
                badge("slider.horizontal.3", "已编辑")
            }
            if photo.isHidden {
                badge("eye.slash", "已隐藏")
            }
            if photo.isDeleted {
                badge("trash", "最近删除")
            }
        }
    }

    private func badge(_ symbol: String, _ help: String, tint: Color = .secondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .help(help)
    }
}
